import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusCore

// A provider that is not the front app but a helper the front app started.
// With the real operating-system checks this test process is the helper and
// the process that started it stands in for the app in front.
final class AmbientDelegatedTests: XCTestCase {
    private var directory: URL!
    private var fake: AmbientFakeProvider!
    private let me = getpid()
    private let front = getppid()
    private let app = "org.example.browser"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
        fake = try AmbientFakeProvider()
        fake.bundleID = "org.example.browser.helper"
        fake.name = "Helper"
        fake.root = Self.page(focused: true)
    }

    override func tearDownWithError() throws {
        fake.stop()
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func source(_ system: AmbientSystem = .live, limit: TimeInterval = 2) -> AmbientContextSource {
        AmbientContextSource(check: AmbientProviderCheck(directory: directory, system: system), limit: limit)
    }

    private func refusal(_ source: AmbientContextSource? = nil, front pid: Int32? = nil) async -> AmbientRefusal? {
        do {
            _ = try await (source ?? self.source()).snapshot(frontPID: pid ?? front, bundleID: app)
            return nil
        } catch {
            return error as? AmbientRefusal
        }
    }

    static func page(focused: Bool, title: String = "Page") -> [String: Any] {
        [
            "id": "app", "role": "Application", "title": "Browser",
            "children": [
                ["id": "w-1", "role": "Window", "focused": focused, "children": [
                    ["id": "p-1", "role": "Page", "title": title, "selected": focused] as [String: Any],
                ]] as [String: Any],
            ],
        ]
    }

    // Process ids a test makes up, each with the port it listens on and
    // the process that started it.
    private func system(_ helpers: [Int32: (port: UInt16, parent: Int32)], running: Set<Int32> = []) -> AmbientSystem {
        let ports = helpers.mapValues(\.port)
        let parents = helpers.mapValues(\.parent)
        return AmbientSystem(
            isRunning: { ports[$0] != nil || running.contains($0) }, listens: { ports[$0] == $1 },
            parent: { parents[$0] }
        )
    }

    // MARK: Accepted

    func testAHelperTheFrontAppStartedIsRead() async throws {
        let url = try fake.writeDescriptor(in: directory, answersFor: (app, front))
        XCTAssertEqual(url.lastPathComponent, "org.example.browser.\(front).for.\(me).json")

        let snapshot = try await source().snapshot(frontPID: front, bundleID: app)
        XCTAssertEqual(snapshot.provider.descriptor.pid, me)
        XCTAssertEqual(snapshot.provider.descriptor.answersFor, .init(id: app, pid: front))
        XCTAssertEqual(snapshot.helper, me)
        XCTAssertEqual(fake.requests.count, 1)

        // The agent is told about the app, not the helper.
        let context = snapshot.messageContext
        XCTAssertEqual(context.source, app)
        XCTAssertEqual(context.app, "Browser")
        XCTAssertEqual(context.items.map(\.id), ["w-1", "p-1"])
    }

    func testAHelpersItemIsLocatedThroughTheHelper() async throws {
        fake.locations["p-1"] = ["id": "p-1", "state": "visible", "rects": [["x": 10, "y": 20, "w": 30, "h": 40]]]
        try fake.writeDescriptor(in: directory, answersFor: (app, front))
        let anchors = AmbientAnchors()
        let snapshot = try await source().snapshot(frontPID: front, bundleID: app)
        let ref = try XCTUnwrap(snapshot.anchor)
        XCTAssertEqual(ref.bundleID, "org.example.browser.helper")
        XCTAssertEqual(ref.pid, me)
        XCTAssertEqual(ref.answersFor, .init(id: app, pid: front))

        let handle = try XCTUnwrap(snapshot.messageContext(anchors: anchors).items.first { $0.id == "p-1" }?.anchor)
        let location = try await source().location(of: try XCTUnwrap(anchors.resolve(handle)))
        XCTAssertEqual(location.rects, [AmbientRect(x: 10, y: 20, w: 30, h: 40)])

        // The helper restarts: the item is gone, and is not asked about.
        fake.instance = "run-2"
        try fake.writeDescriptor(in: directory, answersFor: (app, front))
        let before = fake.requests.count
        do {
            _ = try await source().location(of: ref)
            XCTFail("a stale id was located")
        } catch {
            XCTAssertEqual(error as? AmbientRefusal, .providerChanged)
        }
        XCTAssertEqual(fake.requests.count, before)
    }

    func testADescriptorWithoutTheFieldDecodesAsBefore() throws {
        let plain = #"{"protocol":"0.2.0","app":{"id":"org.example.editor","name":"Editor"},"pid":7,"instance":"r","endpoint":"http://127.0.0.1:1/mcp","token":"t"}"#
        let descriptor = try JSONDecoder().decode(AmbientDescriptor.self, from: Data(plain.utf8))
        XCTAssertNil(descriptor.answersFor)
        XCTAssertEqual(descriptor.pid, 7)

        let helper = #"{"protocol":"0.2.0","app":{"id":"org.example.helper","name":"Helper"},"pid":9,"for":{"id":"org.example.editor","pid":7},"instance":"r","endpoint":"http://127.0.0.1:1/mcp","token":"t"}"#
        let delegated = try JSONDecoder().decode(AmbientDescriptor.self, from: Data(helper.utf8))
        XCTAssertEqual(delegated.answersFor, .init(id: "org.example.editor", pid: 7))
        XCTAssertEqual(AmbientDescriptor.fileName(bundleID: "org.example.editor", pid: 7, helper: 9), "org.example.editor.7.for.9.json")
    }

    func testTheLiveCheckSeesWhoStartedThisProcess() {
        XCTAssertEqual(AmbientSystem.live.parent(me), front)
    }

    // MARK: Refused

    // The helper says it answers for a process that did not start it.
    func testAHelperSomeOtherProcessStartedIsRefused() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let other = sleeper.processIdentifier

        try fake.writeDescriptor(in: directory, answersFor: (app, other))
        let reason = await refusal(front: other)
        XCTAssertEqual(reason, .notStartedByApp)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // Started by a process the front app started is not started by it.
    func testOnlyTheDirectParentCounts() async throws {
        let system = system([7002: (fake.port, 7001), 7001: (0, 7000)], running: [7000])
        try fake.writeDescriptor(in: directory, pid: 7002, answersFor: (app, 7000))
        let reason = await refusal(source(system), front: 7000)
        XCTAssertEqual(reason, .notStartedByApp)
    }

    func testAHelperAnsweringForAnotherProcessIsRefused() async throws {
        // Named for the front app, but saying another process inside.
        let name = AmbientDescriptor.fileName(bundleID: app, pid: front, helper: me)
        try fake.writeDescriptor(in: directory, answersFor: (app, front + 1), fileName: name)
        let reason = await refusal()
        XCTAssertEqual(reason, .targetMismatch)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testAHelperAnsweringForAnotherAppIsRefused() async throws {
        let name = AmbientDescriptor.fileName(bundleID: app, pid: front, helper: me)
        try fake.writeDescriptor(in: directory, answersFor: ("org.example.other", front), fileName: name)
        var reason = await refusal()
        XCTAssertEqual(reason, .targetMismatch)

        // And one that names no app at all, under a helper's file name.
        try fake.writeDescriptor(in: directory, fileName: name)
        reason = await refusal()
        XCTAssertEqual(reason, .targetMismatch)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testAFileNamedForAnotherHelperThanItDescribesIsRefused() async throws {
        let name = AmbientDescriptor.fileName(bundleID: app, pid: front, helper: me + 1)
        try fake.writeDescriptor(in: directory, answersFor: (app, front), fileName: name)
        var reason = await refusal()
        XCTAssertEqual(reason, .pidMismatch)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))

        // A name whose process id is not one.
        for odd in ["\(app).\(front).for.helper.json", "\(app).\(front).for.0\(me).json"] {
            let url = try fake.writeDescriptor(in: directory, answersFor: (app, front), fileName: odd)
            reason = await refusal()
            XCTAssertEqual(reason, .pidMismatch, odd)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // The front app cannot be its own helper.
    func testAHelperThatIsTheFrontProcessIsRefused() async throws {
        try fake.writeDescriptor(in: directory, answersFor: (app, me))
        let reason = await refusal(front: me)
        XCTAssertEqual(reason, .pidMismatch)
    }

    func testAHelpersFileOrFolderOpenToOthersIsRefused() async throws {
        try fake.writeDescriptor(in: directory, fileMode: 0o644, answersFor: (app, front))
        var reason = await refusal()
        XCTAssertEqual(reason, .unsafeFile)

        try fake.writeDescriptor(in: directory, folderMode: 0o755, answersFor: (app, front))
        reason = await refusal()
        XCTAssertEqual(reason, .unsafeFile)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testAHelperThatIsNotTheListenerIsRefused() async throws {
        let system = system([7001: (fake.port == 1 ? 2 : 1, 7000)])
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))
        var reason = await refusal(source(system), front: 7000)
        XCTAssertEqual(reason, .listenerMismatch)

        // A helper that has exited.
        reason = await refusal(source(self.system([:])), front: 7000)
        XCTAssertEqual(reason, .processGone)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // The first draft of the protocol is not read from a helper either.
    func testAHelperOfTheFirstDraftIsRefused() async throws {
        try fake.writeDescriptor(in: directory, protocolVersion: "0.1", answersFor: (app, front))
        let reason = await refusal()
        XCTAssertEqual(reason, .unsupportedProtocol)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // A helper for some other front process is never opened or asked.
    func testOnlyTheFrontAppsHelpersAreAsked() async throws {
        try fake.writeDescriptor(in: directory, answersFor: (app, front + 1))
        try fake.writeDescriptor(in: directory, answersFor: ("org.example.browser.beta", front))
        let reason = await refusal()
        XCTAssertEqual(reason, .noDescriptor)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    // MARK: The app's own descriptor comes first

    func testTheAppsOwnDescriptorWins() async throws {
        let own = try AmbientFakeProvider(token: "own-token")
        defer { own.stop() }
        own.bundleID = app
        own.root = Self.page(focused: true, title: "Own")
        let system = system([7000: (own.port, 1), 7001: (fake.port, 7000)])
        try own.writeDescriptor(in: directory, pid: 7000)
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))

        let snapshot = try await source(system).snapshot(frontPID: 7000, bundleID: app)
        XCTAssertEqual(snapshot.provider.descriptor.pid, 7000)
        XCTAssertNil(snapshot.helper)
        XCTAssertEqual(own.requests.count, 1)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testARefusedOwnDescriptorDoesNotFallThroughToAHelper() async throws {
        let own = try AmbientFakeProvider()
        defer { own.stop() }
        own.bundleID = app
        // The app's own file is open to others; its helper's is sound.
        let system = system([7000: (own.port, 1), 7001: (fake.port, 7000)])
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))
        let url = try own.writeDescriptor(in: directory, pid: 7000)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        var reason = await refusal(source(system), front: 7000)
        XCTAssertEqual(reason, .unsafeFile)

        // The same for one refused for what it says.
        try own.writeDescriptor(in: directory, pid: 7000, protocolVersion: "9.0")
        reason = await refusal(source(system), front: 7000)
        XCTAssertEqual(reason, .unsupportedProtocol)
        XCTAssertTrue(fake.requests.isEmpty)
        XCTAssertTrue(own.requests.isEmpty)
    }

    // An app's own descriptor cannot say it answers for another app.
    func testTheFieldInAnAppsOwnDescriptorIsIgnored() async throws {
        fake.bundleID = app
        let url = try fake.writeDescriptor(in: directory)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["for"] = ["id": "org.example.bank", "pid": 1]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let snapshot = try await source().snapshot(frontPID: me, bundleID: app)
        XCTAssertNil(snapshot.provider.descriptor.answersFor)
        XCTAssertEqual(snapshot.messageContext.source, app)
    }

    // MARK: Several helpers

    private func second(focused: Bool, title: String) throws -> AmbientFakeProvider {
        let other = try AmbientFakeProvider(token: "second-token")
        other.bundleID = fake.bundleID
        other.instance = "run-b"
        other.root = Self.page(focused: focused, title: title)
        return other
    }

    func testOfTwoHelpersTheOneThatSaysWhereTheUserIsWins() async throws {
        fake.root = Self.page(focused: false, title: "Behind")
        let other = try second(focused: true, title: "In front")
        defer { other.stop() }
        let system = system([7001: (fake.port, 7000), 7002: (other.port, 7000)], running: [7000])
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))
        try other.writeDescriptor(in: directory, pid: 7002, answersFor: (app, 7000))

        let snapshot = try await source(system).snapshot(frontPID: 7000, bundleID: app)
        XCTAssertEqual(snapshot.helper, 7002)
        XCTAssertEqual(snapshot.title, "In front")
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(other.requests.count, 1)
        XCTAssertEqual(other.requests.first?.headers["authorization"], "Bearer second-token")
    }

    func testOfTwoHelpersWithNoFocusTheFirstByNameWins() async throws {
        fake.root = Self.page(focused: false, title: "First")
        let other = try second(focused: false, title: "Second")
        defer { other.stop() }
        let system = system([7001: (fake.port, 7000), 7002: (other.port, 7000)], running: [7000])
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))
        try other.writeDescriptor(in: directory, pid: 7002, answersFor: (app, 7000))

        let snapshot = try await source(system).snapshot(frontPID: 7000, bundleID: app)
        XCTAssertEqual(snapshot.helper, 7001)

        // Both in focus: still the first by name.
        fake.root = Self.page(focused: true, title: "First")
        other.root = Self.page(focused: true, title: "Second")
        let both = try await source(system).snapshot(frontPID: 7000, bundleID: app)
        XCTAssertEqual(both.helper, 7001)
    }

    // A refused or silent helper does not cost the app its other one, and
    // two helpers cost no more time than one.
    func testAHelperThatFailsLeavesTheOther() async throws {
        let other = try second(focused: false, title: "Second")
        defer { other.stop() }
        fake.respond { _ in AmbientFakeProvider.Reply(status: 200, body: Data("{}".utf8), delay: 3) }
        // 7003 is some other process's child with a file of its own.
        let system = system(
            [7001: (fake.port, 7000), 7002: (other.port, 7000), 7003: (other.port, 1)], running: [7000]
        )
        try fake.writeDescriptor(in: directory, pid: 7001, answersFor: (app, 7000))
        try other.writeDescriptor(in: directory, pid: 7002, answersFor: (app, 7000))
        try other.writeDescriptor(in: directory, pid: 7003, answersFor: (app, 7000))

        let started = Date()
        let snapshot = try await source(system, limit: 0.3).snapshot(frontPID: 7000, bundleID: app)
        XCTAssertEqual(snapshot.helper, 7002)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(other.requests.count, 1, "the helper the app did not start is not asked")

        // Both silent: no context, in the time one would take.
        other.respond { _ in AmbientFakeProvider.Reply(status: 200, body: Data("{}".utf8), delay: 3) }
        let again = Date()
        let reason = await refusal(source(system, limit: 0.3), front: 7000)
        XCTAssertEqual(reason, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(again), 1.0)
    }
}
