import Foundation

enum Config {
    static var pollInterval: TimeInterval { Double(env["CLAUDE_USAGE_POLL_SECONDS"] ?? "") ?? 60 }

    /// A spike is the session (5h) utilization rising by at least this many
    /// percentage points within `spikeWindow`. Both are chosen in the menu.
    static var spikeThreshold: Double {
        get { max(1, UserDefaults.standard.object(forKey: "spikeThreshold") as? Double ?? 10) }
        set { UserDefaults.standard.set(newValue, forKey: "spikeThreshold") }
    }
    static var spikeWindow: TimeInterval {
        get { max(60, UserDefaults.standard.object(forKey: "spikeWindow") as? Double ?? 5 * 60) }
        set { UserDefaults.standard.set(newValue, forKey: "spikeWindow") }
    }
    static let spikeThresholdChoices: [Double] = [5, 10, 15, 20, 30]
    static let spikeWindowChoices: [TimeInterval] = [2, 5, 10, 15, 30].map { $0 * 60 }
    /// How long the alert waits for an answer before pausing on its own.
    static let replyTimeout = 15

    private static let env = ProcessInfo.processInfo.environment

    /// Same override Claude Code itself honors.
    static let claudeDir = URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"]
        ?? NSHomeDirectory() + "/.claude")

    /// Testing only (also CLAUDE_USAGE_POLL_SECONDS above): read the usage response from this file instead of the API.
    static let snapshotFile = env["CLAUDE_USAGE_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
    static let fakeUsageFile = env["CLAUDE_USAGE_FAKE_FILE"].map { URL(fileURLWithPath: $0) }
}
