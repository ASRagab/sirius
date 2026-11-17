import Foundation
import Network
@testable import SiriusCore

// An Ambient Context provider with no app behind it, for testing a host.
// It listens on the loopback interface, answers the MCP requests a provider
// must, and can be scripted to misbehave: answer late, answer as another
// run, redirect, or serve whatever a test hands it.
final class AmbientFakeProvider: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String] // names lowercased
        var body: Data

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var rpcMethod: String? { json?["method"] as? String }
        var params: [String: Any]? { json?["params"] as? [String: Any] }
        var uri: String? { params?["uri"] as? String }
    }

    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        var delay: TimeInterval = 0

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    let token: String
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ambient.fake.provider")
    private let lock = NSLock()
    private var received: [Request] = []
    private var script: (@Sendable (Request) -> Reply?)?

    // What the provider answers when no script overrides it.
    var bundleID = "org.example.editor"
    var name = "Editor"
    var instance = "run-1"
    // The tree it answers with: a document in focus and words selected in
    // it.
    var root: [String: Any] = [
        "id": "app", "role": "Application", "title": "Editor",
        "children": [
            ["id": "w-1", "role": "Window", "focused": true, "children": [
                ["id": "doc-1", "role": "Document", "title": "draft.md", "url": "file:///tmp/draft.md",
                 "focused": true, "children": [
                     ["id": "sel-1", "role": "Text", "title": "Selection in draft.md", "selected": true,
                      "focused": true, "content": [["type": "text", "text": "thirty years"]],
                      "attributes": ["lines": ["start": 5, "end": 5]]] as [String: Any],
                 ]] as [String: Any],
            ]] as [String: Any],
        ],
    ]
    // The version the answer names. The descriptor is written with it
    // unless a test overrides it.
    var treeVersion = "0.2.0"
    var locations: [String: [String: Any]] = [
        "sel-1": [
            "id": "sel-1", "state": "visible", "rects": [["x": 425, "y": 233, "w": 480, "h": 20]],
            "window": 48211, "edge": "right",
        ],
    ]

    init(token: String = "fake-token") throws {
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    // Replaces the provider's own answer for the requests it returns a
    // reply for; nil falls through to the normal answer.
    func respond(_ script: (@Sendable (Request) -> Reply?)?) {
        lock.lock(); defer { lock.unlock() }
        self.script = script
    }

    // The descriptor a real provider would write, in `directory`, with the
    // permissions the protocol asks for. Fields can be overridden to lie.
    // With `answersFor` it is a helper's: `pid` is the helper, the file is
    // named for the app answered for, and `fileName` can name it wrongly.
    @discardableResult
    func writeDescriptor(
        in directory: URL, pid: Int32 = getpid(), bundleID: String? = nil, instance: String? = nil,
        endpoint: String? = nil, protocolVersion: String? = nil, fileMode: Int = 0o600, folderMode: Int = 0o700,
        answersFor: (id: String, pid: Int32)? = nil, fileName: String? = nil
    ) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: folderMode], ofItemAtPath: directory.path)
        let id = bundleID ?? self.bundleID
        var descriptor: [String: Any] = [
            "protocol": protocolVersion ?? treeVersion,
            "app": ["id": id, "name": name, "version": "1.0"],
            "pid": Int(pid),
            "instance": instance ?? self.instance,
            "endpoint": endpoint ?? self.endpoint,
            "token": token,
            "started": "2026-11-10T08:00:00Z",
        ]
        var name = AmbientDescriptor.fileName(bundleID: id, pid: pid)
        if let answersFor {
            descriptor["for"] = ["id": answersFor.id, "pid": Int(answersFor.pid)]
            name = AmbientDescriptor.fileName(bundleID: answersFor.id, pid: answersFor.pid, helper: pid)
        }
        let url = directory.appendingPathComponent(fileName ?? name)
        try JSONSerialization.data(withJSONObject: descriptor).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: fileMode], ofItemAtPath: url.path)
        return url
    }

    // MARK: Answers

    private func answer(_ request: Request) -> Reply {
        lock.lock()
        received.append(request)
        let script = script
        lock.unlock()
        if let reply = script?(request) { return reply }

        if request.headers["origin"] != nil { return Reply(status: 403) }
        guard request.headers["authorization"] == "Bearer \(token)" else { return Reply(status: 401) }
        guard request.path == "/mcp" else { return Reply(status: 404) }
        guard request.method == "POST" else { return Reply(status: 405) }
        guard let json = request.json, let method = request.rpcMethod else {
            return .json(Self.failure(nil, -32700, "Parse error"), status: 400)
        }
        let id = json["id"]

        // The older handshake, for clients that have not moved to
        // per-request metadata.
        if method == "initialize" {
            return .json(Self.success(id, [
                "protocolVersion": "2025-11-25",
                "capabilities": [
                    "resources": [String: Any](),
                    "experimental": ["io.github.ambientcontextprotocol/context": ["version": treeVersion]],
                ],
                "serverInfo": ["name": name, "version": "1.0"],
            ]))
        }
        let meta = request.params?["_meta"] as? [String: Any]
        guard meta?["io.modelcontextprotocol/protocolVersion"] != nil,
              meta?["io.modelcontextprotocol/clientCapabilities"] != nil
        else { return .json(Self.failure(id, -32602, "Missing request metadata"), status: 400) }
        guard request.headers["mcp-method"] == method else {
            return .json(Self.failure(id, -32020, "Header does not match the body"), status: 400)
        }

        switch method {
        case "server/discover":
            return .json(Self.success(id, [
                "resultType": "complete",
                "supportedVersions": ["2026-07-28"],
                "capabilities": [
                    "resources": [String: Any](),
                    "extensions": ["io.github.ambientcontextprotocol/context": ["version": treeVersion]],
                ],
            ]))
        case "resources/list":
            return .json(Self.success(id, [
                "resultType": "complete",
                "resources": [["uri": "ambient://current", "name": "current", "mimeType": "application/json"]],
            ]))
        case "resources/templates/list":
            return .json(Self.success(id, [
                "resultType": "complete",
                "resourceTemplates": [[
                    "uriTemplate": "ambient://location/{id}", "name": "location", "mimeType": "application/json",
                ]],
            ]))
        case "resources/read":
            guard let uri = request.uri else { return .json(Self.failure(id, -32602, "No uri"), status: 400) }
            if uri == "ambient://current" { return .json(Self.read(id, uri, current())) }
            let prefix = "ambient://location/"
            if uri.hasPrefix(prefix), let location = locations[String(uri.dropFirst(prefix.count))] {
                return .json(Self.read(id, uri, location))
            }
            return .json(Self.failure(id, -32602, "Resource not found"))
        default:
            return .json(Self.failure(id, -32601, "Method not found"), status: 404)
        }
    }

    func current() -> [String: Any] {
        ["protocol": treeVersion, "instance": instance, "root": root]
    }

    static func read(_ id: Any?, _ uri: String, _ answer: [String: Any]) -> [String: Any] {
        let text = String(data: (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(), encoding: .utf8) ?? ""
        return success(id, [
            "resultType": "complete",
            "contents": [["uri": uri, "mimeType": "application/json", "text": text]],
        ])
    }

    static func success(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func failure(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, finished, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let reply = self.answer(request)
                self.queue.asyncAfter(deadline: .now() + reply.delay) { Self.send(reply, on: connection) }
            } else if finished || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<split.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func send(_ reply: Reply, on connection: NWConnection) {
        var head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Status")\r\n"
        var headers = reply.headers
        headers["Content-Length"] = String(reply.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
