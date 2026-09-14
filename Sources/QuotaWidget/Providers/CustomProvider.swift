import Foundation

/// Bring-your-own-endpoint provider for coding plans with no built-in support.
///
/// Two response contracts are understood:
///  - `quota-v1` — a structured `{ plan, account, windows[], metrics[] }` body.
///  - `json-v1`  — an arbitrary body plus dot-path field mappings.
///
/// `staticWindows` covers plans with a fixed allowance and no usage endpoint:
/// declare the window and let the panel render the reset countdown.
struct CustomProvider: QuotaProvider {
    var typeID: String { "custom" }
    var displayName: String { "Custom" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let config = context.config
        let id = config.resolvedID
        let name = config.name ?? id

        guard let urlString = config.url, !urlString.isEmpty else {
            return .failed(id: id, name: name, error: "Custom provider needs a `url`")
        }

        var headers = context.credentials.expandHeaders(config.headers ?? [:])
        if headers["Authorization"] == nil {
            let key = context.credentials.resolve(config: config, envNames: config.apiKeyEnv.map { [$0] } ?? [])
            if let key {
                let scheme = config.authScheme ?? "bearer"
                headers["Authorization"] = scheme == "raw" ? key.value : "Bearer \(key.value)"
            }
        }

        let declared = Self.staticWindows(config.staticWindows)

        do {
            let payload = try await context.http.getJSON(urlString, headers: headers)
            var windows = declared
            var metrics: [QuotaMetric] = []
            var plan: String?
            var account: String?

            switch (config.format ?? "quota-v1").lowercased() {
            case "json-v1":
                (windows, metrics, plan, account) = Self.parseMapped(payload, config: config, seed: declared)
            default:
                let parsed = Self.parseStructured(payload)
                windows.append(contentsOf: parsed.windows)
                metrics = parsed.metrics
                plan = parsed.plan
                account = parsed.account
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "No windows or metrics recognized in the response")
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: plan,
                account: account,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date()
            )
        } catch let failure as HTTPFailure {
            // Static windows still carry the reset schedule when the call fails.
            if !declared.isEmpty {
                return ProviderQuota(
                    id: id,
                    name: name,
                    windows: declared,
                    status: .failed(failure.localizedDescription),
                    updatedAt: Date()
                )
            }
            return .failed(id: id, name: name, error: failure.localizedDescription)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription)
        }
    }

    private static func staticWindows(_ declared: [StaticWindow]?) -> [QuotaWindow] {
        (declared ?? []).enumerated().map { index, window in
            QuotaWindow(
                id: "static-\(index)",
                label: window.label,
                used: window.used,
                limit: window.limit,
                remainingPercent: window.remainingPercent,
                resetAt: window.resetAt.flatMap { TimeParse.date(fromString: $0) },
                unit: window.unit
            )
        }
    }

    private static func parseStructured(_ payload: JSON) -> (windows: [QuotaWindow], metrics: [QuotaMetric], plan: String?, account: String?) {
        var windows: [QuotaWindow] = []
        for (index, entry) in (Parse.array(payload, ["windows", "data.windows"]) ?? []).enumerated() {
            if let window = Parse.window(
                id: "window-\(index)",
                label: Parse.string(entry, ["label", "name"]) ?? "Window #\(index + 1)",
                json: entry,
                used: ["used", "used_count"],
                limit: ["limit", "cap", "total"],
                remainingPercent: ["remainingPercent", "remaining_percent", "percentRemaining"],
                usedPercent: ["usedPercent", "used_percent", "percentage"],
                resetAt: ["resetAt", "reset_at", "resetTime"],
                resetAfter: ["resetIn", "reset_in", "reset_after_seconds"],
                unit: Parse.string(entry, ["unit"])
            ) { windows.append(window) }
        }

        let metrics = (Parse.array(payload, ["metrics", "data.metrics"]) ?? []).enumerated().compactMap { index, entry -> QuotaMetric? in
            guard let label = Parse.string(entry, ["label", "name"]) else { return nil }
            let value = Parse.string(entry, ["value"]) ?? Parse.number(entry, ["value"]).map(QuotaFormat.number)
            guard let value else { return nil }
            return QuotaMetric(id: "metric-\(index)", label: label, value: value, detail: Parse.string(entry, ["detail"]))
        }

        return (windows, metrics, Parse.string(payload, ["plan"]), Parse.string(payload, ["account"]))
    }

    private static func parseMapped(
        _ payload: JSON,
        config: ProviderConfig,
        seed: [QuotaWindow]
    ) -> (windows: [QuotaWindow], metrics: [QuotaMetric], plan: String?, account: String?) {
        let fields = config.windowFields ?? WindowFieldMapping()
        var windows = seed

        let entries = config.windowsPath.flatMap { payload.path($0)?.array }
            ?? Parse.array(payload, ["windows", "data.windows", "limits"])
            ?? []

        for (index, entry) in entries.enumerated() {
            let label = fields.label.flatMap { entry.path($0)?.string } ?? "Window #\(index + 1)"
            if let window = Parse.window(
                id: "window-\(index)",
                label: label,
                json: entry,
                used: [fields.used ?? "used"],
                limit: [fields.limit ?? "limit"],
                remainingPercent: [fields.remainingPercent ?? "remainingPercent"],
                usedPercent: [fields.usedPercent ?? "usedPercent"],
                resetAt: [fields.resetAt ?? "resetAt"],
                resetAfter: ["resetIn"],
                unit: fields.unit.flatMap { entry.path($0)?.string }
            ) { windows.append(window) }
        }

        let metrics = (config.metricPaths ?? [:]).compactMap { label, pointer -> QuotaMetric? in
            guard let value = payload.string(at: pointer) ?? payload.double(at: pointer).map(QuotaFormat.number) else {
                return nil
            }
            return QuotaMetric(id: label, label: label, value: value)
        }

        return (
            windows,
            metrics,
            config.planPath.flatMap { payload.string(at: $0) },
            config.accountPath.flatMap { payload.string(at: $0) }
        )
    }
}
