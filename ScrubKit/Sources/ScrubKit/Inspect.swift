import AVFoundation
import Foundation
import ImageIO

/// What a tag tells a stranger about the person who made the file.
public enum Risk: String, Sendable, CaseIterable, Comparable {
    case location, identity, device, time, software, content, technical

    public static func < (a: Risk, b: Risk) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .location: return "LOCATION"
        case .identity: return "IDENTITY"
        case .device: return "DEVICE"
        case .time: return "TIME"
        case .software: return "SOFTWARE"
        case .content: return "NOTES"
        case .technical: return "RENDER"
        }
    }
}

public struct Tag: Hashable, Sendable, Identifiable {
    public let group: String
    public let key: String
    public let value: String
    public let risk: Risk
    public var id: String { group + "\u{1F}" + key }

    public init(group: String, key: String, value: String, risk: Risk) {
        self.group = group
        self.key = key
        self.value = value
        self.risk = risk
    }
}

public enum MediaKind: String, Sendable {
    case jpeg, png, heif, movie, image, unknown
}

/// The tags Apple's own parsers report for a file. The scrubber does not use
/// this code path to write, so it is an independent reading of the result.
public struct Inspection: Sendable {
    public var kind: MediaKind = .unknown
    public var typeName = ""
    public var byteCount = 0
    public var pixelWidth = 0
    public var pixelHeight = 0
    public var duration: Double = 0
    public var hasGainMap = false
    public var tags: [Tag] = []

    public init() {}

    public var risky: [Tag] { tags.filter { $0.risk != .technical } }
    public func count(_ risk: Risk) -> Int { tags.filter { $0.risk == risk }.count }
}

enum Inspect {
    static func sniff(_ url: URL) -> (MediaKind, Data) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (.unknown, Data()) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if JPEG.isJPEG(head) { return (.jpeg, head) }
        if PNG.isPNG(head) { return (.png, head) }
        if HEIF.isHEIF(head) { return (.heif, head) }
        if Movie.isMovie(head) { return (.movie, head) }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 { return (.image, head) }
        return (.unknown, head)
    }

    static func file(_ url: URL) async -> Inspection {
        let (kind, head) = sniff(url)
        var out = Inspection()
        out.kind = kind
        out.byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        switch kind {
        case .jpeg, .png, .heif, .image: image(url, into: &out)
        case .movie: await movie(url, head: head, into: &out)
        case .unknown: break
        }
        out.tags.sort { ($0.risk, $0.group, $0.key) < ($1.risk, $1.group, $1.key) }
        return out
    }

    // MARK: - Pictures

    /// XMP prefixes that ImageIO makes up from Exif, TIFF and GPS fields. The
    /// same values are already in the property groups.
    private static let mirroredPrefixes: Set<String> = ["exif", "tiff", "exifEX"]

    private static func image(_ url: URL, into out: inout Inspection) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        out.typeName = shortType(CGImageSourceGetType(source) as String? ?? "")
        let count = CGImageSourceGetCount(source)
        guard count > 0, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return }
        out.pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        out.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        out.hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil

        for (key, value) in props {
            if let group = value as? [String: Any] {
                let name = groupName(key)
                for (sub, v) in group { addTag(name, sub, v, to: &out) }
            } else {
                addTag("IMAGE", key, value, to: &out)
            }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            var found: [(String, String)] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
                guard !mirroredPrefixes.contains(prefix) else { return true }
                let value = CGImageMetadataTagCopyValue(tag)
                // A structure or an array shows up again through its members.
                if value is [Any] || value is [String: Any] { return true }
                found.append((path as String, text(value as Any)))
                return true
            }
            for (path, value) in found {
                out.tags.append(Tag(group: "XMP", key: path, value: value, risk: xmpRisk(path)))
            }
        }
        if count > 1 {
            out.tags.append(Tag(group: "IMAGE", key: "FrameCount", value: "\(count)", risk: .technical))
        }
    }

    private static func addTag(_ group: String, _ key: String, _ value: Any, to out: inout Inspection) {
        if let nested = value as? [String: Any] {
            for (k, v) in nested { addTag(group, key + "." + k, v, to: &out) }
            return
        }
        out.tags.append(Tag(group: group, key: key, value: text(value), risk: risk(group: group, key: key)))
    }

    private static func groupName(_ key: String) -> String {
        key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).uppercased()
    }

    private static func shortType(_ uti: String) -> String {
        let names = ["public.jpeg": "JPEG", "public.png": "PNG", "public.heic": "HEIC", "public.heif": "HEIF", "public.avif": "AVIF",
                     "public.tiff": "TIFF", "com.compuserve.gif": "GIF", "org.webmproject.webp": "WEBP", "com.adobe.raw-image": "DNG",
                     "com.microsoft.bmp": "BMP", "public.heics": "HEICS"]
        return names[uti] ?? (uti.split(separator: ".").last.map { $0.uppercased() } ?? "IMAGE")
    }

    static func text(_ value: Any) -> String {
        let raw: String
        switch value {
        case let s as String: raw = s
        case let n as NSNumber: raw = n.stringValue
        case let d as Data: raw = "<\(d.count) bytes>"
        case let a as [Any]: raw = a.map { text($0) }.joined(separator: ", ")
        case let d as Date: raw = ISO8601DateFormatter().string(from: d)
        case let d as [String: Any]: raw = d.keys.sorted().map { "\($0)=\(text(d[$0]!))" }.joined(separator: "; ")
        default: raw = String(describing: value)
        }
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(157)) + "..." : flat
    }

    // MARK: - Risk

    private static let technicalGroups: Set<String> = ["IMAGE", "JFIF", "GIF", "HEICS", "HEIF", "AVIS", "WEBP"]

    private static let byKey: [String: Risk] = [
        // TIFF
        "Make": .device, "Model": .device, "Software": .software, "DateTime": .time, "Artist": .identity,
        "Copyright": .identity, "HostComputer": .device, "ImageDescription": .content, "DocumentName": .content,
        // Exif
        "DateTimeOriginal": .time, "DateTimeDigitized": .time, "SubsecTime": .time, "SubsecTimeOriginal": .time,
        "SubsecTimeDigitized": .time, "OffsetTime": .time, "OffsetTimeOriginal": .time, "OffsetTimeDigitized": .time,
        "LensMake": .device, "LensModel": .device, "LensSpecification": .device, "BodySerialNumber": .device,
        "LensSerialNumber": .device, "SerialNumber": .device, "CameraOwnerName": .identity, "OwnerName": .identity,
        "UserComment": .content, "MakerNote": .device, "ImageUniqueID": .identity, "Firmware": .software,
        // PNG text
        "Author": .identity, "Title": .content, "Description": .content, "Comment": .content, "Source": .device,
        "CreationTime": .time, "ModificationTime": .time, "Warning": .content, "Disclaimer": .content,
        // IPTC
        "Byline": .identity, "BylineTitle": .identity, "Credit": .identity, "CopyrightNotice": .identity,
        "Contact": .identity, "Writer/Editor": .identity, "City": .location, "Province/State": .location,
        "Country/PrimaryLocationName": .location, "Country/PrimaryLocationCode": .location, "SubLocation": .location,
        "DateCreated": .time, "TimeCreated": .time, "DigitalCreationDate": .time, "DigitalCreationTime": .time,
        "Caption/Abstract": .content, "Keywords": .content, "ObjectName": .content, "Headline": .content,
        "OriginatingProgram": .software, "ProgramVersion": .software,
    ]

    /// Keys that only say how to draw the pixels.
    static let renderKeys: [String: Set<String>] = [
        "TIFF": ["Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation",
                 "PlanarConfiguration", "TileWidth", "TileLength"],
        "EXIF": ["ColorSpace", "PixelXDimension", "PixelYDimension", "ComponentsConfiguration", "ExifVersion", "FlashPixVersion",
                 "SceneCaptureType"],
        "PNG": ["InterlaceType", "sRGBIntent", "Gamma", "Chromaticities", "XPixelsPerMeter", "YPixelsPerMeter", "PixelAspectRatio", "DelayTime",
                "UnclampedDelayTime", "LoopCount", "CanvasPixelWidth", "CanvasPixelHeight", "FrameInfo"],
        "MAKERAPPLE": ["33", "48"],
    ]

    static func risk(group: String, key: String) -> Risk {
        let base = key.split(separator: ".").first.map(String.init) ?? key
        if technicalGroups.contains(group) { return .technical }
        if renderKeys[group]?.contains(base) == true { return .technical }
        if group == "GPS" { return .location }
        if group.hasPrefix("MAKER") || group == "CIFF" || group == "EXIFAUX" { return byKey[base] ?? .device }
        if let known = byKey[base] { return known }
        if group == "IPTC" || group == "8BIM" { return .content }
        if group == "EXIF" || group == "TIFF" || group == "DNG" || group == "RAW" { return .device }
        return .content
    }

    private static func xmpRisk(_ path: String) -> Risk {
        let p = path.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { p.contains($0) } }
        if has(["gps", "location", "city", "country", "state", "sublocation"]) { return .location }
        if has(["creator", "rights", "owner", "author", "person", "region", "credit", "artist", "documentid", "instanceid", "uniqueid", "contact"]) { return .identity }
        if has(["serial", "lens", "model", "make", "camera"]) { return .device }
        if has(["date", "time"]) { return .time }
        if has(["tool", "software", "toolkit", "history", "derived", "agent"]) { return .software }
        return .content
    }

    // MARK: - Movies

    private static func movie(_ url: URL, head: Data, into out: inout Inspection) async {
        let asset = AVURLAsset(url: url)
        out.typeName = Movie.fileType(head).1.uppercased()
        out.duration = (try? await asset.load(.duration).seconds) ?? 0
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            for item in items { await addItem(item, group: formatName(format), to: &out) }
        }
        for track in (try? await asset.load(.tracks)) ?? [] {
            let type = track.mediaType
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let name = Movie.trackName(type, descriptions.first)
            if type == .video, let size = try? await track.load(.naturalSize), out.pixelWidth == 0 {
                out.pixelWidth = Int(abs(size.width))
                out.pixelHeight = Int(abs(size.height))
            }
            let content = Movie.contentTypes.contains(type)
            out.tags.append(Tag(group: "TRACK \(track.trackID)", key: "kind", value: name, risk: content ? .technical : .device))
            for item in (try? await track.load(.metadata)) ?? [] { await addItem(item, group: "TRACK \(track.trackID)", to: &out) }
        }
        if let whole = try? Data(contentsOf: url, options: .mappedIfSafe), let date = Movie.headerCreationDate(whole) {
            out.tags.append(Tag(group: "HEADER", key: "creation time", value: ISO8601DateFormatter().string(from: date), risk: .time))
        }
    }

    private static func addItem(_ item: AVMetadataItem, group: String, to out: inout Inspection) async {
        let key = item.identifier?.rawValue ?? (item.key.map { "\($0)" } ?? "item")
        var value = (try? await item.load(.stringValue)) ?? nil
        if value == nil, let date = (try? await item.load(.dateValue)) ?? nil { value = ISO8601DateFormatter().string(from: date) }
        if value == nil, let number = (try? await item.load(.numberValue)) ?? nil { value = number.stringValue }
        if value == nil, let data = (try? await item.load(.dataValue)) ?? nil { value = "<\(data.count) bytes>" }
        let shown = text(value ?? "(no text value)")
        let short = key.replacingOccurrences(of: "mdta/com.apple.quicktime.", with: "").replacingOccurrences(of: "com.apple.quicktime.", with: "")
        out.tags.append(Tag(group: group, key: short, value: shown, risk: movieRisk(short)))
    }

    private static func formatName(_ format: AVMetadataFormat) -> String {
        switch format {
        case .quickTimeMetadata: return "QUICKTIME"
        case .quickTimeUserData: return "USER DATA"
        case .iTunesMetadata: return "ITUNES"
        case .isoUserData: return "ISO USER DATA"
        case .id3Metadata: return "ID3"
        default: return format.rawValue.uppercased()
        }
    }

    private static func movieRisk(_ key: String) -> Risk {
        let k = key.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { k.contains($0) } }
        if has(["location", "xyz", "gps", "iso6709"]) { return .location }
        if has(["make", "model", "lens", "camera", "serial", "identifier"]) { return .device }
        if has(["date", "time", "day", "year"]) { return .time }
        if has(["software", "encoder", "tool", "version"]) { return .software }
        if has(["author", "artist", "copyright", "owner", "director", "producer", "publisher", "performer"]) { return .identity }
        return .content
    }
}
