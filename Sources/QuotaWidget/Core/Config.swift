import Foundation

struct WindowFieldMapping: Codable {
    var label: String?
    var used: String?
    var limit: String?
    var remaining: String?
    var remainingPercent: String?
    var usedPercent: String?
    var resetAt: String?
    var unit: String?
}

/// One stored credential. The shape deliberately mirrors the `auth.json`
/// files the CLI agents write, so migrating them in is a near-copy and the
/// existing lookup code works unchanged.
struct CredentialEntry: Codable {
    /// `api` (uses `apiKey`/`key`) or `oauth` (uses `access`).
    var type: String?
    var apiKey: String?
    var key: String?
    var access: String?
    var refresh: String?
    var expires: Double?
    var accountId: String?
    var subscriptionType: String?
    /// Full `Cookie` header value for session-gated APIs.
    var cookie: String?

    init(
        type: String? = nil,
        apiKey: String? = nil,
        key: String? = nil,
        access: String? = nil,
        refresh: String? = nil,
        expires: Double? = nil,
        accountId: String? = nil,
        subscriptionType: String? = nil,
        cookie: String? = nil
    ) {
        self.type = type
        self.apiKey = apiKey
        self.key = key
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.accountId = accountId
        self.subscriptionType = subscriptionType
        self.cookie = cookie
    }

    /// Rebuilds the `auth.json`-shaped object the providers already parse.
    /// `${VAR}` references are resolved so a config can stay out of the way of
    /// a secret manager.
    func json(environment: [String: String] = ProcessInfo.processInfo.environment) -> JSON {
        func expand(_ value: String) -> String {
            CredentialStore.expandVariables(value, environment: environment)
        }
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let apiKey { dict["apiKey"] = expand(apiKey) }
        if let key { dict["key"] = expand(key) }
        if let access { dict["access"] = expand(access) }
        if let refresh { dict["refresh"] = expand(refresh) }
        if let expires { dict["expires"] = expires }
        if let accountId { dict["accountId"] = accountId }
        if let subscriptionType { dict["subscriptionType"] = subscriptionType }
        if let cookie { dict["cookie"] = expand(cookie) }
        return JSON(dict)
    }

    /// Reads a credential out of an auth-file entry, keeping the standard keys.
    static func from(_ json: JSON) -> CredentialEntry? {
        let entry = CredentialEntry(
            type: json["type"]?.string,
            apiKey: json["apiKey"]?.string,
            key: json["key"]?.string,
            access: json["access"]?.string,
            refresh: json["refresh"]?.string,
            expires: json["expires"]?.double,
            accountId: json["accountId"]?.string,
            subscriptionType: json["subscriptionType"]?.string,
            cookie: json["cookie"]?.string
        )
        // A nested `tokens` blob (Codex CLI) has no useful quota credential.
        let hasSecret = [entry.apiKey, entry.key, entry.access, entry.cookie]
            .contains { $0?.isEmpty == false }
        return hasSecret ? entry : nil
    }

    var isEmpty: Bool {
        [apiKey, key, access, cookie].allSatisfy { $0?.isEmpty ?? true }
    }

    var secretCount: Int {
        [apiKey, key, access, cookie].filter { $0?.isEmpty == false }.count
    }
}

struct ProviderConfig: Codable {
    /// Built-in provider type (`commandcode`, `zai`, `zhipu`, `kimi`, `minimax`,
    /// `minimax-cn`, `deepseek`, `openai`, `anthropic`, `openrouter`) or `custom`.
    var type: String
    /// Stable identity; defaults to `type` for built-ins. Set it to run two
    /// accounts of the same provider side by side.
    var id: String?
    var name: String?
    var enabled: Bool?
    /// Name of an entry in the top-level `credentials` map.
    var credential: String?
    var apiKey: String?
    var apiKeyEnv: String?
    /// Full `Cookie` header value, for providers whose quota API is gated on a
    /// web session rather than an API key (MiniMax Token Plan).
    var cookie: String?
    var cookieEnv: String?
    var baseUrl: String?
    /// Override for the monthly credit allowance, when a provider reports the
    /// remaining balance but not the cap (Command Code).
    var monthlyAllowance: Double?
    var headers: [String: String]?
    var authScheme: String?

    // MARK: custom providers
    var url: String?
    /// `quota-v1` (structured windows) or `json-v1` (path-mapped response).
    var format: String?
    var planPath: String?
    var accountPath: String?
    var windowsPath: String?
    var windowFields: WindowFieldMapping?
    var metricPaths: [String: String]?
    /// Optional literal windows for plans with a fixed, known allowance.
    var staticWindows: [StaticWindow]?

    /// Registry key for this entry. `id` disambiguates two accounts of the same
    /// provider type; `ProviderConfig` normalization guarantees it is unique
    /// across the config, since everything downstream keys off it.
    var resolvedID: String { id ?? type }
    var resolvedName: String { name ?? resolvedID }
    var isEnabled: Bool { enabled ?? true }
}

struct StaticWindow: Codable {
    var label: String
    var used: Double?
    var limit: Double?
    var remainingPercent: Double?
    var unit: String?
    var resetAt: String?
}

struct QuotaWidgetConfig: Codable {
    var refreshIntervalSeconds: Double?
    var warnThreshold: Double?
    var criticalThreshold: Double?
    var showMenuBarText: Bool?
    /// The plan the menu bar tracks. When unset, the tightest provider wins.
    var menuBarProvider: String?
    /// `windows` (default) shows the tracked plan's 5h/1w/1m percentages,
    /// `labeled` adds the window names, `worst` shows a single number.
    var menuBarStyle: String?
    /// Every secret, in one place. Keyed by credential name; a provider picks
    /// one up automatically when the name matches its id or an alias, or
    /// explicitly via its `credential` field.
    var credentials: [String: CredentialEntry]?
    /// Whether to also read the auth files the CLI agents write. Off means
    /// `config.json` is the only source of credentials.
    var useExternalAuthFiles: Bool?
    /// On a config with no stored credentials, copy the ones the configured
    /// providers need out of the agent databases and auth files, so everything
    /// ends up in this file. Default true; never re-adds removed credentials.
    var autoConsolidateCredentials: Bool?
    var providers: [ProviderConfig]

    static let defaultRefreshInterval: Double = 300

    var refreshInterval: Double {
        max(30, refreshIntervalSeconds ?? Self.defaultRefreshInterval)
    }

    var readsExternalAuthFiles: Bool { useExternalAuthFiles ?? true }

    var autoConsolidatesCredentials: Bool { autoConsolidateCredentials ?? true }

    var credentialCount: Int {
        (credentials ?? [:]).values.filter { !$0.isEmpty }.count
    }

    // MARK: - Provider identity

    /// 1-based position among entries of the same provider type, so a second
    /// `zai` account is distinguishable from the first.
    func ordinal(ofIndex index: Int) -> Int {
        guard providers.indices.contains(index) else { return 1 }
        let type = providers[index].type
        return providers.prefix(index).filter { $0.type == type }.count + 1
    }

    /// Card and menu title for one entry. Falls back to the provider's own name,
    /// suffixed `(2)`, `(3)`… when the type repeats.
    func displayName(at index: Int) -> String {
        guard providers.indices.contains(index) else { return "" }
        if let name = providers[index].name, !name.isEmpty { return name }
        let base = ProviderRegistry.defaultName(for: providers[index].type)
        let position = ordinal(ofIndex: index)
        return position > 1 ? "\(base) (\(position))" : base
    }

    /// Entries handed to providers, with a distinguishing `name` filled in.
    func resolvedProviders(enabledOnly: Bool = true) -> [ProviderConfig] {
        providers.enumerated().compactMap { index, provider in
            guard !enabledOnly || provider.isEnabled else { return nil }
            guard provider.name?.isEmpty ?? true else { return provider }
            var copy = provider
            copy.name = displayName(at: index)
            return copy
        }
    }

    /// Assigns an explicit `id` wherever one is missing or would collide, so two
    /// entries can never share an identity. Returns what it changed so the panel
    /// can say so.
    func normalized() -> (config: QuotaWidgetConfig, warning: String?) {
        var copy = self
        var used: Set<String> = []
        var assigned: [String] = []

        for index in copy.providers.indices {
            let provider = copy.providers[index]
            let explicit = provider.id.flatMap { $0.isEmpty ? nil : $0 }
            let candidate = explicit ?? provider.type

            // The first entry keeps its natural id; only a genuine collision
            // gets renamed, so a config that is already unique is untouched.
            guard used.contains(candidate) else {
                used.insert(candidate)
                continue
            }

            var suffix = 2
            while used.contains("\(provider.type)-\(suffix)") { suffix += 1 }
            let fresh = "\(provider.type)-\(suffix)"
            copy.providers[index].id = fresh
            used.insert(fresh)
            assigned.append(fresh)
        }

        guard !assigned.isEmpty else { return (copy, nil) }
        return (
            copy,
            "Gave duplicate provider entries their own id (\(assigned.joined(separator: ", "))) so they can be told apart"
        )
    }

    /// Groups of enabled entries that would read the *same* credential, which
    /// means they show the same account twice.
    func sharedCredentialGroups() -> [[String]] {
        var groups: [String: [(index: Int, title: String)]] = [:]
        for (index, provider) in providers.enumerated() where provider.isEnabled {
            // An explicit `credential` is the identity; otherwise both entries
            // fall back to the same type-level alias.
            let key = provider.credential ?? "auto:\(provider.type)"
            groups[key, default: []].append((index, displayName(at: index)))
        }
        return groups.values
            .filter { $0.count > 1 }
            .map { $0.map(\.title) }
            .sorted { $0[0] < $1[0] }
    }

    /// Every built-in provider, enabled by default. Credentials are resolved at
    /// refresh time, so a provider without credentials simply reports itself as
    /// unconfigured rather than failing the whole panel.
    static var `default`: QuotaWidgetConfig {
        QuotaWidgetConfig(
            refreshIntervalSeconds: defaultRefreshInterval,
            warnThreshold: 25,
            criticalThreshold: 10,
            showMenuBarText: true,
            menuBarProvider: nil,
            providers: [
                ProviderConfig(type: "commandcode"),
                ProviderConfig(type: "opencode-go"),
                ProviderConfig(type: "ollama-cloud"),
                ProviderConfig(type: "zai"),
                ProviderConfig(type: "zhipu", enabled: false),
                ProviderConfig(type: "kimi"),
                ProviderConfig(type: "minimax"),
                ProviderConfig(type: "minimax-cn", enabled: false),
                ProviderConfig(type: "anthropic"),
                ProviderConfig(type: "openai"),
                ProviderConfig(type: "deepseek", enabled: false),
                ProviderConfig(type: "openrouter", enabled: false)
            ]
        )
    }
}

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quota-widget", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    static func load() -> (config: QuotaWidgetConfig, warning: String?) {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = QuotaWidgetConfig.default
            // Best-effort: failing to seed the file must not stop the app.
            try? write(config)
            return (config, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(QuotaWidgetConfig.self, from: data)
            if config.providers.isEmpty {
                config.providers = QuotaWidgetConfig.default.providers
            }
            // Two entries of one provider type must not share an identity.
            let normalized = config.normalized()
            let warnings = [permissionWarning(for: normalized.config), normalized.warning]
                .compactMap { $0 }
            return (normalized.config, warnings.isEmpty ? nil : warnings.joined(separator: " · "))
        } catch {
            return (QuotaWidgetConfig.default, "config.json is invalid (\(error.localizedDescription)); using defaults")
        }
    }

    /// The file holds API keys, so it should not be readable by other accounts.
    private static func permissionWarning(for config: QuotaWidgetConfig) -> String? {
        guard config.credentialCount > 0 else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        let mode = permissions.intValue
        guard mode & 0o077 != 0 else { return nil }
        return String(
            format: "config.json holds credentials but is mode %03o — run: chmod 600 %@",
            mode & 0o777, fileURL.path
        )
    }

    static func write(_ config: QuotaWidgetConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        // Secrets live here; keep them to the owner only.
        if config.credentialCount > 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    static func writeTemplate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = """
        {
          "refreshIntervalSeconds": 300,
          "warnThreshold": 25,
          "criticalThreshold": 10,
          "showMenuBarText": true,
          "credentials": {},
          "providers": [
            { "type": "commandcode" },
            { "type": "opencode-go" },
            { "type": "ollama-cloud" },
            { "type": "zai", "apiKeyEnv": "ZAI_API_KEY" },
            { "type": "zhipu", "enabled": false },
            { "type": "kimi" },
            { "type": "minimax" },
            { "type": "minimax-cn", "enabled": false },
            { "type": "anthropic" },
            { "type": "openai" },
            { "type": "deepseek", "enabled": false },
            { "type": "openrouter", "enabled": false }
          ]
        }

        """
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data(template.utf8).write(to: fileURL, options: .atomic)
        }
    }
}
