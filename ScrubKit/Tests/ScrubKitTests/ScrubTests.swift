import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScrubKit

/// These tests make their own pictures with ImageIO, so they need no sample
/// files. The corpus check in bin/check-corpus covers real camera files.
final class ScrubTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("scrubkit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A small picture with location, camera, owner and time tags, rotated.
    private func makePicture(_ type: UTType, name: String, orientation: Int = 6) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (index, color) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                               CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index * 20, y: index * 10, width: 30, height: 20))
        }
        let url = work.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.0997, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 94.5786, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TESTMAKE", kCGImagePropertyTIFFModel: "TESTMODEL",
                                             kCGImagePropertyTIFFArtist: "TESTOWNER"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05",
                                             kCGImagePropertyExifLensModel: "TESTLENS"],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func assertClean(_ type: UTType, _ name: String) async throws {
        let source = try makePicture(type, name: name)
        let before = await Cleanroom.inspect(source)
        XCTAssertGreaterThan(before.count(.location), 0, "the test picture must carry a location")

        let outcome = try await Cleanroom.scrub(source, into: work.appendingPathComponent("out"))
        XCTAssertTrue(outcome.passed, "\(outcome.checks)")
        XCTAssertEqual(outcome.method, .lossless)
        XCTAssertTrue(outcome.after.risky.isEmpty, "\(outcome.after.risky)")
        XCTAssertGreaterThan(outcome.removed.count, 5)

        let output = try XCTUnwrap(outcome.output)
        XCTAssertNotEqual(output.deletingPathExtension().lastPathComponent, source.deletingPathExtension().lastPathComponent)
        let bytes = try Data(contentsOf: output)
        for word in ["TESTMAKE", "TESTMODEL", "TESTOWNER", "TESTLENS", "2026:01:02"] {
            XCTAssertNil(bytes.range(of: Data(word.utf8)), "\(word) is still in the output")
        }
        let orientation = outcome.after.tags.first { $0.group == "IMAGE" && $0.key == "Orientation" }?.value
        XCTAssertEqual(orientation, "6", "the rotation must stay")
    }

    func testJPEG() async throws { try await assertClean(.jpeg, "picture.jpg") }
    func testPNG() async throws { try await assertClean(.png, "picture.png") }
    func testHEIC() async throws { try await assertClean(.heic, "picture.heic") }

    func testJPEGTrailerGoes() async throws {
        let source = try makePicture(.jpeg, name: "trailer.jpg", orientation: 1)
        var bytes = try Data(contentsOf: source)
        bytes.append(Data("SECRET-AFTER-THE-END".utf8))
        try bytes.write(to: source)
        let outcome = try await Cleanroom.scrub(source, into: work.appendingPathComponent("out"))
        XCTAssertTrue(outcome.passed)
        XCTAssertNil(try Data(contentsOf: XCTUnwrap(outcome.output)).range(of: Data("SECRET".utf8)))
    }

    func testBrokenFilesDoNotCrash() async throws {
        let source = try makePicture(.jpeg, name: "whole.jpg")
        let whole = try Data(contentsOf: source)
        for cut in [3, 10, 40, whole.count / 2] {
            let broken = work.appendingPathComponent("cut-\(cut).jpg")
            try whole.prefix(cut).write(to: broken)
            _ = try? await Cleanroom.scrub(broken, into: work.appendingPathComponent("out"))
        }
        let garbage = work.appendingPathComponent("garbage.heic")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        _ = try? await Cleanroom.scrub(garbage, into: work.appendingPathComponent("out"))
    }

    func testMinimalExifHoldsOnlyRenderingFacts() {
        var facts = ExifFacts()
        facts.orientation = 8
        let block = TinyTIFF.minimalBlock(facts, jpegSize: (640, 480))
        let read = TinyTIFF.read(block)
        XCTAssertEqual(read.orientation, 8)
        XCTAssertFalse(read.hasGPS)
        XCTAssertEqual(read.makerNoteBytes, 0)
        XCTAssertLessThan(block.count, 160)
    }
}
