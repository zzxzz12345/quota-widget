import Foundation

/// Machine-readable rendering of a refresh, shared by `--json` and the panel's
/// "Copy JSON" action so both stay in sync.
enum CLIReport {
    static func render(quotas: [ProviderQuota], lastRefresh: Date?) -> [String: Any] {
        var ok = 0, failed = 0, unconfigured = 0
        for quota in quotas {
            switch quota.status {
            case .ok: ok += 1
            case .failed: failed += 1
            case .notConfigured: unconfigured += 1
            }
        }

        var summary: [String: Any] = [
            "ok": ok,
            "failed": failed,
            "unconfigured": unconfigured
        ]
        let worst = quotas.compactMap(\.worstRemainingPercent).min()
        if let worst { summary["worstRemainingPercent"] = rounded(worst) }

        var report: [String: Any] = [
            "provider": "quota-widget",
            "version": AppInfo.version,
            "summary": summary,
            "providers": quotas.map(render(quota:))
        ]
        if let lastRefresh {
            report["updatedAt"] = ISO8601DateFormatter().string(from: lastRefresh)
        }
        return report
    }

    private static func render(quota: ProviderQuota) -> [String: Any] {
        var entry: [String: Any] = [
            "id": quota.id,
            "name": quota.name,
            "status": statusName(quota.status)
        ]
        if let plan = quota.plan { entry["plan"] = plan }
        if let account = quota.account { entry["account"] = account }
        if let source = quota.credentialSource { entry["credentialSource"] = source }
        if let message = quota.status.message { entry["error"] = message }
        if let worst = quota.worstRemainingPercent { entry["worstRemainingPercent"] = rounded(worst) }
        if let updated = quota.updatedAt {
            entry["updatedAt"] = ISO8601DateFormatter().string(from: updated)
        }

        entry["windows"] = quota.windows.map { window -> [String: Any] in
            var item: [String: Any] = ["id": window.id, "label": window.label]
            if let used = window.used { item["used"] = rounded(used) }
            if let limit = window.limit { item["limit"] = rounded(limit) }
            if let remaining = window.resolvedRemainingPercent { item["remainingPercent"] = rounded(remaining) }
            if let reset = window.resetAt {
                item["resetAt"] = ISO8601DateFormatter().string(from: reset)
                item["resetsInSeconds"] = max(0, Int(reset.timeIntervalSinceNow))
            }
            if let unit = window.unit { item["unit"] = unit }
            return item
        }

        entry["metrics"] = quota.metrics.map { metric -> [String: Any] in
            var item: [String: Any] = ["label": metric.label, "value": metric.value]
            if let detail = metric.detail { item["detail"] = detail }
            return item
        }
        return entry
    }

    private static func statusName(_ status: ProviderStatus) -> String {
        switch status {
        case .ok: return "ok"
        case .failed: return "error"
        case .notConfigured: return "unconfigured"
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    // MARK: - Terminal output

    static func plainText(quotas: [ProviderQuota], lastRefresh: Date?) -> String {
        var lines: [String] = []
        if let lastRefresh {
            lines.append("Coding plan quota — updated \(QuotaFormat.elapsed(since: lastRefresh))")
        } else {
            lines.append("Coding plan quota")
        }
        lines.append("")

        for quota in quotas {
            switch quota.status {
            case .notConfigured(let reason):
                lines.append("○ \(quota.name) — \(reason)")
            case .failed(let message):
                lines.append("✗ \(quota.name) — \(message)")
            case .ok:
                var header = "● \(quota.name)"
                if let plan = quota.plan { header += "  [\(plan)]" }
                lines.append(header)
                if let account = quota.account { lines.append("    \(account)") }
                for window in quota.windows {
                    var row = "    \(window.label.padding(toLength: 22, withPad: " ", startingAt: 0))"
                    if let remaining = window.resolvedRemainingPercent {
                        row += QuotaFormat.percent(remaining) + " left"
                    } else {
                        row += "—"
                    }
                    if let used = window.used, let limit = window.limit {
                        row += "  (\(QuotaFormat.number(used))/\(QuotaFormat.number(limit)))"
                    }
                    if let reset = window.resetAt {
                        row += "  resets in \(QuotaFormat.countdown(to: reset))"
                    }
                    lines.append(row)
                }
                for metric in quota.metrics {
                    var row = "    \(metric.label.padding(toLength: 22, withPad: " ", startingAt: 0))\(metric.value)"
                    if let detail = metric.detail { row += "  (\(detail))" }
                    lines.append(row)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }
}
