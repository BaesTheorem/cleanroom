import Foundation

/// Lossless JPEG scrub. It copies the compressed picture data byte for byte and
/// rebuilds the list of header segments from an allowlist.
enum JPEG {
    struct Result {
        var data: Data
        var notes: [ContainerNote]
    }

    private struct Segment {
        let marker: Int
        let range: Range<Int>
        var payload: Range<Int> { (range.lowerBound + 4)..<range.upperBound }
    }

    private static let exifID = Array("Exif".utf8) + [0, 0]
    private static let xmpID = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    private static let iccID = Array("ICC_PROFILE".utf8) + [0]
    private static let mpfID = Array("MPF".utf8) + [0]
    private static let isoGainMapID = Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0]
    private static let jfifID = Array("JFIF".utf8) + [0]
    private static let adobeID = Array("Adobe".utf8)

    static func isJPEG(_ data: Data) -> Bool {
        Bytes(data).hasPrefix([0xFF, 0xD8, 0xFF], at: 0)
    }

    /// - Parameter gainMap: true when `input` is an HDR gain map image taken
    ///   from the trailer of a primary picture. Its XMP stays if it only
    ///   describes the gain map.
    /// - Parameter impliedProfile: the color profile the decoder assigns to
    ///   this picture from its Exif tags. When the file carries no profile of
    ///   its own, this one goes in, so the colors do not depend on the tags.
    static func strip(_ input: Data, gainMap: Bool = false, impliedProfile: Data? = nil) throws -> Result {
        let b = Bytes(input)
        guard isJPEG(input) else { throw ScrubError.malformed("no JPEG start marker") }

        // 1. Header segments, up to the first scan.
        var header: [Segment] = []
        var pos = 2
        while true {
            let marker = try markerAt(b, &pos)
            if marker == 0xDA || marker == 0xD9 { break }
            if isStandalone(marker) {
                header.append(Segment(marker: marker, range: pos..<(pos + 2)))
                pos += 2
                continue
            }
            let length = try b.be16(pos + 2)
            guard length >= 2 else { throw ScrubError.malformed("segment length \(length) at \(pos)") }
            try b.check(pos, 2 + length)
            header.append(Segment(marker: marker, range: pos..<(pos + 2 + length)))
            pos += 2 + length
        }

        // 2. Scans, up to the end marker. Tables between scans stay, and
        //    application or comment segments between scans go.
        var body: [Range<Int>] = []
        var notes: [ContainerNote] = []
        var imageEnd = b.count
        var hasEnd = false
        while pos < b.count - 1 {
            let marker = try markerAt(b, &pos)
            if marker == 0xD9 {
                body.append(pos..<(pos + 2))
                imageEnd = pos + 2
                hasEnd = true
                break
            }
            if isStandalone(marker) {
                body.append(pos..<(pos + 2))
                pos += 2
                continue
            }
            let length = try b.be16(pos + 2)
            guard length >= 2 else { throw ScrubError.malformed("segment length \(length) at \(pos)") }
            try b.check(pos, 2 + length)
            let end = pos + 2 + length
            if marker == 0xDA {
                let next = endOfScan(input, from: end)
                body.append(pos..<next)
                pos = next
            } else if isApplicationOrComment(marker) {
                notes.append(ContainerNote(name(marker), "segment between scans", bytes: 2 + length, .removed))
                pos = end
            } else {
                body.append(pos..<end)
                pos = end
            }
        }
        guard !body.isEmpty else { throw ScrubError.malformed("no picture data") }

        // 3. Decide the fate of each header segment.
        var facts = ExifFacts()
        var hasICC = false
        var mpfSegment: Segment?
        var seenExif = false
        enum Plan { case keep(Range<Int>), exifSlot, mpfSlot, isoGainMap(Range<Int>), jfif(Data), icc(Int), newProfile }
        var plan: [Plan] = []
        var iccChunks: [(sequence: Int, total: Int, body: Range<Int>)] = []
        var pixelSize: (width: Int, height: Int)?

        for seg in header {
            let size = seg.range.count
            if isStandalone(seg.marker) {
                plan.append(.keep(seg.range))
                continue
            }
            let p = seg.payload.lowerBound
            switch seg.marker {
            case 0xE0:
                if b.hasPrefix(jfifID, at: p) {
                    let (clean, thumb) = try jfifWithoutThumbnail(b, seg)
                    plan.append(.jfif(clean))
                    if thumb > 0 { notes.append(ContainerNote("APP0 JFIF thumbnail", "a small copy of the picture", bytes: thumb, .removed)) }
                } else {
                    notes.append(ContainerNote("APP0 extension", "JFXX thumbnail or vendor data", bytes: size, .removed))
                }
            case 0xE1:
                if b.hasPrefix(exifID, at: p) {
                    if !seenExif {
                        seenExif = true
                        facts = TinyTIFF.read(try b.copy(p + 6, seg.payload.count - 6))
                        plan.append(.exifSlot)
                    }
                    notes.append(ContainerNote("APP1 Exif", exifSummary(facts), bytes: size, .removed))
                } else if b.hasPrefix(xmpID, at: p) {
                    let packet = try b.copy(p + xmpID.count, seg.payload.count - xmpID.count)
                    if gainMap, XMP.describesOnlyGainMap(packet) {
                        plan.append(.keep(seg.range))
                        notes.append(ContainerNote("APP1 XMP", "gain map parameters only", bytes: size, .kept))
                    } else {
                        notes.append(ContainerNote("APP1 XMP", XMP.summary(packet), bytes: size, .removed))
                    }
                } else {
                    notes.append(ContainerNote("APP1", "extended XMP or vendor data", bytes: size, .removed))
                }
            case 0xE2:
                if b.hasPrefix(iccID, at: p), seg.payload.count > 14 {
                    hasICC = true
                    plan.append(.icc(iccChunks.count))
                    iccChunks.append((try b.u8(p + 12), try b.u8(p + 13), (p + 14)..<seg.payload.upperBound))
                } else if b.hasPrefix(mpfID, at: p) {
                    if mpfSegment == nil {
                        mpfSegment = seg
                        plan.append(.mpfSlot)
                    }
                } else if b.hasPrefix(isoGainMapID, at: p) {
                    plan.append(.isoGainMap(seg.range))
                } else {
                    notes.append(ContainerNote("APP2", "FlashPix or vendor data", bytes: size, .removed))
                }
            case 0xEE:
                if b.hasPrefix(adobeID, at: p) {
                    plan.append(.keep(seg.range))
                } else {
                    notes.append(ContainerNote("APP14", "vendor data", bytes: size, .removed))
                }
            case 0xE3...0xEF:
                notes.append(ContainerNote(name(seg.marker), appDescription(b, seg), bytes: size, .removed))
            case 0xFE:
                notes.append(ContainerNote("COM", "text comment", bytes: size, .removed))
            default:
                // A frame header gives the pixel size.
                if (0xC0...0xCF).contains(seg.marker), ![0xC4, 0xC8, 0xCC].contains(seg.marker), seg.payload.count >= 5 {
                    pixelSize = (try b.be16(p + 3), try b.be16(p + 1))
                }
                plan.append(.keep(seg.range))
            }
        }

        // 4. Gain maps in the trailer. A gain map is picture data: without it
        //    an HDR picture renders flat.
        var gainMaps: [Data] = []
        let trailer = imageEnd..<b.count
        if !gainMap, let mpf = mpfSegment {
            let found = try secondaryImages(b, mpf: mpf)
            for (index, range) in found.enumerated() {
                guard range.lowerBound >= imageEnd, range.upperBound <= b.count, range.count > 4 else { continue }
                let sub = try b.copy(range.lowerBound, range.count)
                if isJPEG(sub), isGainMapImage(sub), let clean = try? strip(sub, gainMap: true) {
                    gainMaps.append(clean.data)
                    notes.append(ContainerNote("HDR gain map", "second picture that holds the highlight data", bytes: clean.data.count, .kept))
                    // The profile note of a gain map names the capture time, so it gets its own line.
                    let profileNotes = clean.notes.filter { $0.item.hasPrefix("Color profile") }
                    notes.append(contentsOf: profileNotes)
                    let dropped = clean.notes.filter { $0.action == .removed && !$0.item.hasPrefix("Color profile") }.reduce(0) { $0 + $1.bytes }
                    if dropped > 0 { notes.append(ContainerNote("HDR gain map segments", "vendor data inside the gain map", bytes: dropped, .removed)) }
                } else {
                    notes.append(ContainerNote("Secondary picture \(index + 2)", "depth map, matte or large preview", bytes: range.count, .removed))
                }
            }
        }
        let keptFromTrailer = gainMaps.reduce(0) { $0 + $1.count }
        if trailer.count > 0, gainMaps.isEmpty {
            notes.append(ContainerNote("Trailer", "data after the end of the picture", bytes: trailer.count, .removed))
        } else if trailer.count > keptFromTrailer, !gainMaps.isEmpty {
            // Sizes differ when a secondary picture or its tags went. No separate note.
        }

        // 5. Build the output.
        if gainMaps.isEmpty { facts.appleHDR = [] }
        var embed: Data?
        if !hasICC, !gainMap, let implied = impliedProfile, implied.count > 132, implied.count < 65_000 {
            embed = ICC.sanitized(implied) ?? implied
            hasICC = true
            let lead = plan.prefix { step in
                switch step {
                case .jfif, .exifSlot: return true
                default: return false
                }
            }.count
            plan.insert(.newProfile, at: lead)
        }
        // Exif stays only when the picture renders differently without it:
        // a rotation, HDR headroom, or a color space with no profile to say it.
        let needsExif = !gainMap && seenExif
            && ((facts.orientation ?? 1) != 1 || !facts.appleHDR.isEmpty || (!hasICC && (facts.colorSpace ?? 1) != 1))
        if facts.colorSpace == nil { facts.colorSpace = hasICC ? 0xFFFF : 1 }

        // The color profile, with its date and checksum set to zero.
        var cleanICC: [Int: Data] = [:]
        let ordered = iccChunks.enumerated().sorted { $0.element.sequence < $1.element.sequence }
        if !ordered.isEmpty, ordered.map(\.element.sequence) == Array(1...ordered.count) {
            var profile = Data()
            for chunk in ordered { profile.append(try b.copy(chunk.element.body.lowerBound, chunk.element.body.count)) }
            if let note = ICC.note(for: profile, where: gainMap ? " (gain map)" : ""), let clean = ICC.sanitized(profile) {
                notes.append(note)
                var at = 0
                for chunk in ordered {
                    cleanICC[chunk.offset] = clean.subdata(in: at..<(at + chunk.element.body.count))
                    at += chunk.element.body.count
                }
            }
        }

        var out = Data(capacity: input.count)
        out.append(contentsOf: [0xFF, 0xD8])
        var mpfBase = -1
        var mpfEntriesAt = -1
        for step in plan {
            switch step {
            case .keep(let range):
                out.append(try b.copy(range.lowerBound, range.count))
            case .jfif(let clean):
                out.append(clean)
            case .newProfile:
                guard let profile = embed else { continue }
                var payload = Data(iccID)
                payload.append(contentsOf: [1, 1])
                payload.append(profile)
                out.append(segment(0xE2, payload))
                notes.append(ContainerNote("APP2 color profile (new)", "the camera named its color space only in the Exif tags, so the profile now travels with the picture", bytes: payload.count + 4, .rewritten))
            case .icc(let index):
                let chunk = iccChunks[index]
                if let clean = cleanICC[index] {
                    var payload = Data(iccID)
                    payload.append(contentsOf: [UInt8(chunk.sequence), UInt8(chunk.total)])
                    payload.append(clean)
                    out.append(segment(0xE2, payload))
                } else {
                    let start = chunk.body.lowerBound - 18
                    out.append(try b.copy(start, chunk.body.upperBound - start))
                }
            case .exifSlot:
                guard needsExif else { continue }
                var payload = Data(exifID)
                payload.append(TinyTIFF.minimalBlock(facts, jpegSize: pixelSize))
                out.append(segment(0xE1, payload))
                var keptWhat: [String] = []
                keptWhat.append("orientation")
                keptWhat.append("pixel size")
                keptWhat.append("color space")
                if !facts.appleHDR.isEmpty { keptWhat.append("HDR headroom") }
                notes.append(ContainerNote("APP1 Exif (new)", keptWhat.joined(separator: ", ") + ", and nothing else", bytes: payload.count + 4, .rewritten))
            case .mpfSlot:
                guard !gainMaps.isEmpty else {
                    notes.append(ContainerNote("APP2 MPF", "index of the secondary pictures", bytes: mpfSegment?.range.count ?? 0, .removed))
                    continue
                }
                let (payload, entriesOffset) = mpfIndex(count: 1 + gainMaps.count)
                mpfBase = out.count + 4 + 4
                mpfEntriesAt = out.count + 4 + entriesOffset
                out.append(segment(0xE2, payload))
            case .isoGainMap(let range):
                if gainMap || !gainMaps.isEmpty {
                    out.append(try b.copy(range.lowerBound, range.count))
                } else {
                    notes.append(ContainerNote("APP2 gain map marker", "HDR marker with no gain map to go with it", bytes: range.count, .removed))
                }
            }
        }
        for range in body { out.append(try b.copy(range.lowerBound, range.count)) }
        if !hasEnd { out.append(contentsOf: [0xFF, 0xD9]) }

        if !gainMaps.isEmpty, mpfBase > 0 {
            var entries = Data()
            entries.append(mpEntry(attribute: 0x0003_0000, size: out.count, offset: 0))
            var at = out.count
            for map in gainMaps {
                entries.append(mpEntry(attribute: 0, size: map.count, offset: at - mpfBase))
                at += map.count
            }
            out.replaceSubrange(mpfEntriesAt..<(mpfEntriesAt + entries.count), with: entries)
            for map in gainMaps { out.append(map) }
            notes.append(ContainerNote("APP2 MPF (new)", "index of the picture and its gain map", bytes: 16 * (1 + gainMaps.count) + 54, .rewritten))
        }
        return Result(data: out, notes: notes)
    }

    // MARK: - Walk of the output (used by verification)

    /// Names every segment of a JPEG, in order. The verifier uses it to check
    /// an output file against the allowlist.
    static func segmentNames(_ input: Data) throws -> [String] {
        let b = Bytes(input)
        guard isJPEG(input) else { throw ScrubError.malformed("no JPEG start marker") }
        var names: [String] = []
        var pos = 2
        while pos < b.count - 1 {
            let marker = try markerAt(b, &pos)
            if marker == 0xD9 {
                pos += 2
                if pos < b.count { names.append("TRAILER") }
                break
            }
            if isStandalone(marker) { pos += 2; continue }
            let length = try b.be16(pos + 2)
            try b.check(pos, 2 + length)
            let p = pos + 4
            switch marker {
            case 0xE0: names.append(b.hasPrefix(jfifID, at: p) ? "JFIF" : "APP0?")
            case 0xE1: names.append(b.hasPrefix(exifID, at: p) ? "EXIF" : (b.hasPrefix(xmpID, at: p) ? "XMP" : "APP1?"))
            case 0xE2:
                if b.hasPrefix(iccID, at: p) { names.append("ICC") }
                else if b.hasPrefix(mpfID, at: p) { names.append("MPF") }
                else if b.hasPrefix(isoGainMapID, at: p) { names.append("ISOGAINMAP") }
                else { names.append("APP2?") }
            case 0xEE: names.append(b.hasPrefix(adobeID, at: p) ? "ADOBE" : "APP14?")
            case 0xE3...0xEF: names.append("APP\(marker - 0xE0)?")
            case 0xFE: names.append("COM")
            default: break
            }
            pos += 2 + length
            if marker == 0xDA { pos = endOfScan(input, from: pos) }
        }
        return names
    }

    /// Problems in an output file. An empty list is a pass.
    static func audit(_ data: Data) -> [String] {
        guard let names = try? segmentNames(data) else { return ["the output does not parse as JPEG"] }
        var problems: [String] = []
        let allowed: Set<String> = ["JFIF", "EXIF", "ICC", "ADOBE", "MPF", "ISOGAINMAP", "TRAILER"]
        for name in names where !allowed.contains(name) { problems.append("segment \(name)") }
        if let exif = exifBlock(data), exif.count > 256 { problems.append("Exif block holds \(exif.count) bytes") }
        if names.contains("TRAILER") {
            let b = Bytes(data)
            guard names.contains("MPF"), let mpf = try? firstSegment(b, marker: 0xE2, id: mpfID),
                  let images = try? secondaryImages(b, mpf: mpf), !images.isEmpty else {
                return problems + ["data after the end of the picture"]
            }
            var covered = 0
            let inner: Set<String> = ["JFIF", "XMP", "ICC", "ADOBE", "ISOGAINMAP"]
            for range in images {
                guard range.upperBound <= b.count, let sub = try? b.copy(range.lowerBound, range.count), let subNames = try? segmentNames(sub) else {
                    problems.append("secondary picture cannot be read")
                    continue
                }
                covered += range.count
                for name in subNames where !inner.contains(name) { problems.append("gain map segment \(name)") }
                if subNames.contains("XMP"), !isGainMapImage(sub) { problems.append("gain map XMP holds other data") }
            }
            if let end = try? primaryEnd(b), end + covered != b.count { problems.append("unindexed data after the picture") }
        }
        return problems
    }

    private static func firstSegment(_ b: Bytes, marker wanted: Int, id: [UInt8]) throws -> Segment? {
        var pos = 2
        while pos < b.count - 1 {
            let marker = try markerAt(b, &pos)
            if marker == 0xDA || marker == 0xD9 { return nil }
            if isStandalone(marker) { pos += 2; continue }
            let length = try b.be16(pos + 2)
            try b.check(pos, 2 + length)
            if marker == wanted, b.hasPrefix(id, at: pos + 4) { return Segment(marker: marker, range: pos..<(pos + 2 + length)) }
            pos += 2 + length
        }
        return nil
    }

    /// The offset just after the end marker of the first picture.
    private static func primaryEnd(_ b: Bytes) throws -> Int {
        var pos = 2
        while pos < b.count - 1 {
            let marker = try markerAt(b, &pos)
            if marker == 0xD9 { return pos + 2 }
            if isStandalone(marker) { pos += 2; continue }
            let length = try b.be16(pos + 2)
            try b.check(pos, 2 + length)
            pos += 2 + length
            if marker == 0xDA { pos = endOfScan(b.data, from: pos) }
        }
        return b.count
    }

    /// The Exif TIFF block of a JPEG, if it has one.
    static func exifBlock(_ input: Data) -> Data? {
        let b = Bytes(input)
        var pos = 2
        while pos < b.count - 1 {
            guard let marker = try? markerAt(b, &pos), marker != 0xDA, marker != 0xD9 else { return nil }
            if isStandalone(marker) { pos += 2; continue }
            guard let length = try? b.be16(pos + 2), (try? b.check(pos, 2 + length)) != nil else { return nil }
            if marker == 0xE1, b.hasPrefix(exifID, at: pos + 4) { return try? b.copy(pos + 10, length - 8) }
            pos += 2 + length
        }
        return nil
    }

    // MARK: - Pieces

    /// Moves `pos` to the next marker and returns its code. Fill bytes (0xFF
    /// repeated) are legal before a marker.
    private static func markerAt(_ b: Bytes, _ pos: inout Int) throws -> Int {
        guard try b.u8(pos) == 0xFF else { throw ScrubError.malformed("no marker at \(pos)") }
        while try b.u8(pos + 1) == 0xFF { pos += 1 }
        return try b.u8(pos + 1)
    }

    private static func isStandalone(_ marker: Int) -> Bool {
        marker == 0x01 || (0xD0...0xD8).contains(marker)
    }

    private static func isApplicationOrComment(_ marker: Int) -> Bool {
        (0xE0...0xEF).contains(marker) || marker == 0xFE
    }

    private static func name(_ marker: Int) -> String {
        (0xE0...0xEF).contains(marker) ? "APP\(marker - 0xE0)" : (marker == 0xFE ? "COM" : String(format: "marker %02X", marker))
    }

    /// The offset of the first marker after compressed scan data. Inside a
    /// scan, 0xFF00 is a data byte and 0xFFD0 to 0xFFD7 are restart markers.
    private static func endOfScan(_ data: Data, from: Int) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let n = raw.count
            var i = from
            while i < n - 1 {
                guard let hit = memchr(base + i, 0xFF, n - 1 - i) else { return n }
                i = base.distance(to: UnsafeRawPointer(hit))
                let next = raw[i + 1]
                if next == 0x00 || (next >= 0xD0 && next <= 0xD7) { i += 2; continue }
                if next == 0xFF { i += 1; continue }
                return i
            }
            return n
        }
    }

    private static func segment(_ marker: Int, _ payload: Data) -> Data {
        var out = Data([0xFF, UInt8(marker)])
        out.appendBE16(payload.count + 2)
        out.append(payload)
        return out
    }

    /// A JFIF header can carry an uncompressed thumbnail. This returns the
    /// segment without it, and the number of bytes that went.
    private static func jfifWithoutThumbnail(_ b: Bytes, _ seg: Segment) throws -> (Data, Int) {
        let p = seg.payload.lowerBound
        guard seg.payload.count >= 14 else { return (try b.copy(seg.range.lowerBound, seg.range.count), 0) }
        let thumb = seg.payload.count - 14
        guard thumb > 0 else { return (try b.copy(seg.range.lowerBound, seg.range.count), 0) }
        var payload = try b.copy(p, 12)
        payload.append(contentsOf: [0, 0])
        return (segment(0xE0, payload), thumb)
    }

    private static func exifSummary(_ f: ExifFacts) -> String {
        var parts = ["camera and capture tags"]
        if f.hasGPS { parts.append("GPS") }
        if f.makerNoteBytes > 0 { parts.append("maker note (\(f.makerNoteBytes) bytes)") }
        if f.thumbnailBytes > 0 { parts.append("thumbnail (\(f.thumbnailBytes) bytes)") }
        return parts.joined(separator: ", ")
    }

    private static func appDescription(_ b: Bytes, _ seg: Segment) -> String {
        let p = seg.payload.lowerBound
        let known: [(String, String)] = [
            ("AROT", "Apple rotation table"), ("JP", "JUMBF box (content credentials)"), ("Photoshop", "Photoshop and IPTC data"),
            ("Ducky", "Photoshop save settings"), ("Adobe_CM", "Adobe color data"), ("GoPro", "GoPro data"),
        ]
        for (id, text) in known where b.hasPrefix(Array(id.utf8), at: p) { return text }
        return "vendor data"
    }

    // MARK: - Multi-Picture Format (CIPA DC-007)

    /// File ranges of the pictures after the first one, from the MP index.
    private static func secondaryImages(_ b: Bytes, mpf: Segment) throws -> [Range<Int>] {
        let base = mpf.payload.lowerBound + 4
        let end = mpf.payload.upperBound
        let little = b.hasPrefix([0x49, 0x49], at: base)
        guard little || b.hasPrefix([0x4D, 0x4D], at: base) else { return [] }
        func r16(_ o: Int) throws -> Int { little ? try b.le16(o) : try b.be16(o) }
        func r32(_ o: Int) throws -> Int { little ? try b.le32(o) : try b.be32(o) }
        let ifd = base + (try r32(base + 4))
        let n = try r16(ifd)
        guard n <= 16 else { return [] }
        var ranges: [Range<Int>] = []
        for i in 0..<n {
            let e = ifd + 2 + 12 * i
            guard try r16(e) == 0xB002 else { continue }
            let count = try r32(e + 4) / 16
            let at = base + (try r32(e + 8))
            guard count >= 1, count <= 32, at + 16 * count <= end else { return [] }
            for k in 1..<count {
                let size = try r32(at + 16 * k + 4)
                let offset = try r32(at + 16 * k + 8)
                guard size > 0, offset > 0 else { continue }
                ranges.append((base + offset)..<(base + offset + size))
            }
        }
        return ranges
    }

    /// True for a picture that carries gain map parameters: the ISO 21496-1
    /// segment, or XMP with Apple's gain map type.
    private static func isGainMapImage(_ image: Data) -> Bool {
        let b = Bytes(image)
        var pos = 2
        while pos < b.count - 1 {
            guard let marker = try? markerAt(b, &pos), marker != 0xDA, marker != 0xD9 else { return false }
            if isStandalone(marker) { pos += 2; continue }
            guard let length = try? b.be16(pos + 2), (try? b.check(pos, 2 + length)) != nil else { return false }
            let p = pos + 4
            if marker == 0xE2, b.hasPrefix(isoGainMapID, at: p) { return true }
            if marker == 0xE1, b.hasPrefix(xmpID, at: p), let packet = try? b.copy(p + xmpID.count, length - 2 - xmpID.count),
               XMP.describesOnlyGainMap(packet), XMP.text(packet).contains("hdrgainmap") { return true }
            pos += 2 + length
        }
        return false
    }

    /// A new MP index for `count` pictures. Returns the payload and the offset
    /// of the entry table inside it.
    private static func mpfIndex(count: Int) -> (Data, Int) {
        var p = Data(mpfID)
        p.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        p.appendBE32(8)
        p.appendBE16(3)
        p.appendBE16(0xB000); p.appendBE16(7); p.appendBE32(4); p.appendASCII("0100")
        p.appendBE16(0xB001); p.appendBE16(4); p.appendBE32(1); p.appendBE32(count)
        p.appendBE16(0xB002); p.appendBE16(7); p.appendBE32(16 * count); p.appendBE32(50)
        p.appendBE32(0)
        let entriesAt = p.count
        p.append(Data(count: 16 * count))
        return (p, entriesAt)
    }

    private static func mpEntry(attribute: Int, size: Int, offset: Int) -> Data {
        var e = Data()
        e.appendBE32(attribute)
        e.appendBE32(size)
        e.appendBE32(offset)
        e.appendBE32(0)
        return e
    }
}
