import Foundation

/// Kimi Code (Moonshot) subscription usage.
///
/// `GET https://api.kimi.com/coding/v1/usages` with a Bearer key. The payload
/// carries a top-level `usage` window plus a `limits[]` array whose entries
/// nest the interesting numbers under `detail`.
struct KimiProvider: QuotaProvider {
    private static let endpoint = "https://api.kimi.com/coding/v1/usages"
    private static let envNames = ["KIMI_API_KEY", "MOONSHOT_API_KEY", "KIMI_CODING_PLAN_API_KEY"]
    /// Covers the key names used by the Kimi CLI and by OpenCode's auth.json.
    private static let authKeys = [
        "kimi-for-coding", "kimi", "kimi-coding-plan", "moonshot",
        "kimi-for-coding-oauth"
    ]

    var typeID: String { "kimi" }
    var displayName: String { "Kimi Code" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = context.credentials.resolve(config: context.config, envNames: Self.envNames)
            ?? context.credentials.authValue(keys: Self.authKeys) else {
            return .notConfigured(id: id, name: name, reason: "Set KIMI_API_KEY to a Kimi Code key")
        }

        let endpoint = context.config.baseUrl ?? Self.endpoint
        do {
            let payload = try await context.http.getJSON(endpoint, headers: [
                "Authorization": "Bearer \(key.value)"
            ])

            var windows: [QuotaWindow] = []
            let usagePayload = payload.path("data.usage") ?? payload["usage"]
            if let usagePayload, usagePayload.exists,
               let window = Self.window(from: usagePayload, id: "usage", fallbackLabel: "Weekly limit") {
                windows.append(window)
            }

            let limits = Parse.array(payload, ["data.limits", "limits"]) ?? []
            for (index, limit) in limits.enumerated() {
                // Numbers nest under `detail` when present, otherwise sit on the entry.
                let numbers: JSON = {
                    if let detail = limit["detail"], detail.exists { return detail }
                    return limit
                }()
                let label = Self.label(for: limit, index: index)
                if let window = Self.window(from: limit, id: "limit-\(index)", fallbackLabel: label, detail: numbers) {
                    windows.append(window)
                }
            }

            if windows.isEmpty {
                let keys = payload.object?.keys.sorted().joined(separator: ", ") ?? "empty"
                return .failed(
                    id: id,
                    name: name,
                    error: "Unexpected response structure (keys: \(keys))",
                    credentialSource: key.source
                )
            }

            return ProviderQuota(
                id: id,
                name: name,
                windows: windows,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "Kimi Code rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }

    /// Numbers live under `detail`, labels and window metadata on the entry.
    private static func window(from entry: JSON, id: String, fallbackLabel: String, detail: JSON? = nil) -> QuotaWindow? {
        let numbers = detail ?? entry
        var used = Parse.number(numbers, ["used", "used_count"])
        let limit = Parse.number(numbers, ["limit", "total"])
        if used == nil, let remaining = Parse.number(numbers, ["remaining"]) , let limit {
            used = limit - remaining
        }

        var remainingPercent = Parse.number(numbers, ["remainingPercent", "remaining_percent"])
        if remainingPercent == nil, let used, let limit, limit > 0 {
            remainingPercent = (1 - used / limit) * 100
        }

        guard remainingPercent != nil || limit != nil else { return nil }

        return QuotaWindow(
            id: id,
            label: Parse.string(entry, ["name", "title", "scope"]) ?? fallbackLabel,
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetAt: TimeParse.reset(
                in: entry,
                absolute: ["reset_at", "resetAt", "reset_time", "resetTime"],
                relative: ["reset_in", "resetIn", "ttl", "window.duration"]
            ),
            unit: "requests"
        )
    }

    private static func label(for entry: JSON, index: Int) -> String {
        if let explicit = Parse.string(entry, ["name", "title", "scope"]) { return explicit }
        let duration = Parse.number(entry, ["window.duration", "duration"])
        let timeUnit = (Parse.string(entry, ["window.timeUnit", "timeUnit"]) ?? "").uppercased()
        guard let duration, duration > 0 else { return "Limit #\(index + 1)" }
        if timeUnit.contains("MINUTE") {
            return duration >= 60 && duration.truncatingRemainder(dividingBy: 60) == 0
                ? "\(Int(duration / 60))h limit"
                : "\(Int(duration))m limit"
        }
        if timeUnit.contains("HOUR") { return "\(Int(duration))h limit" }
        if timeUnit.contains("DAY") { return "\(Int(duration))d limit" }
        return "\(Int(duration))s limit"
    }
}
