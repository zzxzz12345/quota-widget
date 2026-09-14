import Foundation

/// Resolves API keys from `config.json` first and, unless disabled, from the
/// auth files the CLI agents already hold on this machine. Nothing is ever
/// written back from here; `AuthMigrator` does the writing, on request.
final class CredentialStore {
    struct Located {
        var value: String
        var source: String
    }

    private struct AuthFile {
        var path: String
        var json: JSON
    }

    private var authFiles: [AuthFile] = []
    private var environment: [String: String]
    /// The `credentials` map, kept separately so a provider can name one entry.
    private var namedCredentials: [String: CredentialEntry] = [:]

    /// Label used for credentials that came from `config.json`.
    static let configSourceLabel = "config.json"
    /// Label used for credentials read out of an agent's SQLite database.
    static let databaseSourceLabel = "omp agent.db"

    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.commandcode/auth.json",
            "\(home)/.pi/agent/auth.json",
            "\(home)/.omp/agent/auth.json",
            "\(home)/.local/share/opencode/auth.json",
            "\(home)/.config/opencode/auth.json",
            "\(home)/.codex/auth.json",
            "\(home)/.claude/.credentials.json"
        ]
    }

    /// Config-backed store: `config.json` wins over every external source.
    init(config: QuotaWidgetConfig, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        loadConfigCredentials(config)
        if config.readsExternalAuthFiles {
            loadAgentDatabases()
            loadExternalAuthFiles()
        }
    }

    /// Store backed by the filesystem's auth files only.
    init() {
        environment = ProcessInfo.processInfo.environment
        loadAgentDatabases()
        loadExternalAuthFiles()
    }

    /// Store backed by explicit contents rather than the filesystem.
    init(environment: [String: String], authFiles: [String: JSON]) {
        self.environment = environment
        self.authFiles = authFiles.map { AuthFile(path: $0.key, json: $0.value) }
    }

    /// Config-backed store with stubbed external sources, for tests.
    init(
        config: QuotaWidgetConfig,
        environment: [String: String],
        externalAuthFiles: [String: JSON],
        databaseEntries: [String: CredentialEntry] = [:]
    ) {
        self.environment = environment
        loadConfigCredentials(config)
        guard config.readsExternalAuthFiles else { return }
        if !databaseEntries.isEmpty {
            let merged = databaseEntries.mapValues { $0.json(environment: environment).raw }
            authFiles.append(AuthFile(path: Self.databaseSourceLabel, json: JSON(merged)))
        }
        authFiles.append(contentsOf: externalAuthFiles.map { AuthFile(path: $0.key, json: $0.value) })
    }

    private func loadConfigCredentials(_ config: QuotaWidgetConfig) {
        guard let credentials = config.credentials else { return }
        for (name, entry) in credentials where !entry.isEmpty {
            namedCredentials[name] = entry
        }
        guard !namedCredentials.isEmpty else { return }
        // Prepend, so an ordinary `authValue(keys:)` lookup prefers config.json.
        let merged = namedCredentials.mapValues { $0.json(environment: environment).raw }
        authFiles.insert(AuthFile(path: Self.configSourceLabel, json: JSON(merged)), at: 0)
    }

    private func loadExternalAuthFiles() {
        for path in Self.candidatePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let json = try? JSON.parse(data) else { continue }
            authFiles.append(AuthFile(path: path, json: json))
        }
    }

    /// The `omp` agent keeps logins in SQLite rather than JSON, so its
    /// credentials are presented in the same flat shape the providers already
    /// parse and placed before the JSON files, which tend to be older.
    private func loadAgentDatabases() {
        let found = SQLiteCredentialSource.credentials()
        guard !found.entries.isEmpty else { return }
        let merged = found.entries.mapValues { $0.json(environment: environment).raw }
        authFiles.append(AuthFile(
            path: found.files.joined(separator: ", "),
            json: JSON(merged)
        ))
    }

    /// Shortens a source label for display.
    private func shortName(_ path: String) -> String {
        if path == Self.configSourceLabel { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Names of the credentials currently known, for status output.
    var namedCredentialKeys: [String] { namedCredentials.keys.sorted() }

    func namedCredential(_ name: String) -> Located? {
        guard let entry = namedCredentials[name] else { return nil }
        guard let value = Self.credentialString(entry.json(environment: environment)) else { return nil }
        return Located(value: value, source: "\(Self.configSourceLabel):\(name)")
    }

    /// Raw entry for a credential name, including non-standard fields such as a
    /// MiniMax session cookie.
    func namedCredentialEntry(_ name: String) -> JSON? {
        namedCredentials[name]?.json(environment: environment)
    }

    /// First credential in the config matching any of `names`.
    func matchingNamedCredential(_ names: [String]) -> Located? {
        for name in names {
            if let found = namedCredential(name) { return found }
        }
        return nil
    }

    // MARK: - Environment

    func fromEnvironment(_ names: [String]) -> Located? {
        for name in names {
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return Located(value: value, source: "env:\(name)")
            }
        }
        return nil
    }

    /// Raw environment read, for provider-specific toggles.
    func flag(_ name: String) -> Bool {
        environment[name] == "1"
    }

    func environmentValue(_ names: [String]) -> Located? { fromEnvironment(names) }

    // MARK: - Config then environment

    /// Config-declared `apiKey` wins, then `apiKeyEnv`, then any env var in the
    /// provider's own list. `${VAR}` inside `apiKey` is expanded.
    /// `config.json` wins at every step: a named reference, then an inline key,
    /// then a credential stored under the provider's own name, then an env var.
    /// The ordering matters because a menu bar app launched from Finder does not
    /// inherit the shell environment, so a stale exported variable must not
    /// shadow what the user stored in the config.
    func resolve(config: ProviderConfig, envNames: [String]) -> Located? {
        if let name = config.credential, let found = namedCredential(name) {
            return found
        }
        if let literal = config.apiKey?.trimmingCharacters(in: .whitespaces), !literal.isEmpty {
            let expanded = Self.expandVariables(literal, environment: environment)
                .trimmingCharacters(in: .whitespaces)
            if !expanded.isEmpty {
                return Located(value: expanded, source: "config:\(config.resolvedID)")
            }
        }
        let implicitNames = [config.resolvedID] + ProviderRegistry.credentialAliases(for: config.type)
        if let found = matchingNamedCredential(implicitNames) {
            return found
        }
        if let envName = config.apiKeyEnv, let found = fromEnvironment([envName]) {
            return found
        }
        return fromEnvironment(envNames)
    }

    /// Cookie header value from the config, the environment, or a named
    /// credential that carries a `cookie` field.
    func resolveCookie(config: ProviderConfig, envNames: [String], names: [String] = []) -> Located? {
        if let literal = config.cookie?.trimmingCharacters(in: .whitespaces), !literal.isEmpty {
            let expanded = Self.expandVariables(literal, environment: environment)
                .trimmingCharacters(in: .whitespaces)
            if !expanded.isEmpty {
                return Located(value: expanded, source: "config:\(config.resolvedID)")
            }
        }
        if let envName = config.cookieEnv, let found = fromEnvironment([envName]) {
            return found
        }
        if let found = fromEnvironment(envNames) {
            return found
        }

        var candidates: [String] = []
        if let referenced = config.credential { candidates.append(referenced) }
        candidates.append(contentsOf: names)
        candidates.append(contentsOf: ProviderRegistry.credentialAliases(for: config.type))
        candidates.append(config.resolvedID)
        for name in candidates {
            guard let entry = namedCredentials[name],
                  let cookie = entry.json(environment: environment)["cookie"]?.string,
                  !cookie.isEmpty else { continue }
            return Located(value: cookie, source: "\(Self.configSourceLabel):\(name).cookie")
        }
        return nil
    }

    // MARK: - Auth files

    /// Looks up `key` in every discovered auth file. A string value is returned
    /// as-is; a dictionary is unwrapped through `access` / `key` / `apiKey`.
    func authValue(keys: [String], typeFilter: String? = nil) -> Located? {
        for key in keys {
            for file in authFiles {
                guard let entry = file.json[key] else { continue }
                if let filter = typeFilter {
                    let entryType = entry["type"]?.string
                    if entryType != filter { continue }
                }
                if let value = Self.credentialString(entry) {
                    return Located(value: value, source: "\(shortName(file.path)):\(key)")
                }
            }
        }
        return nil
    }

    /// Raw auth-file entry, for providers whose files use a bespoke layout.
    func rawAuthEntry(key: String) -> (json: JSON, source: String)? {
        for file in authFiles {
            if let entry = file.json[key], entry.exists {
                return (entry, "\(shortName(file.path)):\(key)")
            }
        }
        return nil
    }

    func rawAuthFile(containingAnyOf keys: [String]) -> (json: JSON, source: String)? {
        for file in authFiles {
            if keys.contains(where: { file.json[$0]?.exists == true }) {
                return (file.json, shortName(file.path))
            }
        }
        return nil
    }

    var discoveredAuthFilePaths: [String] {
        authFiles.map { shortName($0.path) }
    }

    static func credentialString(_ entry: JSON) -> String? {
        if let text = entry.string, !text.isEmpty { return text }
        let type = entry["type"]?.string
        switch type {
        case "api":
            return nonEmpty(entry["key"]?.string)
        case "oauth":
            return nonEmpty(entry["access"]?.string)
        default:
            break
        }
        return nonEmpty(entry["access"]?.string)
            ?? nonEmpty(entry["key"]?.string)
            ?? nonEmpty(entry["apiKey"]?.string)
            ?? nonEmpty(entry["token"]?.string)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    // MARK: - Variable expansion

    /// Expands `${VAR}` and `$VAR` from the environment. Unknown variables
    /// collapse to an empty string so the caller can treat the key as absent.
    static func expandVariables(_ input: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            guard character == "$" else {
                output.append(character)
                index = input.index(after: index)
                continue
            }
            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append(character)
                break
            }
            if input[next] == "{" {
                guard let close = input[next...].firstIndex(of: "}") else {
                    output.append(contentsOf: input[index...])
                    break
                }
                let name = String(input[input.index(after: next)..<close])
                output.append(environment[name] ?? "")
                index = input.index(after: close)
            } else {
                var cursor = next
                var name = ""
                while cursor < input.endIndex, input[cursor].isLetter || input[cursor].isNumber || input[cursor] == "_" {
                    name.append(input[cursor])
                    cursor = input.index(after: cursor)
                }
                if name.isEmpty {
                    output.append(character)
                    index = next
                } else {
                    output.append(environment[name] ?? "")
                    index = cursor
                }
            }
        }
        return output
    }

    /// Expands ${VAR} / $VAR in header values, dropping any that resolve empty.
    func expandHeaders(_ headers: [String: String]) -> [String: String] {
        var expanded: [String: String] = [:]
        for (key, value) in headers {
            let resolved = Self.expandVariables(value, environment: environment)
                .trimmingCharacters(in: .whitespaces)
            if !resolved.isEmpty { expanded[key] = resolved }
        }
        return expanded
    }
}
