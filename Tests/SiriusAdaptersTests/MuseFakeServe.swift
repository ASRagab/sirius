import Foundation

// A stand-in for `muse serve`: the MSP subset the adapter uses. It logs its
// argv and environment to fake-muse.args and every line it receives to
// fake-muse.log, both in its working directory (the agent's root). Every
// turn also emits a reminder child session's turn events, as Muse does,
// which the adapter must ignore. The turn's text picks the behaviour:
// FAKE_FAIL ends it failed, FAKE_EXIT exits mid-turn, FAKE_HANG never ends
// it, FAKE_HOLD keeps it running until a turn/steer whose text has
// FAKE_DONE, FAKE_APPROVAL sends approval/request and ends once
// approval/decide comes, FAKE_INPUT sends userInput/request and ends once
// userInput/cancel comes, FAKE_AGENT starts a turn of the agent's own after
// ours. A session/resume of "missing" is refused.
//
// fake-muse.init beside the script changes initialize: "exit" writes to
// stderr and exits 1, "error" answers with a JSON-RPC error, "old" reports
// 1.4.6, "schema2" reports schema version 2.
enum MuseFakeServe {
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys, time

    here = os.path.dirname(os.path.realpath(sys.argv[0]))
    def setting(name):
        try:
            return open(os.path.join(here, name)).read().strip()
        except OSError:
            return None

    cwd = os.getcwd()
    with open(os.path.join(cwd, "fake-muse.args"), "w") as f:
        json.dump({"argv": sys.argv[1:], "socket": os.environ.get("SIRIUS_SOCKET"),
                   "noUpdate": os.environ.get("MUSE_NO_AUTO_UPDATE"),
                   "path": os.environ.get("PATH")}, f)
    log = open(os.path.join(cwd, "fake-muse.log"), "a")

    def send(obj):
        obj["jsonrpc"] = "2.0"
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    SID = "session-new"
    sid = None
    turns = 0
    held = None
    waiting = None  # (kind, turnId) for an approval or user input

    def started(tid, command):
        send({"method": "turn/started", "params": {"sessionId": sid, "turnId": tid, "commandId": command}})
        # A reminder child session runs alongside: other sessionId.
        send({"method": "turn/started", "params": {"sessionId": "child-1", "turnId": "child-" + tid, "commandId": "c"}})
        send({"method": "turn/completed", "params": {"sessionId": "child-1", "turnId": "child-" + tid, "terminal": "completed"}})

    def completed(tid, terminal="completed", error=None):
        send({"method": "session/contextUsage", "params": {"sessionId": sid, "usedTokens": 28000 + turns, "windowTokens": 1007997, "pressure": "normal"}})
        p = {"sessionId": sid, "turnId": tid, "terminal": terminal}
        if error: p["error"] = {"kind": "modelError", "message": error, "retryable": False}
        send({"method": "turn/completed", "params": p})

    for line in sys.stdin:
        log.write(line); log.flush()
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}
        init = setting("fake-muse.init")
        if method == "initialize" and init == "exit":
            sys.stderr.write("Error: not signed in: run `muse login`\nbye\n")
            sys.exit(1)
        elif method == "initialize" and init == "error":
            send({"id": mid, "error": {"code": -32602, "message": "clientInfo.name: invalid"}})
        elif method == "initialize":
            version = "1.4.6" if init == "old" else "1.4.14"
            schema = 2 if init == "schema2" else 1
            send({"id": mid, "result": {"serverInfo": {"name": "muse", "version": version},
                                        "schema": {"version": schema, "fingerprint": "sha256:fake"},
                                        "grantedCapabilities": ["sessionMcp"]}})
        elif method == "model/list":
            send({"id": mid, "result": {"models": [{"modelId": "muse-wonder-1.0"}, {"modelId": "muse-spark-1.2"}],
                                        "providerId": "meta", "profileId": None, "source": "catalog"}})
        elif method == "session/start":
            sid = SID
            send({"id": mid, "result": {"session": {"sessionId": sid, "modelId": params.get("modelId") or "muse-spark-1.2"},
                                        "viewCursor": "v"}})
        elif method == "session/resume":
            if params.get("sessionId") == "missing":
                send({"id": mid, "error": {"code": -32004, "message": "session not found"}})
            else:
                sid = params["sessionId"]
                send({"id": mid, "result": {"session": {"sessionId": sid, "modelId": "muse-wonder-1.0"},
                                            "history": {}, "pendingRequests": [], "viewCursor": "v"}})
        elif method == "session/setApprovalMode":
            send({"id": mid, "result": {"commandId": params.get("commandId"), "status": "accepted"}})
        elif method == "turn/start":
            turns += 1
            tid = "turn-%d" % turns
            text = params["input"][0]["text"]
            send({"id": mid, "result": {"commandId": params["commandId"], "turnId": tid, "disposition": "started",
                                        "startedNewTurn": True, "status": "accepted"}})
            started(tid, params["commandId"])
            if "FAKE_EXIT" in text:
                time.sleep(0.1)
                sys.exit(3)
            if "FAKE_HANG" in text:
                continue
            if "FAKE_HOLD" in text:
                held = tid
                continue
            if "FAKE_APPROVAL" in text:
                waiting = ("approval", tid)
                send({"id": 900, "method": "approval/request", "params": {
                    "sessionId": sid, "turnId": tid, "approvalId": "ap-1",
                    "currentRequirementId": {"approvalId": "ap-1", "sourceIndex": 0},
                    "availableChoices": [
                        {"choiceId": "deny", "decision": "denied", "label": "No", "scope": "once"},
                        {"choiceId": "always", "decision": "approved", "label": "Always", "scope": "session"},
                        {"choiceId": "yes", "decision": "approved", "label": "Yes", "scope": "once"}]}})
                continue
            if "FAKE_INPUT" in text:
                waiting = ("input", tid)
                send({"id": 901, "method": "userInput/request", "params": {
                    "sessionId": sid, "turnId": tid, "userInputId": "ui-1", "questions": []}})
                continue
            if "FAKE_FAIL" in text:
                completed(tid, "failed", "boom")
            else:
                completed(tid)
            if "FAKE_AGENT" in text:
                time.sleep(0.05)
                turns += 1
                atid = "turn-%d" % turns
                started(atid, "server-minted")
                completed(atid)
        elif method == "turn/steer":
            if held is None or params.get("expectedTurnId") != held:
                send({"id": mid, "error": {"code": -32010, "message": "turn is not active"}})
                continue
            send({"id": mid, "result": {"commandId": params["commandId"], "turnId": held, "status": "accepted"}})
            if "FAKE_DONE" in params["input"][0]["text"]:
                completed(held)
                held = None
        elif method in ("approval/decide", "userInput/cancel"):
            send({"id": mid, "result": {"commandId": params.get("commandId"), "status": "accepted"}})
            if waiting:
                completed(waiting[1])
                waiting = None
    """#

    static func install(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("fake-muse")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func set(_ name: String, _ value: String, in directory: URL) throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // The JSON objects the fake received, in order.
    static func received(in root: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("fake-muse.log"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    static func arguments(in root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fake-muse.args")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
