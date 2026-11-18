import AppKit

// What the app behind the composer has open and selected, as one quiet
// line at the composer's bottom left: the app's favicon, the subject, and the
// selection (AmbientSummary). While it shows, the context goes with the
// message; the × that appears under the pointer takes it off this message.
// It is a status, not a control: no fill and no border.
// TODO(copy): not in the Figma design.
@MainActor
final class ContextLine: NSView {
    struct Model: Equatable {
        var subject: String
        var selection: String?
        var app: String
        // The app's icon, shown when the app has no favicon.
        var icon: NSImage?
        // The app's favicon file, as read (AmbientFavicon).
        var favicon: Data?
        // The first of the selected text, for the tooltip.
        var preview: String?

        static func == (a: Model, b: Model) -> Bool {
            a.subject == b.subject && a.selection == b.selection && a.app == b.app && a.preview == b.preview
                && a.favicon == b.favicon
        }
    }

    static let height: CGFloat = 20
    static let maxWidth: CGFloat = 260
    var onRemove: (() -> Void)?

    private let icon = NSImageView()
    // Two labels, so a long subject gives way (cut in its middle) and the
    // selection is always whole.
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let remove = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Palette.secondary
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(detail)

        remove.isBordered = false
        remove.attributedTitle = NSAttributedString(string: "×", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ])
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.alphaValue = 0
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The × keeps its room when hidden, so the line never shifts.
            detail.leadingAnchor.constraint(equalTo: label.trailingAnchor),
            detail.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            // The selection never takes more than half the line.
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth / 2),
            remove.leadingAnchor.constraint(equalTo: detail.trailingAnchor, constant: 4),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            remove.widthAnchor.constraint(equalToConstant: 16),
            remove.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    func show(_ model: Model) {
        if let data = model.favicon, let mark = NSImage(data: data), mark.isValid {
            mark.size = NSSize(width: 16, height: 16)
            icon.image = mark
            icon.alphaValue = 1
        } else {
            // No favicon (an app that ships none, or one a helper answers
            // for, such as a browser): the app's own icon, as it is.
            icon.image = model.icon
            icon.alphaValue = 1
        }
        label.font = .systemFont(ofSize: 12)
        // What is open reads as text; what is selected in it is secondary.
        label.textColor = Palette.text
        label.stringValue = model.subject
        detail.stringValue = model.selection.map { "  ·  \($0)" } ?? ""
        let said = [model.subject, model.selection].compactMap { $0 }.joined(separator: ", ")
        let preview = model.preview.map { text -> String in
            "\n\n" + (text.count > 400 ? String(text.prefix(400)) + "…" : text)
        } ?? ""
        toolTip = "\(said), from \(model.app). Sent with your message; ⌘⌫ at the start of the text removes it.\(preview)"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Context from \(model.app): \(said)")
        remove.setAccessibilityLabel("Remove context from \(model.app)")
    }

    override func mouseEntered(with event: NSEvent) { remove.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { remove.animator().alphaValue = 0 }

    @objc private func removeClicked() { onRemove?() }
}

// The warning before the first message that carries context from an app
// marked sensitive. Pressing Return the first time does not send: the
// context line gives way to this sentence, and the send button's side
// gains WarningControls. Return again, or the send button, sends.
final class ContextWarning: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(srgbRed: 0xF0 / 255, green: 0xC0 / 255, blue: 0x6A / 255, alpha: 1)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ContextLine.height),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(app: String, agent: String, icon image: NSImage?) {
        icon.image = image
        label.stringValue = "Sends your selection in \(app) to \(agent)." // TODO(copy): copy
    }
}

// Beside the send button while the warning shows: a small checkbox,
// "Don't warn again", and an outlined Cancel that goes back to the message
// unsent.
final class WarningControls: NSView {
    var onCancel: (() -> Void)?
    private let check = NSButton()
    private let cancel = NSButton()

    // Whether the user ticked "Don't warn again".
    var dontWarnAgain: Bool { check.state == .on }

    func reset() { check.state = .off }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Drawn from symbols: the system's checkbox has a dark box that is
        // lost on the composer's surface.
        check.setButtonType(.toggle)
        check.isBordered = false
        check.imagePosition = .imageLeading
        check.imageHugsTitle = true
        let symbols = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        check.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)?.withSymbolConfiguration(symbols)
        check.alternateImage = NSImage(systemSymbolName: "checkmark.square.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbols)
        check.contentTintColor = NSColor(white: 1, alpha: 0.7)
        check.attributedTitle = NSAttributedString(string: " Don't warn again", attributes: [ // TODO(copy): copy
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor(white: 1, alpha: 0.62),
        ])
        check.attributedAlternateTitle = check.attributedTitle
        (check.cell as? NSButtonCell)?.highlightsBy = []
        (check.cell as? NSButtonCell)?.showsStateBy = .contentsCellMask
        cancel.isBordered = false
        cancel.wantsLayer = true
        cancel.layer?.cornerRadius = 11
        cancel.layer?.cornerCurve = .continuous
        cancel.layer?.borderWidth = 1
        cancel.layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
        cancel.attributedTitle = NSAttributedString(string: "Cancel", attributes: [ // TODO(copy): copy
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ])
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [check, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            cancel.widthAnchor.constraint(equalToConstant: 66),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        heightOfCancel = cancel.heightAnchor.constraint(equalToConstant: 30.56)
        heightOfCancel?.isActive = true
    }

    private var heightOfCancel: NSLayoutConstraint?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func cancelClicked() { onCancel?() }
}
