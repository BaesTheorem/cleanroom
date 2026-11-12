import ScrubKit
import SwiftUI
import UniformTypeIdentifiers

/// The one screen: a status strip, the files, and the actions.
struct BenchView: View {
    @Bindable var bench: Bench
    /// Set in the share extension. It closes the extension.
    var onDone: (() -> Void)?

    @State private var showLibrary = false
    @State private var showFiles = false
    @State private var showAbout = false
    @State private var sharing: ShareBundle?
    @State private var opened: Bench.Item.ID?

    private var inExtension: Bool { onDone != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            statusStrip
            Rule()
            if bench.items.isEmpty {
                emptyState
            } else {
                fileList
            }
            Rule()
            actions
        }
        .background(Tone.void.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.small ... .xxLarge)
        .sheet(isPresented: $showLibrary) {
            LibraryPicker { providers in
                Task { await bench.add(providers: providers) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { bench.add(files: urls) }
        }
        .sheet(item: $sharing) { bundle in
            ActivitySheet(urls: bundle.urls).ignoresSafeArea()
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        #if DEBUG
        .task {
            // For screenshots in the simulator.
            let env = ProcessInfo.processInfo.environment
            if env["CLEANROOM_ABOUT"] == "1" { showAbout = true }
            if let index = env["CLEANROOM_OPEN"].flatMap(Int.init) {
                for _ in 0..<400 where !(bench.items.indices.contains(index) && (env["CLEANROOM_AUTOSCRUB"] != "1" || bench.allDone)) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if bench.items.indices.contains(index) { opened = bench.items[index].id }
            }
        }
        #endif
        .sheet(item: Binding(get: { opened.map(Opened.init) }, set: { opened = $0?.id })) { open in
            if let item = bench.items.first(where: { $0.id == open.id }) {
                LedgerView(item: item)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.one) {
            Rectangle().fill(statusColor).frame(width: 10, height: 10)
            Text("CLEANROOM")
                .font(Face.mono(17, .bold))
                .tracking(3)
                .foregroundStyle(Tone.ink)
            Spacer()
            Button { showAbout = true } label: {
                Text("[ INFO ]")
                    .font(Face.mono(11, .medium))
                    .tracking(1.2)
                    .foregroundStyle(Tone.dim)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(PressDim())
            .accessibilityLabel("About Cleanroom")
        }
        .padding(.horizontal, Space.two)
        .padding(.vertical, Space.half)
    }

    private var statusColor: Color {
        if bench.failedCount > 0 { return Tone.ink }
        return bench.allDone ? Tone.signal : Tone.rule
    }

    private var statusStrip: some View {
        HStack(spacing: 0) {
            Readout(label: "Files", value: String(format: "%02d", bench.items.count))
            Rule(vertical: true)
            Readout(label: "Removed", value: bench.removedTotal == 0 ? "--" : "\(bench.removedTotal)")
            Rule(vertical: true)
            Readout(label: "State", value: stateWord, color: bench.allDone && bench.failedCount == 0 ? Tone.signal : Tone.ink)
            Rule(vertical: true)
            Readout(label: "Network", value: "NONE")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stateWord: String {
        if bench.isLoading { return "LOADING" }
        if bench.isScrubbing { return "WORKING" }
        if bench.items.isEmpty { return "IDLE" }
        if bench.failedCount > 0 { return "CHECK" }
        if bench.allDone { return "CLEAN" }
        return "LOADED"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.three) {
            Spacer(minLength: Space.two)
            VStack(alignment: .leading, spacing: Space.two) {
                Legend(bench.isLoading ? "Loading files" : "No files loaded")
                Text("A photo carries the place, the time and the phone that made it. Load files here before you send them.")
                    .font(Face.text(17))
                    .foregroundStyle(Tone.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Cleanroom removes that data without a re-encode, then checks the result. It has no access to your library and it never uses the network.")
                    .font(Face.text(14))
                    .foregroundStyle(Tone.dim)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.three)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Brackets().stroke(Tone.dim, lineWidth: 1))
            Spacer(minLength: Space.two)
        }
        .padding(.horizontal, Space.two)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Files

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(bench.items) { item in
                    Button { opened = item.id } label: { FileRow(item: item) }
                        .buttonStyle(PressDim())
                    Rule()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        VStack(spacing: Space.one) {
            if let saved = bench.savedCount {
                Legend(saved == 1 ? "1 file saved to Photos" : "\(saved) files saved to Photos", color: Tone.signal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = bench.saveError {
                Text(error).font(Face.text(13)).foregroundStyle(Tone.ink).frame(maxWidth: .infinity, alignment: .leading)
            }
            if bench.items.isEmpty {
                if !inExtension {
                    BlockButton(title: "+ Photo library", primary: true) { showLibrary = true }
                    BlockButton(title: "+ Files") { showFiles = true }
                } else {
                    BlockButton(title: "Close") { onDone?() }
                }
            } else if bench.pending > 0 || bench.isScrubbing {
                BlockButton(title: bench.isScrubbing ? "Scrubbing" : (bench.pending == 1 ? "Scrub 1 file" : "Scrub \(bench.pending) files"),
                            primary: true, enabled: !bench.isScrubbing) {
                    Task { await bench.scrubAll() }
                }
                if !inExtension {
                    HStack(spacing: Space.one) {
                        BlockButton(title: "+ Add", enabled: !bench.isScrubbing) { showLibrary = true }
                        BlockButton(title: "Clear", enabled: !bench.isScrubbing) { bench.clear() }
                    }
                }
            } else {
                let clean = bench.cleanURLs
                BlockButton(title: clean.count == 1 ? "Share clean copy" : "Share \(clean.count) clean copies", primary: true, tint: Tone.signal,
                            enabled: !clean.isEmpty) {
                    sharing = ShareBundle(urls: clean)
                }
                HStack(spacing: Space.one) {
                    BlockButton(title: "Save to Photos", enabled: !clean.isEmpty) { Task { await bench.saveToPhotos() } }
                    if inExtension {
                        BlockButton(title: "Done") { onDone?() }
                    } else {
                        BlockButton(title: "Clear") { bench.clear() }
                    }
                }
            }
        }
        .padding(Space.two)
    }
}

private struct Opened: Identifiable {
    let id: Bench.Item.ID
}

struct ShareBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Row

struct FileRow: View {
    let item: Bench.Item

    var body: some View {
        HStack(alignment: .top, spacing: Space.two) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shownName)
                        .font(Face.mono(13, .medium))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.one)
                    Legend(sizeLine, color: Tone.faint)
                }
                summary
                TickBar(fraction: fraction, color: barColor)
                stateLine
            }
        }
        .padding(.horizontal, Space.two)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the list of fields")
    }

    private var thumbnail: some View {
        ZStack {
            Tone.panel
            if let image = item.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .overlay(Rectangle().stroke(Tone.rule, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var shownName: String {
        if let output = item.outcome?.output { return output.lastPathComponent }
        return item.name
    }

    private var sizeLine: String {
        guard let found = item.inspection else { return "" }
        let size = (item.outcome?.after.byteCount ?? found.byteCount).byteText
        return found.typeName.isEmpty ? size : "\(found.typeName) \(size)"
    }

    @ViewBuilder private var summary: some View {
        if let outcome = item.outcome, outcome.passed {
            Text("\(outcome.removed.count) fields removed, \(outcome.kept.count) rendering facts kept")
                .font(Face.mono(11))
                .foregroundStyle(Tone.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let found = item.inspection {
            HStack(spacing: Space.half) {
                Text("\(found.risky.count) fields")
                    .font(Face.mono(11))
                    .foregroundStyle(Tone.dim)
                ForEach(Risk.allCases.filter { $0 != .technical && $0 != .content && found.count($0) > 0 }.prefix(3), id: \.self) { risk in
                    Chip(text: risk.label)
                }
            }
            .lineLimit(1)
        } else {
            Text("reading").font(Face.mono(11)).foregroundStyle(Tone.faint)
        }
    }

    private var fraction: Double {
        switch item.state {
        case .reading, .ready: return 0
        case .scrubbing(let done): return max(0.04, done)
        case .clean, .failed: return 1
        }
    }

    private var barColor: Color {
        switch item.state {
        case .clean: return Tone.signal
        case .failed: return Tone.faint
        default: return Tone.ink
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch item.state {
        case .reading: Legend("Reading", color: Tone.faint)
        case .ready: Legend("Ready", color: Tone.dim)
        case .scrubbing(let done): Legend(done > 0 ? "Scrubbing \(Int(done * 100))%" : "Scrubbing")
        case .clean:
            HStack(spacing: Space.one) {
                Legend("Verified clean", color: Tone.signal)
                if let outcome = item.outcome {
                    Legend(outcome.method == .lossless ? "No re-encode" : "Rebuilt from pixels", color: Tone.dim)
                }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 2) {
                Chip(text: "NOT CLEAN: NO FILE WRITTEN")
                Text(why).font(Face.text(12)).foregroundStyle(Tone.dim).lineLimit(3)
            }
        }
    }
}
