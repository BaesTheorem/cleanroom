import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The fallback for picture formats with no byte-level scrubber, and for files
/// the byte-level scrubber refuses. It decodes the pixels and encodes a new
/// file from them, so nothing but pixels and the color profile can pass.
enum Rebuild {
    static func image(input: URL, directory: URL, name: String) throws -> (URL, [ContainerNote]) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ScrubError.unsupported("the file is not a picture this device can decode")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ScrubError.unsupported("the file holds no picture") }
        let sourceType = (CGImageSourceGetType(source) as String?) ?? ""

        let target: UTType
        switch sourceType {
        case UTType.jpeg.identifier: target = .jpeg
        case UTType.png.identifier: target = .png
        case UTType.gif.identifier: target = .gif
        case UTType.tiff.identifier, UTType.bmp.identifier:
            // PNG keeps every pixel of an RGB or gray picture. It cannot hold CMYK.
            let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            target = (first?[kCGImagePropertyColorModel as String] as? String) == "CMYK" ? .jpeg : .png
        default:
            let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let alpha = first?[kCGImagePropertyHasAlpha as String] as? Bool ?? false
            target = alpha ? .png : .heic
        }
        let ext = target.preferredFilenameExtension ?? "img"
        let output = directory.appendingPathComponent(name).appendingPathExtension(ext == "jpeg" ? "jpg" : ext)
        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, target.identifier as CFString, count, nil) else {
            throw ScrubError.io("cannot create the output picture")
        }

        // Frame timing is the only file-level property that changes playback.
        if let fileProps = CGImageSourceCopyProperties(source, nil) as? [String: Any] {
            var keep: [String: Any] = [:]
            for key in [kCGImagePropertyGIFDictionary as String, kCGImagePropertyPNGDictionary as String] {
                if let timing = fileProps[key] as? [String: Any] { keep[key] = timingOnly(timing) }
            }
            if !keep.isEmpty { CGImageDestinationSetProperties(destination, keep as CFDictionary) }
        }

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw ScrubError.unsupported("frame \(index) does not decode")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            var out: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.92]
            if let orientation = props[kCGImagePropertyOrientation as String] { out[kCGImagePropertyOrientation as String] = orientation }
            for key in [kCGImagePropertyGIFDictionary as String, kCGImagePropertyPNGDictionary as String] {
                if let timing = props[key] as? [String: Any] {
                    let only = timingOnly(timing)
                    if !only.isEmpty { out[key] = only }
                }
            }
            CGImageDestinationAddImage(destination, image, out as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ScrubError.io("cannot write the output picture") }

        let lossy = target == .jpeg || target == .heic
        let note = ContainerNote("Rebuilt from pixels",
                                 lossy ? "decoded and encoded again as \(ext.uppercased()): a small quality loss is possible, and HDR data does not carry over"
                                       : "decoded and encoded again as \(ext.uppercased())",
                                 bytes: 0, .rewritten)
        return (output, [note])
    }

    private static func timingOnly(_ group: [String: Any]) -> [String: Any] {
        let timing: Set<String> = ["DelayTime", "UnclampedDelayTime", "LoopCount"]
        return group.filter { timing.contains($0.key) }
    }
}
