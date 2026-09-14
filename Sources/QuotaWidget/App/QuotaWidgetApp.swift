import AppKit
import SwiftUI

@main
struct QuotaWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // `--json` / `--check` / `--preview` run headless and never open a window.
        _ = CLIRunner.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(service: delegate.service)
        } label: {
            MenuBarLabel(service: delegate.service)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the service so the first refresh happens at launch. Starting it from the
/// panel's `onAppear` would leave the menu bar blank until the user clicked it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let service = QuotaService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.start()
    }
}
