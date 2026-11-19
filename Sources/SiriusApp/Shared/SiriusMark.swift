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

    // The star for tinting at small sizes: the same shape with its alpha
    // raised (scripts/make-icon.sh), so the thin tips of its arms stay
    // visible instead of fading out and reading as cut off.
    static let mark: NSImage? = {
        let url = Bundle.main.url(forResource: "sirius-star-mark", withExtension: "png", subdirectory: "images")
            ?? URL(fileURLWithPath: "packaging/images/sirius-star-mark.png")
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.isTemplate = true
        return image
    }()

    // How much larger than the pill's 20 pt content the star is drawn, so it
    // fills the 46 pt capsule as the symbol it replaced did.
    static let pillScale: CGFloat = 1.25

    static func template(_ description: String? = "Sirius") -> NSImage? {
        guard let star = (mark ?? silver)?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "sparkle", accessibilityDescription: description)
        }
        star.isTemplate = true
        star.accessibilityDescription = description
        return star
    }
}
