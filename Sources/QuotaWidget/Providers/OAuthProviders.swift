import Foundation

/// ChatGPT subscription rate-limit windows (Plus / Pro / Business).
///
/// Uses the OAuth access token that Codex or OpenCode already stored, against
/// `https://chatgpt.com/backend-api/wham/usage`. The `ChatGPT-Account-Id`
/// header comes from the `chatgpt_account_id` claim in the access token.
struct OpenAIProvider: QuotaProvider {
    private static let endpoint = "https://chatgpt.com/backend-api/wham/usage"
    private static let authKeys = ["openai", "codex", "chatgpt"]

    var typeID: String { "openai" }
    var displayName: String { "OpenAI (ChatGPT)" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let credential = resolveCredential(context) else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Sign in with the Codex CLI, or add an `openai` OAuth entry to ~/.pi/agent/auth.json"
            )
        }

        if let expires = credential.expiresAt, expires < Date() {
            return .failed(id: id, name: name, error: "OAuth token expired — refresh it with the Codex CLI", credentialSource: credential.source)
        }

        var headers = ["Authorization": "Bearer \(credential.accessToken)"]
        if let accountID = credential.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }

        do {
            let payload = try await context.http.getJSON(context.config.baseUrl ?? Self.endpoint, headers: headers)

            var windows: [QuotaWindow] = []
            if let primary = Self.window(payload.path("rate_limit.primary_window"), id: "primary") {
                windows.append(primary)
            }
            if let secondary = Self.window(payload.path("rate_limit.secondary_window"), id: "secondary") {
                // Only keep a second window when it is a genuinely different one.
                if windows.first?.label != secondary.label { windows.append(secondary) }
            }

            var metrics: [QuotaMetric] = []
            if let limit = payload.path("spend_control.individual_limit"),
               let remaining = Parse.number(limit, ["remaining_percent"]) {
                metrics.append(QuotaMetric(
                    id: "spend-control",
                    label: "Spend control remaining",
                    value: QuotaFormat.percent(remaining)
                ))
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "No rate-limit windows for this account", credentialSource: credential.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: credential.planHint,
                account: credential.email,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: credential.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "OpenAI rejected the stored token — sign in again with the Codex CLI"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: credential.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: credential.source)
        }
    }

    /// The window kind is inferred from `limit_window_seconds`, since the API
    /// does not name its windows.
    private static func window(_ json: JSON?, id: String) -> QuotaWindow? {
        guard let json, json.exists else { return nil }
        guard let usedPercent = Parse.number(json, ["used_percent"]) else { return nil }

        let duration = Parse.number(json, ["limit_window_seconds"]) ?? 0
        let label: String
        switch duration {
        case 18_000: label = "5h"
        case 604_800: label = "1w"
        case 2_592_000: label = "1m"
        case 0: label = "Rate limit"
        default:
            let hours = duration / 3600
            label = hours >= 24 ? "\(Int(hours / 24))d window" : "\(Int(hours))h window"
        }

        let resetAt = TimeParse.date(fromEpoch: Parse.number(json, ["reset_at"]) ?? 0)
            ?? Parse.number(json, ["reset_after_seconds"]).flatMap { TimeParse.date(fromOffsetSeconds: $0) }

        return QuotaWindow(
            id: id,
            label: label,
            remainingPercent: min(100, max(0, 100 - usedPercent)),
            resetAt: resetAt,
            unit: "requests"
        )
    }

    // MARK: - Credentials

    private struct Credential {
        var accessToken: String
        var accountID: String?
        var email: String?
        var planHint: String?
        var expiresAt: Date?
        var source: String
    }

    private func resolveCredential(_ context: ProviderContext) -> Credential? {
        for key in Self.authKeys {
            guard let (entry, source) = context.credentials.rawAuthEntry(key: key) else { continue }
            let type = entry["type"]?.string
            guard type == nil || type == "oauth" else { continue }
            guard let token = entry["access"]?.string ?? entry["apiKey"]?.string, !token.isEmpty else { continue }
            return Credential(
                accessToken: token,
                accountID: entry["accountId"]?.string ?? Self.jwtClaim(token, "chatgpt_account_id"),
                email: Self.jwtClaim(token, "email"),
                planHint: Self.planHint(from: token),
                expiresAt: TimeParse.date(fromEpoch: entry["expires"]?.double ?? 0),
                source: source
            )
        }

        // Codex CLI layout: { tokens: { access_token, account_id } }
        if let (file, source) = context.credentials.rawAuthFile(containingAnyOf: ["tokens"]),
           let tokens = file.path("tokens"),
           let token = Parse.string(tokens, ["access_token"]) {
            return Credential(
                accessToken: token,
                accountID: Parse.string(tokens, ["account_id"]) ?? Self.jwtClaim(token, "chatgpt_account_id"),
                email: Self.jwtClaim(token, "email"),
                planHint: Self.planHint(from: token),
                expiresAt: nil,
                source: "\(source):tokens"
            )
        }
        return nil
    }

    private static func planHint(from token: String) -> String? {
        guard let plan = jwtPayload(token)?["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.string else {
            return nil
        }
        return "ChatGPT \(plan.capitalized)"
    }

    private static func jwtClaim(_ token: String, _ claim: String) -> String? {
        jwtPayload(token)?["https://api.openai.com/auth"]?[claim]?.string
            ?? jwtPayload(token)?[claim]?.string
    }

    /// Best-effort JWT payload decode; opaque tokens simply yield nil.
    static func jwtPayload(_ token: String) -> JSON? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSON.parse(data)
    }
}

/// Claude subscription usage (Pro / Max).
///
/// Uses the OAuth token stored by Claude Code or OpenCode against
/// `https://api.anthropic.com/api/oauth/usage`, which needs the
/// `anthropic-beta: oauth-2025-04-20` opt-in header.
struct AnthropicProvider: QuotaProvider {
    private static let endpoint = "https://api.anthropic.com/api/oauth/usage"
    private static let betaHeader = "oauth-2025-04-20"
    private static let authKeys = ["anthropic", "claude"]

    var typeID: String { "anthropic" }
    var displayName: String { "Claude" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let credential = resolveCredential(context) else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Run `claude` to sign in, or add an `anthropic` OAuth entry to ~/.pi/agent/auth.json"
            )
        }

        if let expires = credential.expiresAt, expires < Date() {
            return .failed(id: id, name: name, error: "OAuth token expired — run `claude` to refresh it", credentialSource: credential.source)
        }

        do {
            let payload = try await context.http.getJSON(context.config.baseUrl ?? Self.endpoint, headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "anthropic-beta": Self.betaHeader
            ])

            var windows: [QuotaWindow] = []
            if let window = Self.window(payload.path("five_hour"), id: "fiveHour", label: "5h") {
                windows.append(window)
            }
            if let window = Self.window(payload.path("seven_day"), id: "sevenDay", label: "1w (all models)") {
                windows.append(window)
            }
            // Model-scoped weekly windows (e.g. a separate Opus/Sonnet allowance).
            if let scoped = payload.path("seven_day_opus"), let window = Self.window(scoped, id: "sevenDayOpus", label: "1w (Opus)") {
                windows.append(window)
            }
            if let scoped = payload.path("seven_day_sonnet"), let window = Self.window(scoped, id: "sevenDaySonnet", label: "1w (Sonnet)") {
                windows.append(window)
            }
            for (index, entry) in (Parse.array(payload, ["rate_limits"]) ?? []).enumerated() {
                let label = Parse.string(entry, ["name", "scope"]) ?? "Limit #\(index + 1)"
                if let window = Self.window(entry, id: "rate-limit-\(index)", label: label) {
                    windows.append(window)
                }
            }

            var metrics: [QuotaMetric] = []
            if let extra = payload.path("extra_usage"), extra.exists,
               let used = Parse.number(extra, ["used_credits", "used"]) {
                let limit = Parse.number(extra, ["monthly_limit", "limit"])
                metrics.append(QuotaMetric(
                    id: "extra-usage",
                    label: "Extra usage",
                    value: limit.map { "$\(QuotaFormat.compact(used)) / $\(QuotaFormat.compact($0))" }
                        ?? "$\(QuotaFormat.compact(used))"
                ))
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "No usage windows for this account", credentialSource: credential.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: credential.plan,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: credential.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "Anthropic rejected the stored token — run `claude` to sign in again"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: credential.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: credential.source)
        }
    }

    /// `utilization` is the used share; tolerate the several aliases seen in the wild.
    private static func window(_ json: JSON?, id: String, label: String) -> QuotaWindow? {
        guard let json, json.exists else { return nil }
        guard let usedPercent = Parse.number(
            json,
            ["utilization", "used_percentage", "used_percent", "percent_used", "percentUsed"]
        ) else { return nil }

        return QuotaWindow(
            id: id,
            label: label,
            remainingPercent: min(100, max(0, 100 - usedPercent)),
            resetAt: Parse.string(json, ["resets_at", "resetsAt", "reset_at", "resetAt"])
                .flatMap { TimeParse.date(fromString: $0) },
            unit: "requests"
        )
    }

    private struct Credential {
        var accessToken: String
        var plan: String?
        var expiresAt: Date?
        var source: String
    }

    private func resolveCredential(_ context: ProviderContext) -> Credential? {
        // Claude Code writes ~/.claude/.credentials.json with camelCase keys.
        if let (file, source) = context.credentials.rawAuthFile(containingAnyOf: ["claudeAiOauth", "claudeAiOauthTokens"]),
           let oauth = file.path("claudeAiOauth") ?? file.path("claudeAiOauthTokens"),
           let token = Parse.string(oauth, ["accessToken", "access_token"]) {
            return Credential(
                accessToken: token,
                plan: Parse.string(oauth, ["subscriptionType", "subscription_type"]),
                expiresAt: TimeParse.date(fromEpoch: Parse.number(oauth, ["expiresAt", "expires_at"]) ?? 0),
                source: "\(source):claudeAiOauth"
            )
        }

        if let (entry, source) = context.credentials.rawAuthEntry(key: "anthropic"),
           let token = entry["access"]?.string ?? entry["apiKey"]?.string, !token.isEmpty {
            return Credential(
                accessToken: token,
                plan: entry["subscriptionType"]?.string,
                expiresAt: TimeParse.date(fromEpoch: entry["expires"]?.double ?? 0),
                source: source
            )
        }
        return nil
    }
}
