import Foundation
import Testing
@testable import QuotaWidget

private func draft(_ providers: [ProviderConfig], tracked: String? = nil) -> SettingsDraft {
    var config = QuotaWidgetConfig.default
    config.providers = providers
    config.menuBarProvider = tracked
    return SettingsDraft(config)
}

@Suite struct SettingsDraftTests {
    private var threeProviders: [ProviderConfig] {
        [
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "opencode-go"),
            ProviderConfig(type: "ollama-cloud", enabled: false)
        ]
    }

    @Test func disableReleasesTracking() {
        var d = draft(threeProviders, tracked: "opencode-go")
        #expect(d.trackedID == "opencode-go")
        d.setEnabled(false, at: 1)
        // A disabled plan cannot stay tracked.
        #expect(d.trackedID == nil)
        #expect(d.providers[1].isEnabled == false)
    }

    @Test func disablingAnotherProviderLeavesTrackingAlone() {
        var d = draft(threeProviders, tracked: "commandcode")
        d.setEnabled(false, at: 1)
        #expect(d.trackedID == "commandcode")
    }

    @Test func removalReleasesTracking() {
        var d = draft(threeProviders, tracked: "opencode-go")
        d.removeProvider(at: 1)
        #expect(d.trackedID == nil)
        #expect(d.providers.map(\.type) == ["commandcode", "ollama-cloud"])
    }

    @Test func removingAnUntrackedProviderKeepsTracking() {
        var d = draft(threeProviders, tracked: "commandcode")
        d.removeProvider(at: 1)
        #expect(d.trackedID == "commandcode")
    }

    /// Tracking an unknown or disabled provider is refused rather than stored.
    @Test func trackingRequiresAnEnabledProvider() {
        var d = draft(threeProviders)
        d.setTracked("ollama-cloud")   // present but disabled
        #expect(d.trackedID == nil)

        d.setTracked("nope")
        #expect(d.trackedID == nil)

        d.setTracked("opencode-go")
        #expect(d.trackedID == "opencode-go")
    }

    @Test func trackingCanBeCleared() {
        var d = draft(threeProviders, tracked: "commandcode")
        d.setTracked(nil)
        #expect(d.trackedID == nil)
    }

    @Test func enablingAProviderMakesItTrackable() {
        var d = draft(threeProviders)
        d.setEnabled(true, at: 2)
        d.setTracked("ollama-cloud")
        #expect(d.trackedID == "ollama-cloud")
    }

    @Test func addingSkipsDuplicatesAndCustom() {
        var d = draft(threeProviders)
        #expect(!d.addableTypes.contains("custom"))
        #expect(!d.addableTypes.contains("commandcode"))
        #expect(d.addableTypes.contains("zai"))

        let before = d.providers.count
        d.addProvider("zai")
        #expect(d.providers.count == before + 1)
        #expect(d.providers.last?.isEnabled == true)

        // Adding the same type twice is a no-op.
        d.addProvider("zai")
        #expect(d.providers.count == before + 1)
    }

    @Test func styleRoundTripsThroughTheConfig() {
        var d = draft(threeProviders)
        #expect(d.style == .windows)   // default
        d.setStyle(.labeled)
        #expect(d.config.menuBarStyle == "labeled")
        #expect(d.style == .labeled)
    }

    @Test func unknownStoredStyleFallsBackToTheDefault() {
        var config = QuotaWidgetConfig.default
        config.menuBarStyle = "something-else"
        #expect(SettingsDraft(config).style == .windows)
    }

    @Test func emptyProviderListIsRejected() {
        var d = draft([])
        #expect(d.validationError() != nil)
        d.addProvider("deepseek")
        #expect(d.validationError() == nil)
    }

    /// The panel must never rewrite or drop the credential vault.
    @Test func credentialsArePreservedThroughEdits() throws {
        var config = QuotaWidgetConfig.default
        config.credentials = [
            "deepseek": CredentialEntry(type: "api", key: "secret"),
            "commandcode": CredentialEntry(type: "api", key: "user_x")
        ]
        var d = SettingsDraft(config)
        d.setEnabled(false, at: 0)
        d.addProvider("zai")
        d.setTracked("zai")
        d.setStyle(.worst)

        let data = try JSONEncoder().encode(d.config)
        let reloaded = try JSONDecoder().decode(QuotaWidgetConfig.self, from: data)
        #expect(reloaded.credentials?.count == 2)
        #expect(reloaded.credentials?["deepseek"]?.key == "secret")
        #expect(reloaded.menuBarProvider == "zai")
        #expect(reloaded.menuBarStyle == "worst")
    }

    @Test func outOfRangeEditsAreIgnored() {
        var d = draft(threeProviders)
        d.setEnabled(false, at: 99)
        d.removeProvider(at: 99)
        #expect(d.providers.count == 3)
        #expect(d.providers.allSatisfy(\.isEnabled) == false || d.providers[2].isEnabled == false)
    }
}

@MainActor
@Suite struct MenuBarLabelTests {
    private func service(_ windows: [QuotaWindow], style: MenuBarStyle, showText: Bool = true) -> QuotaService {
        var config = QuotaWidgetConfig.default
        config.menuBarStyle = style.rawValue
        config.showMenuBarText = showText
        config.providers = [ProviderConfig(type: "opencode-go")]
        return QuotaService(
            config: config,
            preloaded: [ProviderQuota(id: "opencode-go", name: "OpenCode Go", windows: windows)]
        )
    }

    private var threeWindows: [QuotaWindow] {
        [
            QuotaWindow(id: "rolling", label: "5h", remainingPercent: 20),
            QuotaWindow(id: "weekly", label: "1w", remainingPercent: 68),
            QuotaWindow(id: "monthly", label: "1m", remainingPercent: 84)
        ]
    }

    @Test func trackedQuotaIsTheTightestWhenUnpinned() {
        var config = QuotaWidgetConfig.default
        config.providers = [ProviderConfig(type: "a"), ProviderConfig(type: "b")]
        let service = QuotaService(config: config, preloaded: [
            ProviderQuota(id: "a", name: "A", windows: [QuotaWindow(id: "w", label: "1w", remainingPercent: 50)]),
            ProviderQuota(id: "b", name: "B", windows: [QuotaWindow(id: "w", label: "1w", remainingPercent: 12)])
        ])
        #expect(service.trackedQuota?.id == "b")
    }

    @Test func pinnedQuotaWins() {
        var config = QuotaWidgetConfig.default
        config.menuBarProvider = "a"
        config.providers = [ProviderConfig(type: "a"), ProviderConfig(type: "b")]
        let service = QuotaService(config: config, preloaded: [
            ProviderQuota(id: "a", name: "A", windows: [QuotaWindow(id: "w", label: "1w", remainingPercent: 50)]),
            ProviderQuota(id: "b", name: "B", windows: [QuotaWindow(id: "w", label: "1w", remainingPercent: 12)])
        ])
        #expect(service.trackedQuota?.id == "a")
    }

    /// Pinning a failing plan shows the failure instead of switching plans.
    @Test func pinnedFailingPlanIsStillReported() {
        var config = QuotaWidgetConfig.default
        config.menuBarProvider = "a"
        config.providers = [ProviderConfig(type: "a"), ProviderConfig(type: "b")]
        let service = QuotaService(config: config, preloaded: [
            ProviderQuota.failed(id: "a", name: "A", error: "no key"),
            ProviderQuota(id: "b", name: "B", windows: [QuotaWindow(id: "w", label: "1w", remainingPercent: 90)])
        ])
        #expect(service.trackedQuota?.id == "a")
    }

    @Test func primaryWindowsAreOrdered5h1w1m() {
        let service = self.service(threeWindows.reversed(), style: .windows)
        #expect(service.trackedQuota?.primaryWindows.map(\.label) == ["5h", "1w", "1m"])
    }

    @Test func stylesCoverTheThreeFormats() {
        #expect(MenuBarStyle.windows.example == "20/68/84")
        #expect(MenuBarStyle.labeled.example == "5h20 1w68 1m84")
        #expect(MenuBarStyle.worst.example == "20%")
        #expect(MenuBarStyle.allCases.count == 3)
    }

    @Test func worstStyleNeedsTheTightestWindow() {
        let service = self.service(threeWindows, style: .worst)
        #expect(service.trackedQuota?.primaryWindows.compactMap(\.resolvedRemainingPercent).min() == 20)
    }
}
