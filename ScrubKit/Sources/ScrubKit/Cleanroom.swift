import CryptoKit
import Foundation

public struct ScrubOptions: Sendable {
    /// Give the output a random name. A name like IMG_4123 tells how many
    /// pictures the camera took before this one.
    public var randomNames = true
    /// Longest side, in pixels, of the before and after picture comparison.
    public var comparisonSize = 1024

    public init(randomNames: Bool = true, comparisonSize: Int = 1024) {
        self.randomNames = randomNames
        self.comparisonSize = comparisonSize
    }
}

public struct ScrubOutcome: Sendable, Identifiable {
    public enum Method: String, Sendable {
        /// The coded picture or the coded samples are byte for byte the same.
        case lossless
        /// The picture was decoded and encoded again.
        case rebuilt
    }

    public let id = UUID()
    public let source: URL
    /// nil when a check failed. A file that fails a check is deleted.
    public let output: URL?
    public let method: Method
    public let before: Inspection
    public let after: Inspection
    public let notes: [ContainerNote]
    public let checks: [Check]

    public var passed: Bool { output != nil && !checks.isEmpty && checks.allSatisfy(\.passed) }

    /// Tags of the original that the output does not hold.
    public var removed: [Tag] {
        let left = Set(after.tags.map(\.id))
        return before.tags.filter { !left.contains($0.id) }
    }

    /// Tags that the output holds.
    public var kept: [Tag] { after.tags }
}

public enum Cleanroom {
    public static let version = "1.0"

    public static func kind(of url: URL) -> MediaKind {
        Inspect.sniff(url).0
    }

    /// Reads the tags of a file. It does not change the file.
    public static func inspect(_ url: URL) async -> Inspection {
        await Inspect.file(url)
    }

    /// The container parts of a file, with the action a scrub applies to each.
    /// It does not write anything.
    public static func preview(_ url: URL) -> [ContainerNote] {
        let (kind, _) = Inspect.sniff(url)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        switch kind {
        case .jpeg: return (try? JPEG.strip(data).notes) ?? []
        case .png: return (try? PNG.strip(data).notes) ?? []
        case .heif: return (try? HEIF.plan(data).notes) ?? []
        default: return []
        }
    }

    /// Size and SHA-256 of the rendered comparison picture. For tests.
    public static func previewDigest(_ url: URL, maxPixel: Int = 1024) -> String {
        guard let p = Verify.preview(url, maxPixel: maxPixel) else { return "no decode" }
        return "\(p.width)x\(p.height) \(p.colorName) " + SHA256.hash(data: p.bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The byte-level scrub alone, with no check of the result. For tests.
    public static func stripOnly(_ url: URL, to output: URL) throws {
        let (kind, _) = Inspect.sniff(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        switch kind {
        case .jpeg: try JPEG.strip(data).data.write(to: output)
        case .png: try PNG.strip(data).data.write(to: output)
        case .heif: _ = try HEIF.strip(input: url, output: output)
        default: throw ScrubError.unsupported("no byte-level scrubber for this file")
        }
    }

    /// Writes a scrubbed copy of `url` into `directory`, then checks the copy.
    public static func scrub(_ url: URL, into directory: URL, options: ScrubOptions = ScrubOptions(),
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> ScrubOutcome {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = Date()
        let (kind, head) = Inspect.sniff(url)
        let before = await Inspect.file(url)
        let name = options.randomNames ? randomName() : url.deletingPathExtension().lastPathComponent
        var notes: [ContainerNote] = []
        var method = ScrubOutcome.Method.lossless
        var output: URL
        var sourceDigests: [String] = []
        let pictureBefore = kind == .jpeg || kind == .png || kind == .heif ? Verify.preview(url, maxPixel: options.comparisonSize) : nil

        func rebuild(because reason: String) throws -> URL {
            let (rebuilt, rebuildNotes) = try Rebuild.image(input: url, directory: directory, name: name)
            polish(rebuilt)
            notes = [ContainerNote("Byte-level scrub refused", reason, bytes: 0, .rewritten)] + rebuildNotes
            method = .rebuilt
            return rebuilt
        }

        switch kind {
        case .jpeg, .png:
            let ext = kind == .jpeg ? "jpg" : "png"
            output = directory.appendingPathComponent(name).appendingPathExtension(ext)
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if kind == .jpeg {
                    // A profile that the decoder derives from Exif tags (Adobe RGB
                    // from a camera, for example) must not vanish with the tags.
                    let implied = pictureBefore.flatMap { $0.colorName == "SRGB" ? nil : $0.profile }
                    let result = try JPEG.strip(data, impliedProfile: implied)
                    try result.data.write(to: output, options: .atomic)
                    notes = result.notes
                } else {
                    let result = try PNG.strip(data)
                    try result.data.write(to: output, options: .atomic)
                    notes = result.notes
                }
            } catch let error as ScrubError {
                output = try rebuild(because: error.description)
            }
        case .heif:
            let ext = url.pathExtension.isEmpty ? "heic" : url.pathExtension.lowercased()
            output = directory.appendingPathComponent(name).appendingPathExtension(ext)
            do {
                notes = try HEIF.strip(input: url, output: output)
            } catch let error as ScrubError {
                try? FileManager.default.removeItem(at: output)
                output = try rebuild(because: error.description)
            }
        case .image:
            let (rebuilt, rebuildNotes) = try Rebuild.image(input: url, directory: directory, name: name)
            polish(rebuilt)
            output = rebuilt
            notes = rebuildNotes
            method = .rebuilt
        case .movie:
            let (type, ext) = Movie.fileType(head)
            output = directory.appendingPathComponent(name).appendingPathExtension(ext)
            let result = try await Movie.strip(input: url, output: output, fileType: type, progress: progress)
            notes = result.notes
            sourceDigests = result.digests
        case .unknown:
            throw ScrubError.unsupported("this is not a picture or a movie that the scrubber knows")
        }

        var (after, checks) = await verify(pictureBefore: pictureBefore, before: before, output: output, kind: kind, method: method, options: options,
                                           sourceDigests: sourceDigests, started: started, notes: &notes)

        // A byte-level result that fails a check gets one more attempt from pixels.
        if checks.contains(where: { !$0.passed }), method == .lossless, kind == .jpeg || kind == .png || kind == .heif {
            let failed = checks.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")
            try? FileManager.default.removeItem(at: output)
            output = try rebuild(because: "the byte-level result failed a check (\(failed))")
            (after, checks) = await verify(pictureBefore: pictureBefore, before: before, output: output, kind: kind, method: method, options: options,
                                           sourceDigests: [], started: started, notes: &notes)
        }

        let passed = checks.allSatisfy(\.passed)
        if !passed { try? FileManager.default.removeItem(at: output) }
        return ScrubOutcome(source: url, output: passed ? output : nil, method: method, before: before, after: after, notes: notes, checks: checks)
    }

    private static func verify(pictureBefore: Verify.Preview?, before: Inspection, output: URL, kind: MediaKind, method: ScrubOutcome.Method, options: ScrubOptions,
                               sourceDigests: [String], started: Date, notes: inout [ContainerNote]) async -> (Inspection, [Check]) {
        var after = await Inspect.file(output)
        var checks: [Check] = []

        if kind == .movie {
            // The writer stamps the new container with the time of the scrub.
            // That value is not from the original, so it is not a leftover.
            let formatter = ISO8601DateFormatter()
            after.tags.removeAll { tag in
                guard tag.group == "HEADER", let date = formatter.date(from: tag.value) else { return false }
                return date >= started.addingTimeInterval(-2)
            }
            notes.append(ContainerNote("Header times", "set to the time of the scrub", bytes: 0, .rewritten))
        }
        checks.append(Verify.parser(after))

        guard let data = try? Data(contentsOf: output, options: .mappedIfSafe) else {
            return (after, checks + [Check(name: "STRUCTURE", passed: false, detail: "the output cannot be read")])
        }
        switch after.kind {
        case .jpeg: checks.append(Verify.container(JPEG.audit(data)))
        case .png: checks.append(Verify.container(PNG.audit(data)))
        case .heif: if method == .lossless { checks.append(Verify.container(HEIF.audit(data))) }
        case .movie: checks.append(Verify.container(Movie.atomAudit(data)))
        default: break
        }

        if kind == .movie {
            let copied = (try? await Movie.sampleDigests(output)) ?? []
            checks.append(Verify.samples(before: sourceDigests, after: copied))
        } else if method == .lossless {
            checks.append(Verify.pixels(before: pictureBefore, output: output, maxPixel: options.comparisonSize))
            if before.hasGainMap, !after.hasGainMap {
                notes.append(ContainerNote("HDR gain map", "the original has one and the output does not: the picture renders without HDR", bytes: 0, .removed))
            }
        } else if Verify.preview(output, maxPixel: 64) == nil {
            checks.append(Check(name: "PIXELS", passed: false, detail: "the rebuilt picture does not decode"))
        }
        return (after, checks)
    }

    /// The byte-level pass over a file that the encoder just wrote. The
    /// system encoder adds fields of its own (a rotation table, a color
    /// profile date), and this pass takes them out again.
    private static func polish(_ url: URL) {
        let (kind, _) = Inspect.sniff(url)
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".polish-" + randomName())
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            switch kind {
            case .jpeg, .png:
                let data = try Data(contentsOf: url)
                let clean = kind == .jpeg ? try JPEG.strip(data).data : try PNG.strip(data).data
                try clean.write(to: url, options: .atomic)
            case .heif:
                _ = try HEIF.strip(input: url, output: scratch)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
            default: break
            }
        } catch {}
    }

    static func randomName() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
