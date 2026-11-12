import Foundation

/// The small set of Exif values that change how a picture renders. Everything
/// else in an Exif block describes the camera, the place or the time.
struct ExifFacts {
    /// A raw IFD entry from the Apple MakerNote, kept in big-endian form.
    struct AppleEntry {
        let tag: Int
        let type: Int
        let count: Int
        let value: Data
    }

    var orientation: Int?
    var colorSpace: Int?
    var interopIndex: Data?
    var chromaPositioning: Int?
    /// Apple MakerNote tags 0x21 and 0x30. Older iPhone HDR pictures need
    /// these two numbers to compute the gain map headroom.
    var appleHDR: [AppleEntry] = []
    var hasGPS = false
    var thumbnailBytes = 0
    var makerNoteBytes = 0
}

enum TinyTIFF {
    private static let typeSize: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]

    /// Reads the facts from a TIFF block (the Exif payload after "Exif\0\0").
    /// It never throws: a damaged block gives the facts found up to the damage.
    static func read(_ tiff: Data) -> ExifFacts {
        var facts = ExifFacts()
        try? parse(Bytes(tiff), into: &facts)
        return facts
    }

    private static func parse(_ b: Bytes, into facts: inout ExifFacts) throws {
        let little: Bool
        if b.hasPrefix([0x49, 0x49], at: 0) { little = true }
        else if b.hasPrefix([0x4D, 0x4D], at: 0) { little = false }
        else { return }
        func r16(_ o: Int) throws -> Int { little ? try b.le16(o) : try b.be16(o) }
        func r32(_ o: Int) throws -> Int { little ? try b.le32(o) : try b.be32(o) }

        /// Calls `visit` with (tag, type, count, offset of the 4-byte value field).
        /// Returns the offset of the next IFD.
        func walk(_ ifd: Int, _ visit: (Int, Int, Int, Int) throws -> Void) throws -> Int {
            let n = try r16(ifd)
            guard n <= 512 else { return 0 }
            for i in 0..<n {
                let e = ifd + 2 + 12 * i
                try visit(try r16(e), try r16(e + 2), try r32(e + 4), e + 8)
            }
            return try r32(ifd + 2 + 12 * n)
        }

        var exifIFD = 0
        let ifd1 = try walk(try r32(4)) { tag, _, _, v in
            switch tag {
            case 0x0112: facts.orientation = try r16(v)
            case 0x0213: facts.chromaPositioning = try r16(v)
            case 0x8769: exifIFD = try r32(v)
            case 0x8825: facts.hasGPS = true
            default: break
            }
        }
        if ifd1 != 0 {
            _ = try? walk(ifd1) { tag, _, _, v in
                if tag == 0x0202 { facts.thumbnailBytes = try r32(v) }
            }
        }
        guard exifIFD != 0 else { return }

        var interopIFD = 0
        var makerNote = (offset: 0, length: 0)
        _ = try walk(exifIFD) { tag, _, count, v in
            switch tag {
            case 0xA001: facts.colorSpace = try r16(v)
            case 0xA005: interopIFD = try r32(v)
            case 0x927C: makerNote = (try r32(v), count)
            default: break
            }
        }
        if interopIFD != 0 {
            _ = try? walk(interopIFD) { tag, type, count, v in
                if tag == 0x0001, type == 2, count <= 4 { facts.interopIndex = try b.copy(v, 4) }
            }
        }
        if makerNote.length > 0 {
            facts.makerNoteBytes = makerNote.length
            try? readAppleMakerNote(b, at: makerNote.offset, into: &facts)
        }
    }

    private static func readAppleMakerNote(_ b: Bytes, at mn: Int, into facts: inout ExifFacts) throws {
        guard b.hasPrefix(Array("Apple iOS".utf8) + [0], at: mn), b.hasPrefix([0x4D, 0x4D], at: mn + 12) else { return }
        let n = try b.be16(mn + 14)
        guard n <= 256 else { return }
        for i in 0..<n {
            let e = mn + 16 + 12 * i
            let tag = try b.be16(e)
            guard tag == 0x21 || tag == 0x30 else { continue }
            let type = try b.be16(e + 2)
            let count = try b.be32(e + 4)
            guard let unit = typeSize[type], count >= 1, count <= 4 else { continue }
            let size = unit * count
            let value = size <= 4 ? try b.copy(e + 8, size) : try b.copy(mn + (try b.be32(e + 8)), size)
            facts.appleHDR.append(.init(tag: tag, type: type, count: count, value: value))
        }
    }

    // MARK: - Writer

    /// A big-endian TIFF block that holds only rendering facts.
    /// - Parameter jpegSize: the pixel size of a JPEG. When it is given, the
    ///   block also holds the fields that the Exif standard requires in a
    ///   JPEG (version, component order, color space, pixel size), so the
    ///   result passes a standards check.
    static func minimalBlock(_ facts: ExifFacts, jpegSize: (width: Int, height: Int)? = nil) -> Data {
        let makerNote = appleMakerNote(facts.appleHDR)
        let full = jpegSize != nil
        let wantInterop = facts.interopIndex != nil && full

        var ifd0: [(tag: Int, type: Int, count: Int, value: Data)] = []
        var exif: [(tag: Int, type: Int, count: Int, value: Data)] = []

        if full {
            exif.append((0x9000, 7, 4, Data("0232".utf8)))
            exif.append((0x9101, 7, 4, Data([1, 2, 3, 0])))
        }
        if makerNote != nil { exif.append((0x927C, 7, makerNote!.count, Data())) }
        if full || facts.colorSpace != nil { exif.append((0xA001, 3, 1, Data.be(facts.colorSpace ?? 1, size: 2))) }
        if let size = jpegSize {
            exif.append((0xA002, 4, 1, Data.be(size.width, size: 4)))
            exif.append((0xA003, 4, 1, Data.be(size.height, size: 4)))
        }
        if wantInterop { exif.append((0xA005, 4, 1, Data())) }

        ifd0.append((0x0112, 3, 1, Data.be(facts.orientation ?? 1, size: 2)))
        if full { ifd0.append((0x0213, 3, 1, Data.be(facts.chromaPositioning ?? 1, size: 2))) }
        if !exif.isEmpty { ifd0.append((0x8769, 4, 1, Data())) }

        let ifd0At = 8
        let exifAt = ifd0At + 2 + 12 * ifd0.count + 4
        let interopAt = exifAt + (exif.isEmpty ? 0 : 2 + 12 * exif.count + 4)
        let makerNoteAt = interopAt + (wantInterop ? 2 + 12 * 2 + 4 : 0)

        var out = Data([0x4D, 0x4D, 0x00, 0x2A])
        out.appendBE32(ifd0At)

        func write(_ entries: [(tag: Int, type: Int, count: Int, value: Data)]) {
            out.appendBE16(entries.count)
            for e in entries {
                out.appendBE16(e.tag)
                out.appendBE16(e.type)
                out.appendBE32(e.count)
                var field: Data
                switch e.tag {
                case 0x8769: field = Data.be(exifAt, size: 4)
                case 0xA005: field = Data.be(interopAt, size: 4)
                case 0x927C: field = Data.be(makerNoteAt, size: 4)
                default: field = e.value
                }
                while field.count < 4 { field.append(0) }
                out.append(field.prefix(4))
            }
            out.appendBE32(0)
        }

        write(ifd0)
        if !exif.isEmpty { write(exif) }
        if wantInterop, let index = facts.interopIndex {
            write([(0x0001, 2, 4, index), (0x0002, 7, 4, Data("0100".utf8))])
        }
        if let mn = makerNote { out.append(mn) }
        return out
    }

    /// An Apple MakerNote with only the HDR headroom entries, or nil.
    private static func appleMakerNote(_ entries: [ExifFacts.AppleEntry]) -> Data? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.tag < $1.tag }
        var out = Data("Apple iOS".utf8)
        out.append(contentsOf: [0x00, 0x00, 0x01, 0x4D, 0x4D])
        out.appendBE16(sorted.count)
        var dataAt = 16 + 12 * sorted.count + 4
        var tail = Data()
        for e in sorted {
            out.appendBE16(e.tag)
            out.appendBE16(e.type)
            out.appendBE32(e.count)
            if e.value.count <= 4 {
                var field = e.value
                while field.count < 4 { field.append(0) }
                out.append(field)
            } else {
                out.appendBE32(dataAt)
                tail.append(e.value)
                dataAt += e.value.count
            }
        }
        out.appendBE32(0)
        out.append(tail)
        return out
    }
}
