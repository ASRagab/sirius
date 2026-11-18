import SwiftUI

// The Settings window's controls, after Parrot's (parrot
// Sources/ParrotApp/UI/Pill.swift and SettingsWindow.swift): capsules with a
// light fill and no border, on rows that sit on the window background.

// A capsule with a light fill, with a chevron when it opens a menu.
struct PillLabel: View {
    let title: String
    var chevron = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .contentShape(Capsule())
    }
}

// A button drawn as a pill: `.pill` with the light fill of a PillLabel, or
// `.primaryPill` filled in the text color, for the one thing to do next.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill(pressed: configuration.isPressed)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
    }

    private func fill(pressed: Bool) -> Color {
        primary
            ? Color.primary.opacity(pressed ? 0.8 : 1)
            : Color.primary.opacity(pressed ? 0.14 : 0.08)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(primary: true) }
}

// A menu whose closed state is a PillLabel with a chevron.
struct PillMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu(content: content) {
            PillLabel(title: title, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// A row with its control centered beside the label; with a note, the note
// sits in the caption style under the label.
struct PillRow<Control: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let control: () -> Control

    init(_ label: String, note: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.note = note
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

// A titled group of rows, such as Keys.
struct SettingsGroup<Content: View>: View {
    let title: String
    // One sentence under the title saying what the page is for.
    var note: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.medium))
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }
}

// A switch on the right, as the other controls: outside a Form a toggle is
// a checkbox.
struct PillSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}
