import AppKit
import Combine
import UsageCore

/// Everything one battery needs to draw itself.
struct Reading {
    var provider: Provider
    /// Usage projected to "now", so windows whose reset time has passed show as refilled.
    var usage: ProviderUsage?
    /// The window picked by the user's metric.
    var window: UsageWindow?
    var error: UsageError?
    var isStale: Bool
    var isLoading: Bool
    var nextCheckAt: Date? = nil
    var isProjected = false

    var percent: Double? { window?.remainingPercent }
}

/// Polls both providers, caches the last good reading and projects resets forward in time.
@MainActor
final class UsageStore: ObservableObject {
    typealias FetchUsage = @Sendable (Provider, URLSession) async throws -> ProviderUsage
    @Published private(set) var usage: [Provider: ProviderUsage] = [:]
    @Published private(set) var errors: [Provider: UsageError] = [:]
    @Published private(set) var loading: Set<Provider> = []
    @Published private(set) var now = Date()

    private let prefs: Prefs
    private let defaults: UserDefaults
    private let fetchUsage: FetchUsage
    private let logRoot: URL?
    private let session: URLSession
    private var ticker: Timer?
    private var lastFetch: [Provider: Date] = [:]
    private var retryAt: [Provider: Date] = [:]
    private var failures: [Provider: Int] = [:]
    private let logReader: CodexLocalLog.Reader
    private lazy var logWatcher = CodexLogWatcher(root: logRoot) { [weak self] in
        MainActor.assumeIsolated { self?.pollCodexLog() }
    }
    private var readingCodexLog = false
    private var logChangePending = false
    private var sleepReasons: Set<String> = []
    private var asleep: Bool { !sleepReasons.isEmpty }
    private var tasks: [Provider: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    private static let cacheKey = "usageCache.v1"

    init(prefs: Prefs, defaults: UserDefaults = .standard, logRoot: URL? = nil,
         fetchUsage: @escaping FetchUsage = { provider, session in
             switch provider {
             case .claude: return try await ClaudeSource.fetch(session: session)
             case .openai: return try await CodexSource.fetch(session: session)
             }
         }) {
        self.prefs = prefs
        self.defaults = defaults
        self.logRoot = logRoot
        self.logReader = CodexLocalLog.Reader(root: logRoot)
        self.fetchUsage = fetchUsage
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        loadCache()
    }

    private var interval: TimeInterval { TimeInterval(max(1, prefs.refreshMinutes) * 60) }

    /// A reading older than this is drawn dimmed.
    private var staleAfter: TimeInterval { max(interval * 3, 10 * 60) }

    func start() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        let center = NSWorkspace.shared.notificationCenter
        for (sleep, wake, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display")
        ] {
            observers.append(center.addObserver(forName: sleep, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sleepReasons.insert(reason)
                    self.logWatcher.stop()
                    self.tasks.values.forEach { $0.cancel() }
                }
            })
            observers.append(center.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.sleepReasons.remove(reason) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, !self.asleep else { return }
                    self.updateWatcher()
                    self.refresh()
                }
            })
        }

        // Fetch straight away when a provider is switched on or the interval shortens.
        prefs.$showClaude.merge(with: prefs.$showOpenAI).map { _ in () }
            .merge(with: prefs.$refreshMinutes.map { _ in () })
            .dropFirst(3)
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                for provider in Provider.allCases where !self.prefs.isShown(provider) {
                    self.tasks[provider]?.cancel()
                }
                self.updateWatcher()
                self.tick()
            }
            .store(in: &cancellables)

        updateWatcher()
        tick()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        logWatcher.stop()
        tasks.values.forEach { $0.cancel() }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        cancellables.removeAll()
    }

    private func updateWatcher() {
        if prefs.showOpenAI && !asleep { logWatcher.start() } else { logWatcher.stop() }
    }

    /// Manual refresh: ignores the poll interval but still honours rate-limit back-off.
    func refresh() {
        guard !asleep else { return }
        now = Date()
        for provider in prefs.providers { fetchIfDue(provider, force: true) }
        pollCodexLog()
    }

    private func tick() {
        guard !asleep else { return }
        now = Date()
        updateWatcher()
        for provider in prefs.providers { fetchIfDue(provider, force: false) }
        pollCodexLog()
    }

    // MARK: Fetching

    private func fetchIfDue(_ provider: Provider, force: Bool) {
        guard !loading.contains(provider) else { return }
        if force, let last = lastFetch[provider], now.timeIntervalSince(last) < 20 { return }
        if let retry = retryAt[provider], retry > now {
            let rateLimited: Bool
            if case .rateLimited = errors[provider] { rateLimited = true } else { rateLimited = false }
            if !force || rateLimited { return }
        }
        if !force, retryAt[provider] == nil, let last = lastFetch[provider], now.timeIntervalSince(last) < interval {
            return
        }
        fetch(provider)
    }

    private func fetch(_ provider: Provider) {
        loading.insert(provider)
        lastFetch[provider] = Date()
        let session = session
        tasks[provider] = Task {
            defer {
                loading.remove(provider)
                tasks[provider] = nil
            }
            do {
                let result = try await fetchUsage(provider, session)
                guard !Task.isCancelled else { return }
                errors[provider] = nil
                failures[provider] = 0
                retryAt[provider] = nil
                accept(result)
            } catch {
                guard !Task.isCancelled else { return }
                fail(provider, error as? UsageError ?? .network(error.localizedDescription))
            }
        }
    }

    private func fail(_ provider: Provider, _ error: UsageError) {
        errors[provider] = error
        let count = (failures[provider] ?? 0) + 1
        failures[provider] = count
        switch error {
        case .rateLimited(let retryAfter):
            let backoff = min(interval * pow(2, Double(count)), 30 * 60)
            retryAt[provider] = Date().addingTimeInterval(max(retryAfter ?? 0, backoff))
        case .network, .badResponse:
            // Retry sooner than a full interval the first time, then back off.
            let backoff = min(30 * pow(2, Double(count - 1)), max(interval, 15 * 60))
            retryAt[provider] = Date().addingTimeInterval(backoff)
        case .notSignedIn, .tokenExpired, .unauthorized:
            // Rechecking the local login is cheap; keep the normal cadence so sign-ins show up quickly.
            retryAt[provider] = nil
        }
        if provider == .openai { pollCodexLog() }
    }

    /// Keeps whichever reading is newer, so a fresh local-log snapshot can beat an older API one.
    private func accept(_ new: ProviderUsage) {
        if let old = usage[new.provider], old.observedAt > new.observedAt { return }
        var updated = new
        if updated.plan == nil { updated.plan = usage[new.provider]?.plan }
        guard updated != usage[new.provider] else { return }
        now = Date()
        usage[new.provider] = updated
        saveCache()
    }

    /// File events deliver live updates; the timer is a fallback if events are missed.
    private func pollCodexLog() {
        guard prefs.showOpenAI, !asleep else { return }
        guard !readingCodexLog else {
            logChangePending = true
            return
        }
        readingCodexLog = true
        Task {
            let usage = await logReader.latest()
            readingCodexLog = false
            if prefs.showOpenAI, !asleep, let usage { accept(usage) }
            if logChangePending {
                logChangePending = false
                pollCodexLog()
            }
        }
    }

    // MARK: Reading

    func reading(for provider: Provider) -> Reading {
        let projected = usage[provider]?.projected(at: now)
        let window: UsageWindow?
        switch prefs.metric {
        case .lowest: window = projected?.tightest
        case .session: window = projected?.session ?? projected?.tightest
        case .weekly: window = projected?.weekly ?? projected?.tightest
        }
        let stale = projected.map { now.timeIntervalSince($0.observedAt) > staleAfter } ?? false
        return Reading(provider: provider, usage: projected, window: window, error: errors[provider],
                       isStale: stale, isLoading: loading.contains(provider),
                       nextCheckAt: retryAt[provider] ?? lastFetch[provider]?.addingTimeInterval(interval),
                       isProjected: usage[provider]?.windows.contains { $0.hasReset(at: now) } ?? false)
    }

    var lastUpdated: Date? {
        prefs.providers.compactMap { usage[$0]?.observedAt }.max()
    }

    // MARK: Cache

    private func loadCache() {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([ProviderUsage].self, from: data) else { return }
        for entry in cached { usage[entry.provider] = entry }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(Array(usage.values)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }
}
