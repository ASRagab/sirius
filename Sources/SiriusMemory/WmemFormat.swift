import Foundation

// WMEM.md's format, as the wmem CLI reads and writes it. A header line
// `Window: N days · Cleaned: YYYY-MM-DD` (or `never`), then `## Pinned`
// and `## Learned`, each entry one `- name: text` line. The file is handled
// as lines split on \n after Python's universal newlines, as the Python
// reference handled it; SiriusCore's WorkingMemory reads the header and
// size through here too, so Sirius and wmem never disagree.
public enum WmemFormat {
    public static let sections = ["Pinned", "Learned"]
    public static let defaultWindow = 14
    // What a missing WMEM.md reads as.
    public static let template = """
        # Working memory

        > Pointers to what the user refers to, so a fresh session finds them without searching or asking. Edit this file directly; cleaned up per `gc.md`.

        Window: 14 days · Cleaned: never

        ## Pinned

        ## Learned

        """

    // One `- name: text` line in a known section.
    public struct Entry: Equatable, Sendable {
        public var index: Int
        public var section: String
        public var name: String
        public var text: String
    }

    // The header: its line, the window (as Python's int() prints it, and
    // as a number, Int.max when larger) and the Cleaned: value.
    public struct Header: Equatable, Sendable {
        public var index: Int?
        public var window: String
        public var cleaned: String

        public var windowDays: Int { PythonText.clamped(window) }
    }

    // The file's text as lines.
    public static func lines(_ text: String) -> [String] {
        PythonText.split(PythonText.readText(text), on: "\n")
    }

    // The size `wmem ls` prints: characters (code points) / 4, after
    // universal newlines.
    public static func tokens(_ text: String) -> Int {
        PythonText.length(PythonText.readText(text)) / 4
    }

    // Whether `name` may name an entry: lowercase letters, digits and
    // dashes, not starting with a dash. As Python's `$`, one trailing \n
    // passes.
    public static func isValidName(_ name: String) -> Bool {
        var scalars = Array(name.unicodeScalars)
        if scalars.last == "\n" { scalars.removeLast() }
        guard let first = scalars.first, isNameStart(first) else { return false }
        return scalars.dropFirst().allSatisfy { isNameStart($0) || $0 == "-" }
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    // `- name: text` split, or nil.
    static func entry(_ line: String) -> (name: String, text: String)? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.starts(with: ["-", " "]), scalars.count > 2, isNameStart(scalars[2]) else { return nil }
        var end = 3
        while end < scalars.count, isNameStart(scalars[end]) || scalars[end] == "-" { end += 1 }
        guard scalars[end...].starts(with: [":", " "]) else { return nil }
        return (string(scalars[2..<end]), string(scalars[(end + 2)...]))
    }

    // The text after `## `, when there is some.
    static func heading(_ line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count > 3, scalars.starts(with: ["#", "#", " "]) else { return nil }
        return string(scalars[3...])
    }

    // Each entry under Pinned or Learned, in file order.
    public static func entries(_ lines: [String]) -> [Entry] {
        var section: String?
        var found: [Entry] = []
        for (index, line) in lines.enumerated() {
            if let heading = heading(line) {
                section = PythonText.strip(heading)
                continue
            }
            if let (name, text) = entry(line), let section, sections.contains(section) {
                found.append(Entry(index: index, section: section, name: name, text: text))
            }
        }
        return found
    }

    // The first header line; without one, window 14 and never cleaned.
    public static func header(_ lines: [String]) -> Header {
        for (index, line) in lines.enumerated() {
            if let (window, cleaned) = parseHeader(line) {
                return Header(index: index, window: window, cleaned: cleaned)
            }
        }
        return Header(index: nil, window: String(defaultWindow), cleaned: "never")
    }

    // `Window: (\d+) days · Cleaned: (\S+)`, the whole line.
    private static func parseHeader(_ line: String) -> (String, String)? {
        let scalars = Array(line.unicodeScalars)
        let lead = Array("Window: ".unicodeScalars), middle = Array(" days · Cleaned: ".unicodeScalars)
        guard scalars.starts(with: lead) else { return nil }
        var end = lead.count
        while end < scalars.count, PythonText.decimal(scalars[end]) != nil { end += 1 }
        guard end > lead.count, scalars[end...].starts(with: middle) else { return nil }
        let date = scalars[(end + middle.count)...]
        guard !date.isEmpty, !date.contains(where: PythonText.isSpace),
              let window = PythonText.integerText(string(scalars[lead.count..<end])) else { return nil }
        return (window, string(date))
    }

    // Rewrites the header with a new window or Cleaned: value, adding it
    // before the first section when the file has none.
    public static func setHeader(_ lines: inout [String], window: String? = nil, cleaned: String? = nil) {
        let current = header(lines)
        let line = "Window: \(window ?? current.window) days · Cleaned: \(cleaned ?? current.cleaned)"
        if let index = current.index {
            lines[index] = line
        } else {
            let at = lines.firstIndex { PythonText.startsWith($0, "## ") } ?? lines.count
            lines.insert(contentsOf: [line, ""], at: at)
        }
    }

    // The index after the last line of `section`, before trailing blank
    // lines, adding the section when missing: Pinned before Learned,
    // Learned at the end.
    public static func sectionEnd(_ lines: inout [String], _ section: String) -> Int {
        var start = lines.firstIndex { PythonText.strip($0) == "## \(section)" }
        if start == nil {
            if section == "Pinned" {
                let learned = lines.firstIndex { PythonText.strip($0) == "## Learned" } ?? lines.count
                lines.insert(contentsOf: ["## Pinned", "", ""], at: learned)
                start = learned
            } else {
                lines += ["", "## Learned", ""]
                start = lines.count - 2
            }
        }
        let first = start! + 1
        var end = first
        while end < lines.count, !PythonText.startsWith(lines[end], "## ") { end += 1 }
        while end > first, PythonText.strip(lines[end - 1]).isEmpty { end -= 1 }
        return end
    }

    // The file's text for `lines`: one trailing newline.
    public static func text(_ lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        while text.unicodeScalars.last == "\n" { text.unicodeScalars.removeLast() }
        return text + "\n"
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
