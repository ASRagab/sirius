import Foundation

// The toast FIFO with no UI: one toast visible, the rest waiting in arrival
// order across all agents. The app's ToastPresenter drives it.
public struct Toast: Equatable, Sendable {
    // Assigned by the queue; a stale timer or a second click names a toast
    // that is no longer current and is ignored.
    public var seq: Int
    public var agent: String
    public var text: String
    // Stays until dismissed and holds the queue behind it.
    public var alert: Bool

    // How long a non-alert toast stays, after the reference ack bubble's
    // final line: 5 s, plus 60 ms per character past the first 60, at most
    // 10 s, so three- and four-line toasts leave sooner (was 15 s).
    public var duration: TimeInterval? {
        alert ? nil : min(10, 5 + Double(max(0, text.unicodeScalars.count - 60)) * 0.06)
    }
}

public struct ToastQueue {
    // Toasts allowed to wait behind the visible one.
    public let capacity: Int
    public private(set) var current: Toast?
    private var waiting: [Toast] = []
    private var nextSeq = 1

    public init(capacity: Int) {
        self.capacity = capacity
    }

    // The "+N more" count on the visible toast.
    public var backlog: Int { waiting.count }

    public enum EnqueueOutcome: Equatable {
        // Nothing was showing; this toast is now current.
        case shown(Toast)
        // Waiting behind the current toast; the backlog count changed.
        case queued(backlog: Int)
        // Took the place of the agent's toast on screen; shown with a fresh
        // seq, so the old toast's timer finds it gone.
        case replaced(Toast)
        case full
    }

    // With `replace`, the toast takes the place of the agent's own: the one on
    // screen, else its latest one waiting. An alert is never replaced, nor
    // another agent's toast; with nothing to replace it queues as usual.
    public mutating func enqueue(agent: String, text: String, alert: Bool, replace: Bool = false) -> EnqueueOutcome {
        let toast = Toast(seq: nextSeq, agent: agent, text: text, alert: alert)
        if replace {
            if let shown = current, shown.agent == agent, !shown.alert {
                nextSeq += 1
                current = toast
                return .replaced(toast)
            }
            if let index = waiting.lastIndex(where: { $0.agent == agent && !$0.alert }) {
                nextSeq += 1
                waiting[index] = toast
                return .queued(backlog: waiting.count)
            }
        }
        if current != nil && waiting.count >= capacity { return .full }
        nextSeq += 1
        if current == nil {
            current = toast
            return .shown(toast)
        }
        waiting.append(toast)
        return .queued(backlog: waiting.count)
    }

    // Dismisses the current toast if it is still `seq` and promotes the next
    // one in arrival order. Returns nil when nothing changed.
    public mutating func dismiss(seq: Int) -> Advance? {
        guard let shown = current, shown.seq == seq else { return nil }
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return Advance(next: current)
    }

    public struct Advance: Equatable {
        public var next: Toast?
    }
}
