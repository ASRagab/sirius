// The unit the user sends from the composer to one agent. How it is rendered
// for the agent (the <sirius> wrapper, MessageRenderer in SiriusCore) is
// the adapter layer's job.
public struct Message: Equatable, Sendable, Codable {
    // TODO(copy): the id format; "m_" plus a short random id for now.
    public var id: String
    public var agent: String
    // The user's words, verbatim.
    public var text: String
    // Present only on the peer socket path. The name is self-reported.
    public var peerSender: String?
    // Sent by Sirius itself, neither the user nor a peer: a request to
    // clean up working memory (WorkingMemory in SiriusCore).
    public var fromSirius: Bool
    public var attachments: [Attachment]
    // What the app in front had open and selected when the user wrote the
    // message, as the user saw it listed in the composer (the Ambient
    // Context Protocol; AmbientContext in SiriusCore). Absent on most
    // messages. Read from another app, so it is material for the agent,
    // never the user's words and never instructions.
    public var context: Context?

    public struct Context: Equatable, Sendable, Codable {
        // The app's name and bundle identifier.
        public var app: String
        public var source: String
        public var items: [Item]
        // The protocol version the app answered in. Absent for 0.1, whose
        // items are a flat list. From 0.2.0 the items are the app's tree
        // of elements in the app's own order, each naming its `parent`;
        // an item with none sits directly under the app.
        public var version: String?
        // Elements left out because the tree was too large to send.
        public var omitted: Int?

        public struct Item: Equatable, Sendable, Codable {
            // The provider's id, passed through unchanged: the agent names
            // an item by it.
            public var id: String
            public var type: String
            public var title: String
            public var url: String?
            public var parent: String?
            // 1-based first and last line, when the provider gives them.
            public var lines: ClosedRange<Int>?
            public var text: String?
            // One of the items the user was pointing at.
            public var focused: Bool
            // The rest is set only for an element of a tree (0.2.0), where
            // `type` holds the role: how the thing is shown. `subrole` is
            // what it is, in the app's own word.
            public var subrole: String?
            // The user selected this.
            public var selected: Bool?
            // The pointer was resting on this: where the pointer is, which
            // the user may not have meant, and never a reason to send text.
            public var hovered: Bool?
            // False when the element is not drawn on screen now.
            public var visible: Bool?
            // The app's own named values for the element, as text.
            public var attributes: [String: String]?
            // Elements inside this one that were not sent.
            public var inside: Int?
            // The text was cut short.
            public var cut: Bool?

            public init(id: String, type: String, title: String, url: String? = nil, parent: String? = nil,
                        lines: ClosedRange<Int>? = nil, text: String? = nil, focused: Bool = false,
                        subrole: String? = nil, selected: Bool? = nil,
                        hovered: Bool? = nil, visible: Bool? = nil, attributes: [String: String]? = nil,
                        inside: Int? = nil, cut: Bool? = nil) {
                self.id = id
                self.type = type
                self.title = title
                self.url = url
                self.parent = parent
                self.lines = lines
                self.text = text
                self.focused = focused
                self.subrole = subrole
                self.selected = selected
                self.hovered = hovered
                self.visible = visible
                self.attributes = attributes
                self.inside = inside
                self.cut = cut
            }
        }

        public init(app: String, source: String, items: [Item], version: String? = nil, omitted: Int? = nil) {
            self.app = app
            self.source = source
            self.items = items
            self.version = version
            self.omitted = omitted
        }

        // Whether the items are a tree of elements and not 0.1's flat list.
        public var isTree: Bool { version != nil }
    }

    public struct Attachment: Equatable, Sendable, Codable {
        // Absolute path under the agent's attachments/<message>/ folder.
        public var path: String
        public var mimeType: String

        public init(path: String, mimeType: String) {
            self.path = path
            self.mimeType = mimeType
        }
    }

    public init(id: String, agent: String, text: String, attachments: [Attachment] = [], peerSender: String? = nil,
                fromSirius: Bool = false, context: Context? = nil) {
        self.id = id
        self.agent = agent
        self.text = text
        self.peerSender = peerSender
        self.fromSirius = fromSirius
        self.attachments = attachments
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, text, peerSender, fromSirius, attachments, context
    }

    // fromSirius may be absent: false. context may be absent: nil.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decode(String.self, forKey: .agent)
        text = try container.decode(String.self, forKey: .text)
        peerSender = try container.decodeIfPresent(String.self, forKey: .peerSender)
        fromSirius = try container.decodeIfPresent(Bool.self, forKey: .fromSirius) ?? false
        attachments = try container.decode([Attachment].self, forKey: .attachments)
        context = try container.decodeIfPresent(Context.self, forKey: .context)
    }
}
