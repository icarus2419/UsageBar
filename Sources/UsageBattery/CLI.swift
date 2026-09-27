import Foundation
import UsageCore

/// `UsageBattery --print | --short | --json`: one-shot output for scripts and status lines.
enum CLI {
    enum Format {
        case lines, short, json
    }

    static func format(from arguments: [String]) -> Format? {
        if arguments.contains("--json") { return .json }
        if arguments.contains("--short") { return .short }
        if arguments.contains("--print") { return .lines }
        return nil
    }

    private final class Box: @unchecked Sendable {
        var results: [(Provider, Result<ProviderUsage, UsageError>)] = []
    }

    static func run(_ format: Format) -> Int32 {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            async let claude = result { try await ClaudeSource.fetch() }
            async let openai = result {
                do {
                    return try await CodexSource.fetch()
                } catch {
                    // Same fallback the app uses: Codex's own session log.
                    if let local = CodexLocalLog.latestRecent() {
                        return local
                    }
                    throw error
                }
            }
            box.results = [(.claude, await claude), (.openai, await openai)]
            done.signal()
        }
        done.wait()

        let now = Date()
        switch format {
        case .lines:
            for (provider, result) in box.results {
                switch result {
                case .success(let usage): print(UsageFormat.summary(usage, now: now))
                case .failure(let error): print("\(provider.displayName): \(error.localizedDescription)")
                }
            }
        case .short:
            let parts = box.results.map { provider, result -> String in
                let mark = provider == .claude ? "✳" : "⬡"
                guard case .success(let usage) = result, let window = usage.projected(at: now).tightest else {
                    return "\(mark) –"
                }
                return "\(mark) \(UsageFormat.percent(window.remainingPercent))"
            }
            print(parts.joined(separator: "  "))
        case .json:
            print(json(box.results, now: now))
        }
        return box.results.contains { if case .success = $0.1 { return true } else { return false } } ? 0 : 1
    }

    private static func result(_ body: @Sendable () async throws -> ProviderUsage) async -> Result<ProviderUsage, UsageError> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error as? UsageError ?? .network(error.localizedDescription))
        }
    }

    private static func json(_ results: [(Provider, Result<ProviderUsage, UsageError>)], now: Date) -> String {
        let iso = ISO8601DateFormatter()
        var output: [String: Any] = [:]
        for (provider, result) in results {
            switch result {
            case .success(let usage):
                let projected = usage.projected(at: now)
                func encode(_ window: UsageWindow) -> [String: Any] {
                    var entry: [String: Any] = [
                        "label": window.label,
                        "usedPercent": window.usedPercent,
                        "remainingPercent": window.remainingPercent,
                    ]
                    if let resets = window.resetsAt { entry["resetsAt"] = iso.string(from: resets) }
                    return entry
                }
                var entry: [String: Any] = [
                    "observedAt": iso.string(from: usage.observedAt),
                    "source": usage.source.rawValue,
                    "windows": projected.windows.map(encode),
                ]
                entry["plan"] = usage.plan
                if let session = projected.session { entry["session"] = encode(session) }
                if let weekly = projected.weekly { entry["weekly"] = encode(weekly) }
                if let tightest = projected.tightest { entry["remainingPercent"] = tightest.remainingPercent }
                output[provider.rawValue] = entry
            case .failure(let error):
                output[provider.rawValue] = ["error": error.localizedDescription]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
