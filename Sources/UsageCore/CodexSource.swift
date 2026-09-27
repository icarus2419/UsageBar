import Foundation

/// ChatGPT plan limits for Codex, read with the login the Codex CLI already stored.
public enum CodexSource {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static let signInMessage = "Sign in to Codex with ChatGPT (run `codex login`) to show OpenAI usage."
    static let apiKeyMessage = "Codex is signed in with an API key. Plan limits only exist for ChatGPT sign-in."
    static let expiredMessage = "OpenAI login expired. Run `codex` once to refresh it."

    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    struct Credentials {
        var accessToken: String
        var accountID: String?
    }

    // MARK: Fetch

    public static func fetch(session: URLSession = .shared) async throws -> ProviderUsage {
        let credentials = try readCredentials()
        var headers = ["Authorization": "Bearer \(credentials.accessToken)"]
        if let account = credentials.accountID {
            headers["ChatGPT-Account-Id"] = account
        }
        let (data, response) = try await HTTP.get(endpoint, headers: headers, session: session)
        try HTTP.check(response, authMessage: expiredMessage)
        return try parseUsage(data, now: Date())
    }

    // MARK: Parsing

    public static func parseUsage(_ data: Data, now: Date) throws -> ProviderUsage {
        let json = try JSON.object(data)
        guard let limits = json["rate_limit"] as? [String: Any] else {
            throw UsageError.badResponse("no rate_limit in OpenAI response")
        }

        func window(_ key: String) -> UsageWindow? {
            guard let object = limits[key] as? [String: Any],
                  let used = JSON.double(object["used_percent"]) else { return nil }
            let seconds = JSON.double(object["limit_window_seconds"])
            var resets = JSON.date(object["reset_at"])
            if resets == nil, let after = JSON.double(object["reset_after_seconds"]) {
                resets = now.addingTimeInterval(after)
            }
            return makeWindow(used: used, seconds: seconds, resetsAt: resets)
        }

        let usage = assemble(windows: [window("primary_window"), window("secondary_window")],
                             plan: planName(json["plan_type"] as? String), observedAt: now, source: .api)
        guard let usage else { throw UsageError.badResponse("no usage windows in OpenAI response") }
        return usage
    }

    /// Labels a window from its length: Codex reports "primary"/"secondary" rather than what they mean.
    static func makeWindow(used: Double, seconds: Double?, resetsAt: Date?) -> UsageWindow {
        let seconds = seconds ?? 0
        if seconds > 0, seconds <= 24 * 3600 {
            let hours = Int((seconds / 3600).rounded())
            return UsageWindow(kind: .session, label: "\(hours)-hour", usedPercent: used,
                               resetsAt: resetsAt, windowSeconds: seconds)
        }
        if seconds >= 6 * 86400, seconds <= 8 * 86400 {
            return UsageWindow(kind: .weekly, label: "Weekly", usedPercent: used,
                               resetsAt: resetsAt, windowSeconds: seconds)
        }
        return UsageWindow(kind: .other, label: seconds > 0 ? "\(Int(seconds / 86400))-day" : "Limit",
                           usedPercent: used, resetsAt: resetsAt, windowSeconds: seconds > 0 ? seconds : nil)
    }

    static func assemble(windows: [UsageWindow?], plan: String?, observedAt: Date,
                         source: ProviderUsage.Source) -> ProviderUsage? {
        let windows = windows.compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            provider: .openai,
            plan: plan,
            session: windows.first { $0.kind == .session },
            weekly: windows.first { $0.kind == .weekly },
            extras: windows.filter { $0.kind == .other },
            observedAt: observedAt,
            source: source
        )
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        case "edu": return "ChatGPT Edu"
        case "free": return "ChatGPT Free"
        default: return "ChatGPT " + raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    // MARK: Credentials

    static func readCredentials() throws -> Credentials {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else {
            throw UsageError.notSignedIn(signInMessage)
        }
        return try parseCredentials(data)
    }

    static func parseCredentials(_ data: Data) throws -> Credentials {
        let json = try JSON.object(data)
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            return Credentials(accessToken: access, accountID: tokens["account_id"] as? String)
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty {
            throw UsageError.notSignedIn(apiKeyMessage)
        }
        throw UsageError.notSignedIn(signInMessage)
    }
}

/// Codex writes a `rate_limits` snapshot into its session log after every turn. Reading it
/// needs no network, and while Codex is running it is fresher than polling.
public enum CodexLocalLog {
    public struct Stamp: Equatable, Sendable {
        var path: String
        var modified: Date
    }

    /// Keeps unchanged log tails in memory. Frequent filesystem events only cause
    /// changed files to be read, with bounded history and no periodic disk writes.
    public actor Reader {
        private let root: URL?
        private var cache: [String: (Stamp, ProviderUsage?)] = [:]

        public init(root: URL? = nil) { self.root = root }

        public func latest() -> ProviderUsage? {
            let files = recentFiles(in: root)
            var next: [String: (Stamp, ProviderUsage?)] = [:]
            for stamp in files {
                if let existing = cache[stamp.path], existing.0 == stamp {
                    next[stamp.path] = existing
                } else {
                    next[stamp.path] = (stamp, CodexLocalLog.latest(in: stamp))
                }
            }
            cache = next
            return next.values.compactMap { $0.1 }.max { $0.observedAt < $1.observedAt }
        }
    }

    /// Recent files sorted by modification time. An old session can still be active, so
    /// folder names cannot be used to decide which files to inspect.
    public static func recentFiles(in root: URL? = nil) -> [Stamp] {
        let fm = FileManager.default
        let root = root ?? CodexSource.home.appendingPathComponent("sessions")
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { return [] }
        var stamps: [Stamp] = []
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            stamps.append(Stamp(path: file.path, modified: modified))
        }
        return Array(stamps.sorted { $0.modified > $1.modified }.prefix(32))
    }

    public static func newestFile() -> Stamp? {
        recentFiles().first
    }

    /// A new rollout may not contain usage yet. Look through recent files and pick the
    /// newest actual snapshot, rather than letting that empty file hide valid data.
    public static func latestRecent(in root: URL? = nil) -> ProviderUsage? {
        latestRecent(in: recentFiles(in: root))
    }

    public static func latestRecent(in files: [Stamp]) -> ProviderUsage? {
        files.compactMap(latest(in:)).max { $0.observedAt < $1.observedAt }
    }

    /// The latest usage snapshot in `stamp`'s file, reading only its tail.
    public static func latest(in stamp: Stamp) -> ProviderUsage? {
        guard let handle = FileHandle(forReadingAtPath: stamp.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // The byte limit can cut through a UTF-8 character, and Codex may still
        // be appending the last line. Decode each complete JSON line separately.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let usage = parseLine(Data(line.utf8)) {
                return usage
            }
        }
        return nil
    }

    static func parseLine(_ data: Data) -> ProviderUsage? {
        guard let json = try? JSON.object(data) else { return nil }
        let payload = json["payload"] as? [String: Any] ?? json
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        if let id = limits["limit_id"] as? String, id != "codex" { return nil }

        func window(_ key: String) -> UsageWindow? {
            guard let object = limits[key] as? [String: Any],
                  let used = JSON.double(object["used_percent"]) else { return nil }
            let minutes = JSON.double(object["window_minutes"])
            return CodexSource.makeWindow(used: used, seconds: minutes.map { $0 * 60 },
                                          resetsAt: JSON.date(object["resets_at"]))
        }

        // An undated snapshot cannot establish freshness or beat a known reading.
        guard let observed = JSON.date(json["timestamp"]) else { return nil }
        return CodexSource.assemble(windows: [window("primary"), window("secondary")],
                                    plan: CodexSource.planName(limits["plan_type"] as? String),
                                    observedAt: observed, source: .localLog)
    }
}
