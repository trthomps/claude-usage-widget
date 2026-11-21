import AppKit
import Combine

/// Owns the current usage snapshot: polls the API, caches the last good result on disk,
/// and ticks a clock so countdowns and "stale" dimming stay current between fetches.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var plan: String?
    @Published private(set) var credentialSource: String?
    @Published private(set) var tokenExpiresAt: Date?
    @Published private(set) var now = Date()

    private let api = UsageAPI()
    private let isPreview: Bool
    private var credential: OAuthCredential?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var backoffUntil: Date?
    /// The plan name from the profile endpoint, tagged with the login it was fetched under.
    private struct CachedPlan: Codable {
        var plan: String
        var login: String
    }
    private var cachedPlan: CachedPlan?
    private var profileToken: String?
    private var profileNextAt = Date.distantPast
    private var profileTask: Task<Void, Never>?
    private static let profilePlanKey = "profilePlan"
    private var wakeObserver: NSObjectProtocol?

    init() {
        isPreview = false
        snapshot = Self.loadCache()
        cachedPlan = UserDefaults.standard.data(forKey: Self.profilePlanKey)
            .flatMap { try? JSONDecoder().decode(CachedPlan.self, from: $0) }
        plan = cachedPlan?.plan
    }

    /// A frozen store for previews and screenshots. Never touches the network.
    init(preview: UsageSnapshot?, now: Date, plan: String? = nil, error: UsageError? = nil) {
        isPreview = true
        snapshot = preview
        self.now = now
        self.plan = plan
        self.error = error
    }

    // MARK: - Derived state

    /// Limits as of `now`, with windows whose reset time has passed rolled over.
    var effectiveLimits: [UsageLimit] {
        snapshot?.limits.map { $0.effective(at: now) } ?? []
    }

    /// The last good data is too old to trust at a glance.
    var isStale: Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.fetchedAt) > max(Prefs.refreshInterval * 3, 15 * 60)
    }

    var shouldRefreshOnOpen: Bool {
        if let backoffUntil, backoffUntil > Date() { return false }
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > 45
    }

    // MARK: - Lifecycle

    func start() {
        guard !isPreview else { return }
        reschedulePolling()

        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                // Give the network a moment to come back after sleep.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Task { await self?.refresh() }
                }
            }
        }

        Task { await refresh() }
    }

    func preferencesChanged() {
        guard !isPreview, Prefs.refreshInterval != pollInterval else { return }
        reschedulePolling()
    }

    private func reschedulePolling() {
        pollTimer?.invalidate()
        pollInterval = Prefs.refreshInterval
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        timer.tolerance = pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Fetching

    func refresh(userInitiated: Bool = false) async {
        guard !isPreview, !isRefreshing else { return }
        if !userInitiated, let backoffUntil, backoffUntil > Date() { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            now = Date()
        }

        do {
            let fresh = try await fetchWithRetry()
            Debug.log("fetched \(fresh.limits.map { "\($0.id)=\($0.percent)" }.joined(separator: " "))")
            snapshot = fresh
            error = nil
            backoffUntil = nil
            saveCache(fresh)
            refreshPlanIfNeeded()
        } catch let failure as UsageError {
            Debug.log("fetch failed: \(failure)")
            error = failure
            if case .rateLimited(let retryAfter) = failure {
                backoffUntil = Date().addingTimeInterval(retryAfter ?? 5 * 60)
            }
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    private func fetchWithRetry() async throws -> UsageSnapshot {
        let current = try await loadCredential(forceReload: false)
        do {
            return try await api.fetch(token: current.accessToken)
        } catch UsageError.unauthorized {
            // Claude Code may have rotated the token since we cached it. Re-read once.
            let reloaded = try await loadCredential(forceReload: true)
            guard reloaded.accessToken != current.accessToken else { throw UsageError.unauthorized }
            return try await api.fetch(token: reloaded.accessToken)
        }
    }

    /// The plan rarely changes, so ask the profile endpoint hourly, or right away when the token
    /// changes. A failure retries in 5 minutes. Runs on its own so it never holds up a refresh.
    private func refreshPlanIfNeeded() {
        guard profileTask == nil, let credential else { return }
        if credential.accessToken == profileToken, Date() < profileNextAt { return }
        let api = self.api
        let token = credential.accessToken
        let login = credential.loginID
        profileTask = Task { [weak self] in
            let fresh = await api.fetchPlan(token: token)
            guard let self else { return }
            self.profileTask = nil
            self.profileToken = token
            self.profileNextAt = Date().addingTimeInterval(fresh == nil ? 5 * 60 : 3600)
            if let fresh {
                let entry = CachedPlan(plan: fresh, login: login)
                self.cachedPlan = entry
                UserDefaults.standard.set(try? JSONEncoder().encode(entry), forKey: Self.profilePlanKey)
            }
            self.updatePlan()
        }
    }

    /// The profile's plan name if it was fetched under the current login, otherwise the
    /// (possibly stale) one saved with the login. Switching accounts never shows the old plan.
    private func updatePlan() {
        if let cachedPlan, credential == nil || cachedPlan.login == credential?.loginID {
            plan = cachedPlan.plan
        } else {
            plan = credential?.planDescription
        }
    }

    private func loadCredential(forceReload: Bool) async throws -> OAuthCredential {
        if !forceReload, let credential, !credential.expiresSoon { return credential }

        let loaded = try await Task.detached(priority: .utility) {
            try CredentialStore.load()
        }.value

        credential = loaded
        updatePlan()
        credentialSource = loaded.source
        tokenExpiresAt = loaded.expiresAt
        if loaded.isExpired { throw UsageError.credentialsExpired }
        return loaded
    }

    // MARK: - Cache

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeUsage", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }()

    private static func loadCache() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    private func saveCache(_ snapshot: UsageSnapshot) {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
