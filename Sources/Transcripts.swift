import Foundation

/// Token usage one Claude Code session recorded in its transcript(s) during one poll interval.
struct SessionActivity {
    let sessionId: String
    var cwd: String?
    /// The session's main transcript (also for usage that came from its subagents).
    var transcript: URL?
    var calls = 0
    var sidechainCalls = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var models: Set<String> = []
    /// Estimate of how much these calls count towards the limit, for ranking sessions
    /// against each other: tokens weighted by what they cost relative to each other.
    var weight = 0.0

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    mutating func add(_ other: SessionActivity) {
        cwd = cwd ?? other.cwd
        transcript = transcript ?? other.transcript
        calls += other.calls
        sidechainCalls += other.sidechainCalls
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        models.formUnion(other.models)
        weight += other.weight
    }

    /// API list-price ratios: output 5× input, cache reads 0.1×, cache writes 1.25× (5 min)
    /// or 2× (1 h); Opus : Sonnet : Haiku as 5 : 3 : 1. Models that fit none count as Opus.
    static func weight(of usage: [String: Any], model: String?) -> Double {
        func tokens(_ key: String) -> Double { Double(usage[key] as? Int ?? 0) }
        let cacheWrite = tokens("cache_creation_input_tokens")
        let oneHour = min(cacheWrite, Double((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0))
        let base = tokens("input_tokens") + 5 * tokens("output_tokens") + 0.1 * tokens("cache_read_input_tokens")
            + 1.25 * (cacheWrite - oneHour) + 2 * oneHour
        let model = model ?? ""
        return base * (model.contains("haiku") ? 1 : model.contains("sonnet") ? 3 : 5)
    }
}

/// Tails Claude Code's transcripts (~/.claude/projects/**/*.jsonl), returning only
/// the usage written since the previous scan. Without `since`, history from before the
/// widget started is skipped, so the first scan only sets the starting offsets; with it,
/// the first scan also returns the usage recorded from that time on.
final class TranscriptScanner {
    private let root = Config.claudeDir.appendingPathComponent("projects")
    private var offsets: [String: UInt64] = [:]
    private var initialized = false
    private let since: Date?
    /// `since` as Claude Code writes timestamps (UTC, milliseconds), so records can be
    /// compared as strings without parsing every date.
    private let sinceTimestamp: String?

    init(since: Date? = nil) {
        self.since = since
        sinceTimestamp = since.map {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: $0)
        }
    }
    /// Claude Code writes one line per content block, each repeating the same usage;
    /// count each API response once (same rule ccusage uses).
    private var seen: Set<String> = []

    func scan() -> [SessionActivity] {
        var bySession: [String: SessionActivity] = [:]
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        )
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(values?.fileSize ?? 0)

            guard let start = offsets[path] else {
                // Files that appear after startup are read from the beginning, as are
                // files written to since `since`.
                let readAll = initialized || (since.map { (values?.contentModificationDate ?? .distantFuture) >= $0 } ?? false)
                offsets[path] = readAll ? 0 : size
                if readAll { read(url, from: 0, size: size, into: &bySession) }
                continue
            }
            if size < start { offsets[path] = 0 }  // truncated/rewritten
            if size > (offsets[path] ?? 0) { read(url, from: offsets[path] ?? 0, size: size, into: &bySession) }
        }
        initialized = true
        if seen.count > 200_000 { seen.removeAll() }
        return Array(bySession.values)
    }

    private func read(_ url: URL, from start: UInt64, size: UInt64, into bySession: inout [String: SessionActivity]) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)) else { return }
        // Only consume complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offsets[url.path] = start + UInt64(lastNewline - data.startIndex + 1)

        let sessionId = Self.sessionId(for: url)
        for line in data[data.startIndex...lastNewline].split(separator: UInt8(ascii: "\n")) {
            // Cheap pre-filter: most lines are tool results without usage.
            guard line.count > 20, line.range(of: Data("\"usage\"".utf8)) != nil,
                  let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  record["type"] as? String == "assistant",
                  sinceTimestamp.map({ (record["timestamp"] as? String ?? "") >= $0 }) ?? true,
                  let message = record["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let key = "\(message["id"] as? String ?? ""):\(record["requestId"] as? String ?? "")"
            if key != ":" {
                guard seen.insert(key).inserted else { continue }
            }

            var activity = bySession[sessionId] ?? SessionActivity(sessionId: sessionId, transcript: Self.mainTranscript(for: url))
            activity.cwd = activity.cwd ?? record["cwd"] as? String
            activity.calls += 1
            if record["isSidechain"] as? Bool == true { activity.sidechainCalls += 1 }
            activity.inputTokens += usage["input_tokens"] as? Int ?? 0
            activity.outputTokens += usage["output_tokens"] as? Int ?? 0
            activity.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
            activity.cacheWriteTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
            if let model = message["model"] as? String, model != "<synthetic>" { activity.models.insert(model) }
            activity.weight += SessionActivity.weight(of: usage, model: message["model"] as? String)
            bySession[sessionId] = activity
        }
    }

    private static func mainTranscript(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        guard parent.lastPathComponent == "subagents" else { return url }
        let sessionDir = parent.deletingLastPathComponent()
        return sessionDir.deletingLastPathComponent().appendingPathComponent(sessionDir.lastPathComponent + ".jsonl")
    }

    /// `projects/<dir>/<session>.jsonl`, or `projects/<dir>/<session>/subagents/agent-x.jsonl`
    /// for subagents — which are counted towards the session that spawned them.
    private static func sessionId(for url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            return parent.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// Token totals per session since the start of the current 5h usage window.
final class WindowTally {
    private var start: Date?
    private var scanner: TranscriptScanner?
    private(set) var sessions: [String: SessionActivity] = [:]

    /// Starting a new window drops the old totals and reads the new window from the transcripts.
    func update(windowStart: Date) {
        if windowStart != start {
            start = windowStart
            scanner = TranscriptScanner(since: windowStart)
            sessions = [:]
        }
        for activity in scanner?.scan() ?? [] {
            if sessions[activity.sessionId] == nil { sessions[activity.sessionId] = activity }
            else { sessions[activity.sessionId]?.add(activity) }
        }
    }

    func reset() {
        start = nil
        scanner = nil
        sessions = [:]
    }
}

/// Finds sessions that were ended with `/clear`. Claude Code leaves no mark in the cleared
/// transcript; the conversation continues in a new one that starts with the `/clear`
/// command, written at the moment the old one was last touched.
final class ClearedSessions {
    /// When the transcript was started by `/clear` (nil if it wasn't), by path. Never changes.
    private var clearTimes: [String: Date?] = [:]
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func isCleared(_ transcript: URL?) -> Bool {
        guard let transcript, let modified = Self.modified(transcript) else { return false }
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: transcript.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return siblings.contains { sibling in
            guard sibling.pathExtension == "jsonl", sibling != transcript,
                  // The successor was written at or after the clear.
                  (Self.modified(sibling) ?? .distantPast) >= modified.addingTimeInterval(-5),
                  let cleared = clearTime(of: sibling) else { return false }
            return abs(cleared.timeIntervalSince(modified)) < 5
        }
    }

    private func clearTime(of transcript: URL) -> Date? {
        if let known = clearTimes[transcript.path] { return known }
        var result: Date?
        if let handle = try? FileHandle(forReadingFrom: transcript) {
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 64 << 10)) ?? Data()
            for line in head.split(separator: UInt8(ascii: "\n")).prefix(10)
            where line.range(of: Data("<command-name>/clear</command-name>".utf8)) != nil {
                let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                result = (record?["timestamp"] as? String).flatMap(formatter.date)
                break
            }
        }
        clearTimes[transcript.path] = .some(result)
        return result
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// What a session is about, for telling sessions apart in the spike alert.
struct SessionContext {
    var title: String?
    var lastPrompt: String?
    var gitBranch: String?

    /// Reads the newest title / last prompt / branch from the end of the transcript.
    /// Only done when an alert is shown, so reading a few MB is fine.
    static func load(_ transcript: URL?) -> SessionContext {
        var context = SessionContext()
        guard let transcript, let handle = try? FileHandle(forReadingFrom: transcript) else { return context }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 8 << 20
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return context }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if context.title != nil, context.lastPrompt != nil, context.gitBranch != nil { break }
            guard line.count < 200_000,
                  let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            switch record["type"] as? String {
            case "ai-title": context.title = context.title ?? record["aiTitle"] as? String
            case "last-prompt": context.lastPrompt = context.lastPrompt ?? record["lastPrompt"] as? String
            default:
                if let branch = record["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    context.gitBranch = context.gitBranch ?? branch
                }
            }
        }
        return context
    }
}
