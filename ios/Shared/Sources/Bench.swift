import AVFoundation
import ImageIO
import Photos
import ScrubKit
import SwiftUI
import UniformTypeIdentifiers

/// The files on the bench and what happened to each. One instance drives the
/// app, and one drives the share extension.
@MainActor
@Observable
final class Bench {
    struct Item: Identifiable {
        enum State: Equatable {
            case reading
            case ready
            case scrubbing(Double)
            case clean
            case failed(String)
        }

        let id = UUID()
        let source: URL
        let name: String
        var state: State = .reading
        var inspection: Inspection?
        var plan: [ContainerNote] = []
        var outcome: ScrubOutcome?
        var thumbnail: UIImage?

        var isDone: Bool {
            switch state {
            case .clean, .failed: return true
            default: return false
            }
        }
    }

    var items: [Item] = []
    var isScrubbing = false
    var isLoading = false
    var savedCount: Int?
    var saveError: String?

    /// Longest side of the before and after comparison. The share extension
    /// runs with less memory, so it uses a smaller value.
    var comparisonSize = 1024

    private let inbox: URL
    private let outbox: URL

    init(scope: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanroom-" + scope)
        inbox = root.appendingPathComponent("in")
        outbox = root.appendingPathComponent("out")
        // Files from an earlier session never stay on disk.
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    var cleanURLs: [URL] { items.compactMap { $0.outcome?.passed == true ? $0.outcome?.output : nil } }
    var pending: Int { items.filter { $0.state == .ready }.count }
    var cleanCount: Int { items.filter { $0.state == .clean }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var removedTotal: Int { items.reduce(0) { $0 + ($1.outcome?.removed.count ?? 0) } }
    var allDone: Bool { !items.isEmpty && items.allSatisfy(\.isDone) }

    static var randomNames: Bool {
        get { UserDefaults.standard.object(forKey: "randomNames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "randomNames") }
    }

    // MARK: - Intake

    /// A fresh folder for one incoming file, so two files with one name do not collide.
    func slot(for name: String) -> URL {
        let folder = inbox.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    /// Copies files from the Files picker. The URLs are security-scoped.
    func add(files: [URL]) {
        var copies: [URL] = []
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = slot(for: url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { copies.append(copy) }
        }
        add(copies: copies)
    }

    /// Loads the file behind each item provider (the photo picker and the
    /// share sheet both hand over providers).
    func add(providers: [NSItemProvider]) async {
        isLoading = true
        var copies: [URL] = []
        for provider in providers {
            if let copy = await Self.load(provider, into: { self.slot(for: $0) }) { copies.append(copy) }
        }
        isLoading = false
        add(copies: copies)
    }

    private func add(copies: [URL]) {
        for copy in copies {
            let item = Item(source: copy, name: copy.lastPathComponent)
            items.append(item)
            let id = item.id
            Task {
                let inspection = await Cleanroom.inspect(copy)
                let plan = await Task.detached { Cleanroom.preview(copy) }.value
                let thumbnail = await Self.thumbnail(copy, kind: inspection.kind)
                self.update(id) { item in
                    item.inspection = inspection
                    item.plan = plan
                    item.thumbnail = thumbnail
                    item.state = inspection.kind == .unknown ? .failed("This is not a picture or a movie that Cleanroom can read.") : .ready
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// A still picture has several representations in one provider. The order
    /// here takes the still of a Live Photo, so its sound and motion stay behind.
    private nonisolated static func load(_ provider: NSItemProvider, into slot: @escaping @MainActor (String) -> URL) async -> URL? {
        let types = provider.registeredTypeIdentifiers
        func first(_ parent: UTType) -> String? { types.first { UTType($0)?.conforms(to: parent) == true } }
        guard let type = first(.image) ?? first(.movie) ?? first(.audiovisualContent) else { return nil }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                // The system deletes `url` when this block returns, so copy now.
                let ext = url.pathExtension
                var name = url.lastPathComponent
                if let suggested, !suggested.isEmpty {
                    name = (suggested as NSString).pathExtension.isEmpty ? suggested + "." + ext : suggested
                }
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                guard (try? FileManager.default.copyItem(at: url, to: scratch)) != nil else { done.resume(returning: nil); return }
                Task { @MainActor in
                    let home = slot(name)
                    if (try? FileManager.default.moveItem(at: scratch, to: home)) != nil { done.resume(returning: home) }
                    else { done.resume(returning: nil) }
                }
            }
        }
    }

    private nonisolated static func thumbnail(_ url: URL, kind: MediaKind) async -> UIImage? {
        if kind == .movie {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return UIImage(cgImage: frame)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: - Scrub

    func scrubAll() async {
        guard !isScrubbing else { return }
        isScrubbing = true
        defer { isScrubbing = false }
        let options = ScrubOptions(randomNames: Self.randomNames, comparisonSize: comparisonSize)
        for item in items where item.state == .ready {
            let id = item.id
            update(id) { $0.state = .scrubbing(0) }
            do {
                let outcome = try await Cleanroom.scrub(item.source, into: outbox, options: options) { fraction in
                    Task { @MainActor in
                        self.update(id) { item in
                            if case .scrubbing = item.state { item.state = .scrubbing(fraction) }
                        }
                    }
                }
                update(id) { item in
                    item.outcome = outcome
                    if outcome.passed {
                        item.state = .clean
                    } else {
                        let failed = outcome.checks.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }
                        item.state = .failed(failed.isEmpty ? "The result did not pass its checks." : failed.joined(separator: "\n"))
                    }
                }
            } catch {
                update(id) { $0.state = .failed("\(error)") }
            }
            // The copy of the original has done its work.
            try? FileManager.default.removeItem(at: item.source.deletingLastPathComponent())
        }
        if failedCount == 0, cleanCount > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if failedCount > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func clear() {
        items.removeAll()
        savedCount = nil
        saveError = nil
        for folder in [inbox, outbox] {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: - Save

    /// Adds the clean copies to the photo library. This asks for add-only
    /// access: the app can put pictures in, and it cannot read any.
    func saveToPhotos() async {
        saveError = nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveError = "Photos did not give permission to add pictures. Change it in Settings."
            return
        }
        let urls = cleanURLs
        var saved = 0
        for url in urls {
            let isMovie = Cleanroom.kind(of: url) == .movie
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: isMovie ? .video : .photo, fileURL: url, options: options)
                    request.creationDate = Date()
                    request.location = nil
                }
                saved += 1
            } catch {
                saveError = "Photos refused \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        savedCount = saved
        if saved > 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}
