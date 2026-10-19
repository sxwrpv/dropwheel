import Foundation

/// Reads and writes delimiter-separated values (RFC 4180 quoting).
public enum CSV {
    public static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.makeIterator()
        var pending = characters.next()

        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                row.append(field)
                field = ""
            // Swift treats "\r\n" as one Character.
            case "\n", "\r\n", "\r":
                rows.append(row + [field])
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            rows.append(row + [field])
        }
        return rows
    }

    public static func write(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { quoteIfNeeded($0, separator: separator) }.joined(separator: String(separator))
        }.map { $0 + "\n" }.joined()
    }

    private static func quoteIfNeeded(_ field: String, separator: Character) -> String {
        // Checked by scalar: Swift treats "\r\n" as one Character, so
        // contains("\n") alone would miss Windows line breaks.
        let hasLineBreak = field.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        let needsQuotes = field.contains(separator) || field.contains("\"") || hasLineBreak
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Recovers structure from text extracted from a PDF page, which arrives as
/// one line per printed line with no paragraph markers.
public enum PlainTextLayout {
    /// A line shorter than this share of the page's longest line, ending a
    /// sentence, is taken as the end of a paragraph.
    private static let shortLineRatio = 0.8
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", "\u{201D}", "\""]

    public static func paragraphs(in pageText: String) -> [String] {
        let lines = pageText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let longest = lines.map(\.count).max() ?? 0
        var paragraphs: [String] = []
        var current = ""

        func finish() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
        }

        for line in lines {
            guard !line.isEmpty else {
                finish()
                continue
            }
            if current.hasSuffix("-"), line.first?.isLowercase == true {
                current = String(current.dropLast()) + line
            } else {
                current = current.isEmpty ? line : current + " " + line
            }
            let endsSentence = line.last.map(sentenceEnders.contains) ?? false
            if endsSentence && Double(line.count) < Double(longest) * shortLineRatio {
                finish()
            }
        }
        finish()
        return paragraphs
    }

    /// Splits each non-empty line into cells on tabs or runs of two or more spaces.
    public static func tableRows(in pageText: String) -> [[String]] {
        pageText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                line.replacingOccurrences(of: "\t| {2,}", with: "\u{1F}", options: .regularExpression)
                    .split(separator: "\u{1F}")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }
}

/// Minimal HTML used as a hand-off format to pandoc.
public enum HTMLDocument {
    public static func make(title: String, paragraphs: [String]) -> String {
        wrap(title: title, body: paragraphs.map { "<p>\(escape($0))</p>" }.joined(separator: "\n"))
    }

    /// Blank lines separate paragraphs; single line breaks are kept as <br>.
    public static func fromPlainText(_ text: String, title: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = paragraphs.map { paragraph in
            "<p>" + paragraph.components(separatedBy: "\n").map(escape).joined(separator: "<br>") + "</p>"
        }.joined(separator: "\n")
        return wrap(title: title, body: body)
    }

    private static func wrap(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title></head>
        <body>
        \(body)
        </body></html>
        """
    }

    /// Escapes markup and drops characters XML 1.0 forbids, which would
    /// otherwise make EPUB output unreadable.
    static func escape(_ text: String) -> String {
        let allowed = String(String.UnicodeScalarView(text.unicodeScalars.filter(isXMLCharacter)))
        return allowed.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func isXMLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }
}
