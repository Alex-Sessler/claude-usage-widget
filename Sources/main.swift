import AppKit
import ServiceManagement

// MARK: - Menu bar app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var latest: UsageResponse?
    private var lastError: Error?
    private var lastUpdated: Date?
    private var isRefreshing = false
    /// While the API rate-limits us, skip calls until this time (doubling, up to 10 min).
    private var nextAPIAttempt: Date?
    private var backoff: TimeInterval = 0

    private let scanner = TranscriptScanner()
    private let spikeGuard = SpikeGuard()
    private var paused: [PausedProcess] = []
    private let windowTally = WindowTally()
    /// Titles of the top sessions, re-read from their transcripts every few minutes.
    private var topContexts: [String: (context: SessionContext, loadedAt: Date)] = [:]
    private let clearedSessions = ClearedSessions()
    /// Top sessions that were ended with `/clear`.
    private var topCleared: Set<String> = []
    /// What the last real spike was and who caused it, kept for the menu.
    private var lastSpike: String?
    private let menu = NSMenu()

    private var spikeGuardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "spikeGuardEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "spikeGuardEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        statusItem.menu = menu
        render()

        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 5

        // The timer doesn't fire while asleep; refresh right away on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()
        if UserDefaults.standard.object(forKey: "spikeGuardEnabled") == nil { askAboutSpikeGuard() }
    }

    /// First launch only: the spike guard inspects and pauses processes, so turning it
    /// on is the user's call. Either answer is saved, so this isn't asked again.
    private func askAboutSpikeGuard() {
        let alert = NSAlert()
        alert.messageText = "Turn on the spike guard?"
        alert.informativeText = "The spike guard watches for sudden jumps in your session usage "
            + "(+\(Int(Config.spikeThreshold))% of the session limit in \(Int(Config.spikeWindow / 60)) min by default). "
            + "When one happens, it shows which local Claude Code sessions caused it and pauses them "
            + "unless you decline. Pausing is reversible.\n\n"
            + "Without it, the widget only shows your usage. You can change this any time in the menu."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Keep Off")
        NSApp.activate(ignoringOtherApps: true)
        setSpikeGuard(alert.runModal() == .alertFirstButtonReturn)
    }

    private func setSpikeGuard(_ enabled: Bool) {
        spikeGuardEnabled = enabled
        // Skip what was written while the guard was off, so it isn't attributed to the next poll.
        if enabled { _ = scanner.scan() }
        render()
    }

    // MARK: Polling

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Local activity is sampled every poll, even if the API call fails — but only
        // while the spike guard is on, or something it paused is still waiting.
        let now = Date()
        let guardOn = spikeGuardEnabled
        let table = guardOn || !paused.isEmpty ? Processes.table() : []
        let claudes = guardOn ? Processes.claudeProcesses(in: table) : []
        if guardOn { spikeGuard.recordActivity(scanner.scan(), processes: claudes, at: now) }
        updatePaused(table)

        if let next = nextAPIAttempt, now < next {
            isRefreshing = false
            updateWindowTally()
            render()
            return
        }

        Task {
            defer { isRefreshing = false; updateWindowTally(); render() }
            do {
                let usage = try await UsageClient.fetch()
                latest = usage
                lastError = nil
                nextAPIAttempt = nil
                backoff = 0
                lastUpdated = Date()

                if guardOn, spikeGuardEnabled, let session = usage.fiveHour,
                   let spike = spikeGuard.recordUtilization(session.utilization,
                                                            window: Self.windowKey(session.resetsAt), at: now) {
                    handleSpike(spike, processes: claudes, test: false)
                }
            } catch {
                lastError = error
                if case UsageError.rateLimited = error {
                    backoff = min(max(backoff * 2, 2 * 60), 10 * 60)
                    nextAPIAttempt = now.addingTimeInterval(backoff)
                }
            }
        }
    }

    /// The API's `resets_at` carries sub-second noise that varies per request; round it
    /// so samples from the same 5h window compare equal.
    private static func windowKey(_ date: Date?) -> Date? {
        date.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
    }

    /// Keeps the per-session token totals for the current 5h window up to date.
    private func updateWindowTally() {
        guard let resetsAt = Self.windowKey(latest?.fiveHour?.resetsAt), resetsAt > Date() else {
            windowTally.reset()
            topContexts = [:]
            topCleared = []
            return
        }
        windowTally.update(windowStart: resetsAt.addingTimeInterval(-5 * 60 * 60))
        let top = topSessions
        topContexts = topContexts.filter { entry in top.contains { $0.sessionId == entry.key } }
        for session in top where Date().timeIntervalSince(topContexts[session.sessionId]?.loadedAt ?? .distantPast) > 5 * 60 {
            topContexts[session.sessionId] = (SessionContext.load(session.transcript), Date())
        }
        topCleared = Set(top.filter { clearedSessions.isCleared($0.transcript) }.map(\.sessionId))
    }

    private var topSessions: [SessionActivity] {
        Array(windowTally.sessions.values.filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }.prefix(5))
    }

    /// Drops processes that were resumed (e.g. `fg` in their terminal) or have exited,
    /// and those that were replaced: the session was continued in a new process
    /// (`claude --resume`), or a new `claude` was started in the same terminal. The
    /// stopped process stays behind then, but nothing is waiting to be resumed.
    private func updatePaused(_ table: [ProcessEntry]) {
        guard !paused.isEmpty else { return }
        let sessions = Processes.sessionIds()
        let running = table.filter { Processes.isClaude($0) && !$0.isStopped }
        let runningSessions = Set(running.compactMap { sessions[$0.pid] })
        paused.removeAll { process in
            table.first { $0.pid == process.pid }?.isStopped != true
                || process.sessionId.map(runningSessions.contains) == true
                || running.contains { $0.hasTerminal && $0.tty == process.tty && !process.pids.contains($0.pid) }
        }
    }

    /// The menu is only rebuilt on a poll; catch up on what was resumed since.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let before = paused.count
        updatePaused(Processes.table())
        if paused.count != before { render() }
    }

    // MARK: Spike handling

    private enum Decision {
        case pausedByUser
        case pausedOnTimeout
        case declined
        case nothingToPause
    }

    private func handleSpike(_ spike: Spike, processes: [ClaudeProcess], test: Bool) {
        let candidates = spikeGuard.candidates(since: spike.since, processes: processes)
        var seen = Set(paused.map(\.pid))
        let targets = candidates.flatMap(\.processes).filter {
            !$0.entry.isStopped && seen.insert($0.pid).inserted
        }

        let table = Processes.table()
        let contexts = Dictionary(candidates.map { ($0.activity.sessionId, SessionContext.load($0.activity.transcript)) },
                                  uniquingKeysWith: { first, _ in first })
        let details = Dictionary(candidates.flatMap(\.processes).map { ($0.pid, Processes.details(of: $0.pid, in: table)) },
                                 uniquingKeysWith: { first, _ in first })

        let decision = ask(spike: spike, candidates: candidates, targets: targets,
                           contexts: contexts, details: details, test: test)

        if !test, decision == .pausedByUser || decision == .pausedOnTimeout {
            // Re-check right before signalling: a pid may have exited or been reused.
            let fresh = Processes.table()
            let current = Processes.claudeProcesses(in: fresh)
            // A nested claude inside another target's tree is stopped along with that tree.
            let covered = Set(targets.flatMap { Processes.descendants(of: $0.pid, in: fresh).map(\.pid) })
            for target in targets where !covered.contains(target.pid) {
                guard let process = current.first(where: { $0.pid == target.pid && $0.cwd == target.cwd }),
                      let result = Pauser.pause(process, table: fresh) else { continue }
                paused.append(result)
            }
        }

        if !test {
            let time = DateFormatter()
            time.dateFormat = "HH:mm"
            var summary = "Last spike \(time.string(from: Date())): +\(Int(spike.delta.rounded()))% — "
            if let main = candidates.first {
                summary += "mostly \(Self.name(main, contexts[main.activity.sessionId])) (\(Format.percent(main.share)) of local usage)"
            } else {
                summary += "not from a local session"
            }
            lastSpike = summary
        }

        spikeGuard.resetBaseline()
        render()
    }

    /// Folder and title: how a session is named in one line.
    private static func name(_ candidate: SpikeCandidate, _ context: SessionContext?) -> String {
        let folder = candidate.activity.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
        return folder + (context?.title.map { " “\(Format.truncate($0, 40))”" } ?? "")
    }

    /// Shows the spike alert. When there's something to pause, it pauses after
    /// `Config.replyTimeout` seconds without an answer.
    private func ask(spike: Spike, candidates: [SpikeCandidate], targets: [ClaudeProcess],
                     contexts: [String: SessionContext], details: [pid_t: Processes.Details],
                     test: Bool) -> Decision {
        let minutes = max(1, Int((Date().timeIntervalSince(spike.since) / 60).rounded()))
        let canPause = !targets.isEmpty
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (test ? "[TEST — nothing will be paused] " : "")
            + "Claude session usage jumped +\(Int(spike.delta.rounded()))% of the limit in \(minutes) min "
            + "(\(Format.percent(spike.from)) → \(Format.percent(spike.to)))"

        if candidates.isEmpty {
            alert.informativeText = "No local Claude Code session made API calls in that time, so the usage came "
                + "from somewhere else (claude.ai, another device, Claude Code on the web). Nothing to pause."
        } else {
            let main = candidates[0]
            alert.informativeText = "Main offender: \(Self.name(main, contexts[main.activity.sessionId])) — about "
                + "\(Format.percent(main.share)) of what local sessions used during the jump.\n\n"
                + (canPause
                    ? "The sessions marked PAUSE will be paused in \(Config.replyTimeout) s unless you choose otherwise. "
                        + "Pausing is reversible: type fg in that terminal to resume."
                    : "None of the active sessions has a running process that can be paused.")
            alert.accessoryView = candidateList(candidates, targets: targets, contexts: contexts, details: details)
        }

        let primary = alert.addButton(withTitle: canPause ? "Pause now" : "OK")
        if canPause { alert.addButton(withTitle: "Don't pause") }
        // The alert grabs focus while you may be typing elsewhere: a stray Return or
        // Escape must not decide for you, so both buttons need a click.
        for button in alert.buttons { button.keyEquivalent = "" }

        let label = canPause ? (test ? "Would pause" : "Pause now") : "OK"
        func setTitle(_ remaining: Int) {
            let title = "\(label) (\(remaining))"
            guard canPause else { primary.title = title; return }
            primary.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            ])
        }
        if canPause {
            primary.bezelColor = .systemRed
            primary.hasDestructiveAction = true
        }

        let timeout = NSApplication.ModalResponse(rawValue: 9_999)
        final class Countdown: @unchecked Sendable { var remaining = Config.replyTimeout }
        let countdown = Countdown()
        setTitle(countdown.remaining)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                countdown.remaining -= 1
                setTitle(countdown.remaining)
                if countdown.remaining <= 0 { NSApp.stopModal(withCode: timeout) }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        if let snapshot = Config.snapshotFile {
            // Testing only: render the alert to a PNG (works without screen-recording access).
            let shot = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let view = alert.window.contentView?.superview ?? alert.window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: snapshot)
                }
            }
            RunLoop.main.add(shot, forMode: .modalPanel)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        NSSound(named: "Funk")?.play()
        let response = alert.runModal()
        timer.invalidate()

        guard canPause else { return .nothingToPause }
        switch response {
        case timeout: return .pausedOnTimeout
        case .alertFirstButtonReturn: return .pausedByUser
        default: return .declined
        }
    }

    /// One block per active session: where it runs, what it's about, which process it
    /// is and what it did during the spike.
    private func candidateList(_ candidates: [SpikeCandidate], targets: [ClaudeProcess],
                               contexts: [String: SessionContext], details: [pid_t: Processes.Details]) -> NSView {
        let size = NSFont.smallSystemFontSize + 1
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                                     .foregroundColor: NSColor.labelColor]
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                                       .foregroundColor: NSColor.secondaryLabelColor]
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                                                  .foregroundColor: NSColor.secondaryLabelColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 10
        let text = NSMutableAttributedString()
        func add(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let targetPids = Set(targets.map(\.pid))

        for (index, candidate) in candidates.prefix(5).enumerated() {
            let a = candidate.activity
            let context = contexts[a.sessionId] ?? SessionContext()
            let willPause = candidate.processes.contains { targetPids.contains($0.pid) }

            func badge(_ title: String, _ color: NSColor) {
                text.append(NSAttributedString(string: title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: size - 2),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: color,
                    .paragraphStyle: index == 0 ? NSParagraphStyle.default : paragraph,
                ]))
            }
            if index == 0 {
                badge(" MAIN OFFENDER ", .systemOrange)
                add(" ", regular)
            }
            badge(willPause ? " PAUSE " : " NOT PAUSABLE ", willPause ? .systemRed : .systemGray)
            add("  \(Format.percent(candidate.share)) · " + Format.path(a.cwd),
                [.font: NSFont.boldSystemFont(ofSize: size + 1), .foregroundColor: NSColor.labelColor])
            if let branch = context.gitBranch { add("  (\(branch))", secondary) }
            add("\n", regular)

            if let title = context.title { add("“\(title)”\n", regular) }
            if let prompt = context.lastPrompt {
                add("Last prompt: ", secondary)
                add("“\(Format.truncate(prompt, 160))”\n", regular)
            }

            if candidate.processes.isEmpty {
                add("No running claude process for this session (ended, or not a CLI session)\n", secondary)
            }
            for process in candidate.processes {
                let info = details[process.pid]
                var parts = ["pid \(process.pid)"]
                if let app = info?.hostApp { parts.append(app) }
                if process.entry.hasTerminal { parts.append(process.entry.tty) }
                if let elapsed = info?.elapsed { parts.append("running \(elapsed)") }
                add(parts.joined(separator: " · ") + "  ", secondary)
                add(Format.truncate(info?.arguments ?? "claude", 70) + "\n", mono)
            }
            if candidate.matchedByFolder, candidate.processes.count > 1 {
                add("\(candidate.processes.count) claude processes run in this folder and can't be told apart — all are paused\n",
                    [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.systemOrange])
            }

            var activity = "In this window: \(a.calls) API call\(a.calls == 1 ? "" : "s")"
            if a.sidechainCalls > 0 { activity += " (\(a.sidechainCalls) by subagents)" }
            if !a.models.isEmpty { activity += " · " + a.models.sorted().map(Format.model).joined(separator: ", ") }
            activity += " · \(Format.tokens(a.cacheReadTokens)) cache read · \(Format.tokens(a.cacheWriteTokens)) cache write"
            activity += " · \(Format.tokens(a.inputTokens + a.outputTokens)) in+out"
            if !candidate.processes.isEmpty {
                activity += String(format: " · %.0f s CPU", candidate.cpuSeconds.values.reduce(0, +))
            }
            add(activity, secondary)
            if index < min(candidates.count, 5) - 1 { add("\n", regular) }
        }
        if candidates.count > 5 { add("\n…and \(candidates.count - 5) more", secondary) }

        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 520
        label.isSelectable = true
        label.frame.size = label.fittingSize
        label.frame.size.width = max(label.frame.width, 520)
        return label
    }

    // MARK: Menu

    private func render() {
        let session = latest?.fiveHour?.utilization
        let weekly = latest?.sevenDay?.utilization

        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        func append(_ text: String, _ color: NSColor = .labelColor) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        append("✳︎ ", .systemOrange)
        append("S ", .secondaryLabelColor)
        append(Format.percent(session), Format.color(for: session))
        append("  W ", .secondaryLabelColor)
        append(Format.percent(weekly), Format.color(for: weekly))
        if !paused.isEmpty { append(" ⏸\(paused.count)", .systemRed) }
        if lastError != nil { append(" ⚠︎", .systemYellow) }
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "Claude usage — session (5h) / weekly (7d)"

        buildMenu()
    }

    private func buildMenu() {
        menu.removeAllItems()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        func choices(_ title: String, _ values: [Double], current: Double, _ selector: Selector,
                     label: (Double) -> String) {
            let submenu = NSMenu()
            for value in values {
                let item = NSMenuItem(title: label(value), action: selector, keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: value)
                item.state = value == current ? .on : .off
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: "    " + title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        func window(_ label: String, _ window: UsageWindow?) {
            guard let window else { return }
            info("\(label): \(Format.percent(window.utilization))")
            let reset = Format.resetDescription(window.resetsAt)
            if !reset.isEmpty { info("    \(reset)") }
        }

        if let usage = latest {
            window("Current session (5h)", usage.fiveHour)
            window("Weekly (7d)", usage.sevenDay)
            window("Weekly Opus", usage.sevenDayOpus)
            window("Weekly Sonnet", usage.sevenDaySonnet)
            if let extra = usage.extraUsage, extra.isEnabled,
               let used = extra.usedCredits, let limit = extra.monthlyLimit {
                menu.addItem(.separator())
                let currency = extra.currency ?? "USD"
                info(String(format: "Extra usage: %.2f / %.2f %@ (%@)",
                            used / 100, limit / 100, currency, Format.percent(extra.utilization)))
            }
        } else if lastError == nil {
            info("Loading…")
        }

        let top = topSessions
        if !top.isEmpty {
            menu.addItem(.separator())
            info("Top sessions this window (share of local tokens):")
            let total = windowTally.sessions.values.reduce(0) { $0 + $1.totalTokens }
            for session in top {
                let context = topContexts[session.sessionId]?.context
                let share = Double(session.totalTokens) / Double(max(total, 1)) * 100
                var line = "    \(Format.percent(share))  " + (session.cwd.map { ($0 as NSString).lastPathComponent } ?? "?")
                if let branch = context?.gitBranch { line += " (\(branch))" }
                if let title = context?.title { line += " — “\(Format.truncate(title, 40))”" }
                line += " · \(Format.tokens(session.totalTokens)) tokens"
                if topCleared.contains(session.sessionId) { line += " · cleared" }
                info(line)
            }
        }

        if let lastError {
            menu.addItem(.separator())
            info("⚠︎ \(lastError.localizedDescription)")
        }

        if spikeGuardEnabled, let lastSpike {
            menu.addItem(.separator())
            info(lastSpike)
        }

        if !paused.isEmpty {
            menu.addItem(.separator())
            info("Paused by spike guard:")
            for process in paused {
                let folder = process.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
                if process.wasForegroundJob {
                    info("    \(folder) — pid \(process.pid): type fg in terminal \(process.tty) to resume")
                } else {
                    let item = action("    Resume \(folder) — pid \(process.pid)", #selector(resumePaused(_:)))
                    item.representedObject = NSNumber(value: process.pid)
                }
            }
        }

        menu.addItem(.separator())
        if let lastUpdated {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            info("Updated \(formatter.string(from: lastUpdated))")
        }
        _ = action("Refresh Now", #selector(refreshNow), key: "r")
        _ = action("Open Usage Page…", #selector(openUsagePage))

        menu.addItem(.separator())
        if spikeGuardEnabled {
            let guardItem = action("Spike Guard: pause at +\(Int(Config.spikeThreshold))% of session limit in "
                                   + "\(Int(Config.spikeWindow / 60)) min", #selector(toggleSpikeGuard))
            guardItem.state = .on
            choices("Threshold: +\(Int(Config.spikeThreshold))% of limit", Config.spikeThresholdChoices,
                    current: Config.spikeThreshold, #selector(setSpikeThreshold(_:))) { "+\(Int($0))%" }
            choices("Window: \(Int(Config.spikeWindow / 60)) min", Config.spikeWindowChoices,
                    current: Config.spikeWindow, #selector(setSpikeWindow(_:))) { "\(Int($0 / 60)) min" }
            _ = action("Test Spike Alert (pauses nothing)", #selector(testSpikeAlert))
        } else {
            _ = action("Spike Guard: pause sessions when usage jumps", #selector(toggleSpikeGuard))
        }

        menu.addItem(.separator())
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func refreshNow() { refresh() }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func resumePaused(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.int32Value,
              let process = paused.first(where: { $0.pid == pid }) else { return }
        Pauser.resume(process)
        updatePaused(Processes.table())
        render()
    }

    @objc private func toggleSpikeGuard() {
        setSpikeGuard(!spikeGuardEnabled)
    }

    @objc private func setSpikeThreshold(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        Config.spikeThreshold = value
        render()
    }

    @objc private func setSpikeWindow(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        Config.spikeWindow = value
        render()
    }

    @objc private func testSpikeAlert() {
        let current = latest?.fiveHour?.utilization ?? 0
        let spike = Spike(from: current, to: current + Config.spikeThreshold,
                          since: Date().addingTimeInterval(-Config.spikeWindow))
        handleSpike(spike, processes: Processes.claudeProcesses(in: Processes.table()), test: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = error
        }
        render()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
