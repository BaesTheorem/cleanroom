import CoreGraphics
import Foundation
import zlib

/// Color profiles stay, because the picture needs them to render. Three parts
/// of a profile do not affect rendering and can identify a file:
/// the creation date in the header (an iPhone writes the capture time of the
/// photo into the profile of its HDR gain map), the profile ID (a checksum
/// that covers the date), and the make-and-model tag of a display profile
/// (it holds the serial number of the monitor).
enum ICC {
    /// True for a profile that the system knows as a named standard space
    /// (sRGB, Display P3, Adobe RGB). Every copy of such a profile has the
    /// same date, so the date says nothing about the file. A changed byte
    /// stops the system from recognizing the profile, so these stay as is.
    static func isStandard(_ profile: Data) -> Bool {
        CGColorSpace(iccData: profile as CFData)?.name != nil
    }

    /// Byte ranges of `profile` to set to zero.
    static func privateRanges(_ profile: Data) -> [Range<Int>] {
        let b = Bytes(profile)
        guard b.count >= 132, b.hasPrefix(Array("acsp".utf8), at: 36), !isStandard(profile) else { return [] }
        var ranges = [24..<36, 84..<100]
        if let n = try? b.be32(128), n <= 512 {
            for i in 0..<n {
                let e = 132 + 12 * i
                guard let signature = try? b.fourCC(e), let offset = try? b.be32(e + 4), let size = try? b.be32(e + 8) else { break }
                if signature == "mmod", size > 8, offset >= 132, offset + size <= b.count { ranges.append((offset + 8)..<(offset + size)) }
            }
        }
        return ranges.filter { range in profile[(profile.startIndex + range.lowerBound)..<(profile.startIndex + range.upperBound)].contains { $0 != 0 } }
    }

    /// The profile with its private ranges set to zero, or nil if it has none.
    static func sanitized(_ profile: Data) -> Data? {
        let ranges = privateRanges(profile)
        guard !ranges.isEmpty else { return nil }
        var out = Data(profile)
        for range in ranges { out.replaceSubrange(range, with: Data(count: range.count)) }
        return out
    }

    /// The header date as text, or nil when it is zero.
    static func date(_ profile: Data) -> String? {
        let b = Bytes(profile)
        guard b.count >= 36, let y = try? b.be16(24), let mo = try? b.be16(26), let d = try? b.be16(28),
              let h = try? b.be16(30), let mi = try? b.be16(32), let s = try? b.be16(34), y + mo + d + h + mi + s > 0 else { return nil }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
    }

    static func note(for profile: Data, where place: String) -> ContainerNote? {
        let ranges = privateRanges(profile)
        guard !ranges.isEmpty else { return nil }
        var parts: [String] = []
        if let stamp = date(profile) { parts.append("creation date \(stamp)") }
        if ranges.contains(where: { $0.lowerBound >= 132 }) { parts.append("display make, model and serial number") }
        if parts.isEmpty { parts.append("profile checksum") }
        return ContainerNote("Color profile fields\(place)", parts.joined(separator: ", "), bytes: ranges.reduce(0) { $0 + $1.count }, .removed)
    }

    // MARK: - zlib (the PNG iCCP chunk stores the profile compressed)

    static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var capacity = max(input.count * 8, 1 << 16)
        while capacity <= 1 << 27 {
            var out = Data(count: capacity)
            var length = uLongf(capacity)
            let status = out.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    uncompress(dst.bindMemory(to: Bytef.self).baseAddress, &length, src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
                }
            }
            if status == Z_OK { return out.prefix(Int(length)) }
            if status != Z_BUF_ERROR { return nil }
            capacity *= 4
        }
        return nil
    }

    static func deflate(_ input: Data) -> Data? {
        var length = compressBound(uLong(input.count))
        var out = Data(count: Int(length))
        let status = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compress2(dst.bindMemory(to: Bytef.self).baseAddress, &length, src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_BEST_COMPRESSION)
            }
        }
        return status == Z_OK ? out.prefix(Int(length)) : nil
    }
}
