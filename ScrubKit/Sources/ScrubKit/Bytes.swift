import Foundation

public enum ScrubError: Error, CustomStringConvertible {
    /// The file does not follow its format, so a byte-level edit is not safe.
    case malformed(String)
    /// The file is valid, but it uses a structure this version does not edit.
    case unsupported(String)
    case io(String)

    public var description: String {
        switch self {
        case .malformed(let why): return "malformed file: \(why)"
        case .unsupported(let why): return "not supported: \(why)"
        case .io(let why): return "file error: \(why)"
        }
    }
}

/// Bounds-checked reads over file bytes. Every input is untrusted, so a bad
/// offset must become an error and never a crash.
struct Bytes {
    let data: Data
    let count: Int
    private let start: Int

    init(_ data: Data) {
        self.data = data
        self.count = data.count
        self.start = data.startIndex
    }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, length <= count, offset <= count - length else {
            throw ScrubError.malformed("read of \(length) bytes at \(offset) passes the end (\(count))")
        }
    }

    func u8(_ o: Int) throws -> Int {
        try check(o, 1)
        return Int(data[start + o])
    }

    func be16(_ o: Int) throws -> Int {
        try check(o, 2)
        return Int(data[start + o]) << 8 | Int(data[start + o + 1])
    }

    func be32(_ o: Int) throws -> Int {
        try check(o, 4)
        var v = 0
        for i in 0..<4 { v = v << 8 | Int(data[start + o + i]) }
        return v
    }

    func be64(_ o: Int) throws -> Int {
        try check(o, 8)
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(data[start + o + i]) }
        guard v <= UInt64(Int.max) else { throw ScrubError.malformed("64-bit value too large at \(o)") }
        return Int(v)
    }

    /// Big-endian unsigned integer of 0, 1, 2, 4 or 8 bytes. Size 0 reads as 0.
    func beUInt(_ o: Int, size: Int) throws -> Int {
        switch size {
        case 0: return 0
        case 1: return try u8(o)
        case 2: return try be16(o)
        case 4: return try be32(o)
        case 8: return try be64(o)
        default: throw ScrubError.malformed("field size \(size)")
        }
    }

    func le16(_ o: Int) throws -> Int {
        try check(o, 2)
        return Int(data[start + o]) | Int(data[start + o + 1]) << 8
    }

    func le32(_ o: Int) throws -> Int {
        try check(o, 4)
        var v = 0
        for i in (0..<4).reversed() { v = v << 8 | Int(data[start + o + i]) }
        return v
    }

    func fourCC(_ o: Int) throws -> String {
        try check(o, 4)
        return String(decoding: data[(start + o)..<(start + o + 4)], as: Unicode.ASCII.self)
    }

    /// A copy of `length` bytes at `o`, with indices that start at 0.
    func copy(_ o: Int, _ length: Int) throws -> Data {
        try check(o, length)
        return data.subdata(in: (start + o)..<(start + o + length))
    }

    func hasPrefix(_ prefix: [UInt8], at o: Int) -> Bool {
        guard o >= 0, prefix.count <= count, o <= count - prefix.count else { return false }
        for (i, byte) in prefix.enumerated() where data[start + o + i] != byte { return false }
        return true
    }

    /// A NUL-terminated string that starts at `o` and ends before `limit`.
    /// Returns the text and the offset after the terminator.
    func cString(at o: Int, limit: Int) throws -> (String, Int) {
        guard o >= 0, o <= limit, limit <= count else { throw ScrubError.malformed("string at \(o)") }
        var end = o
        while end < limit, data[start + end] != 0 { end += 1 }
        let text = String(decoding: data[(start + o)..<(start + end)], as: UTF8.self)
        return (text, min(end + 1, limit))
    }
}

extension Data {
    mutating func appendBE16(_ v: Int) {
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    mutating func appendBE32(_ v: Int) {
        for shift in [24, 16, 8, 0] { append(UInt8(truncatingIfNeeded: v >> shift)) }
    }

    mutating func appendASCII(_ s: String) {
        append(contentsOf: Array(s.utf8))
    }

    static func be(_ v: Int, size: Int) -> Data {
        var out = Data()
        for i in (0..<size).reversed() { out.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
        return out
    }
}

/// One line of the container report: a structure the byte-level pass found,
/// and what it did with it.
public struct ContainerNote: Hashable, Sendable {
    public enum Action: String, Sendable { case removed, kept, rewritten }
    public let item: String
    public let detail: String
    public let bytes: Int
    public let action: Action

    public init(_ item: String, _ detail: String, bytes: Int, _ action: Action) {
        self.item = item
        self.detail = detail
        self.bytes = bytes
        self.action = action
    }
}
