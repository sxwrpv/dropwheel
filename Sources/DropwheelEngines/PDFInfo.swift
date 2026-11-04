import CoreGraphics
import Foundation

/// A PDF's document information. PDFKit stamps its own producer and dates over
/// whatever it is given, and writes other names so that nothing can read
/// them, so the dictionary is written here, into the file PDFKit saved.
enum PDFInfo {
    enum Value: Equatable, Sendable {
        case text(String)
        /// A PDF name, such as the value of /Trapped.
        case name(String)
        /// A number, true or false, written just as it reads.
        case literal(String)
        /// A list or dictionary, which isn't carried over.
        case unsupported
    }

    static func entries(of url: URL) -> [String: Value] {
        guard let document = CGPDFDocument(url as CFURL) else { return [:] }
        return withExtendedLifetime(document) {
            guard let info = document.info else { return [:] }
            var entries: [String: Value] = [:]
            CGPDFDictionaryApplyBlock(info, { key, object, _ in
                entries[String(cString: key)] = value(of: object)
                return true
            }, nil)
            return entries
        }
    }

    /// PDFKit raises an exception, which Swift can't catch, on reading or
    /// saving a document whose information has a name that isn't UTF-8.
    static func hasValidNames(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return withExtendedLifetime(document) {
            guard let info = document.info else { return true }
            var isValid = true
            CGPDFDictionaryApplyBlock(info, { key, _, _ in
                isValid = isValid && String(data: Data(bytes: key, count: strlen(key)), encoding: .utf8) != nil
                return true
            }, nil)
            return isValid
        }
    }

    /// Replaces the dictionary in `url`. The old one is wiped, as an update
    /// alone would leave it in the file.
    static func write(_ entries: [String: Value], in url: URL) throws(ConversionError) {
        var data = try PDFPatch.read(url)
        guard let number = PDFPatch.reference("/Info", in: data), let old = PDFPatch.objectBody(number, in: data) else {
            throw .writeFailed(PDFPatch.unusualFile)
        }
        PDFPatch.blank(old, in: &data)
        let items = entries.filter { $0.value != .unsupported }.sorted { $0.key < $1.key }.map { "\(name($0.key)) \(serialized($0.value))" }
        try PDFPatch.append(number, body: Data(("<< " + items.joined(separator: " ") + " >>").utf8), to: &data)
        try PDFPatch.write(data, to: url)
    }

    private static func value(of object: CGPDFObjectRef) -> Value? {
        switch CGPDFObjectGetType(object) {
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string), let string, let text = CGPDFStringCopyTextString(string) else { return nil }
            return .text(text as String)
        case .name:
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &name), let name else { return nil }
            return .name(String(cString: name))
        case .integer:
            var number: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &number) ? .literal(String(number)) : nil
        case .real:
            var number: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &number) ? .literal("\(number)") : nil
        case .boolean:
            var flag: CGPDFBoolean = 0
            return CGPDFObjectGetValue(object, .boolean, &flag) ? .literal(flag == 0 ? "false" : "true") : nil
        case .array, .dictionary, .stream:
            return .unsupported
        default:
            return nil
        }
    }

    /// A PDF name: anything but plain characters is written as #xx.
    private static func name(_ text: String) -> String {
        "/" + text.utf8.map { byte in
            let isPlain = (0x21...0x7E).contains(byte) && !"#()<>[]{}/%".utf8.contains(byte)
            return isPlain ? String(UnicodeScalar(byte)) : String(format: "#%02X", byte)
        }.joined()
    }

    /// Text as a hex string, which needs no escaping: plain bytes if it is
    /// ASCII, as dates must be, and UTF-16 with a byte-order mark otherwise.
    private static func serialized(_ value: Value) -> String {
        switch value {
        case .name(let text):
            return name(text)
        case .literal(let text):
            return text
        case .unsupported:
            return "null"
        case .text(let text):
            let isASCII = text.utf8.allSatisfy { $0 < 0x80 }
            let bytes = isASCII ? Array(text.utf8) : [0xFE, 0xFF] + text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
        }
    }
}
