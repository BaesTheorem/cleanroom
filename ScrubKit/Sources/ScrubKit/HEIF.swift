import Foundation

/// ISO base media file format boxes (ISO/IEC 14496-12).
enum BMFF {
    struct Box {
        let type: String
        let start: Int
        let headerSize: Int
        let end: Int
        var payload: Int { start + headerSize }
        var size: Int { end - start }
    }

    /// The boxes in the byte range `from..<to`.
    static func boxes(_ b: Bytes, from: Int, to: Int) throws -> [Box] {
        var out: [Box] = []
        var pos = from
        while pos + 8 <= to {
            var size = try b.be32(pos)
            let type = try b.fourCC(pos + 4)
            var header = 8
            if size == 1 {
                size = try b.be64(pos + 8)
                header = 16
            } else if size == 0 {
                size = to - pos
            }
            guard size >= header, size <= to - pos else {
                throw ScrubError.malformed("box \(type) at \(pos) has size \(size)")
            }
            out.append(Box(type: type, start: pos, headerSize: header, end: pos + size))
            pos += size
        }
        return out
    }

    static func brands(_ b: Bytes) -> [String] {
        guard (try? b.fourCC(4)) == "ftyp", let size = try? b.be32(0), size >= 16, size <= b.count else { return [] }
        var out: [String] = []
        if let major = try? b.fourCC(8) { out.append(major) }
        var pos = 16
        while pos + 4 <= size {
            if let brand = try? b.fourCC(pos) { out.append(brand) }
            pos += 4
        }
        return out
    }
}

/// Lossless HEIC, HEIF and AVIF scrub. The picture data and every offset stay
/// where they are. The Exif and XMP items become small blocks that hold only
/// rendering facts, and the bytes they used become zeros.
enum HEIF {
    static let stillBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1", "miaf", "avif", "avis", "jpeg", "j2ki"]

    /// Item types that hold a picture or build one from other items.
    static let pictureTypes: Set<String> = ["hvc1", "hev1", "lhv1", "av01", "avc1", "vvc1", "jpeg", "j2k1", "unci", "grid", "iovl", "iden", "tmap"]

    static let gainMapAuxType = "urn:com:apple:photo:2020:aux:hdrgainmap"

    struct Extent {
        var offset: Int
        var length: Int
        let lengthFieldAt: Int
        let lengthFieldSize: Int
    }

    struct Item {
        let id: Int
        var type = ""
        var name = ""
        var contentType = ""
        var construction = 0
        var dataReference = 0
        var baseOffset = 0
        var extents: [Extent] = []
        var located = false
    }

    struct Reference {
        let type: String
        let from: Int
        let to: [Int]
    }

    struct Layout {
        var top: [BMFF.Box] = []
        var items: [Int: Item] = [:]
        var order: [Int] = []
        var references: [Reference] = []
        var primary: Int?
        var idat: Range<Int>?
        var auxTypes: [Int: String] = [:]
        var iccProfiles: [Range<Int>] = []
    }

    enum Patch {
        case write(Int, Data)
        case zero(Range<Int>)
    }

    struct Plan {
        var patches: [Patch] = []
        var notes: [ContainerNote] = []
    }

    static func isHEIF(_ data: Data) -> Bool {
        let brands = BMFF.brands(Bytes(data))
        return !brands.isEmpty && !stillBrands.isDisjoint(with: brands)
    }

    // MARK: - Parse

    static func parse(_ data: Data) throws -> Layout {
        let b = Bytes(data)
        var layout = Layout()
        layout.top = try BMFF.boxes(b, from: 0, to: b.count)
        guard let meta = layout.top.first(where: { $0.type == "meta" }) else {
            throw ScrubError.unsupported("no meta box")
        }
        if layout.top.contains(where: { $0.type == "moov" }) {
            throw ScrubError.unsupported("picture sequence with a movie box")
        }
        // In HEIF the meta box has a 4-byte version and flags field.
        let children = try BMFF.boxes(b, from: meta.payload + 4, to: meta.end)
        for box in children {
            switch box.type {
            case "pitm":
                let version = try b.u8(box.payload)
                layout.primary = version == 0 ? try b.be16(box.payload + 4) : try b.be32(box.payload + 4)
            case "iinf": try parseItemInfo(b, box, &layout)
            case "iloc": try parseLocations(b, box, &layout)
            case "iref": try parseReferences(b, box, &layout)
            case "iprp": try parseProperties(b, box, &layout)
            case "idat": layout.idat = box.payload..<box.end
            default: break
            }
        }
        return layout
    }

    private static func parseItemInfo(_ b: Bytes, _ box: BMFF.Box, _ layout: inout Layout) throws {
        let version = try b.u8(box.payload)
        let first = box.payload + 4 + (version == 0 ? 2 : 4)
        for entry in try BMFF.boxes(b, from: first, to: box.end) where entry.type == "infe" {
            let v = try b.u8(entry.payload)
            var pos = entry.payload + 4
            let id: Int
            if v == 3 { id = try b.be32(pos); pos += 4 } else { id = try b.be16(pos); pos += 2 }
            pos += 2
            var item = layout.items[id] ?? Item(id: id)
            if v >= 2 {
                item.type = try b.fourCC(pos)
                pos += 4
                (item.name, pos) = try b.cString(at: pos, limit: entry.end)
                if item.type == "mime" { (item.contentType, pos) = try b.cString(at: pos, limit: entry.end) }
            } else {
                (item.name, pos) = try b.cString(at: pos, limit: entry.end)
                (item.contentType, pos) = try b.cString(at: pos, limit: entry.end)
                item.type = "mime"
            }
            if layout.items[id] == nil { layout.order.append(id) }
            layout.items[id] = item
        }
    }

    private static func parseLocations(_ b: Bytes, _ box: BMFF.Box, _ layout: inout Layout) throws {
        let version = try b.u8(box.payload)
        guard version <= 2 else { throw ScrubError.unsupported("item location version \(version)") }
        let sizes = try b.be16(box.payload + 4)
        let offsetSize = sizes >> 12 & 0xF
        let lengthSize = sizes >> 8 & 0xF
        let baseSize = sizes >> 4 & 0xF
        let indexSize = version == 0 ? 0 : sizes & 0xF
        var pos = box.payload + 6
        let count: Int
        if version < 2 { count = try b.be16(pos); pos += 2 } else { count = try b.be32(pos); pos += 4 }
        for _ in 0..<count {
            let id: Int
            if version < 2 { id = try b.be16(pos); pos += 2 } else { id = try b.be32(pos); pos += 4 }
            var item = layout.items[id] ?? Item(id: id)
            if version >= 1 { item.construction = try b.be16(pos) & 0xF; pos += 2 }
            item.dataReference = try b.be16(pos); pos += 2
            item.baseOffset = try b.beUInt(pos, size: baseSize); pos += baseSize
            let extentCount = try b.be16(pos); pos += 2
            item.extents = []
            for _ in 0..<extentCount {
                pos += indexSize
                let offset = try b.beUInt(pos, size: offsetSize); pos += offsetSize
                let length = try b.beUInt(pos, size: lengthSize)
                item.extents.append(Extent(offset: offset, length: length, lengthFieldAt: pos, lengthFieldSize: lengthSize))
                pos += lengthSize
            }
            item.located = true
            if layout.items[id] == nil { layout.order.append(id) }
            layout.items[id] = item
            guard pos <= box.end else { throw ScrubError.malformed("item location table passes its box") }
        }
    }

    private static func parseReferences(_ b: Bytes, _ box: BMFF.Box, _ layout: inout Layout) throws {
        let wide = try b.u8(box.payload) == 1
        let idSize = wide ? 4 : 2
        for ref in try BMFF.boxes(b, from: box.payload + 4, to: box.end) {
            var pos = ref.payload
            let from = try b.beUInt(pos, size: idSize); pos += idSize
            let n = try b.be16(pos); pos += 2
            var to: [Int] = []
            for _ in 0..<n { to.append(try b.beUInt(pos, size: idSize)); pos += idSize }
            layout.references.append(Reference(type: ref.type, from: from, to: to))
        }
    }

    private static func parseProperties(_ b: Bytes, _ box: BMFF.Box, _ layout: inout Layout) throws {
        var properties: [BMFF.Box] = []
        var associations: [(item: Int, indexes: [Int])] = []
        for child in try BMFF.boxes(b, from: box.payload, to: box.end) {
            if child.type == "ipco" {
                properties = try BMFF.boxes(b, from: child.payload, to: child.end)
            } else if child.type == "ipma" {
                let version = try b.u8(child.payload)
                let wideIndex = try b.u8(child.payload + 3) & 1 == 1
                var pos = child.payload + 4
                let count = try b.be32(pos); pos += 4
                for _ in 0..<count {
                    let id: Int
                    if version < 1 { id = try b.be16(pos); pos += 2 } else { id = try b.be32(pos); pos += 4 }
                    let n = try b.u8(pos); pos += 1
                    var indexes: [Int] = []
                    for _ in 0..<n {
                        if wideIndex { indexes.append(try b.be16(pos) & 0x7FFF); pos += 2 }
                        else { indexes.append(try b.u8(pos) & 0x7F); pos += 1 }
                    }
                    associations.append((id, indexes))
                }
            }
        }
        for (item, indexes) in associations {
            for index in indexes where index >= 1 && index <= properties.count {
                let p = properties[index - 1]
                if p.type == "auxC" {
                    let (urn, _) = try b.cString(at: p.payload + 4, limit: p.end)
                    layout.auxTypes[item] = urn
                }
            }
        }
        for p in properties where p.type == "colr" {
            let kind = try b.fourCC(p.payload)
            if kind == "prof" || kind == "rICC" { layout.iccProfiles.append((p.payload + 4)..<p.end) }
        }
    }

    // MARK: - Plan

    /// The absolute file ranges of an item's data.
    static func ranges(of item: Item, in layout: Layout, fileSize: Int) throws -> [Range<Int>] {
        guard item.dataReference == 0 else { throw ScrubError.unsupported("item data in another file") }
        let origin: Int
        switch item.construction {
        case 0: origin = item.baseOffset
        case 1:
            guard let idat = layout.idat else { throw ScrubError.malformed("item in a missing idat box") }
            origin = idat.lowerBound + item.baseOffset
        default: throw ScrubError.unsupported("item built from another item")
        }
        return try item.extents.map { e in
            let range = (origin + e.offset)..<(origin + e.offset + e.length)
            guard range.lowerBound >= 0, range.upperBound <= fileSize else { throw ScrubError.malformed("item \(item.id) passes the end of the file") }
            return range
        }
    }

    static func plan(_ data: Data) throws -> Plan {
        let b = Bytes(data)
        let layout = try parse(data)
        var plan = Plan()
        let auxItems = Set(layout.references.filter { $0.type == "auxl" }.map(\.from))
        let hasGainMap = layout.auxTypes.values.contains { $0.lowercased().contains("gainmap") }
            || layout.items.values.contains { $0.type == "tmap" }
        let described = Dictionary(grouping: layout.references.filter { $0.type == "cdsc" }, by: \.from)

        for id in layout.order {
            guard let item = layout.items[id] else { continue }
            let isXMP = item.type == "mime" && item.contentType.lowercased().contains("rdf+xml")
            let isMetadata = item.type == "Exif" || item.type == "mime" || item.type == "uri " || described[id] != nil
            if !isMetadata {
                guard pictureTypes.contains(item.type) else { throw ScrubError.unsupported("item type '\(item.type)'") }
                continue
            }
            if pictureTypes.contains(item.type) { continue }
            guard item.located else { continue }
            let spans = try ranges(of: item, in: layout, fileSize: b.count)
            let total = spans.reduce(0) { $0 + $1.count }
            guard let first = spans.first, total > 0 else { continue }
            let old = try spans.reduce(into: Data()) { $0.append(try b.copy($1.lowerBound, $1.count)) }

            var replacement = Data()
            var label = item.type == "Exif" ? "Exif item" : (isXMP ? "XMP item" : "Metadata item (\(item.contentType.isEmpty ? item.type : item.contentType))")
            var detail = ""
            if item.type == "Exif" {
                var facts = ExifFacts()
                if old.count > 4, let skip = try? Bytes(old).be32(0), skip >= 0, 4 + skip < old.count {
                    facts = TinyTIFF.read(old.subdata(in: (4 + skip)..<old.count))
                }
                detail = exifSummary(facts)
                var keep = ExifFacts()
                keep.orientation = facts.orientation
                if hasGainMap { keep.appleHDR = facts.appleHDR }
                replacement = Data([0, 0, 0, 6]) + Data("Exif".utf8) + Data([0, 0]) + TinyTIFF.minimalBlock(keep)
            } else if isXMP {
                let targets = Set((described[id] ?? []).flatMap(\.to))
                let onlyAux = !targets.isEmpty && targets.isSubset(of: auxItems)
                    && targets.allSatisfy { (layout.auxTypes[$0] ?? "").lowercased().contains("gainmap") }
                if onlyAux, XMP.describesOnlyGainMap(old) {
                    plan.notes.append(ContainerNote("XMP item (gain map)", "gain map parameters only", bytes: total, .kept))
                    continue
                }
                detail = XMP.summary(old)
                replacement = Data()
                label = onlyAux ? "XMP item (auxiliary picture)" : label
            }

            // The new block goes at the start of the first extent. Every other
            // byte the item used becomes zero.
            guard replacement.count <= first.count else {
                throw ScrubError.unsupported("metadata item smaller than its replacement")
            }
            if !replacement.isEmpty { plan.patches.append(.write(first.lowerBound, replacement)) }
            if first.count > replacement.count { plan.patches.append(.zero((first.lowerBound + replacement.count)..<first.upperBound)) }
            for span in spans.dropFirst() where !span.isEmpty { plan.patches.append(.zero(span)) }
            for (index, extent) in item.extents.enumerated() where extent.lengthFieldSize > 0 {
                let newLength = index == 0 ? replacement.count : 0
                plan.patches.append(.write(extent.lengthFieldAt, Data.be(newLength, size: extent.lengthFieldSize)))
            }
            let kept = replacement.isEmpty ? "" : " (\(replacement.count) bytes stay: orientation\(replacement.count > 60 ? ", HDR headroom" : ""))"
            plan.notes.append(ContainerNote(label, detail + kept, bytes: total - replacement.count, replacement.isEmpty ? .removed : .rewritten))
        }

        // Boxes outside the picture structure: XMP or content credentials in a
        // uuid box, vendor boxes, and old free space.
        let structural: Set<String> = ["ftyp", "meta", "mdat"]
        for box in layout.top where !structural.contains(box.type) {
            let payload = box.payload..<box.end
            if box.type == "free" || box.type == "skip" {
                if try nonZero(b, payload) {
                    plan.patches.append(.zero(payload))
                    plan.notes.append(ContainerNote("Free space", "old data in an unused box", bytes: payload.count, .removed))
                }
            } else {
                plan.patches.append(.write(box.start + 4, Data("free".utf8)))
                plan.patches.append(.zero(payload))
                plan.notes.append(ContainerNote("Box '\(box.type)'", "data outside the picture structure", bytes: box.size, .removed))
            }
        }

        // Color profiles: the header date and the checksum become zero.
        for (index, range) in layout.iccProfiles.enumerated() {
            guard let profile = try? b.copy(range.lowerBound, range.count), let note = ICC.note(for: profile, where: index == 0 ? "" : " (\(index + 1))") else { continue }
            for part in ICC.privateRanges(profile) {
                plan.patches.append(.zero((range.lowerBound + part.lowerBound)..<(range.lowerBound + part.upperBound)))
            }
            plan.notes.append(note)
        }

        // Bytes in the data box that no item points at.
        var used: [Range<Int>] = []
        var mapComplete = true
        for item in layout.items.values where item.located && item.construction == 0 {
            if item.extents.contains(where: { $0.length == 0 }) && pictureTypes.contains(item.type) { mapComplete = false }
            if let spans = try? ranges(of: item, in: layout, fileSize: b.count) { used.append(contentsOf: spans) } else { mapComplete = false }
        }
        if mapComplete {
            used.sort { $0.lowerBound < $1.lowerBound }
            var slack = 0
            for box in layout.top where box.type == "mdat" {
                var cursor = box.payload
                for span in used where span.upperBound > cursor && span.lowerBound < box.end {
                    if span.lowerBound > cursor, try nonZero(b, cursor..<span.lowerBound) {
                        plan.patches.append(.zero(cursor..<span.lowerBound))
                        slack += span.lowerBound - cursor
                    }
                    cursor = max(cursor, span.upperBound)
                }
                if cursor < box.end, try nonZero(b, cursor..<box.end) {
                    plan.patches.append(.zero(cursor..<box.end))
                    slack += box.end - cursor
                }
            }
            if slack > 0 {
                plan.notes.append(ContainerNote("Unreferenced data", "bytes in the data box that no picture uses", bytes: slack, .removed))
            }
        }

        // What stays, for the report.
        let thumbs = Set(layout.references.filter { $0.type == "thmb" }.map(\.from))
        if !thumbs.isEmpty {
            plan.notes.append(ContainerNote("Thumbnail picture", "small coded copy of the picture", bytes: 0, .kept))
        }
        for (item, urn) in layout.auxTypes.sorted(by: { $0.key < $1.key }) where auxItems.contains(item) {
            plan.notes.append(ContainerNote("Auxiliary picture", auxName(urn), bytes: 0, .kept))
        }
        return plan
    }

    /// Copies `input` to `output` and applies the plan to the copy.
    static func strip(input: URL, output: URL) throws -> [ContainerNote] {
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        let plan = try plan(data)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let zeros = Data(count: 1 << 16)
        for patch in plan.patches {
            switch patch {
            case .write(let offset, let bytes):
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: bytes)
            case .zero(let range):
                try handle.seek(toOffset: UInt64(range.lowerBound))
                var left = range.count
                while left > 0 {
                    let n = min(left, zeros.count)
                    try handle.write(contentsOf: zeros.prefix(n))
                    left -= n
                }
            }
        }
        try handle.synchronize()
        return plan.notes
    }

    /// Problems in an output file. An empty list is a pass.
    static func audit(_ data: Data) -> [String] {
        var problems: [String] = []
        guard let layout = try? parse(data) else { return ["the output does not parse as HEIF"] }
        let b = Bytes(data)
        let structural: Set<String> = ["ftyp", "meta", "mdat", "free", "skip"]
        for box in layout.top where !structural.contains(box.type) { problems.append("box '\(box.type)' at the top level") }
        for item in layout.items.values {
            if pictureTypes.contains(item.type) { continue }
            guard let spans = try? ranges(of: item, in: layout, fileSize: b.count) else {
                problems.append("item \(item.id) cannot be located")
                continue
            }
            let total = spans.reduce(0) { $0 + $1.count }
            if item.type == "Exif" {
                if total > 160 { problems.append("Exif item holds \(total) bytes") }
            } else if total > 0 {
                let payload = spans.reduce(into: Data()) { $0.append((try? b.copy($1.lowerBound, $1.count)) ?? Data()) }
                if !XMP.describesOnlyGainMap(payload) { problems.append("metadata item '\(item.type)' holds \(total) bytes") }
            }
        }
        return problems
    }

    // MARK: - Helpers

    private static func nonZero(_ b: Bytes, _ range: Range<Int>) throws -> Bool {
        guard !range.isEmpty else { return false }
        try b.check(range.lowerBound, range.count)
        return b.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            for i in range where raw[i] != 0 { return true }
            return false
        }
    }

    private static func exifSummary(_ f: ExifFacts) -> String {
        var parts = ["camera and capture tags"]
        if f.hasGPS { parts.append("GPS") }
        if f.makerNoteBytes > 0 { parts.append("maker note") }
        if f.thumbnailBytes > 0 { parts.append("thumbnail") }
        return parts.joined(separator: ", ")
    }

    static func auxName(_ urn: String) -> String {
        let u = urn.lowercased()
        if u.contains("gainmap") { return "HDR gain map" }
        if u.contains("portraiteffectsmatte") { return "portrait matte" }
        if u.contains("semantic") { return "segmentation matte" }
        if u.contains("depth") || u.contains("disparity") || u.hasSuffix("auxid:2") { return "depth map" }
        if u.hasSuffix("auxid:1") { return "alpha channel" }
        return "auxiliary data (\(urn))"
    }
}
