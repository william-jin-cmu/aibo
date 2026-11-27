import SwiftUI
import UIKit

// Sticker-book styling, ported from Bower: things sit on dotted paper as die-cut stickers,
// each with a white edge, a crisp contact shadow and, for the playful ones, a slight tilt.
// Aibo's paper is blue-black (the deep sea she lives in); light values are kept for later.

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A color that switches with light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Screen background: the paper.
    static let paperBase = Color(light: 0xF6F8FC, dark: 0x0E131D)
    /// Cards, chips and her bubbles on top of the paper.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1A2131)
    /// Fields and quieter fills on top of `surface`.
    static let surfaceMuted = Color(light: 0xEEF2F8, dark: 0x252E42)
    static let ink = Color(light: 0x1C2333, dark: 0xEEF2FA)
    static let inkSoft = Color(light: 0x6B7690, dark: 0x93A0B8)
    static let line = Color(light: 0xE3E8F0, dark: 0x2A3346)
    /// Her color: the character pack's sea blue. The one main action and highlights.
    static let sea = Color(light: 0x3E8EDB, dark: 0x8FD8FF)
    /// Your bubbles.
    static let tide = Color(light: 0xDCEBFF, dark: 0x22406A)
    static let coral = Color(light: 0xFF6B57, dark: 0xFF7A68)
    // Pastels, deeper at night so `ink` stays readable on them.
    static let butter = Color(light: 0xFFD66B, dark: 0x7D6526)
    static let mint = Color(light: 0x8FD9B6, dark: 0x2C6E58)
    static let sky = Color(light: 0x9CC8FF, dark: 0x34558A)
    static let lilac = Color(light: 0xC9B6FF, dark: 0x54478F)
    static let blush = Color(light: 0xFFC2CF, dark: 0x7E4157)
    static let shadow = Color(light: 0x1C2333, dark: 0x000000)
    /// The die-cut edge around stickers; stays near-white at night, like a real sticker.
    static let stickerEdge = Color(light: 0xFFFFFF, dark: 0xD9E2F0)
    /// The edge around bigger stickers (cards, bubbles): dropped at night, where it would read as an outline.
    static let cardEdge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .clear : .white })
    static let paperDot = Color(light: 0xDDE3EE, dark: 0x1C2434)
}

enum AiboFont {
    enum Weight {
        case regular, medium, semibold, bold, extrabold
        var system: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .extrabold: .heavy
            }
        }
    }

    /// SF Pro Rounded, scaled with Dynamic Type relative to `style`.
    static func rounded(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: UIFontMetrics(forTextStyle: style.uiKit).scaledValue(for: size), weight: weight.system, design: .rounded)
    }
}

private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension Font {
    static let aiboDisplay = AiboFont.rounded(34, .extrabold, relativeTo: .largeTitle)
    static let aiboTitle = AiboFont.rounded(22, .bold, relativeTo: .title2)
    static let aiboHeadline = AiboFont.rounded(17, .semibold, relativeTo: .headline)
    static let aiboBody = AiboFont.rounded(17, .regular, relativeTo: .body)
    static let aiboCallout = AiboFont.rounded(14, .medium, relativeTo: .callout)
    static let aiboCaption = AiboFont.rounded(12, .semibold, relativeTo: .caption)
}

// MARK: - Stickers

extension View {
    /// The shadow of a sticker lying on paper: a tight contact shadow plus a soft lift.
    func stickerShadow(lift: CGFloat = 1) -> some View {
        compositingGroup()
            .shadow(color: Color.shadow.opacity(0.22), radius: 1, y: 1)
            .shadow(color: Color.shadow.opacity(0.14 * lift), radius: 8 * lift, y: 4 * lift)
    }

    /// A sticker cut to `shape`: filled, with a white edge just inside its outline.
    /// `tag` marks small labels and avatars, which keep their edge at night too.
    func sticker<S: InsettableShape>(_ fill: some ShapeStyle, in shape: S, edge: CGFloat = 3, lift: CGFloat = 1, tag: Bool = false) -> some View {
        background(fill, in: shape)
            .overlay(shape.strokeBorder(tag ? Color.stickerEdge : Color.cardEdge, lineWidth: edge))
            .stickerShadow(lift: lift)
    }

    /// A big card: a sticker with rounded corners.
    func card(_ fill: Color = .surface, radius: CGFloat = 24) -> some View {
        sticker(fill, in: .rect(cornerRadius: radius, style: .continuous), edge: 3.5)
    }

    /// Liquid Glass behind a button's label.
    func glassButton<S: Shape>(_ tint: Color? = nil, in shape: S) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: shape)
            .contentShape(shape)
    }

    /// A round icon button in Liquid Glass.
    func glassIcon(compact: Bool = false) -> some View {
        font(.system(size: compact ? 13 : 16, weight: .semibold))
            .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
            .glassButton(in: .circle)
    }

    /// A die-cut edge that follows the content's own silhouette (emoji, symbols). Keep to static views.
    func dieCut(_ width: CGFloat = 3, lift: CGFloat = 0.6) -> some View {
        modifier(DieCut(width: width, lift: lift))
    }

    /// Leans a sticker by a small angle picked from `seed`, so the same thing always leans the same way.
    func tilt(_ seed: String, by maxDegrees: Double = 4) -> some View {
        let hash = seed.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return rotationEffect(.degrees((Double(hash % 1000) / 999 * 2 - 1) * maxDegrees))
    }

    /// Dotted paper behind a screen.
    func paper() -> some View {
        background { PaperBackground().ignoresSafeArea() }
    }
}

private struct DieCut: ViewModifier {
    let width: CGFloat
    let lift: CGFloat
    private static let steps = 12

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    ForEach(0..<Self.steps, id: \.self) { i in
                        let a = Double(i) / Double(Self.steps) * 2 * .pi
                        content.offset(x: cos(a) * width, y: sin(a) * width)
                    }
                    content
                }
                .brightness(1)
                .colorMultiply(.stickerEdge)
                .accessibilityHidden(true)
            }
            .stickerShadow(lift: lift)
    }
}

struct PaperBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let dot: CGFloat = 2.2
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)), with: .color(.paperDot))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(Color.paperBase)
    }
}

/// An emoji as a die-cut sticker.
struct StickerEmoji: View {
    let emoji: String
    var size: CGFloat = 44
    var tilt: Double = 6

    var body: some View {
        Text(emoji)
            .font(.system(size: size))
            .dieCut(max(2, size * 0.07))
            .tilt(emoji, by: tilt)
    }
}

/// Her face: the app icon as a round sticker with a white edge. This is how she shows up everywhere.
struct Avatar: View {
    var size: CGFloat = 30

    var body: some View {
        Image("Avatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.circle)
            .sticker(Color.surface, in: .circle, edge: max(1.5, size * 0.06), lift: 0.4, tag: true)
            .accessibilityHidden(true)
    }
}

struct Pill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .butter

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
            Text(text).font(.aiboCaption)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sticker(tint, in: .capsule, edge: 2, lift: 0.4, tag: true)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.aiboTitle).foregroundStyle(Color.ink)
            Spacer()
            if let trailing { Text(trailing).font(.aiboCallout).foregroundStyle(Color.inkSoft) }
        }
    }
}

/// Full-width capsule button: the one main action (sea) or a quiet glass one.
struct WideButton: View {
    let title: String
    var symbol: String? = nil
    var primary = true
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(primary ? Color.paperBase : .ink)
                } else {
                    HStack(spacing: 8) {
                        if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .bold)) }
                        Text(title)
                    }
                }
            }
            .font(AiboFont.rounded(17, primary ? .bold : .semibold))
            .foregroundStyle(primary ? Color.paperBase : .ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .glassButton(primary ? (enabled ? Color.sea : Color.inkSoft.opacity(0.4)) : nil, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

/// Quick replies under her messages (choices in onboarding).
struct QuickReply: View {
    var title: String
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AiboFont.rounded(15, .semibold))
                .foregroundStyle(primary ? Color.paperBase : Color.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .sticker(primary ? Color.sea : Color.surface, in: .capsule, edge: 2.5, lift: 0.5, tag: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chat pieces

/// A reply split the way a person texts: the stage direction becomes a small caption,
/// and each paragraph becomes its own bubble.
struct ReplyParts {
    var direction: String?
    var bubbles: [String]

    init(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var directions: [String] = []
        while let first = rest.first, first == "（" || first == "(" {
            let close: Character = first == "（" ? "）" : ")"
            guard let end = rest.firstIndex(of: close) else { break }
            directions.append(String(rest[rest.index(after: rest.startIndex)..<end]))
            rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        bubbles = rest
            .components(separatedBy: "\n\n")
            .map { p -> String in
                var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
                while let f = s.first, f == "（" || f == "(" {
                    let close: Character = f == "（" ? "）" : ")"
                    guard let e = s.firstIndex(of: close) else { break }
                    s = String(s[s.index(after: e)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty }
        direction = directions.first
    }
}

/// Her bubble (left, surface) or yours (right, tide). Each points at its sender with a small corner.
struct Bubble: View {
    var text: String
    var mine = false

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            Text(text)
                .font(mine ? AiboFont.rounded(17, .medium) : .aiboBody)
                .lineSpacing(4)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .sticker(mine ? Color.tide : Color.surface, in: shape, edge: 2.5, lift: 0.4)
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: mine ? 22 : 6, bottomTrailingRadius: mine ? 6 : 22, topTrailingRadius: 22, style: .continuous)
    }
}

/// Small italic caption above her bubbles: what she's doing as she speaks.
struct DirectionCaption: View {
    var text: String
    var body: some View {
        Text(text)
            .font(AiboFont.rounded(13, .medium).italic())
            .foregroundStyle(Color.inkSoft)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three bouncing dots while she thinks, with an optional line about what she's doing.
struct TypingBubble: View {
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.inkSoft.opacity(0.55))
                            .frame(width: 7, height: 7)
                            .offset(y: -4 * max(0, sin(t * 6 - Double(i) * 0.7)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .sticker(Color.surface, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 22, style: .continuous), edge: 2.5, lift: 0.4)
            if let label {
                Text(label).font(.aiboCaption).foregroundStyle(Color.inkSoft).padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Typing")
    }
}
