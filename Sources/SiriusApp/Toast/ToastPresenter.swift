import AppKit
import SiriusCore
import SiriusProtocol

// What the presenter needs of the toast window; ToastPanel, or a stand-in
// in tests.
@MainActor
protocol ToastSurface: AnyObject {
    var onClick: (() -> Void)? { get set }
    var onHover: ((Bool) -> Void)? { get set }
    var isVisible: Bool { get }
    // Ordered in but on no Space the user can see: it shows nothing.
    var isStranded: Bool { get }
    // WindowServer has it on screen, within a display; asked a moment
    // after it is shown.
    var isOnScreen: Bool { get }
    // What the log records of it per toast.
    var state: String { get }
    func present(agent: String, mark: NSImage?, text: String)
    func dismiss()
    func retire()
}

// Drives the toast panel from the FIFO: shows the current toast and advances
// on timeout or click; the next toast swaps in place, the last one closes.
@MainActor
final class ToastPresenter {
    private var queue = ToastQueue(capacity: Limits.maxQueued)
    private var dismissTimer: Timer?
    // The pointer on the toast holds it; the timer looks again every 0.8 s,
    // as the reference ack bubble does.
    private var hovered = false
    private static let hoverRecheck: TimeInterval = 0.8
    // The sending agent's logo, so the user sees who answered.
    private let mark: (String) -> NSImage?

    // Builds the toast window, once and again whenever it has to be
    // replaced: a display sleep can strand the one in use (ToastPanel.isStranded).
    private let makeSurface: @MainActor () -> ToastSurface
    private var built: ToastSurface?
    // The displays have slept and woken since the panel was built: the next
    // toast to open gets a new one rather than risk a stranded window.
    private var wokeSinceBuilt = false
    private var wakeObserver: NSObjectProtocol?
    // How long after a toast is shown WindowServer is asked whether it is
    // on screen (verify). Nil in tests, which call verify themselves.
    private let verifyDelay: TimeInterval?
    private var verifyTimer: Timer?

    init(mark: @escaping (String) -> NSImage? = { _ in nil },
         verifyDelay: TimeInterval? = 0.4,
         makeSurface: @escaping @MainActor () -> ToastSurface = { ToastPanel() }) {
        self.mark = mark
        self.verifyDelay = verifyDelay
        self.makeSurface = makeSurface
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysWoke() }
        }
    }

    func displaysWoke() {
        wokeSinceBuilt = true
    }

    private var panel: ToastSurface {
        if let built { return built }
        let panel = makeSurface()
        panel.onClick = { [weak self] in self?.dismissCurrent() }
        panel.onHover = { [weak self] in self?.hovered = $0 }
        built = panel
        wokeSinceBuilt = false
        return panel
    }

    // Drops the panel; the next use builds a fresh one.
    private func rebuild(_ reason: String, unexpected: Bool) {
        let line = "toast panel rebuilt: \(reason)"
        if unexpected { SiriusLog.toast.error(line) } else { SiriusLog.toast.info(line) }
        built?.retire()
        built = nil
        hovered = false
    }

    // False when the queue is full; the caller answers QUEUE_FULL. With
    // `replace`, the toast takes the place of the agent's own (ToastQueue).
    func enqueue(agent: String, text: String, alert: Bool, replace: Bool = false) -> Bool {
        switch queue.enqueue(agent: agent, text: text, alert: alert, replace: replace) {
        case .shown(let toast), .replaced(let toast):
            show(toast)
            return true
        case .queued:
            return true
        case .full:
            return false
        }
    }

    private func dismissCurrent() {
        guard let seq = queue.current?.seq else { return }
        dismiss(seq: seq)
    }

    private func dismiss(seq: Int) {
        guard let advance = queue.dismiss(seq: seq) else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let next = advance.next {
            show(next)
        } else {
            hovered = false
            panel.dismiss()
        }
    }

    private func show(_ toast: Toast) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        // Opening, not swapping into a toast that is up: the moment a panel
        // can be replaced unseen.
        let opening = !(built?.isVisible ?? false)
        if opening && wokeSinceBuilt && built != nil { rebuild("the displays woke since it was built", unexpected: false) }
        panel.present(agent: toast.agent, mark: mark(toast.agent), text: toast.text)
        if opening && panel.isStranded {
            rebuild("it was ordered in on no Space", unexpected: true)
            panel.present(agent: toast.agent, mark: mark(toast.agent), text: toast.text)
            if panel.isStranded { SiriusLog.toast.error("toast panel still on no Space after a rebuild") }
        }
        // An alert has no timer: it holds the queue until clicked.
        if let duration = toast.duration(base: ToastStay.seconds()) {
            expire(seq: toast.seq, after: duration)
        }
        scheduleVerify(seq: toast.seq)
    }

    private func scheduleVerify(seq: Int) {
        verifyTimer?.invalidate()
        verifyTimer = nil
        guard let verifyDelay else { return }
        verifyTimer = Timer.scheduledTimer(withTimeInterval: verifyDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.verify(seq: seq) }
        }
    }

    // A moment after a toast is shown, opened or swapped in: if AppKit has
    // the panel up but WindowServer has it on no screen, the panel is
    // replaced and the toast shown again on the new one, once. The AppKit
    // check in show (isStranded) does not see this case (2026.11.15).
    func verify(seq: Int) {
        verifyTimer = nil
        guard let toast = queue.current, toast.seq == seq, let built, built.isVisible else { return }
        SiriusLog.toast.info("toast \(seq) shown: \(built.state)")
        guard !built.isOnScreen else { return }
        rebuild("it was up but not on any screen", unexpected: true)
        // Not verified again: the next toast is, so a panel that keeps
        // stranding is replaced at most once per toast, never in a loop.
        panel.present(agent: toast.agent, mark: mark(toast.agent), text: toast.text)
        SiriusLog.toast.info("toast \(seq) shown again: \(panel.state)")
    }

    private func expire(seq: Int, after interval: TimeInterval) {
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovered { return self.expire(seq: seq, after: Self.hoverRecheck) }
                self.dismiss(seq: seq)
            }
        }
    }
}
