import Foundation

struct Spike {
    let from: Double
    let to: Double
    let since: Date
    var delta: Double { to - from }
}

/// A local Claude Code session that made API calls during the spike window, plus the
/// running `claude` processes that belong to it.
struct SpikeCandidate {
    let activity: SessionActivity
    /// Its part of what all local sessions used during the spike (0–100, estimated).
    let share: Double
    /// Its part of the rise, in percent of the session limit (estimated: `share` of the
    /// spike, as if all of it came from local sessions).
    let rise: Double
    /// Went over the spike threshold on its own. Only these are paused; the others are
    /// only listed.
    var isOffender: Bool { rise >= Config.spikeThreshold - 0.05 }
    let processes: [ClaudeProcess]
    /// The processes were matched by working directory only, because Claude Code's
    /// registry doesn't say which session they run.
    let matchedByFolder: Bool
    /// CPU seconds each matching process used during the window (pid → seconds).
    let cpuSeconds: [pid_t: Double]
}

/// Detects the session utilization rising by `Config.spikeThreshold` percentage points within
/// `Config.spikeWindow`, and keeps the recent local activity needed to attribute it.
///
/// Detection deliberately uses only the account-wide API utilization: that is what the
/// limit is actually counted on. Local token counts don't reliably predict how much of
/// the limit something uses, so they're only used to find who was active.
final class SpikeGuard {
    private struct Sample {
        let time: Date
        let utilization: Double
        let window: Date?
    }

    private struct Interval {
        let time: Date
        let sessions: [SessionActivity]
        let cpuSeconds: [pid_t: Double]
    }

    private var samples: [Sample] = []
    private var intervals: [Interval] = []
    private var lastCPU: [pid_t: Double] = [:]

    /// Records local activity for the poll that just happened; returns CPU seconds
    /// each Claude process used since the previous poll.
    @discardableResult
    func recordActivity(_ sessions: [SessionActivity], processes: [ClaudeProcess], at time: Date) -> [pid_t: Double] {
        var cpu: [pid_t: Double] = [:]
        for process in processes {
            if let previous = lastCPU[process.pid] { cpu[process.pid] = max(0, process.entry.cpuSeconds - previous) }
        }
        lastCPU = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.entry.cpuSeconds) })
        intervals.append(Interval(time: time, sessions: sessions, cpuSeconds: cpu))
        intervals.removeAll { time.timeIntervalSince($0.time) > Config.spikeWindow + 30 }
        return cpu
    }

    /// Adds an API sample; returns a spike if the threshold was crossed.
    func recordUtilization(_ utilization: Double, window: Date?, at time: Date) -> Spike? {
        // Samples from a previous 5h window aren't comparable — its usage was reset.
        samples.removeAll { $0.window != window || time.timeIntervalSince($0.time) > Config.spikeWindow + 5 }
        samples.append(Sample(time: time, utilization: utilization, window: window))
        guard let lowest = samples.min(by: { $0.utilization < $1.utilization }),
              utilization - lowest.utilization >= Config.spikeThreshold
        else { return nil }
        return Spike(from: lowest.utilization, to: utilization, since: lowest.time)
    }

    /// After a spike was handled (whatever the outcome), start measuring from the
    /// current level so the same rise doesn't alert again.
    func resetBaseline() {
        samples = Array(samples.suffix(1))
    }

    func candidates(for spike: Spike, processes: [ClaudeProcess]) -> [SpikeCandidate] {
        // The interval ending at `since` already belongs to the rise.
        let relevant = intervals.filter { $0.time >= spike.since.addingTimeInterval(-Config.pollInterval - 5) }
        var bySession: [String: SessionActivity] = [:]
        var cpu: [pid_t: Double] = [:]
        for interval in relevant {
            for session in interval.sessions { bySession[session.sessionId, default: session.emptyCopy].add(session) }
            cpu.merge(interval.cpuSeconds, uniquingKeysWith: +)
        }
        let active = bySession.values.filter { $0.calls > 0 }
        let total = max(active.reduce(0) { $0 + $1.weight }, 1)
        return active
            .sorted { $0.weight > $1.weight }
            .map { activity in
                let share = activity.weight / total * 100
                var matching = processes.filter { $0.sessionId == activity.sessionId }
                let matchedByFolder = matching.isEmpty
                if matchedByFolder {
                    let cwd = activity.cwd.map(Processes.normalize)
                    matching = processes.filter { $0.sessionId == nil && $0.cwd != nil && $0.cwd == cwd }
                }
                // A stopped process left behind after the session was continued in a new one.
                if matching.contains(where: { !$0.entry.isStopped }) { matching.removeAll { $0.entry.isStopped } }
                return SpikeCandidate(activity: activity, share: share,
                                      rise: share / 100 * spike.delta, processes: matching,
                                      matchedByFolder: matchedByFolder,
                                      cpuSeconds: cpu.filter { pid in matching.contains { $0.pid == pid.key } })
            }
    }
}

private extension SessionActivity {
    var emptyCopy: SessionActivity { SessionActivity(sessionId: sessionId, cwd: cwd, transcript: transcript) }
}
