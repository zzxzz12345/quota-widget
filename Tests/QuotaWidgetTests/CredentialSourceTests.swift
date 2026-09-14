import Foundation
import SQLite3
import Testing
@testable import QuotaWidget

@Suite struct MonthlyAllowanceTests {
    /// The published table: GOAT is $70/mo with $14 (5h) and $35 (1w) caps.
    @Test func longestPlanKeyWins() {
        // "individual-goat" contains both "go" and "goat"; goat must win.
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "individual-goat") == 70)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "individual-go") == 10)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "individual-pro") == 80)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "max-20x") == 300)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "max-10x") == 150)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "team-pro") == 40)
    }

    @Test func caseIsIgnored() {
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "Individual-GOAT") == 70)
    }

    @Test func unknownPlanHasNoAllowance() {
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "mystery-tier") == nil)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: "") == nil)
        #expect(CommandCodeProvider.monthlyAllowance(forPlan: nil) == nil)
    }
}

@Suite struct WindowOrderTests {
    private func quota(_ windows: [QuotaWindow]) -> ProviderQuota {
        ProviderQuota(id: "x", name: "X", windows: windows)
    }

    @Test func orderedWindowsFollow5h1w1m() {
        let unordered = quota([
            QuotaWindow(id: "monthly", label: "1m", remainingPercent: 30),
            QuotaWindow(id: "fiveHour", label: "5h", remainingPercent: 10),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 20)
        ])
        #expect(unordered.orderedWindows.map(\.label) == ["5h", "1w", "1m"])
    }

    /// OpenCode Go names its rolling window differently but it is still first.
    @Test func rollingIsTreatedAsTheFiveHourWindow() {
        let q = quota([
            QuotaWindow(id: "monthly", label: "1m", remainingPercent: 30),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 20),
            QuotaWindow(id: "rolling", label: "5h", remainingPercent: 10)
        ])
        #expect(q.orderedWindows.map(\.id) == ["rolling", "weekly", "monthly"])
    }

    @Test func unknownWindowsSortLastButKeepRelativeOrder() {
        let q = quota([
            QuotaWindow(id: "mcp", label: "Tools", remainingPercent: 5),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 20),
            QuotaWindow(id: "other", label: "Extra", remainingPercent: 6)
        ])
        #expect(q.orderedWindows.map(\.label) == ["1w", "Tools", "Extra"])
    }

    @Test func primaryWindowsAreTheFirstThreeWithNumbers() {
        let q = quota([
            QuotaWindow(id: "fiveHour", label: "5h", remainingPercent: 10),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 20),
            QuotaWindow(id: "monthly", label: "1m", remainingPercent: 30),
            QuotaWindow(id: "extra", label: "Extra", remainingPercent: 40)
        ])
        #expect(q.primaryWindows.map(\.label) == ["5h", "1w", "1m"])
    }

    @Test func windowsWithoutNumbersAreSkipped() {
        let q = quota([
            QuotaWindow(id: "fiveHour", label: "5h"),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 20)
        ])
        #expect(q.primaryWindows.map(\.label) == ["1w"])
    }
}

/// SQLite copies the bound bytes instead of holding a pointer to a Swift
/// temporary that is already gone by the time `sqlite3_step` runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@Suite struct SQLiteCredentialTests {
    /// Builds a throwaway agent.db matching the shape omp writes.
    private func makeDatabase(rows: [(provider: String, type: String, data: String, disabled: String?)]) throws -> String {
        let path = NSTemporaryDirectory() + "qw-agent-\(UUID().uuidString).db"
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }

        let create = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL
        );
        """
        #expect(sqlite3_exec(handle, create, nil, nil, nil) == SQLITE_OK)

        for row in rows {
            var statement: OpaquePointer?
            let sql = "INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES (?,?,?,?)"
            #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
            sqlite3_bind_text(statement, 1, row.provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, row.type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, row.data, -1, SQLITE_TRANSIENT)
            if let disabled = row.disabled {
                sqlite3_bind_text(statement, 4, disabled, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return path
    }

    @Test func readsApiKeyRows() throws {
        let path = try makeDatabase(rows: [
            ("commandcode", "api_key", #"{"key":"user_abc","source":"login"}"#, nil),
            ("opencode-go", "api_key", #"{"key":"sk-xyz"}"#, nil)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = try SQLiteCredentialSource.readCredentials(at: path)
        #expect(rows.count == 2)
        #expect(rows.first?.provider == "commandcode")

        let entries = rows.compactMap { SQLiteCredentialSource.entry(from: $0) }
        #expect(entries.count == 2)
        #expect(entries.first?.key == "user_abc")
        #expect(entries.first?.type == "api")
    }

    @Test func readsOAuthRows() throws {
        let path = try makeDatabase(rows: [
            ("anthropic", "oauth", #"{"access":"a","refresh":"r","expires":123}"#, nil)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = try SQLiteCredentialSource.readCredentials(at: path)
        let entry = try #require(rows.compactMap { SQLiteCredentialSource.entry(from: $0) }.first)
        #expect(entry.type == "oauth")
        #expect(entry.access == "a")
        #expect(entry.refresh == "r")
        #expect(entry.expires == 123)
    }

    @Test func disabledRowsAreSkipped() throws {
        let path = try makeDatabase(rows: [
            ("commandcode", "api_key", #"{"key":"revoked"}"#, "revoked"),
            ("deepseek", "api_key", #"{"key":"live"}"#, nil)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = try SQLiteCredentialSource.readCredentials(at: path)
        #expect(rows.count == 2)
        let usable = rows
            .filter { $0.disabledCause == nil || $0.disabledCause?.isEmpty == true }
            .compactMap { SQLiteCredentialSource.entry(from: $0) }
        #expect(usable.map(\.key) == ["live"])
    }

    @Test func rowsWithoutASecretAreIgnored() throws {
        let path = try makeDatabase(rows: [
            ("broken", "api_key", #"{"source":"login"}"#, nil),
            ("malformed", "api_key", "not json", nil)
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rows = try SQLiteCredentialSource.readCredentials(at: path)
        #expect(rows.compactMap { SQLiteCredentialSource.entry(from: $0) }.isEmpty)
    }

    @Test func missingTableIsAnErrorNotACrash() throws {
        let path = NSTemporaryDirectory() + "qw-empty-\(UUID().uuidString).db"
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        sqlite3_close(handle)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: (any Error).self) {
            try SQLiteCredentialSource.readCredentials(at: path)
        }
    }

    @Test func missingFileIsAnError() {
        #expect(throws: (any Error).self) {
            try SQLiteCredentialSource.readCredentials(at: "/nonexistent/nope.db")
        }
    }

    /// A database-sourced credential behaves like any other in the store.
    @Test func databaseEntriesReachProviders() {
        var config = QuotaWidgetConfig.default
        config.useExternalAuthFiles = true
        let store = CredentialStore(
            config: config,
            environment: [:],
            externalAuthFiles: [:],
            databaseEntries: ["commandcode": CredentialEntry(type: "api", key: "user_from_db")]
        )
        #expect(store.authValue(keys: ["commandcode"])?.value == "user_from_db")
    }

    /// config.json still outranks the database.
    @Test func configBeatsDatabase() {
        var config = QuotaWidgetConfig.default
        config.credentials = ["commandcode": CredentialEntry(type: "api", key: "from-config")]
        let store = CredentialStore(
            config: config,
            environment: [:],
            externalAuthFiles: [:],
            databaseEntries: ["commandcode": CredentialEntry(type: "api", key: "from-db")]
        )
        let found = store.resolve(config: ProviderConfig(type: "commandcode"), envNames: [])
        #expect(found?.value == "from-config")
    }
}
