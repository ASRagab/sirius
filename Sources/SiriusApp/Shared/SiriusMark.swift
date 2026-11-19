import AppKit

// Sirius's mark: the silver star (packaging/images/sirius-star.png, made by
// scripts/make-icon.sh). `silver` is the star in its own colors, for dark
// surfaces; `template` is the same shape for macOS to tint, as the pill tints
// it blue. Both fall back to the SF Symbol "sparkle" when the bundle lacks the
// file, as in `swift run` from a checkout without packaging/.
enum SiriusMark {
    static let silver: NSImage? = {
        let url = Bundle.main.url(forResource: "sirius-star", withExtension: "png", subdirectory: "images")
            ?? URL(fileURLWithPath: "packaging/images/sirius-star.png")
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.accessibilityDescription = "Sirius"
        return image
    }()

    static func template(_ description: String? = "Sirius") -> NSImage? {
        guard let star = silver?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "sparkle", accessibilityDescription: description)
        }
        star.isTemplate = true
        star.accessibilityDescription = description
        return star
    }
}
