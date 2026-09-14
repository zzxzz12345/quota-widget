import AppKit
import SwiftUI

/// Renders the dropdown panel to a PNG without opening a window. Used by
/// `--preview` to eyeball the layout against real provider payloads, and handy
/// for regenerating documentation screenshots.
@MainActor
enum PanelRenderer {
    static func write(
        to path: String,
        service: QuotaService,
        width: CGFloat = 360,
        settings: Bool = false
    ) throws {
        // ImageRenderer needs AppKit initialized, but the app must not activate.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let content = Group {
            if settings {
                SettingsView(service: service, renderMode: .offscreen, onDone: {})
            } else {
                PanelView(service: service, renderMode: .offscreen)
            }
        }
        .frame(width: width)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.failed
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    enum RenderError: LocalizedError {
        case failed

        var errorDescription: String? { "SwiftUI failed to render the panel" }
    }
}
