import Foundation

/// Canonical JSON value domain for the D4 handoff payload, restricted at the
/// type level to {string, integer, bool, null, array, object} — **no floats
/// exist in the payload; every numeric field is an integer (milliseconds)**,
/// which is exactly how the determinism guarantee is achieved (C8 spec).
public indirect enum CanonicalJSONValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null
    case array([CanonicalJSONValue])
    /// Key order on input is irrelevant; the writer sorts byte-wise.
    case object([(String, CanonicalJSONValue)])

    public static func == (lhs: CanonicalJSONValue, rhs: CanonicalJSONValue) -> Bool {
        CanonicalJSONWriter.write(lhs) == CanonicalJSONWriter.write(rhs)
    }
}

/// Blaise's OWN canonicalization convention (C1/C8): object keys sorted
/// byte-wise (UTF-8); integer-only numerics; strings escaped minimally
/// (`\"`, `\\`, control chars as `\u00XX`; all other characters verbatim
/// UTF-8); no insignificant whitespace; trailing `\n`. Determinism is by
/// construction, not by encoder version. the knowledge graph re-hashes payloads under its
/// own convention at ingestion — the hashes are not shared keys.
public enum CanonicalJSONWriter {
    /// Canonical document bytes: the serialized value + trailing newline.
    public static func write(_ value: CanonicalJSONValue) -> Data {
        var out = Data()
        append(value, to: &out)
        out.append(0x0A) // trailing "\n"
        return out
    }

    private static func append(_ value: CanonicalJSONValue, to out: inout Data) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .integer(let number):
            out.append(contentsOf: Array(String(number).utf8))
        case .string(let string):
            appendEscaped(string, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                append(item, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let pairs):
            // Sort byte-wise over the key's UTF-8 representation.
            let sorted = pairs.sorted { lexicographicallyPrecedes($0.0, $1.0) }
            out.append(UInt8(ascii: "{"))
            for (index, pair) in sorted.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                appendEscaped(pair.0, to: &out)
                out.append(UInt8(ascii: ":"))
                append(pair.1, to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func lexicographicallyPrecedes(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    /// Minimal escaping: `\"`, `\\`, control characters (< 0x20) as
    /// `\u00XX`; everything else verbatim UTF-8.
    private static func appendEscaped(_ string: String, to out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""):
                out.append(contentsOf: Array("\\\"".utf8))
            case UInt8(ascii: "\\"):
                out.append(contentsOf: Array("\\\\".utf8))
            case 0 ..< 0x20:
                let hex = String(format: "\\u%04x", Int(byte))
                out.append(contentsOf: Array(hex.utf8))
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
