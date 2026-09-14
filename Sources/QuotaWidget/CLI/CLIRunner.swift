import Foundation

/// Headless entry points, so the widget doubles as a scriptable status command:
/// `QuotaWidget --json` feeds status bars and CI, `QuotaWidget --check` gates
/// on the warn threshold.
enum CLIRunner {
    struct Options {
        var json = false
        var check = false
        var initConfig = false
        var migrateAuth = false
        var migrateAll = false
        var authStatus = false
        var help = false
        var version = false
        var providerFilter: String?
        var previewPath: String?
        var previewSettings = false
        var previewDemo = false
        var quiet = false
    }

    static let usage = """
    quota-widget — coding plan quota in the macOS menu bar

    USAGE
      QuotaWidget [options]

    OPTIONS
      --json              Print the full report as JSON and exit
      --check             Print a text report; exit 1 if any quota is below the warn threshold
      --preview <path>    Render the dropdown panel to a PNG and exit
      --settings          With --preview, render the settings screen instead
      --demo              With --preview, use illustrative data instead of
                          fetching anything (used for the README screenshots)
      --provider <id>     Limit output to one provider id
      --quiet             With --check, print nothing and use the exit code only
      --migrate-auth      Copy credentials from the CLI auth files and the shell
                          environment into config.json, then exit. Only names the
                          configured providers read are copied.
      --all           With --migrate-auth, copy every credential found
      --auth              Show where each configured credential comes from
      --init              Write a config template to ~/.config/quota-widget/config.json
      --version           Print the version and exit
      -h, --help          Show this help

    Without arguments the menu bar app launches.
    """

    /// Returns true when the process handled the invocation and exited.
    static func runIfRequested() -> Bool {
        let options = parse(Array(CommandLine.arguments.dropFirst()))
        let wantsCLI = options.json || options.check || options.initConfig || options.migrateAuth
            || options.authStatus || options.previewPath != nil || options.help || options.version
        guard wantsCLI else { return false }

        if options.help {
            print(usage)
            exit(0)
        }
        if options.version {
            print(AppInfo.version)
            exit(0)
        }
        if options.initConfig {
            do {
                try ConfigStore.writeTemplate()
                print("Wrote \(ConfigStore.fileURL.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Could not write config: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if options.migrateAuth {
            exit(runMigration(options))
        }
        if options.authStatus {
            exit(runAuthStatus())
        }

        exit(runReport(options))
    }

    // MARK: - Credentials

    /// Pulls credentials out of the CLI auth files and the shell environment
    /// into `config.json`, which is the only source the widget needs.
    private static func runMigration(_ options: Options) -> Int32 {
        var (config, _) = ConfigStore.load()
        let result = AuthMigrator.consolidate(into: &config, includeAll: options.migrateAll)

        do {
            try ConfigStore.write(config)
        } catch {
            FileHandle.standardError.write(Data("Could not write config: \(error.localizedDescription)\n".utf8))
            return 1
        }

        print("Migrating credentials into \(ConfigStore.fileURL.path)")
        print("")
        print(AuthMigrator.describe(result.report))
        print("")
        print("File mode set to 600 — it now contains secrets.")
        if !result.oauthSkipped.isEmpty {
            print("")
            print("Left in place (OAuth access tokens rotate, so a copy would shadow the live one):")
            print("  " + result.oauthSkipped.joined(separator: ", "))
        }
        if !options.migrateAll {
            let outstanding = AuthMigrator.outstanding(for: config)
            if !outstanding.isEmpty {
                print("")
                print("Not copied (no configured provider reads them): "
                    + outstanding.map(\.name).joined(separator: ", "))
                print("Use --migrate-auth --all to copy those in as well.")
            }
        }
        return 0
    }

    /// Shows the resolved origin of each credential, never the value.
    private static func runAuthStatus() -> Int32 {
        let (config, warning) = ConfigStore.load()
        if let warning { print("warning: \(warning)") }

        let store = CredentialStore(config: config)
        let names = store.namedCredentialKeys
        print("Credentials in config.json: \(names.count)")
        for name in names {
            let hasCookie = store.namedCredentialEntry(name)?["cookie"]?.string?.isEmpty == false
            print("  \(name)\(hasCookie ? " (+cookie)" : "")")
        }
        if names.isEmpty {
            print("  (none — run --migrate-auth to copy them in)")
        }

        print("")
        print("External auth files read: \(config.readsExternalAuthFiles ? "yes" : "no")")
        if config.readsExternalAuthFiles {
            for path in CredentialStore(config: config).discoveredAuthFilePaths where path != CredentialStore.configSourceLabel {
                print("  \(path)")
            }
        }
        return 0
    }

    private static func runReport(_ options: Options) -> Int32 {
        let (config, _) = ConfigStore.load()
        var providers = config.providers.filter(\.isEnabled)
        if let filter = options.providerFilter {
            providers = providers.filter { $0.resolvedID == filter || $0.type == filter }
        }

        let demo = options.previewDemo
        let effectiveConfig = demo ? DemoData.config() : config
        let quotas = demo
            ? DemoData.quotas()
            : collectQuotas(providers: providers, credentials: CredentialStore(config: config))
        let now = Date()

        if let path = options.previewPath {
            let service = MainActor.assumeIsolated {
                let service = QuotaService(config: effectiveConfig, preloaded: quotas, lastRefresh: now)
                // The preview must show the same notices the live panel would —
                // except in demo mode, which reflects nobody's real machine.
                if !demo { service.refreshCredentialNotice() }
                return service
            }
            do {
                try MainActor.assumeIsolated {
                    try PanelRenderer.write(to: path, service: service, settings: options.previewSettings)
                }
                print("Wrote \(path)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("Could not render preview: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }

        if options.json {
            let payload = CLIReport.render(quotas: quotas, lastRefresh: now)
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                FileHandle.standardError.write(Data("Could not encode report\n".utf8))
                return 1
            }
            return 0
        }

        if !options.quiet {
            print(CLIReport.plainText(quotas: quotas, lastRefresh: now))
        }

        let warn = config.warnThreshold ?? 25
        let breached = quotas.contains { quota in
            guard let remaining = quota.worstRemainingPercent else { return false }
            return remaining < warn
        }
        return breached ? 1 : 0
    }

    /// Fetches every enabled provider concurrently, blocking until they settle so
    /// the CLI can print and exit.
    static func collectQuotas(
        providers: [ProviderConfig],
        credentials: CredentialStore? = nil
    ) -> [ProviderQuota] {
        let (config, _) = ConfigStore.load()
        let store = credentials ?? CredentialStore(config: config)
        let http = HTTPClient()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var quotas: [ProviderQuota] = []

        Task {
            quotas = await withTaskGroup(of: (Int, ProviderQuota).self) { group in
                for (index, providerConfig) in providers.enumerated() {
                    group.addTask {
                        guard let provider = ProviderRegistry.provider(for: providerConfig.type) else {
                            return (index, ProviderQuota.failed(
                                id: providerConfig.resolvedID,
                                name: providerConfig.resolvedName,
                                error: "Unknown provider type '\(providerConfig.type)'"
                            ))
                        }
                        let context = ProviderContext(credentials: store, http: http, config: providerConfig)
                        return (index, await provider.fetch(context))
                    }
                }
                var collected: [(Int, ProviderQuota)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return quotas
    }

    private static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": options.json = true
            case "--check": options.check = true
            case "--init": options.initConfig = true
            case "--migrate-auth": options.migrateAuth = true
            case "--all": options.migrateAll = true
            case "--settings": options.previewSettings = true
            case "--demo": options.previewDemo = true
            case "--auth": options.authStatus = true
            case "--version": options.version = true
            case "--quiet", "-q": options.quiet = true
            case "-h", "--help": options.help = true
            case "--provider":
                if index + 1 < arguments.count {
                    options.providerFilter = arguments[index + 1]
                    index += 1
                }
            case "--preview":
                if index + 1 < arguments.count {
                    options.previewPath = arguments[index + 1]
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return options
    }
}
