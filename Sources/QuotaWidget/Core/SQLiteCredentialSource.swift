import Foundation
import SQLite3

/// Read-only view of the credential tables that the `omp` agent keeps in its
/// SQLite databases.
///
/// omp stores logins (including Command Code's `user_…` key) in
/// `auth_credentials`, one row per provider, with the secret in a JSON `data`
/// column. Nothing here ever writes to the database.
enum SQLiteCredentialSource {
    struct Row {
        var provider: String
        var credentialType: String
        var data: String
        var disabledCause: String?
    }

    /// Databases that may hold logins, in the order they should be consulted.
    static var databasePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.omp/agent/agent.db",
            "\(home)/.pi/agent/agent.db"
        ]
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Reads credential names → entries from every database that exists.
    /// A database that cannot be read is skipped rather than treated as fatal.
    static func credentials() -> (entries: [String: CredentialEntry], files: [String]) {
        var entries: [String: CredentialEntry] = [:]
        var files: [String] = []

        for path in databasePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let rows = (try? readCredentials(at: path)) ?? []
            guard !rows.isEmpty else { continue }
            files.append(displayPath(path))

            for row in rows {
                // A revoked login is still in the table; ignore it.
                guard row.disabledCause == nil || row.disabledCause?.isEmpty == true else { continue }
                guard let entry = entry(from: row) else { continue }
                // First database wins, so a stale row cannot shadow a fresh one.
                if entries[row.provider] == nil {
                    entries[row.provider] = entry
                }
            }
        }
        return (entries, files)
    }

    /// Maps one `auth_credentials` row onto the shared credential shape.
    static func entry(from row: Row) -> CredentialEntry? {
        guard let json = try? JSON.parse(Data(row.data.utf8)) else { return nil }

        let isOAuth = row.credentialType.lowercased().contains("oauth")
        if isOAuth {
            let access = json["access"]?.string ?? json["access_token"]?.string
            let refresh = json["refresh"]?.string ?? json["refresh_token"]?.string
            guard let access, !access.isEmpty else { return nil }
            return CredentialEntry(
                type: "oauth",
                access: access,
                refresh: refresh,
                expires: json["expires"]?.double ?? json["expires_at"]?.double,
                accountId: json["accountId"]?.string ?? json["account_id"]?.string,
                subscriptionType: json["subscriptionType"]?.string
            )
        }

        guard let key = json["key"]?.string ?? json["apiKey"]?.string, !key.isEmpty else {
            return nil
        }
        // omp keeps a session cookie for some providers under a cookie key.
        let cookie = json["cookie"]?.string
        return CredentialEntry(type: "api", key: key, cookie: cookie)
    }

    // MARK: - SQLite plumbing

    enum SQLiteError: LocalizedError {
        case open(String, Int32)
        case prepare(String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let path, let code): return "Cannot open \(path) (sqlite \(code))"
            case .prepare(let message): return "Cannot read auth_credentials: \(message)"
            case .step(let message): return "Cannot read auth_credentials: \(message)"
            }
        }
    }

    static func readCredentials(at path: String) throws -> [Row] {
        var handle: OpaquePointer?
        // Read-only first. A WAL database needs a writable directory for its
        // -shm file, so fall back to read-write (still issuing no writes).
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            if handle != nil { sqlite3_close(handle); handle = nil }
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                let code = handle.map { sqlite3_errcode($0) } ?? -1
                if handle != nil { sqlite3_close(handle) }
                throw SQLiteError.open(displayPath(path), code)
            }
        }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT provider, credential_type, data, disabled_cause
        FROM auth_credentials
        ORDER BY id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
            func text(_ index: Int32) -> String {
                guard let pointer = sqlite3_column_text(statement, index) else { return "" }
                return String(cString: pointer)
            }
            let disabled = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : text(3)
            rows.append(Row(
                provider: text(0),
                credentialType: text(1),
                data: text(2),
                disabledCause: disabled
            ))
        }
        return rows
    }
}
