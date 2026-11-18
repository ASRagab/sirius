import Foundation

// Context from apps that are not Ambient Context providers. Sirius reads a
// short fixed list of Apple's apps itself, through macOS Accessibility, and
// reports what it found as the tree a provider would send, so the context
// line, the message and the log handle one shape. The reading is done in
// SiriusApp (AccessibilityReader); everything here is pure: the list, the
// switches, and the step from what an app reported to the tree.
//
// The list is the privacy boundary: these apps did not opt in, so an app
// not on it is never read, and each has a switch.
public struct NativeApp: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        // A window on one document: its address and title, and the
        // selected text in it. The subrole says what kind.
        case document(String)
        // A window on a folder; the selection is files.
        case folder
    }

    public let id: String
    public let name: String
    public let shape: Shape
    // Read without being switched on first. An app that is off is opt in:
    // read only once the user turns it on in Settings.
    public let onByDefault: Bool
    // What it shows is often someone else's words. Sirius warns before the
    // first message that carries context from a sensitive app.
    public let sensitive: Bool
}

public enum NativeApps {
    // Messages is left out: every bubble on screen is readable there, and
    // it is someone else's words.
    public static let all: [NativeApp] = [
        NativeApp(id: "com.apple.Preview", name: "Preview", shape: .document("file"), onByDefault: true, sensitive: false),
        NativeApp(id: "com.apple.Notes", name: "Notes", shape: .document("note"), onByDefault: true, sensitive: false),
        NativeApp(id: "com.apple.Safari", name: "Safari", shape: .document("page"), onByDefault: true, sensitive: false),
        NativeApp(id: "com.apple.finder", name: "Finder", shape: .folder, onByDefault: true, sensitive: false),
        NativeApp(id: "com.apple.mail", name: "Mail", shape: .document("message"), onByDefault: false, sensitive: true),
    ]

    public static func app(_ bundleID: String) -> NativeApp? {
        all.first { $0.id == bundleID }
    }

    // The app's switch in Sirius's defaults. Unset is the app's default.
    public static func key(_ app: NativeApp) -> String { "context.app.\(app.id)" }

    public static func isOn(_ app: NativeApp, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key(app)) == nil ? app.onByDefault : defaults.bool(forKey: key(app))
    }
}

// What one read of an app's front window reported, before it is a tree.
public struct AccessibilityReading: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String?
        public var url: String?

        public init(title: String? = nil, url: String? = nil) {
            self.title = title
            self.url = url
        }
    }

    public var windowTitle: String?
    // The document, page or folder the window shows.
    public var documentURL: String?
    public var documentTitle: String?
    public var selectedText: String?
    // The selected files (Finder).
    public var items: [Item]
    // More that names the document, by attribute name: a note's folder and
    // when it was last changed.
    public var details: [String: String]

    public init(
        windowTitle: String? = nil, documentURL: String? = nil, documentTitle: String? = nil,
        selectedText: String? = nil, items: [Item] = [], details: [String: String] = [:]
    ) {
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.documentTitle = documentTitle
        self.selectedText = selectedText
        self.items = items
        self.details = details
    }
}

public enum AccessibilityContext {
    // The scheme of the endpoint of a snapshot Sirius assembled itself:
    // nothing listens there, and nothing is ever asked of it.
    public static let scheme = "accessibility"
    // On the root, so an agent can tell a tree Sirius read from an app's
    // own answer.
    public static let sourceAttribute = "via"
    // The most characters of selected text kept, as for a provider.
    public static let maxTextChars = 20_000
    // The most selected files kept.
    public static let maxItems = 50

    // The snapshot for what `app`, process `pid`, reported, or nil when it
    // reported nothing worth sending: no window, document or selection.
    public static func snapshot(
        _ reading: AccessibilityReading, app: NativeApp, pid: Int32, instance: String = UUID().uuidString
    ) -> AmbientSnapshot? {
        guard let window = window(reading, app: app) else { return nil }
        let root = AmbientElement(
            id: "app", role: "Application", title: app.name, focused: true, children: [window],
            attributes: [sourceAttribute: .string(scheme)])
        let descriptor = AmbientDescriptor(
            protocol: "0.2.2", app: .init(id: app.id, name: app.name, version: nil), pid: pid, instance: instance,
            endpoint: "\(scheme):", token: "", started: nil, answersFor: nil)
        guard let endpoint = URL(string: descriptor.endpoint) else { return nil }
        return AmbientSnapshot(
            provider: AmbientProvider(descriptor: descriptor, endpoint: endpoint),
            tree: AmbientTree(protocol: descriptor.protocol, instance: instance, root: root))
    }

    // The window and the one path in it that matters. Every element on the
    // way to the selection is focused, as the protocol asks.
    static func window(_ reading: AccessibilityReading, app: NativeApp) -> AmbientElement? {
        let title = clean(reading.windowTitle)
        let text = clean(reading.selectedText).map(capped)
        let selection = text.map {
            AmbientElement(id: "selection", role: "Text", content: [.object(["type": .string("text"), "text": .string($0)])],
                           selected: true, focused: true)
        }
        let inner: AmbientElement
        switch app.shape {
        case .document(let kind):
            let url = clean(reading.documentURL)
            // A file is named by its address: Preview's window title adds
            // the page count to it.
            let name = clean(reading.documentTitle) ?? fileName(url) ?? title
            guard name != nil || url != nil || selection != nil else { return nil }
            var details: [String: AmbientJSON] = [:]
            for (key, value) in reading.details { if let value = clean(value) { details[key] = .string(value) } }
            inner = AmbientElement(id: "document", role: "Document", subrole: fileKind(url) ?? kind, title: name, url: url, focused: true,
                                   children: selection.map { [$0] } ?? [], attributes: details.isEmpty ? nil : details)
        case .folder:
            let rows = reading.items.prefix(maxItems).enumerated().compactMap { index, item -> AmbientElement? in
                let name = clean(item.title), url = clean(item.url)
                guard name != nil || url != nil else { return nil }
                return AmbientElement(id: "file-\(index + 1)", role: "Row", subrole: "file", title: name, url: url,
                                      selected: true, focused: index == 0)
            }
            // Finder gives a window no address, so the folder's is the one
            // its selected files share.
            let url = clean(reading.documentURL) ?? sharedFolder(reading.items.compactMap { clean($0.url) })
            guard title != nil || url != nil || !rows.isEmpty else { return nil }
            inner = AmbientElement(id: "folder", role: "List", subrole: "folder", title: clean(reading.documentTitle) ?? title,
                                   url: url, focused: true, children: rows)
        }
        // The mark again on the window: the message lists what is inside
        // the root, so this is the one an agent sees.
        return AmbientElement(id: "window", role: "Window", title: title, focused: true, children: [inner],
                              attributes: [sourceAttribute: .string(scheme)])
    }

    // Apple's role names onto the protocol's thirteen. Anything else is a
    // group.
    public static func role(forApple role: String) -> String {
        switch role {
        case "AXApplication": "Application"
        case "AXWindow", "AXSheet", "AXDrawer": "Window"
        case "AXStaticText", "AXTextArea", "AXTextField": "Text"
        case "AXWebArea": "Document"
        case "AXOutline", "AXList", "AXBrowser": "List"
        case "AXTable": "Table"
        case "AXRow": "Row"
        case "AXCell": "Cell"
        case "AXHeading": "Heading"
        case "AXLink": "Link"
        case "AXImage": "Image"
        default: "Group"
        }
    }

    // What a file is, by its extension, when the app opens more than one
    // kind: Preview shows PDFs and images alike.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif", "icns", "psd", "svg",
    ]

    private static func fileKind(_ address: String?) -> String? {
        guard let address, let url = URL(string: address), url.isFileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return "pdf" }
        if imageExtensions.contains(ext) { return "image" }
        return ext.isEmpty ? nil : "file"
    }

    // The folder every one of these files is directly in, as an address.
    static func sharedFolder(_ addresses: [String]) -> String? {
        let folders = Set(addresses.compactMap { address -> String? in
            guard let url = URL(string: address), url.isFileURL else { return nil }
            return url.deletingLastPathComponent().absoluteString
        })
        return folders.count == 1 && !addresses.isEmpty ? folders.first : nil
    }

    private static func fileName(_ address: String?) -> String? {
        guard let address, let url = URL(string: address), url.isFileURL, !url.hasDirectoryPath else { return nil }
        return clean(url.lastPathComponent)
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func capped(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxTextChars else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars.prefix(maxTextChars))
        return String(kept)
    }
}

extension AmbientProvider {
    // Whether Sirius assembled this itself through Accessibility: there is
    // then no endpoint to ask and no watch to open on it.
    public var isNative: Bool { endpoint.scheme == AccessibilityContext.scheme }
}

// The apps that have given Sirius context as providers, their own or
// through a helper, kept so Settings can list them with a switch each.
// Sirius holds no list otherwise: it looks for the front app's descriptor
// at each read. An app is noted the first time a read of it answers, and
// is on until switched off; off, it is not asked.
public enum ContextProviders {
    public struct Seen: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        // Where the app was running from, for its icon: an app built
        // locally may not be one the system can find by its identifier.
        public var path: String?

        public init(id: String, name: String, path: String? = nil) {
            self.id = id
            self.name = name
            self.path = path
        }
    }

    public static let key = "context.providers"
    // The most apps remembered; the oldest are dropped past it.
    public static let maxSeen = 100

    public static func seen(in defaults: UserDefaults) -> [Seen] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Seen].self, from: data)) ?? []
    }

    // Remembers the app, or its new name or place. Returns whether anything
    // changed.
    @discardableResult
    public static func note(id: String, name: String, path: String? = nil, in defaults: UserDefaults) -> Bool {
        var all = seen(in: defaults)
        if let index = all.firstIndex(where: { $0.id == id }) {
            let place = path ?? all[index].path
            guard all[index].name != name || all[index].path != place else { return false }
            all[index].name = name
            all[index].path = place
        } else {
            all.append(Seen(id: id, name: name, path: path))
            if all.count > maxSeen { all.removeFirst(all.count - maxSeen) }
        }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    public static func key(_ id: String) -> String { "context.provider.\(id)" }

    public static func isOn(_ id: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key(id)) == nil ? true : defaults.bool(forKey: key(id))
    }
}

// Apps whose context is often someone else's words or private pages. Before
// a message carries context from one, Sirius warns, every time, until the
// user ticks "Don't warn again" for that app or turns the warning off in
// Settings. The mark is on the app, however its context is read: Mail is
// read by Sirius, Chrome answers through its helper.
public enum ContextWarnings {
    // Apps Sirius warns about whatever they say: Mail, which it reads
    // itself, and Chrome, whose provider may be older than the mark.
    public static let sensitive: Set<String> = ["com.apple.mail", "com.google.Chrome"]
    // The warning's switch in Settings. Unset is on.
    public static let enabledKey = "context.warn_sensitive"
    static let dismissedPrefix = "context.no_warning."
    // Apps that have marked an answer sensitive themselves (RFC-0007),
    // remembered so Settings can say so beside them.
    static let declaredKey = "context.declared_sensitive"

    public static func declared(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: declaredKey) ?? [])
    }

    // An answer from this app was marked sensitive.
    public static func noteDeclared(_ bundleID: String, in defaults: UserDefaults) {
        var seen = declared(in: defaults)
        guard seen.insert(bundleID).inserted else { return }
        defaults.set(seen.sorted(), forKey: declaredKey)
    }

    // Sirius's own list only.
    public static func isSensitive(_ bundleID: String) -> Bool { sensitive.contains(bundleID) }

    // Sirius's list, or an app that has said so itself: what Settings shows.
    public static func isSensitive(_ bundleID: String, in defaults: UserDefaults) -> Bool {
        isSensitive(bundleID) || declared(in: defaults).contains(bundleID)
    }

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    // Whether a message with context from this app is warned about first:
    // the app is on Sirius's list, or the answer in hand is marked
    // sensitive (`declared`). An answer that is not marked takes nothing
    // away from the list.
    public static func shouldWarn(_ bundleID: String, declared: Bool = false, in defaults: UserDefaults) -> Bool {
        (isSensitive(bundleID) || declared) && isEnabled(in: defaults)
            && !defaults.bool(forKey: dismissedPrefix + bundleID)
    }

    // "Don't warn again", for one app.
    public static func dismiss(_ bundleID: String, in defaults: UserDefaults) {
        defaults.set(true, forKey: dismissedPrefix + bundleID)
    }

    // The switch in Settings. Turning it on warns for every app again.
    public static func setEnabled(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: enabledKey)
        guard on else { return }
        for id in sensitive.union(declared(in: defaults)) { defaults.removeObject(forKey: dismissedPrefix + id) }
    }
}
