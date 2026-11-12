import AVFoundation
import CryptoKit
import Foundation

/// Lossless movie scrub. It copies the compressed video, audio and caption
/// samples into a new container and leaves every metadata atom and every other
/// track behind.
enum Movie {
    struct Result {
        var notes: [ContainerNote]
        /// One SHA-256 per copied track, over the compressed sample bytes.
        var digests: [String]
    }

    /// Track kinds that are content. Every other kind (timed metadata,
    /// timecode, depth, haptics) describes the recording.
    static let contentTypes: Set<AVMediaType> = [.video, .audio, .subtitle, .closedCaption, .text]

    static func isMovie(_ data: Data) -> Bool {
        let b = Bytes(data)
        guard let type = try? b.fourCC(4) else { return false }
        if type == "ftyp" { return !HEIF.isHEIF(data) }
        return ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(type)
    }

    static func fileType(_ data: Data) -> (AVFileType, String) {
        let brands = BMFF.brands(Bytes(data))
        if brands.isEmpty || brands.first == "qt  " { return (.mov, "mov") }
        if brands.first == "M4V " { return (.m4v, "m4v") }
        return (.mp4, "mp4")
    }

    static func strip(input: URL, output: URL, fileType: AVFileType, progress: (@Sendable (Double) -> Void)?) async throws -> Result {
        let asset = AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.load(.tracks)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.metadata = []
        writer.shouldOptimizeForNetworkUse = true

        var notes: [ContainerNote] = []
        var lanes: [Lane] = []
        var inputByTrack: [CMPersistentTrackID: AVAssetWriterInput] = [:]

        for track in tracks {
            let type = track.mediaType
            let formats = try await track.load(.formatDescriptions)
            let trackBytes = Int((try? await track.load(.totalSampleDataLength)) ?? 0)
            guard contentTypes.contains(type), let format = formats.first else {
                notes.append(ContainerNote("Track \(track.trackID) (\(trackName(type, formats.first)))", trackPurpose(type, formats.first), bytes: trackBytes, .removed))
                continue
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.metadata = []
            input.marksOutputTrackAsEnabled = (try? await track.load(.isEnabled)) ?? true
            if type == .video {
                input.transform = (try? await track.load(.preferredTransform)) ?? .identity
                input.mediaTimeScale = (try? await track.load(.naturalTimeScale)) ?? 0
            }
            if type == .audio { input.preferredVolume = (try? await track.load(.preferredVolume)) ?? 1 }
            if let language = try? await track.load(.languageCode), type != .video { input.languageCode = language }
            guard reader.canAdd(out), writer.canAdd(input) else {
                if type == .video || type == .audio {
                    throw ScrubError.unsupported("track \(track.trackID) (\(trackName(type, format))) cannot be copied without a re-encode")
                }
                notes.append(ContainerNote("Track \(track.trackID) (\(trackName(type, format)))", "this container cannot hold the track", bytes: trackBytes, .removed))
                continue
            }
            reader.add(out)
            writer.add(input)
            inputByTrack[track.trackID] = input
            lanes.append(Lane(output: out, input: input, isVideo: type == .video))
            notes.append(ContainerNote("Track \(track.trackID) (\(trackName(type, format)))", "copied sample for sample", bytes: trackBytes, .kept))
        }
        guard !lanes.isEmpty else { throw ScrubError.unsupported("no video or audio track") }

        // Alternate groups (for example stereo and spatial audio of one take).
        if let groups = try? await asset.load(.trackGroups) {
            for group in groups {
                let ids = group.trackIDs.map { CMPersistentTrackID(truncating: $0) }
                let inputs = ids.compactMap { inputByTrack[$0] }
                guard inputs.count >= 2 else { continue }
                let chosen = inputs.first { $0.marksOutputTrackAsEnabled } ?? inputs[0]
                let inputGroup = AVAssetWriterInputGroup(inputs: inputs, defaultInput: chosen)
                if writer.canAdd(inputGroup) { writer.add(inputGroup) }
            }
        }
        for track in tracks {
            guard let from = inputByTrack[track.trackID] else { continue }
            for kind in [AVAssetTrack.AssociationType.audioFallback, .chapterList, .forcedSubtitlesOnly, .selectionFollower] {
                guard let others = try? await track.loadAssociatedTracks(ofType: kind) else { continue }
                for other in others {
                    guard let to = inputByTrack[other.trackID], from.canAddTrackAssociation(withTrackOf: to, type: kind.rawValue) else { continue }
                    from.addTrackAssociation(withTrackOf: to, type: kind.rawValue)
                }
            }
        }

        guard reader.startReading() else { throw ScrubError.io(reader.error?.localizedDescription ?? "cannot read the movie") }
        guard writer.startWriting() else { throw ScrubError.io(writer.error?.localizedDescription ?? "cannot write the movie") }
        writer.startSession(atSourceTime: .zero)

        let failure = FailureBox()
        await withTaskGroup(of: Void.self) { group in
            for (index, lane) in lanes.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "cleanroom.copy.\(index)")
                        lane.input.requestMediaDataWhenReady(on: queue) {
                            while lane.input.isReadyForMoreMediaData {
                                guard failure.error == nil, let sample = lane.output.copyNextSampleBuffer() else {
                                    lane.input.markAsFinished()
                                    done.resume()
                                    return
                                }
                                lane.hash(sample)
                                if lane.isVideo, duration > 0, let progress {
                                    progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                                }
                                if !lane.input.append(sample) {
                                    failure.error = writer.error ?? ScrubError.io("a sample was refused")
                                    reader.cancelReading()
                                    lane.input.markAsFinished()
                                    done.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }

        if let error = failure.error {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw ScrubError.io("movie copy failed: \(error.localizedDescription)")
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw ScrubError.io("movie read failed: \(reader.error?.localizedDescription ?? "unknown")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw ScrubError.io("movie write failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
        return Result(notes: notes, digests: lanes.map { $0.digest() })
    }

    /// One SHA-256 per content track, over the compressed sample bytes, in
    /// track order. Two files with equal digests hold the same samples.
    static func sampleDigests(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        var lanes: [Lane] = []
        for track in try await asset.load(.tracks) where contentTypes.contains(track.mediaType) {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { continue }
            reader.add(out)
            lanes.append(Lane(output: out, input: nil, isVideo: false))
        }
        guard !lanes.isEmpty, reader.startReading() else { throw ScrubError.io("cannot read the movie samples") }
        for lane in lanes {
            while let sample = lane.output.copyNextSampleBuffer() { lane.hash(sample) }
        }
        guard reader.status == .completed else { throw ScrubError.io("movie read failed") }
        return lanes.map { $0.digest() }
    }

    /// Problems that the byte-level walk finds in a movie file: metadata
    /// atoms, and tracks that are not content. An empty list is a pass.
    static func atomAudit(_ data: Data) -> [String] {
        let b = Bytes(data)
        var problems: [String] = []
        guard let top = try? BMFF.boxes(b, from: 0, to: b.count) else { return ["the output does not parse as a movie"] }
        let contentHandlers: Set<String> = ["vide", "soun", "sbtl", "subt", "text", "clcp"]
        for box in top {
            switch box.type {
            case "uuid", "meta", "udta": problems.append("'\(box.type)' atom at the top level")
            case "moov":
                for child in (try? BMFF.boxes(b, from: box.payload, to: box.end)) ?? [] {
                    if child.type == "udta" || child.type == "meta" {
                        if child.size > 16 { problems.append("'\(child.type)' atom in the movie header (\(child.size) bytes)") }
                    } else if child.type == "trak" {
                        for part in (try? BMFF.boxes(b, from: child.payload, to: child.end)) ?? [] {
                            if part.type == "udta" || part.type == "meta" {
                                if part.size > 16 { problems.append("'\(part.type)' atom in a track (\(part.size) bytes)") }
                            } else if part.type == "mdia" {
                                for m in (try? BMFF.boxes(b, from: part.payload, to: part.end)) ?? [] where m.type == "hdlr" {
                                    let handler = (try? b.fourCC(m.payload + 8)) ?? "?"
                                    if !contentHandlers.contains(handler) { problems.append("track with handler '\(handler)'") }
                                }
                            }
                        }
                    }
                }
            default: break
            }
        }
        return problems
    }

    /// The creation time in the movie header, if it is set.
    static func headerCreationDate(_ data: Data) -> Date? {
        let b = Bytes(data)
        guard let top = try? BMFF.boxes(b, from: 0, to: b.count), let moov = top.first(where: { $0.type == "moov" }),
              let mvhd = (try? BMFF.boxes(b, from: moov.payload, to: moov.end))?.first(where: { $0.type == "mvhd" }),
              let version = try? b.u8(mvhd.payload) else { return nil }
        let seconds = version == 1 ? (try? b.be64(mvhd.payload + 4)) : (try? b.be32(mvhd.payload + 4))
        guard let s = seconds, s > 0 else { return nil }
        // Movie header times count seconds from 1904-01-01.
        return Date(timeIntervalSince1970: TimeInterval(s) - 2_082_844_800)
    }

    static func trackName(_ type: AVMediaType, _ format: CMFormatDescription?) -> String {
        let code = format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        let kind: String
        switch type {
        case .video: kind = "video"
        case .audio: kind = "audio"
        case .metadata: kind = "timed metadata"
        case .timecode: kind = "timecode"
        case .subtitle, .text: kind = "subtitles"
        case .closedCaption: kind = "captions"
        case .depthData: kind = "depth"
        case .haptic: kind = "haptics"
        default: kind = type.rawValue
        }
        return code.isEmpty ? kind : "\(kind), \(code)"
    }

    private static func trackPurpose(_ type: AVMediaType, _ format: CMFormatDescription?) -> String {
        if type == .metadata, let format {
            let ids = (CMMetadataFormatDescriptionGetIdentifiers(format) as? [String]) ?? []
            if !ids.isEmpty { return ids.map { $0.replacingOccurrences(of: "mdta/com.apple.quicktime.", with: "") }.prefix(4).joined(separator: ", ") }
            return "data recorded with each frame"
        }
        if type == .timecode { return "clock time of the first frame" }
        return "not picture or sound"
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}

/// One track on its way from the reader to the writer, with a running hash of
/// its sample bytes.
private final class Lane: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput!
    let isVideo: Bool
    private var hasher = SHA256()
    private var scratch = [UInt8]()

    init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput?, isVideo: Bool) {
        self.output = output
        self.input = input
        self.isVideo = isVideo
    }

    func hash(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        if scratch.count < length { scratch = [UInt8](repeating: 0, count: length) }
        let status = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr else { return }
        scratch.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<length])) }
    }

    func digest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; if stored == nil { stored = newValue } }
    }
}
