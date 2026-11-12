import CoreText
import SwiftUI

/// The five colors of DESIGN.md. `dim` and `faint` are the ink color at a
/// lower opacity: derived values, and not more colors.
enum Tone {
    static let void = Color(red: 0, green: 0, blue: 0)
    static let panel = Color(red: 0.043, green: 0.047, blue: 0.051)
    static let rule = Color(red: 0.165, green: 0.176, blue: 0.192)
    static let ink = Color(red: 0.949, green: 0.953, blue: 0.961)
    /// The one accent. It means "verified clean" and nothing else.
    static let signal = Color(red: 0.271, green: 0.878, blue: 0.541)

    static let dim = ink.opacity(0.58)
    static let faint = ink.opacity(0.34)
}

/// Spacing on an 8-point scale.
enum Space {
    static let half: CGFloat = 4
    static let one: CGFloat = 8
    static let two: CGFloat = 16
    static let three: CGFloat = 24
    static let four: CGFloat = 32
}

enum Face {
    /// JetBrains Mono: labels, readouts, buttons.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .semibold, .heavy, .black: name = "JetBrainsMono-Bold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return .custom(name, size: size, relativeTo: .footnote)
    }

    /// Inter: sentences.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .semibold, .heavy, .black: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    private static var registered = false

    /// Loads the font files of this bundle. The app and the share extension
    /// each carry their own copies.
    static func register() {
        guard !registered else { return }
        registered = true
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Parts

/// A small capital label, like the legends on an instrument.
struct Legend: View {
    let text: String
    var color: Color = Tone.dim

    init(_ text: String, color: Color = Tone.dim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Face.mono(10.5, .medium))
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A one-point line.
struct Rule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Tone.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Four corner brackets around a region.
struct Brackets: Shape {
    var arm: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return path
    }
}

/// A row of ticks that fills from the left: progress, or a share of a total.
struct TickBar: View {
    var fraction: Double
    var color: Color = Tone.ink
    var count = 48

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(count)
            let lit = Int((Double(count) * min(max(fraction, 0), 1)).rounded())
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * step, y: 0, width: max(1, step * 0.45), height: size.height)
                context.fill(Path(rect), with: .color(index < lit ? color : Tone.rule))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// An inverse label for a kind of leak.
struct Chip: View {
    let text: String
    var filled = true

    var body: some View {
        Text(text)
            .font(Face.mono(9.5, .bold))
            .tracking(1)
            .foregroundStyle(filled ? Tone.void : Tone.dim)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(filled ? Tone.ink : Color.clear)
            .overlay(Rectangle().stroke(filled ? Color.clear : Tone.rule, lineWidth: 1))
    }
}

/// A full-width button. `primary` is a solid block, the other kind an outline.
struct BlockButton: View {
    let title: String
    var primary = false
    var tint: Color = Tone.ink
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Face.mono(13, .bold))
                .tracking(1.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, Space.one)
                .foregroundStyle(primary ? Tone.void : (enabled ? tint : Tone.faint))
                .background(primary ? (enabled ? tint : Tone.faint) : Color.clear)
                .overlay(Rectangle().stroke(primary ? Color.clear : (enabled ? tint.opacity(0.7) : Tone.rule), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .disabled(!enabled)
    }
}

struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A label over a value, used in the status strip.
struct Readout: View {
    let label: String
    let value: String
    var color: Color = Tone.ink

    var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            Legend(label, color: Tone.faint)
            Text(value)
                .font(Face.mono(13, .medium))
                .tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.two)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension Int {
    /// "2.7 MB", "19.7 KB", "412 B".
    var byteText: String {
        let value = Double(self)
        if abs(value) >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if abs(value) >= 1024 { return String(format: "%.1f KB", value / 1024) }
        return "\(self) B"
    }
}
