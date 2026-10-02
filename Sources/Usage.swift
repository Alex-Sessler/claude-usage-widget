import AppKit

// MARK: - API model

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

enum UsageError: LocalizedError {
    case noCredentials
    case unauthorized
    case rateLimited
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude Code login found in Keychain — run `claude` and log in"
        case .unauthorized: return "Token expired — run `claude` once to refresh the login"
        case .rateLimited: return "Usage API is rate limiting — spike guard can't see usage until it recovers"
        case .http(let code): return "Usage API returned HTTP \(code)"
        }
    }
}

// MARK: - Fetching

enum UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Reads Claude Code's OAuth access token from the login Keychain.
    /// Goes through /usr/bin/security so the Keychain ACL that Claude Code already
    /// set up applies, instead of prompting for this (ad-hoc signed) binary.
    /// Re-read on every poll so tokens refreshed by Claude Code are picked up.
    static func accessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw UsageError.noCredentials }
        return token
    }

    static func fetch() async throws -> UsageResponse {
        if let fake = Config.fakeUsageFile {
            return try decode(Data(contentsOf: fake))
        }
        let token = try accessToken()
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageError.unauthorized }
        if status == 429 { throw UsageError.rateLimited }
        guard status == 200 else { throw UsageError.http(status) }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(string)"))
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))%"
    }

    /// Full path with the home folder shortened to ~
    static func path(_ path: String?) -> String {
        guard let path else { return "unknown folder" }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func truncate(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? flat.prefix(length - 1) + "…" : flat
    }

    /// claude-opus-4-8 → Opus 4.8
    static func model(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 2, parts[0] == "claude" else { return id }
        let name = parts[1].capitalized
        let version = parts.dropFirst(2).prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return "\(count / 1_000)K"
        default: return "\(count)"
        }
    }

    static func color(for value: Double?) -> NSColor {
        guard let value else { return .labelColor }
        switch value {
        case 90...: return .systemRed
        case 75..<90: return .systemOrange
        default: return .labelColor
        }
    }

    static func resetDescription(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "resetting…" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        let relative: String
        if days > 0 { relative = "\(days)d \(hours)h" }
        else if hours > 0 { relative = "\(hours)h \(minutes)m" }
        else { relative = "\(max(minutes, 1))m" }

        let absolute = DateFormatter()
        absolute.dateFormat = days > 0 ? "EEE HH:mm" : "HH:mm"
        return "resets in \(relative) (\(absolute.string(from: date)))"
    }
}
