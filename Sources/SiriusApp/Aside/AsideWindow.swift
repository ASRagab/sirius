import AppKit
import SiriusCore

// One aside's window, the composer's companion:
// dark, the conversation as a chat page, and at the foot a
// single-line pill to answer in:
// the + at its left, the agent's mark and a round send
// button at its right. It grows by the line as the text does.
// Return sends, Shift-Return adds a line, Escape or ⌘W closes, and closing
// ends the aside (AsideController). Files and images attach by paste, drop
// or the +, and show as the composer's tiles until sent.
//
// TextKit 1 throughout: the user's bubble and the code boxes are NSTextBlocks.
// TODO(copy): every size, colour and spacing here is a first pass.
@MainActor
final class AsideWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let size = NSSize(width: 600, height: 720)
    private static let margin: CGFloat = 28
    private static let inputLines: CGFloat = 8
    // The pill: 38 tall on one line, its controls 28 round, 5 in.
    private static let fieldInset: CGFloat = 5
    private static let control: CGFloat = 28
    private static let tilesTop: CGFloat = 12

    let window: NSWindow
    // The user sent `text` and these files from the field.
    var onSend: ((String, [URL]) -> Void)?
    var onClose: (() -> Void)?

    private var transcript = AsideTranscript()
    private let page: NSTextView
    private let pageScroll = NSScrollView()
    private let input: AsideInputView
    private let inputScroll = NSScrollView()
    private var inputHeight: NSLayoutConstraint!
    private var inputTop: NSLayoutConstraint!
    private let tiles = NSStackView()
    private var attachments: [URL] = []
    // A text view built on its own container does not keep its storage.
    private let storages: [NSTextStorage]
    // Where the answer under way starts in the page's text.
    private var tailStart = 0
    // Heard and not yet shown. A harness sends an answer faster than it
    // reads: 150 words in about a second and a half, after a wait of
    // seconds, which looked like the whole answer landing at once.
    // So the page takes what it has heard at a steady pace:
    // each tick shows a share of what is waiting, and never less than a
    // few characters, so a long burst catches up and a short one still
    // visibly arrives.
    private var incoming: [TurnEvent] = []
    private var pacer: Timer?
    // The turn has ended, with this failure; settled once all is shown.
    private var ending: String??
    // Off for the snapshots: what is heard shows at once.
    var isPaced = true
    private static let tick: TimeInterval = 1.0 / 30
    private static let share = 0.12
    private static let least = 6
    // The leading edge is soft over this many characters, and firms up
    // this many a tick once nothing new arrives (AsideTranscript.Fade).
    private static let fadeWidth = 28
    private static let fadeStep = 4
    private var firmed = 0
    private var fade: AsideTranscript.Fade? {
        isPaced ? AsideTranscript.Fade(width: Self.fadeWidth, settled: firmed) : nil
    }

    init(agent: String, name: String, mark: NSImage?) {
        window = AsidePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        let (pageStorage, pageContainer) = Self.container()
        let (inputStorage, inputContainer) = Self.container()
        // The bubble is as wide as its words exactly.
        pageContainer.lineFragmentPadding = 0
        storages = [pageStorage, inputStorage]
        page = NSTextView(frame: NSRect(origin: .zero, size: Self.size), textContainer: pageContainer)
        Self.configure(page, editable: false)
        input = AsideInputView(frame: NSRect(x: 0, y: 0, width: Self.size.width, height: 36),
                               textContainer: inputContainer)
        super.init()

        window.title = "Aside with \(name)" // TODO(copy): copy
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.background
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 320)
        window.delegate = self

        // The content stops short of the title bar, which is clear and the
        // page's color: a scroll view run under it is drawn by the system's
        // scroll-edge effect, and the page came out blank.
        let content = AsideDropView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor
        content.onDrop = { [weak self] urls in self?.attach(urls) }
        window.contentView = content

        page.textContainerInset = NSSize(width: Self.margin, height: 14)
        page.linkTextAttributes = [.foregroundColor: Palette.caret, .cursor: NSCursor.pointingHand]
        page.selectedTextAttributes = [.backgroundColor: Palette.selection]
        pageScroll.documentView = page
        pageScroll.hasVerticalScroller = true
        pageScroll.drawsBackground = false
        pageScroll.scrollerStyle = .overlay
        pageScroll.scrollerKnobStyle = .light
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pageScroll)

        // The field: a pill. Tiles, when there are any, then one row: the
        // +, a text view that grows with what is typed, to a few lines,
        // then scrolls, the agent's mark and the send button.
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Self.fieldInset + Self.control / 2
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(box)

        tiles.orientation = .horizontal
        tiles.spacing = 8
        tiles.alignment = .top
        tiles.isHidden = true
        tiles.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tiles)

        Self.configure(input, editable: true)
        input.font = Palette.body
        input.textColor = Palette.text
        input.insertionPointColor = Palette.caret
        input.selectedTextAttributes = [.backgroundColor: Palette.selection]
        input.typingAttributes = [.font: Palette.body, .foregroundColor: Palette.text]
        input.textContainerInset = NSSize(width: 0, height: 5)
        input.textContainer?.lineFragmentPadding = 2
        input.placeholder = "Reply to \(name)" // TODO(copy): copy
        input.delegate = self
        input.onSend = { [weak self] in self?.send() }
        input.onFiles = { [weak self] urls in self?.attach(urls) }
        input.onCancel = { [weak self] in self?.window.performClose(nil) }
        input.onRemoveLastAttachment = { [weak self] in
            guard let self, !attachments.isEmpty else { return false }
            attachments.removeLast()
            showAttachments()
            return true
        }
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = false
        inputScroll.drawsBackground = false
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inputScroll)

        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Attach files") ?? NSImage(),
                            target: self, action: #selector(chooseFiles))
        plus.isBordered = false
        plus.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        plus.contentTintColor = Palette.glyph
        plus.wantsLayer = true
        plus.layer?.cornerRadius = Self.control / 2
        plus.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        plus.toolTip = "Attach files" // TODO(copy): copy
        plus.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(plus)

        let logo = NSImageView(image: mark ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.toolTip = name
        logo.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(logo)

        // Round and light, the one bright thing in the window.
        let sendButton = NSButton(title: "", target: self, action: #selector(sendClicked))
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = Palette.text.cgColor
        sendButton.layer?.cornerRadius = Self.control / 2
        sendButton.setAccessibilityLabel("Send")
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send") ?? NSImage())
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        glyph.contentTintColor = Palette.background
        glyph.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(glyph)
        box.addSubview(sendButton)

        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 36)
        inputTop = inputScroll.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.fieldInset)
        NSLayoutConstraint.activate([
            pageScroll.topAnchor.constraint(equalTo: content.topAnchor),
            pageScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageScroll.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -8),

            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            box.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            tiles.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.tilesTop),
            tiles.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            tiles.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            tiles.heightAnchor.constraint(equalToConstant: AttachmentTile.side),

            inputTop,
            inputScroll.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: logo.leadingAnchor, constant: -10),
            inputScroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.fieldInset),
            inputHeight,

            sendButton.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.fieldInset),
            sendButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.fieldInset),
            sendButton.widthAnchor.constraint(equalToConstant: Self.control),
            sendButton.heightAnchor.constraint(equalToConstant: Self.control),
            glyph.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),

            logo.widthAnchor.constraint(equalToConstant: 16),
            logo.heightAnchor.constraint(equalToConstant: 16),
            logo.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            logo.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),

            plus.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.fieldInset),
            plus.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.fieldInset),
            plus.widthAnchor.constraint(equalToConstant: Self.control),
            plus.heightAnchor.constraint(equalToConstant: Self.control),
        ])
        (window as? AsidePanel)?.field = input
        resizeInput()
    }

    // MARK: The conversation

    // The user's words, then the wait for the answer.
    func ask(_ text: String, attachments: [URL] = []) {
        transcript.append(.user(text, attachments))
        transcript.begin()
        render(all: true, follow: true)
    }

    // A turn the user did not type (the agent's brief): only the wait.
    func await_() {
        transcript.begin()
        render(all: true, follow: true)
    }

    // What the turn says and does (TurnEvent), in order.
    func hear(_ event: TurnEvent) {
        incoming.append(event)
        guard isPaced else { return show(all: true) }
        guard pacer == nil else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(all: false) }
        }
        // Common modes: the text keeps coming while the page is scrolled.
        RunLoop.main.add(timer, forMode: .common)
        pacer = timer
    }

    // A piece of the answer, as one run.
    func hear(_ text: String) {
        hear(.textDelta(id: "answer", text: text))
    }

    // Moves the next of what was heard onto the page; settles the turn
    // once it has ended and nothing waits. Text is paced by its length;
    // the events between pieces of it take effect as their turn comes.
    private func show(all: Bool) {
        let waiting = incoming.reduce(0) { count, event in
            if case .textDelta(_, let text) = event { return count + text.count }
            return count
        }
        var budget = all ? waiting : min(waiting, max(Self.least, Int((Double(waiting) * Self.share).rounded(.up))))
        let follow = atBottom
        var shown = 0
        var changed = false
        while let next = incoming.first {
            if case .textDelta(let id, let text) = next {
                guard budget > 0 else { break }
                if text.count <= budget {
                    transcript.hear(next)
                    incoming.removeFirst()
                } else {
                    transcript.hear(.textDelta(id: id, text: String(text.prefix(budget))))
                    incoming[0] = .textDelta(id: id, text: String(text.dropFirst(budget)))
                }
                let took = min(text.count, budget)
                budget -= took
                shown += took
            } else {
                transcript.hear(next)
                incoming.removeFirst()
            }
            changed = true
        }
        if changed {
            firmed = max(0, firmed - shown)
            render(all: false, follow: follow)
        } else if isPaced, firmed < Self.fadeWidth {
            // Nothing new: the edge firms up.
            firmed = min(Self.fadeWidth, firmed + Self.fadeStep)
            render(all: false, follow: false)
        }
        guard incoming.isEmpty, !isPaced || firmed >= Self.fadeWidth else { return }
        pacer?.invalidate()
        pacer = nil
        if let failure = ending {
            ending = nil
            settle(failure: failure)
        }
    }

    // The turn ended. What the user sent meanwhile that is next to go is
    // shown as asked and sent (onSend), once the answer is all on the page.
    func end(failure: String?) {
        // While the pacer runs there is text to show or an edge to firm up.
        if pacer == nil { settle(failure: failure) } else { ending = .some(failure) }
        transcript.isFinishing = pacer != nil
    }

    private func settle(failure: String?) {
        firmed = 0
        let follow = atBottom
        transcript.end(failure: failure)
        let next = transcript.dequeue()
        if let next {
            transcript.append(.user(next.text, next.attachments))
            transcript.begin()
        }
        render(all: true, follow: follow)
        if let next { onSend?(next.text, next.attachments) }
    }

    var isAwaiting: Bool { transcript.isRunning }

    // The page as it reads now.
    var pageText: String { page.string }

    private func send() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        input.string = ""
        attachments = []
        showAttachments()
        resizeInput()
        input.needsDisplay = true
        if isAwaiting {
            // Shown waiting under the answer; sent when the turn ends.
            transcript.queue(text, attachments: files)
            render(all: false, follow: true)
        } else {
            ask(text, attachments: files)
            onSend?(text, files)
        }
    }

    @objc private func sendClicked() { send() }

    // MARK: Attachments

    // Files and images for the next message, as the composer's tiles.
    func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
        showAttachments()
        focus()
    }

    private func showAttachments() {
        for view in tiles.arrangedSubviews { view.removeFromSuperview() }
        for url in attachments {
            let tile = AttachmentTile(url: url)
            tile.onRemove = { [weak self] in
                self?.attachments.removeAll { $0 == url }
                self?.showAttachments()
            }
            tiles.addArrangedSubview(tile)
        }
        tiles.isHidden = attachments.isEmpty
        inputTop.constant = attachments.isEmpty ? Self.fieldInset : Self.tilesTop + AttachmentTile.side + 8
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(panel.urls)
        }
    }

    private var atBottom: Bool {
        let visible = pageScroll.contentView.bounds
        return visible.maxY >= page.frame.height - 24
    }

    private func render(all: Bool, follow: Bool) {
        guard let storage = page.textStorage else { return }
        storage.beginEditing()
        // A run that ended has joined the head since the last time.
        if all || transcript.head.length != tailStart {
            storage.setAttributedString(transcript.head)
            tailStart = storage.length
        } else {
            storage.deleteCharacters(in: NSRange(location: tailStart, length: storage.length - tailStart))
        }
        storage.append(transcript.tail(fade: fade))
        storage.endEditing()
        if follow {
            page.layoutManager?.ensureLayout(for: page.textContainer!)
            page.scrollToEndOfDocument(nil)
        }
    }

    // MARK: The field

    func textDidChange(_ notification: Notification) {
        resizeInput()
        input.needsDisplay = true
    }

    private func resizeInput() {
        guard let layout = input.layoutManager, let container = input.textContainer else { return }
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: input.font ?? Palette.body)
        let used = max(layout.usedRect(for: container).height, line)
        inputHeight.constant = min(used, line * Self.inputLines) + input.textContainerInset.height * 2
    }

    func focus() {
        window.makeFirstResponder(input)
    }

    // MARK: The window

    func windowWillClose(_ notification: Notification) {
        pacer?.invalidate()
        pacer = nil
        onClose?()
    }

    // MARK: Text views

    private static func container() -> (NSTextStorage, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // A finite height: text blocks are laid out against what is left of it.
        let container = NSTextContainer(size: NSSize(width: size.width, height: 10_000_000))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return (storage, container)
    }

    private static func configure(_ view: NSTextView, editable: Bool) {
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = editable
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
    }
}

// The window itself. Sirius has no menus (it lives in the menu bar), so the
// standard shortcuts are routed here: ⌘W closes, and the editing ones go to
// whichever text has focus, the page (copy) or the field. A key typed with
// the page in focus goes to the field.
final class AsidePanel: NSWindow {
    weak var field: NSTextView?
    // For the snapshots: stay off every screen.
    var staysWherePut = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        staysWherePut ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Escape closes the aside, wherever the focus is.
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command], key == "w" {
            performClose(nil)
            return true
        }
        if flags == [.command], key == "m" {
            performMiniaturize(nil)
            return true
        }
        let editing: [String: Selector] = [
            "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
            "x": #selector(NSText.cut(_:)), "z": Selector(("undo:")),
        ]
        if flags == [.command], let key, let action = editing[key] {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let field, firstResponder !== field, flags.subtracting([.shift, .capsLock]).isEmpty,
           let typed = event.characters, typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            makeFirstResponder(field)
            field.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}

// The window's body: files dropped anywhere on it attach.
final class AsideDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// The field: Return sends, Shift-Return (or ⌥Return) adds a line, Escape
// closes the aside. A paste or drop of files or an image attaches them, as
// in the composer; any other paste is plain text. ⌫ with the caret at the
// start takes off the last attachment.
final class AsideInputView: NSTextView {
    var onSend: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onCancel: (() -> Void)?
    // Removes the last attachment; false when there is none.
    var onRemoveLastAttachment: (() -> Bool)?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []), (36, [.command]), (76, [.command]):
            if hasMarkedText() { return super.keyDown(with: event) }
            onSend?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.location == 0, range.length == 0, !hasMarkedText(), onRemoveLastAttachment?() == true { return }
        super.deleteBackward(sender)
    }

    override func paste(_ sender: Any?) {
        let files = PastedFiles.read(.general)
        if !files.isEmpty { return onFiles?(files) ?? () }
        pasteAsPlainText(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? Palette.body, .foregroundColor: NSColor(white: 1, alpha: 0.3),
        ])
    }
}
