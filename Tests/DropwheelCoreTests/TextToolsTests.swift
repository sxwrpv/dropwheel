import Testing
@testable import DropwheelCore

@Suite("CSV")
struct CSVTests {
    @Test("Parses quoted fields with separators, quotes and newlines")
    func parseQuoted() {
        let text = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\"\n\"multi\nline\",x\n"
        #expect(CSV.parse(text, separator: ",") == [
            ["name", "note"],
            ["Smith, J", "said \"hi\""],
            ["multi\nline", "x"],
        ])
    }

    @Test("Keeps empty fields and a missing final newline")
    func emptyFields() {
        #expect(CSV.parse("a,,c\n,b,", separator: ",") == [["a", "", "c"], ["", "b", ""]])
    }

    @Test("Parses tab-separated values")
    func tsv() {
        #expect(CSV.parse("a\tb, c\n1\t2", separator: "\t") == [["a", "b, c"], ["1", "2"]])
    }

    @Test("Writing quotes only the fields that need it")
    func write() {
        let rows = [["plain", "has,comma", "has \"quote\"", "two\nlines"]]
        #expect(CSV.write(rows, separator: ",") == "plain,\"has,comma\",\"has \"\"quote\"\"\",\"two\nlines\"\n")
    }

    @Test("Fields holding Windows line breaks are quoted")
    func crlfField() {
        let tsv = CSV.write([["x\r\ny", "z"]], separator: "\t")
        #expect(CSV.parse(tsv, separator: "\t") == [["x\r\ny", "z"]])
    }

    @Test("CSV to TSV round-trips the values")
    func roundTrip() {
        let rows = CSV.parse("a,\"b\tc\",d\n", separator: ",")
        let tsv = CSV.write(rows, separator: "\t")
        #expect(CSV.parse(tsv, separator: "\t") == rows)
    }
}

@Suite("PlainTextLayout")
struct PlainTextLayoutTests {
    @Test("Blank lines separate paragraphs; wrapped lines are joined")
    func blankLines() {
        let page = "First line of a paragraph\nthat continues here.\n\nSecond paragraph."
        #expect(PlainTextLayout.paragraphs(in: page) == [
            "First line of a paragraph that continues here.",
            "Second paragraph.",
        ])
    }

    @Test("A short line ending a sentence closes the paragraph")
    func shortSentenceEnd() {
        let page = """
        This is a fairly long line of body text that wraps to
        the next line and then ends here.
        A new paragraph starts on this line and it is also long
        enough to wrap.
        """
        #expect(PlainTextLayout.paragraphs(in: page).count == 2)
    }

    @Test("Hyphenated line breaks are joined without a space")
    func hyphenation() {
        #expect(PlainTextLayout.paragraphs(in: "an exam-\nple of joining") == ["an example of joining"])
    }

    @Test("Columns split on tabs or runs of two or more spaces")
    func tableRows() {
        let page = "Name   Qty\tPrice\nApple  3      1.20\n\nPear   10     0.80"
        #expect(PlainTextLayout.tableRows(in: page) == [
            ["Name", "Qty", "Price"],
            ["Apple", "3", "1.20"],
            ["Pear", "10", "0.80"],
        ])
    }
}

@Suite("HTMLDocument")
struct HTMLDocumentTests {
    @Test("Escapes markup and wraps each paragraph")
    func escaping() {
        let html = HTMLDocument.make(title: "A & B", paragraphs: ["x < y", "\"quoted\" & done"])
        #expect(html.contains("<title>A &amp; B</title>"))
        #expect(html.contains("<p>x &lt; y</p>"))
        #expect(html.contains("<p>&quot;quoted&quot; &amp; done</p>"))
    }

    @Test("Characters XML forbids are removed, so EPUB output stays valid")
    func controlCharacters() {
        let html = HTMLDocument.make(title: "t", paragraphs: ["a\u{01}b\u{0B}c\u{FFFE}d\te"])
        #expect(html.contains("<p>abcd\te</p>"))
    }

    @Test("Plain text keeps its line breaks inside paragraphs")
    func plainText() {
        let html = HTMLDocument.fromPlainText("line one\nline two\n\nnext", title: "t")
        #expect(html.contains("<p>line one<br>line two</p>"))
        #expect(html.contains("<p>next</p>"))
    }
}
