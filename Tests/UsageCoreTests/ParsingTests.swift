import Foundation
import Testing
@testable import UsageCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let now = Date(timeIntervalSince1970: 1_790_460_000) // 2026-09-26T22:40:00Z

@Suite struct ClaudeParsing {
    @Test func namedWindows() throws {
        let usage = try ClaudeSource.parseUsage(fixture("claude-usage.json"), plan: "Pro", now: now)
        #expect(usage.provider == .claude)
        #expect(usage.plan == "Pro")
        #expect(usage.session?.remainingPercent == 21)
        #expect(usage.weekly?.remainingPercent == 56)
        #expect(usage.tightest?.kind == .session)
        #expect(usage.extras.map(\.label) == ["Weekly · Sonnet"])

        // Microsecond fractions ("…59.916404+00:00") must parse.
        let reset = try #require(usage.session?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_790_473_799.916) < 0.01)
    }

    @Test func fallsBackToLimitsList() throws {
        let usage = try ClaudeSource.parseUsage(fixture("claude-usage-limits-only.json"), plan: nil, now: now)
        #expect(usage.session?.usedPercent == 33)
        #expect(usage.weekly?.usedPercent == 61)
    }

    @Test func rejectsEmptyResponse() {
        #expect(throws: UsageError.self) {
            try ClaudeSource.parseUsage(Data(#"{"five_hour":null}"#.utf8), plan: nil, now: now)
        }
    }

    @Test func credentialsAndPlanNames() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1790467170602,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let credentials = try ClaudeSource.parseCredentials(Data(json.utf8))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.plan == "Max 20x")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_790_467_170.602))
        #expect(credentials.isExpired(at: Date(timeIntervalSince1970: 1_790_467_200)))
        #expect(!credentials.isExpired(at: now))

        #expect(ClaudeSource.planName(subscription: "pro", tier: "default_claude_ai") == "Pro")
        #expect(ClaudeSource.planName(subscription: nil, tier: nil) == nil)
        #expect(throws: UsageError.self) { try ClaudeSource.parseCredentials(Data("{}".utf8)) }
    }
}

@Suite struct CodexParsing {
    @Test func apiResponse() throws {
        let usage = try CodexSource.parseUsage(fixture("codex-usage.json"), now: now)
        #expect(usage.provider == .openai)
        #expect(usage.plan == "ChatGPT Plus")
        #expect(usage.session?.label == "5-hour")
        #expect(usage.session?.remainingPercent == 43)
        #expect(usage.weekly?.remainingPercent == 91)
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_790_468_724))
        #expect(usage.source == .api)
    }

    @Test func localLogUsesNewestSnapshot() throws {
        let lines = String(decoding: try fixture("codex-rollout.jsonl"), as: UTF8.self)
            .split(separator: "\n")
        let latest = lines.reversed().lazy.compactMap { CodexLocalLog.parseLine(Data($0.utf8)) }.first
        let usage = try #require(latest)
        #expect(usage.session?.usedPercent == 57)
        #expect(usage.weekly?.usedPercent == 9)
        #expect(usage.source == .localLog)
        #expect(usage.observedAt == ISODate.parse("2026-09-26T22:45:14.337Z"))
    }

    @Test func localLogIgnoresOtherLimitIDs() {
        let line = #"{"timestamp":"2026-09-26T22:45:14Z","payload":{"rate_limits":{"limit_id":"other","primary":{"used_percent":1,"window_minutes":300}}}}"#
        #expect(CodexLocalLog.parseLine(Data(line.utf8)) == nil)
    }

    @Test func localLogWithoutATimestampDoesNotInventAFreshReading() {
        let line = #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":1,"window_minutes":300}}}}"#
        #expect(CodexLocalLog.parseLine(Data(line.utf8)) == nil)
    }

    @Test func unicodeSplitAtTheTailBoundaryDoesNotHideUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try fixture("codex-rollout.jsonl")
        // A 512 KiB tail begins inside this four-byte character. Its partial
        // leading line must not invalidate complete usage lines later in the file.
        var content = Data("😀".utf8)
        content.append(Data(repeating: 65, count: 512 * 1024 - log.count - 2))
        content.append(10)
        content.append(log)
        try content.write(to: root.appendingPathComponent("rollout.jsonl"))
        #expect(CodexLocalLog.latestRecent(in: root)?.session?.usedPercent == 57)
    }

    @Test func newestSessionWithoutUsageDoesNotHideAnOlderSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("older.jsonl")
        let empty = root.appendingPathComponent("newer.jsonl")
        try fixture("codex-rollout.jsonl").write(to: valid)
        try Data(#"{"payload":{"type":"message"}}"#.utf8).write(to: empty)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: valid.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: empty.path)

        let usage = CodexLocalLog.latestRecent(in: root)
        #expect(usage?.session?.usedPercent == 57)
    }

    @Test func activeSessionInAnOlderDayFolderIsFound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for day in 1...4 {
            let folder = root.appendingPathComponent("2026/09/\(day)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("rollout.jsonl")
            try (day == 1 ? fixture("codex-rollout.jsonl") : Data("{}".utf8)).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(day == 1 ? 100 : -Double(day))],
                ofItemAtPath: file.path)
        }

        #expect(CodexLocalLog.latestRecent(in: root)?.session?.usedPercent == 57)
    }

    @Test func apiKeyLoginIsExplained() {
        let json = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":null}"#
        #expect(throws: UsageError.notSignedIn(CodexSource.apiKeyMessage)) {
            try CodexSource.parseCredentials(Data(json.utf8))
        }
    }

    @Test func windowsAreLabelledByLength() {
        #expect(CodexSource.makeWindow(used: 1, seconds: 18000, resetsAt: nil).kind == .session)
        #expect(CodexSource.makeWindow(used: 1, seconds: 604_800, resetsAt: nil).kind == .weekly)
        #expect(CodexSource.makeWindow(used: 1, seconds: 30 * 86400, resetsAt: nil).label == "30-day")
    }
}

@Suite struct LiveLogUpdates {
    @Test func watcherNoticesAChangedSessionLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await confirmation("local log change delivered") { confirm in
            var delivered = false
            let watcher = CodexLogWatcher(root: root) {
                if !delivered {
                    delivered = true
                    confirm()
                }
            }
            defer { watcher.stop() }
            #expect(watcher.start())
            try? fixture("codex-rollout.jsonl").write(to: root.appendingPathComponent("rollout.jsonl"))
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

@Suite struct Projection {
    @Test func sessionRefillsAfterReset() {
        let window = UsageWindow(kind: .session, label: "5-hour", usedPercent: 100,
                                 resetsAt: now.addingTimeInterval(-1), windowSeconds: 18000)
        let projected = window.projected(at: now)
        #expect(projected.remainingPercent == 100)
        #expect(projected.resetsAt == nil)
        #expect(window.projected(at: now.addingTimeInterval(-10)).remainingPercent == 0)
    }

    @Test func weeklyRollsForward() {
        let week: Double = 604_800
        let reset = now.addingTimeInterval(-week - 60)
        let window = UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 70, resetsAt: reset, windowSeconds: week)
        let projected = window.projected(at: now)
        #expect(projected.usedPercent == 0)
        #expect(projected.resetsAt == reset.addingTimeInterval(2 * week))
    }

    @Test func tightestIgnoresModelExtras() {
        let usage = ProviderUsage(
            provider: .claude, plan: nil,
            session: UsageWindow(kind: .session, label: "5-hour", usedPercent: 30, resetsAt: nil, windowSeconds: nil),
            weekly: UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 60, resetsAt: nil, windowSeconds: nil),
            extras: [UsageWindow(kind: .other, label: "Opus", usedPercent: 99, resetsAt: nil, windowSeconds: nil)],
            observedAt: now, source: .api)
        #expect(usage.tightest?.kind == .weekly)
    }

    @Test func unknownWindowLengthsStillShowAReading() {
        let limit = UsageWindow(kind: .other, label: "Limit", usedPercent: 45, resetsAt: nil, windowSeconds: nil)
        let usage = ProviderUsage(provider: .openai, plan: nil, session: nil, weekly: nil,
                                  extras: [limit], observedAt: now, source: .api)
        #expect(usage.tightest?.remainingPercent == 55)
    }

    @Test func remainingIsClamped() {
        #expect(UsageWindow(kind: .session, label: "", usedPercent: 130, resetsAt: nil, windowSeconds: nil).remainingPercent == 0)
        #expect(UsageWindow(kind: .session, label: "", usedPercent: -5, resetsAt: nil, windowSeconds: nil).remainingPercent == 100)
    }
}

@Suite struct Formatting {
    @Test func durations() {
        #expect(UsageFormat.duration(20) == "1m")
        #expect(UsageFormat.duration(45 * 60) == "45m")
        #expect(UsageFormat.duration(2 * 3600 + 13 * 60) == "2h 13m")
        #expect(UsageFormat.duration(3 * 3600) == "3h")
        #expect(UsageFormat.duration(3 * 86400 + 4 * 3600) == "3d 4h")
    }

    @Test func refillPhrases() {
        let soon = UsageWindow(kind: .session, label: "5-hour", usedPercent: 50,
                               resetsAt: now.addingTimeInterval(3600), windowSeconds: nil)
        #expect(UsageFormat.refill(soon, now: now) == "refills in 1h")
        let idle = UsageWindow(kind: .session, label: "5-hour", usedPercent: 0, resetsAt: nil, windowSeconds: nil)
        #expect(UsageFormat.refill(idle, now: now) == "full · starts on next use")
    }

    @Test func missingResetDoesNotClaimAPartlyUsedWindowIsFull() {
        let window = UsageWindow(kind: .session, label: "5-hour", usedPercent: 45,
                                 resetsAt: nil, windowSeconds: 18000)
        #expect(UsageFormat.refill(window, now: now) == nil)
    }

    @Test func dates() {
        #expect(ISODate.parse("2026-11-05T07:59:00+00:00") != nil)
        #expect(ISODate.parse("2026-09-27T01:49:59.916404+00:00") != nil)
        #expect(JSON.date(1_790_467_170_602) == Date(timeIntervalSince1970: 1_790_467_170.602))
        #expect(JSON.date(1_790_468_724) == Date(timeIntervalSince1970: 1_790_468_724))
    }
}
