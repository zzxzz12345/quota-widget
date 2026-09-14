import AppKit
import SwiftUI

/// In-panel configuration: which plan the menu bar tracks, how it summarises it,
/// and which providers are enabled. Writes straight back to `config.json`, so
/// the panel and the file never disagree.
struct SettingsView: View {
    @ObservedObject var service: QuotaService
    @State private var draft: SettingsDraft
    @State private var saveError: String?
    var onDone: () -> Void
    /// `ImageRenderer` cannot lay out a `ScrollView`, so `--preview --settings`
    /// asks for a static composition.
    var renderMode: PanelView.RenderMode = .live

    init(
        service: QuotaService,
        renderMode: PanelView.RenderMode = .live,
        onDone: @escaping () -> Void
    ) {
        self.service = service
        self.renderMode = renderMode
        _draft = State(initialValue: SettingsDraft(service.config))
        self.onDone = onDone
    }

    private var enabledProviders: [ProviderConfig] { draft.enabledProviders }
    private var addableTypes: [String] { draft.addableTypes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if renderMode == .offscreen {
                sections
            } else {
                ScrollView { sections }
                    .frame(maxHeight: 400)
            }
            Divider()
            footer
        }
    }

    // MARK: - Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            trackedPlanSection
            menuBarSection
            providersSection
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Button("Done", action: commit)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var trackedPlanSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Tracked plan", "Shown in the menu bar as 5h / 1w / 1m.")

            Picker("", selection: Binding(
                get: { draft.trackedID ?? "" },
                set: { draft.setTracked($0.isEmpty ? nil : $0) }
            )) {
                Text("Tightest across all").tag("")
                ForEach(enabledProviders, id: \.resolvedID) { provider in
                    Text(displayName(for: provider)).tag(provider.resolvedID)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Menu bar", nil)

            Picker("", selection: Binding(
                get: { draft.style },
                set: { draft.setStyle($0) }
            )) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text("\(style.title)  ·  \(style.example)").tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            Toggle("Show the numbers next to the icon", isOn: Binding(
                get: { draft.config.showMenuBarText ?? true },
                set: { draft.setShowMenuBarText($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionTitle("Providers", nil)
                Spacer()
                if !addableTypes.isEmpty {
                    Menu("Add") {
                        ForEach(addableTypes, id: \.self) { type in
                            Button(ProviderRegistry.defaultName(for: type)) {
                                addProvider(type)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 11))
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(draft.providers.enumerated()), id: \.element.resolvedID) { index, provider in
                    providerRow(index: index, provider: provider)
                    if index < draft.providers.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.07)))

            Text("Credentials stay in config.json; add a key by editing the file or running --migrate-auth.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerRow(index: Int, provider: ProviderConfig) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { provider.isEnabled },
                set: { draft.setEnabled($0, at: index) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(displayName(for: provider))
                .font(.system(size: 11.5))
                .foregroundStyle(provider.isEnabled ? .primary : .secondary)

            if draft.trackedID == provider.resolvedID {
                Badge(text: "tracked", tint: .accentColor)
            }

            Spacer(minLength: 6)

            Button {
                removeProvider(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Remove from the panel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Open config file") {
                try? ConfigStore.writeTemplate()
                NSWorkspace.shared.open(ConfigStore.fileURL)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ text: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    private func displayName(for provider: ProviderConfig) -> String {
        provider.name ?? ProviderRegistry.defaultName(for: provider.type)
    }

    private func addProvider(_ type: String) {
        draft.addProvider(type)
    }

    private func removeProvider(at index: Int) {
        draft.removeProvider(at: index)
    }

    /// Persists the draft, then refreshes so the panel reflects it immediately.
    private func commit() {
        if let problem = draft.validationError() {
            saveError = problem
            return
        }
        do {
            try ConfigStore.write(draft.config)
            saveError = nil
            service.applyConfig(draft.config)
            onDone()
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }
}
