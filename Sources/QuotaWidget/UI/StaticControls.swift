import SwiftUI

/// `ImageRenderer` cannot draw AppKit-backed controls — buttons, toggles and
/// pickers come out as "unavailable" placeholders. These stand-ins draw the
/// same label content statically so `--preview` screenshots show the real
/// layout. They are only used in `RenderMode.offscreen`; the live panel always
/// builds the interactive control.
enum StaticControls {
    struct Icon: View {
        var systemName: String
        var size: CGFloat = 12

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }

    struct TextButton: View {
        var title: String
        var size: CGFloat = 11

        var body: some View {
            SwiftUI.Text(title).font(.system(size: size))
        }
    }

    /// A radio group, drawn as the rows the real picker would show.
    struct RadioGroup<Value: Hashable>: View {
        var options: [(value: Value, title: String)]
        var selection: Value

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(options, id: \.value) { option in
                    HStack(spacing: 5) {
                        Image(systemName: option.value == selection
                            ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(option.value == selection ? Color.accentColor : .secondary)
                        SwiftUI.Text(option.title).font(.system(size: 11))
                    }
                }
            }
        }
    }

    struct Checkbox: View {
        var title: String
        var isOn: Bool
        var size: CGFloat = 11

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: size))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                SwiftUI.Text(title).font(.system(size: size))
            }
        }
    }

    struct MenuLabel: View {
        var title: String

        var body: some View {
            HStack(spacing: 2) {
                SwiftUI.Text(title).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
        }
    }
}
