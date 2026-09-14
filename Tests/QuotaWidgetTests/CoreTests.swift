import Foundation
import Testing
@testable import QuotaWidget

@Suite struct TimeParseTests {
    @Test func epochSeconds() throws {
        let date = try #require(TimeParse.date(fromEpoch: 1_800_000_000))
        #expect(date.timeIntervalSince1970 == 1_800_000_000)
    }

    @Test func epochMilliseconds() throws {
        let date = try #require(TimeParse.date(fromEpoch: 1_800_000_000_000))
        #expect(date.timeIntervalSince1970 == 1_800_000_000)
    }

    @Test func zeroAndNegativeAreRejected() {
        #expect(TimeParse.date(fromEpoch: 0) == nil)
        #expect(TimeParse.date(fromEpoch: -5) == nil)
    }

    @Test func iso8601String() throws {
        let date = try #require(TimeParse.date(fromString: "2030-01-01T00:00:00Z"))
        #expect(date.timeIntervalSince1970 == 1_893_456_000)
    }

    @Test func numericStringIsTreatedAsEpoch() throws {
        let date = try #require(TimeParse.date(fromString: "1800000000"))
        #expect(date.timeIntervalSince1970 == 1_800_000_000)
    }

    @Test func relativeOffset() throws {
        let date = try #require(TimeParse.date(fromOffsetSeconds: 3600))
        #expect(abs(date.timeIntervalSinceNow - 3600) < 5)
    }

    @Test func garbageIsRejected() {
        #expect(TimeParse.date(fromString: "not a date") == nil)
    }

    /// Z.ai uses `nextResetTime` (epoch ms) while Kimi uses `reset_in` (seconds).
    @Test func absoluteWinsOverRelative() throws {
        let json = try JSON.parse(Data(#"{"resetAt": 4102444800, "reset_in": 60}"#.utf8))
        let date = try #require(TimeParse.reset(in: json, absolute: ["resetAt"], relative: ["reset_in"]))
        #expect(date.timeIntervalSince1970 == 4_102_444_800)
    }

    @Test func relativeUsedWhenAbsoluteMissing() throws {
        let json = try JSON.parse(Data(#"{"reset_in": 120}"#.utf8))
        let date = try #require(TimeParse.reset(in: json, absolute: ["resetAt"], relative: ["reset_in"]))
        #expect(abs(date.timeIntervalSinceNow - 120) < 5)
    }
}

@Suite struct JSONTests {
    private func parse(_ text: String) throws -> JSON {
        try JSON.parse(Data(text.utf8))
    }

    @Test func pathTraversalWithArrayIndex() throws {
        let json = try parse(#"{"data":{"limits":[{"type":"TOKENS_LIMIT"}]}}"#)
        #expect(json.string(at: "data.limits.0.type") == "TOKENS_LIMIT")
    }

    @Test func missingPathReturnsNil() throws {
        let json = try parse(#"{"a":1}"#)
        #expect(json.path("a.b.c") == nil)
    }

    /// `false` bridges to NSNumber; it must not be read as the number 0.
    @Test func booleanIsNotANumber() throws {
        let json = try parse(#"{"success":false,"count":0}"#)
        #expect(json["success"]?.bool == false)
        #expect(json["success"]?.double == nil)
        #expect(json["count"]?.double == 0)
    }

    @Test func numericStringCoercion() throws {
        let json = try parse(#"{"limit":"1200"}"#)
        #expect(json["limit"]?.double == 1200)
    }

    @Test func firstMatchingPointerWins() throws {
        let json = try parse(#"{"a":{"used":4}}"#)
        #expect(json.firstDouble(["b.used", "a.used"]) == 4)
    }

    @Test func nullIsNotPresent() throws {
        let json = try parse(#"{"value":null}"#)
        #expect(json["value"]?.exists == false)
    }
}

@Suite struct CredentialTests {
    @Test func variableExpansion() {
        let environment = ["MY_KEY": "secret"]
        #expect(CredentialStore.expandVariables("Bearer ${MY_KEY}", environment: environment) == "Bearer secret")
        #expect(CredentialStore.expandVariables("Bearer $MY_KEY", environment: environment) == "Bearer secret")
        #expect(CredentialStore.expandVariables("${MY_KEY}x", environment: environment) == "secretx")
    }

    @Test func unknownVariableCollapsesToEmpty() {
        #expect(CredentialStore.expandVariables("${NOPE}", environment: [:]) == "")
    }

    @Test func malformedBraceIsLeftAlone() {
        #expect(CredentialStore.expandVariables("${UNCLOSED", environment: [:]) == "${UNCLOSED")
    }

    @Test func configKeyBeatsEnvironment() {
        let store = Stub.store(environment: ["ZAI_API_KEY": "from-env"])
        let config = ProviderConfig(type: "zai", apiKey: "from-config")
        #expect(store.resolve(config: config, envNames: ["ZAI_API_KEY"])?.value == "from-config")
    }

    @Test func apiKeyEnvBeatsProviderDefaultList() {
        let store = Stub.store(environment: ["SPECIFIC": "specific", "ZAI_API_KEY": "generic"])
        let config = ProviderConfig(type: "zai", apiKeyEnv: "SPECIFIC")
        let found = store.resolve(config: config, envNames: ["ZAI_API_KEY"])
        #expect(found?.value == "specific")
        #expect(found?.source == "env:SPECIFIC")
    }

    @Test func apiKeySupportsVariableReference() {
        let store = Stub.store(environment: ["REAL": "resolved"])
        let config = ProviderConfig(type: "custom", apiKey: "${REAL}")
        #expect(store.resolve(config: config, envNames: [])?.value == "resolved")
    }

    @Test func oauthEntryUsesAccessToken() {
        let store = Stub.store(authFiles: [
            "~/.pi/agent/auth.json": #"{"anthropic":{"type":"oauth","access":"sk-oauth"}}"#
        ])
        #expect(store.authValue(keys: ["anthropic"])?.value == "sk-oauth")
    }

    @Test func apiEntryUsesKey() {
        let store = Stub.store(authFiles: [
            "~/.pi/agent/auth.json": #"{"zai-coding-plan":{"type":"api","key":"z-key"}}"#
        ])
        #expect(store.authValue(keys: ["zai-coding-plan"])?.value == "z-key")
    }

    @Test func typeFilterSkipsMismatchedEntries() {
        let store = Stub.store(authFiles: [
            "auth.json": #"{"openai":{"type":"api","key":"nope"}}"#
        ])
        #expect(store.authValue(keys: ["openai"], typeFilter: "oauth") == nil)
    }

    @Test func headersDropUnresolvedValues() {
        let store = Stub.store(environment: ["TOKEN": "t"])
        let headers = store.expandHeaders(["Authorization": "Bearer ${TOKEN}", "X-Empty": "${MISSING}"])
        #expect(headers["Authorization"] == "Bearer t")
        #expect(headers["X-Empty"] == nil)
    }

    @Test func commandCodeAuthFileShapes() throws {
        let store = Stub.store(authFiles: [
            "~/.commandcode/auth.json": #"{"commandcode":{"type":"api","key":"user_abc"}}"#
        ])
        let entry = try #require(store.rawAuthEntry(key: "commandcode"))
        #expect(CredentialStore.credentialString(entry.json) == "user_abc")
    }

    @Test func flatCommandCodeAuthFileShape() throws {
        let store = Stub.store(authFiles: [
            "~/.commandcode/auth.json": #"{"apiKey":"user_flat"}"#
        ])
        let entry = try #require(store.rawAuthEntry(key: "apiKey"))
        #expect(entry.json.string == "user_flat")
    }
}

@Suite struct ErrorBodyTests {
    /// Providers bury the readable text in different fields; the panel should
    /// show a sentence rather than a raw JSON blob.
    @Test func extractsCommonMessageFields() {
        #expect(HTTPClient.messageFromErrorBody(#"{"message":"insufficient balance"}"#) == "insufficient balance")
        #expect(HTTPClient.messageFromErrorBody(#"{"msg":"token expired"}"#) == "token expired")
        #expect(HTTPClient.messageFromErrorBody(#"{"error":{"message":"bad key"}}"#) == "bad key")
        #expect(HTTPClient.messageFromErrorBody(#"{"detail":"not found"}"#) == "not found")
        #expect(HTTPClient.messageFromErrorBody(#"{"base_resp":{"status_msg":"invalid api key"}}"#) == "invalid api key")
    }

    @Test func returnsNilWhenNothingUsable() {
        #expect(HTTPClient.messageFromErrorBody("not json at all") == nil)
        #expect(HTTPClient.messageFromErrorBody(#"{"unrelated":1}"#) == nil)
        #expect(HTTPClient.messageFromErrorBody(#"{"message":"   "}"#) == nil)
    }

    @Test func statusErrorUsesExtractedMessage() async throws {
        let provider = KimiProvider()
        let quota = await provider.fetch(Stub.context(
            ProviderConfig(type: "kimi"),
            client: Stub.client(
                status: 429,
                body: #"{"code":"resource_exhausted","message":"insufficient balance"}"#
            ),
            store: Stub.store(environment: ["KIMI_API_KEY": "k"])
        ))
        let message = try #require(quota.status.failureMessage)
        #expect(message == "HTTP 429: insufficient balance")
    }
}

@Suite struct RegistryTests {    /// Regression: two variants of one provider type previously collided on a
    /// static type id and crashed the registry dictionary.
    @Test func variantProvidersHaveDistinctIDs() {
        #expect(ProviderRegistry.provider(for: "zai") != nil)
        #expect(ProviderRegistry.provider(for: "zhipu") != nil)
        #expect(ProviderRegistry.provider(for: "minimax") != nil)
        #expect(ProviderRegistry.provider(for: "minimax-cn") != nil)
    }

    @Test func registryNamesAreDistinct() {
        let names = ProviderRegistry.knownTypeIDs.map { ProviderRegistry.defaultName(for: $0) }
        #expect(Set(names).count == names.count, "duplicate display names: \(names)")
    }

    @Test func everyKnownTypeResolvesWithoutCrashing() {
        for id in ProviderRegistry.knownTypeIDs {
            #expect(ProviderRegistry.provider(for: id) != nil, "\(id) missing from registry")
        }
    }

    @Test func unknownTypeHasNoProvider() {
        #expect(ProviderRegistry.provider(for: "nope") == nil)
        #expect(ProviderRegistry.defaultName(for: "nope") == "nope")
    }

    @Test func defaultConfigOnlyEnablesKnownTypes() {
        for provider in QuotaWidgetConfig.default.providers {
            #expect(
                ProviderRegistry.provider(for: provider.type) != nil,
                "default config references unknown type '\(provider.type)'"
            )
        }
    }
}
