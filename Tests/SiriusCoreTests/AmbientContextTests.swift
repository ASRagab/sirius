import Foundation
import XCTest
@testable import SiriusCore

// The host side of the Ambient Context Protocol against a fake provider.
// The V- numbers are the protocol PRD's verifications.
final class AmbientContextTests: XCTestCase {
    private var directory: URL!
    private var fake: AmbientFakeProvider!
    private let me = getpid()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
        fake = try AmbientFakeProvider()
    }

    override func tearDownWithError() throws {
        fake.stop()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // The real operating-system checks: this test process is the listener.
    private func source(limit: TimeInterval = 2) -> AmbientContextSource {
        AmbientContextSource(check: AmbientProviderCheck(directory: directory, system: .live), limit: limit)
    }

    private func refusal(_ work: () async throws -> some Any) async -> AmbientRefusal? {
        do {
            _ = try await work()
            return nil
        } catch {
            return error as? AmbientRefusal
        }
    }

    // MARK: Reading

    func testReadsCurrentAndLocatesTheFocus() async throws {
        try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)

        XCTAssertEqual(snapshot.source, "org.example.editor")
        XCTAssertEqual(snapshot.tree.root.all.map(\.id), ["app", "w-1", "doc-1", "sel-1"])
        XCTAssertEqual(snapshot.tree.selected.first?.text, "thirty years")
        XCTAssertEqual(snapshot.tree.focusPath.map(\.id), ["w-1", "doc-1", "sel-1"])

        let location = try await source().location(of: snapshot.ref("sel-1"))
        XCTAssertTrue(location.isVisible)
        XCTAssertEqual(location.rects, [AmbientRect(x: 425, y: 233, w: 480, h: 20)])
        XCTAssertEqual(location.window, 48211)
        XCTAssertEqual(location.edge, "right")
    }

    func testNoDescriptorMeansNoContext() async {
        let nothing = await source().context(frontPID: me, bundleID: "org.example.editor")
        XCTAssertNil(nothing)
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: "org.example.editor") }
        XCTAssertEqual(reason, .noDescriptor)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // Only the front app's descriptor is opened; a second provider in the
    // folder is never contacted.
    func testOnlyTheFrontAppIsAsked() async throws {
        let other = try AmbientFakeProvider()
        defer { other.stop() }
        other.bundleID = "org.example.tracker"
        try fake.writeDescriptor(in: directory)
        try other.writeDescriptor(in: directory, pid: me + 1)

        _ = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertTrue(other.requests.isEmpty)
    }

    func testOffscreenAndGoneAreNotVisible() async throws {
        fake.locations["sel-1"] = ["id": "sel-1", "state": "offscreen"]
        try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        let location = try await source().location(of: snapshot.ref("sel-1"))
        XCTAssertEqual(location.state, "offscreen")
        XCTAssertFalse(location.isVisible)
    }

    // MARK: V-017 — request metadata

    func testEveryRequestCarriesTheMetadataAndHeadersMCPRequires() async throws {
        try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        _ = try await source().location(of: snapshot.ref("sel-1"))

        XCTAssertEqual(fake.requests.count, 2)
        for (request, uri) in zip(fake.requests, ["ambient://current", "ambient://location/sel-1"]) {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/mcp")
            XCTAssertEqual(request.headers["authorization"], "Bearer fake-token")
            XCTAssertEqual(request.headers["mcp-protocol-version"], "2026-07-28")
            XCTAssertEqual(request.headers["mcp-method"], "resources/read")
            XCTAssertEqual(request.headers["mcp-name"], uri)
            XCTAssertNil(request.headers["origin"])
            XCTAssertNil(request.headers["cookie"])
            XCTAssertEqual(request.rpcMethod, "resources/read")
            XCTAssertEqual(request.uri, uri)
            let meta = request.params?["_meta"] as? [String: Any]
            XCTAssertEqual(meta?["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
            XCTAssertNotNil(meta?["io.modelcontextprotocol/clientCapabilities"] as? [String: Any])
        }
    }

    // MARK: V-015 — a false descriptor

    // A descriptor that names another running process but points at this
    // one's server: the listener is not the process named, so it is refused
    // before any request is sent.
    func testADescriptorPointingAtAnotherProcessesServerIsRefused() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let front = sleeper.processIdentifier

        try fake.writeDescriptor(in: directory, pid: front)
        let reason = await refusal { try await self.source().snapshot(frontPID: front, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .listenerMismatch)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testADescriptorWhoseContentsNameAnotherProcessIsRefused() async throws {
        // Named for this process, but saying pid 1 inside.
        let url = try fake.writeDescriptor(in: directory)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["pid"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .pidMismatch)
    }

    func testADescriptorForAnotherAppsBundleIsNotFound() async throws {
        try fake.writeDescriptor(in: directory, bundleID: "org.example.impostor")
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: "org.example.editor") }
        XCTAssertEqual(reason, .noDescriptor)
    }

    func testAnEndpointThatIsNotLoopbackHTTPIsRefused() async throws {
        for endpoint in [
            "http://localhost:\(fake.port)/mcp", "https://127.0.0.1:\(fake.port)/mcp",
            "http://192.168.1.10:\(fake.port)/mcp", "http://127.0.0.1/mcp",
            "http://user:pass@127.0.0.1:\(fake.port)/mcp", "http://127.0.0.1.example.com:\(fake.port)/mcp",
        ] {
            try fake.writeDescriptor(in: directory, endpoint: endpoint)
            let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
            XCTAssertEqual(reason, .badEndpoint, endpoint)
        }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testAFileOrFolderOpenToOthersIsRefused() async throws {
        try fake.writeDescriptor(in: directory, fileMode: 0o644)
        var reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .unsafeFile)

        try fake.writeDescriptor(in: directory, folderMode: 0o755)
        reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .unsafeFile)
    }

    func testALinkInPlaceOfTheDescriptorIsRefused() async throws {
        let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("elsewhere", isDirectory: true)
        let real = try fake.writeDescriptor(in: elsewhere)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(real.lastPathComponent), withDestinationURL: real
        )
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .unsafeFile)
    }

    func testAProtocolVersionTheHostDoesNotSpeakIsRefused() async throws {
        try fake.writeDescriptor(in: directory, protocolVersion: "9.0")
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .unsupportedProtocol)
    }

    // The first draft of the protocol is no longer read: its provider is
    // refused before any request is sent.
    func testAProviderOfTheFirstDraftIsRefused() async throws {
        try fake.writeDescriptor(in: directory, protocolVersion: "0.1")
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .unsupportedProtocol)
        XCTAssertFalse(AmbientDescriptor.supports("0.1"))
        XCTAssertTrue(AmbientDescriptor.supports("0.2.0"))
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // MARK: V-016 — a stale descriptor

    func testADescriptorForAProcessThatHasExitedIsRefused() async throws {
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let pid = gone.processIdentifier

        try fake.writeDescriptor(in: directory, pid: pid)
        let reason = await refusal { try await self.source().snapshot(frontPID: pid, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .processGone)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // The file is from one run and the answer from another.
    func testAnAnswerFromAnotherRunIsDiscarded() async throws {
        try fake.writeDescriptor(in: directory, instance: "run-0")
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .instanceMismatch)
        let nothing = await source().context(frontPID: me, bundleID: fake.bundleID)
        XCTAssertNil(nothing)
    }

    // MARK: V-014 — stale and colliding ids

    func testAnIdFromBeforeARestartIsGone() async throws {
        try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        let ref = snapshot.ref("sel-1")

        // The provider restarts: same app, same process id as far as the
        // file name goes, a new run, and `sel-1` now means something else.
        fake.instance = "run-2"
        fake.locations["sel-1"] = ["id": "sel-1", "state": "visible", "rects": [["x": 1, "y": 1, "w": 1, "h": 1]]]
        try fake.writeDescriptor(in: directory)
        let before = fake.requests.count

        let reason = await refusal { try await self.source().location(of: ref) }
        XCTAssertEqual(reason, .providerChanged)
        let nothing = await source().locate(ref)
        XCTAssertNil(nothing)
        XCTAssertEqual(fake.requests.count, before, "a stale id must not be asked about at all")
    }

    func testAnIdWhoseProviderHasQuitIsGone() async throws {
        let url = try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        try FileManager.default.removeItem(at: url)
        let reason = await refusal { try await self.source().location(of: snapshot.ref("sel-1")) }
        XCTAssertEqual(reason, .noDescriptor)
    }

    // Two providers both issue `sel-1`. Each id is asked of the provider
    // that issued it and of no other.
    func testTheSameIdFromTwoProvidersStaysSeparate() async throws {
        let tracker = try AmbientFakeProvider(token: "tracker-token")
        defer { tracker.stop() }
        tracker.bundleID = "org.example.tracker"
        tracker.locations["sel-1"] = ["id": "sel-1", "state": "visible", "rects": [["x": 900, "y": 40, "w": 200, "h": 30]]]

        // Two process ids are needed and the test has one, so the
        // operating-system answers are stood in for here.
        let ports: [Int32: UInt16] = [5001: fake.port, 5002: tracker.port]
        let system = AmbientSystem(isRunning: { ports[$0] != nil }, listens: { ports[$0] == $1 })
        let source = AmbientContextSource(check: AmbientProviderCheck(directory: directory, system: system), limit: 2)
        try fake.writeDescriptor(in: directory, pid: 5001)
        try tracker.writeDescriptor(in: directory, pid: 5002)

        let editorRef = try await source.snapshot(frontPID: 5001, bundleID: fake.bundleID).ref("sel-1")
        let trackerRef = try await source.snapshot(frontPID: 5002, bundleID: tracker.bundleID).ref("sel-1")
        XCTAssertNotEqual(editorRef, trackerRef)

        let inEditor = try await source.location(of: editorRef)
        let inTracker = try await source.location(of: trackerRef)
        XCTAssertEqual(inEditor.rects?.first?.x, 425)
        XCTAssertEqual(inTracker.rects?.first?.x, 900)
        XCTAssertEqual(tracker.requests.map(\.headers["authorization"]), ["Bearer tracker-token", "Bearer tracker-token"])
        XCTAssertEqual(fake.requests.count, 2)
    }

    // MARK: V-018 — delayed answers

    func testASlowProviderCostsNoMoreThanTheLimit() async throws {
        fake.respond { _ in AmbientFakeProvider.Reply(status: 200, body: Data("{}".utf8), delay: 3) }
        try fake.writeDescriptor(in: directory)

        let started = Date()
        let reason = await refusal { try await self.source(limit: 0.2).snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(reason, .timeout)
        XCTAssertLessThan(took, 1.0)

        let nothing = await source(limit: 0.2).context(frontPID: me, bundleID: fake.bundleID)
        XCTAssertNil(nothing)
    }

    // MARK: Refusals from the provider

    func testARedirectIsNotFollowed() async throws {
        let elsewhere = try AmbientFakeProvider()
        defer { elsewhere.stop() }
        let target = elsewhere.endpoint
        fake.respond { _ in AmbientFakeProvider.Reply(status: 307, headers: ["Location": target]) }
        try fake.writeDescriptor(in: directory)

        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .redirect)
        XCTAssertTrue(elsewhere.requests.isEmpty, "the token must not reach the redirect's target")
    }

    func testAnIdTheProviderNeverIssuedIsAnError() async throws {
        try fake.writeDescriptor(in: directory)
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        let reason = await refusal { try await self.source().location(of: snapshot.ref("sel-99")) }
        XCTAssertEqual(reason, .rpc(-32602))
    }

    func testAWrongTokenIsRefusedByTheProvider() async throws {
        let impostor = try AmbientFakeProvider(token: "another-token")
        defer { impostor.stop() }
        // The descriptor carries the impostor's token but this fake's port.
        let url = try impostor.writeDescriptor(in: directory, bundleID: fake.bundleID, endpoint: fake.endpoint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .http(401))
    }

    func testAMalformedAnswerIsDiscarded() async throws {
        try fake.writeDescriptor(in: directory)
        fake.respond { request in
            .json(AmbientFakeProvider.success(1, ["contents": [["uri": request.uri ?? "", "text": "not json"]]]))
        }
        var reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .malformed)

        // An answer for an address other than the one read.
        let other = fake.current()
        fake.respond { _ in .json(AmbientFakeProvider.read(1, "ambient://location/sel-1", other)) }
        reason = await refusal { try await self.source().snapshot(frontPID: self.me, bundleID: self.fake.bundleID) }
        XCTAssertEqual(reason, .malformed)
    }

    // MARK: The fake itself

    // The fake answers the older handshake too, so a host that still opens
    // with `initialize` can be run against it.
    func testTheFakeAnswersTheOlderHandshake() async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: fake.endpoint)))
        request.httpMethod = "POST"
        request.setValue("Bearer fake-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    // MARK: Small things

    // An agent's anchor, as the asides use it: the handle back to the item
    // in full, then the provider that issued it asked where it is.
    func testAHandleLeadsBackToWhereTheItemIs() async throws {
        try fake.writeDescriptor(in: directory)
        let anchors = AmbientAnchors()
        let snapshot = try await source().snapshot(frontPID: me, bundleID: fake.bundleID)
        let context = snapshot.messageContext(anchors: anchors)
        let handle = try XCTUnwrap(context.items.first { $0.id == "sel-1" }?.anchor)
        XCTAssertNil(context.items.first { $0.id == "doc-1" }?.anchor)

        let item = try XCTUnwrap(anchors.resolve(handle))
        let location = await source().locate(item)
        XCTAssertEqual(location?.rects, [AmbientRect(x: 425, y: 233, w: 480, h: 20)])

        // The app restarts: the handle still resolves, and the item is gone.
        fake.instance = "run-2"
        try fake.writeDescriptor(in: directory)
        let after = await source().locate(item)
        XCTAssertNil(after)
    }

    func testAnIdIsEscapedInTheLocationAddress() {
        XCTAssertEqual(AmbientClient.locationURI("sel-23"), "ambient://location/sel-23")
        XCTAssertEqual(AmbientClient.locationURI("a/b?c"), "ambient://location/a%2Fb%3Fc")
    }

    func testTheLiveCheckSeesThisProcessListening() {
        XCTAssertTrue(AmbientSystem.live.listens(me, fake.port))
        XCTAssertFalse(AmbientSystem.live.listens(me, fake.port == 1 ? 2 : 1))
        XCTAssertFalse(AmbientSystem.live.listens(1, fake.port))
        XCTAssertTrue(AmbientSystem.live.isRunning(me))
    }

    // MARK: Live, against a real provider

    // Reads a running provider through the real folder and the real checks:
    //   SIRIUS_AMBIENT_LIVE="<pid> <bundle id>" swift test --filter AmbientContextTests/testLive
    func testLiveProvider() async throws {
        guard let spec = ProcessInfo.processInfo.environment["SIRIUS_AMBIENT_LIVE"] else {
            throw XCTSkip("set SIRIUS_AMBIENT_LIVE=\"<pid> <bundle id>\" to read a running provider")
        }
        let parts = spec.split(separator: " ")
        let pid = try XCTUnwrap(Int32(parts[0]))
        let source = AmbientContextSource()
        let snapshot = try await source.snapshot(frontPID: pid, bundleID: String(parts[1]))
        print("LIVE provider \(snapshot.provider.descriptor.app.name) protocol \(snapshot.provider.descriptor.protocol)")
        // The tree's shape, states and sizes, and none of its words.
        func show(_ element: AmbientElement, depth: Int) {
            var line = String(repeating: "  ", count: depth) + element.role
            if let subrole = element.subrole { line += " [\(subrole)]" }
            line += " \(element.id)"
            if element.selected { line += " selected" }
            if element.focused { line += " focused" }
            if element.hovered { line += " hovered" }
            if element.visible == false { line += " not-visible" }
            if let text = element.text { line += " text:\(text.count)" }
            print("LIVE " + line)
            for child in element.children { show(child, depth: depth + 1) }
        }
        show(snapshot.tree.root, depth: 0)
        let context = snapshot.messageContext
        print("LIVE message: \(context.items.count) items, \(context.items.filter { $0.text != nil }.count) with text")
    }
}
