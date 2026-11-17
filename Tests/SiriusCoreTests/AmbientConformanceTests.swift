import Foundation
import XCTest
@testable import SiriusCore

// The host's reader and watch against the protocol repository's own fake
// provider (tools/conformance/fake_provider.py), which is not part of this
// package. Skipped unless SIRIUS_ACP_DESCRIPTORS names the folder that
// provider was started with:
//
//   python3 tools/conformance/fake_provider.py --directory /tmp/acp/providers --change-every 1
//   SIRIUS_ACP_DESCRIPTORS=/tmp/acp/providers swift test --filter AmbientConformanceTests
//
// SIRIUS_ACP_EXPECT says what that provider was told to do: `watch` (the
// default: notices arrive), `none` (it offers no watch, or never
// acknowledges, or breaks the rules: the watch says nothing or ends after
// its acknowledgment without a notice).
final class AmbientConformanceTests: XCTestCase {
    private func client() throws -> AmbientClient {
        guard let folder = ProcessInfo.processInfo.environment["SIRIUS_ACP_DESCRIPTORS"] else {
            throw XCTSkip("no fake provider: set SIRIUS_ACP_DESCRIPTORS")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let file = try XCTUnwrap(files.first, "no descriptor in \(folder)")
        let descriptor = try JSONDecoder().decode(AmbientDescriptor.self, from: Data(contentsOf: file))
        return AmbientClient(provider: AmbientProvider(descriptor: descriptor, endpoint: try XCTUnwrap(URL(string: descriptor.endpoint))))
    }

    private var expectation: String { ProcessInfo.processInfo.environment["SIRIUS_ACP_EXPECT"] ?? "watch" }

    // Listens for `seconds`, reading `current` on each notice as the
    // composer does.
    private func listen(_ client: AmbientClient, for seconds: TimeInterval) async -> (events: [AmbientWatchEvent], reads: Int) {
        let collected = Task { () -> ([AmbientWatchEvent], Int) in
            var events: [AmbientWatchEvent] = []
            var reads = 0
            for await event in client.watch() {
                events.append(event)
                if event == .changed, (try? await client.current()) != nil { reads += 1 }
            }
            return (events, reads)
        }
        let stop = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            collected.cancel()
        }
        let result = await collected.value
        stop.cancel()
        return result
    }

    func testTheFakeProviderIsReadAndWatched() async throws {
        let client = try client()
        let tree = try await client.current()
        XCTAssertFalse(AmbientSummary(tree, app: client.provider.descriptor.app.name).subject.isEmpty)

        let (events, reads) = await listen(client, for: 5)
        print("conformance: protocol \(client.provider.descriptor.protocol), events \(events), rereads \(reads)")
        switch expectation {
        case "none":
            XCTAssertFalse(events.contains(.changed), "a provider that should not be watched sent a notice that was used")
        default:
            XCTAssertTrue(AmbientClient.offersWatch(client.provider.descriptor.protocol))
            XCTAssertEqual(events.first, .acknowledged)
            XCTAssertGreaterThanOrEqual(events.filter { $0 == .changed }.count, 2)
            XCTAssertEqual(reads, events.filter { $0 == .changed }.count, "every notice was followed by a good read")
        }
    }
}
