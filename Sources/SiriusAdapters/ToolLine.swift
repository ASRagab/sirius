import Foundation
import SiriusCore

// What to show for a tool call a harness names by its tool and its input:
// one line, and the kind of thing it does. Claude Code's and Muse Code's
// tools go by the same names in different cases ("Bash", "bash").
enum ToolLine {
    static func title(tool name: String, input: [String: Any]) -> String {
        func first(_ keys: String...) -> String? {
            keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
        }
        let said: String?
        switch key(name) {
        case "bash", "shell": said = first("command")
        case "read", "edit", "write", "multiedit", "notebookedit":
            said = first("file_path", "path", "notebook_path").map { ($0 as NSString).lastPathComponent }
        case "grep", "glob": said = first("pattern")
        case "webfetch", "fetch": said = first("url")
        case "websearch": said = first("query")
        default: said = first("description", "command", "file_path", "path", "pattern", "query", "url", "prompt")
        }
        return line(said ?? name)
    }

    static func kind(tool name: String) -> ToolKind {
        switch key(name) {
        case "bash", "shell", "bashoutput", "killshell": return .execute
        case "read": return .read
        case "edit", "write", "multiedit", "notebookedit", "applypatch": return .edit
        case "grep", "glob", "websearch", "toolsearch", "ls", "find": return .search
        case "webfetch", "fetch": return .fetch
        case "todowrite": return .think
        default: return .other
        }
    }

    // The first line, short enough to show.
    static func line(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.count > 200 ? String(first.prefix(200)) + "…" : first
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}
