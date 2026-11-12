import CoreGraphics
import Foundation
import ImageIO

/// One test that an output file went through after the scrub.
public struct Check: Sendable, Identifiable, Hashable {
    public let name: String
    public let passed: Bool
    public let detail: String
    public var id: String { name }

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

enum Verify {
    /// Apple's parser must find nothing but rendering facts in the output.
    static func parser(_ after: Inspection) -> Check {
        let left = after.risky
        if left.isEmpty {
            let reader = after.kind == .movie ? "AVFoundation" : "ImageIO"
            return Check(name: "PARSER", passed: true, detail: "\(reader) reads \(after.tags.count) fields, and all of them are rendering facts")
        }
        let sample = left.prefix(4).map { "\($0.group) \($0.key)" }.joined(separator: ", ")
        return Check(name: "PARSER", passed: false, detail: "\(left.count) fields remain: \(sample)")
    }

    /// The byte-level walk must find only allowlisted structures.
    static func container(_ problems: [String]) -> Check {
        if problems.isEmpty {
            return Check(name: "STRUCTURE", passed: true, detail: "byte-level walk finds only allowlisted parts")
        }
        return Check(name: "STRUCTURE", passed: false, detail: problems.prefix(4).joined(separator: ", "))
    }

    /// The decoded picture must be the same before and after: the same
    /// pixels, the same rotation, and the same color space.
    static func pixels(before a: Preview?, output: URL, maxPixel: Int) -> Check {
        guard let a, let b = preview(output, maxPixel: maxPixel) else {
            return Check(name: "PIXELS", passed: false, detail: "the output does not decode")
        }
        guard a.width == b.width, a.height == b.height else {
            return Check(name: "PIXELS", passed: false, detail: "size or rotation changed: \(a.width)x\(a.height) to \(b.width)x\(b.height)")
        }
        guard a.bytes == b.bytes else {
            return Check(name: "PIXELS", passed: false, detail: "decoded picture differs from the original")
        }
        guard a.color == b.color else {
            return Check(name: "PIXELS", passed: false, detail: "color space changed: \(a.colorName) to \(b.colorName)")
        }
        return Check(name: "PIXELS", passed: true, detail: "decoded picture, rotation and color space are identical (\(a.width)x\(a.height) comparison)")
    }

    static func samples(before: [String], after: [String]) -> Check {
        if !before.isEmpty, before == after {
            return Check(name: "SAMPLES", passed: true, detail: "SHA-256 of every copied track matches the original (\(before.count) tracks)")
        }
        return Check(name: "SAMPLES", passed: false, detail: "the copied samples differ from the original")
    }

    struct Preview {
        let bytes: Data
        let width: Int
        let height: Int
        /// The color profile with its date and checksum set to zero, or the
        /// name of the color space when it has no profile.
        let color: Data
        let colorName: String
        /// The profile that the decoder assigns to the picture.
        let profile: Data?
    }

    /// The first picture of a file, decoded at reduced size with its rotation
    /// applied. Two files that render the same give equal previews.
    static func preview(_ url: URL, maxPixel: Int) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Read the properties first. ImageIO applies the rotation of a PNG
        // with both XMP and Exif chunks only after it has parsed them, so
        // without this call the same file can decode in two ways.
        _ = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0, let bytes = image.dataProvider?.data as Data? else { return nil }
        let name = (image.colorSpace?.name as String?) ?? "unnamed"
        let profile = image.colorSpace?.copyICCData() as Data?
        let color = profile.map { ICC.sanitized($0) ?? $0 } ?? Data(name.utf8)
        return Preview(bytes: bytes, width: image.width, height: image.height, color: color, colorName: shortColorName(name), profile: profile)
    }

    private static func shortColorName(_ name: String) -> String {
        name.replacingOccurrences(of: "kCGColorSpace", with: "")
    }
}
