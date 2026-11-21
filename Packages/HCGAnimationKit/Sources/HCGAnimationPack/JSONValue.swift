//
//  JSONValue.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  A strict JSON value. Booleans and numbers are kept apart (the preset format refuses `1` where it wants `true`
//  and vice versa, exactly like HCGBackgroundKit's Objective-C reader), and the writer is deterministic: sorted keys,
//  two-space indentation, whole numbers without a fraction. Same input, same bytes, on macOS, iOS and Linux.
//

import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors (nil when the type differs)

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Parsing

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool first: Foundation's decoders only produce a Bool from true/false, never from 0/1.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    /// Parses a JSON document. Returns nil for anything that is not valid JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Writing

extension JSONValue {
    /// Canonical text: sorted keys, two-space indentation, trailing newline.
    public func canonicalData() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += JSONValue.format(n)
        case .string(let s): out += JSONValue.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += inner
                v.write(into: &out, indent: indent + 1)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{\n"
            let keys = o.keys.sorted()
            for (i, k) in keys.enumerated() {
                out += inner + JSONValue.quote(k) + ": "
                o[k]!.write(into: &out, indent: indent + 1)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        if n == n.rounded(), abs(n) < 9.0e15 { return String(Int64(n)) }
        return "\(n)" // shortest representation that round-trips
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    r += String(format: "\\u%04x", u.value)
                } else {
                    r.unicodeScalars.append(u)
                }
            }
        }
        return r + "\""
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
