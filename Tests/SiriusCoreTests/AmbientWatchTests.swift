import Foundation
import XCTest
@testable import SiriusCore

// A watch on a provider's `current` (protocol 0.2.2, RFC-0006): the host
// holds one request open and the provider says "changed" on it.
final class AmbientWatchTests: XCTestCase {
    private var fake: AmbientFakeProvider!

    override func setUpWithError() throws {
        fake = try AmbientFakeProvider()
        fake.treeVersion = "0.2.2"
        fake.offersWatch = true
    }

    override func tearDown() {
        fake.stop()
        fake = nil
    }

    private var client: AmbientClient {
        let descriptor = AmbientDescriptor(
            protocol: fake.treeVersion, app: .init(id: fake.bundleID, name: fake.name, version: "1.0"), pid: getpid(),
            instance: fake.instance, endpoint: fake.endpoint, token: fake.token, started: nil
        )
        return AmbientClient(provider: AmbientProvider(descriptor: descriptor, endpoint: URL(string: fake.endpoint)!))
    }

    // Collects what a watch says until it is over or `count` events came.
    private func events(
        _ count: Int = .max, acknowledgeWithin: TimeInterval = 2, quiet: TimeInterval = 40,
        then act: @escaping @Sendable (AmbientWatchEvent, Int) -> Void = { _, _ in }
    ) async -> [AmbientWatchEvent] {
        var seen: [AmbientWatchEvent] = []
        for await event in client.watch(acknowledgeWithin: acknowledgeWithin, quiet: quiet) {
            seen.append(event)
            act(event, seen.count)
            if seen.count >= count { break }
        }
        return seen
    }

    private func waitForNoWatches() async {
        for _ in 0..<200 where fake.watchCount > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Which providers are asked

    func testOnlyAProviderFrom022IsAsked() {
        XCTAssertTrue(AmbientClient.offersWatch("0.2.2"))
        XCTAssertTrue(AmbientClient.offersWatch("0.2.10"))
        XCTAssertFalse(AmbientClient.offersWatch("0.2.1"))
        XCTAssertFalse(AmbientClient.offersWatch("0.2.0"))
        XCTAssertFalse(AmbientClient.offersWatch("0.3.2"))
        XCTAssertFalse(AmbientClient.offersWatch("0.2"))
        XCTAssertFalse(AmbientClient.offersWatch("nonsense"))
    }

    // MARK: The request

    func testTheRequestIsListenForCurrentAloneWithTheReadsToken() throws {
        let request = client.watchRequest(quiet: 40)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Method"), "subscriptions/listen")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["method"] as? String, "subscriptions/listen")
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        let notifications = try XCTUnwrap(params["notifications"] as? [String: Any])
        XCTAssertEqual(notifications["resourceSubscriptions"] as? [String], ["ambient://current"])
        XCTAssertEqual(notifications.count, 1)
    }

    // MARK: What a watch says

    func testAWatchIsAcknowledgedThenSaysChangedForEachNotice() async {
        let fake = fake!
        let seen = await events(3) { event, count in
            // Each notice is sent only after the one before arrived.
            if count < 3 { fake.notify() }
        }
        XCTAssertEqual(seen, [.acknowledged, .changed, .changed])
        XCTAssertEqual(fake.requests.last?.rpcMethod, "subscriptions/listen")
        XCTAssertEqual(fake.requests.last?.headers["authorization"], "Bearer fake-token")
    }

    func testTheKeepAliveSaysNothing() async {
        let fake = fake!
        let seen = await events(2) { _, count in
            if count == 1 {
                fake.comment()
                fake.notify()
            }
        }
        XCTAssertEqual(seen, [.acknowledged, .changed])
    }

    // No longer listening is the end of the watch for the provider too.
    func testStoppingTheWatchClosesTheStream() async {
        let seen = await events(1)
        XCTAssertEqual(seen, [.acknowledged])
        await waitForNoWatches()
        XCTAssertEqual(fake.watchCount, 0)
    }

    // MARK: How a watch ends

    func testAProviderEndingTheWatchFinishesIt() async {
        let fake = fake!
        let seen = await events { _, count in
            if count == 1 { fake.endWatches(gracefully: true) }
        }
        XCTAssertEqual(seen, [.acknowledged])
    }

    func testALostConnectionFinishesIt() async {
        let fake = fake!
        let seen = await events { _, count in
            if count == 1 { fake.endWatches() }
        }
        XCTAssertEqual(seen, [.acknowledged])
    }

    func testAProviderWithoutAWatchSaysNothing() async {
        fake.offersWatch = false
        let seen = await events()
        XCTAssertEqual(seen, [])
    }

    func testAWatchThatIsNeverAcknowledgedIsGivenUp() async {
        fake.acknowledgesWatch = false
        let started = Date()
        let seen = await events(acknowledgeWithin: 0.2)
        XCTAssertEqual(seen, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAWrongTokenIsRefusedBeforeAnyStream() async {
        let descriptor = AmbientDescriptor(
            protocol: "0.2.2", app: .init(id: fake.bundleID, name: fake.name, version: "1.0"), pid: getpid(),
            instance: fake.instance, endpoint: fake.endpoint, token: "wrong", started: nil
        )
        let other = AmbientClient(provider: AmbientProvider(descriptor: descriptor, endpoint: URL(string: fake.endpoint)!))
        var seen: [AmbientWatchEvent] = []
        for await event in other.watch() { seen.append(event) }
        XCTAssertEqual(seen, [])
        XCTAssertEqual(fake.watchCount, 0)
    }

    // A provider never sends what was not asked for: a notice for another
    // address ends the watch.
    func testANoticeForAnotherAddressEndsTheWatch() async {
        let fake = fake!
        let seen = await events { _, count in
            if count == 1 { fake.notify(uri: "ambient://location/sel-1") }
        }
        XCTAssertEqual(seen, [.acknowledged])
    }

    // MARK: Reading one event

    func testWhatAnEventMeans() {
        func notice(_ method: String, uri: String? = "ambient://current", id: Any? = 2) -> String {
            var params: [String: Any] = [:]
            if let uri { params["uri"] = uri }
            if let id { params["_meta"] = ["io.modelcontextprotocol/subscriptionId": id] }
            let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])
            return String(data: data, encoding: .utf8)!
        }
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/subscriptions/acknowledged", uri: nil)), .acknowledged)
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/resources/updated")), .changed)
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/resources/updated", id: nil)), .changed)
        // Another watch's notice, another address, another kind of notice.
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/resources/updated", id: 9)), .over)
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/resources/updated", uri: "file:///etc/passwd")), .over)
        XCTAssertEqual(AmbientClient.watchMessage(notice("notifications/resources/list_changed", uri: nil)), .over)
        // The request's own result or error is the provider ending it.
        XCTAssertEqual(AmbientClient.watchMessage(#"{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}"#), .over)
        XCTAssertEqual(AmbientClient.watchMessage(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603}}"#), .over)
        XCTAssertEqual(AmbientClient.watchMessage("not json"), .over)
    }

    // MARK: One read at a time

    func testNoticesDuringAReadMakeOneMoreRead() {
        var rereads = AmbientRereads()
        XCTAssertTrue(rereads.notice())   // read now
        XCTAssertFalse(rereads.notice())  // a read is out
        XCTAssertFalse(rereads.notice())
        XCTAssertTrue(rereads.finished()) // once more, for all of them
        XCTAssertFalse(rereads.finished())
        XCTAssertTrue(rereads.notice())   // quiet again: the next notice reads
    }

    func testAResetForgetsWhatWasWanted() {
        var rereads = AmbientRereads()
        _ = rereads.notice()
        _ = rereads.notice()
        rereads.reset()
        XCTAssertFalse(rereads.finished())
        XCTAssertTrue(rereads.notice())
    }
}
