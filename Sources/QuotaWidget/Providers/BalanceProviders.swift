import Foundation

/// DeepSeek prepaid balance.
///
/// `GET https://api.deepseek.com/user/balance` with a Bearer key. There is no
/// quota window here, only per-currency balances.
struct DeepSeekProvider: QuotaProvider {
    private static let endpoint = "https://api.deepseek.com/user/balance"
    private static let envNames = ["DEEPSEEK_API_KEY"]
    private static let authKeys = ["deepseek"]

    var typeID: String { "deepseek" }
    var displayName: String { "DeepSeek" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = context.credentials.resolve(config: context.config, envNames: Self.envNames)
            ?? context.credentials.authValue(keys: Self.authKeys) else {
            return .notConfigured(id: id, name: name, reason: "Set DEEPSEEK_API_KEY to a DeepSeek key")
        }

        let endpoint = context.config.baseUrl ?? Self.endpoint
        do {
            let payload = try await context.http.getJSON(endpoint, headers: [
                "Authorization": "Bearer \(key.value)"
            ])

            guard let infos = Parse.array(payload, ["balance_infos"]) else {
                return .failed(id: id, name: name, error: "Unexpected response structure", credentialSource: key.source)
            }

            let available = payload["is_available"]?.bool
            var metrics: [QuotaMetric] = []
            for (index, info) in infos.enumerated() {
                let currency = Parse.string(info, ["currency"]) ?? "CNY"
                guard let total = Parse.number(info, ["total_balance"]) else { continue }
                var detail: [String] = []
                if let granted = Parse.number(info, ["granted_balance"]) {
                    detail.append("granted \(QuotaFormat.compact(granted))")
                }
                if let toppedUp = Parse.number(info, ["topped_up_balance"]) {
                    detail.append("topped up \(QuotaFormat.compact(toppedUp))")
                }
                metrics.append(QuotaMetric(
                    id: "balance-\(index)",
                    label: "Balance (\(currency))",
                    value: QuotaFormat.compact(total),
                    detail: detail.isEmpty ? nil : detail.joined(separator: " · ")
                ))
            }

            if metrics.isEmpty {
                let state = available == false ? "Account is not available" : "No balance reported"
                return .failed(id: id, name: name, error: state, credentialSource: key.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "DeepSeek rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }
}

/// OpenRouter key budget.
///
/// `GET https://openrouter.ai/api/v1/key` with a Bearer key returns the key's
/// spend limit and usage.
struct OpenRouterProvider: QuotaProvider {
    private static let endpoint = "https://openrouter.ai/api/v1/key"
    private static let envNames = ["OPENROUTER_API_KEY"]
    private static let authKeys = ["openrouter"]

    var typeID: String { "openrouter" }
    var displayName: String { "OpenRouter" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = context.credentials.resolve(config: context.config, envNames: Self.envNames)
            ?? context.credentials.authValue(keys: Self.authKeys) else {
            return .notConfigured(id: id, name: name, reason: "Set OPENROUTER_API_KEY to an OpenRouter key")
        }

        let endpoint = context.config.baseUrl ?? Self.endpoint
        do {
            let payload = try await context.http.getJSON(endpoint, headers: [
                "Authorization": "Bearer \(key.value)"
            ])
            let data = payload["data"] ?? payload

            let limit = Parse.number(data, ["limit"])
            let usage = Parse.number(data, ["usage"])
            let limitRemaining = Parse.number(data, ["limit_remaining"])

            var windows: [QuotaWindow] = []
            var metrics: [QuotaMetric] = []

            if let limit, limit > 0 {
                let spent = usage ?? max(0, limit - (limitRemaining ?? limit))
                windows.append(QuotaWindow(
                    id: "budget",
                    label: "Budget",
                    used: spent,
                    limit: limit,
                    unit: "USD"
                ))
            }

            if let usage {
                metrics.append(QuotaMetric(
                    id: "spend",
                    label: "Total spend",
                    value: "$" + String(format: "%.2f", usage)
                ))
            }
            if limit == nil, let limitRemaining {
                metrics.append(QuotaMetric(
                    id: "remaining",
                    label: "Credits remaining",
                    value: "$" + String(format: "%.2f", limitRemaining)
                ))
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "No usage data for this key", credentialSource: key.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: Parse.string(data, ["label"]),
                account: Parse.string(data, ["name"]),
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "OpenRouter rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }
}
