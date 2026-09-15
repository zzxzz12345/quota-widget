import Foundation
import SwiftUI

/// Owns the refresh loop and the last known quota for every configured provider.
@MainActor
final class QuotaService: ObservableObject {
    @Published private(set) var quotas: [ProviderQuota] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var configWarning: String?
    @Published private(set) var hasLoadedOnce = false
    /// Credentials the enabled providers read from outside `config.json`.
    @Published private(set) var externalCredentials: [AuthMigrator.Source] = []
    @Published private(set) var consolidationMessage: String?
    /// Config problems worth surfacing, e.g. two entries reading one credential.
    @Published private(set) var configNotices: [String] = []
    @Published var config: QuotaWidgetConfig

    private var refreshLoop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(config: QuotaWidgetConfig? = nil, warning: String? = nil) {
        if let config {
            self.config = config
            self.configWarning = warning
        } else {
            let loaded = ConfigStore.load()
            self.config = loaded.config
            self.configWarning = loaded.warning
        }
    }

    /// Pre-populated instance for offscreen rendering (`--preview`).
    init(config: QuotaWidgetConfig, preloaded: [ProviderQuota], lastRefresh: Date = Date()) {
        self.config = config
        self.quotas = preloaded
        self.lastRefresh = lastRefresh
        self.hasLoadedOnce = true
    }

    deinit {
        refreshLoop?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    var enabledProviders: [ProviderConfig] {
        config.resolvedProviders()
    }

    // MARK: - Lifecycle

    func start() {
        guard refreshLoop == nil else { return }

        // A config with nothing stored yet gets the keys it needs copied in, so
        // a fresh install ends up fully centralized without a manual step. A
        // config that already holds credentials is left alone — an empty slot
        // there means the user removed it on purpose.
        if config.autoConsolidatesCredentials && config.credentialCount == 0 {
            consolidateCredentials()
        } else {
            refreshCredentialNotice()
        }
        refreshLoop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                let interval = self?.config.refreshInterval ?? QuotaWidgetConfig.defaultRefreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
        // A laptop that just woke has stale numbers and possibly a stale token.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoadedOnce = true
        }

        // Re-read the config every cycle so edits to config.json take effect
        // without relaunching the app.
        let loaded = ConfigStore.load()
        config = loaded.config
        configWarning = loaded.warning
        let snapshot = loaded.config

        // Re-read credentials every cycle so a fresh CLI login — or an edit to
        // config.json — is picked up without a relaunch.
        let credentials = CredentialStore(config: snapshot)
        let http = HTTPClient()
        let results = await Self.fetchAll(config: snapshot, credentials: credentials, http: http)

        quotas = Self.ordered(results)
        lastRefresh = Date()
        refreshCredentialNotice()
    }

    /// Recomputes which credentials are still living outside the config file,
    /// and any config problem worth showing.
    func refreshCredentialNotice() {
        configNotices = config.sharedCredentialGroups().map { group in
            "\(group.joined(separator: " and ")) use the same credential, so they show the same account"
        }
        guard config.readsExternalAuthFiles else {
            externalCredentials = []
            return
        }
        externalCredentials = AuthMigrator.outstanding(for: config)
    }

    /// Copies the outstanding long-lived credentials into `config.json`.
    func consolidateCredentials() {
        var updated = config
        let result = AuthMigrator.consolidate(into: &updated, includeAll: false)
        guard !result.report.added.isEmpty else {
            consolidationMessage = nil
            refreshCredentialNotice()
            return
        }
        do {
            try ConfigStore.write(updated)
            config = updated
            let names = result.report.added.joined(separator: ", ")
            consolidationMessage = "Copied \(result.report.added.count) credential(s) into config.json: \(names)"
            refreshCredentialNotice()
        } catch {
            consolidationMessage = "Could not write config.json: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    func dismissConsolidationMessage() {
        consolidationMessage = nil
    }

    private static func fetchAll(
        config: QuotaWidgetConfig,
        credentials: CredentialStore,
        http: HTTPClient
    ) async -> [ProviderQuota] {
        // `resolvedProviders` fills in a distinguishing name for a second
        // account of the same provider, so its card is tellable apart.
        let targets = config.resolvedProviders()
        return await withTaskGroup(of: (Int, ProviderQuota).self) { group in
            for (index, providerConfig) in targets.enumerated() {
                group.addTask {
                    let context = ProviderContext(
                        credentials: credentials,
                        http: http,
                        config: providerConfig
                    )
                    let quota = await Self.fetch(providerConfig: providerConfig, context: context)
                    return (index, quota)
                }
            }
            var collected: [(Int, ProviderQuota)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func fetch(providerConfig: ProviderConfig, context: ProviderContext) async -> ProviderQuota {
        let id = providerConfig.resolvedID
        let name = providerConfig.name ?? ProviderRegistry.defaultName(for: providerConfig.type)

        guard let provider = ProviderRegistry.provider(for: providerConfig.type) else {
            return .failed(id: id, name: name, error: "Unknown provider type '\(providerConfig.type)'")
        }
        return await provider.fetch(context)
    }

    /// Configured providers rank above unconfigured ones, and within the healthy
    /// group the tightest quota floats to the top — that is what the user acts on.
    private static func ordered(_ quotas: [ProviderQuota]) -> [ProviderQuota] {
        quotas.sorted { left, right in
            let leftRank = rank(left.status)
            let rightRank = rank(right.status)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftPercent = left.worstRemainingPercent ?? 101
            let rightPercent = right.worstRemainingPercent ?? 101
            if leftPercent != rightPercent { return leftPercent < rightPercent }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private static func rank(_ status: ProviderStatus) -> Int {
        switch status {
        case .ok: return 0
        case .failed: return 1
        case .notConfigured: return 2
        }
    }

    // MARK: - Derived presentation state

    /// The plan the menu bar reports on: the one the user pinned, or the
    /// tightest across all. A pinned plan is returned even when it is failing,
    /// so the label shows its real state instead of quietly switching plans.
    var trackedQuota: ProviderQuota? {
        if let pinned = config.menuBarProvider {
            return quotas.first { $0.id == pinned }
        }
        return quotas
            .filter { $0.status.isOK && $0.worstRemainingPercent != nil }
            .min { ($0.worstRemainingPercent ?? 101) < ($1.worstRemainingPercent ?? 101) }
    }

    var counts: (ok: Int, failed: Int, unconfigured: Int) {
        var ok = 0, failed = 0, unconfigured = 0
        for quota in quotas {
            switch quota.status {
            case .ok: ok += 1
            case .failed: failed += 1
            case .notConfigured: unconfigured += 1
            }
        }
        return (ok, failed, unconfigured)
    }

    /// Adopts a config the settings panel just saved and refreshes against it.
    func applyConfig(_ newConfig: QuotaWidgetConfig) {
        config = newConfig
        configWarning = nil
        refreshCredentialNotice()
        Task { await refresh() }
    }

    func reloadConfig() {
        Task { await refresh() }
    }
}
