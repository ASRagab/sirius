import AppKit
import CoreImage

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
        // The app's icon, shown greyed when the app has no favicon.
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
            // An app icon is drawn for a Dock, not for a line of text: grey
            // and dimmed, it sits with the words instead of over them.
            icon.image = model.icon.map(Self.grey)
            icon.alphaValue = 0.75
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
        toolTip = "\(said), from \(model.app). Sent with your message.\(preview)"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Context from \(model.app): \(said)")
        remove.setAccessibilityLabel("Remove context from \(model.app)")
    }

    private static func grey(_ image: NSImage) -> NSImage {
        let side: CGFloat = 32
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let made = CIContext().createCGImage(output, from: output.extent) else { return image }
        return NSImage(cgImage: made, size: NSSize(width: 16, height: 16))
    }

    override func mouseEntered(with event: NSEvent) { remove.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { remove.animator().alphaValue = 0 }

    @objc private func removeClicked() { onRemove?() }
}
