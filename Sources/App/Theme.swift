import SwiftUI
import AppKit

struct Palette: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let bg: UInt32, bg2: UInt32, surface: UInt32, surface2: UInt32, surface3: UInt32
    let accent: UInt32, accent2: UInt32

    static let all: [Palette] = [
        Palette(id: "sunset", name: "Sunset Stage", isDark: true,
                bg: 0x0E0E10, bg2: 0x121214, surface: 0x18181B, surface2: 0x202024, surface3: 0x2A2A2F,
                accent: 0xFF9A4D, accent2: 0xFF6A5C),
        Palette(id: "midnight", name: "Midnight Blue", isDark: true,
                bg: 0x0B0C10, bg2: 0x0F1116, surface: 0x15171E, surface2: 0x1C1F28, surface3: 0x272B36,
                accent: 0x7C8CFF, accent2: 0x9D7BFF),
        Palette(id: "forest", name: "Forest Session", isDark: true,
                bg: 0x0B0E0D, bg2: 0x0F1312, surface: 0x151A18, surface2: 0x1C2320, surface3: 0x26302B,
                accent: 0x4FD69A, accent2: 0x2BB8C9),
        Palette(id: "neon", name: "Neon Arcade", isDark: true,
                bg: 0x0D0B10, bg2: 0x121016, surface: 0x18151D, surface2: 0x201C27, surface3: 0x2B2634,
                accent: 0xF06BD0, accent2: 0x8B6BFF),
        Palette(id: "mahogany", name: "Mahogany", isDark: true,
                bg: 0x100D0B, bg2: 0x15110E, surface: 0x1C1714, surface2: 0x241E1A, surface3: 0x302823,
                accent: 0xE6AE68, accent2: 0xD06A4A),
        Palette(id: "paper", name: "Studio Light", isDark: false,
                bg: 0xF6F5F2, bg2: 0xEFEEEA, surface: 0xFFFFFF, surface2: 0xF2F1EE, surface3: 0xE7E5E0,
                accent: 0xE8792B, accent2: 0xE0424F)
    ]
    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? all[0] }
}

enum Theme {
    static var palette: Palette = .all[0]

    private static var ink: Color { palette.isDark ? .white : Color(hex: 0x16140F) }
    static var bg: Color { Color(hex: palette.bg) }
    static var bg2: Color { Color(hex: palette.bg2) }
    static var surface: Color { Color(hex: palette.surface) }
    static var surface2: Color { Color(hex: palette.surface2) }
    static var surface3: Color { Color(hex: palette.surface3) }
    static var stroke: Color { ink.opacity(palette.isDark ? 0.06 : 0.08) }
    static var strokeStrong: Color { ink.opacity(palette.isDark ? 0.11 : 0.13) }
    /// Quiet fills for controls, chips and pills (no outlines).
    static var fill: Color { ink.opacity(palette.isDark ? 0.07 : 0.055) }
    static var fillHover: Color { ink.opacity(palette.isDark ? 0.11 : 0.09) }
    static var text: Color { ink.opacity(0.96) }
    static var textDim: Color { ink.opacity(palette.isDark ? 0.62 : 0.64) }
    static var textFaint: Color { ink.opacity(palette.isDark ? 0.36 : 0.40) }
    static var track: Color { ink.opacity(palette.isDark ? 0.08 : 0.10) }
    static var colorScheme: ColorScheme { palette.isDark ? .dark : .light }

    static var accent: Color { Color(hex: palette.accent) }
    static var accent2: Color { Color(hex: palette.accent2) }
    /// Text on an accent fill: dark on light accents, white on deep ones.
    static var onAccent: Color { luminance(palette.accent) > 0.63 ? Color.black.opacity(0.86) : .white }
    static func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
    static func lighter(_ c: Color, _ f: CGFloat) -> Color {
        Color(nsColor: NSColor(c).usingColorSpace(.sRGB)?.blended(withFraction: f, of: .white) ?? NSColor(c))
    }
    static let success = Color(hex: 0x2FCB88)
    static let info = Color(hex: 0x4C9DFF)
    static let warn = Color(hex: 0xF5B83D)
    static let danger = Color(hex: 0xFF6B6B)
    static let violet = Color(hex: 0x9C82FF)
    static let teal = Color(hex: 0x2CC9C4)

    /// A near-flat fill with a soft top sheen — reads as solid colour, not a 2000s gradient.
    static var accentGradient: LinearGradient { LinearGradient(colors: [lighter(accent, 0.1), accent], startPoint: .top, endPoint: .bottom) }
    static var coolGradient: LinearGradient { LinearGradient(colors: [lighter(info, 0.1), info], startPoint: .top, endPoint: .bottom) }
    static var greenGradient: LinearGradient { LinearGradient(colors: [lighter(success, 0.1), success], startPoint: .top, endPoint: .bottom) }

    static func levelColor(_ level: Int) -> Color {
        switch level {
        case ...1: return success
        case 2: return teal
        case 3: return info
        case 4: return violet
        default: return accent2
        }
    }

    /// SF Pro throughout; the heaviest weights are capped at bold for a calmer, modern look.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let w: Font.Weight = (weight == .heavy || weight == .black) ? .bold : weight
        return .system(size: size, weight: w)
    }

    /// Curated artwork gradients.
    static let artPalettes: [[Color]] = [
        [Color(hex: 0xF7A072), Color(hex: 0xC2456B), Color(hex: 0x3B1D3F)],
        [Color(hex: 0x8FB8FF), Color(hex: 0x5B5BD6), Color(hex: 0x1B1F4B)],
        [Color(hex: 0x7EE0C3), Color(hex: 0x2A8C9E), Color(hex: 0x0F2E3A)],
        [Color(hex: 0xFFD27A), Color(hex: 0xE5733C), Color(hex: 0x4A1E14)],
        [Color(hex: 0xF29FD8), Color(hex: 0x8A4FD8), Color(hex: 0x24123F)],
        [Color(hex: 0x9EE6FF), Color(hex: 0x3D7BE0), Color(hex: 0x0E1E3D)],
        [Color(hex: 0xC8EE90), Color(hex: 0x3FA36B), Color(hex: 0x10291D)],
        [Color(hex: 0xFF9C8A), Color(hex: 0xB33A5B), Color(hex: 0x2A0F1F)],
        [Color(hex: 0xF5DDAA), Color(hex: 0xB9774A), Color(hex: 0x2E1B12)],
        [Color(hex: 0xB9F0F5), Color(hex: 0x7A6CF0), Color(hex: 0x1A1640)]
    ]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Reusable modifiers & styles

struct CardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var fill: Color
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.75))
    }
}

extension View {
    func card(padding: CGFloat = 20, radius: CGFloat = 20, fill: Color = Theme.surface) -> some View {
        modifier(CardModifier(padding: padding, radius: radius, fill: fill))
    }
}

/// Shared hover/press feedback for the custom button styles.
private struct ButtonSkin<Background: View>: View {
    var label: AnyView
    var pressed: Bool
    var font: Font
    var foreground: Color
    var hPad: CGFloat
    var vPad: CGFloat
    @ViewBuilder var background: (_ hover: Bool) -> Background
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(background(hover && enabled))
            .opacity(enabled ? (pressed ? 0.85 : 1) : 0.45)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        ButtonSkin(label: AnyView(configuration.label), pressed: configuration.isPressed,
                   font: Theme.font(large ? 15 : 13.5, .semibold), foreground: Theme.onAccent,
                   hPad: large ? 24 : 16, vPad: large ? 12 : 8.5) { hover in
            Capsule().fill(Theme.accentGradient)
                .overlay(Capsule().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75).blendMode(.plusLighter))
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        ButtonSkin(label: AnyView(configuration.label), pressed: configuration.isPressed,
                   font: Theme.font(large ? 15 : 13.5, .medium), foreground: Theme.text,
                   hPad: large ? 22 : 15, vPad: large ? 12 : 8.5) { hover in
            Capsule().fill(hover ? Theme.fillHover : Theme.fill)
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        IconSkin(label: AnyView(configuration.label), pressed: configuration.isPressed, size: size)
    }
    private struct IconSkin: View {
        var label: AnyView
        var pressed: Bool
        var size: CGFloat
        @State private var hover = false
        var body: some View {
            label
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(hover ? Theme.fillHover : Theme.fill))
                .scaleEffect(pressed ? 0.94 : 1)
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

/// A soft, tinted icon square (the modern replacement for bright gradient tiles).
struct IconTile: View {
    var icon: String
    var tint: Color = Theme.accent
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.16))
            Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct Chip: View {
    var title: String
    var icon: String? = nil
    var selected: Bool
    var tint: Color = Theme.accent
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(Theme.font(13, .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? (tint == Theme.accent ? Theme.onAccent : .white) : Theme.textDim)
            .background(Capsule().fill(selected ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.fill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(18, .semibold)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(Theme.font(13)).foregroundStyle(Theme.textDim) }
            }
            Spacer()
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.font(30, .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.font(14.5)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing()
        }
    }
}

struct DifficultyBadge: View {
    var level: Int
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2.5) {
                ForEach(1...5, id: \.self) { i in
                    Capsule()
                        .fill(i <= level ? Theme.levelColor(level) : Theme.track)
                        .frame(width: compact ? 5 : 6, height: compact ? 9 : 11)
                }
            }
            if !compact {
                Text(Difficulty.name(level))
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.levelColor(level))
            }
        }
    }
}

enum Difficulty {
    static let names = ["Beginner", "Easy", "Intermediate", "Hard", "Advanced"]
    static func name(_ l: Int) -> String { names[max(0, min(4, l - 1))] }
}

struct Pill: View {
    var icon: String
    var text: String
    var tint: Color = Theme.textDim
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(Theme.font(13, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.fill))
    }
}

struct StatTile: View {
    var icon: String
    var value: String
    var label: String
    var tint: Color
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.16))
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(Theme.font(20, .bold)).foregroundStyle(Theme.text).monospacedDigit()
                Text(label).font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16, radius: 16)
    }
}

struct StarRow: View {
    var stars: Int
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(i < stars ? Theme.warn : Theme.textFaint)
            }
        }
    }
}

struct RingView: View {
    var progress: Double
    var lineWidth: CGFloat = 8
    var gradient: LinearGradient = Theme.accentGradient
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Generated album-style artwork for songs.
struct ArtworkView: View {
    var seed: String
    var title: String
    var genre: String
    var size: CGFloat
    var radius: CGFloat? = nil
    @ObservedObject private var art = AlbumArt.shared

    var body: some View {
        let h = abs(seed.stableHash)
        let colors = Theme.artPalettes[h % Theme.artPalettes.count]
        let r = radius ?? size * 0.12
        Group {
            if let img = art.image(for: seed) {
                cover(img, r: r)
            } else {
                generated(h: h, colors: colors, r: r)
            }
        }
        .onAppear { art.request(seed) }
    }

    private func cover(_ img: NSImage, r: CGFloat) -> some View {
        Group {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
        }
    }

    /// Soft, layered colour fields (like modern album art) with a quiet genre mark.
    private func generated(h: Int, colors: [Color], r: CGFloat) -> some View {
        let a = CGFloat(h % 97) / 97, b = CGFloat((h / 97) % 89) / 89
        return ZStack {
            colors[2]
            RadialGradient(colors: [colors[1], colors[1].opacity(0)], center: UnitPoint(x: 0.85 - a * 0.5, y: 0.75 - b * 0.4),
                           startRadius: 0, endRadius: size * 0.95)
            RadialGradient(colors: [colors[0], colors[0].opacity(0)], center: UnitPoint(x: 0.2 + b * 0.5, y: 0.15 + a * 0.3),
                           startRadius: 0, endRadius: size * 0.7)
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
            Image(systemName: Genre.icon(genre))
                .font(.system(size: size * 0.13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(size * 0.1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
    }
}

/// A soft glow made from a song's cover — used behind headers, like modern music players.
struct AmbientArt: View {
    var seed: String
    var title: String
    var genre: String
    var opacity: Double = 0.4
    var body: some View {
        GeometryReader { g in
            ArtworkView(seed: seed, title: title, genre: genre, size: max(g.size.width, g.size.height), radius: 0)
                .frame(width: g.size.width, height: g.size.height)
                .blur(radius: 70)
                .saturation(1.3)
                .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum Genre {
    static let all = ["Rock", "Pop", "Folk", "Country", "Blues", "Reggae", "Indie", "Grunge", "Soul", "Traditional", "Exercise", "Custom"]
    static func icon(_ g: String) -> String {
        switch g {
        case "Rock": return "bolt.fill"
        case "Pop": return "sparkles"
        case "Folk": return "leaf.fill"
        case "Country": return "sun.max.fill"
        case "Blues": return "moon.stars.fill"
        case "Reggae": return "sun.haze.fill"
        case "Indie": return "headphones"
        case "Grunge": return "flame.fill"
        case "Soul": return "heart.fill"
        case "Traditional": return "music.quarternote.3"
        case "Exercise": return "dumbbell.fill"
        default: return "guitars.fill"
        }
    }
}

extension String {
    var stableHash: Int {
        var h: UInt64 = 5381
        for b in utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(truncatingIfNeeded: h & 0x7FFF_FFFF)
    }
    var monogram: String {
        let words = split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.joined()
    }
}

/// Simple flow layout for wrapping chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
