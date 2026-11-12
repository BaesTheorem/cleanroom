import Foundation
import zlib

/// Lossless PNG scrub. It copies the chunks a decoder needs and drops text,
/// time, Exif and private chunks.
enum PNG {
    struct Result {
        var data: Data
        var notes: [ContainerNote]
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Chunks that carry pixels, or that change how the pixels render.
    static let allowed: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND",
        "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV", "cLLI",
        "bKGD", "hIST", "pHYs", "sPLT",
        "acTL", "fcTL", "fdAT",
    ]

    private static let reasons: [String: String] = [
        "tEXt": "text field", "zTXt": "compressed text field", "iTXt": "text field (XMP lives here)",
        "eXIf": "Exif block", "tIME": "last-modified time", "iDOT": "Apple decoder hint",
        "caBX": "content credentials", "vpAg": "ImageMagick page data", "oFFs": "page offset",
        "pCAL": "pixel calibration", "sCAL": "physical scale", "sTER": "stereo layout",
    ]

    static func isPNG(_ data: Data) -> Bool {
        Bytes(data).hasPrefix(signature, at: 0)
    }

    static func strip(_ input: Data) throws -> Result {
        let b = Bytes(input)
        guard isPNG(input) else { throw ScrubError.malformed("no PNG signature") }
        var out = Data(capacity: input.count)
        out.append(contentsOf: signature)
        var notes: [ContainerNote] = []
        var dropped: [String: (count: Int, bytes: Int)] = [:]
        var pos = 8
        var sawEnd = false
        var wroteExif = false
        // With no color chunk, a decoder takes the color space from Exif.
        let hasColorChunk = !Set(try chunkTypes(input)).isDisjoint(with: ["iCCP", "sRGB", "cICP"])

        while pos < b.count {
            let length = try b.be32(pos)
            let type = try b.fourCC(pos + 4)
            let total = 12 + length
            try b.check(pos, total)

            if type == "iCCP", let clean = try? cleanProfileChunk(b, at: pos, length: length, notes: &notes) {
                out.append(clean)
            } else if allowed.contains(type) {
                out.append(try b.copy(pos, total))
            } else if type == "eXIf" {
                let facts = TinyTIFF.read(try b.copy(pos + 8, length))
                dropped[type, default: (0, 0)].count += 1
                dropped[type, default: (0, 0)].bytes += total
                let keepColor = facts.colorSpace != nil && !hasColorChunk
                if (facts.orientation ?? 1) != 1 || keepColor, !wroteExif {
                    var only = ExifFacts()
                    only.orientation = facts.orientation
                    if keepColor { only.colorSpace = facts.colorSpace }
                    let block = TinyTIFF.minimalBlock(only)
                    out.append(chunk("eXIf", block))
                    wroteExif = true
                    notes.append(ContainerNote("eXIf (new)", keepColor ? "orientation and color space only" : "orientation only", bytes: block.count + 12, .rewritten))
                }
            } else if let first = type.unicodeScalars.first, first.value & 0x20 == 0 {
                // An unknown critical chunk: a decoder cannot show the picture
                // without it, so this file is not one to edit at the byte level.
                throw ScrubError.unsupported("PNG with critical chunk \(type)")
            } else {
                dropped[type, default: (0, 0)].count += 1
                dropped[type, default: (0, 0)].bytes += total
            }
            pos += total
            if type == "IEND" { sawEnd = true; break }
        }
        guard sawEnd else { throw ScrubError.malformed("PNG has no end chunk") }

        for (type, tally) in dropped.sorted(by: { $0.key < $1.key }) {
            let label = tally.count > 1 ? "\(type) ×\(tally.count)" : type
            notes.append(ContainerNote(label, reasons[type] ?? "private chunk", bytes: tally.bytes, .removed))
        }
        if pos < b.count {
            notes.append(ContainerNote("Trailer", "data after the end of the picture", bytes: b.count - pos, .removed))
        }
        return Result(data: out, notes: notes)
    }

    /// Chunk types of a PNG, in order, plus "TRAILER" when bytes follow IEND.
    static func chunkTypes(_ input: Data) throws -> [String] {
        let b = Bytes(input)
        guard isPNG(input) else { throw ScrubError.malformed("no PNG signature") }
        var types: [String] = []
        var pos = 8
        while pos < b.count {
            let length = try b.be32(pos)
            let type = try b.fourCC(pos + 4)
            try b.check(pos, 12 + length)
            types.append(type)
            pos += 12 + length
            if type == "IEND" { break }
        }
        if pos < b.count { types.append("TRAILER") }
        return types
    }

    /// Problems in an output file. An empty list is a pass.
    static func audit(_ data: Data) -> [String] {
        guard let types = try? chunkTypes(data) else { return ["the output does not parse as PNG"] }
        var problems: [String] = []
        for type in types where !allowed.contains(type) && type != "eXIf" { problems.append("chunk \(type)") }
        if let exif = exifBlock(data), exif.count > 64 { problems.append("Exif chunk holds \(exif.count) bytes") }
        return problems
    }

    /// The Exif TIFF block of a PNG, if it has one.
    static func exifBlock(_ input: Data) -> Data? {
        let b = Bytes(input)
        var pos = 8
        while pos < b.count {
            guard let length = try? b.be32(pos), let type = try? b.fourCC(pos + 4), (try? b.check(pos, 12 + length)) != nil else { return nil }
            if type == "eXIf" { return try? b.copy(pos + 8, length) }
            if type == "IEND" { return nil }
            pos += 12 + length
        }
        return nil
    }

    /// The iCCP chunk with the profile date and checksum set to zero. It
    /// throws when the profile needs no change or does not decompress, and the
    /// caller then copies the chunk as it is.
    private static func cleanProfileChunk(_ b: Bytes, at pos: Int, length: Int, notes: inout [ContainerNote]) throws -> Data {
        let start = pos + 8
        let (name, afterName) = try b.cString(at: start, limit: start + min(length, 80))
        guard afterName + 1 <= start + length, try b.u8(afterName) == 0 else { throw ScrubError.unsupported("profile compression") }
        let packed = try b.copy(afterName + 1, start + length - afterName - 1)
        guard let profile = ICC.inflate(packed), let note = ICC.note(for: profile, where: ""), let clean = ICC.sanitized(profile),
              let repacked = ICC.deflate(clean) else { throw ScrubError.unsupported("profile needs no change") }
        notes.append(note)
        var payload = Data(name.utf8)
        payload.append(contentsOf: [0, 0])
        payload.append(repacked)
        return chunk("iCCP", payload)
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var body = Data(type.utf8)
        body.append(payload)
        let crc = body.withUnsafeBytes { raw -> UInt in
            UInt(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
        var out = Data()
        out.appendBE32(payload.count)
        out.append(body)
        out.appendBE32(Int(crc))
        return out
    }
}
