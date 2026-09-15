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

    @Test func addableTypesExcludeOnlyCustom() {
        let d = draft(threeProviders)
        // Already-present types stay available: a second account is supported.
        #expect(!d.addableTypes.contains("custom"))
        #expect(d.addableTypes.contains("commandcode"))
        #expect(d.addableTypes.contains("zai"))
    }

    /// The core of two-accounts support: the second entry gets its own id.
    @Test func addingTheSameTypeTwiceCreatesDistinctEntries() {
        var d = draft(threeProviders)
        let before = d.providers.count

        d.addProvider("commandcode")            // already present
        #expect(d.providers.count == before + 1)
        #expect(d.providers.last?.id == "commandcode-2")

        d.addProvider("commandcode")
        #expect(d.providers.last?.id == "commandcode-3")

        let ids = d.providers.map(\.resolvedID)
        #expect(Set(ids).count == ids.count, "ids must stay unique: \(ids)")
    }

    @Test func secondInstanceGetsADistinguishingTitle() {
        var d = draft(threeProviders)
        d.addProvider("commandcode")
        let titles = d.providers.indices.map { d.displayName(at: $0) }
        #expect(titles.contains("Command Code"))
        #expect(titles.contains("Command Code (2)"))
    }

    @Test func explicitNameWinsOverTheGeneratedTitle() {
        var d = draft(threeProviders)
        d.addProvider("commandcode")            // already present
        d.setName("Work account", at: d.providers.count - 1)
        #expect(d.displayName(at: d.providers.count - 1) == "Work account")

        // An empty name falls back to the generated title.
        d.setName("   ", at: d.providers.count - 1)
        #expect(d.displayName(at: d.providers.count - 1) == "Command Code (2)")
    }

    @Test func renamingAnIDKeepsTrackingPointedAtTheSameEntry() {
        var d = draft(threeProviders, tracked: "commandcode")
        let renamed = d.setID("work", at: 0)
        #expect(renamed)
        #expect(d.providers[0].resolvedID == "work")
        #expect(d.trackedID == "work")
    }

    @Test func setIDRefusesEmptyAndDuplicateValues() {
        var d = draft(threeProviders)
        let empty = d.setID("", at: 0)
        let blank = d.setID("   ", at: 0)
        let taken = d.setID("opencode-go", at: 0)
        #expect(!empty)
        #expect(!blank)
        #expect(!taken)
        #expect(d.providers[0].resolvedID == "commandcode")
    }

    /// Two entries of one type with no explicit credential read the same
    /// account, which is worth flagging before saving.
    @Test func sharingACredentialIsWarnedAbout() {
        var d = draft(threeProviders)
        #expect(d.warnings().isEmpty)

        d.addProvider("commandcode")
        let warnings = d.warnings()
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("same credential"))
    }

    @Test func namingDistinctCredentialsClearsTheWarning() {
        var d = draft(threeProviders)
        d.addProvider("commandcode")
        #expect(!d.warnings().isEmpty)

        d.config.providers[0].credential = "commandcode-work"
        d.config.providers[3].credential = "commandcode-personal"
        #expect(d.warnings().isEmpty)
    }

    @Test func disablingOneInstanceClearsTheWarning() {
        var d = draft(threeProviders)
        d.addProvider("commandcode")
        #expect(!d.warnings().isEmpty)
        d.setEnabled(false, at: 3)
        #expect(d.warnings().isEmpty)
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

@Suite struct ProviderIdentityTests {
    private func config(_ providers: [ProviderConfig]) -> QuotaWidgetConfig {
        var c = QuotaWidgetConfig.default
        c.providers = providers
        return c
    }

    /// Two implicit entries of one type previously shared `resolvedID == type`,
    /// which broke every lookup keyed on it.
    @Test func normalizationSeparatesImplicitDuplicates() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai")])
        let normalized = c.normalized()

        #expect(normalized.config.providers[0].resolvedID == "zai")
        #expect(normalized.config.providers[1].resolvedID == "zai-2")
        let warning = try! #require(normalized.warning)
        #expect(warning.contains("zai-2"))

        let ids = normalized.config.providers.map(\.resolvedID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func normalizationSeparatesExplicitCollisions() {
        let c = config([
            ProviderConfig(type: "zai", id: "mine"),
            ProviderConfig(type: "zhipu", id: "mine")
        ])
        let normalized = c.normalized()
        let ids = normalized.config.providers.map(\.resolvedID)
        #expect(Set(ids).count == 2)
        #expect(normalized.warning != nil)
    }

    @Test func normalizationLeavesAUniqueConfigAlone() {
        let c = config([
            ProviderConfig(type: "zai"),
            ProviderConfig(type: "kimi"),
            ProviderConfig(type: "zai", id: "work-zai")
        ])
        let normalized = c.normalized()
        #expect(normalized.warning == nil)
        #expect(normalized.config.providers.map(\.resolvedID) == ["zai", "kimi", "work-zai"])
    }

    @Test func normalizationIsIdempotent() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai")])
        let once = c.normalized().config
        let twice = once.normalized()
        #expect(twice.warning == nil)
        #expect(twice.config.providers.map(\.resolvedID) == ["zai", "zai-2"])
    }

    @Test func normalizationDoesNotTouchASingleProvider() {
        let c = config([ProviderConfig(type: "zai")])
        #expect(c.normalized().warning == nil)
        #expect(c.normalized().config.providers[0].id == nil)
    }

    @Test func ordinalsCountPerTypeNotGlobally() {
        let c = config([
            ProviderConfig(type: "zai"),
            ProviderConfig(type: "kimi"),
            ProviderConfig(type: "zai"),
            ProviderConfig(type: "zai")
        ])
        #expect([0, 1, 2, 3].map { c.ordinal(ofIndex: $0) } == [1, 1, 2, 3])
    }

    /// The whole point: the second card must be tellable apart from the first.
    @Test func duplicateEntriesGetNumberedTitles() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai")])
        #expect(c.displayName(at: 0) == "Z.ai Coding Plan")
        #expect(c.displayName(at: 1) == "Z.ai Coding Plan (2)")
    }

    @Test func singleEntryKeepsThePlainTitle() {
        let c = config([ProviderConfig(type: "opencode-go")])
        #expect(c.displayName(at: 0) == "OpenCode Go")
    }

    @Test func resolvedProvidersFillsNamesAndSkipsDisabled() {
        let c = config([
            ProviderConfig(type: "zai"),
            ProviderConfig(type: "zai", enabled: false),
            ProviderConfig(type: "kimi", name: "Personal")
        ])
        let resolved = c.resolvedProviders()
        #expect(resolved.count == 2)
        #expect(resolved[0].name == "Z.ai Coding Plan")
        #expect(resolved[1].name == "Personal")

        #expect(c.resolvedProviders(enabledOnly: false).count == 3)
    }

    /// The two entries must be distinguishable in the panel, which keys off the
    /// name a provider reports.
    @Test func resolvedProvidersNamesTheSecondInstance() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai")])
        let resolved = c.resolvedProviders()
        #expect(resolved.map(\.name) == ["Z.ai Coding Plan", "Z.ai Coding Plan (2)"])
    }

    @Test func sharedCredentialGroupsDetectsTheSameAccountTwice() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai")])
        let groups = c.sharedCredentialGroups()
        #expect(groups.count == 1)
        #expect(groups[0] == ["Z.ai Coding Plan", "Z.ai Coding Plan (2)"])
    }

    @Test func distinctCredentialReferencesAreNotFlagged() {
        var providers = [
            ProviderConfig(type: "zai"),
            ProviderConfig(type: "zai")
        ]
        providers[0].credential = "zai-work"
        providers[1].credential = "zai-personal"
        #expect(config(providers).sharedCredentialGroups().isEmpty)
    }

    @Test func aDisabledSecondInstanceIsNotFlagged() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "zai", enabled: false)])
        #expect(c.sharedCredentialGroups().isEmpty)
    }

    @Test func differentTypesAreNeverFlagged() {
        let c = config([ProviderConfig(type: "zai"), ProviderConfig(type: "kimi")])
        #expect(c.sharedCredentialGroups().isEmpty)
    }
}

@Suite struct TrackedPlanPickerTests {
    /// The reported bug: two accounts of one provider were listed identically,
    /// so picking the second was impossible.
    @Test func duplicateEntriesAreListedWithDistinctTitles() {
        var d = draft([
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "deepseek")
        ])
        d.config = d.config.normalized().config

        let options = d.trackedOptions()
        #expect(options.first?.value == "")            // "Tightest across all"
        #expect(options.count == 4)
        #expect(options.map(\.title) == [
            "Tightest across all", "Command Code", "Command Code (2)", "DeepSeek"
        ])
        let values = options.map(\.value)
        #expect(Set(values).count == values.count, "values must be unique: \(values)")
    }

    @Test func eachOptionSelectsItsOwnEntry() {
        var d = draft([
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "commandcode")
        ])
        d.config = d.config.normalized().config
        let options = d.trackedOptions()

        // Selecting the second option tracks the second entry, not the first.
        d.setTracked(options[2].value)
        #expect(d.trackedID == options[2].value)
        #expect(d.trackedID != d.providers[0].resolvedID)
    }

    @Test func disabledEntriesAreNotOffered() {
        var d = draft([
            ProviderConfig(type: "commandcode"),
            ProviderConfig(type: "commandcode", enabled: false)
        ])
        d.config = d.config.normalized().config
        let options = d.trackedOptions()
        #expect(options.count == 2)
        #expect(!options.dropFirst().contains { $0.title.contains("(2)") })
    }

    @Test func explicitNamesAreUsedInThePicker() {
        var d = draft([ProviderConfig(type: "commandcode"), ProviderConfig(type: "commandcode")])
        d.config = d.config.normalized().config
        d.setName("Work", at: 0)
        d.setName("Personal", at: 1)
        #expect(d.trackedOptions().map(\.title) == ["Tightest across all", "Work", "Personal"])
    }
}
