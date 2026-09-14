import Foundation
import Testing
@testable import QuotaWidget

@Suite struct OpenCodeGoProviderTests {
    private let usage = """
    {"usage":{
      "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-14T15:55:00.000Z"},
      "weekly":{"status":"ok","percent":100,"resetsAt":"2026-09-21T08:00:00.000Z"},
      "monthly":{"status":"ok","percent":74,"resetsAt":"2026-09-24T08:00:00.000Z"}
    }}
    """

    private func quota(
        store: CredentialStore,
        body: String? = nil,
        status: Int = 200,
        log: RequestLog? = nil
    ) async -> ProviderQuota {
        let provider = OpenCodeGoProvider()
        return await provider.fetch(Stub.context(
            ProviderConfig(type: "opencode-go"),
            client: Stub.client(status: status, body: body ?? usage) { log?.record($0) },
            store: store
        ))
    }

    @Test func percentIsUsedShare() async throws {
        let quota = await quota(store: Stub.store(environment: ["OPENCODE_API_KEY": "k"]))
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.count == 3)

        let fiveHour = try #require(quota.window("rolling"))
        #expect(fiveHour.label == "5h")
        #expect(fiveHour.resolvedRemainingPercent == 100)

        let weekly = try #require(quota.window("weekly"))
        #expect(weekly.resolvedRemainingPercent == 0)

        let monthly = try #require(quota.window("monthly"))
        #expect(abs((monthly.resolvedRemainingPercent ?? 0) - 26) < 0.01)
        #expect(monthly.resetAt != nil)
    }

    @Test func authFileAndEndpoint() async {
        let store = Stub.store(authFiles: [
            "~/.local/share/opencode/auth.json": #"{"opencode-go":{"type":"api","key":"og-key"}}"#
        ])
        let log = RequestLog()
        let quota = await quota(store: store, log: log)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(log.recordedURLs.first == "https://opencode.ai/zen/go/v1/usage")
        #expect(log.header("Authorization") == "Bearer og-key")
        // The endpoint is behind Cloudflare, which blocks requests without a UA.
        #expect(log.header("User-Agent")?.isEmpty == false)
    }

    /// A window the API flags as not-ok is reported, not silently dropped.
    @Test func degradedWindowIsSurfaced() async throws {
        let body = """
        {"usage":{
          "rolling":{"status":"ok","percent":10,"resetsAt":"2026-09-14T15:55:00Z"},
          "weekly":{"status":"error","percent":0,"resetsAt":"2026-09-21T08:00:00Z"}
        }}
        """
        let quota = await quota(store: Stub.store(environment: ["OPENCODE_API_KEY": "k"]), body: body)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(quota.windows.count == 1)
        #expect(quota.metrics.contains { $0.label == "Unavailable" })
    }

    @Test func noUsableWindowsFails() async throws {
        let body = #"{"usage":{"weekly":{"status":"error"}}}"#
        let quota = await quota(store: Stub.store(environment: ["OPENCODE_API_KEY": "k"]), body: body)
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("1w: error"))
    }

    @Test func missingCredentialIsUnconfigured() async throws {
        let quota = await quota(store: Stub.store())
        let reason = try #require(quota.status.unconfiguredReason)
        #expect(reason.contains("OPENCODE_API_KEY"))
    }

    @Test func cloudflareBlockIsReportedAsAuthFailure() async throws {
        let body = #"{"title":"Error 1010: Access denied","status":403}"#
        let quota = await quota(store: Stub.store(environment: ["OPENCODE_API_KEY": "k"]), body: body, status: 403)
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("rejected the API key"), "\(message)")
    }

    @Test func credentialSourceIsReportedOnFailure() async {
        let store = Stub.store(environment: ["OPENCODE_API_KEY": "k"])
        let quota = await quota(store: store, body: #"{"usage":{}}"#)
        #expect(quota.credentialSource == "env:OPENCODE_API_KEY")
    }
}

@Suite struct OllamaCloudProviderTests {
    private let usage = """
    {"activity":{"cost":"0.00000","period":{"type":"last_4_weeks",
                  "starting_at":"2026-08-24T02:00:00Z","ending_at":"2026-09-14T02:00:00Z"},
                 "models":[]},
     "limits":{"session":{"usage":0.1,"models":[{"model":"deepseek-v4.1-flash"},{"model":"deepseek-v4-flash:0731"}]},
               "weekly":{"usage":0.02,"models":[{"model":"deepseek-v4.1-flash"}]}}}
    """

    private func quota(
        store: CredentialStore,
        body: String? = nil,
        log: RequestLog? = nil
    ) async -> ProviderQuota {
        let provider = OllamaCloudProvider()
        return await provider.fetch(Stub.context(
            ProviderConfig(type: "ollama-cloud"),
            client: Stub.client(body: body ?? usage) { log?.record($0) },
            store: store
        ))
    }

    @Test func usageFractionBecomesRemainingPercent() async throws {
        let quota = await quota(store: Stub.store(environment: ["OLLAMA_API_KEY": "k"]))
        #expect(quota.status.isOK, "\(quota.status)")

        let session = try #require(quota.window("session"))
        #expect(session.label == "Session")
        #expect(abs((session.resolvedRemainingPercent ?? 0) - 90) < 0.01)

        let weekly = try #require(quota.window("weekly"))
        #expect(abs((weekly.resolvedRemainingPercent ?? 0) - 98) < 0.01)
    }

    /// The API documents a 0…1 fraction; a bare percentage is handled too.
    @Test func percentageIsAcceptedDefensively() async throws {
        let body = #"{"limits":{"session":{"usage":35}}}"#
        let quota = await quota(store: Stub.store(environment: ["OLLAMA_API_KEY": "k"]), body: body)
        let session = try #require(quota.window("session"))
        #expect(abs((session.resolvedRemainingPercent ?? 0) - 65) < 0.01)
    }

    @Test func metricsDescribeModelsCostAndPeriod() async throws {
        let quota = await quota(store: Stub.store(environment: ["OLLAMA_API_KEY": "k"]))
        #expect(quota.metric("models")?.value == "2")
        #expect(quota.metric("models")?.detail?.contains("deepseek-v4.1-flash") == true)
        // "0.00000" from the API is rendered as a readable amount.
        #expect(quota.metric("cost")?.value == "$0.00")

        let period = try #require(quota.metric("period"))
        #expect(period.value == "Aug 24 – Sep 14")
        #expect(period.detail == "last 4 weeks")
    }

    /// A trailing window has no reset, so no countdown is shown.
    @Test func trailingPeriodHasNoCountdown() async throws {
        let quota = await quota(store: Stub.store(environment: ["OLLAMA_API_KEY": "k"]))
        let period = try #require(quota.metric("period"))
        #expect(!period.value.contains("resets"))
        #expect(period.detail?.contains("reset") != true)
    }

    @Test func authFileAndEndpoint() async {
        let store = Stub.store(authFiles: [
            "~/.local/share/opencode/auth.json": #"{"ollama-cloud":{"type":"api","key":"ol-key"}}"#
        ])
        let log = RequestLog()
        let quota = await quota(store: store, log: log)
        #expect(quota.status.isOK, "\(quota.status)")
        #expect(log.recordedURLs.first == "https://ollama.com/api/usage")
        #expect(log.header("Authorization") == "Bearer ol-key")
    }

    @Test func missingCredentialIsUnconfigured() async throws {
        let quota = await quota(store: Stub.store())
        let reason = try #require(quota.status.unconfiguredReason)
        #expect(reason.contains("OLLAMA_API_KEY"))
    }

    @Test func emptyPayloadFails() async throws {
        let quota = await quota(
            store: Stub.store(environment: ["OLLAMA_API_KEY": "k"]),
            body: #"{"limits":{}}"#
        )
        let message = try #require(quota.status.failureMessage)
        #expect(message.contains("No usage limits"))
    }

    @Test func costFormattingKeepsSmallAmountsVisible() {
        // Sub-cent spend should not round away to $0.00.
        #expect(OllamaCloudProvider.currency("0.00234") == "$0.0023")
        #expect(OllamaCloudProvider.currency("1.5") == "$1.50")
        #expect(OllamaCloudProvider.currency("$4.2") == "$4.20")
    }
}
