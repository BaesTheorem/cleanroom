import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScrubKit

/// Command-line front end of the engine, for the Mac. It is also the test
/// harness: the corpus checks drive it and then ask ExifTool about the result.
@main
struct Scrub {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        args.removeFirst()
        switch command {
        case "inspect": await inspect(args)
        case "clean": await clean(args)
        case "plan": plan(args)
        case "pixelhash": pixelHash(args)
        case "preview":
            for path in args { print(Cleanroom.previewDigest(URL(fileURLWithPath: path)), path) }
        case "strip-only":
            guard args.count == 2 else { usage() }
            do { try Cleanroom.stripOnly(URL(fileURLWithPath: args[0]), to: URL(fileURLWithPath: args[1])) } catch { print("ERROR \(error)"); exit(1) }
        default: usage()
        }
    }

    static func usage() -> Never {
        print("""
        scrub inspect FILE...            tags that Apple's parsers read
        scrub plan FILE...               container parts and what a scrub does to each
        scrub clean FILE... -o DIR       write scrubbed copies, then check them
              [--keep-names] [--json]
        scrub pixelhash FILE [--hdr]     SHA-256 of the decoded picture
        """)
        exit(2)
    }

    static func inspect(_ files: [String]) async {
        for path in files {
            let found = await Cleanroom.inspect(URL(fileURLWithPath: path))
            print("\(path): \(found.typeName) \(found.pixelWidth)x\(found.pixelHeight) \(found.byteCount) bytes, \(found.tags.count) tags, gain map: \(found.hasGainMap)")
            for tag in found.tags { print("  [\(tag.risk.label)] \(tag.group) \(tag.key) = \(tag.value)") }
        }
    }

    static func plan(_ files: [String]) {
        for path in files {
            print(path)
            for note in Cleanroom.preview(URL(fileURLWithPath: path)) {
                print("  \(note.action.rawValue.uppercased()) \(note.item) (\(note.bytes) bytes): \(note.detail)")
            }
        }
    }

    static func clean(_ input: [String]) async {
        var files: [String] = []
        var directory = "out"
        var options = ScrubOptions()
        var json = false
        var i = 0
        while i < input.count {
            switch input[i] {
            case "-o": i += 1; directory = input[i]
            case "--keep-names": options.randomNames = false
            case "--json": json = true
            default: files.append(input[i])
            }
            i += 1
        }
        var failures = 0
        var records: [[String: Any]] = []
        for path in files {
            let url = URL(fileURLWithPath: path)
            do {
                let outcome = try await Cleanroom.scrub(url, into: URL(fileURLWithPath: directory), options: options)
                if !outcome.passed { failures += 1 }
                if json {
                    records.append([
                        "source": path, "output": outcome.output?.path ?? "", "passed": outcome.passed, "method": outcome.method.rawValue,
                        "removed": outcome.removed.count, "kept": outcome.kept.map { "\($0.group) \($0.key)" },
                        "bytesBefore": outcome.before.byteCount, "bytesAfter": outcome.after.byteCount,
                        "checks": outcome.checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
                        "notes": outcome.notes.map { ["item": $0.item, "detail": $0.detail, "bytes": $0.bytes, "action": $0.action.rawValue] },
                    ])
                } else {
                    print("\(outcome.passed ? "PASS" : "FAIL") \(path) -> \(outcome.output?.lastPathComponent ?? "(no output)") [\(outcome.method.rawValue)] \(outcome.before.byteCount) -> \(outcome.after.byteCount) bytes, \(outcome.removed.count) tags removed, \(outcome.kept.count) kept")
                    for check in outcome.checks { print("  \(check.passed ? "ok  " : "FAIL") \(check.name): \(check.detail)") }
                    for note in outcome.notes { print("  \(note.action.rawValue) \(note.item) (\(note.bytes) bytes): \(note.detail)") }
                }
            } catch {
                failures += 1
                if json { records.append(["source": path, "passed": false, "error": "\(error)"]) }
                else { print("ERROR \(path): \(error)") }
            }
        }
        if json, let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// Full-size decode, hashed with its geometry. With --hdr the decode asks
    /// for the HDR rendition, so a lost gain map changes the hash.
    static func pixelHash(_ input: [String]) {
        let hdr = input.contains("--hdr")
        for path in input where !path.hasPrefix("--") {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { print("\(path): cannot open"); continue }
            var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary), let data = image.dataProvider?.data as Data? else {
                print("\(path): cannot decode"); continue
            }
            var hasher = SHA256()
            hasher.update(data: Data("\(image.width)x\(image.height)x\(image.bitsPerPixel)x\(image.bytesPerRow)".utf8))
            hasher.update(data: data)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let headroom = hdr ? " headroom=\(image.contentHeadroom)" : ""
            let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?[kCGImagePropertyOrientation as String] ?? 1
            print("\(digest) \(image.width)x\(image.height) bpp=\(image.bitsPerPixel) orientation=\(orientation)\(headroom) \(path)")
        }
    }
}
