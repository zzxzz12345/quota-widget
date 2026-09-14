import Foundation
import SwiftUI

enum ProviderStatus: Equatable {
    case ok
    case notConfigured(String)
    case failed(String)

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .ok: return nil
        case .notConfigured(let text), .failed(let text): return text
        }
    }

    var isNotConfigured: Bool {
        if case .notConfigured = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A single metered window (5-hour, weekly, monthly, budget…) for a provider.
struct QuotaWindow: Identifiable, Equatable {
    let id: String
    var label: String
    var used: Double?
    var limit: Double?
    /// Canonical value when the provider reports a percentage directly.
    var remainingPercent: Double?
    var resetAt: Date?
    var unit: String?

    init(
        id: String,
        label: String,
        used: Double? = nil,
        limit: Double? = nil,
        remainingPercent: Double? = nil,
        resetAt: Date? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.unit = unit
    }

    var resolvedRemainingPercent: Double? {
        if let percent = remainingPercent { return clamp(percent) }
        guard let used, let limit, limit > 0 else { return nil }
        return clamp((1 - used / limit) * 100)
    }

    var usedPercent: Double? {
        resolvedRemainingPercent.map { clamp(100 - $0) }
    }

    var remaining: Double? {
        if let used, let limit { return max(0, limit - used) }
        return nil
    }

    private func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

/// A scalar fact that has no natural used/limit ratio (balances, spend, token totals).
struct QuotaMetric: Identifiable, Equatable {
    let id: String
    var label: String
    var value: String
    var detail: String?
}

struct ProviderQuota: Identifiable, Equatable {
    let id: String
    var name: String
    var plan: String?
    var account: String?
    var windows: [QuotaWindow] = []
    var metrics: [QuotaMetric] = []
    var status: ProviderStatus = .ok
    var updatedAt: Date?
    var credentialSource: String?

    /// Drives the menu bar summary: the tightest window across the tightest provider.
    var worstRemainingPercent: Double? {
        windows.compactMap(\.resolvedRemainingPercent).min()
    }

    /// Windows in 5h / 1w / 1m order, which is the order they are displayed in.
    var orderedWindows: [QuotaWindow] {
        windows.enumerated().sorted { left, right in
            let leftRank = QuotaWindowOrder.rank(left.element)
            let rightRank = QuotaWindowOrder.rank(right.element)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// 5h / 1w / 1m readings, for the compact menu bar label.
    var primaryWindows: [QuotaWindow] {
        orderedWindows.filter { $0.resolvedRemainingPercent != nil }.prefix(3).map { $0 }
    }

    static func notConfigured(id: String, name: String, reason: String) -> ProviderQuota {
        ProviderQuota(id: id, name: name, status: .notConfigured(reason))
    }

    /// `credentialSource` is recorded on failures too, so it is possible to tell
    /// *which* stored credential a provider was using when it failed.
    static func failed(
        id: String,
        name: String,
        error: String,
        credentialSource: String? = nil
    ) -> ProviderQuota {
        ProviderQuota(id: id, name: name, status: .failed(error), credentialSource: credentialSource)
    }
}

/// Sort key that puts the rolling 5-hour window first, then weekly, then monthly.
enum QuotaWindowOrder {
    static func rank(_ window: QuotaWindow) -> Int {
        let haystack = (window.id + " " + window.label).lowercased()
        if haystack.contains("5h") || haystack.contains("five") || haystack.contains("5 hour")
            || haystack.contains("rolling") || haystack.contains("session") {
            return 0
        }
        if haystack.contains("1w") || haystack.contains("week") || haystack.contains("7d")
            || haystack.contains("seven") {
            return 1
        }
        if haystack.contains("1m") || haystack.contains("month") || haystack.contains("30d") {
            return 2
        }
        return 3
    }
}

enum QuotaPalette {
    static func color(forRemaining percent: Double) -> Color {
        switch percent {
        case ..<10: return .red
        case ..<25: return .orange
        case ..<50: return .yellow
        default: return .green
        }
    }

    static func color(for status: ProviderStatus) -> Color {
        switch status {
        case .ok: return .green
        case .notConfigured: return .secondary
        case .failed: return .red
        }
    }
}

enum QuotaFormat {
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func number(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.0fk", value / 1_000) }
        if magnitude >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }

    static func compact(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if totalMinutes > 0 { return "\(totalMinutes)m" }
        return "<1m"
    }

    /// Short, locale-stable date and time, so a card does not mix languages.
    static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func resetDescription(for date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        // Pinned to en_US_POSIX so the timestamp does not switch language under
        // an English UI on a non-English system.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d HH:mm"
        return "resets \(formatter.string(from: date)) · in \(countdown(to: date, now: now))"
    }
}
