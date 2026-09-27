import Foundation

/// Claude plan limits, read with the login Claude Code already stored on this Mac.
public enum ClaudeSource {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        var plan: String?

        func isExpired(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now.addingTimeInterval(60)
        }
    }

    static let signInMessage = "Sign in to Claude Code (run `claude`) to show Claude usage."
    static let expiredMessage = "Claude login expired. Open Claude Code once to refresh it."

    // MARK: Fetch

    public static func fetch(session: URLSession = .shared) async throws -> ProviderUsage {
        var credentials = try await Task.detached(priority: .utility) { try readCredentials() }.value

        if credentials.isExpired(at: Date()) {
            credentials = try await refreshViaCLI() ?? credentials
            guard !credentials.isExpired(at: Date()) else { throw UsageError.tokenExpired(expiredMessage) }
        }

        do {
            return try await request(credentials, session: session, now: Date())
        } catch UsageError.unauthorized {
            // The token may have been revoked or rotated; give Claude Code one chance to refresh it.
            guard let fresh = try await refreshViaCLI(), fresh.accessToken != credentials.accessToken else {
                throw UsageError.tokenExpired(expiredMessage)
            }
            return try await request(fresh, session: session, now: Date())
        }
    }

    private static func request(_ credentials: Credentials, session: URLSession, now: Date) async throws -> ProviderUsage {
        let (data, response) = try await HTTP.get(endpoint, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
        ], session: session)
        try HTTP.check(response, authMessage: expiredMessage)
        return try parseUsage(data, plan: credentials.plan, now: now)
    }

    // MARK: Parsing

    public static func parseUsage(_ data: Data, plan: String?, now: Date) throws -> ProviderUsage {
        let json = try JSON.object(data)

        func window(_ key: String, _ kind: UsageWindow.Kind, _ label: String, seconds: Double?) -> UsageWindow? {
            guard let object = json[key] as? [String: Any],
                  let used = JSON.double(object["utilization"]) else { return nil }
            return UsageWindow(kind: kind, label: label, usedPercent: used,
                               resetsAt: JSON.date(object["resets_at"]), windowSeconds: seconds)
        }

        var session = window("five_hour", .session, "5-hour", seconds: 5 * 3600)
        var weekly = window("seven_day", .weekly, "Weekly", seconds: 7 * 86400)
        let extras = [
            window("seven_day_opus", .other, "Weekly · Opus", seconds: 7 * 86400),
            window("seven_day_sonnet", .other, "Weekly · Sonnet", seconds: 7 * 86400),
        ].compactMap { $0 }

        // Newer responses also carry a generic `limits` list; use it if the named keys ever disappear.
        if session == nil || weekly == nil, let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let percent = JSON.double(limit["percent"]) else { continue }
                let resets = JSON.date(limit["resets_at"])
                switch limit["group"] as? String {
                case "session" where session == nil:
                    session = UsageWindow(kind: .session, label: "5-hour", usedPercent: percent,
                                          resetsAt: resets, windowSeconds: 5 * 3600)
                case "weekly" where weekly == nil:
                    weekly = UsageWindow(kind: .weekly, label: "Weekly", usedPercent: percent,
                                         resetsAt: resets, windowSeconds: 7 * 86400)
                default:
                    break
                }
            }
        }

        guard session != nil || weekly != nil else {
            throw UsageError.badResponse("no usage windows in Claude response")
        }
        return ProviderUsage(provider: .claude, plan: plan, session: session, weekly: weekly,
                             extras: extras, observedAt: now, source: .api)
    }

    static func parseCredentials(_ data: Data) throws -> Credentials {
        let json = try JSON.object(data)
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.notSignedIn(signInMessage)
        }
        return Credentials(
            accessToken: token,
            expiresAt: JSON.date(oauth["expiresAt"]),
            plan: planName(subscription: oauth["subscriptionType"] as? String,
                           tier: oauth["rateLimitTier"] as? String)
        )
    }

    static func planName(subscription: String?, tier: String?) -> String? {
        let tier = tier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.prefix(1).uppercased() + subscription.dropFirst()
    }

    // MARK: Credentials

    /// Reads the token through `/usr/bin/security`, which Claude Code used to create the Keychain item,
    /// so macOS does not prompt. Falls back to the plaintext file some installs use.
    static func readCredentials() throws -> Credentials {
        for arguments in [["-a", NSUserName()], []] {
            let output = try? Shell.run("/usr/bin/security",
                                        ["find-generic-password", "-s", keychainService] + arguments + ["-w"],
                                        timeout: 10)
            if let output, output.status == 0, !output.stdout.isEmpty {
                return try parseCredentials(output.stdout)
            }
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return try parseCredentials(data)
        }
        throw UsageError.notSignedIn(signInMessage)
    }

    /// Asks Claude Code to refresh its own login (it rewrites the Keychain item), then re-reads it.
    /// UsageBar never uses the refresh token itself: rotating it would sign Claude Code out.
    private static func refreshViaCLI() async throws -> Credentials? {
        guard await RefreshThrottle.shared.allow() else { return nil }
        return try await Task.detached(priority: .utility) { () -> Credentials? in
            guard let claude = Shell.locate("claude") else { return nil }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Shell.toolPath
            _ = try? Shell.run(claude, ["auth", "status"], environment: environment, timeout: 30)
            return try readCredentials()
        }.value
    }
}

/// Makes sure the Claude CLI is launched at most once every 10 minutes.
actor RefreshThrottle {
    static let shared = RefreshThrottle()
    private var last: Date?

    func allow(now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < 600 { return false }
        last = now
        return true
    }
}
