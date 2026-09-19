import Foundation

/// A strict RFC 8259 scanner that records the byte span of every value, so a caller can
/// splice one value in a JSON file without re-serialising (and re-formatting) the rest.
/// Duplicate keys are kept in order; `lastMember(named:)` matches JSON.parse (last wins).
struct JSONSourceMap {
    struct Span: Equatable { var start: Int; var end: Int }   // half-open byte range

    indirect enum Node {
        case object(members: [Member], span: Span)
        case array(items: [Node], span: Span)
        case string(value: String, span: Span)
        case scalar(span: Span)   // number, true, false, null

        var span: Span {
            switch self {
            case .object(_, let s), .array(_, let s), .string(_, let s), .scalar(let s): return s
            }
        }
        var members: [Member]? { if case .object(let m, _) = self { return m }; return nil }
        var stringValue: String? { if case .string(let v, _) = self { return v }; return nil }
        func lastMember(named key: String) -> Member? { members?.last { $0.key == key } }
    }

    struct Member { let key: String; let keySpan: Span; let value: Node }

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int; let reason: String
        var description: String { "JSON 解析失败（字节 \(offset)）：\(reason)" }
    }

    let bytes: [UInt8]
    let root: Node
    /// Offset of the first byte after an optional UTF-8 BOM.
    let bodyStart: Int

    init(data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        bytes = parser.bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        bodyStart = parser.index
        parser.skipWhitespace()
        root = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw ParseError(offset: parser.index, reason: "根值之后还有多余内容") }
    }

    func text(_ span: Span) -> String { String(decoding: bytes[span.start..<span.end], as: UTF8.self) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail(_ reason: String) -> ParseError { ParseError(offset: index, reason: reason) }

        mutating func parseValue(depth: Int) throws -> Node {
            guard depth < 512 else { throw fail("嵌套过深") }
            guard index < bytes.count else { throw fail("意外的文件结尾") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                let start = index
                let value = try parseString()
                return .string(value: value, span: Span(start: start, end: index))
            case UInt8(ascii: "t"): return try literal("true")
            case UInt8(ascii: "f"): return try literal("false")
            case UInt8(ascii: "n"): return try literal("null")
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String) throws -> Node {
            let w = Array(word.utf8), start = index
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { throw fail("无效的字面量") }
            index += w.count
            return .scalar(span: Span(start: start, end: index))
        }

        mutating func parseNumber() throws -> Node {
            let start = index
            func digits() -> Int { let s = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - s }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw fail("无效的数字") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw fail("无效的数字") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; if digits() == 0 { throw fail("无效的数字") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                if digits() == 0 { throw fail("无效的数字") }
            }
            return .scalar(span: Span(start: start, end: index))
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw fail("字符串未结束") }
                let b = bytes[index]
                if b == UInt8(ascii: "\"") { index += 1; break }
                if b < 0x20 { throw fail("字符串中含有未转义的控制字符") }
                if b != UInt8(ascii: "\\") { out.append(b); index += 1; continue }
                index += 1
                guard index < bytes.count else { throw fail("转义不完整") }
                let e = bytes[index]; index += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else { index = save }
                    }
                    let s = Unicode.Scalar(scalar) ?? "\u{FFFD}"   // lone surrogate -> U+FFFD like Swift strings
                    out.append(contentsOf: Array(String(Character(s)).utf8))
                default: throw fail("无效的转义")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { throw fail("无效的 \\u 转义") }
            index += 4
            return v
        }

        mutating func parseObject(depth: Int) throws -> Node {
            let start = index
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members: [], span: Span(start: start, end: index)) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("需要字符串键") }
                let keyStart = index
                let key = try parseString()
                let keySpan = Span(start: keyStart, end: index)
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("需要冒号") }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(Member(key: key, keySpan: keySpan, value: value))
                skipWhitespace()
                guard index < bytes.count else { throw fail("对象未结束") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                throw fail("需要逗号或右花括号")
            }
            return .object(members: members, span: Span(start: start, end: index))
        }

        mutating func parseArray(depth: Int) throws -> Node {
            let start = index
            index += 1
            var items: [Node] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items: [], span: Span(start: start, end: index)) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail("数组未结束") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                throw fail("需要逗号或右方括号")
            }
            return .array(items: items, span: Span(start: start, end: index))
        }
    }
}

enum JSONText {
    /// Encodes like JavaScript's JSON.stringify (what Claude Code itself writes): only `"`, `\`
    /// and control characters are escaped; `/` and non-ASCII stay literal.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
