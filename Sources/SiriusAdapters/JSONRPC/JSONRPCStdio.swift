import Darwin
import Foundation
import SiriusProtocol

// One child process and the JSON-RPC 2.0 over its stdio: one JSON object
// per line, requests from us, responses and notifications from it, and the
// requests it sends us, which `serverRequests` answers. Shared by every
// harness that speaks JSON-RPC over stdio: Codex's app-server, Muse's
// `muse serve`, and ACP agents.
//
// When the process exits or its stdout closes, every pending request fails,
// and so does every wait a harness layer registered through onFailure;
// after terminate() they fail with CancellationError.
final class JSONRPCStdio: @unchecked Sendable {
    // What to send back for a request from the server: a result, or a
    // JSON-RPC error.
    enum Reply: Sendable {
        case result(JSONValue)
        case error(code: Int64, message: String)
    }

    // The handlers a harness layer sets before launch().
    struct Handlers: Sendable {
        // Each notification: its method and params (.null when absent).
        var notification: @Sendable (_ method: String, _ params: JSONValue) -> Void = { _, _ in }
        // Each request from the server, answered with the reply returned.
        // The default refuses everything as method-not-found.
        var serverRequest: @Sendable (_ method: String, _ params: JSONValue) -> Reply = { method, _ in
            .error(code: -32601, message: "Sirius does not handle \(method)")
        }
        // Once, with why the connection is gone, after pending requests
        // have failed.
        var failure: @Sendable (Error) -> Void = { _ in }

        init() {}
    }

    // How errors name the process, e.g. "app-server" or "muse serve", and
    // how a JSON-RPC error names it, e.g. "codex app-server".
    let name: String
    let errorLabel: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    private let lock = NSLock()
    // Held for the whole of one write to the child, which can block until
    // the child reads. The reader never takes it and nothing else is done
    // under it, so a blocked write cannot stop the reading that unblocks it.
    private let writeLock = NSLock()
    // The reader's answers to the child's requests are written here, in
    // order, so the reader does not block on a write either.
    private let answers = DispatchQueue(label: "sirius.jsonrpc.answers")
    private var handlers = Handlers()
    private var nextId: Int64 = 0
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    // Set once: why the connection is gone.
    private var failure: Error?
    private var stopping = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var exited = false
    private var launched = false
    private var stderrTail = Data()
    // The start of stderr, for why it quit as it started.
    private var stderrHead = Data()
    private var stderrClosed = false
    private var observer: (@Sendable (String) -> Void)?

    init(name: String, errorLabel: String? = nil, executable: URL, arguments: [String],
         environment: [String: String], directory: URL) {
        self.name = name
        self.errorLabel = errorLabel ?? name
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var processIdentifier: Int32 { process.processIdentifier }

    // Every line in both directions, prefixed ">> " (sent) or "<< "
    // (received). For tests and diagnostics.
    func observe(_ observer: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.observer = observer }
    }

    // Set before launch(); a notification read before then is dropped.
    func setHandlers(_ handlers: Handlers) {
        lock.withLock { self.handlers = handlers }
    }

    func launch() throws {
        // A write to a dead process must fail with EPIPE, not kill the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] process in
            self?.didExit(status: process.terminationStatus, reason: process.terminationReason)
        }
        try process.run()
        lock.withLock { launched = true }
        let out = stdout.fileHandleForReading.fileDescriptor
        let err = stderr.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in readLines(out) }
        Thread.detachNewThread { [self] in drainStderr(err) }
    }

    // Sends a request and waits for its result. Throws the server's error
    // as JSONRPCStdioError.rpc, or why the connection is gone.
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int64? = lock.withLock {
                if let failure {
                    continuation.resume(throwing: failure)
                    return nil
                }
                nextId += 1
                pending[nextId] = continuation
                return nextId
            }
            guard let id else { return }
            let frame: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string(method), "params": params,
            ])
            if let error = send(frame) {
                lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    // A notification; params are left out when nil.
    func notify(_ method: String, _ params: JSONValue? = nil) throws {
        var frame: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { frame["params"] = params }
        if let error = send(.object(frame)) { throw error }
    }

    // Closes stdin, asks the process to exit, kills it if it has not within
    // `grace`, and returns once it is gone. Pending waits throw
    // CancellationError, before this returns.
    func terminate(grace: TimeInterval = 2) async {
        lock.withLock { stopping = true }
        fail(CancellationError())
        try? stdin.fileHandleForWriting.close()
        guard lock.withLock({ launched && !exited }) else { return }
        process.terminate()
        let pid = process.processIdentifier
        let killer = Task {
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if !Task.isCancelled { kill(pid, SIGKILL) }
        }
        await waitForExit()
        killer.cancel()
    }

    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock {
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    // The first line of stderr, once the process has exited and stderr has
    // been read to its end, waiting up to `seconds` for both: stdout can
    // close before the exit and the last of stderr. Nil when it wrote none.
    func firstStderrLine(within seconds: Double = 0.5) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ exited && stderrClosed }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let head = lock.withLock { String(decoding: stderrHead, as: UTF8.self) }
        return head.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - Writing

    // nil on success.
    private func send(_ frame: JSONValue) -> Error? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(frame) else { return JSONRPCStdioError.closed("unencodable frame") }
        if let observer = lock.withLock({ observer }) {
            observer(">> " + String(decoding: data, as: UTF8.self))
        }
        data.append(0x0A)
        let fd = stdin.fileHandleForWriting.fileDescriptor
        if let failure = lock.withLock({ failure }) { return failure }
        // One writer at a time, so lines never interleave.
        return writeLock.withLock { () -> Error? in
            var offset = 0
            while offset < data.count {
                // terminate() closes stdin once the connection has failed;
                // nothing more is written to that descriptor after.
                if offset > 0, let failure = lock.withLock({ failure }) { return failure }
                let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR { continue }
                    return JSONRPCStdioError.closed("stdin: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
            return nil
        }
    }

    // MARK: - Reading

    private func readLines(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                handle(Data(line))
            }
        }
        // stdout closed: the process cannot answer anything more.
        fail(JSONRPCStdioError.closed("\(name) closed its output\(stderrSuffix())"))
    }

    private func drainStderr(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                lock.withLock { stderrClosed = true }
                return
            }
            lock.withLock {
                if stderrHead.count < 2048 { stderrHead.append(contentsOf: chunk[0..<min(count, 2048)]) }
                stderrTail.append(contentsOf: chunk[0..<count])
                if stderrTail.count > 2048 { stderrTail = stderrTail.suffix(2048) }
            }
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        if let observer = lock.withLock({ observer }) {
            observer("<< " + String(decoding: line, as: UTF8.self))
        }
        guard let message = try? JSONValue.parse(line), message.object != nil else { return }
        let method = message["method"]?.string
        let id = message["id"]
        let params = message["params"] ?? .null
        if let method, let id {
            let reply = lock.withLock { handlers.serverRequest }(method, params)
            answer(id: id, with: reply)
        } else if let method {
            lock.withLock { handlers.notification }(method, params)
        } else if let id = id?.safeInteger {
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: JSONRPCStdioError.rpc(
                    server: errorLabel, code: error["code"]?.safeInteger ?? 0,
                    message: error["message"]?.string ?? "unknown error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    private func answer(id: JSONValue, with reply: Reply) {
        let frame: JSONValue
        switch reply {
        case .result(let result):
            frame = .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        case .error(let code, let message):
            frame = .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                "code": .number(Double(code)), "message": .string(message),
            ])])
        }
        answers.async { [self] in _ = send(frame) }
    }

    // MARK: - Ending

    private func didExit(status: Int32, reason: Process.TerminationReason) {
        let how = reason == .uncaughtSignal ? "was killed by signal \(status)" : "exited with status \(status)"
        fail(JSONRPCStdioError.exited("\(name) \(how)\(stderrSuffix())"))
        let waiters = lock.withLock {
            exited = true
            defer { exitWaiters.removeAll() }
            return exitWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ error: Error) {
        let (requests, first) = lock.withLock { () -> ([CheckedContinuation<JSONValue, Error>], Bool) in
            let first = failure == nil
            if first { failure = stopping ? CancellationError() : error }
            defer { pending.removeAll() }
            return (Array(pending.values), first)
        }
        let reason = lock.withLock { failure ?? error }
        for continuation in requests { continuation.resume(throwing: reason) }
        if first { lock.withLock { handlers.failure }(reason) }
    }

    private func stderrSuffix() -> String {
        let tail = lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = tail.split(separator: "\n").last else { return "" }
        return ": \(last)"
    }
}

enum JSONRPCStdioError: Error, Equatable, CustomStringConvertible {
    // The process answered a request with a JSON-RPC error. `server` is the
    // process's name, for the description.
    case rpc(server: String, code: Int64, message: String)
    // stdout closed or stdin refused a write.
    case closed(String)
    // The process exited.
    case exited(String)

    var description: String {
        switch self {
        case .rpc(let server, let code, let message): return "\(server) error \(code): \(message)"
        case .closed(let reason), .exited(let reason): return reason
        }
    }
}
