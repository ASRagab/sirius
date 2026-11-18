import CoreGraphics
import Darwin
import Foundation
import SiriusProtocol

// The host side of the Ambient Context Protocol, draft 0.2: find the
// provider for the app in front, check it, and read what is open and
// selected (`current`, a tree of elements) and where an item is on screen
// (`locate`). The first draft's flat list of items is no longer read. No UI
// and no AppKit; the app supplies the front app's process id and bundle id.
//
// The provider is the front app itself or, when the app has none of its
// own, a helper process that app started and that says it answers for it.
//
// Every failure, refusal or late answer comes back as no context. A provider
// can never make the host wait or show an error.

// MARK: - What a provider answers

// Global display coordinates in points: origin at the primary display's top
// left, y increasing downward.
public struct AmbientRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

// Free-form JSON, kept as the provider sent it: content blocks and payloads
// are passed to the agent untranslated.
public enum AmbientJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AmbientJSON])
    case object([String: AmbientJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AmbientJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AmbientJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> AmbientJSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// One thing the app shows: the app, a window, a document, a row,
// a run of text. Read leniently: a field of the wrong kind is dropped, not
// refused, and a role outside the protocol's list is read as a group.
public struct AmbientElement: Decodable, Equatable, Sendable {
    public static let roles: Set<String> = [
        "Application", "Window", "Group", "List", "Table", "Row", "Cell", "Text", "Heading", "Link", "Image",
        "Page", "Document",
    ]

    public var id: String
    public var role: String
    public var subrole: String?
    public var title: String?
    public var content: [AmbientJSON]?
    public var url: String?
    public var selected: Bool
    public var focused: Bool
    // Nil when the provider did not say: the parent's value then holds.
    public var visible: Bool?
    public var hovered: Bool
    public var children: [AmbientElement]
    public var attributes: [String: AmbientJSON]?

    public init(
        id: String, role: String, subrole: String? = nil, title: String? = nil, content: [AmbientJSON]? = nil,
        url: String? = nil, selected: Bool = false, focused: Bool = false, visible: Bool? = nil,
        hovered: Bool = false, children: [AmbientElement] = [], attributes: [String: AmbientJSON]? = nil
    ) {
        self.id = id
        self.role = Self.roles.contains(role) ? role : "Group"
        self.subrole = subrole
        self.title = title
        self.content = content
        self.url = url
        self.selected = selected
        self.focused = focused
        self.visible = visible
        self.hovered = hovered
        self.children = children
        self.attributes = attributes
    }

    private enum Key: String, CodingKey {
        case id, role, subrole, title, content, url, selected, focused, visible, hovered, children, attributes
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        func optional<Value: Decodable>(_ key: Key) -> Value? {
            (try? fields.decodeIfPresent(Value.self, forKey: key)) ?? nil
        }
        // The two fields nothing can be made of an element without.
        let id = try fields.decode(String.self, forKey: .id)
        let role = try fields.decode(String.self, forKey: .role)
        guard Self.isID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: fields, debugDescription: "not an element id")
        }
        // A child that cannot be read fails the answer: half a tree would
        // put what is left under the wrong parent.
        let children = try fields.decodeIfPresent([AmbientElement].self, forKey: .children) ?? []
        self.init(
            id: id, role: role, subrole: optional(.subrole), title: optional(.title), content: optional(.content),
            url: optional(.url), selected: optional(.selected) ?? false, focused: optional(.focused) ?? false,
            visible: optional(.visible), hovered: optional(.hovered) ?? false, children: children,
            attributes: optional(.attributes)
        )
    }

    // 1 to 128 letters, digits, hyphens and underscores.
    static func isID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard (1...128).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    // The element's text blocks joined.
    public var text: String? {
        let parts = (content ?? []).compactMap { block -> String? in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // This element and everything inside it, parents before children.
    public var all: [AmbientElement] { [self] + children.flatMap(\.all) }

    // How many elements are inside this one, at any depth.
    public var inside: Int { children.reduce(0) { $0 + 1 + $1.inside } }
}

// The answer to `current`: one tree rooted at the app.
public struct AmbientTree: Decodable, Equatable, Sendable {
    public var `protocol`: String
    public var instance: String
    public var root: AmbientElement
    // The app's own words for the composer's line, as a page's meta tags
    // word its card (0.2.1, operations 4.3). Optional; a field of the
    // wrong kind is dropped, not refused.
    public var display: AmbientDisplay?

    public init(protocol: String, instance: String, root: AmbientElement, display: AmbientDisplay? = nil) {
        self.protocol = `protocol`
        self.instance = instance
        self.root = root
        self.display = display
    }

    private enum Key: String, CodingKey { case `protocol`, instance, root, display }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        self.init(
            protocol: try fields.decode(String.self, forKey: .protocol),
            instance: try fields.decode(String.self, forKey: .instance),
            root: try fields.decode(AmbientElement.self, forKey: .root),
            display: (try? fields.decodeIfPresent(AmbientDisplay.self, forKey: .display)) ?? nil
        )
    }

    // Where the user is: the focused elements followed down from the root,
    // outermost first. One path; a second focused sibling, or a focused
    // element under an unfocused one, is a provider's mistake and is not on
    // it.
    public var focusPath: [AmbientElement] {
        var path: [AmbientElement] = []
        var at = root
        while let next = at.children.first(where: \.focused) {
            path.append(next)
            at = next
        }
        return path
    }

    public var selected: [AmbientElement] { root.all.dropFirst().filter(\.selected) }

    // The element under the pointer: the first so marked. The protocol
    // allows one, and none means nothing, not "the pointer is elsewhere".
    public var hovered: AmbientElement? { root.all.dropFirst().first(where: \.hovered) }

    // Every id names one element.
    var idsAreUnique: Bool {
        let ids = root.all.map(\.id)
        return Set(ids).count == ids.count
    }
}

public struct AmbientLocation: Codable, Equatable, Sendable {
    public var id: String
    // `visible`, `offscreen` or `gone`; anything else is treated as not
    // visible.
    public var state: String
    public var rects: [AmbientRect]?
    public var window: Int?
    public var avoid: AmbientRect?
    public var edge: String?

    public var isVisible: Bool { state == "visible" && !(rects ?? []).isEmpty }
}

// MARK: - The descriptor

// The file a running provider writes so a host can reach it.
public struct AmbientDescriptor: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: String?
    }

    // The app a helper answers for, when the provider is not the app
    // itself.
    public struct Target: Codable, Hashable, Sendable {
        public var id: String
        public var pid: Int32

        public init(id: String, pid: Int32) {
            self.id = id
            self.pid = pid
        }
    }

    public var `protocol`: String
    public var app: App
    public var pid: Int32
    public var instance: String
    public var endpoint: String
    public var token: String
    public var started: String?
    // `for` in the file. Absent when the app answers for itself; `app` and
    // `pid` then describe the helper, not the app answered for.
    public var answersFor: Target?

    private enum CodingKeys: String, CodingKey {
        case `protocol`, app, pid, instance, endpoint, token, started
        case answersFor = "for"
    }

    // The version has three parts, and a host and a provider work together
    // when the first two agree: any 0.2.x. The first draft, 0.1, is not
    // read.
    public static func supports(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "0" && parts[1] == "2" && UInt(parts[2]) != nil
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AmbientContext/providers", isDirectory: true)
    }

    public static func fileName(bundleID: String, pid: Int32) -> String {
        "\(bundleID).\(pid).json"
    }

    // The file of a helper, process `helper`, answering for the app
    // `bundleID` running as `pid`.
    public static func fileName(bundleID: String, pid: Int32, helper: Int32) -> String {
        "\(delegatedPrefix(bundleID: bundleID, pid: pid))\(helper).json"
    }

    // What the name of every helper's file for one process starts with.
    static func delegatedPrefix(bundleID: String, pid: Int32) -> String {
        "\(bundleID).\(pid).for."
    }
}

// Why a provider was not used. Never shown to the user; for the log and the
// tests.
public enum AmbientRefusal: Error, Equatable, Sendable {
    // No descriptor names the front app's process.
    case noDescriptor
    // The folder or file is not the user's alone, or is not a plain file.
    case unsafeFile
    case unreadable
    // The file's contents disagree with its name or with the front app.
    case pidMismatch
    case bundleMismatch
    case processGone
    case unsupportedProtocol
    // The endpoint is not plain HTTP on 127.0.0.1 with a port.
    case badEndpoint
    // The process the descriptor names is not the one listening there.
    case listenerMismatch
    // A helper's descriptor does not say it answers for the front app.
    case targetMismatch
    // A helper the front app did not start.
    case notStartedByApp
    case timeout
    case redirect
    case http(Int)
    case rpc(Int)
    case malformed
    // The answer came from a different run than the descriptor describes.
    case instanceMismatch
    // The answer is in a different version than the descriptor announced.
    case versionMismatch
    // The provider that issued an id has quit or restarted.
    case providerChanged
}

// The operating-system facts the checks need, replaceable in tests.
public struct AmbientSystem: Sendable {
    public var isRunning: @Sendable (Int32) -> Bool
    // Whether `pid` holds a listening TCP socket on `port`.
    public var listens: @Sendable (Int32, UInt16) -> Bool
    // The process that started `pid`, or nil when that cannot be told.
    public var parent: @Sendable (Int32) -> Int32?
    public var userID: @Sendable () -> UInt32

    // With no `parent` given nothing can be told, so every helper is
    // refused.
    public init(
        isRunning: @escaping @Sendable (Int32) -> Bool,
        listens: @escaping @Sendable (Int32, UInt16) -> Bool,
        parent: @escaping @Sendable (Int32) -> Int32? = { _ in nil },
        userID: @escaping @Sendable () -> UInt32 = { getuid() }
    ) {
        self.isRunning = isRunning
        self.listens = listens
        self.parent = parent
        self.userID = userID
    }

    public static let live = AmbientSystem(
        isRunning: { pid in kill(pid, 0) == 0 || errno == EPERM },
        listens: { pid, port in AmbientSystem.processListens(pid: pid, port: port) },
        parent: { pid in AmbientSystem.processParent(pid: pid) }
    )

    // The direct parent, as the kernel has it now: a process whose parent
    // has exited belongs to launchd, not to the one that started it.
    static func processParent(pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(exactly: info.pbi_ppid)
    }

    // Walks the process's open files for a TCP socket in the listening
    // state bound to `port`. Works for the user's own processes without any
    // permission; for anyone else's it finds nothing, which refuses.
    static func processListens(pid: Int32, port: UInt16) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var files = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &files, Int32(files.count * stride))
        guard used > 0 else { return false }
        let socketType: UInt32 = 2 // PROX_FDTYPE_SOCKET
        let tcpKind: Int32 = 2 // SOCKINFO_TCP
        let listening: Int32 = 1 // TSI_S_LISTEN
        for file in files.prefix(Int(used) / stride) where file.proc_fdtype == socketType {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_kind == tcpKind else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == listening else { continue }
            // The local port sits in the low 16 bits, in network byte order.
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if local == port { return true }
        }
        return false
    }
}

// A provider that passed every check: the only thing a client is made from.
public struct AmbientProvider: Equatable, Sendable {
    public let descriptor: AmbientDescriptor
    public let endpoint: URL
}

// The full name of an item: the provider, its run, and the id. An id alone
// means nothing; two providers may both issue `sel-1`, and one provider may
// issue it again after a restart.
//
// `bundleID` and `pid` are the provider's own. When that is a helper,
// `answersFor` is the app it answered for, which is what its file is named
// after and so what finds it again.
public struct AmbientItemRef: Hashable, Sendable {
    public let bundleID: String
    public let pid: Int32
    public let instance: String
    public let id: String
    public let answersFor: AmbientDescriptor.Target?

    public init(
        bundleID: String, pid: Int32, instance: String, id: String, answersFor: AmbientDescriptor.Target? = nil
    ) {
        self.bundleID = bundleID
        self.pid = pid
        self.instance = instance
        self.id = id
        self.answersFor = answersFor
    }
}

// An app's favicon: a small picture of the app made for a line of text,
// as a site's favicon is to its app icon. It is a file in the app's own
// bundle, `Contents/Resources/favicon.svg` or, failing that,
// `favicon.png`. It is never sent: Sirius knows the bundle of the app in
// front and looks for the fixed name itself, so it follows no path an app
// names, and the file is under the app's code signature. A file over
// `maxBytes`, or one that is not what its name says, is passed over, and the host shows the app's own icon.
public enum AmbientFavicon {
    public static let maxBytes = 256 * 1024
    public static let names = ["favicon.svg", "favicon.png"]

    // Where a few well-known apps that ship no favicon keep a picture of
    // themselves made for small sizes, inside their own bundle: by bundle
    // id, a path from the bundle's root. Sirius ships no other app's logo;
    // it reads the one the app installed. Looked at only when the app has
    // no favicon of its own.
    public static let known: [String: String] = {
        // Chrome's own logo without the Dock icon's white tile, 32 px.
        let chrome = "Contents/Frameworks/Google Chrome Framework.framework/Resources/product_logo_32.png"
        return [
            "com.google.Chrome": chrome,
            "com.google.Chrome.beta": chrome,
            "com.google.Chrome.dev": chrome,
            "com.google.Chrome.canary": chrome,
        ]
    }()

    // The favicon's bytes for the app at `bundle`, or nil: the app's own
    // favicon file, else the picture a well-known app keeps (`known`).
    public static func data(inBundle bundle: URL, bundleID: String? = nil) -> Data? {
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        for name in names {
            if let data = file(resources.appendingPathComponent(name), in: bundle) { return data }
        }
        if let bundleID, let path = known[bundleID] { return file(bundle.appendingPathComponent(path), in: bundle) }
        return nil
    }

    // A file's bytes when it is a plain file of a sane size, is what its
    // name says, and is inside `bundle` once every link on the way to it
    // is followed. A link out of the bundle is not the app's own file.
    private static func file(_ file: URL, in bundle: URL) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maxBytes
        else { return nil }
        let real = file.resolvingSymlinksInPath().standardizedFileURL.path
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        guard real.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              let data = try? Data(contentsOf: file), data.count <= maxBytes,
              looksRight(data, name: file.lastPathComponent)
        else { return nil }
        return data
    }

    private static func looksRight(_ data: Data, name: String) -> Bool {
        if name.hasSuffix(".png") { return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
        return String(data: data, encoding: .utf8)?.contains("<svg") == true
    }
}

// What an app asks the composer's line to say: `title` for what is open,
// `detail` for what is selected in it. Plain text; Sirius cuts each to one
// line of `maxChars` and draws it in its own layout. The picture beside
// it is the app's favicon, a file in its bundle (AmbientFavicon).
public struct AmbientDisplay: Equatable, Sendable, Decodable {
    public static let maxChars = 80
    public var title: String?
    public var detail: String?

    public init(title: String? = nil, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    private enum Key: String, CodingKey { case title, detail }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        title = (try? fields.decodeIfPresent(String.self, forKey: .title)) ?? nil
        detail = (try? fields.decodeIfPresent(String.self, forKey: .detail)) ?? nil
    }
}

// One line for what a tree holds, as the composer shows it beside the
// app's icon: the subject, which is what is open (the innermost titled
// thing in focus that is not itself the selection, else the app), and the
// selection, which is what the agent is sent text for. An app that sends
// its own words (AmbientDisplay) is quoted; one that does not gets
// Sirius's wording from its tree.
public struct AmbientSummary: Equatable, Sendable {
    public var subject: String
    public var selection: String?

    public init(subject: String, selection: String? = nil) {
        self.subject = subject
        self.selection = selection
    }

    public init(_ tree: AmbientTree, app: String) {
        if let title = Self.named(tree.display?.title) {
            subject = title
            selection = Self.named(tree.display?.detail)
            return
        }
        let selected = tree.selected
        let open = tree.focusPath.last { !$0.selected && $0.role != "Text" && Self.named($0.title) != nil }
        subject = Self.named(open?.title) ?? app
        guard let first = selected.first else { return }
        if selected.count > 1 {
            selection = "\(selected.count) selected"
            return
        }
        // One thing selected. With nothing titled open around it (a
        // browser's page, say), its own title is the subject.
        let own = Self.named(first.title)
        if open == nil, let own { subject = own }
        if let range = AmbientSnapshot.lines(first.attributes) {
            selection = range.count == 1 ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)"
        } else if let own, own != subject {
            selection = own
        } else if first.role == "Text" || own == nil,
                  let words = first.text?.split(whereSeparator: \.isWhitespace).count, words > 0 {
            selection = words == 1 ? "1 word" : "\(words) words"
        } else if own == nil {
            selection = "1 selected"
        }
    }

    // A title worth showing: one line, without control characters, not
    // blank.
    private static func named(_ title: String?) -> String? {
        guard let line = title?.split(whereSeparator: \.isNewline).first else { return nil }
        var plain = String.UnicodeScalarView()
        plain.append(contentsOf: line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = String(plain).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > AmbientDisplay.maxChars ? String(trimmed.prefix(AmbientDisplay.maxChars)) + "…" : trimmed
    }
}

// What one read of the front app gave: the tree, and the provider it came
// from, so every id in it can be named in full.
public struct AmbientSnapshot: Equatable, Sendable {
    public let provider: AmbientProvider
    public let tree: AmbientTree

    public init(provider: AmbientProvider, tree: AmbientTree) {
        self.provider = provider
        self.tree = tree
    }

    // How many things the tree names, for the log.
    public var count: Int { tree.root.inside }

    // What the composer's context line says (AmbientSummary).
    public var summary: AmbientSummary { AmbientSummary(tree, app: appName) }

    // The app's name: the tree's own, or the descriptor's.
    public var appName: String { tree.root.title ?? provider.descriptor.app.name }

    // The app the context is about: the one a helper answers for, or the
    // provider's own.
    public var source: String { provider.descriptor.answersFor?.id ?? provider.descriptor.app.id }

    // The helper's process id when a helper answered, for the log.
    public var helper: Int32? { provider.descriptor.answersFor == nil ? nil : provider.descriptor.pid }

    // The most elements one message carries, and the most characters of
    // an attribute's value.
    public static let maxElements = 150
    public static let maxAttributes = 8
    public static let maxAttributeChars = 200

    // The form that goes on a message. Text is sent for what the user is
    // pointing at only; everything else open is named, not quoted.
    //
    // The tree as the items of a message, parents before children, each
    // naming its parent. The root is left out: it is the app, which the
    // context already names.
    //
    // What is sent in full is what the user is pointing at. An element's
    // text goes only when it is selected or on the focus path; being
    // hovered never adds text. A branch that is not on screen and holds
    // nothing selected, focused or hovered is one item with a count of
    // what is inside it. If the tree is still too large, the same is done
    // to every branch that holds nothing pointed at, and whatever is over
    // the limit after that is dropped and counted.
    public var messageContext: Message.Context {
        let path = Set(tree.focusPath.map(\.id))
        let hovered = tree.hovered?.id
        var pointed: Set<String> = [] // holds, or is, something pointed at
        func mark(_ element: AmbientElement) -> Bool {
            var any = element.selected || path.contains(element.id) || element.id == hovered
            for child in element.children where mark(child) { any = true }
            if any { pointed.insert(element.id) }
            return any
        }
        _ = mark(tree.root)

        var textLeft = Limits.maxTextChars
        func build(onlyPointed: Bool) -> [Message.Context.Item] {
            var items: [Message.Context.Item] = []
            textLeft = Limits.maxTextChars
            func walk(_ element: AmbientElement, parent: String?, parentVisible: Bool) {
                let visible = element.visible ?? parentVisible
                let open = pointed.contains(element.id) || (visible && !onlyPointed)
                let sendsText = element.selected || path.contains(element.id)
                var text: String?
                var cut: Bool?
                if sendsText, let whole = element.text, textLeft > 0 {
                    let scalars = whole.unicodeScalars
                    if scalars.count > textLeft {
                        var kept = String.UnicodeScalarView()
                        kept.append(contentsOf: scalars.prefix(textLeft))
                        text = String(kept)
                        cut = true
                    } else {
                        text = whole
                    }
                    textLeft -= min(scalars.count, textLeft)
                }
                items.append(Message.Context.Item(
                    id: element.id, type: element.role, title: element.title ?? "", url: element.url,
                    parent: parent, lines: Self.lines(element.attributes), text: text,
                    focused: path.contains(element.id),
                    subrole: element.subrole, selected: element.selected ? true : nil,
                    hovered: element.id == hovered ? true : nil, visible: visible ? nil : false,
                    attributes: Self.attributes(element.attributes),
                    inside: open || element.children.isEmpty ? nil : element.inside, cut: cut
                ))
                guard open else { return }
                for child in element.children { walk(child, parent: element.id, parentVisible: visible) }
            }
            for child in tree.root.children { walk(child, parent: nil, parentVisible: tree.root.visible ?? true) }
            return items
        }

        var items = build(onlyPointed: false)
        if items.count > Self.maxElements { items = build(onlyPointed: true) }
        var omitted: Int?
        if items.count > Self.maxElements {
            // Keep everything pointed at; fill what room is left in order.
            var room = Self.maxElements - items.filter { pointed.contains($0.id) }.count
            var kept: Set<String> = []
            var dropped = 0
            items = items.filter { item in
                // An item whose parent went has nothing to hang from.
                if let parent = item.parent, !kept.contains(parent) { dropped += 1 + (item.inside ?? 0); return false }
                if !pointed.contains(item.id) {
                    guard room > 0 else { dropped += 1 + (item.inside ?? 0); return false }
                    room -= 1
                }
                kept.insert(item.id)
                return true
            }
            omitted = dropped
        }
        return Message.Context(
            app: appName, source: source, items: items, version: tree.protocol, omitted: omitted
        )
    }

    // `lines` among an element's attributes: 1-based first and last.
    static func lines(_ attributes: [String: AmbientJSON]?) -> ClosedRange<Int>? {
        guard case .number(let start)? = attributes?["lines"]?["start"],
              case .number(let end)? = attributes?["lines"]?["end"],
              let first = Int(exactly: start), let last = Int(exactly: end), first <= last
        else { return nil }
        return first...last
    }

    // The app's plain named values, as text: strings, numbers and
    // booleans. Lists and objects are left out, and so are names that
    // would not make an attribute. At most `maxAttributes`, by name.
    private static func attributes(_ attributes: [String: AmbientJSON]?) -> [String: String]? {
        var plain: [String: String] = [:]
        for name in (attributes ?? [:]).keys.sorted() where plain.count < maxAttributes {
            guard AmbientElement.isID(name), name.count <= 40 else { continue }
            let value: String
            switch attributes?[name] {
            case .string(let text)?: value = text
            case .bool(let flag)?: value = flag ? "true" : "false"
            case .number(let number)?:
                value = Int(exactly: number).map(String.init) ?? String(number)
            default: continue
            }
            var short = String.UnicodeScalarView()
            short.append(contentsOf: value.unicodeScalars.prefix(maxAttributeChars))
            plain[name] = String(short)
        }
        return plain.isEmpty ? nil : plain
    }

    public func ref(_ id: String) -> AmbientItemRef {
        AmbientItemRef(
            bundleID: provider.descriptor.app.id, pid: provider.descriptor.pid,
            instance: provider.descriptor.instance, id: id, answersFor: provider.descriptor.answersFor
        )
    }
}

// MARK: - Finding and checking

public struct AmbientProviderCheck: Sendable {
    public var directory: URL
    public var system: AmbientSystem

    public init(directory: URL = AmbientDescriptor.defaultDirectory, system: AmbientSystem = .live) {
        self.directory = directory
        self.system = system
    }

    // The most helper files opened for one front app.
    public static let maxDelegates = 16

    // The provider for the process in front, or the reason there is none.
    // Reads one file, named for that process; no other descriptor is opened.
    public func provider(pid: Int32, bundleID: String) -> Result<AmbientProvider, AmbientRefusal> {
        let file = directory.appendingPathComponent(AmbientDescriptor.fileName(bundleID: bundleID, pid: pid))
        return load(file).flatMap { found in
            var descriptor = found
            guard descriptor.pid == pid else { return .failure(.pidMismatch) }
            guard descriptor.app.id == bundleID else { return .failure(.bundleMismatch) }
            // An app answering for itself answers for no one else.
            descriptor.answersFor = nil
            return reachable(descriptor)
        }
    }

    // The helpers that say they answer for the process in front, in the
    // order of their files' names, each checked. Looked at only when the
    // app has no descriptor of its own. Only files named for that process
    // are opened.
    public func delegates(pid: Int32, bundleID: String) -> [Result<AmbientProvider, AmbientRefusal>] {
        let prefix = AmbientDescriptor.delegatedPrefix(bundleID: bundleID, pid: pid)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted()
        return names.prefix(Self.maxDelegates).map { name in
            // Only a name that is exactly what this helper's file would be
            // called: the process id in it is then the one to hold it to.
            guard let helper = Int32(name.dropFirst(prefix.count).dropLast(".json".count)),
                  name == AmbientDescriptor.fileName(bundleID: bundleID, pid: pid, helper: helper)
            else { return .failure(.pidMismatch) }
            return delegate(pid: pid, bundleID: bundleID, helper: helper)
        }
    }

    // One helper, process `helper`, answering for the process in front. As
    // for the app's own descriptor, with the helper as the process that
    // must be running and listening, and one check more: the front app
    // started it. Its direct parent, not any ancestor.
    public func delegate(pid: Int32, bundleID: String, helper: Int32) -> Result<AmbientProvider, AmbientRefusal> {
        let name = AmbientDescriptor.fileName(bundleID: bundleID, pid: pid, helper: helper)
        return load(directory.appendingPathComponent(name)).flatMap { descriptor in
            guard descriptor.pid == helper, helper != pid else { return .failure(.pidMismatch) }
            guard descriptor.answersFor == AmbientDescriptor.Target(id: bundleID, pid: pid) else {
                return .failure(.targetMismatch)
            }
            return reachable(descriptor).flatMap { provider in
                system.parent(helper) == pid ? .success(provider) : .failure(.notStartedByApp)
            }
        }
    }

    // The descriptor in `file`, if it is the user's own plain file, closed
    // to everyone else, in a folder that is the same.
    private func load(_ file: URL) -> Result<AmbientDescriptor, AmbientRefusal> {
        guard let fileState = Self.status(of: file) else { return .failure(.noDescriptor) }
        guard let folderState = Self.status(of: directory) else { return .failure(.noDescriptor) }
        let user = system.userID()
        guard fileState.st_mode & S_IFMT == S_IFREG, fileState.st_uid == user, fileState.st_mode & 0o077 == 0,
              folderState.st_mode & S_IFMT == S_IFDIR, folderState.st_uid == user, folderState.st_mode & 0o077 == 0
        else { return .failure(.unsafeFile) }

        guard let data = try? Data(contentsOf: file),
              let descriptor = try? JSONDecoder().decode(AmbientDescriptor.self, from: data)
        else { return .failure(.unreadable) }
        return .success(descriptor)
    }

    // The checks on the process the descriptor names: a version the host
    // speaks, still running, and itself the listener at the endpoint.
    private func reachable(_ descriptor: AmbientDescriptor) -> Result<AmbientProvider, AmbientRefusal> {
        guard AmbientDescriptor.supports(descriptor.protocol) else {
            return .failure(.unsupportedProtocol)
        }
        guard system.isRunning(descriptor.pid) else { return .failure(.processGone) }

        guard let endpoint = URL(string: descriptor.endpoint), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", let port = endpoint.port, let narrow = UInt16(exactly: port),
              endpoint.user == nil, endpoint.password == nil
        else { return .failure(.badEndpoint) }
        guard system.listens(descriptor.pid, narrow) else { return .failure(.listenerMismatch) }
        return .success(AmbientProvider(descriptor: descriptor, endpoint: endpoint))
    }

    // lstat, so a link is seen as a link and refused.
    private static func status(of url: URL) -> stat? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info : nil
    }
}

// MARK: - Reading

// Reads the two resources from one checked provider. One HTTP POST per
// read, no redirects, a limit on the whole exchange.
public struct AmbientClient: Sendable {
    public static let mcpVersion = "2026-07-28"
    public static let currentURI = "ambient://current"

    public let provider: AmbientProvider
    public var limit: TimeInterval

    public init(provider: AmbientProvider, limit: TimeInterval = 0.25) {
        self.provider = provider
        self.limit = limit
    }

    public static func locationURI(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return "ambient://location/" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)
    }

    // What is open. An answer from another run, or in another version than
    // the descriptor announced, is not used.
    public func current() async throws -> AmbientTree {
        let tree: AmbientTree = try await read(Self.currentURI)
        guard tree.instance == provider.descriptor.instance else { throw AmbientRefusal.instanceMismatch }
        guard tree.protocol == provider.descriptor.protocol else { throw AmbientRefusal.versionMismatch }
        guard tree.idsAreUnique else { throw AmbientRefusal.malformed }
        return tree
    }

    public func locate(_ id: String) async throws -> AmbientLocation {
        let answer: AmbientLocation = try await read(Self.locationURI(id))
        guard answer.id == id else { throw AmbientRefusal.malformed }
        return answer
    }

    // The request as it goes on the wire, exposed for the tests.
    func request(reading uri: String) -> URLRequest {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = limit
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(provider.descriptor.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.mcpVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("resources/read", forHTTPHeaderField: "Mcp-Method")
        request.setValue(uri, forHTTPHeaderField: "Mcp-Name")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/read",
            "params": [
                "uri": uri,
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": Self.mcpVersion,
                    "io.modelcontextprotocol/clientCapabilities": [String: Any](),
                ] as [String: Any],
            ] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func read<Answer: Decodable>(_ uri: String) async throws -> Answer {
        let request = request(reading: uri)
        let limit = limit
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                let session = URLSession(configuration: Self.configuration(limit: limit))
                defer { session.invalidateAndCancel() }
                do {
                    return try await session.data(for: request, delegate: RedirectRefuser())
                } catch is CancellationError {
                    throw AmbientRefusal.timeout
                } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
                    throw AmbientRefusal.timeout
                } catch {
                    throw AmbientRefusal.unreadable
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                throw AmbientRefusal.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AmbientRefusal.timeout }
            return first
        }
        guard let http = response as? HTTPURLResponse else { throw AmbientRefusal.malformed }
        if (300..<400).contains(http.statusCode) { throw AmbientRefusal.redirect }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw http.statusCode == 200 ? AmbientRefusal.malformed : AmbientRefusal.http(http.statusCode)
        }
        if let error = envelope.error { throw AmbientRefusal.rpc(error.code) }
        guard http.statusCode == 200 else { throw AmbientRefusal.http(http.statusCode) }
        // Exactly one entry, for the address that was read.
        guard let contents = envelope.result?.contents, contents.count == 1, contents[0].uri == uri,
              let text = contents[0].text, let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        else { throw AmbientRefusal.malformed }
        return answer
    }

    static func configuration(limit: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        // A loopback address never goes through a proxy.
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    private struct Envelope: Decodable {
        struct Result: Decodable {
            struct Content: Decodable {
                var uri: String
                var text: String?
            }
            var contents: [Content]
        }
        struct Failure: Decodable {
            var code: Int
        }
        var result: Result?
        var error: Failure?
    }
}

// MARK: - Watching

// What a watch says. `acknowledged` once, when the provider has agreed to
// say when `current` changes; `changed` each time it does. Neither carries
// anything from the app: the new state is learned by reading `current`
// again, through every check a read has.
public enum AmbientWatchEvent: Equatable, Sendable {
    case acknowledged
    case changed
}

extension AmbientClient {
    // The request id of a watch, which its notices name.
    static let watchID = 2
    static let updatedMethod = "notifications/resources/updated"
    static let acknowledgedMethod = "notifications/subscriptions/acknowledged"
    // The longest line of the stream that is read. A notice is a few
    // hundred bytes; a provider that sends more is not being watched.
    static let maxWatchLine = 16 * 1024

    // Whether a provider in this version of the protocol may offer a
    // watch: 0.2.2 and later (RFC-0006). One that does not is never asked.
    public static func offersWatch(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard AmbientDescriptor.supports(version), let patch = UInt(parts[2]) else { return false }
        return patch >= 2
    }

    // The watch request as it goes on the wire: MCP's `subscriptions/listen`
    // for `current` alone, to the same endpoint with the same token as a
    // read, answered by an event stream on that response.
    func watchRequest(quiet: TimeInterval) -> URLRequest {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = quiet
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(provider.descriptor.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.mcpVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("subscriptions/listen", forHTTPHeaderField: "Mcp-Method")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Self.watchID,
            "method": "subscriptions/listen",
            "params": [
                "notifications": ["resourceSubscriptions": [Self.currentURI]],
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": Self.mcpVersion,
                    "io.modelcontextprotocol/clientCapabilities": [String: Any](),
                ] as [String: Any],
            ] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // Asks the provider to say when its answer to `current` changes, and
    // gives each thing it says until the watch is over. It is over when
    // the caller stops listening, when the provider ends it or quits, when
    // the connection is lost, when the provider refuses or does not offer
    // it, when it has not acknowledged within `acknowledgeWithin`, when
    // the stream has been silent for `quiet` (a provider keeps a quiet
    // watch alive every 15 s), or when it sends anything a watch on
    // `current` should not. None of these is an error to anyone: the
    // stream simply finishes.
    public func watch(acknowledgeWithin: TimeInterval = 2, quiet: TimeInterval = 40) -> AsyncStream<AmbientWatchEvent> {
        let request = watchRequest(quiet: quiet)
        return AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                let configuration = Self.configuration(limit: quiet)
                // The watch lasts as long as the composer is open.
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                // The deadline runs from the request, not from the
                // response: a response with no body yet may not be
                // handed over until its first bytes arrive.
                let acknowledged = WatchFlag()
                let deadline = Task {
                    try? await Task.sleep(nanoseconds: UInt64(acknowledgeWithin * 1_000_000_000))
                    if !Task.isCancelled, !acknowledged.isSet { session.invalidateAndCancel() }
                }
                defer { deadline.cancel() }
                guard let (bytes, response) = try? await session.bytes(for: request, delegate: RedirectRefuser()),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/event-stream")
                else { return }

                // Server-sent events, read a byte at a time: lines end in
                // LF or CRLF, an empty line ends an event, a line starting
                // with a colon is a comment (the keep-alive).
                var line: [UInt8] = []
                var data: [String] = []
                do {
                    for try await byte in bytes {
                        if byte != 0x0A {
                            guard line.count < Self.maxWatchLine else { return }
                            line.append(byte)
                            continue
                        }
                        if line.last == 0x0D { line.removeLast() }
                        let text = String(decoding: line, as: UTF8.self)
                        line.removeAll(keepingCapacity: true)
                        if !text.isEmpty {
                            if text.hasPrefix("data:") {
                                let value = text.dropFirst(5)
                                data.append(String(value.first == " " ? value.dropFirst() : value))
                            }
                            continue
                        }
                        guard !data.isEmpty else { continue }
                        let event = data.joined(separator: "\n")
                        data.removeAll()
                        switch Self.watchMessage(event) {
                        case .acknowledged:
                            guard !acknowledged.isSet else { continue }
                            acknowledged.set()
                            continuation.yield(.acknowledged)
                        case .changed:
                            // A notice before the acknowledgment is not
                            // the watch that was asked for.
                            guard acknowledged.isSet else { return }
                            continuation.yield(.changed)
                        case .other:
                            continue
                        case .over:
                            return
                        }
                    }
                } catch {
                    return
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum WatchMessage: Equatable { case acknowledged, changed, other, over }

    // What one event of the stream means. A notice counts only for
    // `current` and only for this watch; the request's own result or error
    // is the provider ending it; a notice for anything else ends it too,
    // since a provider never sends what was not asked for.
    static func watchMessage(_ event: String) -> WatchMessage {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any] else {
            return .over
        }
        if json["result"] != nil || json["error"] != nil { return .over }
        guard let method = json["method"] as? String else { return .other }
        let params = json["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        if let id = meta?["io.modelcontextprotocol/subscriptionId"], (id as? Int) != watchID { return .over }
        switch method {
        case acknowledgedMethod:
            return .acknowledged
        case updatedMethod:
            return params?["uri"] as? String == currentURI ? .changed : .over
        default:
            return method.hasPrefix("notifications/") ? .over : .other
        }
    }
}

private final class WatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// One read at a time, however many reasons there are to read: a notice
// that arrives while a read is out is remembered, and one more read is
// made when that read ends. Ten notices during one read make one more
// read, not ten.
public struct AmbientRereads: Equatable, Sendable {
    private var reading = false
    private var again = false

    public init() {}

    // A reason to read. True when the caller should start a read now.
    public mutating func notice() -> Bool {
        if reading {
            again = true
            return false
        }
        reading = true
        return true
    }

    // A read ended. True when the caller should read once more.
    public mutating func finished() -> Bool {
        if again {
            again = false
            return true
        }
        reading = false
        return false
    }

    // Nothing is wanted any more: the composer closed, sent or lost its
    // context.
    public mutating func reset() {
        reading = false
        again = false
    }
}

// A redirect is handed back as the response it is, never followed: the
// token goes to the checked endpoint and nowhere else.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - The one call the rest of Sirius uses

public struct AmbientContextSource: Sendable {
    public var check: AmbientProviderCheck
    public var limit: TimeInterval

    public init(check: AmbientProviderCheck = AmbientProviderCheck(), limit: TimeInterval = 0.25) {
        self.check = check
        self.limit = limit
    }

    // What the app in front has open and selected, or nil. Called when the
    // user invokes an agent, with the process that was in front at that
    // moment. Only that process's descriptor is read and only it is asked;
    // when it has none, only the helpers it started.
    public func context(frontPID pid: Int32, bundleID: String) async -> AmbientSnapshot? {
        try? await snapshot(frontPID: pid, bundleID: bundleID)
    }

    public func snapshot(frontPID pid: Int32, bundleID: String) async throws -> AmbientSnapshot {
        let provider: AmbientProvider
        switch check.provider(pid: pid, bundleID: bundleID) {
        case .success(let own): provider = own
        // An app with a descriptor of its own that is refused has no
        // context: a helper is never a way around a refusal.
        case .failure(.noDescriptor): return try await delegated(frontPID: pid, bundleID: bundleID)
        case .failure(let refusal): throw refusal
        }
        let tree = try await AmbientClient(provider: provider, limit: limit).current()
        return AmbientSnapshot(provider: provider, tree: tree)
    }

    // What the helpers the front app started say. One is simply read. An
    // app may start several, each seeing part of it, so all are asked at
    // once, within the one limit, and the first by name that says where
    // the user is wins; failing that, the first that answered at all.
    private func delegated(frontPID pid: Int32, bundleID: String) async throws -> AmbientSnapshot {
        let checked = check.delegates(pid: pid, bundleID: bundleID)
        let providers = checked.compactMap { try? $0.get() }
        guard !providers.isEmpty else {
            // The first refusal, or none of them: no file at all.
            for case .failure(let refusal) in checked { throw refusal }
            throw AmbientRefusal.noDescriptor
        }
        let limit = limit
        let answers = await withTaskGroup(of: (Int, Result<AmbientTree, Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await AmbientClient(provider: provider, limit: limit).current()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var answers = [Result<AmbientTree, Error>?](repeating: nil, count: providers.count)
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
        var snapshots: [AmbientSnapshot] = []
        for (provider, answer) in zip(providers, answers) {
            if case .success(let tree)? = answer {
                snapshots.append(AmbientSnapshot(provider: provider, tree: tree))
            }
        }
        if let pointed = snapshots.first(where: { !$0.tree.focusPath.isEmpty }) { return pointed }
        if let first = snapshots.first { return first }
        for case .failure(let error)? in answers { throw error }
        throw AmbientRefusal.timeout
    }

    // Where an item is, asked of the provider and run that issued it. If
    // that provider has quit or restarted the item is gone: nil.
    public func locate(_ ref: AmbientItemRef) async -> AmbientLocation? {
        try? await location(of: ref)
    }

    public func location(of ref: AmbientItemRef) async throws -> AmbientLocation {
        let provider: AmbientProvider
        if let target = ref.answersFor {
            // A helper's item: the same helper, still the app's own.
            provider = try check.delegate(pid: target.pid, bundleID: target.id, helper: ref.pid).get()
            guard provider.descriptor.app.id == ref.bundleID else { throw AmbientRefusal.providerChanged }
        } else {
            provider = try check.provider(pid: ref.pid, bundleID: ref.bundleID).get()
        }
        guard provider.descriptor.instance == ref.instance else { throw AmbientRefusal.providerChanged }
        return try await AmbientClient(provider: provider, limit: limit).locate(ref.id)
    }
}

// MARK: - What the composer holds

// The context one opening of the composer has collected. The read is
// started when the composer opens and may land any time after; an answer
// is kept only if it belongs to the opening still on screen and the user
// has not removed or sent it. Removed means removed: a late answer never
// comes back.
public struct AmbientAttachment: Sendable {
    public private(set) var snapshot: AmbientSnapshot?
    private var generation = 0
    private var waiting = false

    public init() {}

    // A new opening: what was held goes, and the ticket names this read.
    public mutating func begin() -> Int {
        generation += 1
        snapshot = nil
        waiting = true
        return generation
    }

    // The read's answer. False when it is no longer wanted.
    @discardableResult
    public mutating func accept(_ answer: AmbientSnapshot?, ticket: Int) -> Bool {
        guard waiting, ticket == generation else { return false }
        waiting = false
        snapshot = answer
        return answer != nil
    }

    // Names the opening a later read belongs to (replace).
    public var ticket: Int { generation }

    // A later read of the same app, made when the user comes back to the
    // composer: it takes the place of what is held. False when the opening
    // read is still out, or the composer has closed, sent, reopened or had
    // its context removed since `ticket`.
    @discardableResult
    public mutating func replace(_ answer: AmbientSnapshot, ticket: Int) -> Bool {
        guard !waiting, ticket == generation else { return false }
        snapshot = answer
        return true
    }

    // The user removed the context, sent the message or closed the composer.
    public mutating func clear() {
        generation += 1
        snapshot = nil
        waiting = false
    }
}

// MARK: - Reading again at send

// What a send carries. The composer reads the app behind it when it opens,
// and the user may then click into that app and select something before
// sending (issue 0010), so the same app is read again as the message goes.
// That read answers or it does not: when it fails, finds no provider, or
// has not answered within `limit`, the copy from the opening goes instead.
// `read` nil means there is nothing to read again (context off, removed by
// the user, or no app behind), and the held copy goes at once.
public enum AmbientSendRead {
    // Reads take about 20 ms; the client's own limit is 0.25 s.
    public static let limit: Duration = .milliseconds(300)

    public static func resolve(
        held: AmbientSnapshot?, limit: Duration = limit,
        read: (@Sendable () async -> AmbientSnapshot?)?
    ) async -> AmbientSnapshot? {
        guard let read else { return held }
        let fresh: AmbientSnapshot? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let reader = Task { once.resume(await read()) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
                reader.cancel()
            }
        }
        return fresh ?? held
    }

    // The first of the read and the timer resumes; the other is ignored.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AmbientSnapshot?, Never>?

        init(_ continuation: CheckedContinuation<AmbientSnapshot?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: AmbientSnapshot?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }
}
