import Foundation

struct ProviderContext {
    var credentials: CredentialStore
    var http: HTTPClient
    var config: ProviderConfig
}

protocol QuotaProvider {
    /// Registry key and default config `type`. An instance property because a
    /// single type can serve several variants (Z.ai vs Zhipu, MiniMax intl vs CN).
    var typeID: String { get }
    /// Human-friendly fallback used when the config omits `name`.
    var displayName: String { get }
    func fetch(_ context: ProviderContext) async -> ProviderQuota
}

enum ProviderRegistry {
    private static let providers: [String: QuotaProvider] = {
        let all: [QuotaProvider] = [
            CommandCodeProvider(),
            ZaiProvider(variant: .zai),
            ZaiProvider(variant: .zhipu),
            KimiProvider(),
            MiniMaxProvider(variant: .international),
            MiniMaxProvider(variant: .china),
            OpenCodeGoProvider(),
            OllamaCloudProvider(),
            DeepSeekProvider(),
            OpenAIProvider(),
            AnthropicProvider(),
            OpenRouterProvider(),
            CustomProvider()
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.typeID, $0) })
    }()

    static var knownTypeIDs: [String] { providers.keys.sorted() }

    static func provider(for type: String) -> QuotaProvider? { providers[type] }

    static func defaultName(for type: String) -> String {
        providers[type]?.displayName ?? type
    }

    /// Credential names in `config.json` that a provider type will consume, most
    /// specific first. Shared by credential resolution and by `--migrate-auth`.
    static func credentialAliases(for type: String) -> [String] {
        switch type {
        case "commandcode": return ["command-code", "commandcode"]
        case "zai": return ["zai-coding-plan", "zai", "glm"]
        case "zhipu": return ["zhipu-coding-plan", "zhipu", "bigmodel", "glm"]
        case "kimi": return ["kimi-for-coding", "kimi", "kimi-coding-plan", "moonshot"]
        case "minimax": return ["minimax-coding-plan", "minimax", "minimax-token-plan"]
        case "minimax-cn":
            return ["minimax-cn-coding-plan", "minimax-cn", "minimax-china-coding-plan", "minimax-china"]
        case "deepseek": return ["deepseek"]
        case "openrouter": return ["openrouter"]
        case "opencode-go": return ["opencode-go"]
        case "ollama-cloud": return ["ollama-cloud", "ollama"]
        case "openai": return ["openai", "codex", "chatgpt"]
        case "anthropic": return ["anthropic", "claude"]
        default: return []
        }
    }
}

// MARK: - Timestamp parsing

enum TimeParse {
    /// Accepts ISO-8601 strings, epoch seconds, epoch milliseconds, and
    /// relative "seconds from now" offsets. Upstream APIs use all four.
    static func date(_ json: JSON?) -> Date? {
        guard let json else { return nil }
        if let text = json.string { return date(fromString: text) }
        if let number = json.double { return date(fromEpoch: number) }
        return nil
    }

    static func date(fromString text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let epoch = Double(trimmed) { return date(fromEpoch: epoch) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = fallback.date(from: trimmed) { return date }
        fallback.dateFormat = "yyyy-MM-dd"
        return fallback.date(from: trimmed)
    }

    static func date(fromEpoch value: Double) -> Date? {
        guard value > 0, value.isFinite else { return nil }
        // Anything past ~2001 in seconds is too small to be milliseconds.
        let seconds = value >= 1e12 ? value / 1000 : value
        let date = Date(timeIntervalSince1970: seconds)
        // Reject absurd values rather than rendering "resets in 50000d".
        guard date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    static func date(fromOffsetSeconds value: Double) -> Date? {
        guard value > 0, value.isFinite else { return nil }
        return Date(timeIntervalSinceNow: value)
    }

    /// Tries absolute reset fields first, then relative offsets.
    static func reset(in json: JSON?, absolute: [String], relative: [String]) -> Date? {
        for pointer in absolute {
            if let date = date(json?.path(pointer)) { return date }
        }
        for pointer in relative {
            if let seconds = json?.path(pointer)?.double, let date = date(fromOffsetSeconds: seconds) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Shared parsing helpers

enum Parse {
    /// First finite, non-negative number across candidate pointers.
    static func number(_ json: JSON?, _ pointers: [String]) -> Double? {
        guard let json else { return nil }
        for pointer in pointers {
            if let value = json.path(pointer)?.double, value.isFinite { return value }
        }
        return nil
    }

    static func string(_ json: JSON?, _ pointers: [String]) -> String? {
        guard let json else { return nil }
        for pointer in pointers {
            if let value = json.path(pointer)?.string {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func array(_ json: JSON?, _ pointers: [String]) -> [JSON]? {
        guard let json else { return nil }
        for pointer in pointers {
            if let value = json.path(pointer)?.array { return value }
        }
        return nil
    }

    /// Prefers a provider-declared remaining percentage over derivable used/limit.
    static func window(
        id: String,
        label: String,
        json: JSON?,
        used: [String] = ["used", "used_count", "usage", "current_interval_usage_count"],
        limit: [String] = ["limit", "cap", "total", "current_interval_total_count"],
        remainingPercent: [String] = ["remainingPercent", "remaining_percent", "percentRemaining", "current_interval_remaining_percent"],
        usedPercent: [String] = ["percentage", "used_percent", "usedPercent", "current_interval_used_percent"],
        resetAt: [String] = ["resetAt", "reset_at", "resetTime", "nextResetTime"],
        resetAfter: [String] = ["reset_in", "resetIn", "remains_time", "reset_after_seconds", "ttl"],
        unit: String? = nil
    ) -> QuotaWindow? {
        var remaining = number(json, remainingPercent)
        if remaining == nil, let used = number(json, usedPercent) {
            remaining = 100 - used
        }
        let usedValue = number(json, used)
        let limitValue = number(json, limit)
        let reset = TimeParse.reset(in: json, absolute: resetAt, relative: resetAfter)

        // A window with no numeric signal at all is not worth rendering.
        guard remaining != nil || (usedValue != nil && limitValue != nil) || limitValue != nil else {
            return nil
        }
        return QuotaWindow(
            id: id,
            label: label,
            used: usedValue,
            limit: limitValue,
            remainingPercent: remaining,
            resetAt: reset,
            unit: unit
        )
    }

    static func metric(_ label: String, _ json: JSON?, _ pointers: [String], unit: String? = nil) -> QuotaMetric? {
        guard let value = number(json, pointers) else { return nil }
        return QuotaMetric(id: label, label: label, value: QuotaFormat.number(value), detail: unit)
    }
}
