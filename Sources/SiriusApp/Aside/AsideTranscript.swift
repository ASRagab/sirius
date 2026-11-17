import AppKit
import ImageIO
import SiriusCore
import UniformTypeIdentifiers

// What an aside's window shows, top to bottom, as a chat does:
// the user's words in a bubble at the right, with
// any images above it, and the agent's answers as plain text at the left.
// A turn's answer comes as runs of text (TurnEvent), with tool calls
// between them. The run being written is rendered again on each piece; a
// run that has ended is rendered once and kept, when the next one begins.
// Under the text, one line says what the agent is doing when it is not
// writing.
@MainActor
struct AsideTranscript {
    enum Entry: Equatable {
        case user(String, [URL] = [])
        case agent(String)
        // The agent's remarks on its work, as it worked: dimmed.
        case commentary(String)
        // A turn that did not finish, with why.
        case failure(String)
    }

    // What the user sent while a turn ran.
    struct Queued: Equatable {
        var text: String
        var attachments: [URL] = []
    }

    // A run of the turn under way that is not yet in `entries`.
    private struct Run {
        var id: String
        var text = ""
        var commentary: Bool
        var ended = false

        var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private(set) var entries: [Entry] = []
    // Whether a turn runs.
    private(set) var isRunning = false
    private var runs: [Run] = []
    // The tool calls running, in the order they began; the reasoning under
    // way; and the last notice, until the agent does something else.
    private var tools: [ToolCall] = []
    private var reasoning: Set<String> = []
    private var notice: String?
    // The turn has ended and only its last text is still coming in: there
    // is nothing more to wait for.
    var isFinishing = false
    // Whether the turn under way has put a run in `entries`: what follows
    // is then a paragraph away, not a turn away.
    private var hasSettledRun = false
    // Shown under the answer, dimmed, and sent in order as turns end.
    private(set) var queued: [Queued] = []
    private var settled = NSAttributedString()
    var style = AsideMarkdown.Style.standard

    static let gap: CGFloat = 26

    // The answer under way, as far as it has come; nil when no turn runs.
    var streaming: String? {
        isRunning ? runs.filter { !$0.isBlank }.map(\.text).joined(separator: "\n\n") : nil
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        settled = join(settled, render(entry))
    }

    // A turn began: the answer is awaited.
    mutating func begin() {
        isRunning = true
        isFinishing = false
        hasSettledRun = false
    }

    // What the turn says and does, in order.
    mutating func hear(_ event: TurnEvent) {
        switch event {
        case .textStarted(let id, let phase):
            start(id, commentary: phase == .commentary)
        case .textDelta(let id, let text):
            // A piece with no start before it begins its run.
            if !runs.contains(where: { $0.id == id && !$0.ended }) { start(id, commentary: false) }
            if let at = runs.lastIndex(where: { $0.id == id }) { runs[at].text += text }
            notice = nil
        case .textEnded(let id, let phase):
            guard let at = runs.lastIndex(where: { $0.id == id }) else { return }
            runs[at].ended = true
            if let phase { runs[at].commentary = phase == .commentary }
        case .reasoningStarted(let id):
            reasoning.insert(id)
            notice = nil
        case .reasoningEnded(let id):
            reasoning.remove(id)
        case .toolCall(let call):
            notice = nil
            tools.removeAll { $0.id == call.id }
            if call.status != .completed, call.status != .failed { tools.append(call) }
        case .toolCallUpdated(let id, let change):
            guard let at = tools.firstIndex(where: { $0.id == id }) else { return }
            if let title = change.title { tools[at].title = title }
            if let status = change.status { tools[at].status = status }
            if tools[at].status == .completed || tools[at].status == .failed { tools.remove(at: at) }
        case .notice(let said):
            notice = said.text
        case .stepStarted, .stepFinished, .reasoningDelta:
            break
        }
    }

    // A piece of the answer with no run named: the run under way, or a new one.
    mutating func hear(_ text: String) {
        hear(.textDelta(id: runs.last(where: { !$0.ended })?.id ?? "run-\(entries.count)", text: text))
    }

    // A run begins: those before it that have ended are kept as they are.
    private mutating func start(_ id: String, commentary: Bool) {
        while let first = runs.first, first.ended { settle(runs.removeFirst()) }
        runs.append(Run(id: id, commentary: commentary))
    }

    private mutating func settle(_ run: Run) {
        guard !run.isBlank else { return }
        let entry: Entry = run.commentary ? .commentary(run.text) : .agent(run.text)
        entries.append(entry)
        settled = hasSettledRun ? join(settled, render(entry), gap: style.paragraphSpacing) : join(settled, render(entry))
        hasSettledRun = true
    }

    // The turn ended: what was heard becomes entries.
    mutating func end(failure: String?) {
        for run in runs { settle(run) }
        runs = []
        tools = []
        reasoning = []
        notice = nil
        isRunning = false
        isFinishing = false
        hasSettledRun = false
        if let failure { append(.failure(failure)) }
    }

    // What the agent is doing when it is not writing: the last notice, the
    // tool call running, or thinking. nil while it writes, and when there
    // is nothing more to wait for.
    var activity: String? {
        guard isRunning else { return nil }
        if let notice { return notice }
        if let call = tools.last { return Self.line(call) }
        if !reasoning.isEmpty { return "Thinking…" } // TODO(copy): copy
        let writing = runs.contains { !$0.ended && !$0.isBlank }
        return writing || isFinishing ? nil : "Thinking…" // TODO(copy): copy
    }

    // TODO(copy): copy
    private static func line(_ call: ToolCall) -> String {
        let what = call.title.isEmpty ? (call.name ?? "") : call.title
        let verb: String
        switch call.kind {
        case .execute: verb = "Running"
        case .read: verb = "Reading"
        case .edit: verb = "Editing"
        case .delete: verb = "Deleting"
        case .move: verb = "Moving"
        case .search: verb = "Searching"
        case .fetch: verb = "Fetching"
        case .think, .other: return what.isEmpty ? "Working…" : "\(what)…"
        }
        return what.isEmpty ? "\(verb)…" : "\(verb) \(what)…"
    }

    mutating func queue(_ text: String, attachments: [URL] = []) {
        queued.append(Queued(text: text, attachments: attachments))
    }

    mutating func dequeue() -> Queued? {
        queued.isEmpty ? nil : queued.removeFirst()
    }

    // Everything before the runs under way.
    var head: NSAttributedString { settled }

    // The runs under way as far as they have come, the activity line and
    // the replies waiting, with the gap before them; empty when no turn
    // runs.
    var tail: NSAttributedString { tail(fade: nil) }

    // How the newest text comes in (after Codex's
    // side chat): soft at its leading edge, the last `width` characters
    // rising from nearly clear to full. `settled` is how far the edge has
    // already firmed up while nothing new arrived.
    struct Fade {
        var width: Int
        var settled: Int
        static let floor: CGFloat = 0.1
    }

    func tail(fade: Fade?) -> NSAttributedString {
        guard isRunning else { return NSAttributedString() }
        var body = NSAttributedString()
        let shown = runs.filter { !$0.isBlank }
        for (index, run) in shown.enumerated() {
            var text = render(run.commentary ? .commentary(run.text) : .agent(run.text))
            // The edge is the end of the last run, while it is being written.
            if let fade, index == shown.count - 1, fade.settled < fade.width {
                let soft = NSMutableAttributedString(attributedString: text)
                for distance in 0..<min(fade.width - fade.settled, soft.length) {
                    let index = soft.length - 1 - distance
                    let share = CGFloat(distance + fade.settled) / CGFloat(fade.width)
                    let alpha = Fade.floor + (1 - Fade.floor) * share
                    let color = soft.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor ?? style.color
                    soft.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * alpha),
                                      range: NSRange(location: index, length: 1))
                }
                text = soft
            }
            body = join(body, text, gap: style.paragraphSpacing)
        }
        if let activity {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = style.lineHeight
            paragraph.lineBreakMode = .byTruncatingTail
            body = join(body, NSAttributedString(string: activity, attributes: [
                .font: style.body, .foregroundColor: style.secondary, .paragraphStyle: paragraph,
            ]), gap: style.paragraphSpacing)
        }
        for waiting in queued {
            body = join(body, render(.user(waiting.text, waiting.attachments), dimmed: true))
        }
        guard settled.length > 0, body.length > 0 else { return body }
        return join(NSAttributedString(), body, gap: hasSettledRun ? style.paragraphSpacing : Self.gap, leading: true)
    }

    private func render(_ entry: Entry, dimmed: Bool = false) -> NSAttributedString {
        switch entry {
        case .user(let text, let attachments):
            let result = NSMutableAttributedString()
            // Images above the bubble, at the right; other files by name
            // in it.
            let right = NSMutableParagraphStyle()
            right.alignment = .right
            right.paragraphSpacing = 8
            var names: [String] = []
            let images = NSMutableAttributedString()
            for url in attachments {
                if AsideImages.isImage(url), let image = AsideImages.attachment(url) {
                    if images.length > 0 { images.append(NSAttributedString(string: "\u{2009}")) }
                    images.append(NSAttributedString(attachment: image))
                } else {
                    names.append(url.lastPathComponent)
                }
            }
            if images.length > 0 {
                images.addAttributes([.paragraphStyle: right, .font: style.body],
                                     range: NSRange(location: 0, length: images.length))
                result.append(images)
            }
            let said = ([text] + names).filter { !$0.isEmpty }.joined(separator: "\n")
            if !said.isEmpty {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: right, .font: style.body]))
                }
                let words = NSMutableAttributedString(string: said.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
                    .font: style.body, .foregroundColor: dimmed ? style.secondary : style.color,
                ])
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = style.lineHeight
                paragraph.textBlocks = [AsideBubble(natural: ceil(words.size().width) + 1,
                                                    fill: dimmed ? style.bubble.withAlphaComponent(0.5) : style.bubble)]
                words.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: words.length))
                result.append(words)
            }
            return result
        case .agent(let text):
            return AsideMarkdown.render(text.trimmingCharacters(in: .whitespacesAndNewlines), style: style)
        case .commentary(let text):
            let said = NSMutableAttributedString(attributedString: AsideMarkdown.render(
                text.trimmingCharacters(in: .whitespacesAndNewlines), style: style))
            said.addAttribute(.foregroundColor, value: style.secondary, range: NSRange(location: 0, length: said.length))
            return said
        case .failure(let reason):
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = style.lineHeight
            return NSAttributedString(string: "Couldn't finish: \(reason)", attributes: [ // TODO(copy): copy
                .font: NSFont.systemFont(ofSize: style.body.pointSize * 0.88), .foregroundColor: NSColor.systemRed,
                .paragraphStyle: paragraph,
            ])
        }
    }

    // `next` under `text`, a gap apart: a line break whose paragraph
    // carries the gap as its spacing.
    private func join(_ text: NSAttributedString, _ next: NSAttributedString, gap: CGFloat? = nil,
                      leading: Bool = false) -> NSAttributedString {
        guard text.length > 0 || leading else { return next }
        let gap = gap ?? Self.gap
        let result = NSMutableAttributedString(attributedString: text)
        let spacer = NSMutableParagraphStyle()
        spacer.minimumLineHeight = gap
        spacer.maximumLineHeight = gap
        result.append(NSAttributedString(string: "\n\u{200B}\n", attributes: [
            .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: spacer,
        ]))
        result.append(next)
        return result
    }
}

// The user's bubble: a rounded box as wide as its words, to most of the
// page's width, set against the right edge. NSTextBlock has no "hug the
// text" width, so the block sizes itself as it is laid out, from the width
// its words take on one line.
final class AsideBubble: NSTextBlock {
    static let padX: CGFloat = 18
    static let padY: CGFloat = 9
    static let share: CGFloat = 0.82
    static let radius: CGFloat = 22

    private let natural: CGFloat
    private let fill: NSColor
    // The words' width as last laid out.
    private var content: CGFloat = 0

    init(natural: CGFloat, fill: NSColor) {
        self.natural = natural
        self.fill = fill
        super.init()
        setWidth(Self.padX, type: .absoluteValueType, for: .padding, edge: .minX)
        setWidth(Self.padX, type: .absoluteValueType, for: .padding, edge: .maxX)
        setWidth(Self.padY, type: .absoluteValueType, for: .padding, edge: .minY)
        setWidth(Self.padY, type: .absoluteValueType, for: .padding, edge: .maxY)
    }

    required init?(coder: NSCoder) { nil }

    // A paragraph style copies its blocks; a copy made by NSTextBlock would
    // lose the width and the color.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    override func rectForLayout(at startingPoint: NSPoint, in rect: NSRect, textContainer: NSTextContainer,
                                characterRange: NSRange) -> NSRect {
        content = max(20, min(natural, rect.width * Self.share - Self.padX * 2))
        setContentWidth(content, type: .absoluteValueType)
        setWidth(max(0, rect.width - content - Self.padX * 2), type: .absoluteValueType, for: .margin, edge: .minX)
        return super.rectForLayout(at: startingPoint, in: rect, textContainer: textContainer, characterRange: characterRange)
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        // The frame given runs the page's width, the margin included.
        let width = min(frameRect.width, content + Self.padX * 2)
        let frame = NSRect(x: frameRect.maxX - width, y: frameRect.minY, width: width, height: frameRect.height)
        fill.setFill()
        let radius = min(Self.radius, frame.height / 2)
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    }
}

// An attached image as the page shows it: to fit 240 × 180, corners rounded.
@MainActor
enum AsideImages {
    static let box = NSSize(width: 240, height: 180)

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func attachment(_ url: URL) -> NSTextAttachment? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 720,
              ] as CFDictionary), cg.width > 0, cg.height > 0 else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let fit = min(box.width / width, box.height / height, 1)
        let size = NSSize(width: (width * fit).rounded(), height: (height * fit).rounded())
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).addClip()
            NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }
}
