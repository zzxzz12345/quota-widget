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

    /// Built-in types not already in the panel. `custom` is excluded because it
    /// needs a URL, which this panel does not collect.
    var addableTypes: [String] {
        let present = Set(config.providers.map(\.type))
        return ProviderRegistry.knownTypeIDs.filter { $0 != "custom" && !present.contains($0) }
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

    mutating func addProvider(_ type: String) {
        guard !config.providers.contains(where: { $0.type == type }) else { return }
        config.providers.append(ProviderConfig(type: type))
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
}
