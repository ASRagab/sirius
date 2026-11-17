import Foundation
import SiriusProtocol
import XCTest
@testable import SiriusAdapters

final class JSONRPCStdioTests: XCTestCase {
    // A child that writes more than a pipe holds before it reads anything,
    // then answers each line it reads with "ok" for request 1, the only one
    // the test sends. It does not look for the id in the line: the keys of a
    // frame come in no fixed order, so the id can sit after a long payload.
    private static let floodThenAnswer = #"""
    pad=$(printf '%01000d' 0)
    i=0
    while [ $i -lt 400 ]; do
      printf '{"jsonrpc":"2.0","method":"noise","params":"%s"}\n' "$pad"
      i=$((i+1))
    done
    while IFS= read -r line; do
      printf '{"jsonrpc":"2.0","id":1,"result":"ok"}\n'
    done
    """#

    // A write the child is not reading yet must not stop Sirius reading what
    // the child writes, or each waits on the other for good.
    func testAWriteTheChildIsNotReadingDoesNotStopTheReader() async throws {
        let stdio = JSONRPCStdio(name: "child", executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", Self.floodThenAnswer], environment: [:],
                                 directory: FileManager.default.temporaryDirectory)
        // The reader waits in the first notification until the write below
        // has filled the child's stdin.
        let gate = DispatchSemaphore(value: 0)
        let first = Once()
        var handlers = JSONRPCStdio.Handlers()
        handlers.notification = { _, _ in
            if first.take() { gate.wait() }
        }
        stdio.setHandlers(handlers)
        try stdio.launch()
        let pid = stdio.processIdentifier

        // Larger than the pipe, so the write blocks until the child reads.
        let big = JSONValue.string(String(repeating: "x", count: 1_000_000))
        let reply = Task { try await stdio.request("big", big) }
        try await Task.sleep(nanoseconds: 300_000_000)
        gate.signal()

        let watchdog = Task {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            // Ends a deadlock so the test fails instead of hanging.
            kill(pid, SIGKILL)
        }
        let result = try await reply.value
        watchdog.cancel()
        XCTAssertEqual(result, .string("ok"))
        await stdio.terminate()
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
