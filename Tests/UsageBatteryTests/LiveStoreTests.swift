import AppKit
import Testing
import UsageCore
@testable import UsageBattery

@Suite(.serialized) @MainActor struct LiveStoreTests {
    private func environment() -> (UserDefaults, Prefs) {
        let defaults = UserDefaults(suiteName: "UsageBattery.Tests.\(UUID().uuidString)")!
        let prefs = Prefs(defaults: defaults)
        prefs.showClaude = false
        prefs.alerts = false
        return (defaults, prefs)
    }

    private func snapshot(used: Int, at date: Date) -> Data {
        let stamp = ISO8601DateFormatter().string(from: date)
        return Data("{\"timestamp\":\"\(stamp)\",\"payload\":{\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\(used),\"window_minutes\":300}}}}\n".utf8)
    }

    @Test func appendedLogUpdatesTheDisplayedReadingWithoutAnotherNetworkCheck() async throws {
        let (defaults, prefs) = environment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let date = Date()
        try snapshot(used: 30, at: date.addingTimeInterval(-2)).write(to: file)
        let counter = Counter()
        let store = UsageStore(prefs: prefs, defaults: defaults, logRoot: root) { _, _ in
            await counter.increment()
            throw UsageError.network("Test is offline")
        }
        defer { store.stop() }
        store.start()
        for _ in 0..<40 where store.reading(for: .openai).percent != 70 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.reading(for: .openai).percent == 70)
        // Let startup requests and scans settle so only the file event can deliver
        // this update before the 15-second safety timer fires.
        try await Task.sleep(for: .milliseconds(500))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: snapshot(used: 42, at: Date()))
        try handle.close()
        for _ in 0..<80 where store.reading(for: .openai).percent != 58 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.reading(for: .openai).percent == 58)
        #expect(store.reading(for: .openai).usage?.source == .localLog)
        #expect(await counter.value == 1)
    }

    @Test func refreshesDoNotOverlapAndSleepingPausesChecks() async throws {
        let (defaults, prefs) = environment()
        let counter = Counter()
        let store = UsageStore(prefs: prefs, defaults: defaults,
                               logRoot: URL(fileURLWithPath: "/nonexistent-test-sessions")) { _, _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return ProviderUsage(provider: .openai, plan: "Test", session:
                UsageWindow(kind: .session, label: "5-hour", usedPercent: 25, resetsAt: nil, windowSeconds: 18000),
                weekly: nil, observedAt: Date(), source: .api)
        }
        defer { store.stop() }
        store.start()
        store.start()
        for _ in 0..<10 { store.refresh() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await counter.value == 1)
        #expect(store.loading.isEmpty)
        #expect(store.reading(for: .openai).percent == 75)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await counter.value == 1)
    }

    @Test func aRateLimitPreservesCachedDataAndTheServerRetryTime() async throws {
        let (defaults, prefs) = environment()
        let old = ProviderUsage(provider: .openai, plan: "Test", session:
            UsageWindow(kind: .session, label: "5-hour", usedPercent: 40, resetsAt: nil, windowSeconds: 18000),
            weekly: nil, observedAt: Date().addingTimeInterval(-1000), source: .api)
        defaults.set(try JSONEncoder().encode([old]), forKey: "usageCache.v1")
        let store = UsageStore(prefs: prefs, defaults: defaults,
                               logRoot: URL(fileURLWithPath: "/nonexistent-test-sessions")) { _, _ in
            throw UsageError.rateLimited(retryAfter: 600)
        }
        defer { store.stop() }
        store.start()
        try await Task.sleep(for: .milliseconds(100))
        let reading = store.reading(for: .openai)
        #expect(reading.percent == 60)
        #expect(reading.isStale)
        #expect(reading.usage?.observedAt == old.observedAt)
        #expect(reading.error == .rateLimited(retryAfter: 600))
        let retry = try #require(reading.nextCheckAt)
        #expect(retry.timeIntervalSinceNow > 599)
        #expect(retry.timeIntervalSinceNow <= 600)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
