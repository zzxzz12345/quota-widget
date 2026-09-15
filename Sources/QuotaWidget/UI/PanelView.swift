import AppKit
import SwiftUI
import ServiceManagement

struct PanelView: View {
    @ObservedObject var service: QuotaService
    @State private var showingSettings = false

    /// `ImageRenderer` cannot lay out a `ScrollView` or resolve `TimelineView`,
    /// so offscreen rendering asks for a fully static composition.
    enum RenderMode { case live, offscreen }

    var renderMode: RenderMode = .live

    private var warnThreshold: Double { service.config.warnThreshold ?? 25 }
    private var criticalThreshold: Double { service.config.criticalThreshold ?? 10 }

    /// Onboarding copy is only accurate when nothing resolved a credential at
    /// all. A provider that errored *has* credentials and explains itself.
    private var showsOnboarding: Bool {
        !service.quotas.isEmpty && service.quotas.allSatisfy { $0.status.isNotConfigured }
    }

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(service: service) { showingSettings = false }
            } else {
                panel
            }
        }
        .frame(width: 360)
        .background(renderMode == .offscreen ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let warning = service.configWarning {
                banner(warning)
            }

            if let message = service.consolidationMessage {
                notice(message, tint: .green) {
                    Button("Dismiss") { service.dismissConsolidationMessage() }
                        .controlSize(.small)
                }
            } else if !service.externalCredentials.isEmpty {
                credentialNotice
            } else if let sharedCredential = service.configNotices.first {
                notice(sharedCredential, tint: .orange) {
                    Button("Settings") { showingSettings = true }
                        .controlSize(.small)
                }
            }

            content

            Divider()
            footer
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.trackedQuota.map { "\($0.name)" } ?? "Coding Plan Quota")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if renderMode == .offscreen {
                HStack(spacing: 10) {
                    StaticControls.Icon(systemName: "arrow.clockwise")
                    StaticControls.Icon(systemName: "slider.horizontal.3")
                }
            } else {
                Button {
                    Task { await service.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(service.isRefreshing)
                .help("Refresh now")

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Choose the tracked plan and providers")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        if service.isRefreshing && !service.hasLoadedOnce { return "Loading…" }
        guard let last = service.lastRefresh else { return "Not refreshed yet" }
        let counts = service.counts
        var parts: [String] = ["Updated \(QuotaFormat.elapsed(since: last))"]
        if counts.ok > 0 { parts.append("\(counts.ok) live") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.unconfigured > 0 { parts.append("\(counts.unconfigured) unconfigured") }
        return parts.joined(separator: " · ")
    }

    /// Credentials are being read from an agent database or auth file rather
    /// than from config.json. One click moves them in.
    private var credentialNotice: some View {
        let sources = Set(service.externalCredentials.map(\.origin)).sorted()
        let names = service.externalCredentials.map(\.name)
        let count = names.count
        return notice(
            "\(count) credential\(count == 1 ? "" : "s") (\(names.joined(separator: ", "))) "
                + "still read from \(sources.joined(separator: ", "))",
            tint: .orange
        ) {
            Button("Copy into config.json") { service.consolidateCredentials() }
                .controlSize(.small)
        }
    }

    private func notice<Actions: View>(
        _ text: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var content: some View {
        if service.isRefreshing && !service.hasLoadedOnce {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching quota…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if service.quotas.isEmpty {
            Text("No providers enabled. Add one in the config file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else if renderMode == .offscreen {
            cards(now: Date())
        } else {
            // Ticks the countdowns while the panel stays open.
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                ScrollView {
                    cards(now: timeline.date)
                }
                .frame(maxHeight: 460)
            }
        }
    }

    private func cards(now: Date) -> some View {
        VStack(spacing: 8) {
            if showsOnboarding {
                EmptyStateView(
                    authFiles: CredentialStore(config: service.config)
                        .discoveredAuthFilePaths
                        .filter { $0 != CredentialStore.configSourceLabel },
                    usesExternalAuthFiles: service.config.readsExternalAuthFiles,
                    onOpenConfig: openConfig,
                    onRefresh: { Task { await service.refresh() } }
                )
            }
            ForEach(service.quotas) { quota in
                ProviderCard(
                    quota: quota,
                    warnThreshold: warnThreshold,
                    criticalThreshold: criticalThreshold,
                    now: now
                )
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if renderMode == .offscreen {
                StaticControls.TextButton(title: "Config")
                StaticControls.TextButton(title: "Copy JSON")
                Spacer()
                StaticControls.Checkbox(title: "Login", isOn: LoginItem.isEnabled)
                StaticControls.TextButton(title: "Quit")
            } else {
                Button("Config") { openConfig() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Copy JSON") { copyJSON() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Spacer()
                Toggle("Login", isOn: loginItemBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Launch Quota Widget at login")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Actions

    private func openConfig() {
        try? ConfigStore.writeTemplate()
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    private func copyJSON() {
        let payload = CLIReport.render(quotas: service.quotas, lastRefresh: service.lastRefresh)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.setEnabled($0) }
        )
    }
}

/// Thin wrapper over `SMAppService` so the toggle stays a one-liner in the view.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("QuotaWidget: could not change login item: \(error.localizedDescription)")
        }
    }
}
