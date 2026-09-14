import Foundation

/// OpenCode Go (opencode.ai) plan usage.
///
/// `GET https://opencode.ai/zen/go/v1/usage` returns three windows, each with a
/// `percent` that is the *used* share and an offset-qualified `resetsAt`. The
/// endpoint sits behind Cloudflare, whose bot rule rejects request signatures
/// without a User-Agent — the shared client always sends one.
struct OpenCodeGoProvider: QuotaProvider {
    static let endpoint = "https://opencode.ai/zen/go/v1/usage"
    private static let envNames = ["OPENCODE_API_KEY", "OPENCODE_GO_API_KEY"]
    private static let authKeys = ["opencode-go"]

    var typeID: String { "opencode-go" }
    var displayName: String { "OpenCode Go" }

    /// Window key, display label.
    private static let windows: [(key: String, id: String, label: String)] = [
        ("rolling", "rolling", "5h"),
        ("weekly", "weekly", "1w"),
        ("monthly", "monthly", "1m")
    ]

    private struct Credential {
        var source: String
    }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = context.credentials.resolve(config: context.config, envNames: Self.envNames)
            ?? context.credentials.authValue(keys: Self.authKeys) else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Set OPENCODE_API_KEY, or store an `opencode-go` credential"
            )
        }

        do {
            let payload = try await context.http.getJSON(context.config.baseUrl ?? Self.endpoint, headers: [
                "Authorization": "Bearer \(key.value)"
            ])

            var windows: [QuotaWindow] = []
            var unreadable: [String] = []
            for spec in Self.windows {
                let entry = payload.path("usage.\(spec.key)")
                guard let entry, entry.exists else { continue }
                if let status = entry["status"]?.string, status != "ok" {
                    unreadable.append("\(spec.label): \(status)")
                    continue
                }
                guard let usedPercent = Parse.number(entry, ["percent"]) else {
                    unreadable.append("\(spec.label): no percent")
                    continue
                }
                windows.append(QuotaWindow(
                    id: spec.id,
                    label: spec.label,
                    remainingPercent: min(100, max(0, 100 - usedPercent)),
                    resetAt: TimeParse.date(entry["resetsAt"]),
                    unit: "requests"
                ))
            }

            if windows.isEmpty {
                let detail = unreadable.isEmpty ? "no windows in the response" : unreadable.joined(separator: "; ")
                return .failed(id: id, name: name, error: detail, credentialSource: key.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                windows: windows,
                // A window present but not `ok` still deserves to be visible.
                metrics: unreadable.map {
                    QuotaMetric(id: "unavailable-\($0)", label: "Unavailable", value: $0)
                },
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "OpenCode Go rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }
}

/// Ollama Cloud usage.
///
/// `GET https://ollama.com/api/usage` reports `limits.session` and
/// `limits.weekly` as a *fraction used* (0…1), plus per-model request counts
/// and a spend figure for the current period.
struct OllamaCloudProvider: QuotaProvider {
    static let endpoint = "https://ollama.com/api/usage"
    private static let envNames = ["OLLAMA_API_KEY"]
    private static let authKeys = ["ollama-cloud", "ollama"]

    var typeID: String { "ollama-cloud" }
    var displayName: String { "Ollama Cloud" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = context.credentials.resolve(config: context.config, envNames: Self.envNames)
            ?? context.credentials.authValue(keys: Self.authKeys) else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Set OLLAMA_API_KEY, or store an `ollama-cloud` credential"
            )
        }

        do {
            let payload = try await context.http.getJSON(context.config.baseUrl ?? Self.endpoint, headers: [
                "Authorization": "Bearer \(key.value)"
            ])

            var windows: [QuotaWindow] = []
            for (key, id, label) in [("session", "session", "Session"), ("weekly", "weekly", "Weekly")] {
                guard let entry = payload.path("limits.\(key)"), entry.exists else { continue }
                guard let window = Self.window(from: entry, id: id, label: label) else { continue }
                windows.append(window)
            }

            var metrics: [QuotaMetric] = []
            if let models = payload.path("limits.session.models")?.array, !models.isEmpty {
                let names = models.compactMap { Parse.string($0, ["model", "name"]) }
                if !names.isEmpty {
                    metrics.append(QuotaMetric(
                        id: "models",
                        label: "Models this session",
                        value: "\(names.count)",
                        detail: names.prefix(4).joined(separator: ", ")
                    ))
                }
            }
            if let cost = Parse.string(payload, ["activity.cost"]), !cost.isEmpty {
                metrics.append(QuotaMetric(
                    id: "cost",
                    label: "Cost this period",
                    value: Self.currency(cost)
                ))
            }
            // `activity.period` is a trailing lookback, so a reset countdown
            // would be meaningless — show the range it covers instead.
            if let period = Self.periodRange(payload) {
                metrics.append(QuotaMetric(
                    id: "period",
                    label: "Usage period",
                    value: period.range,
                    detail: period.label
                ))
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(
                    id: id,
                    name: name,
                    error: "No usage limits for this account",
                    credentialSource: key.source
                )
            }

            return ProviderQuota(
                id: id,
                name: name,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            let message = failure.isAuthFailure
                ? "Ollama Cloud rejected the API key"
                : failure.localizedDescription
            return .failed(id: id, name: name, error: message, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }

    /// `usage` is a 0…1 fraction of the allowance already consumed.
    private static func window(from entry: JSON, id: String, label: String) -> QuotaWindow? {
        guard let used = Parse.number(entry, ["usage"]) else { return nil }
        let usedPercent = used <= 1 ? used * 100 : used
        return QuotaWindow(
            id: id,
            label: label,
            remainingPercent: min(100, max(0, 100 - usedPercent)),
            unit: "requests"
        )
    }

    private static func periodDetail(_ payload: JSON) -> String? {
        periodRange(payload)?.range
    }

    /// "Aug 17 – Sep 14" plus the API's own period name.
    private static func periodRange(_ payload: JSON) -> (range: String, label: String?)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"

        let start = Parse.string(payload, ["activity.period.starting_at"])
            .flatMap { TimeParse.date(fromString: $0) }
        let end = Parse.string(payload, ["activity.period.ending_at"])
            .flatMap { TimeParse.date(fromString: $0) }
        let label = Parse.string(payload, ["activity.period.type"])?
            .replacingOccurrences(of: "_", with: " ")

        switch (start, end) {
        case let (start?, end?):
            return ("\(formatter.string(from: start)) – \(formatter.string(from: end))", label)
        default:
            return label.map { ($0, nil) }
        }
    }

    /// The API returns cost as a string with fixed precision.
    static func currency(_ raw: String) -> String {
        let digits = raw.hasPrefix("$") ? String(raw.dropFirst()) : raw
        guard let amount = Double(digits) else { return raw }
        let format = (amount > 0 && amount < 0.01) ? "%.4f" : "%.2f"
        return "$" + String(format: format, amount)
    }
}
