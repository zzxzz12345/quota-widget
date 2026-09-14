import Foundation

/// Command Code (commandcode.ai) subscription quota.
///
/// Mirrors the `/commandcode-quota` behaviour of the `pi-commandcode-provider`
/// extension: one `/alpha/whoami` call to learn the account, then credits,
/// subscription and usage-summary calls scoped to the resolved org.
struct CommandCodeProvider: QuotaProvider {
    static let defaultBaseURL = "https://api.commandcode.ai"

    private static let envNames = ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"]

    var typeID: String { "commandcode" }
    var displayName: String { "Command Code" }

    func fetch(_ context: ProviderContext) async -> ProviderQuota {
        let id = context.config.resolvedID
        let name = context.config.name ?? displayName

        guard let key = resolveAPIKey(context) else {
            return .notConfigured(
                id: id,
                name: name,
                reason: "Set COMMAND_CODE_API_KEY or sign in with the Command Code CLI (~/.commandcode/auth.json)"
            )
        }

        let base = (context.config.baseUrl ?? Self.defaultBaseURL).trimmingTrailingSlash()
        var requestHeaders = [
            "accept": "application/json",
            "Authorization": "Bearer \(key.value)"
        ]
        // Zero-data-retention is opt-in upstream; forward it when the shell asked for it.
        if context.credentials.flag("CMD_ZDR") || context.credentials.flag("COMMANDCODE_ZDR") {
            requestHeaders["x-cmd-zdr"] = "1"
        }
        let headers = requestHeaders

        do {
            let whoami = try await context.http.getJSON("\(base)/alpha/whoami", headers: headers)
            guard let account = Self.parseWhoami(whoami) else {
                return .failed(id: id, name: name, error: "Unrecognized account response from Command Code", credentialSource: key.source)
            }

            let orgQuery = account.orgID.map { "?orgId=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""

            // Credits and subscription are independent; one failing should not
            // blank out the other.
            async let creditsResult = fetchOptional(context, "\(base)/alpha/billing/credits\(orgQuery)", headers)
            async let subscriptionResult = fetchOptional(context, "\(base)/alpha/billing/subscriptions\(orgQuery)", headers)
            let (creditsJSON, subscriptionJSON) = await (creditsResult, subscriptionResult)

            // A 401/403 on the first authenticated call means the key is bad.
            if let authError = [creditsJSON, subscriptionJSON].compactMap({ $0.authError }).first {
                return .failed(id: id, name: name, error: authError, credentialSource: key.source)
            }

            var windows: [QuotaWindow] = []
            var metrics: [QuotaMetric] = []

            let planID = Parse.string(subscriptionJSON.json?["data"], ["planId"])

            if let limits = creditsJSON.json?["windowLimits"] {
                for (key, id, label) in [
                    ("fiveHour", "fiveHour", "5h"),
                    ("weekly", "weekly", "1w"),
                    ("monthly", "monthly", "1m")
                ] {
                    guard let entry = limits[key], entry.exists else { continue }
                    guard let window = Parse.window(
                        id: id,
                        label: label,
                        json: entry,
                        used: ["used"],
                        limit: ["cap"],
                        remainingPercent: [],
                        usedPercent: [],
                        resetAt: ["resetAt", "reset_at", "nextResetTime"],
                        resetAfter: [],
                        unit: "credits"
                    ) else { continue }
                    windows.append(window)
                }
            }

            if let credits = creditsJSON.json?["credits"] {
                let monthly = credits["monthlyCredits"]?.double ?? 0
                let purchased = credits["purchasedCredits"]?.double ?? 0
                let free = credits["freeCredits"]?.double ?? 0
                let total = monthly + purchased + free

                // The API reports the remaining monthly balance but not its cap,
                // so the 1m window comes from the plan's published allowance.
                if !windows.contains(where: { $0.id == "monthly" }) {
                    let allowance = context.config.monthlyAllowance ?? Self.monthlyAllowance(forPlan: planID)
                    if let allowance, allowance > 0 {
                        windows.append(QuotaWindow(
                            id: "monthly",
                            label: "1m",
                            used: max(0, allowance - monthly),
                            limit: allowance,
                            resetAt: TimeParse.date(subscriptionJSON.json?.path("data.currentPeriodEnd")),
                            unit: "credits"
                        ))
                    }
                }

                if total > 0 {
                    metrics.append(QuotaMetric(
                        id: "credits",
                        label: "Credits remaining",
                        value: QuotaFormat.number(total),
                        detail: "monthly \(QuotaFormat.number(monthly)) · purchased \(QuotaFormat.number(purchased)) · free \(QuotaFormat.number(free))"
                    ))
                }
            }

            var plan: String?
            if let subscription = subscriptionJSON.json?["data"] {
                plan = planID
                if let status = Parse.string(subscription, ["status"]) {
                    plan = plan.map { "\($0) · \(status)" } ?? status
                }
                if let periodEnd = TimeParse.date(subscription.path("currentPeriodEnd")) {
                    metrics.append(QuotaMetric(
                        id: "period",
                        label: "Current period ends",
                        value: QuotaFormat.countdown(to: periodEnd),
                        detail: QuotaFormat.shortDateTime(periodEnd)
                    ))
                }
            }

            let since = subscriptionJSON.json?.string(at: "data.currentPeriodStart")
            if let summary = await fetchOptional(context, Self.summaryURL(base: base, orgID: account.orgID, since: since), headers).json {
                if let cost = Parse.number(summary, ["totalCost"]) {
                    metrics.append(QuotaMetric(
                        id: "cost",
                        label: "Usage this period",
                        value: "$" + String(format: "%.2f", cost),
                        detail: Self.usageDetail(summary)
                    ))
                }
            }

            if windows.isEmpty && metrics.isEmpty {
                return .failed(id: id, name: name, error: "Command Code returned no recognized usage data", credentialSource: key.source)
            }

            return ProviderQuota(
                id: id,
                name: name,
                plan: plan,
                account: account.label,
                windows: windows,
                metrics: metrics,
                status: .ok,
                updatedAt: Date(),
                credentialSource: key.source
            )
        } catch let failure as HTTPFailure {
            if failure.isAuthFailure {
                return .failed(id: id, name: name, error: "Command Code rejected the API key", credentialSource: key.source)
            }
            return .failed(id: id, name: name, error: failure.localizedDescription, credentialSource: key.source)
        } catch {
            return .failed(id: id, name: name, error: error.localizedDescription, credentialSource: key.source)
        }
    }

    /// Monthly credit allowance by plan, from the published limits table.
    /// Matched longest-key-first so `individual-goat` resolves to `goat`, not `go`.
    static let monthlyAllowances: [(plan: String, credits: Double)] = [
        ("max-20x", 300), ("max20x", 300),
        ("max-10x", 150), ("max10x", 150),
        ("team-pro", 40),
        ("individual-goat", 70), ("goat", 70),
        ("individual-pro", 80), ("pro", 80),
        ("individual-go", 10), ("go", 10)
    ]

    /// Nil when the plan is unknown, so no percentage is invented for it.
    static func monthlyAllowance(forPlan planID: String?) -> Double? {
        guard let planID, !planID.isEmpty else { return nil }
        let normalized = planID.lowercased()
        let matches = monthlyAllowances
            .filter { normalized.contains($0.plan) }
            .sorted { $0.plan.count > $1.plan.count }
        return matches.first?.credits
    }

    private static func summaryURL(base: String, orgID: String?, since: String?) -> String {
        var items: [String] = []
        if let orgID { items.append("orgId=\(orgID)") }
        if let since { items.append("since=\(since)") }
        return "\(base)/alpha/usage/summary" + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
    }

    private static func usageDetail(_ summary: JSON) -> String? {
        var parts: [String] = []
        if let count = Parse.number(summary, ["totalCount"]) {
            parts.append("\(QuotaFormat.number(count)) calls")
        }
        if let tokens = Parse.number(summary, ["totalTokens", "tokens"]) {
            parts.append("\(QuotaFormat.number(tokens)) tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private struct OptionalResult {
        var json: JSON?
        var authError: String?
    }

    /// Credits/subscription/summary are best-effort: a single unavailable
    /// section should degrade the panel, not empty it.
    private func fetchOptional(_ context: ProviderContext, _ url: String, _ headers: [String: String]) async -> OptionalResult {
        do {
            return OptionalResult(json: try await context.http.getJSON(url, headers: headers))
        } catch let failure as HTTPFailure {
            return OptionalResult(json: nil, authError: failure.isAuthFailure ? failure.localizedDescription : nil)
        } catch {
            return OptionalResult(json: nil, authError: nil)
        }
    }

    private struct Account {
        var label: String
        var orgID: String?
    }

    /// `{ org: { login, id }, user: { userName|name, keyName } }`
    private static func parseWhoami(_ json: JSON) -> Account? {
        let orgLogin = Parse.string(json, ["org.login"])
        let userName = Parse.string(json, ["user.userName", "user.name"])
        guard let label = orgLogin ?? userName else { return nil }
        let suffix = Parse.string(json, ["user.keyName", "user.displayName"])
        return Account(
            label: suffix.map { "\(label) · \($0)" } ?? label,
            orgID: Parse.string(json, ["org.id"])
        )
    }

    // MARK: - Credentials

    private func resolveAPIKey(_ context: ProviderContext) -> CredentialStore.Located? {
        if let located = context.credentials.resolve(config: context.config, envNames: Self.envNames) {
            return located
        }

        // Command Code auth files use several shapes; the shared resolver only
        // understands the standard `{type, key}` entry, so handle the rest here.
        let keys = ["commandcode", "command-code", "apiKey"]
        for key in keys {
            guard let (entry, source) = context.credentials.rawAuthEntry(key: key) else { continue }
            if let value = entry.string, !value.isEmpty { return .init(value: value, source: source) }
            for nested in ["apiKey", "key", "access", "token"] {
                if let value = entry[nested]?.string, !value.isEmpty {
                    return .init(value: value, source: source)
                }
            }
        }
        return nil
    }
}

extension String {
    func trimmingTrailingSlash() -> String {
        var copy = self
        while copy.hasSuffix("/") { copy.removeLast() }
        return copy
    }
}
