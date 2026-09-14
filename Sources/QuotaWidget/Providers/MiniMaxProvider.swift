import Foundation

/// MiniMax Token Plan / Coding Plan.
///
/// `model_remains[]` holds one record per model bucket. The two endpoints
/// disagree on `current_interval_usage_count`: the international API reports
/// the *remaining* count, the mainland one the *used* count.
struct MiniMaxProvider: QuotaProvider {
    enum Variant: String {
        /// Raw value doubles as the provider type in `config.json`.
        case international = "minimax"
        case china = "minimax-cn"

        var endpoint: String {
            switch self {
            case .international: return "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
            case .china: return "https://api.minimaxi.com/v1/token_plan/remains"
            }
        }

        var displayName: String {
            switch self {
            case .international: return "MiniMax Token Plan"
            case .china: return "MiniMax Token Plan (CN)"
            }
        }

        /// The count field means "remaining" internationally, "used" in China.
        var countIsUsed: Bool { self == .china }

        var cookieEnvNames: [String] {
            switch self {
            case .international: return ["MINIMAX_COOKIE", "MINIMAX_SESSION"]
            case .china: return ["MINIMAX_CN_COOKIE", "MINIMAX_COOKIE", "MINIMAX_SESSION"]
            }
        }

        /// Credential names in `config.json` that may carry a `cookie` field.
        var cookieCredentialNames: [String] {
            authKeys + ["minimax-cn-coding-plan", "minimax-china-coding-plan", "minimax-coding-plan"]
        }

        var envNames: [String] {
            switch self {
            case .international: return ["MINIMAX_API_KEY", "MINIMAX_TOKEN_PLAN_API_KEY", "MINIMAX_CODING_PLAN_API_KEY"]
            case .china: return ["MINIMAX_CN_API_KEY", "MINIMAX_CHINA_CODING_PLAN_API_KEY"]
            }
        }

        var authKeys: [String] {
            switch self {
            case .international:
                return ["minimax", "minimax-token-plan", "minimax-coding-plan"]
            case .china:
                // OpenCode writes the mainland plan under a longer key name.
                return ["minimax-cn-coding-plan", "minimax-china-coding-plan", "minimax-cn", "minimax-china"]
            }
        }
    }

    let variant: Variant

    var typeID: String { variant.rawValue }
    var displayName: String { variant.displayName }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        // These endpoints are gated on the platform web session, so a Cookie
        // header is the credential that actually works; an API key is accepted
        // as a first attempt because some plans do authenticate with one.
        let cookie = context.credentials.resolveCookie(
            config: context.config,
            envNames: variant.cookieEnvNames,
            names: variant.cookieCredentialNames
        )
        let key = context.credentials.resolve(config: context.config, envNames: variant.envNames)
            ?? context.credentials.authValue(keys: variant.authKeys)

        guard cookie != nil || key != nil else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Set \(variant.cookieEnvNames[0]) to the platform cookie, or \(variant.envNames[0]) to an API key"
            )
        }

        var headers: [String: String] = [:]
        var credentialSource: String?
        if let cookie {
            headers["Cookie"] = cookie.value
            credentialSource = cookie.source
        } else if let key {
            headers["Authorization"] = "Bearer \(key.value)"
            credentialSource = key.source
        }

        let endpoint = context.config.baseUrl ?? variant.endpoint
        do {
            let payload = try await context.http.getJSON(endpoint, headers: headers)

            if let code = Parse.number(payload, ["base_resp.status_code"]), code != 0 {
                let message = Parse.string(payload, ["base_resp.status_msg"]) ?? "unknown"
                return .failed(
                    id: id,
                    name: name,
                    error: Self.explain(code: code, message: message, variant: variant),
                    credentialSource: credentialSource
                )
            }

            let models = Parse.array(payload, ["model_remains", "data.model_remains"]) ?? []
            // A 200 with no rows still carries the reason in status_msg.
            if models.isEmpty {
                let note = Parse.string(payload, ["base_resp.status_msg"])
                return .failed(
                    id: id,
                    name: name,
                    error: note ?? "No quota windows in the response"
                )
            }
            let relevant = models.filter { Self.isCodingBucket($0) }
            let candidates = relevant.isEmpty ? models : relevant

            var windows: [QuotaWindow] = []
            var metrics: [QuotaMetric] = []

            for model in candidates {
                if let window = Self.window(
                    from: model,
                    id: "fiveHour",
                    label: "5h",
                    totalPaths: ["current_interval_total_count"],
                    countPaths: ["current_interval_usage_count"],
                    percentPaths: ["current_interval_remaining_percent"],
                    resetPaths: ["remains_time"],
                    countIsUsed: variant.countIsUsed
                ) {
                    windows.append(window)
                }
                if let window = Self.window(
                    from: model,
                    id: "weekly",
                    label: "1w",
                    totalPaths: ["current_weekly_total_count"],
                    countPaths: ["current_weekly_usage_count"],
                    percentPaths: ["current_weekly_remaining_percent"],
                    resetPaths: ["weekly_remains_time"],
                    countIsUsed: variant.countIsUsed
                ) {
                    windows.append(window)
                }
            }

            if let general = candidates.first(where: { ($0["model_name"]?.string ?? "").lowercased() == "general" }) {
                let start = Parse.number(general, ["start_time"])
                let end = Parse.number(general, ["end_time"])
                if let start, let end, end > start {
                    metrics.append(QuotaMetric(
                        id: "cycle",
                        label: "Plan cycle",
                        value: QuotaFormat.countdown(to: Date(timeIntervalSince1970: end / 1000)),
                        detail: "started \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: start / 1000), dateStyle: .medium, timeStyle: .none))"
                    ))
                }
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "No quota windows in the response", credentialSource: credentialSource)
            }

            return ProviderQuota(
                id: id,
                name: name,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: credentialSource
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "MiniMax rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: credentialSource)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: credentialSource)
        }
    }

    /// MiniMax answers 1004 with a message aimed at API integrators. Translate
    /// the auth ones into something a user can act on.
    private static func explain(code: Double, message: String, variant: Variant) -> String {
        let lowered = message.lowercased()
        if lowered.contains("cookie is missing") || lowered.contains("login fail") {
            return "Needs a platform session cookie — sign in at minimax\(variant == .china ? "i" : "").com, then set \(variant.cookieEnvNames[0]) to the Cookie header value"
        }
        return "MiniMax error \(Int(code)): \(message)"
    }

    /// Rows for other models share the plan allowance; only coding buckets are meaningful.
    private static func isCodingBucket(_ model: JSON) -> Bool {
        let name = (Parse.string(model, ["model_name"]) ?? "").lowercased()
        if name == "general" { return true }
        return name.hasPrefix("minimax-m")
    }

    private static func window(
        from model: JSON,
        id: String,
        label: String,
        totalPaths: [String],
        countPaths: [String],
        percentPaths: [String],
        resetPaths: [String],
        countIsUsed: Bool
    ) -> QuotaWindow? {
        let reset = Self.number(model, resetPaths)
        let resetAt = reset.flatMap { TimeParse.date(fromOffsetSeconds: $0) }

        if let total = Self.number(model, totalPaths), total > 0,
           let rawCount = Self.number(model, countPaths) {
            let used = countIsUsed ? max(0, rawCount) : max(0, total - min(total, rawCount))
            return QuotaWindow(
                id: id,
                label: label,
                used: used,
                limit: total,
                resetAt: resetAt,
                unit: "requests"
            )
        }

        // Newer plans expose only a percentage for the general bucket.
        guard let percent = Self.number(model, percentPaths) else { return nil }
        return QuotaWindow(
            id: id,
            label: label,
            remainingPercent: min(100, max(0, percent)),
            resetAt: resetAt,
            unit: "requests"
        )
    }

    private static func number(_ json: JSON, _ pointers: [String]) -> Double? {
        for pointer in pointers {
            if let value = json.path(pointer)?.double { return value }
        }
        return nil
    }
}
