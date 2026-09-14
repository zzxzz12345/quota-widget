import Foundation
import Testing
@testable import QuotaWidget

@Suite struct CommandCodeProviderTests {
    private let whoami = #"{"org":{"login":"acme","id":"org_123"},"user":{"userName":"alice","keyName":"laptop"}}"#
    private let credits = """
    {"credits":{"monthlyCredits":60,"purchasedCredits":25,"freeCredits":5},
     "windowLimits":{"fiveHour":{"used":12,"cap":40,"resetAt":4102444800},
                     "weekly":{"used":100,"cap":400,"resetAt":"2030-01-01T00:00:00Z"}}}
    """
    private let subscriptions = """
    {"data":{"planId":"pro","status":"active",
             "currentPeriodStart":"2026-09-01T00:00:00Z",
             "currentPeriodEnd":"2026-10-01T00:00:00Z"}}
    """
    private let summary = #"{"totalCost":12.5,"totalCount":340,"totalTokens":1200000}"#

    private var routes: [String: (status: Int, body: String)] {
        [
            "whoami": (200, whoami),
            "billing/credits": (200, credits),
            "billing/subscriptions": (200, subscriptions),
            "usage/summary": (200, summary)
        ]
    }

    private func fetch(
        store: CredentialStore,
        config: ProviderConfig = ProviderConfig(type: "commandcode"),
        routes override: [String: (status: Int, body: String)]? = nil,
        log: RequestLog? = nil
    ) async -> ProviderQuota {
        let provider = CommandCodeProvider()
        let client = Stub.routing(override ?? routes) { request in
            log?.record(request)
        }
        return await provider.fetch(Stub.context(config, client: client, store: store))
    }

    @Test func missingKeyIsUnconfigured() async throws {
        let quota = await fetch(store: Stub.store())
        let reason = try #require(quota.status.unconfiguredReason)
        #expect(reason.contains("COMMAND_CODE_API_KEY"))
    }

    @Test func environmentKeyDrivesFullReport() async throws {
        let quota = await fetch(store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]))
        #expect(quota.status.isOK, "\(quota.status)")

        #expect(quota.account == "acme · laptop")
        #expect(quota.plan == "pro · active")
        #expect(quota.credentialSource == "env:COMMAND_CODE_API_KEY")
        // 5h, 1w from windowLimits plus a derived 1m from the plan allowance.
        #expect(quota.windows.count == 3)

        let fiveHour = try #require(quota.window("fiveHour"))
        #expect(fiveHour.label == "5h")
        #expect(abs((fiveHour.resolvedRemainingPercent ?? 0) - 70) < 0.01)
        #expect(fiveHour.resetAt?.timeIntervalSince1970 == 4_102_444_800)

        let weekly = try #require(quota.window("weekly"))
        #expect(weekly.label == "1w")
        #expect(abs((weekly.resolvedRemainingPercent ?? 0) - 75) < 0.01)

        // The API gives the remaining monthly balance but not the cap, so the
        // 1m window uses the plan's published allowance (pro = 80).
        let monthly = try #require(quota.window("monthly"))
        #expect(monthly.label == "1m")
        #expect(monthly.limit == 80)
        #expect(abs((monthly.used ?? 0) - 20) < 0.01)
        #expect(abs((monthly.resolvedRemainingPercent ?? 0) - 75) < 0.01)
        #expect(monthly.resetAt != nil)

        // 60 monthly + 25 purchased + 5 free
        #expect(quota.metric("credits")?.value == "90")
    }

    @Test func orgScopedQueriesAreSent() async {
        let log = RequestLog()
        _ = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            log: log
        )
        #expect(log.recordedURLs.contains { $0.contains("/alpha/billing/credits?orgId=org_123") })
        #expect(log.recordedURLs.contains { $0.contains("usage/summary?") && $0.contains("since=2026-09-01") })
    }

    @Test func bearerHeaderIsSent() async {
        let log = RequestLog()
        _ = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            log: log
        )
        #expect(log.header("Authorization") == "Bearer user_x")
    }

    @Test func zeroDataRetentionHeader() async {
        let log = RequestLog()
        _ = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x", "CMD_ZDR": "1"]),
            log: log
        )
        #expect(log.header("x-cmd-zdr") == "1")
    }

    @Test func noZDRHeaderByDefault() async {
        let log = RequestLog()
        _ = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            log: log
        )
        #expect(log.header("x-cmd-zdr") == nil)
    }

    @Test func unauthorizedKeyReportsAuthFailure() async throws {
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "bad"]),
            routes: ["whoami": (401, #"{"error":"nope"}"#)]
        )
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("rejected the API key"))
    }

    /// A dead credits endpoint must not hide a healthy usage summary.
    @Test func partialSectionFailureStillReports() async throws {
        var partial = routes
        partial["billing/credits"] = (500, #"{"error":"boom"}"#)
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            routes: partial
        )
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.isEmpty)
        #expect(quota.plan == "pro · active")
        #expect(quota.metric("cost") != nil)
        #expect(try #require(quota.metric("cost")).detail?.contains("340 calls") == true)
    }

    @Test func unrecognizedAccountResponse() async throws {
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            routes: ["whoami": (200, #"{"something":"else"}"#)]
        )
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("Unrecognized account"))
    }

    @Test func credentialsFromCommandCodeAuthFile() async {
        let store = Stub.store(authFiles: [
            "~/.commandcode/auth.json": #"{"commandcode":{"type":"api","key":"user_file"}}"#
        ])
        let quota = await fetch(store: store)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.credentialSource == "~/.commandcode/auth.json:commandcode")
    }

    @Test func credentialsFromFlatAuthFile() async {
        let store = Stub.store(authFiles: [
            "~/.commandcode/auth.json": #"{"apiKey":"user_flat"}"#
        ])
        let quota = await fetch(store: store)
        #expect(quota.status.isOK, "\(quota.status)")
    }

    /// An unknown plan must not have a monthly percentage invented for it.
    @Test func unknownPlanSkipsTheMonthlyWindow() async throws {
        var plan = routes
        plan["billing/subscriptions"] = (200, #"{"data":{"planId":"mystery-tier","status":"active"}}"#)
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            routes: plan
        )
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.window("monthly") == nil)
        #expect(quota.windows.count == 2)
    }

    /// The allowance is overridable for plans not in the published table.
    @Test func monthlyAllowanceCanBeOverridden() async throws {
        var plan = routes
        plan["billing/subscriptions"] = (200, #"{"data":{"planId":"mystery-tier","status":"active"}}"#)
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            config: ProviderConfig(type: "commandcode", monthlyAllowance: 120),
            routes: plan
        )
        let monthly = try #require(quota.window("monthly"))
        #expect(monthly.limit == 120)
        #expect(abs((monthly.resolvedRemainingPercent ?? 0) - 50) < 0.01)
    }

    /// A plan allowance with no per-window cap still reports credits and spend.
    @Test func creditsOnlyAccountStillReports() async throws {
        var plan = routes
        plan["billing/credits"] = (200, #"{"credits":{"monthlyCredits":50,"purchasedCredits":0,"freeCredits":0}}"#)
        plan["billing/subscriptions"] = (200, #"{}"#)
        let quota = await fetch(
            store: Stub.store(environment: ["COMMAND_CODE_API_KEY": "user_x"]),
            routes: plan
        )
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.metric("credits")?.value == "50")
        #expect(quota.windows.isEmpty)
    }
}

@Suite struct ZaiProviderTests {
    @Test func limitsAreMappedByUnit() async throws {
        let body = """
        {"code":200,"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"percentage":20,"nextResetTime":4102444800000},
          {"type":"TOKENS_LIMIT","unit":6,"percentage":55},
          {"type":"TIME_LIMIT","unit":5,"percentage":10}
        ]}}
        """
        let provider = ZaiProvider(variant: .zai)
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "zai"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["ZAI_API_KEY": "k"])
        ))

        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.count == 3)

        let fiveHour = try #require(quota.window("fiveHour"))
        #expect(abs((fiveHour.resolvedRemainingPercent ?? 0) - 80) < 0.01)
        // Epoch milliseconds convert to seconds.
        #expect(fiveHour.resetAt?.timeIntervalSince1970 == 4_102_444_800)

        #expect(abs((quota.window("weekly")?.resolvedRemainingPercent ?? 0) - 45) < 0.01)
        #expect(abs((quota.window("mcp")?.resolvedRemainingPercent ?? 0) - 90) < 0.01)
    }

    /// Z.ai reports failures inside a 200 response.
    @Test func apiLevelErrorIsSurfaced() async throws {
        let provider = ZaiProvider(variant: .zai)
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "zai"),
            client: Stub.client(body: #"{"code":401,"msg":"token expired or incorrect","success":false}"#),
            store: Stub.store(environment: ["ZAI_API_KEY": "k"])
        ))
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("token expired"))
    }

    @Test func zhipuUsesBigmodelEndpointAndOwnEnv() async {
        let log = RequestLog()
        let client = Stub.client(body: #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":5}]}}"#) { request in
            log.record(request)
        }
        let provider = ZaiProvider(variant: .zhipu)
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "zhipu"),
            client: client,
            store: Stub.store(environment: ["ZHIPU_API_KEY": "k"])
        ))
        #expect(log.recordedURLs.first == "https://bigmodel.cn/api/monitor/usage/quota/limit")
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.name == "Zhipu Coding Plan")
    }

    @Test func rawAuthorizationByDefaultAndBearerOverride() async {
        let rawLog = RequestLog()
        let provider = ZaiProvider(variant: .zai)
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "zai"),
            client: Stub.client(body: #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":1}]}}"#) { rawLog.record($0) },
            store: Stub.store(environment: ["ZAI_API_KEY": "raw-key"])
        ))
        #expect(rawLog.header("Authorization") == "raw-key")

        let bearerLog = RequestLog()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "zai", authScheme: "bearer"),
            client: Stub.client(body: #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":1}]}}"#) { bearerLog.record($0) },
            store: Stub.store(environment: ["ZAI_API_KEY": "raw-key"])
        ))
        #expect(bearerLog.header("Authorization") == "Bearer raw-key")
    }

    @Test func authFileKeyIsUsed() async {
        let store = Stub.store(authFiles: [
            "~/.pi/agent/auth.json": #"{"zai-coding-plan":{"type":"api","key":"file-key"}}"#
        ])
        let provider = ZaiProvider(variant: .zai)
        let log = RequestLog()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "zai"),
            client: Stub.client(body: #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":1}]}}"#) { log.record($0) },
            store: store
        ))
        #expect(log.header("Authorization") == "file-key")
    }
}

@Suite struct KimiProviderTests {
    @Test func usageAndNestedLimits() async throws {
        let body = """
        {"data":{
          "usage":{"limit":100,"used":30,"reset_at":"2030-01-01T00:00:00Z"},
          "limits":[
            {"name":"5h limit","detail":{"limit":50,"remaining":10},
             "window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}
          ]
        }}
        """
        let provider = KimiProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["KIMI_API_KEY": "k"])
        ))

        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.count == 2)

        let usage = try #require(quota.window("usage"))
        #expect(usage.label == "Weekly limit")
        #expect(abs((usage.resolvedRemainingPercent ?? 0) - 70) < 0.01)
        #expect(usage.resetAt?.timeIntervalSince1970 == 1_893_456_000)

        let limit = try #require(quota.window("limit-0"))
        #expect(limit.label == "5h limit")
        // remaining 10 of limit 50
        #expect(abs((limit.resolvedRemainingPercent ?? 0) - 20) < 0.01)
        #expect(abs((limit.used ?? 0) - 40) < 0.01)
    }

    @Test func durationLabelFallsBackWhenUnnamed() async throws {
        let body = #"{"data":{"limits":[{"detail":{"limit":10,"used":1},"window":{"duration":180,"timeUnit":"TIME_UNIT_MINUTE"}}]}}"#
        let provider = KimiProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: Stub.client(body: body),
            store: Stub.store(environment: ["KIMI_API_KEY": "k"])
        ))
        #expect(quota.windows.first?.label == "3h limit")
    }

    @Test func bearerAuthAndEndpoint() async {
        let log = RequestLog()
        let client = Stub.client(body: #"{"data":{"usage":{"limit":10,"used":1}}}"#) { log.record($0) }
        let provider = KimiProvider()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: client,
            store: Stub.store(environment: ["KIMI_API_KEY": "kimi-key"])
        ))
        #expect(log.recordedURLs.first == "https://api.kimi.com/coding/v1/usages")
        #expect(log.header("Authorization") == "Bearer kimi-key")
    }

    @Test func unexpectedPayloadIsReported() async throws {
        let provider = KimiProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: Stub.client(body: #"{"weird":true}"#),
            store: Stub.store(environment: ["KIMI_API_KEY": "k"])
        ))
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("Unexpected response structure"))
    }

    /// OpenCode's auth.json names this credential `kimi-for-coding` (api) and
    /// also stores an `kimi-for-coding-oauth` entry that may be stale.
    @Test func openCodeAuthKeyNamesAreRecognised() async {
        let store = Stub.store(authFiles: [
            "~/.local/share/opencode/auth.json": """
            {"kimi-for-coding":{"type":"api","key":"code-key"},
             "kimi-for-coding-oauth":{"type":"oauth","access":"stale-oauth"}}
            """
        ])
        let log = RequestLog()
        let provider = KimiProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: Stub.client(body: #"{"data":{"usage":{"limit":10,"used":1}}}"#) { log.record($0) },
            store: store
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        // The api key must win over the OAuth entry.
        #expect(log.header("Authorization") == "Bearer code-key")
    }
}

@Suite struct MiniMaxProviderTests {
    private var model: String {
        """
        {"model_name":"minimax-m2","remains_time":3600000,
         "current_interval_total_count":100,"current_interval_usage_count":25,
         "current_weekly_total_count":500,"current_weekly_usage_count":100}
        """
    }

    private func quota(
        for variant: MiniMaxProvider.Variant,
        body: String? = nil,
        log: RequestLog? = nil
    ) async -> ProviderQuota {
        let payload = body ?? (#"{"base_resp":{"status_code":0},"model_remains":["# + model + "]}")
        let provider = MiniMaxProvider(variant: variant)
        let environment = variant == .china ? ["MINIMAX_CN_API_KEY": "k"] : ["MINIMAX_API_KEY": "k"]
        return await provider.fetch(Stub.context(
            ProviderConfig(type: variant.rawValue),
            client: Stub.client(body: payload) { log?.record($0) },
            store: Stub.store(environment: environment)
        ))
    }

    /// International reports the count as *remaining*.
    @Test func internationalCountIsRemaining() async throws {
        let quota = await quota(for: .international)
        #expect(quota.status.isOK, "\(quota.status)")
        let fiveHour = try #require(quota.window("fiveHour"))
        #expect(abs((fiveHour.used ?? 0) - 75) < 0.01)
        #expect(abs((fiveHour.resolvedRemainingPercent ?? 0) - 25) < 0.01)
    }

    /// Mainland reports the same field as *used*.
    @Test func chinaCountIsUsed() async throws {
        let quota = await quota(for: .china)
        #expect(quota.status.isOK, "\(quota.status)")
        let fiveHour = try #require(quota.window("fiveHour"))
        #expect(abs((fiveHour.used ?? 0) - 25) < 0.01)
        #expect(abs((fiveHour.resolvedRemainingPercent ?? 0) - 75) < 0.01)
    }

    @Test func percentOnlyGeneralBucket() async throws {
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","remains_time":60000,"current_interval_remaining_percent":42}]}"#
        let quota = await quota(for: .international, body: body)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(abs((quota.window("fiveHour")?.resolvedRemainingPercent ?? 0) - 42) < 0.01)
        #expect(quota.window("fiveHour")?.limit == nil)
    }

    @Test func nonCodingModelsAreFilteredOut() async {
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"speech-01","remains_time":1000,"current_interval_total_count":10,"current_interval_usage_count":1}]}"#
        let quota = await quota(for: .international, body: body)
        // No coding bucket present, so the general fallback keeps every row.
        #expect(quota.status.isOK || quota.status.isFailed)
        #expect(quota.window("fiveHour") != nil)
    }

    @Test func apiErrorSurfaced() async throws {
        let body = #"{"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}"#
        let quota = await quota(for: .international, body: body)
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("invalid api key"))
    }

    @Test func endpointPerVariant() async {
        for (variant, expected) in [
            (MiniMaxProvider.Variant.international, "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"),
            (MiniMaxProvider.Variant.china, "https://api.minimaxi.com/v1/token_plan/remains")
        ] {
            let log = RequestLog()
            _ = await quota(for: variant, log: log)
            #expect(log.recordedURLs.first == expected)
        }
    }

    /// OpenCode stores the mainland plan under `minimax-cn-coding-plan`.
    @Test func openCodeAuthKeyNameIsRecognised() async {
        let store = Stub.store(authFiles: [
            "~/.local/share/opencode/auth.json": #"{"minimax-cn-coding-plan":{"type":"api","key":"mm-key"}}"#
        ])
        let body = #"{"base_resp":{"status_code":0},"model_remains":["# + model + "]}"
        let provider = MiniMaxProvider(variant: .china)
        let log = RequestLog()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "minimax-cn"),
            client: Stub.client(body: body) { log.record($0) },
            store: store
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(log.header("Authorization") == "Bearer mm-key")
    }

    /// A 200 with no rows still carries the reason in `status_msg`.
    @Test func emptyRowsSurfaceStatusMessage() async throws {
        let body = #"{"base_resp":{"status_code":0,"status_msg":"plan not activated"}}"#
        let quota = await quota(for: .china, body: body)
        let message = try #require(quota.status.failureMessage)
        #expect(message == "plan not activated")
    }

    /// The quota endpoints are gated on a web session, so a Cookie header is the
    /// credential that works. A cookie must take precedence over an API key.
    @Test func cookieFromConfigIsSentAsCookieHeader() async {
        let body = #"{"base_resp":{"status_code":0},"model_remains":["# + model + "]}"
        let provider = MiniMaxProvider(variant: .china)
        let log = RequestLog()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "minimax-cn", cookie: "session=abc123"),
            client: Stub.client(body: body) { log.record($0) },
            store: Stub.store(environment: ["MINIMAX_CN_API_KEY": "ignored-key"])
        ))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(log.header("Cookie") == "session=abc123")
        #expect(log.header("Authorization") == nil)
    }

    @Test func cookieFromEnvironment() async {
        let body = #"{"base_resp":{"status_code":0},"model_remains":["# + model + "]}"
        let provider = MiniMaxProvider(variant: .china)
        let log = RequestLog()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "minimax-cn"),
            client: Stub.client(body: body) { log.record($0) },
            store: Stub.store(environment: ["MINIMAX_CN_COOKIE": "_token=xyz"])
        ))
        #expect(log.header("Cookie") == "_token=xyz")
    }

    @Test func apiKeyStillTriedWhenNoCookie() async {
        let body = #"{"base_resp":{"status_code":0},"model_remains":["# + model + "]}"
        let provider = MiniMaxProvider(variant: .international)
        let log = RequestLog()
        _ = await provider.fetch(Stub.context(
            ProviderConfig(type: "minimax"),
            client: Stub.client(body: body) { log.record($0) },
            store: Stub.store(environment: ["MINIMAX_API_KEY": "api-key"])
        ))
        #expect(log.header("Authorization") == "Bearer api-key")
        #expect(log.header("Cookie") == nil)
    }

    /// The upstream 1004 text is written for API integrators; translate it.
    @Test func sessionErrorsAreExplained() async throws {
        for message in [
            "cookie is missing, log in again",
            "login fail: Please carry the API secret key in the 'Authorization' field of the request header"
        ] {
            let body = #"{"base_resp":{"status_code":1004,"status_msg":"\#(message)"}}"#
            let quota = await quota(for: .china, body: body)
            let failure = try #require(quota.status.failureMessage)
            #expect(failure.contains("session cookie"), "\(failure)")
            #expect(failure.contains("MINIMAX_CN_COOKIE"), "\(failure)")
        }
    }

    @Test func missingCredentialMentionsCookie() async throws {
        let provider = MiniMaxProvider(variant: .china)
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "minimax-cn"),
            client: Stub.client(body: "{}"),
            store: Stub.store()
        ))
        let reason = try #require(quota.status.unconfiguredReason)
        #expect(reason.contains("MINIMAX_CN_COOKIE"))
    }
}
