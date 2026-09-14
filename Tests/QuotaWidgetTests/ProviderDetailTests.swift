import Foundation
import Testing
@testable import QuotaWidget

@Suite struct OpenAIProviderTests {
    /// Builds a JWT-shaped token whose payload carries the claims the provider reads.
    /// Keys are sorted so the encoded token is byte-identical across calls.
    private func makeToken(accountID: String = "acct_1", plan: String = "plus") -> String {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_plan_type": plan
            ],
            "email": "alice@example.com"
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    private func store(token: String, expires: Double = 4_102_444_800_000) -> CredentialStore {
        let json = """
        {"openai":{"type":"oauth","access":"\(token)","refresh":"r","expires":\(expires)}}
        """
        return Stub.store(authFiles: ["~/.pi/agent/auth.json": json])
    }

    private let usage = """
    {"rate_limit":{
        "primary_window":{"used_percent":35,"reset_at":4102444800,"limit_window_seconds":18000},
        "secondary_window":{"used_percent":60,"reset_after_seconds":3600,"limit_window_seconds":604800}
     },
     "spend_control":{"individual_limit":{"remaining_percent":88}}}
    """

    private func quota(store: CredentialStore, body: String? = nil, log: RequestLog? = nil) async -> ProviderQuota {
        let provider = OpenAIProvider()
        return await provider.fetch(Stub.context(
            ProviderConfig(type: "openai"),
            client: Stub.client(body: body ?? usage) { log?.record($0) },
            store: store
        ))
    }

    @Test func windowsMappedFromWindowDuration() async throws {
        let quota = await quota(store: store(token: makeToken()))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.account == "alice@example.com")
        #expect(quota.plan == "ChatGPT Plus")

        let fiveHour = try #require(quota.windows.first { $0.label == "5h" })
        #expect(abs((fiveHour.resolvedRemainingPercent ?? 0) - 65) < 0.01)
        #expect(fiveHour.resetAt?.timeIntervalSince1970 == 4_102_444_800)

        let weekly = try #require(quota.windows.first { $0.label == "1w" })
        #expect(abs((weekly.resolvedRemainingPercent ?? 0) - 40) < 0.01)
        #expect(abs((weekly.resetAt?.timeIntervalSinceNow ?? 0) - 3600) < 5)

        #expect(quota.metric("spend-control")?.value == "88%")
    }

    @Test func accountIDHeaderComesFromTokenClaim() async {
        let token = makeToken(accountID: "acct_xyz")
        let log = RequestLog()
        _ = await quota(store: store(token: token), log: log)
        #expect(log.header("ChatGPT-Account-Id") == "acct_xyz")
        #expect(log.header("Authorization") == "Bearer \(token)")
    }

    /// Duplicate windows with the same duration should not be rendered twice.
    @Test func identicalWindowsCollapse() async {
        let body = """
        {"rate_limit":{
            "primary_window":{"used_percent":10,"limit_window_seconds":18000},
            "secondary_window":{"used_percent":10,"limit_window_seconds":18000}}}
        """
        let quota = await quota(store: store(token: makeToken()), body: body)
        #expect(quota.windows.count == 1)
    }

    @Test func expiredTokenIsReported() async throws {
        let quota = await quota(store: store(token: makeToken(), expires: 1_000_000))
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("expired"))
    }

    @Test func codexAuthFileLayout() async {
        let codexStore = Stub.store(authFiles: [
            "~/.codex/auth.json": #"{"tokens":{"access_token":"tok","account_id":"acct_codex"}}"#
        ])
        let quota = await quota(store: codexStore)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.credentialSource == "~/.codex/auth.json:tokens")
    }

    @Test func noCredentialIsUnconfigured() async {
        let quota = await quota(store: Stub.store())
        #expect(quota.status.isNotConfigured)
    }

    @Test func opaqueTokenStillWorks() async {
        // A non-JWT access token yields no account id, which is not an error.
        let quota = await quota(store: store(token: "opaque-token"))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.account == nil)
    }
}

@Suite struct AnthropicProviderTests {
    private let usage = """
    {"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},
     "seven_day":{"utilization":80,"resets_at":"2030-01-05T00:00:00Z"},
     "seven_day_opus":{"utilization":95}}
    """

    private var store: CredentialStore {
        Stub.store(authFiles: [
            "~/.claude/.credentials.json": """
            {"claudeAiOauth":{"accessToken":"claude-token","subscriptionType":"max","expiresAt":4102444800000}}
            """
        ])
    }

    @Test func utilizationBecomesRemaining() async {
        let provider = AnthropicProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "anthropic"),
            client: Stub.client(body: usage),
            store: store
        ))

        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.plan == "max")
        #expect(abs((quota.window("fiveHour")?.resolvedRemainingPercent ?? 0) - 75) < 0.01)
        #expect(abs((quota.window("sevenDay")?.resolvedRemainingPercent ?? 0) - 20) < 0.01)
        #expect(abs((quota.window("sevenDayOpus")?.resolvedRemainingPercent ?? 0) - 5) < 0.01)
    }

    @Test func betaHeaderAndClaudeCredentialSource() async {
        let log = RequestLog()
        let provider = AnthropicProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "anthropic"),
            client: Stub.client(body: usage) { log.record($0) },
            store: store
        ))
        #expect(log.recordedURLs.first == "https://api.anthropic.com/api/oauth/usage")
        #expect(log.header("anthropic-beta") == "oauth-2025-04-20")
        #expect(quota.credentialSource == "~/.claude/.credentials.json:claudeAiOauth")
    }

    @Test func expiredClaudeToken() async throws {
        let expired = Stub.store(authFiles: [
            "~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000}}"#
        ])
        let provider = AnthropicProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "anthropic"),
            client: Stub.client(body: usage),
            store: expired
        ))
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("expired"))
    }

    @Test func noCredentialIsUnconfigured() async {
        let provider = AnthropicProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "anthropic"),
            client: Stub.client(body: usage),
            store: Stub.store()
        ))
        #expect(quota.status.isNotConfigured)
    }

    @Test func authJsonOAuthEntryWorks() async {
        let jsonStore = Stub.store(authFiles: [
            "~/.pi/agent/auth.json": #"{"anthropic":{"type":"oauth","access":"sk-ant"}}"#
        ])
        let provider = AnthropicProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "anthropic"),
            client: Stub.client(body: usage),
            store: jsonStore
        ))
        #expect(quota.status.isOK, "\(quota.status)")
    }
}

@Suite struct BalanceProviderTests {
    @Test func deepSeekBalancesPerCurrency() async throws {
        let body = """
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"42.50","granted_balance":"10.00","topped_up_balance":"32.50"}]}
        """
        let provider = DeepSeekProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "deepseek"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["DEEPSEEK_API_KEY": "k"])
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        let metric = try #require(quota.metric("balance-0"))
        #expect(metric.label == "Balance (CNY)")
        #expect(metric.value == "42.5")
        #expect(metric.detail?.contains("granted 10") == true)
    }

    @Test func deepSeekUnavailableAccount() async {
        let provider = DeepSeekProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "deepseek"),
            client: Stub.client(body: #"{"is_available":false,"balance_infos":[]}"#),
            store: Stub.store(environment: ["DEEPSEEK_API_KEY": "k"])
        ))
        #expect(quota.status.isFailed)
    }

    @Test func openRouterBudgetWindow() async throws {
        let body = #"{"data":{"label":"sk-or-v1","limit":100,"usage":25,"limit_remaining":75}}"#
        let provider = OpenRouterProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "openrouter"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["OPENROUTER_API_KEY": "k"])
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        let budget = try #require(quota.window("budget"))
        #expect(abs((budget.resolvedRemainingPercent ?? 0) - 75) < 0.01)
        #expect(budget.unit == "USD")
        #expect(quota.metric("spend")?.value == "$25.00")
    }

    /// Unlimited keys report spend but no ratio.
    @Test func openRouterUnlimitedKey() async throws {
        let body = #"{"data":{"usage":12.5}}"#
        let provider = OpenRouterProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "openrouter"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["OPENROUTER_API_KEY": "k"])
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.isEmpty)
        #expect(quota.metric("spend")?.value == "$12.50")
    }
}

@Suite struct CustomProviderTests {
    @Test func quotaV1Format() async throws {
        let body = """
        {"plan":"Studio","account":"team@example.com",
         "windows":[{"label":"5-hour","used":10,"limit":50,"unit":"requests","resetAt":"2030-01-01T00:00:00Z"}],
         "metrics":[{"label":"Balance","value":"12.50","detail":"USD"}]}
        """
        let provider = CustomProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "custom", url: "https://example.com/quota"),
            client: Stub.client(body: body),
            store: Stub.store()
        ))

        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.plan == "Studio")
        #expect(quota.account == "team@example.com")
        let window = try #require(quota.windows.first)
        #expect(abs((window.resolvedRemainingPercent ?? 0) - 80) < 0.01)
        #expect(window.resetAt?.timeIntervalSince1970 == 1_893_456_000)
        #expect(quota.metrics.first?.value == "12.50")
    }

    @Test func jsonV1Format() async throws {
        let body = """
        {"data":{"plan_name":"Pro","limits":[{"name":"Weekly","used_count":30,"total":100}],"balance":7.25}}
        """
        let config = ProviderConfig(
            type: "custom",
            url: "https://example.com/quota",
            format: "json-v1",
            planPath: "data.plan_name",
            windowsPath: "data.limits",
            windowFields: WindowFieldMapping(
                label: "name",
                used: "used_count",
                limit: "total",
                remaining: nil,
                remainingPercent: nil,
                usedPercent: nil,
                resetAt: "resetAt",
                unit: nil
            ),
            metricPaths: ["Balance": "data.balance"]
        )
        let provider = CustomProvider()
        let quota = await provider.fetch(Stub.context(
            config,
            client: Stub.client(body: body),
            store: Stub.store()
        ))

        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.plan == "Pro")
        let window = try #require(quota.windows.first)
        #expect(window.label == "Weekly")
        #expect(abs((window.resolvedRemainingPercent ?? 0) - 70) < 0.01)
        #expect(quota.metrics.first { $0.label == "Balance" }?.value == "7.25")
    }

    @Test func apiKeyBecomesBearerHeader() async {
        let log = RequestLog()
        let provider = CustomProvider()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "custom", apiKeyEnv: "MY_KEY", url: "https://example.com/q"),
            client: Stub.client(body: #"{"windows":[{"label":"w","used":1,"limit":2}]}"#) { log.record($0) },
            store: Stub.store(environment: ["MY_KEY": "abc"])
        ))
        #expect(log.header("Authorization") == "Bearer abc")
    }

    @Test func templateHeaderExpansion() async {
        let log = RequestLog()
        let provider = CustomProvider()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(
                type: "custom",
                headers: ["x-api-key": "${SECRET}"],
                url: "https://example.com/q"
            ),
            client: Stub.client(body: #"{"windows":[{"label":"w","used":1,"limit":2}]}"#) { log.record($0) },
            store: Stub.store(environment: ["SECRET": "s3cret"])
        ))
        #expect(log.header("x-api-key") == "s3cret")
    }

    @Test func missingURLFails() async throws {
        let provider = CustomProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "custom"),
            client: Stub.client(body: "{}"),
            store: Stub.store()
        ))
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("url"))
    }

    /// A plan with a known allowance but a flaky endpoint still shows its window.
    @Test func staticWindowsSurviveFetchFailure() async throws {
        let config = ProviderConfig(
            type: "custom",
            url: "https://example.com/q",
            staticWindows: [StaticWindow(label: "Monthly", remainingPercent: 100, unit: "requests")]
        )
        let provider = CustomProvider()
        let quota = await provider.fetch(Stub.context(
            config,
            client: Stub.client(status: 500, body: "boom"),
            store: Stub.store()
        ))
        #expect(quota.windows.count == 1)
        #expect(quota.windows.first?.label == "Monthly")
        #expect(try #require(quota.status.failureMessage).contains("HTTP 500"))
    }
}

@Suite struct ReportTests {
    private var sample: [ProviderQuota] {
        [
            ProviderQuota(
                id: "commandcode",
                name: "Command Code",
                plan: "pro",
                windows: [
                    QuotaWindow(id: "fiveHour", label: "5-hour", used: 10, limit: 40, resetAt: Date(timeIntervalSince1970: 4_102_444_800))
                ],
                metrics: [QuotaMetric(id: "credits", label: "Credits remaining", value: "130")],
                status: .ok,
                updatedAt: Date(),
                credentialSource: "env:COMMAND_CODE_API_KEY"
            ),
            ProviderQuota.notConfigured(id: "kimi", name: "Kimi Code", reason: "no key")
        ]
    }

    @Test func summaryCounts() throws {
        let payload = CLIReport.render(quotas: sample, lastRefresh: Date())
        let summary = try #require(payload["summary"] as? [String: Any])
        #expect(summary["ok"] as? Int == 1)
        #expect(summary["unconfigured"] as? Int == 1)
        #expect(summary["failed"] as? Int == 0)
        #expect(summary["worstRemainingPercent"] as? Double == 75)
    }

    @Test func providerEntriesCarryWindowsAndErrors() throws {
        let payload = CLIReport.render(quotas: sample, lastRefresh: Date())
        let providers = try #require(payload["providers"] as? [[String: Any]])
        #expect(providers.count == 2)

        let commandCode = try #require(providers.first { $0["id"] as? String == "commandcode" })
        #expect(commandCode["status"] as? String == "ok")
        let windows = try #require(commandCode["windows"] as? [[String: Any]])
        #expect(windows.first?["remainingPercent"] as? Double == 75)
        #expect((windows.first?["resetsInSeconds"] as? Int ?? -1) > 0)

        let kimi = try #require(providers.first { $0["id"] as? String == "kimi" })
        #expect(kimi["status"] as? String == "unconfigured")
        #expect(kimi["error"] as? String == "no key")
    }

    @Test func reportIsJSONSerializable() {
        let payload = CLIReport.render(quotas: sample, lastRefresh: Date())
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test func plainTextMentionsProviders() {
        let text = CLIReport.plainText(quotas: sample, lastRefresh: Date())
        #expect(text.contains("Command Code"))
        #expect(text.contains("75% left"))
        #expect(text.contains("Credits remaining"))
        #expect(text.contains("no key"))
    }
}

@Suite struct WindowModelTests {
    @Test func remainingDerivedFromUsedAndLimit() {
        let window = QuotaWindow(id: "w", label: "w", used: 30, limit: 120)
        #expect(abs((window.resolvedRemainingPercent ?? 0) - 75) < 0.01)
        #expect(abs((window.remaining ?? 0) - 90) < 0.01)
    }

    @Test func explicitPercentWins() {
        let window = QuotaWindow(id: "w", label: "w", used: 90, limit: 100, remainingPercent: 10)
        #expect(abs((window.resolvedRemainingPercent ?? 0) - 10) < 0.01)
    }

    @Test func percentIsClamped() {
        #expect(QuotaWindow(id: "w", label: "w", remainingPercent: 140).resolvedRemainingPercent == 100)
        #expect(QuotaWindow(id: "w", label: "w", remainingPercent: -20).resolvedRemainingPercent == 0)
        #expect(QuotaWindow(id: "w", label: "w", used: 500, limit: 100).resolvedRemainingPercent == 0)
    }

    @Test func noNumbersYieldsNoPercent() {
        #expect(QuotaWindow(id: "w", label: "w").resolvedRemainingPercent == nil)
    }

    @Test func zeroLimitDoesNotDivideByZero() {
        #expect(QuotaWindow(id: "w", label: "w", used: 5, limit: 0).resolvedRemainingPercent == nil)
    }

    @Test func worstRemainingPicksTightestWindow() {
        let quota = ProviderQuota(
            id: "x",
            name: "X",
            windows: [
                QuotaWindow(id: "a", label: "a", remainingPercent: 80),
                QuotaWindow(id: "b", label: "b", remainingPercent: 12)
            ]
        )
        #expect(quota.worstRemainingPercent == 12)
    }

    @Test func elapsedAndCountdownFormatting() {
        #expect(QuotaFormat.elapsed(since: Date()) == "just now")
        #expect(QuotaFormat.countdown(to: Date().addingTimeInterval(-1)) == "now")
        #expect(QuotaFormat.countdown(to: Date().addingTimeInterval(7200)) == "2h 0m")
    }

    @Test func numberFormatting() {
        #expect(QuotaFormat.number(1_500_000) == "1.5M")
        #expect(QuotaFormat.number(12_000) == "12k")
        #expect(QuotaFormat.number(42) == "42")
    }

    @Test func thresholdsMapToColors() {
        #expect(QuotaPalette.color(forRemaining: 5) == .red)
        #expect(QuotaPalette.color(forRemaining: 20) == .orange)
        #expect(QuotaPalette.color(forRemaining: 40) == .yellow)
        #expect(QuotaPalette.color(forRemaining: 90) == .green)
    }
}
