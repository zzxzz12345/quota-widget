import SwiftUI

struct QuotaBar: View {
    var remainingPercent: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geometry.size.width * remainingPercent / 100))
            }
        }
        .frame(height: height)
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.45 : 1)
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

struct QuotaWindowRow: View {
    var window: QuotaWindow
    var warnThreshold: Double
    var criticalThreshold: Double
    var now: Date

    private var remaining: Double? { window.resolvedRemainingPercent }

    private var tint: Color {
        guard let remaining else { return .secondary }
        if remaining < criticalThreshold { return .red }
        if remaining < warnThreshold { return .orange }
        if remaining < 50 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let remaining {
                    Text(QuotaFormat.percent(remaining) + " left")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                }
                if let limit = window.limit {
                    Text("/ " + QuotaFormat.number(limit))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let remaining {
                QuotaBar(remainingPercent: remaining, tint: tint)
            }

            HStack(spacing: 6) {
                if let used = window.used {
                    Text("\(QuotaFormat.number(used)) used")
                }
                if let limit = window.limit {
                    Text("of \(QuotaFormat.number(limit))\(window.unit.map { " \($0)" } ?? "")")
                }
                if let reset = window.resetAt {
                    if window.used != nil || window.limit != nil { Text("·") }
                    Text(QuotaFormat.resetDescription(for: reset, now: now))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

struct ProviderCard: View {
    var quota: ProviderQuota
    var warnThreshold: Double
    var criticalThreshold: Double
    var now: Date

    private var statusColor: Color { QuotaPalette.color(for: quota.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor, pulsing: quota.status.isOK && (quota.worstRemainingPercent ?? 100) < criticalThreshold)
                Text(quota.name)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                if let plan = quota.plan {
                    Badge(text: plan)
                }
            }

            if let account = quota.account {
                Text(account)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !quota.windows.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(quota.windows) { window in
                        QuotaWindowRow(
                            window: window,
                            warnThreshold: warnThreshold,
                            criticalThreshold: criticalThreshold,
                            now: now
                        )
                    }
                }
            }

            if !quota.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(quota.metrics) { metric in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(metric.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(metric.value)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                            if let detail = metric.detail {
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let message = quota.status.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(quota.status.isOK ? Color.secondary : statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let source = quota.credentialSource {
                Text("via \(source)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(quota.status.isOK ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct EmptyStateView: View {
    var authFiles: [String]
    var usesExternalAuthFiles: Bool = true
    var onOpenConfig: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No credentials found")
                .font(.system(size: 12, weight: .semibold))
            Text("Credentials live in the `credentials` section of config.json. Run --migrate-auth to copy in the keys your CLI agents already hold.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !usesExternalAuthFiles {
                Text("External auth files are disabled, so config.json is the only source.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if authFiles.isEmpty {
                Text("No external auth files detected on this machine.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("External files detected:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(authFiles, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Open config", action: onOpenConfig)
                    .controlSize(.small)
                Button("Retry", action: onRefresh)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
