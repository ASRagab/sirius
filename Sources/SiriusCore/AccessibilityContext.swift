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
    public static let sourceAttribute = "source"
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
        return AmbientElement(id: "window", role: "Window", title: title, focused: true, children: [inner])
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

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public static let key = "context.providers"
    // The most apps remembered; the oldest are dropped past it.
    public static let maxSeen = 100

    public static func seen(in defaults: UserDefaults) -> [Seen] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Seen].self, from: data)) ?? []
    }

    // Remembers the app, or its new name. Returns whether anything changed.
    @discardableResult
    public static func note(id: String, name: String, in defaults: UserDefaults) -> Bool {
        var all = seen(in: defaults)
        if let index = all.firstIndex(where: { $0.id == id }) {
            guard all[index].name != name else { return false }
            all[index].name = name
        } else {
            all.append(Seen(id: id, name: name))
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
