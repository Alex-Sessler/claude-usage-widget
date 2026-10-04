import Foundation

struct ProcessEntry {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    /// Foreground process group of the controlling terminal (0 if none).
    let tpgid: pid_t
    let stat: String
    let cpuSeconds: Double
    let tty: String
    let command: String

    var isStopped: Bool { stat.hasPrefix("T") }
    var hasTerminal: Bool { tty != "??" && !tty.isEmpty }
    var isForegroundJob: Bool { hasTerminal && tpgid == pgid }
}

/// A running Claude Code CLI process.
struct ClaudeProcess {
    let entry: ProcessEntry
    let cwd: String?
    /// The session it is running, from Claude Code's own registry (nil if it has no entry).
    let sessionId: String?
    var pid: pid_t { entry.pid }
}

enum Processes {
    static func table() -> [ProcessEntry] {
        // `comm` last: it is the only column that can contain spaces.
        let output = run("/bin/ps", ["-axo", "pid=,ppid=,pgid=,tpgid=,stat=,time=,tty=,comm="])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8,
                  let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                  let pgid = pid_t(fields[2]), let tpgid = pid_t(fields[3])
            else { return nil }
            return ProcessEntry(pid: pid, ppid: ppid, pgid: pgid, tpgid: tpgid,
                                stat: String(fields[4]), cpuSeconds: parseCPUTime(String(fields[5])),
                                tty: String(fields[6]),
                                // ps pads columns for alignment; maxSplits leaves that padding on the last field.
                                command: fields[7].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Claude Code CLI processes. Matches the executable name exactly, so the Claude
    /// desktop app ("Claude", "Claude Helper", …) is never included.
    /// A `claude` running under another `claude` in the same folder can't be told apart
    /// from it and is left out (it's paused as part of that one's tree). One in a
    /// different folder — e.g. `claude -p` run from inside a session — is its own entry.
    static func claudeProcesses(in table: [ProcessEntry]) -> [ClaudeProcess] {
        let entries = table.filter(isClaude)
        guard !entries.isEmpty else { return [] }
        let cwds = workingDirectories(of: entries.map(\.pid))
        let sessions = sessionIds()
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func claudeAncestor(of entry: ProcessEntry) -> ProcessEntry? {
            var current = byPid[entry.ppid]
            var hops = 0
            while let parent = current, parent.pid > 1, hops < 64 {
                if isClaude(parent) { return parent }
                current = byPid[parent.ppid]
                hops += 1
            }
            return nil
        }
        return entries
            .filter { entry in
                guard let ancestor = claudeAncestor(of: entry) else { return true }
                return cwds[entry.pid] == nil || cwds[entry.pid] != cwds[ancestor.pid]
            }
            .map { ClaudeProcess(entry: $0, cwd: cwds[$0.pid], sessionId: sessions[$0.pid]) }
    }

    static func isClaude(_ entry: ProcessEntry) -> Bool {
        (entry.command as NSString).lastPathComponent == "claude"
    }

    /// Which session each Claude Code process is running (pid → session id), from the
    /// `sessions/<pid>.json` files Claude Code keeps. It follows `/clear` and `--resume`.
    static func sessionIds() -> [pid_t: String] {
        let directory = Config.claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [pid_t: String] = [:]
        for file in files where file.pathExtension == "json" {
            guard let pid = pid_t(file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = record["sessionId"] as? String else { continue }
            result[pid] = session
        }
        return result
    }

    /// Human-readable context for a process: how it was started, how long it's been
    /// running and which app it lives in (Terminal, iTerm2, VS Code, tmux, …).
    struct Details {
        let arguments: String
        let elapsed: String
        let hostApp: String?
    }

    static func details(of pid: pid_t, in table: [ProcessEntry]) -> Details {
        let output = run("/bin/ps", ["-o", "etime=,args=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var hostApp: String?
        var current = byPid[pid].flatMap { byPid[$0.ppid] }
        var hops = 0
        // The outermost app wins: that's the window you'd look for (Terminal, iTerm2,
        // VS Code), not a helper app somewhere in between.
        while let entry = current, entry.pid > 1, hops < 64 {
            let name = (entry.command as NSString).lastPathComponent
            if name == "tmux" || name == "screen" { hostApp = name }
            else if let range = entry.command.range(of: ".app/") {
                let appPath = entry.command[..<range.lowerBound]
                hostApp = (String(appPath) as NSString).lastPathComponent
            }
            current = byPid[entry.ppid]
            hops += 1
        }
        return Details(arguments: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "",
                       elapsed: parts.first.map { formatElapsed(String($0)) } ?? "?",
                       hostApp: hostApp)
    }

    /// `ps` etime is [[dd-]hh:]mm:ss
    private static func formatElapsed(_ value: String) -> String {
        var days = 0
        var rest = Substring(value)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        let hours = parts.count == 3 ? parts[0] : 0
        let minutes = parts.count >= 2 ? parts[parts.count - 2] : 0
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func descendants(of pid: pid_t, in table: [ProcessEntry]) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            let children = table.filter { $0.ppid == parent }
            result += children
            frontier += children.map(\.pid)
        }
        return result
    }

    private static func workingDirectories(of pids: [pid_t]) -> [pid_t: String] {
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.map(String.init).joined(separator: ",")])
        var result: [pid_t: String] = [:]
        var current: pid_t?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current { result[pid] = normalize(String(line.dropFirst())) }
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `ps` prints cumulative CPU time as [[dd-]hh:]mm:ss.ss
    private static func parseCPUTime(_ value: String) -> Double {
        var days = 0.0
        var rest = Substring(value)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let seconds = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86_400 + seconds
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A Claude process the widget paused, with what's needed to resume it correctly.
struct PausedProcess {
    let pid: pid_t
    let cwd: String?
    let sessionId: String?
    let tty: String
    /// Whole job (process group) signalled, or just these pids.
    let processGroup: pid_t?
    let pids: [pid_t]
    /// Paused while in the foreground of a terminal. The shell then takes the terminal
    /// back, so it must be resumed with `fg` there — SIGCONT from here would leave it
    /// running in the background, unable to read keyboard input.
    let wasForegroundJob: Bool
    let pausedAt: Date
}

enum Pauser {
    /// Stops the Claude process together with everything it started (running tool
    /// commands, builds, …). Prefers signalling the whole job, which is exactly what
    /// Ctrl-Z / `fg` act on, but only when that group contains nothing but Claude and
    /// its descendants — never the user's shell or unrelated processes.
    static func pause(_ claude: ClaudeProcess, table: [ProcessEntry]) -> PausedProcess? {
        let tree = [claude.entry] + Processes.descendants(of: claude.pid, in: table)
        let treePids = Set(tree.map(\.pid))
        let group = table.filter { $0.pgid == claude.entry.pgid }
        let groupIsOnlyClaude = group.allSatisfy { treePids.contains($0.pid) }
            && claude.entry.pgid != getpgrp() && claude.entry.pgid > 1

        let ok: Bool
        if groupIsOnlyClaude {
            ok = kill(-claude.entry.pgid, SIGSTOP) == 0
        } else {
            ok = tree.map { kill($0.pid, SIGSTOP) == 0 }.first ?? false
        }
        guard ok else { return nil }
        if claude.entry.hasTerminal { restoreTerminal(claude.entry.tty) }

        return PausedProcess(
            pid: claude.pid, cwd: claude.cwd, sessionId: claude.sessionId, tty: claude.entry.tty,
            processGroup: groupIsOnlyClaude ? claude.entry.pgid : nil,
            pids: tree.map(\.pid), wasForegroundJob: claude.entry.isForegroundJob, pausedAt: Date()
        )
    }

    /// SIGSTOP can't be caught, so Claude Code freezes without switching off the terminal
    /// modes it turned on (SIGTSTP doesn't help: it doesn't clean up on that either).
    /// The shell then gets a terminal that still reports the mouse, and every mouse
    /// move lands on its prompt as `^[[<35;99;38M`. Switch those modes off for it;
    /// Claude Code turns them back on by itself when it continues.
    private static func restoreTerminal(_ tty: String) {
        // Mouse reporting, focus events, bracketed paste, kitty keyboard, alternate screen, hidden cursor.
        let reset = ["?1000l", "?1002l", "?1003l", "?1005l", "?1006l", "?1015l", "?1004l", "?2004l", "<u", "?1049l", "?25h"]
            .map { "\u{1B}[" + $0 }.joined()
        usleep(200_000)  // let the stop land, so nothing it was still drawing follows the reset
        let device = open("/dev/" + tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard device >= 0 else { return }
        defer { close(device) }
        _ = reset.withCString { write(device, $0, strlen($0)) }
    }

    static func resume(_ paused: PausedProcess) {
        if let group = paused.processGroup {
            kill(-group, SIGCONT)
        } else {
            paused.pids.forEach { kill($0, SIGCONT) }
        }
    }
}
