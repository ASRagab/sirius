// Python's string rules where wmem's output depends on them, so this port
// prints what the Python reference (~/.agents/bin/wmem) printed: what
// str.strip() and str.isspace() call whitespace, how a file read in text
// mode turns \r\n and \r into \n, how splitlines() splits, how repr()
// quotes, and how strings compare and pad (by code point). Everything here
// works on Unicode scalars, Python's characters, not Swift's graphemes.
enum PythonText {
    // str.isspace(): the scalars Python strips.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000: true
        default: false
        }
    }

    // str.strip() with no argument.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return string(scalars[first...last])
    }

    // What Path.read_text() returns for the file's UTF-8: universal
    // newlines, so \r\n and a lone \r each become \n.
    static func readText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousCR = true
                continue
            }
            if scalar == "\n" && previousCR {
                previousCR = false
                continue
            }
            previousCR = false
            out.append(scalar)
        }
        return String(out)
    }

    // str.split("\n").
    static func split(_ text: String, on separator: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == separator {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        parts.append(String(current))
        return parts
    }

    // str.splitlines(): no empty last line for a trailing break.
    static func splitlines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previousCR {
                previousCR = false
                continue
            }
            previousCR = scalar == "\r"
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(String(current))
                current = String.UnicodeScalarView()
            default:
                current.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    // len(text).
    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    // text[:count].
    static func prefix(_ text: String, _ count: Int) -> String {
        string(text.unicodeScalars.prefix(count))
    }

    // text.startswith(prefix), by code point.
    static func startsWith(_ text: String, _ prefix: String) -> Bool {
        text.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    // a < b, by code point.
    static func less(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    // f"{text:width}" for a string: padded on the right.
    static func leftAligned(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - length(text)))
    }

    // f"{text:>width}", and an int's default alignment.
    static func rightAligned(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - length(text))) + text
    }

    // The scalar's value as a decimal digit (\d, a Unicode Nd), or nil.
    static func decimal(_ scalar: Unicode.Scalar) -> Int? {
        guard scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue else {
            return nil
        }
        return Int(value)
    }

    // str.isdigit(): non-empty, every scalar a decimal or other digit.
    static func isDigit(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.properties.numericType == .decimal || $0.properties.numericType == .digit
        }
    }

    // str(int(text)) for decimal digits: ASCII, no leading zeros.
    static func integerText(_ digits: String) -> String? {
        guard !digits.isEmpty else { return nil }
        var out = ""
        for scalar in digits.unicodeScalars {
            guard let value = decimal(scalar) else { return nil }
            out += String(value)
        }
        let trimmed = out.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    // An integer's text as an Int, Int.max when larger.
    static func clamped(_ integerText: String) -> Int {
        Int(integerText) ?? Int.max
    }

    // repr(text).
    static func repr(_ text: String) -> String {
        let quote: Unicode.Scalar = text.unicodeScalars.contains("'") && !text.unicodeScalars.contains("\"")
            ? "\"" : "'"
        var out = String(Character(quote))
        for scalar in text.unicodeScalars {
            switch scalar {
            case quote, "\\": out += "\\" + String(Character(scalar))
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\x" + hex(scalar.value, 2)
                } else if scalar.value < 0x7F || isPrintable(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value < 0x100 {
                    out += "\\x" + hex(scalar.value, 2)
                } else if scalar.value < 0x10000 {
                    out += "\\u" + hex(scalar.value, 4)
                } else {
                    out += "\\U" + hex(scalar.value, 8)
                }
            }
        }
        out.unicodeScalars.append(quote)
        return out
    }

    // str.isprintable() for one scalar: not a control, format, surrogate,
    // private-use, unassigned or separator character, the space excepted.
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator,
             .spaceSeparator: return false
        default: return true
        }
    }

    private static func hex(_ value: UInt32, _ width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
