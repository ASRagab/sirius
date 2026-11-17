import AppKit

// What the app in front had open and selected, as a tile in the composer's
// attachment row: the app's icon, the item's title and the app's name, and
// the same round × on hover that removes a file. While it shows, the
// context goes with the message; removed, it does not.
// TODO(copy): not in the Figma design; drawn after AttachmentTile.
@MainActor
final class ContextTile: NSView {
    struct Model: Equatable {
        var title: String
        var app: String
        var icon: NSImage?
        // The first of the selected text, for the tooltip.
        var preview: String?

        static func == (a: Model, b: Model) -> Bool {
            a.title == b.title && a.app == b.app && a.preview == b.preview
        }
    }

    static let size = NSSize(width: 188, height: AttachmentTile.side)
    var onRemove: (() -> Void)?

    private let remove = NSButton()

    init(_ model: Model) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 0x3A / 255, green: 0x3D / 255, blue: 0x41 / 255, alpha: 1).cgColor
        layer?.backgroundColor = NSColor(srgbRed: 0x2D / 255, green: 0x30 / 255, blue: 0x34 / 255, alpha: 1).cgColor
        let preview = model.preview.map { text -> String in
            let short = text.count > 400 ? String(text.prefix(400)) + "…" : text
            return "\n\n" + short
        } ?? ""
        toolTip = "\(model.title), from \(model.app). Sent with your message.\(preview)"
        setAccessibilityLabel("Context: \(model.title), from \(model.app)")

        let icon = NSImageView(frame: NSRect(x: 12, y: (Self.size.height - 32) / 2, width: 32, height: 32))
        icon.image = model.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let title = Self.label(model.title, size: 12, weight: .medium, color: NSColor(white: 1, alpha: 0.92))
        title.frame = NSRect(x: 54, y: 33, width: Self.size.width - 54 - 12, height: 16)
        addSubview(title)
        let app = Self.label(model.app, size: 11, weight: .regular, color: NSColor(white: 1, alpha: 0.55))
        app.frame = NSRect(x: 54, y: 16, width: Self.size.width - 54 - 12, height: 14)
        addSubview(app)

        remove.frame = NSRect(x: Self.size.width - 3 - 18, y: Self.size.height - 3 - 18, width: 18, height: 18)
        remove.isBordered = false
        remove.wantsLayer = true
        remove.layer?.cornerRadius = 9
        remove.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        remove.attributedTitle = NSAttributedString(string: "×", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ])
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.isHidden = true
        remove.setAccessibilityLabel("Remove context from \(model.app)")
        addSubview(remove)

        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }

    override func mouseEntered(with event: NSEvent) { remove.isHidden = false }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }

    @objc private func removeClicked() { onRemove?() }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        return label
    }
}
