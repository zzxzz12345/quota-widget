import Foundation

/// Editable copy of the config behind the settings panel.
///
/// The mutations live here rather than in the view so the rules that keep the
/// config coherent — a disabled provider cannot be the tracked one, removing a
/// provider releases the tracking — are testable without a window.
struct SettingsDraft {
    var config: QuotaWidgetConfig

    init(_ config: QuotaWidgetConfig) {
        self.config = config
    }

    var providers: [ProviderConfig] { config.providers }

    var enabledProviders: [ProviderConfig] { config.providers.filter(\.isEnabled) }

    var trackedID: String? { config.menuBarProvider }

    var style: MenuBarStyle { config.menuBarStyleResolved }

    /// Every built-in type, including ones already in the panel — a second
    /// account of the same provider is a supported setup. `custom` is excluded
    /// because it needs a URL, which this panel does not collect.
    var addableTypes: [String] {
        ProviderRegistry.knownTypeIDs.filter { $0 != "custom" }
    }

    /// Title for one row, e.g. `Z.ai Coding Plan (2)`.
    func displayName(at index: Int) -> String {
        config.displayName(at: index)
    }

    /// Options for the tracked-plan picker. The empty value means "tightest
    /// across all"; every enabled entry gets its distinguishing title, so two
    /// accounts of one provider are not listed as two identical rows.
    func trackedOptions() -> [(value: String, title: String)] {
        [(value: "", title: "Tightest across all")]
            + config.providers.enumerated()
                .filter { $0.element.isEnabled }
                .map { (value: $0.element.resolvedID, title: config.displayName(at: $0.offset)) }
    }

    mutating func setEnabled(_ enabled: Bool, at index: Int) {
        guard config.providers.indices.contains(index) else { return }
        config.providers[index].enabled = enabled
        if !enabled {
            releaseTrackingIfNeeded(removing: [config.providers[index].resolvedID])
        }
    }

    mutating func setTracked(_ id: String?) {
        guard let id else {
            config.menuBarProvider = nil
            return
        }
        // Only an enabled, present provider can be tracked.
        let exists = config.providers.contains { $0.resolvedID == id && $0.isEnabled }
        config.menuBarProvider = exists ? id : nil
    }

    mutating func setStyle(_ style: MenuBarStyle) {
        config.menuBarStyle = style.rawValue
    }

    mutating func setShowMenuBarText(_ show: Bool) {
        config.showMenuBarText = show
    }

    /// Appends a provider, giving it an explicit `id` when the type is already
    /// present so the two entries stay distinguishable.
    mutating func addProvider(_ type: String) {
        var provider = ProviderConfig(type: type)
        let duplicates = config.providers.filter { $0.type == type }.count
        if duplicates > 0 {
            var suffix = duplicates + 1
            var candidate = "\(type)-\(suffix)"
            let taken = Set(config.providers.map(\.resolvedID))
            while taken.contains(candidate) {
                suffix += 1
                candidate = "\(type)-\(suffix)"
            }
            provider.id = candidate
        }
        config.providers.append(provider)
    }

    /// Renames a row. An empty value falls back to the generated title.
    mutating func setName(_ name: String, at index: Int) {
        guard config.providers.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        config.providers[index].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Renames the identity a tracked plan and `--provider` refer to. Refuses
    /// values that are empty or already taken.
    mutating func setID(_ id: String, at index: Int) -> Bool {
        guard config.providers.indices.contains(index) else { return false }
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let taken = Set(config.providers.enumerated()
            .filter { $0.offset != index }
            .map { $0.element.resolvedID })
        guard !taken.contains(trimmed) else { return false }

        let previous = config.providers[index].resolvedID
        config.providers[index].id = trimmed
        // Keep the menu bar pointed at the same entry after a rename.
        if config.menuBarProvider == previous {
            config.menuBarProvider = trimmed
        }
        return true
    }

    mutating func removeProvider(at index: Int) {
        guard config.providers.indices.contains(index) else { return }
        let removed = config.providers[index].resolvedID
        config.providers.remove(at: index)
        releaseTrackingIfNeeded(removing: [removed])
    }

    /// Clears the tracked plan when the provider it names is gone or off.
    private mutating func releaseTrackingIfNeeded(removing ids: [String]) {
        guard let tracked = config.menuBarProvider, ids.contains(tracked) else { return }
        config.menuBarProvider = nil
    }

    /// Last line of defence before writing: the panel must keep at least one
    /// provider, and the credential vault is never touched by this panel.
    func validationError() -> String? {
        if config.providers.isEmpty {
            return "Keep at least one provider, or the panel has nothing to show."
        }
        return nil
    }

    /// Non-blocking problems worth surfacing before saving.
    func warnings() -> [String] {
        var messages: [String] = []
        for group in config.sharedCredentialGroups() {
            messages.append(
                "\(group.joined(separator: " and ")) would use the same credential — "
                + "give each a different `credential` entry to track two accounts."
            )
        }
        return messages
    }
}
