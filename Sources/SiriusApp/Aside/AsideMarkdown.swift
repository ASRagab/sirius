import AppKit

// The Markdown an aside renders, as attributed text for a TextKit 1 view:
// headings, paragraphs, bullet and numbered lists with nesting, block
// quotes, fenced code, rules, and inline bold, italic, code, strikethrough
// and links. A table stays as typed, in the code face, so its columns line
// up. Written to be run again on every piece of a streaming answer: an
// unclosed fence is code to the end, and an unclosed inline marker stays
// as typed until its close arrives.
// TODO(copy): every size, colour and spacing here is a first pass.
@MainActor
enum AsideMarkdown {
    struct Style {
        var body: NSFont
        var color: NSColor
        var secondary: NSColor
        var code: NSFont
        var codeBackground: NSColor
        var rule: NSColor
        // The fill of the user's bubble.
        var bubble: NSColor
        var lineHeight: CGFloat
        var paragraphSpacing: CGFloat

        // The composer's face and colors (Palette): the aside is its
        // companion, dark whatever the system's appearance.
        static var standard: Style {
            let size = Palette.body.pointSize
            return Style(body: Palette.body, color: Palette.text, secondary: Palette.secondary,
                         code: .monospacedSystemFont(ofSize: size * 0.86, weight: .regular),
                         codeBackground: NSColor(white: 1, alpha: 0.07),
                         rule: NSColor(white: 1, alpha: 0.18),
                         bubble: NSColor(srgbRed: 0x1B / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),
                         lineHeight: 1.3, paragraphSpacing: 12)
        }
    }

    nonisolated static func with(_ traits: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: Blocks

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(level: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case table(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                var body = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                    body.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                }
                blocks.append(.quote(body.joined(separator: " ")))
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    index += 1
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                }
                blocks.append(.table(rows.joined(separator: "\n")))
            } else if let item = item(line) {
                flush()
                var body = item.text
                // Lines indented under the item, with no marker, continue it.
                while index + 1 < lines.count {
                    let next = lines[index + 1]
                    guard next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).isEmpty,
                          self.item(next) == nil, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                    else { break }
                    body += " " + next.trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                blocks.append(.item(level: item.level, marker: item.marker, text: body))
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    // "- x", "* x", "+ x", "1. x", "1) x", by its indent: two spaces a level.
    private static func item(_ line: String) -> (level: Int, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return (min(indent / 2, 4), "•", String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return (min(indent / 2, 4), "\(digits).", String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Rendering

    static func render(_ text: String, style: Style = .standard) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let all = blocks(text)
        for (index, block) in all.enumerated() {
            let last = index == all.count - 1
            // Items of one list sit closer than paragraphs do.
            var spacing = style.paragraphSpacing
            if case .item = block, !last, case .item = all[index + 1] { spacing = 4 }
            let piece = NSMutableAttributedString(attributedString: render(block, style: style, spacing: spacing))
            if !last { piece.append(NSAttributedString(string: "\n", attributes: piece.attributes(at: max(0, piece.length - 1), effectiveRange: nil))) }
            result.append(piece)
        }
        return result
    }

    private static func paragraphStyle(_ style: Style, spacing: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeight
        paragraph.paragraphSpacing = spacing
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    private static func render(_ block: Block, style: Style, spacing: CGFloat) -> NSAttributedString {
        switch block {
        case .paragraph(let text):
            return styled(inline(text, font: style.body, color: style.color, style: style),
                          paragraphStyle(style, spacing: spacing))
        case .heading(let level, let text):
            let sizes: [CGFloat] = [1.4, 1.22, 1.08, 1, 1, 1]
            let font = NSFont.systemFont(ofSize: style.body.pointSize * sizes[level - 1], weight: .semibold)
            let paragraph = paragraphStyle(style, spacing: spacing * 0.7)
            paragraph.paragraphSpacingBefore = level <= 2 ? 8 : 4
            paragraph.lineHeightMultiple = 1.15
            return styled(inline(text, font: font, color: style.color, style: style), paragraph)
        case .item(let level, let marker, let text):
            let paragraph = paragraphStyle(style, spacing: spacing)
            let start = 6 + CGFloat(level) * 22
            let width: CGFloat = marker == "•" ? 16 : 26
            paragraph.firstLineHeadIndent = start
            paragraph.headIndent = start + width
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: start + width)]
            let result = NSMutableAttributedString(string: marker + "\t",
                                                   attributes: [.font: style.body, .foregroundColor: style.secondary])
            result.append(inline(text, font: style.body, color: style.color, style: style))
            return styled(result, paragraph)
        case .quote(let text):
            let paragraph = paragraphStyle(style, spacing: spacing)
            paragraph.textBlocks = [bar(color: style.rule)]
            return styled(inline(text, font: with(.italic, style.body), color: style.secondary, style: style), paragraph)
        case .code(let text), .table(let text):
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.18
            paragraph.paragraphSpacing = spacing
            paragraph.lineBreakMode = .byCharWrapping
            let box = AsideBox(fill: style.codeBackground)
            box.setContentWidth(100, type: .percentageValueType)
            box.setWidth(14, type: .absoluteValueType, for: .padding)
            paragraph.textBlocks = [box]
            // One paragraph, its lines parted by line separators, so the
            // spacing falls once, after the box.
            return NSAttributedString(string: text.isEmpty ? " " : text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                                      attributes: [.font: style.code, .foregroundColor: style.color,
                                                   .paragraphStyle: paragraph])
        case .rule:
            let paragraph = paragraphStyle(style, spacing: spacing)
            paragraph.alignment = .center
            return NSAttributedString(string: "· · ·", attributes: [.font: style.body, .foregroundColor: style.rule,
                                                                    .paragraphStyle: paragraph])
        }
    }

    // A box with only a bar down its left edge: a quote.
    static func bar(color: NSColor) -> NSTextBlock {
        let block = NSTextBlock()
        // Without a width a block is as narrow as one glyph.
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(color, for: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    private static func styled(_ text: NSAttributedString, _ paragraph: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Inline

    static func inline(_ text: String, font: NSFont, color: NSColor, style: Style) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.86, weight: .regular)
                    attributes[.backgroundColor] = style.codeBackground
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty { attributes[.font] = with(traits, font) }
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

// A code box: NSTextBlock's own background is square, so this one draws
// its fill rounded.
final class AsideBox: NSTextBlock {
    static let radius: CGFloat = 14
    private let fill: NSColor

    init(fill: NSColor) {
        self.fill = fill
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    // A copy made by NSTextBlock would lose the color.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        fill.setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}
