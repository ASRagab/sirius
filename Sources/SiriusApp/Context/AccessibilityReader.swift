import AppKit
import ApplicationServices
import Foundation
import SiriusCore

// Reads what a listed app (NativeApps) has open and selected, through macOS
// Accessibility, which Sirius already holds for dictation. It takes only
// the path that matters, never the window's whole tree: the front window's
// title and document, the selected text, and in Finder the selected files.
//
// Keyboard focus is not trusted to be on the text (in Mail and Notes it
// sits on the list), so after the focused element the window is searched,
// breadth first, for the element that has a selection. Web content
// (Safari, and a message's body) answers nothing to the standard
// selected-text attribute; its selection is asked of its web area by text
// marker. Secure fields are never read.
//
// Every call is to another process, so the whole read has a budget and
// each call a timeout; out of time, it returns what it has.
struct AccessibilityReader {
    // The most seconds one read may take, and one call to the app.
    var budget: TimeInterval = 0.4
    var callTimeout: Float = 0.25
    // The most elements of the window looked at.
    var maxElements = 1500

    static var isTrusted: Bool { AXIsProcessTrusted() }
    // The apps whose document is web content, with an address of its own.
    static let showsWebContent: Set<String> = ["com.apple.Safari", "com.apple.mail"]

    // The snapshot for `app`, running as `pid`, or nil when it shows
    // nothing to send. Blocking: call it off the main thread.
    func read(app: NativeApp, pid: Int32) -> AmbientSnapshot? {
        guard let reading = reading(app: app, pid: pid) else { return nil }
        return AccessibilityContext.snapshot(reading, app: app, pid: pid)
    }

    func reading(app: NativeApp, pid: Int32) -> AccessibilityReading? {
        let deadline = Date().addingTimeInterval(budget)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, callTimeout)
        guard let window = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute)
        else { return nil }
        var reading = AccessibilityReading(windowTitle: string(window, kAXTitleAttribute),
                                           documentURL: string(window, kAXDocumentAttribute))
        switch app.shape {
        case .folder:
            readFolder(window, deadline: deadline, into: &reading)
        case .document:
            // First, with time of its own: it is quick, and the search for
            // a selection may use all of the rest.
            if app.id == "com.apple.Notes" {
                describeNote(in: window, deadline: Date().addingTimeInterval(budget / 2), into: &reading)
            }
            // The focused element first: when it is the text, no search.
            if let focused = element(application, kAXFocusedUIElementAttribute), let text = selection(of: focused) {
                reading.selectedText = text
                if let area = webArea(above: focused) { describe(area, into: &reading) }
            } else {
                search(window, deadline: deadline, into: &reading)
            }
            // A page with nothing selected is still what is open.
            // Only where there is a page to find: looking for one in Notes or
            // Preview walked the whole window and used the whole budget.
            if Self.showsWebContent.contains(app.id), reading.documentURL == nil, reading.selectedText != nil,
               let area = firstWebArea(in: window, deadline: deadline) {
                describe(area, into: &reading)
            }
        }
        return reading
    }

    // Breadth first over the window for the first element with a
    // selection, noting the first web area passed for its address.
    private func search(_ window: AXUIElement, deadline: Date, into reading: inout AccessibilityReading) {
        var queue = [window]
        var seen = 0
        var described = false
        while !queue.isEmpty, seen < maxElements, Date() < deadline {
            let next = queue.removeFirst()
            seen += 1
            // A toolbar holds the address and search fields, whose selection
            // is not what the user is reading.
            // Nor is a row of a list beside the document (the notes, the
            // mailboxes, a PDF's thumbnails), and those are most of a window.
            let role = string(next, kAXRoleAttribute)
            if isSecure(next) || role == "AXToolbar" || role == "AXOutline" || role == "AXTable" { continue }
            if !described, role == "AXWebArea" {
                describe(next, into: &reading)
                described = true
            }
            if let text = selection(of: next) {
                reading.selectedText = text
                return
            }
            queue.append(contentsOf: children(next))
        }
    }

    // The selected text of one element: the standard attribute, or for web
    // content the string of its selected marker range.
    private func selection(of element: AXUIElement) -> String? {
        // A one-line field is an address, a search or a form's box, never
        // the document.
        guard !isSecure(element), string(element, kAXRoleAttribute) != "AXTextField" else { return nil }
        if let text = string(element, kAXSelectedTextAttribute), !text.isEmpty { return text }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &text) == .success,
            let found = text as? String, !found.isEmpty else { return nil }
        return found
    }

    // A page's own address and title, from its web area.
    private func describe(_ area: AXUIElement, into reading: inout AccessibilityReading) {
        if let url = url(area) { reading.documentURL = url }
        if let title = string(area, kAXTitleAttribute) ?? string(area, kAXDescriptionAttribute), !title.isEmpty {
            reading.documentTitle = title
        }
    }

    // Notes gives a note no address and no id, and its window is titled
    // for the folder. What names the note is beside it: the folder selected
    // in the sidebar, and the note's row in the list, whose texts are its
    // title, a snippet and when it was changed, in that order. The snippet
    // is not taken.
    private func describeNote(in window: AXUIElement, deadline: Date, into reading: inout AccessibilityReading) {
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen < maxElements, Date() < deadline {
            let next = queue.removeFirst()
            seen += 1
            let role = string(next, kAXRoleAttribute)
            if role == "AXOutline" || role == "AXTable", let row = elements(next, kAXSelectedRowsAttribute).first {
                let texts = staticTexts(in: row)
                if role == "AXOutline" {
                    if let folder = texts.first { reading.details["folder"] = folder }
                } else if let title = texts.first {
                    reading.documentTitle = title
                    if texts.count > 1, let changed = texts.last, changed.contains(where: \.isNumber) {
                        reading.details["modified"] = changed
                    }
                }
                continue
            }
            // The note's own text holds no list.
            if role == "AXTextArea" { continue }
            queue.append(contentsOf: children(next))
        }
    }

    private func staticTexts(in row: AXUIElement) -> [String] {
        var found: [String] = []
        var queue = [row]
        var seen = 0
        while !queue.isEmpty, seen < 40 {
            let next = queue.removeFirst()
            seen += 1
            if string(next, kAXRoleAttribute) == "AXStaticText", let value = string(next, kAXValueAttribute), !value.isEmpty {
                found.append(value)
            }
            queue.append(contentsOf: children(next))
        }
        return found
    }

    private func firstWebArea(in window: AXUIElement, deadline: Date) -> AXUIElement? {
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen < maxElements, Date() < deadline {
            let next = queue.removeFirst()
            seen += 1
            let role = string(next, kAXRoleAttribute)
            if role == "AXWebArea" { return next }
            if role == "AXToolbar" || role == "AXOutline" || role == "AXTable" { continue }
            queue.append(contentsOf: children(next))
        }
        return nil
    }

    private func webArea(above element: AXUIElement) -> AXUIElement? {
        var at: AXUIElement? = element
        for _ in 0..<40 {
            guard let current = at else { return nil }
            if string(current, kAXRoleAttribute) == "AXWebArea" { return current }
            at = self.element(current, kAXParentAttribute)
        }
        return nil
    }

    // Finder: the selected entries of the last list in the window that has
    // any, each with its name and address. The last, because column view
    // is a list per column, each with the folder on the way selected, and
    // the files the user chose are in the final one. The sidebar is a list
    // with a selection too, and is passed over.
    //
    // Finder gives a window no address. The folder's is the one its
    // selected files share (AccessibilityContext); with nothing selected it
    // is the folder the first entry of the last list is in; and when the
    // one thing selected is the folder the window is titled for (column
    // view, a folder clicked and nothing chosen inside it), that folder is
    // what is open and nothing counts as selected.
    private func readFolder(_ window: AXUIElement, deadline: Date, into reading: inout AccessibilityReading) {
        var queue = [window]
        var seen = 0
        var found: [AXUIElement] = []
        var lastList: AXUIElement?
        while !queue.isEmpty, seen < maxElements, Date() < deadline {
            let next = queue.removeFirst()
            seen += 1
            if string(next, kAXDescriptionAttribute) == "sidebar" { continue }
            let role = string(next, kAXRoleAttribute)
            let isList = role == "AXList" || role == "AXOutline"
            if isList { lastList = next }
            let chosen = elements(next, kAXSelectedRowsAttribute) + elements(next, kAXSelectedChildrenAttribute)
            if !chosen.isEmpty {
                found = chosen
                // What is selected is not searched: a file holds no list.
                continue
            }
            // Nor are a list's own entries: there can be thousands.
            if isList { continue }
            queue.append(contentsOf: children(next))
        }
        var items = found.prefix(AccessibilityContext.maxItems).compactMap { file($0) }
        if items.count == 1, let only = items.first, let address = only.url, let url = URL(string: address),
           url.hasDirectoryPath, only.title == reading.windowTitle {
            reading.documentURL = address
            items = []
        } else if items.isEmpty, let lastList {
            for entry in children(lastList).prefix(3) {
                guard let address = file(entry)?.url, let url = URL(string: address), url.isFileURL else { continue }
                reading.documentURL = url.deletingLastPathComponent().absoluteString
                break
            }
        }
        reading.items = items
    }

    // A file's name and address: its own, or those of something just
    // inside it (a row holds a cell, which holds the name).
    private func file(_ row: AXUIElement) -> AccessibilityReading.Item? {
        var item = AccessibilityReading.Item()
        var level = [row]
        for _ in 0..<3 where item.title == nil || item.url == nil {
            for element in level {
                if item.url == nil { item.url = url(element) }
                if item.title == nil {
                    item.title = string(element, kAXFilenameAttribute) ?? name(element)
                }
            }
            level = level.flatMap { children($0) }
        }
        if item.title == nil, let url = item.url, let parsed = URL(string: url) { item.title = parsed.lastPathComponent }
        return item.title == nil && item.url == nil ? nil : item
    }

    private func name(_ element: AXUIElement) -> String? {
        let role = string(element, kAXRoleAttribute)
        guard role == "AXTextField" || role == "AXStaticText" else { return nil }
        guard let value = string(element, kAXValueAttribute), !value.isEmpty else { return nil }
        return value
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == "AXSecureTextField"
    }

    // MARK: - Attribute reads

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func url(_ element: AXUIElement) -> String? {
        guard let value = value(element, kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }
}

// The one read of the app in front that the composer and dictation share:
// its provider when it has one, its own or a helper's; otherwise, for a
// listed app that is switched on, Sirius's own read through Accessibility.
enum FrontAppContext {
    static func read(pid: Int32, bundleID: String, defaults: UserDefaults = .standard) async -> AmbientSnapshot? {
        // A provider the user switched off in Settings is not asked.
        guard ContextProviders.isOn(bundleID, in: defaults) else { return nil }
        if let answer = await AmbientContextSource().context(frontPID: pid, bundleID: bundleID) {
            // Remembered, so Settings can list it: the app in front, which
            // a helper may have answered for.
            let running = NSRunningApplication(processIdentifier: pid)
            ContextProviders.note(id: bundleID, name: running?.localizedName ?? answer.appName,
                                  path: running?.bundleURL?.path, in: defaults)
            return answer
        }
        guard let app = NativeApps.app(bundleID), NativeApps.isOn(app, in: defaults), AccessibilityReader.isTrusted
        else { return nil }
        return await Task.detached(priority: .userInitiated) {
            AccessibilityReader().read(app: app, pid: pid)
        }.value
    }
}

// Reads one running app the way a message would and prints what kind of
// thing came back, for checking the reader against a real app:
//   SiriusApp --probe-context com.apple.Preview
// Lengths and counts only, never content, unless SIRIUS_PROBE_SHOW=1.
// Reads the app whatever its switch says. Exits.
enum AccessibilityProbe {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--probe-context"), flag + 1 < arguments.count else { return }
        let bundleID = arguments[flag + 1]
        guard AccessibilityReader.isTrusted else { exit(say("not trusted for Accessibility", 3)) }
        guard let app = NativeApps.app(bundleID) else { exit(say("\(bundleID) is not a listed app", 2)) }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            exit(say("\(bundleID) is not running", 1))
        }
        let show = ProcessInfo.processInfo.environment["SIRIUS_PROBE_SHOW"] == "1"
        let started = Date()
        let reading = AccessibilityReader().reading(app: app, pid: running.processIdentifier)
        let took = Int(Date().timeIntervalSince(started) * 1000)
        func describe(_ text: String?) -> String {
            guard let text else { return "none" }
            return show ? "\"\(text.prefix(120))\"" : "\(text.count) chars"
        }
        print("\(app.name): \(took) ms")
        if arguments.contains("--times") {
            for _ in 0..<5 {
                let again = Date()
                _ = AccessibilityReader().reading(app: app, pid: running.processIdentifier)
                print("  again: \(Int(Date().timeIntervalSince(again) * 1000)) ms")
            }
        }
        guard let reading else { exit(say("no window", 1)) }
        print("  window title: \(describe(reading.windowTitle))")
        print("  document url: \(describe(reading.documentURL))")
        print("  document title: \(describe(reading.documentTitle))")
        print("  selected text: \(describe(reading.selectedText))")
        print("  items: \(reading.items.count)")
        for (key, value) in reading.details.sorted(by: { $0.key < $1.key }) { print("  \(key): \(describe(value))") }
        for item in reading.items.prefix(5) { print("    title \(describe(item.title)), url \(describe(item.url))") }
        if let snapshot = AccessibilityContext.snapshot(reading, app: app, pid: running.processIdentifier) {
            let summary = snapshot.summary
            print("  line: \(describe(summary.subject)) · \(describe(summary.selection))")
            print("  elements: \(snapshot.count)")
        } else {
            print("  nothing to send")
        }
        exit(0)
    }

    private static func say(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
        return code
    }
}
