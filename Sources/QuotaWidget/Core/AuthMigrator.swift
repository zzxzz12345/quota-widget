import Foundation

/// Collects credentials that currently live elsewhere — the auth files the CLI
/// agents write, and environment variables visible to the calling shell — so
/// they can be stored in `~/.config/quota-widget/config.json` instead.
///
/// This matters beyond tidiness: a menu bar app launched from Finder does not
/// inherit the shell environment, so a key exported in `.zshrc` never reaches
/// the widget. Moving it into the config file makes it work everywhere.
enum AuthMigrator {
    /// Maps a well-known environment variable onto the credential name a
    /// provider will look up.
    static let environmentVariables: [(variable: String, credential: String)] = [
        ("COMMAND_CODE_API_KEY", "commandcode"),
        ("COMMANDCODE_API_KEY", "commandcode"),
        ("ZAI_API_KEY", "zai"),
        ("ZAI_CODING_PLAN_API_KEY", "zai"),
        ("ZHIPU_API_KEY", "zhipu"),
        ("GLM_API_KEY", "zai"),
        ("KIMI_API_KEY", "kimi-for-coding"),
        ("MOONSHOT_API_KEY", "kimi-for-coding"),
        ("MINIMAX_API_KEY", "minimax-coding-plan"),
        ("MINIMAX_CN_API_KEY", "minimax-cn-coding-plan"),
        ("DEEPSEEK_API_KEY", "deepseek"),
        ("OPENROUTER_API_KEY", "openrouter"),
        ("OPENCODE_API_KEY", "opencode-go"),
        ("OLLAMA_API_KEY", "ollama-cloud"),
        ("MINIMAX_COOKIE", "minimax-coding-plan"),
        ("MINIMAX_CN_COOKIE", "minimax-cn-coding-plan")
    ]

    /// Credential names that some provider in the registry actually reads.
    static let providerNames: Set<String> = [
        "commandcode", "command-code",
        "zai", "zai-coding-plan", "glm",
        "zhipu", "zhipu-coding-plan", "bigmodel",
        "kimi", "kimi-for-coding", "kimi-coding-plan", "moonshot", "kimi-for-coding-oauth",
        "minimax", "minimax-coding-plan", "minimax-token-plan",
        "minimax-cn", "minimax-cn-coding-plan", "minimax-china", "minimax-china-coding-plan",
        "deepseek",
        "openrouter",
        "opencode-go",
        "ollama-cloud", "ollama",
        "openai", "codex", "chatgpt",
        "anthropic", "claude"
    ]

    struct Source {
        var name: String
        var origin: String
        var entry: CredentialEntry
        /// False when the name is not one any provider looks up.
        var consumedByProvider: Bool
    }

    struct Report {
        var sources: [Source] = []
        var added: [String] = []
        /// Names already present in `config.json`; existing values are kept.
        var kept: [String] = []
        var filesRead: [String] = []

        var unused: [String] { sources.filter { !$0.consumedByProvider }.map(\.name) }
    }

    /// Scans `authFiles` (path → parsed JSON) and `environment` for credentials.
    /// Pure, so the mapping rules are testable without touching the disk.
    static func collect(
        authFiles: [(path: String, json: JSON)],
        environment: [String: String]
    ) -> [Source] {
        var found: [String: Source] = [:]

        // Auth files first: they carry refresh tokens and cookies that an env
        // var cannot express.
        for file in authFiles {
            guard let entries = file.json.object else { continue }
            for (name, value) in entries {
                guard let entry = CredentialEntry.from(value) else { continue }
                // First source wins, matching how the credential store resolves.
                guard found[name] == nil else { continue }
                found[name] = Source(
                    name: name,
                    origin: file.path,
                    entry: entry,
                    consumedByProvider: providerNames.contains(name)
                )
            }
        }

        for (variable, credential) in environmentVariables {
            let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { continue }
            let isCookie = variable.hasSuffix("_COOKIE")

            if let existing = found[credential] {
                // A cookie complements a key rather than replacing it, and a
                // file entry is richer than an env var, so only fill gaps.
                if isCookie, existing.entry.cookie == nil {
                    var entry = existing.entry
                    entry.cookie = value
                    found[credential] = Source(
                        name: existing.name,
                        origin: "\(existing.origin) + env:\(variable)",
                        entry: entry,
                        consumedByProvider: existing.consumedByProvider
                    )
                }
                continue
            }

            found[credential] = Source(
                name: credential,
                origin: "env:\(variable)",
                entry: isCookie
                    ? CredentialEntry(type: "cookie", cookie: value)
                    : CredentialEntry(type: "api", key: value),
                consumedByProvider: providerNames.contains(credential)
            )
        }

        return found.values.sorted { $0.name < $1.name }
    }

    /// Reads the on-disk auth files and agent databases the widget knows about.
    static func discoverAuthFiles(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (files: [(path: String, json: JSON)], shortcuts: [String: String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.commandcode/auth.json",
            "\(home)/.pi/agent/auth.json",
            "\(home)/.omp/agent/auth.json",
            "\(home)/.local/share/opencode/auth.json",
            "\(home)/.config/opencode/auth.json",
            "\(home)/.codex/auth.json",
            "\(home)/.claude/.credentials.json"
        ]

        var files: [(path: String, json: JSON)] = []
        var shortcuts: [String: String] = [:]

        // SQLite-backed logins first: they are the freshest source for agents
        // that migrated off JSON.
        let databases = SQLiteCredentialSource.credentials()
        if !databases.entries.isEmpty {
            let merged = databases.entries.mapValues { $0.json(environment: environment).raw }
            files.append(("\(databases.files.joined(separator: ", ")) (sqlite)", JSON(merged)))
        }

        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSON.parse(data) else { continue }
            files.append((path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path, json))

            // Some files nest the interesting blob one level down.
            if let oauth = json.path("claudeAiOauth"), oauth.exists {
                shortcuts["claude"] = path
                files.append(("claude", JSON(["claudeAiOauth": oauth.raw])))
            }
        }
        return (files, shortcuts)
    }

    /// Narrows discovered credentials to the ones the configured providers will
    /// actually read, so a pruned config is not repopulated with unrelated keys.
    static func filter(
        _ sources: [Source],
        for providers: [ProviderConfig],
        includeAll: Bool
    ) -> (wanted: [Source], skipped: [Source]) {
        guard !includeAll else { return (sources, []) }

        // Only enabled providers: copying a secret in for a plan the user has
        // switched off is both unwanted and would undo their pruning.
        var wanted: Set<String> = []
        for provider in providers where provider.isEnabled {
            if let explicit = provider.credential { wanted.insert(explicit) }
            wanted.insert(provider.resolvedID)
            wanted.formUnion(ProviderRegistry.credentialAliases(for: provider.type))
        }
        return (
            sources.filter { wanted.contains($0.name) },
            sources.filter { !wanted.contains($0.name) }
        )
    }

    /// OAuth access tokens rotate every few hours. Copying one into the config
    /// would freeze it and shadow the fresh token the CLI keeps writing, so
    /// only long-lived keys are consolidated.
    static func split(_ sources: [Source]) -> (keys: [Source], oauth: [Source]) {
        var keys: [Source] = []
        var oauth: [Source] = []
        for source in sources {
            if source.entry.type?.lowercased() == "oauth" {
                oauth.append(source)
            } else {
                keys.append(source)
            }
        }
        return (keys, oauth)
    }

    struct Consolidation {
        var report: Report
        var oauthSkipped: [String] = []
        var filesRead: [String] = []
    }

    /// Everything discoverable on this machine, already flattened to sources.
    static func discoverSources(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (files: [String], sources: [Source]) {
        let discovered = discoverAuthFiles(environment: environment)
        var files = discovered.files

        // `.claude/.credentials.json` nests its secret; present it flat.
        if let claudePath = discovered.shortcuts["claude"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: claudePath)),
           let raw = try? JSON.parse(data), let oauth = raw.path("claudeAiOauth") {
            files.append(("claude (from ~/.claude/.credentials.json)", JSON(["anthropic": JSON([
                "type": "oauth",
                "access": oauth["accessToken"]?.raw ?? "",
                "refresh": oauth["refreshToken"]?.raw ?? "",
                "expires": oauth["expiresAt"]?.raw ?? 0,
                "subscriptionType": oauth["subscriptionType"]?.raw ?? ""
            ]).raw])))
        }

        return (files.map(\.path), collect(authFiles: files, environment: environment))
    }

    /// Discovers what is on this machine and merges the long-lived credentials
    /// the configured providers need into `config`.
    @discardableResult
    static func consolidate(
        into config: inout QuotaWidgetConfig,
        includeAll: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Consolidation {
        let discovered = discoverSources(environment: environment)
        return consolidate(
            into: &config,
            sources: discovered.sources,
            fileLabels: discovered.files,
            includeAll: includeAll
        )
    }

    /// The rule set, with no file access, so it can be tested directly.
    static func consolidate(
        into config: inout QuotaWidgetConfig,
        sources: [Source],
        fileLabels: [String],
        includeAll: Bool
    ) -> Consolidation {
        let (wanted, _) = filter(sources, for: config.providers, includeAll: includeAll)
        let (keys, oauth) = split(wanted)
        let report = merge(into: &config, sources: keys, fileLabels: fileLabels)
        wireProviders(&config, sources: sources)
        return Consolidation(
            report: report,
            oauthSkipped: oauth.map(\.name),
            filesRead: fileLabels
        )
    }

    /// Wanted, long-lived credentials still only available outside `config.json`.
    static func outstanding(
        for config: QuotaWidgetConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Source] {
        outstanding(for: config, sources: discoverSources(environment: environment).sources)
    }

    static func outstanding(for config: QuotaWidgetConfig, sources: [Source]) -> [Source] {
        let (wanted, _) = filter(sources, for: config.providers, includeAll: false)
        let (keys, _) = split(wanted)
        let stored = Set((config.credentials ?? [:]).filter { !$0.value.isEmpty }.keys)
        return keys.filter { !stored.contains($0.name) }
    }

    /// Merges discovered credentials into `config`, returning a report.
    /// Existing entries win, so re-running never clobbers an edit.
    static func merge(
        into config: inout QuotaWidgetConfig,
        sources: [Source],
        fileLabels: [String]
    ) -> Report {
        var report = Report()
        report.sources = sources
        report.filesRead = fileLabels

        var credentials = config.credentials ?? [:]
        for source in sources {
            if let existing = credentials[source.name], !existing.isEmpty {
                report.kept.append(source.name)
                continue
            }
            credentials[source.name] = source.entry
            report.added.append(source.name)
        }
        config.credentials = credentials.isEmpty ? nil : credentials
        return report
    }

    /// Points each enabled provider at the credential discovered for it, so the
    /// lookup does not depend on alias guessing.
    static func wireProviders(_ config: inout QuotaWidgetConfig, sources: [Source]) {
        let available = Set(sources.map(\.name))
        for index in config.providers.indices {
            guard config.providers[index].credential == nil else { continue }
            let type = config.providers[index].type
            // With two entries of one type, a type-level alias cannot say which
            // account belongs to which, so leave both for the user to point.
            let sameType = config.providers.filter { $0.type == type }.count
            guard sameType == 1 else { continue }
            let candidates = [type] + aliases(for: type)
            if let match = candidates.first(where: { available.contains($0) }) {
                config.providers[index].credential = match
            }
        }
    }

    /// Credential names a provider type will consume, most specific first.
    static func aliases(for type: String) -> [String] {
        ProviderRegistry.credentialAliases(for: type)
    }

    /// Human-readable summary. Never prints secret material.
    static func describe(_ report: Report) -> String {
        var lines: [String] = []
        if !report.filesRead.isEmpty {
            lines.append("Scanned: " + report.filesRead.joined(separator: ", "))
        }
        if report.sources.isEmpty {
            lines.append("No credentials found to migrate.")
            return lines.joined(separator: "\n")
        }
        for source in report.sources {
            let status = report.added.contains(source.name) ? "added"
                : report.kept.contains(source.name) ? "kept existing" : "skipped"
            let note = source.consumedByProvider ? "" : "  (no provider reads this name)"
            let kind = source.entry.type ?? (source.entry.cookie != nil ? "cookie" : "api")
            lines.append("  \(source.name)  [\(kind)]  from \(source.origin) — \(status)\(note)")
        }
        lines.append("")
        lines.append("\(report.added.count) added, \(report.kept.count) kept.")
        if !report.filesRead.isEmpty {
            lines.append("The original auth files were left untouched.")
        }
        return lines.joined(separator: "\n")
    }
}
