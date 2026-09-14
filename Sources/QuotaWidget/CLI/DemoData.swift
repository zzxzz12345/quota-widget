import Foundation

/// Illustrative data for `--preview --demo`, used to regenerate the README
/// screenshots. Renders the real views without touching the network or showing
/// anyone's actual account, balances or usage.
enum DemoData {
    static func config() -> QuotaWidgetConfig {
        var config = QuotaWidgetConfig.default
        config.menuBarStyle = MenuBarStyle.windows.rawValue
        config.providers = [
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "opencode-go"),
            ProviderConfig(type: "ollama-cloud"),
            ProviderConfig(type: "deepseek")
        ]
        return config
    }

    static func quotas() -> [ProviderQuota] {
        let now = Date()
        func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

        return [
            ProviderQuota(
                id: "commandcode",
                name: "Command Code",
                plan: "individual-goat · active",
                windows: [
                    QuotaWindow(id: "fiveHour", label: "5h", used: 11.4, limit: 14,
                                resetAt: inHours(2.9), unit: "credits"),
                    QuotaWindow(id: "weekly", label: "1w", used: 11.4, limit: 35,
                                resetAt: inHours(6 * 24 + 21), unit: "credits"),
                    QuotaWindow(id: "monthly", label: "1m", used: 11.4, limit: 70,
                                resetAt: inHours(29 * 24 + 21), unit: "credits")
                ],
                metrics: [
                    QuotaMetric(id: "credits", label: "Credits remaining", value: "58.59",
                                detail: "monthly 58.59 · purchased 0 · free 0"),
                    QuotaMetric(id: "period", label: "Current period ends", value: "29d 21h",
                                detail: "Oct 14 08:58"),
                    QuotaMetric(id: "cost", label: "Usage this period", value: "$11.22",
                                detail: "4.3k calls · 475.3M tokens")
                ],
                status: .ok,
                updatedAt: now,
                credentialSource: "config.json:commandcode"
            ),
            ProviderQuota(
                id: "opencode-go",
                name: "OpenCode Go",
                windows: [
                    QuotaWindow(id: "rolling", label: "5h", remainingPercent: 100, resetAt: inHours(5)),
                    QuotaWindow(id: "weekly", label: "1w", remainingPercent: 100, resetAt: inHours(6 * 24 + 20)),
                    QuotaWindow(id: "monthly", label: "1m", remainingPercent: 26, resetAt: inHours(9 * 24 + 21))
                ],
                status: .ok,
                updatedAt: now,
                credentialSource: "config.json:opencode-go"
            ),
            ProviderQuota(
                id: "ollama-cloud",
                name: "Ollama Cloud",
                windows: [
                    QuotaWindow(id: "session", label: "Session", remainingPercent: 88),
                    QuotaWindow(id: "weekly", label: "Weekly", remainingPercent: 98)
                ],
                metrics: [
                    QuotaMetric(id: "models", label: "Models this session", value: "2",
                                detail: "deepseek-v4.1-flash, deepseek-v4-flash:0731"),
                    QuotaMetric(id: "cost", label: "Cost this period", value: "$0.00"),
                    QuotaMetric(id: "period", label: "Usage period", value: "Aug 24 – Sep 14",
                                detail: "last 4 weeks")
                ],
                status: .ok,
                updatedAt: now,
                credentialSource: "config.json:ollama-cloud"
            ),
            ProviderQuota(
                id: "minimax-cn",
                name: "MiniMax Token Plan (CN)",
                status: .failed("Needs a platform session cookie — sign in at minimaxi.com, then set MINIMAX_CN_COOKIE to the Cookie header value"),
                updatedAt: now
            ),
            ProviderQuota(
                id: "deepseek",
                name: "DeepSeek",
                metrics: [
                    QuotaMetric(id: "balance-0", label: "Balance (CNY)", value: "7.5",
                                detail: "granted 0 · topped up 7.5")
                ],
                status: .ok,
                updatedAt: now,
                credentialSource: "config.json:deepseek"
            )
        ]
    }
}
