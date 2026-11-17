import SwiftUI
import AVFoundation

// MARK: - Chord diagram

struct ChordDiagramView: View {
    static var leftHanded = false
    var shape: ChordShape
    var width: CGFloat = 120
    var dotColor: Color = Theme.accent

    var body: some View {
        let lefty = Self.leftHanded
        let ink = Theme.text
        let faint = Theme.textFaint
        let dot = dotColor
        let onDot = Theme.onAccent
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let left = w * 0.17, right = w * 0.07
            let top = h * 0.14, bottom = h * 0.04
            let gw = w - left - right, gh = h - top - bottom
            let sx = gw / 5, fy = gh / 5
            let base = shape.baseFret
            func x(_ s: Int) -> CGFloat { left + CGFloat(lefty ? 5 - s : s) * sx }

            // frets
            for f in 0...5 {
                var p = Path()
                let y = top + CGFloat(f) * fy
                p.move(to: CGPoint(x: left, y: y)); p.addLine(to: CGPoint(x: left + gw, y: y))
                ctx.stroke(p, with: .color(ink.opacity(f == 0 && base == 1 ? 0.9 : 0.22)), lineWidth: f == 0 && base == 1 ? max(3, w * 0.035) : 1)
            }
            // strings
            for s in 0..<6 {
                var p = Path()
                p.move(to: CGPoint(x: x(s), y: top)); p.addLine(to: CGPoint(x: x(s), y: top + gh))
                ctx.stroke(p, with: .color(ink.opacity(0.45)), lineWidth: 1 + CGFloat(5 - s) * 0.18)
            }
            if base > 1 {
                ctx.draw(Text("\(base)fr").font(.system(size: max(9, w * 0.085), weight: .semibold)).foregroundColor(faint),
                         at: CGPoint(x: left * 0.45, y: top + fy * 0.5))
            }
            // open / muted markers
            let mk = max(5, w * 0.045)
            for s in 0..<6 {
                let cx = x(s), cy = top * 0.48
                if shape.frets[s] == 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: cx - mk, y: cy - mk, width: mk * 2, height: mk * 2)), with: .color(ink.opacity(0.75)), lineWidth: 1.4)
                } else if shape.frets[s] < 0 {
                    var p = Path()
                    p.move(to: CGPoint(x: cx - mk * 0.8, y: cy - mk * 0.8)); p.addLine(to: CGPoint(x: cx + mk * 0.8, y: cy + mk * 0.8))
                    p.move(to: CGPoint(x: cx + mk * 0.8, y: cy - mk * 0.8)); p.addLine(to: CGPoint(x: cx - mk * 0.8, y: cy + mk * 0.8))
                    ctx.stroke(p, with: .color(faint), lineWidth: 1.5)
                }
            }
            let r = min(sx, fy) * 0.38
            // barre
            var barreStrings = Set<Int>()
            if let b = shape.barre {
                let idx = (0..<6).filter { shape.frets[$0] == b && shape.fingers[$0] == 1 }
                if let a = idx.min(), let z = idx.max(), z > a {
                    let row = CGFloat(b - base)
                    let cy = top + (row + 0.5) * fy
                    let x1 = min(x(a), x(z)), x2 = max(x(a), x(z))
                    let rect = CGRect(x: x1 - r, y: cy - r, width: x2 - x1 + r * 2, height: r * 2)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(dot))
                    ctx.draw(Text("1").font(.system(size: r * 1.15, weight: .bold)).foregroundColor(onDot), at: CGPoint(x: (x1 + x2) / 2, y: cy))
                    barreStrings = Set(idx)
                }
            }
            for s in 0..<6 where shape.frets[s] > 0 && !barreStrings.contains(s) {
                let row = CGFloat(shape.frets[s] - base)
                let c = CGPoint(x: x(s), y: top + (row + 0.5) * fy)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(dot))
                if shape.fingers[s] > 0 {
                    ctx.draw(Text("\(shape.fingers[s])").font(.system(size: r * 1.15, weight: .bold)).foregroundColor(onDot), at: c)
                }
            }
        }
        .frame(width: width, height: width * 1.2)
        .accessibilityLabel("\(shape.name) chord diagram")
    }
}

struct MissingDiagramView: View {
    var name: String
    var width: CGFloat = 120
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed").font(.system(size: width * 0.22))
            Text(ChordSymbol.parse(name)?.noteNames.joined(separator: " · ") ?? "Unknown chord")
                .font(Theme.font(11, .medium))
        }
        .foregroundStyle(Theme.textFaint)
        .frame(width: width, height: width * 1.2)
    }
}

struct ChordDiagram: View {
    var name: String
    var width: CGFloat = 120
    var dotColor: Color = Theme.accent
    var body: some View {
        if let s = ChordLibrary.displayShape(for: name) {
            ChordDiagramView(shape: s, width: width, dotColor: dotColor)
        } else {
            MissingDiagramView(name: name, width: width)
        }
    }
}

// MARK: - Clickable chord name → popover with the fingering

struct ChordChip: View {
    var name: String
    var size: CGFloat = 15
    var highlighted = false
    var dimmed = false
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Text(name)
                .font(Theme.font(size, .bold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(highlighted ? Theme.onAccent : (dimmed ? Theme.textFaint : Theme.text))
                .padding(.horizontal, size * 0.75)
                .padding(.vertical, size * 0.4)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.55, style: .continuous)
                        .fill(highlighted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.fill))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show how to play \(name)")
        .accessibilityLabel("\(ChordSymbol.parse(name)?.longName ?? name) chord")
        .accessibilityHint("Shows how to play it")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            ChordPopover(name: name)
        }
    }
}

struct ChordPopover: View {
    var name: String
    @State private var pick = 0
    var body: some View {
        let sym = ChordSymbol.parse(name)
        let options = ChordLibrary.voicings(for: name)
        let preferred = options.firstIndex { $0.shape.frets == ChordLibrary.displayShape(for: name)?.frets } ?? 0
        let idx = options.indices.contains(pick) ? pick : preferred
        let shape = options.isEmpty ? nil : options[idx].shape
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(name).font(Theme.font(26, .heavy)).foregroundStyle(Theme.text)
                Text(sym?.longName.capitalized ?? "").font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
            }
            if options.count > 1 {
                HStack(spacing: 4) {
                    ForEach(options.indices, id: \.self) { i in
                        Button { pick = i } label: {
                            Text(options[i].label).font(Theme.font(11, .semibold))
                                .foregroundStyle(i == idx ? Theme.onAccent : Theme.textDim)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(i == idx ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface2)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(i == idx ? .isSelected : [])
                    }
                }
            }
            if let shape {
                ChordDiagramView(shape: shape, width: 150)
                    .accessibilityLabel("Fingering: \(shape.frets.map { $0 < 0 ? "x" : String($0) }.joined(separator: " "))")
            } else {
                ChordDiagram(name: name, width: 150)
            }
            if let sym {
                HStack(spacing: 6) {
                    ForEach(Array(zip(sym.noteNames, sym.quality.intervalNames)), id: \.0) { n, iv in
                        VStack(spacing: 1) {
                            Text(n).font(Theme.font(13, .bold)).foregroundStyle(Theme.text)
                            Text(iv).font(Theme.font(10, .medium)).foregroundStyle(Theme.textFaint)
                        }
                        .frame(minWidth: 30)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let shape {
                HStack(spacing: 8) {
                    Button { GuitarSynth.shared.strum(shape) } label: { Label("Hear it", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Text(shape.levelName)
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Theme.levelColor(shape.level * 2 - 1))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.levelColor(shape.level * 2 - 1).opacity(0.15)))
                }
                Text(shape.tips)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .frame(width: 210)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Theme.surface)
        .preferredColorScheme(Theme.colorScheme)
    }
}

// MARK: - Strum pattern

struct StrumPatternView: View {
    var pattern: StrumPattern
    var activeSlot: Int? = nil
    var grades: [Int: StrumGrade] = [:]
    var slotWidth: CGFloat = 38
    var showCounts = true

    var body: some View {
        let strokes = pattern.strokes
        let per = pattern.slotsPerBeat
        let counts = pattern.counts
        HStack(spacing: 0) {
            ForEach(Array(strokes.enumerated()), id: \.offset) { i, s in
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: slotWidth * 0.26, style: .continuous)
                            .fill(fill(i))
                        symbol(s)
                            .font(.system(size: slotWidth * 0.42, weight: .heavy))
                            .foregroundStyle(color(i, s))
                    }
                    .frame(width: slotWidth - 6, height: slotWidth * 1.15)
                    .scaleEffect(activeSlot == i ? 1.08 : 1)
                    if showCounts {
                        Text(i < counts.count ? counts[i] : "")
                            .font(Theme.font(max(10, slotWidth * 0.3), i % per == 0 ? .bold : .medium))
                            .foregroundStyle(i % per == 0 ? Theme.textDim : Theme.textFaint)
                    }
                }
                .frame(width: slotWidth)
                .padding(.leading, i > 0 && i % per == 0 ? slotWidth * 0.18 : 0)
            }
        }
        .animation(.easeOut(duration: 0.08), value: activeSlot)
    }

    @ViewBuilder private func symbol(_ s: StrumStroke) -> some View {
        switch s {
        case .down: Image(systemName: "arrow.down")
        case .up: Image(systemName: "arrow.up")
        case .mute: Image(systemName: "xmark")
        case .rest: Image(systemName: "circle.fill").font(.system(size: slotWidth * 0.12))
        }
    }

    private func fill(_ i: Int) -> AnyShapeStyle {
        if let g = grades[i] { return AnyShapeStyle(g.color.opacity(0.22)) }
        if activeSlot == i { return AnyShapeStyle(Theme.accentGradient) }
        return AnyShapeStyle(Theme.surface2)
    }

    private func color(_ i: Int, _ s: StrumStroke) -> Color {
        if let g = grades[i] { return g.color }
        if activeSlot == i { return Theme.onAccent }
        switch s {
        case .rest: return Theme.textFaint.opacity(0.6)
        case .mute: return Theme.violet
        default: return Theme.text
        }
    }
}

enum StrumGrade {
    case perfect, early, late, missed, extra, wrongWay
    var color: Color {
        switch self {
        case .perfect: return Theme.success
        case .early, .late: return Theme.warn
        case .missed: return Theme.danger
        case .extra: return Theme.violet
        case .wrongWay: return Theme.accent2
        }
    }
    var label: String {
        switch self {
        case .perfect: return "Perfect"
        case .early: return "Early"
        case .late: return "Late"
        case .missed: return "Missed"
        case .extra: return "Extra"
        case .wrongWay: return "Wrong direction"
        }
    }
}

// MARK: - Song card

struct SongCard: View {
    @EnvironmentObject var progress: ProgressStore
    var song: Song
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                ArtworkView(seed: song.id, title: song.title, genre: song.genre, size: g.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .foregroundStyle(Theme.onAccent)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .padding(10)
                    .opacity(hover ? 1 : 0)
                    .scaleEffect(hover ? 1 : 0.8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(song.artist).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            HStack {
                DifficultyBadge(level: song.difficulty, compact: true)
                Spacer()
                if let r = progress.data.songs[song.id], r.plays > 0 { StarRow(stars: r.stars, size: 9) }
                else { Text("\(song.uniqueChords.count) chords").font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(hover ? Theme.surface : Color.clear))
        .scaleEffect(hover && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var t = "\(song.title) by \(song.artist). \(Difficulty.name(song.difficulty)). \(song.uniqueChords.count) chords."
        if let r = progress.data.songs[song.id], r.plays > 0 { t += " \(r.stars) of 3 stars." }
        return t
    }
}

// MARK: - Mic UI

struct LevelMeter: View {
    var level: Float
    var bars = 12
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let on = Float(i) / Float(bars) < level
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? (i > bars * 3 / 4 ? Theme.warn : Theme.success) : Theme.track)
                    .frame(width: 4, height: 6 + CGFloat(i) * 0.9)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct MicStatusView: View {
    @EnvironmentObject var audio: AudioEngine
    var body: some View {
        HStack(spacing: 10) {
            switch audio.permission {
            case .denied, .restricted:
                Image(systemName: "mic.slash.fill").foregroundStyle(Theme.danger)
                Text("Microphone blocked").font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
                Button("Open Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(SecondaryButtonStyle())
            default:
                Image(systemName: audio.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(audio.isListening ? Theme.success : Theme.textFaint)
                LevelMeter(level: audio.level)
                Text(audio.isListening ? "Listening" : "Mic off").font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.surface2))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

struct InputModePicker: View {
    @Binding var mode: InputMode
    var body: some View {
        HStack(spacing: 4) {
            ForEach(InputMode.allCases) { m in
                Button { mode = m } label: {
                    Label(m.title, systemImage: m.icon)
                        .font(Theme.font(12, .semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(mode == m ? Theme.onAccent : Theme.textDim)
                        .background(Capsule().fill(mode == m ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface2))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .help("Microphone listens to your guitar. Tap mode lets you press Space when you've played it.")
    }
}

struct Segmented<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    Text(label(o))
                        .font(Theme.font(12, selection == o ? .semibold : .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(selection == o ? Theme.text : Theme.textDim)
                        .background {
                            if selection == o {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface3)
                                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Global key monitor helper for game screens.
final class KeyMonitor {
    private var token: Any?
    func start(_ handler: @escaping (UInt16) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // don't steal keys from text fields
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return e }
            return handler(e.keyCode) ? nil : e
        }
    }
    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }
    deinit { stop() }
}

enum Keys {
    static let space: UInt16 = 49, escape: UInt16 = 53, returnKey: UInt16 = 36
    static let left: UInt16 = 123, right: UInt16 = 124, l: UInt16 = 37
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.textFaint)
            Text(title).font(Theme.font(17, .semibold)).foregroundStyle(Theme.text)
            Text(message).font(Theme.font(13)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .padding(40)
    }
}
