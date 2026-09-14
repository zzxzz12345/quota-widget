import AppKit
import SwiftUI

/// The menu bar item: a gauge plus the tracked plan's 5h / 1w / 1m readings.
struct MenuBarLabel: View {
    @ObservedObject var service: QuotaService

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if showsText, let text = labelText {
                Text(text)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint)
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var showsText: Bool { service.config.showMenuBarText ?? true }

    private var style: MenuBarStyle { service.config.menuBarStyleResolved }

    /// The windows the label reports, in 5h / 1w / 1m order.
    private var windows: [QuotaWindow] { service.trackedQuota?.primaryWindows ?? [] }

    private var labelText: String? {
        guard service.hasLoadedOnce else { return "…" }

        switch style {
        case .windows:
            guard !windows.isEmpty else { return fallback }
            return windows
                .map { QuotaFormat.percent($0.resolvedRemainingPercent ?? 0).replacingOccurrences(of: "%", with: "") }
                .joined(separator: "/")
        case .labeled:
            guard !windows.isEmpty else { return fallback }
            return windows.map { window in
                let value = QuotaFormat.percent(window.resolvedRemainingPercent ?? 0)
                    .replacingOccurrences(of: "%", with: "")
                return "\(window.label)\(value)"
            }.joined(separator: " ")
        case .worst:
            if let percent = windows.compactMap(\.resolvedRemainingPercent).min() {
                return QuotaFormat.percent(percent)
            }
            return fallback
        }
    }

    /// Shown when the tracked plan has no numbers to report.
    private var fallback: String {
        if service.counts.ok > 0 { return "ok" }
        if service.counts.failed > 0 { return "!" }
        return "—"
    }

    private var tint: Color {
        guard let percent = windows.compactMap(\.resolvedRemainingPercent).min() else {
            return .primary
        }
        return QuotaPalette.color(forRemaining: percent)
    }

    private var symbolName: String {
        guard let percent = windows.compactMap(\.resolvedRemainingPercent).min() else {
            return "gauge.medium"
        }
        switch percent {
        case ..<10: return "gauge.with.dots.needle.bottom.0percent"
        case ..<80: return "gauge.with.dots.needle.bottom.50percent"
        default: return "gauge.with.dots.needle.bottom.100percent"
        }
    }

    private var accessibility: String {
        guard let quota = service.trackedQuota else { return "Coding plan quota unavailable" }
        var parts = [quota.name]
        if quota.orderedWindows.isEmpty {
            parts.append(quota.status.message ?? "no usage reported")
        } else {
            for window in quota.orderedWindows {
                guard let percent = window.resolvedRemainingPercent else { continue }
                parts.append("\(window.label) \(QuotaFormat.percent(percent)) remaining")
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// How the menu bar summarises the tracked plan.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// `20/68/84` — the three percentages, in 5h / 1w / 1m order.
    case windows
    /// `5h20 1w68 1m84` — the same readings with their window names.
    case labeled
    /// `20%` — only the tightest window.
    case worst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Percentages"
        case .labeled: return "Percentages with labels"
        case .worst: return "Tightest only"
        }
    }

    var example: String {
        switch self {
        case .windows: return "20/68/84"
        case .labeled: return "5h20 1w68 1m84"
        case .worst: return "20%"
        }
    }
}

extension QuotaWidgetConfig {
    var menuBarStyleResolved: MenuBarStyle {
        menuBarStyle.flatMap(MenuBarStyle.init(rawValue:)) ?? .windows
    }
}
