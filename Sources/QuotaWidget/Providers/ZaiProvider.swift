import Foundation

/// GLM Coding Plan quota, shared by the international (Z.ai) and mainland
/// (Zhipu / bigmodel.cn) endpoints — both return the same `limits` payload.
///
/// `GET {endpoint}` with the raw API key in `Authorization` (no `Bearer`
/// prefix), responding with `data.limits[]` where `type` is `TOKENS_LIMIT`,
/// `CREDIT_LIMIT` or `TIME_LIMIT`, `unit` 3 is the 5-hour window and 6 the
/// weekly one, and `percentage` is the *used* share.
struct ZaiProvider: QuotaProvider {
    enum Variant: String {
        case zai
        case zhipu

        var endpoint: String {
            switch self {
            case .zai: return "https://api.z.ai/api/monitor/usage/quota/limit"
            case .zhipu: return "https://bigmodel.cn/api/monitor/usage/quota/limit"
            }
        }

        var displayName: String {
            switch self {
            case .zai: return "Z.ai Coding Plan"
            case .zhipu: return "Zhipu Coding Plan"
            }
        }

        var envNames: [String] {
            switch self {
            case .zai: return ["ZAI_API_KEY", "ZAI_CODING_PLAN_API_KEY", "GLM_API_KEY"]
            case .zhipu: return ["ZHIPU_API_KEY", "ZHIPUAI_API_KEY", "BIGMODEL_API_KEY", "GLM_API_KEY"]
            }
        }

        var authKeys: [String] {
            switch self {
            case .zai: return ["zai-coding-plan", "zai", "glm"]
            case .zhipu: return ["zhipu-coding-plan", "zhipu", "bigmodel", "glm"]
            }
        }
    }

    let variant: Variant

    var typeID: String { variant.rawValue }
    var displayName: String { variant.displayName }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = resolveKey(context) else {
            let hint = variant == .zai ? "ZAI_API_KEY" : "ZHIPU_API_KEY"
            return .notConfigured(id: id, name: name, reason: "Set \(hint) to a GLM Coding Plan key")
        }

        let endpoint = context.config.baseUrl ?? variant.endpoint
        // Z.ai reads the bare key; keep an escape hatch for gateways that want Bearer.
        let scheme = context.config.authScheme ?? "raw"
        let authorization = scheme == "bearer" ? "Bearer \(key.value)" : key.value
        let headers = [
            "Authorization": authorization,
            "Content-Type": "application/json"
        ]

        do {
            let payload = try await context.http.getJSON(endpoint, headers: headers)

            if payload["success"]?.bool == false || (payload["code"]?.double ?? 0) >= 400 {
                // The card already shows the provider name, so only the API text here.
                let message = Parse.string(payload, ["msg", "message"]) ?? "request rejected"
                return .failed(id: id, name: name, error: message, credentialSource: key.source)
            }

            let limits = Parse.array(payload, ["data.limits", "limits"]) ?? []
            var windows: [QuotaWindow] = []
            for (index, limit) in limits.enumerated() {
                guard let window = Self.window(from: limit, index: index) else { continue }
                windows.append(windows.contains { $0.id == window.id }
                    ? QuotaWindow(
                        id: "\(window.id)-\(index)",
                        label: window.label,
                        used: window.used,
                        limit: window.limit,
                        remainingPercent: window.remainingPercent,
                        resetAt: window.resetAt,
                        unit: window.unit
                    )
                    : window)
            }
            if windows.isEmpty {
                return .failed(id: id, name: name, error: "No quota windows in the response", credentialSource: key.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: Parse.string(payload, ["data.planName", "data.plan", "plan"]),
                windows: windows,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "\(displayName) rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }

    private func resolveKey(_ context: ProviderContext) -> CredentialStore.Located? {
        context.credentials.resolve(config: context.config, envNames: variant.envNames)
            ?? context.credentials.authValue(keys: variant.authKeys)
    }

    private static func window(from limit: JSON, index: Int) -> QuotaWindow? {
        let type = limit["type"]?.string?.uppercased() ?? ""
        let unit = limit["unit"]?.double
        // `percentage` is the consumed share; convert to remaining for display.
        guard let usedPercent = Parse.number(limit, ["percentage", "usedPercent", "used_percent"]) else {
            return nil
        }

        let label: String
        let identifier: String
        switch (type, unit) {
        case ("TIME_LIMIT", _):
            label = "Tools (MCP)"
            identifier = "mcp"
        case (_, .some(3)):
            label = "5h"
            identifier = "fiveHour"
        case (_, .some(6)):
            label = "1w"
            identifier = "weekly"
        default:
            label = type.isEmpty ? "Limit #\(index + 1)" : type.replacingOccurrences(of: "_", with: " ").capitalized
            identifier = "limit-\(index)"
        }

        return QuotaWindow(
            id: identifier,
            label: label,
            used: Parse.number(limit, ["currentValue", "used", "usage"]),
            limit: Parse.number(limit, ["total", "limit", "cap"]),
            remainingPercent: min(100, max(0, 100 - usedPercent)),
            resetAt: TimeParse.reset(
                in: limit,
                absolute: ["nextResetTime", "resetAt", "resetTime"],
                relative: ["reset_in", "resetIn"]
            ),
            unit: "requests"
        )
    }
}
