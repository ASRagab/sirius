import Foundation
import SiriusProtocol

// Where muse is and how `muse serve` is started for Sirius.
enum MuseLaunch {
    // The first release Sirius was checked against (2026.11.05), and the
    // MSP schema version it speaks.
    static let floor = "1.4.14"
    static let schemaVersion: Int64 = 1
    // The stable fingerprint on 1.4.14. A different one is not refused:
    // Muse updates itself hourly and adds methods often. It's reported.
    static let fingerprint = "sha256:c94c3d1f2f51e6424074b9ec43eac3eedcf532d3dcd77351ec1383a87d3049c6"

    // The registered executable when it runs; else muse on PATH; else
    // where Meta's installer puts it.
    static func findExecutable(registered: String, environment: [String: String],
                               home: String = NSHomeDirectory(),
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:))
        -> String? {
        if !registered.isEmpty, isExecutable(registered) { return registered }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/muse"
            if isExecutable(candidate) { return candidate }
        }
        let installed = "\(home)/.local/bin/muse"
        return isExecutable(installed) ? installed : nil
    }

    // `muse serve` for one agent:
    // - the meta provider and the registered model;
    // - contributor mode off for this process, whatever the user's own
    //   setting (§6.2);
    // - no request_user_input tool: nobody is at the terminal;
    // - the agent's root trusted, so its AGENTS.md loads;
    // - network on in the sandbox (§6.1): proxy-only refuses the shell's
    //   Unix socket connects, as Codex's sandbox did without it;
    // - Sirius's instructions as the developer prompt (§3.3 item 6). The
    //   value is read as TOML.
    static func arguments(model: String?, instructions: String?) -> [String] {
        var args = ["serve", "--provider", "meta"]
        if let model { args += ["--model", model] }
        args += ["--contributor-mode", "off", "--disable-request-user-input", "--trust-workspace",
                 "--sandbox-network", "enabled"]
        if let instructions, !instructions.isEmpty {
            args += ["-c", "run.developer_prompt=\(CodexLaunch.toml(instructions))"]
        }
        return args
    }

    // The child's environment: the socket for the sirius helpers, the
    // helpers first on PATH, and no self-update mid-session (§6.4). Only
    // the child's: the user's own muse keeps updating.
    // An aside gets neither the socket nor the helpers: its words are its reply.
    static func environment(_ base: [String: String], socketPath: String, helpers: URL,
                            aside: Bool = false) -> [String: String] {
        var env = base
        if aside {
            env[SiriusEnvironment.socket] = nil
        } else {
            env[SiriusEnvironment.socket] = socketPath
            env["PATH"] = helpers.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        env["MUSE_NO_AUTO_UPDATE"] = "1"
        return env
    }

    // The three sirius-mcp tools, as the MCP server "sirius" on each
    // session. MCP servers run outside the agent's sandbox.
    static func mcpServers(mcpHelper: String, socketPath: String) -> JSONValue {
        .object(["sirius": .object([
            "transport": .string("stdio"),
            "command": .string(mcpHelper),
            "args": .array([]),
            "env": .object([SiriusEnvironment.socket: .string(socketPath)]),
            "mode": .string("required"),
        ])])
    }

    // The version in serverInfo, e.g. "1.4.14", is at least the floor.
    static func isTooOld(_ version: String?) -> Bool {
        !CodexCapabilities.atLeast(version, floor)
    }
}
