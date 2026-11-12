import ScrubKit
import SwiftUI

/// Everything known about one file: the checks, each field and its fate, and
/// the container parts the byte-level pass touched.
struct LedgerView: View {
    let item: Bench.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: Space.half) {
                    Legend("Ledger", color: Tone.faint)
                    Text(title)
                        .font(Face.mono(13, .medium))
                        .foregroundStyle(Tone.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button { dismiss() } label: {
                    Text("[ CLOSE ]")
                        .font(Face.mono(11, .medium))
                        .tracking(1.2)
                        .foregroundStyle(Tone.ink)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(PressDim())
            }
            .padding(.horizontal, Space.two)
            .padding(.vertical, Space.one)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let outcome = item.outcome {
                        verify(outcome)
                        fields(title: "Removed", tags: outcome.removed, struck: true)
                        fields(title: "Kept: rendering facts", tags: outcome.kept, struck: false)
                        container(outcome.notes)
                    } else if let found = item.inspection {
                        if case .failed(let why) = item.state { failure(why) }
                        fields(title: "Found", tags: found.risky, struck: false)
                        fields(title: "Rendering facts", tags: found.tags.filter { $0.risk == .technical }, struck: false)
                        container(item.plan)
                    } else {
                        Legend("Reading").padding(Space.two)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Tone.void.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.hidden)
        .presentationBackground(Tone.void)
    }

    private var title: String {
        if let output = item.outcome?.output { return "\(item.name)  ->  \(output.lastPathComponent)" }
        return item.name
    }

    // MARK: - Sections

    private func section(_ name: String, count: Int? = nil, color: Color = Tone.dim) -> some View {
        HStack {
            Legend(name, color: color)
            Spacer()
            if let count { Legend("\(count)", color: Tone.faint) }
        }
        .padding(.horizontal, Space.two)
        .padding(.top, Space.three)
        .padding(.bottom, Space.one)
    }

    private func verify(_ outcome: ScrubOutcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.one) {
                Rectangle().fill(outcome.passed ? Tone.signal : Tone.ink).frame(width: 10, height: 10)
                Text(outcome.passed ? "VERIFIED CLEAN" : "NOT CLEAN")
                    .font(Face.mono(15, .bold))
                    .tracking(2)
                    .foregroundStyle(outcome.passed ? Tone.signal : Tone.ink)
                Spacer()
                Legend(outcome.method == .lossless ? "No re-encode" : "Rebuilt")
            }
            .padding(Space.two)
            ForEach(outcome.checks) { check in
                Rule()
                HStack(alignment: .top, spacing: Space.one) {
                    Text(check.passed ? "OK" : "FAIL")
                        .font(Face.mono(11, .bold))
                        .foregroundStyle(check.passed ? Tone.signal : Tone.void)
                        .padding(.horizontal, check.passed ? 0 : 4)
                        .background(check.passed ? Color.clear : Tone.ink)
                        .frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Legend(check.name, color: Tone.ink)
                        Text(check.detail)
                            .font(Face.text(13))
                            .foregroundStyle(Tone.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.two)
                .padding(.vertical, 10)
            }
            Rule()
            HStack(spacing: 0) {
                Readout(label: "Before", value: outcome.before.byteCount.byteText)
                Rule(vertical: true)
                Readout(label: "After", value: outcome.after.byteCount.byteText)
                Rule(vertical: true)
                Readout(label: "Fields out", value: "\(outcome.removed.count)")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(Rectangle().stroke(Tone.rule, lineWidth: 1))
        .padding(Space.two)
    }

    private func failure(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: Space.one) {
            Chip(text: "NOT CLEAN: NO FILE WRITTEN")
            Text(why).font(Face.text(13)).foregroundStyle(Tone.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.two)
    }

    @ViewBuilder private func fields(title: String, tags: [Tag], struck: Bool) -> some View {
        if !tags.isEmpty {
            section(title, count: tags.count)
            Rule()
            let groups = Dictionary(grouping: tags, by: \.risk)
            ForEach(Risk.allCases.filter { groups[$0] != nil }, id: \.self) { risk in
                HStack(spacing: Space.one) {
                    Chip(text: risk.label, filled: risk != .technical)
                    Legend("\(groups[risk]?.count ?? 0)", color: Tone.faint)
                }
                .padding(.horizontal, Space.two)
                .padding(.top, 12)
                .padding(.bottom, 4)
                ForEach(groups[risk] ?? []) { tag in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(tag.group) \(tag.key)")
                            .font(Face.mono(12, .medium))
                            .foregroundStyle(struck ? Tone.dim : Tone.ink)
                        Text(tag.value.isEmpty ? "(empty)" : tag.value)
                            .font(Face.mono(12))
                            .foregroundStyle(Tone.dim)
                            .strikethrough(struck, color: Tone.dim)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Space.two)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                Rule().padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func container(_ notes: [ContainerNote]) -> some View {
        if !notes.isEmpty {
            section("Container", count: notes.count)
            Rule()
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: Space.one) {
                    Text(note.action.rawValue.uppercased())
                        .font(Face.mono(10, .bold))
                        .tracking(0.8)
                        .foregroundStyle(note.action == .kept ? Tone.faint : Tone.ink)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(note.item).font(Face.mono(12, .medium)).foregroundStyle(Tone.ink)
                            Spacer()
                            if note.bytes > 0 { Legend(note.bytes.byteText, color: Tone.faint) }
                        }
                        Text(note.detail)
                            .font(Face.text(13))
                            .foregroundStyle(Tone.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.two)
                .padding(.vertical, 10)
                Rule()
            }
            Color.clear.frame(height: Space.four)
        }
    }
}

/// What the app does, in plain words, and the one setting.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var randomNames = Bench.randomNames

    private let points: [(String, String)] = [
        ("What goes", "Place, time, camera and owner fields. Maker notes. Embedded thumbnails. Text comments. Content credentials. Data after the end of the picture. In a movie: every metadata atom, and every track that is not picture, sound or captions."),
        ("What stays", "The compressed picture, byte for byte. The rotation. The color profile. The HDR gain map. A new file holds only these."),
        ("Rebuilt files", "TIFF, GIF and RAW pictures have no byte-level scrubber. Cleanroom decodes those and encodes a new file from the pixels, and the row says REBUILT FROM PIXELS."),
        ("How it checks", "After each scrub, the system's own parser reads the new file, and the app shows VERIFIED CLEAN only when that parser finds nothing but rendering facts and the decoded picture is identical. A file that fails is not written."),
        ("Live Photos", "A Live Photo comes out as a still. Its motion and its sound stay behind."),
        ("What it cannot do", "It does not change what the picture shows: a street sign, a face or a screen in the frame is still there. It cannot remove the noise pattern of a camera sensor or the traces an encoder leaves in the compressed data."),
        ("Network", "None. The app has no code that opens a connection. You can confirm it in Settings, Privacy & Security, App Privacy Report."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Legend("Info", color: Tone.faint)
                Spacer()
                Button { dismiss() } label: {
                    Text("[ CLOSE ]").font(Face.mono(11, .medium)).tracking(1.2).foregroundStyle(Tone.ink).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(PressDim())
            }
            .padding(.horizontal, Space.two)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.three) {
                    Button {
                        randomNames.toggle()
                        Bench.randomNames = randomNames
                    } label: {
                        HStack(alignment: .top, spacing: Space.two) {
                            Text(randomNames ? "[X]" : "[ ]").font(Face.mono(14, .bold)).foregroundStyle(Tone.ink)
                            VStack(alignment: .leading, spacing: Space.half) {
                                Legend("Random file names", color: Tone.ink)
                                Text("A name like IMG_4123 tells how many pictures the phone took before this one.")
                                    .font(Face.text(13)).foregroundStyle(Tone.dim).multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(Space.two)
                        .overlay(Rectangle().stroke(Tone.rule, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                    .accessibilityValue(randomNames ? "On" : "Off")

                    ForEach(points, id: \.0) { point in
                        VStack(alignment: .leading, spacing: Space.one) {
                            Legend(point.0, color: Tone.ink)
                            Text(point.1)
                                .font(Face.text(15))
                                .foregroundStyle(Tone.dim)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Rule()
                    VStack(alignment: .leading, spacing: Space.half) {
                        Legend("Cleanroom \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))", color: Tone.faint)
                        Text("Open source, MIT license. Type: JetBrains Mono and Inter, both under the SIL Open Font License.")
                            .font(Face.text(12)).foregroundStyle(Tone.faint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.two)
            }
        }
        .background(Tone.void.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationBackground(Tone.void)
    }
}
