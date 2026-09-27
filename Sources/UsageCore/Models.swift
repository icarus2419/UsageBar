import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        }
    }

    /// Where the user can see the same numbers on the web.
    public var usagePageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .openai: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }
}

/// One rate-limit window, e.g. "5-hour" or "Weekly".
public struct UsageWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case session
        case weekly
        case other
    }

    public var kind: Kind
    public var label: String
    /// 0–100, how much of the window has been consumed.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowSeconds: Double?

    public init(kind: Kind, label: String, usedPercent: Double, resetsAt: Date?, windowSeconds: Double?) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    /// The "battery charge": what is left of this window, 0–100.
    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    /// True once the reset time has passed but we have not re-fetched yet.
    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// The window as it must look at `now`: once the reset time passes it has refilled,
    /// even if nothing has been fetched since.
    public func projected(at now: Date) -> UsageWindow {
        guard hasReset(at: now), let resetsAt else { return self }
        var window = self
        window.usedPercent = 0
        if kind == .weekly, let length = windowSeconds, length > 0 {
            // Weekly windows run on a fixed cadence, so the next reset is predictable.
            let periods = (now.timeIntervalSince(resetsAt) / length).rounded(.down) + 1
            window.resetsAt = resetsAt.addingTimeInterval(periods * length)
        } else {
            // Session windows only start again on the next request.
            window.resetsAt = nil
        }
        return window
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case api
        case localLog
    }

    public var provider: Provider
    /// Human plan name, e.g. "Pro", "Max 5x", "Plus".
    public var plan: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    /// Model-specific windows (e.g. Claude's weekly Opus limit).
    public var extras: [UsageWindow]
    public var observedAt: Date
    public var source: Source

    public init(
        provider: Provider,
        plan: String?,
        session: UsageWindow?,
        weekly: UsageWindow?,
        extras: [UsageWindow] = [],
        observedAt: Date,
        source: Source
    ) {
        self.provider = provider
        self.plan = plan
        self.session = session
        self.weekly = weekly
        self.extras = extras
        self.observedAt = observedAt
        self.source = source
    }

    public var windows: [UsageWindow] {
        [session, weekly].compactMap { $0 } + extras
    }

    public func projected(at now: Date) -> ProviderUsage {
        var usage = self
        usage.session = session?.projected(at: now)
        usage.weekly = weekly?.projected(at: now)
        usage.extras = extras.map { $0.projected(at: now) }
        return usage
    }

    /// Whichever of the session/weekly windows is closest to running out.
    /// Model-specific extras are left out because they only bite if you use that model.
    public var tightest: UsageWindow? {
        let primary = [session, weekly].compactMap { $0 }
        return (primary.isEmpty ? extras : primary).min { $0.remainingPercent < $1.remainingPercent }
    }
}

public enum UsageError: Error, Equatable, Sendable, LocalizedError {
    case notSignedIn(String)
    case tokenExpired(String)
    case unauthorized(String)
    case rateLimited(retryAfter: Double?)
    case network(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let message), .tokenExpired(let message), .unauthorized(let message):
            return message
        case .rateLimited:
            return "The usage endpoint is rate limiting requests. Retrying later."
        case .network(let message):
            return "Network error: \(message)"
        case .badResponse(let message):
            return "Unexpected response: \(message)"
        }
    }

    /// One or two words for tight spaces.
    public var shortLabel: String {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .tokenExpired: return "Login expired"
        case .unauthorized: return "Login rejected"
        case .rateLimited: return "Rate limited"
        case .network: return "Offline"
        case .badResponse: return "Bad response"
        }
    }

    /// Errors that won't fix themselves by retrying soon.
    public var needsUserAction: Bool {
        switch self {
        case .notSignedIn, .tokenExpired, .unauthorized: return true
        default: return false
        }
    }
}
