import Foundation
import Testing
@testable import QuotaWidget

/// A config with credentials embedded, plus a stubbed external auth file that
/// holds a competing value for the same name.
private func makeStore(
    credentials: [String: CredentialEntry] = [:],
    useExternalAuthFiles: Bool = true,
    externalAuthFiles: [String: String] = [:],
    environment: [String: String] = [:]
) -> CredentialStore {
    var config = QuotaWidgetConfig(
        refreshIntervalSeconds: nil,
        warnThreshold: nil,
        criticalThreshold: nil,
        showMenuBarText: nil,
        menuBarProvider: nil,
        credentials: credentials.isEmpty ? nil : credentials,
        useExternalAuthFiles: useExternalAuthFiles,
        providers: []
    )
    if !useExternalAuthFiles { config.useExternalAuthFiles = false }
    var parsed: [String: JSON] = [:]
    for (path, json) in externalAuthFiles {
        parsed[path] = try! JSON.parse(Data(json.utf8))
    }
    return CredentialStore(config: config, environment: environment, externalAuthFiles: parsed)
}

@Suite struct ConfigCredentialTests {
    /// The whole point of the change: config.json is authoritative.
    @Test func configBeatsExternalAuthFile() {
        let store = makeStore(
            credentials: ["zai-coding-plan": CredentialEntry(type: "api", key: "from-config")],
            externalAuthFiles: [
                "~/.local/share/opencode/auth.json": #"{"zai-coding-plan":{"type":"api","key":"from-file"}}"#
            ]
        )
        let found = store.authValue(keys: ["zai-coding-plan"])
        #expect(found?.value == "from-config")
        #expect(found?.source == "config.json:zai-coding-plan")
    }

    @Test func externalFilesStillUsedAsFallback() {
        let store = makeStore(externalAuthFiles: [
            "~/.local/share/opencode/auth.json": #"{"deepseek":{"type":"api","key":"from-file"}}"#
        ])
        #expect(store.authValue(keys: ["deepseek"])?.value == "from-file")
    }

    @Test func externalFilesCanBeDisabled() {
        let store = makeStore(
            useExternalAuthFiles: false,
            externalAuthFiles: [
                "~/.local/share/opencode/auth.json": #"{"deepseek":{"type":"api","key":"from-file"}}"#
            ]
        )
        #expect(store.authValue(keys: ["deepseek"]) == nil)
    }

    /// A provider can name its credential instead of relying on alias matching.
    @Test func namedCredentialReferenceWins() {
        let store = makeStore(credentials: [
            "work-zai": CredentialEntry(type: "api", key: "work-key"),
            "zai-coding-plan": CredentialEntry(type: "api", key: "default-key")
        ])
        var config = ProviderConfig(type: "zai")
        config.credential = "work-zai"
        let found = store.resolve(config: config, envNames: [])
        #expect(found?.value == "work-key")
        #expect(found?.source == "config.json:work-zai")
    }

    @Test func namedCredentialBeatsInlineApiKey() {
        let store = makeStore(credentials: ["zai": CredentialEntry(type: "api", key: "named")])
        var config = ProviderConfig(type: "zai", apiKey: "inline")
        config.credential = "zai"
        #expect(store.resolve(config: config, envNames: [])?.value == "named")
    }

    @Test func configCredentialBeatsEnvironment() {
        let store = makeStore(
            credentials: ["zai": CredentialEntry(type: "api", key: "from-config")],
            environment: ["ZAI_API_KEY": "from-env"]
        )
        #expect(store.resolve(config: ProviderConfig(type: "zai"), envNames: ["ZAI_API_KEY"])?.value == "from-config")
    }

    @Test func oauthEntryAccessTokenIsRead() {
        let store = makeStore(credentials: [
            "anthropic": CredentialEntry(type: "oauth", access: "sk-ant-oat", refresh: "r", expires: 4_102_444_800_000)
        ])
        #expect(store.authValue(keys: ["anthropic"])?.value == "sk-ant-oat")
    }

    /// Values may point at a secret manager via `${VAR}`.
    @Test func credentialValuesExpandVariables() {
        let store = makeStore(
            credentials: ["zai": CredentialEntry(type: "api", key: "${MY_ZAI}")],
            environment: ["MY_ZAI": "resolved-secret"]
        )
        #expect(store.authValue(keys: ["zai"])?.value == "resolved-secret")
    }

    @Test func cookieComesFromNamedCredential() {
        let store = makeStore(credentials: [
            "minimax-cn-coding-plan": CredentialEntry(type: "cookie", cookie: "session=abc")
        ])
        let found = store.resolveCookie(
            config: ProviderConfig(type: "minimax-cn"),
            envNames: [],
            names: ["minimax-cn-coding-plan"]
        )
        #expect(found?.value == "session=abc")
        #expect(found?.source == "config.json:minimax-cn-coding-plan.cookie")
    }

    @Test func cookieFromProviderConfigBeatsNamedCredential() {
        let store = makeStore(credentials: [
            "minimax-cn-coding-plan": CredentialEntry(type: "cookie", cookie: "session=named")
        ])
        var config = ProviderConfig(type: "minimax-cn", cookie: "session=inline")
        config.credential = "minimax-cn-coding-plan"
        let found = store.resolveCookie(config: config, envNames: [], names: ["minimax-cn-coding-plan"])
        #expect(found?.value == "session=inline")
    }

    @Test func emptyCredentialEntriesAreIgnored() {
        let store = makeStore(credentials: [
            "zai": CredentialEntry(type: "api"),
            "kimi": CredentialEntry()
        ])
        #expect(store.namedCredentialKeys.isEmpty)
        #expect(store.authValue(keys: ["zai", "kimi"]) == nil)
    }

    @Test func credentialCountIgnoresEmptyEntries() {
        var config = QuotaWidgetConfig.default
        config.credentials = [
            "a": CredentialEntry(type: "api", key: "x"),
            "b": CredentialEntry(type: "api")
        ]
        #expect(config.credentialCount == 1)
    }

    /// The on-disk schema must round-trip exactly, since it now holds secrets.
    @Test func configRoundTripsCredentials() throws {
        var config = QuotaWidgetConfig.default
        config.credentials = [
            "zai": CredentialEntry(type: "api", key: "k1"),
            "anthropic": CredentialEntry(type: "oauth", access: "a1", refresh: "r1", expires: 123, subscriptionType: "max"),
            "minimax-cn": CredentialEntry(type: "cookie", cookie: "session=xyz")
        ]
        config.useExternalAuthFiles = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(QuotaWidgetConfig.self, from: data)

        #expect(decoded.credentials?["zai"]?.key == "k1")
        #expect(decoded.credentials?["anthropic"]?.refresh == "r1")
        #expect(decoded.credentials?["anthropic"]?.subscriptionType == "max")
        #expect(decoded.credentials?["minimax-cn"]?.cookie == "session=xyz")
        #expect(decoded.readsExternalAuthFiles == false)
    }

    /// A config written before this change must still decode.
    @Test func legacyConfigWithoutCredentialsDecodes() throws {
        let legacy = #"{"refreshIntervalSeconds":300,"providers":[{"type":"zai"}]}"#
        let config = try JSONDecoder().decode(QuotaWidgetConfig.self, from: Data(legacy.utf8))
        #expect(config.credentials == nil)
        #expect(config.readsExternalAuthFiles == true)
        #expect(config.credentialCount == 0)
    }
}

@Suite struct AuthMigratorTests {
    private func json(_ text: String) -> JSON {
        try! JSON.parse(Data(text.utf8))
    }

    @Test func collectsApiKeysFromAuthFiles() {
        let sources = AuthMigrator.collect(
            authFiles: [("~/.local/share/opencode/auth.json", json("""
            {"deepseek":{"type":"api","key":"d1"},"kimi-for-coding":{"type":"api","key":"k1"}}
            """))],
            environment: [:]
        )
        #expect(sources.count == 2)
        #expect(sources.first { $0.name == "deepseek" }?.entry.key == "d1")
        let allConsumed = sources.allSatisfy(\.consumedByProvider)
        #expect(allConsumed)
    }

    @Test func keepsOAuthFieldsForRefresh() throws {
        let sources = AuthMigrator.collect(
            authFiles: [("auth.json", json("""
            {"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":999,"subscriptionType":"max"}}
            """))],
            environment: [:]
        )
        let entry = try #require(sources.first?.entry)
        #expect(entry.access == "a")
        #expect(entry.refresh == "r")
        #expect(entry.expires == 999)
        #expect(entry.subscriptionType == "max")
    }

    @Test func mapsEnvironmentVariables() {
        let sources = AuthMigrator.collect(
            authFiles: [],
            environment: ["ZAI_API_KEY": "z", "DEEPSEEK_API_KEY": "d", "UNRELATED": "x"]
        )
        #expect(sources.map(\.name).sorted() == ["deepseek", "zai"])
        #expect(sources.first { $0.name == "zai" }?.entry.key == "z")
        #expect(sources.first { $0.name == "zai" }?.origin == "env:ZAI_API_KEY")
    }

    @Test func fileEntryBeatsEnvironmentVariable() {
        let sources = AuthMigrator.collect(
            authFiles: [("auth.json", json(#"{"deepseek":{"type":"api","key":"from-file"}}"#))],
            environment: ["DEEPSEEK_API_KEY": "from-env"]
        )
        #expect(sources.count == 1)
        #expect(sources.first?.entry.key == "from-file")
    }

    /// A cookie complements an API key rather than replacing it.
    @Test func cookieEnvironmentVariableMergesIntoKeyEntry() throws {
        let sources = AuthMigrator.collect(
            authFiles: [("auth.json", json(#"{"minimax-cn-coding-plan":{"type":"api","key":"mm"}}"#))],
            environment: ["MINIMAX_CN_COOKIE": "session=abc"]
        )
        #expect(sources.count == 1)
        let entry = try #require(sources.first?.entry)
        #expect(entry.key == "mm")
        #expect(entry.cookie == "session=abc")
    }

    @Test func cookieEnvironmentVariableAlone() throws {
        let sources = AuthMigrator.collect(authFiles: [], environment: ["MINIMAX_CN_COOKIE": "session=abc"])
        let entry = try #require(sources.first?.entry)
        #expect(entry.cookie == "session=abc")
        #expect(entry.key == nil)
        #expect(sources.first?.name == "minimax-cn-coding-plan")
    }

    /// Entries no provider reads are still preserved, but flagged.
    @Test func unknownNamesArePreservedAndFlagged() {
        let sources = AuthMigrator.collect(
            authFiles: [("auth.json", json(#"{"runinfra":{"type":"api","key":"x"}}"#))],
            environment: [:]
        )
        #expect(sources.first?.consumedByProvider == false)
    }

    @Test func skipsEntriesWithoutASecret() {
        let sources = AuthMigrator.collect(
            authFiles: [("~/.codex/auth.json", json(#"{"tokens":{"access_token":"t","account_id":"a"}}"#))],
            environment: [:]
        )
        #expect(sources.isEmpty)
    }

    @Test func mergeAddsThenKeeps() {
        var config = QuotaWidgetConfig.default
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json(#"{"zai":{"type":"api","key":"file"}}"#))],
            environment: [:]
        )

        let first = AuthMigrator.merge(into: &config, sources: sources, fileLabels: ["a.json"])
        #expect(first.added == ["zai"])
        #expect(config.credentials?["zai"]?.key == "file")

        // A second run must not clobber the stored value.
        config.credentials?["zai"] = CredentialEntry(type: "api", key: "edited")
        let second = AuthMigrator.merge(into: &config, sources: sources, fileLabels: ["a.json"])
        #expect(second.kept == ["zai"])
        #expect(config.credentials?["zai"]?.key == "edited")
    }

    @Test func wiringPointsProvidersAtDiscoveredCredentials() throws {
        var config = QuotaWidgetConfig.default
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json("""
            {"kimi-for-coding":{"type":"api","key":"k"},
             "minimax-cn-coding-plan":{"type":"api","key":"m"},
             "deepseek":{"type":"api","key":"d"}}
            """))],
            environment: [:]
        )
        AuthMigrator.wireProviders(&config, sources: sources)

        let kimi = try #require(config.providers.first { $0.type == "kimi" })
        #expect(kimi.credential == "kimi-for-coding")
        let mini = try #require(config.providers.first { $0.type == "minimax-cn" })
        #expect(mini.credential == "minimax-cn-coding-plan")
        // No credential found for these, so nothing is wired.
        #expect(config.providers.first { $0.type == "zai" }?.credential == nil)
    }

    @Test func wiringDoesNotOverrideAnExplicitReference() {
        var config = QuotaWidgetConfig.default
        for index in config.providers.indices where config.providers[index].type == "kimi" {
            config.providers[index].credential = "chosen-by-hand"
        }
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json(#"{"kimi-for-coding":{"type":"api","key":"k"}}"#))],
            environment: [:]
        )
        AuthMigrator.wireProviders(&config, sources: sources)
        #expect(config.providers.first { $0.type == "kimi" }?.credential == "chosen-by-hand")
    }

    @Test func aliasesCoverEveryBuiltinType() {
        for type in ProviderRegistry.knownTypeIDs where type != "custom" {
            #expect(!AuthMigrator.aliases(for: type).isEmpty, "no aliases for \(type)")
        }
    }

    /// A trimmed config must not be repopulated with unrelated credentials.
    @Test func filterKeepsOnlyWhatConfiguredProvidersRead() {
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json("""
            {"deepseek":{"type":"api","key":"d"},
             "opencode-go":{"type":"api","key":"o"},
             "kimi-for-coding":{"type":"api","key":"k"},
             "google":{"type":"oauth","access":"g"},
             "runinfra":{"type":"api","key":"r"}}
            """))],
            environment: [:]
        )
        let providers = [
            ProviderConfig(type: "deepseek"),
            ProviderConfig(type: "opencode-go"),
            ProviderConfig(type: "commandcode")
        ]
        let (wanted, skipped) = AuthMigrator.filter(sources, for: providers, includeAll: false)

        #expect(wanted.map(\.name).sorted() == ["deepseek", "opencode-go"])
        #expect(skipped.map(\.name).sorted() == ["google", "kimi-for-coding", "runinfra"])
    }

    @Test func filterIncludeAllKeepsEverything() {
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json(#"{"google":{"type":"oauth","access":"g"}}"#))],
            environment: [:]
        )
        let (wanted, skipped) = AuthMigrator.filter(sources, for: [], includeAll: true)
        #expect(wanted.count == 1)
        #expect(skipped.isEmpty)
    }

    /// An explicit `credential` reference counts as wanted even if the name is
    /// not one of the type's usual aliases.
    @Test func filterHonoursExplicitCredentialReference() {
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json(#"{"my-team-key":{"type":"api","key":"x"}}"#))],
            environment: [:]
        )
        var provider = ProviderConfig(type: "custom", url: "https://example.com")
        provider.credential = "my-team-key"
        let (wanted, _) = AuthMigrator.filter(sources, for: [provider], includeAll: false)
        #expect(wanted.map(\.name) == ["my-team-key"])
    }

    /// Regression: `opencode` is the Zen credential, not a fallback for the Go
    /// plan. Aliasing it pulled an unrelated key into the config.
    @Test func openCodeGoDoesNotAliasTheZenCredential() {
        #expect(!ProviderRegistry.credentialAliases(for: "opencode-go").contains("opencode"))

        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json("""
            {"opencode-go":{"type":"api","key":"go"},"opencode":{"type":"api","key":"zen"}}
            """))],
            environment: [:]
        )
        let (wanted, skipped) = AuthMigrator.filter(
            sources,
            for: [ProviderConfig(type: "opencode-go")],
            includeAll: false
        )
        #expect(wanted.map(\.name) == ["opencode-go"])
        #expect(skipped.map(\.name) == ["opencode"])
    }

    @Test func descriptionNeverLeaksSecrets() {
        let sources = AuthMigrator.collect(
            authFiles: [("a.json", json(#"{"zai":{"type":"api","key":"SUPERSECRET"}}"#))],
            environment: [:]
        )
        var config = QuotaWidgetConfig.default
        let report = AuthMigrator.merge(into: &config, sources: sources, fileLabels: ["a.json"])
        let text = AuthMigrator.describe(report)
        #expect(!text.contains("SUPERSECRET"))
        #expect(text.contains("zai"))
    }
}

@Suite struct ConsolidationTests {
    private func json(_ text: String) -> JSON {
        try! JSON.parse(Data(text.utf8))
    }

    private func sources(_ text: String, origin: String = "~/.omp/agent/agent.db") -> [AuthMigrator.Source] {
        AuthMigrator.collect(authFiles: [(origin, json(text))], environment: [:])
    }

    private func config(providers: [ProviderConfig], credentials: [String: CredentialEntry]? = nil) -> QuotaWidgetConfig {
        var c = QuotaWidgetConfig.default
        c.providers = providers
        c.credentials = credentials
        return c
    }

    @Test func apiKeysAreConsolidatedForConfiguredProviders() throws {
        var c = config(providers: [ProviderConfig(type: "commandcode"), ProviderConfig(type: "deepseek")])
        let result = AuthMigrator.consolidate(
            into: &c,
            sources: sources(#"{"commandcode":{"type":"api","key":"user_k"},"deepseek":{"type":"api","key":"d"}}"#),
            fileLabels: ["agent.db"],
            includeAll: false
        )
        #expect(result.report.added.sorted() == ["commandcode", "deepseek"])
        #expect(c.credentials?["commandcode"]?.key == "user_k")
    }

    /// The core safety rule: a copied OAuth access token would shadow the token
    /// the CLI keeps refreshing.
    @Test func oauthTokensAreNeverCopied() throws {
        var c = config(providers: [ProviderConfig(type: "anthropic")])
        let result = AuthMigrator.consolidate(
            into: &c,
            sources: sources(#"{"anthropic":{"type":"oauth","access":"a","refresh":"r"}}"#),
            fileLabels: ["auth.json"],
            includeAll: false
        )
        #expect(result.report.added.isEmpty)
        #expect(c.credentials?["anthropic"] == nil)
        #expect(result.oauthSkipped == ["anthropic"])
    }

    @Test func unreadNamesAreLeftAloneUnlessIncludeAll() throws {
        let source = sources(#"{"runinfra":{"type":"api","key":"x"}}"#)
        var c = config(providers: [ProviderConfig(type: "deepseek")])

        let narrow = AuthMigrator.consolidate(into: &c, sources: source, fileLabels: [], includeAll: false)
        #expect(narrow.report.added.isEmpty)

        var wide = config(providers: [ProviderConfig(type: "deepseek")])
        let all = AuthMigrator.consolidate(into: &wide, sources: source, fileLabels: [], includeAll: true)
        #expect(all.report.added == ["runinfra"])
    }

    @Test func existingValuesAreKept() throws {
        var c = config(
            providers: [ProviderConfig(type: "commandcode")],
            credentials: ["commandcode": CredentialEntry(type: "api", key: "hand-edited")]
        )
        let result = AuthMigrator.consolidate(
            into: &c,
            sources: sources(#"{"commandcode":{"type":"api","key":"from-db"}}"#),
            fileLabels: [],
            includeAll: false
        )
        #expect(result.report.kept == ["commandcode"])
        #expect(c.credentials?["commandcode"]?.key == "hand-edited")
    }

    @Test func outstandingListsOnlyKeysNotYetStored() {
        let source = sources("""
        {"commandcode":{"type":"api","key":"k"},
         "deepseek":{"type":"api","key":"d"},
         "anthropic":{"type":"oauth","access":"a"},
         "runinfra":{"type":"api","key":"r"}}
        """)
        let c = config(
            providers: [ProviderConfig(type: "commandcode"), ProviderConfig(type: "deepseek"), ProviderConfig(type: "anthropic")],
            credentials: ["deepseek": CredentialEntry(type: "api", key: "already")]
        )
        // commandcode is missing; deepseek is stored; anthropic is OAuth;
        // runinfra is read by nobody.
        #expect(AuthMigrator.outstanding(for: c, sources: source).map(\.name) == ["commandcode"])
    }

    @Test func outstandingIsEmptyOnceEverythingIsStored() {
        let source = sources(#"{"commandcode":{"type":"api","key":"k"}}"#)
        let c = config(
            providers: [ProviderConfig(type: "commandcode")],
            credentials: ["commandcode": CredentialEntry(type: "api", key: "k")]
        )
        #expect(AuthMigrator.outstanding(for: c, sources: source).isEmpty)
    }

    /// Empty entries do not count as stored, so they still get filled in.
    @Test func blankStoredEntryCountsAsOutstanding() {
        let source = sources(#"{"commandcode":{"type":"api","key":"k"}}"#)
        let c = config(
            providers: [ProviderConfig(type: "commandcode")],
            credentials: ["commandcode": CredentialEntry(type: "api")]
        )
        #expect(AuthMigrator.outstanding(for: c, sources: source).map(\.name) == ["commandcode"])
    }

    @Test func disablingANameRemovesItFromOutstanding() {
        let source = sources(#"{"commandcode":{"type":"api","key":"k"}}"#)
        var c = config(providers: [ProviderConfig(type: "commandcode")])
        #expect(AuthMigrator.outstanding(for: c, sources: source).count == 1)
        c.providers[0].enabled = false
        #expect(AuthMigrator.outstanding(for: c, sources: source).isEmpty)
    }

    @Test func consolidationWiresTheProviderToItsCredential() throws {
        var c = config(providers: [ProviderConfig(type: "kimi")])
        AuthMigrator.consolidate(
            into: &c,
            sources: sources(#"{"kimi-for-coding":{"type":"api","key":"k"}}"#),
            fileLabels: [],
            includeAll: false
        )
        #expect(c.providers[0].credential == "kimi-for-coding")
    }

    /// First-run behaviour is driven by these two properties.
    @Test func autoConsolidationDefaultsOnAndTargetsEmptyConfigs() {
        let fresh = QuotaWidgetConfig.default
        #expect(fresh.autoConsolidatesCredentials)
        #expect(fresh.credentialCount == 0)

        var pruned = fresh
        pruned.credentials = ["deepseek": CredentialEntry(type: "api", key: "d")]
        #expect(pruned.credentialCount == 1)

        var optedOut = fresh
        optedOut.autoConsolidateCredentials = false
        #expect(!optedOut.autoConsolidatesCredentials)
    }

    /// Once folded in, a credential resolves from config.json, not the database.
    @Test func consolidatedCredentialResolvesFromConfig() throws {
        var c = config(providers: [ProviderConfig(type: "commandcode")])
        AuthMigrator.consolidate(
            into: &c,
            sources: sources(#"{"commandcode":{"type":"api","key":"user_k"}}"#),
            fileLabels: ["agent.db"],
            includeAll: false
        )
        let store = CredentialStore(
            config: c,
            environment: [:],
            externalAuthFiles: [:],
            databaseEntries: ["commandcode": CredentialEntry(type: "api", key: "user_k")]
        )
        #expect(store.authValue(keys: ["commandcode"])?.source == "config.json:commandcode")
    }
}
