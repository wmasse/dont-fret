import SwiftUI

/// The song's melody as a scrolling strip, bar by bar: each note sits at its pitch and length,
/// labelled with where to fret it. Follows along while the song plays.
struct MelodyCard: View {
    @ObservedObject var player: ProgressionPlayer
    var song: Song
    var tempo: Double = 1

    var body: some View {
        let melody = song.melody ?? []
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Melody",
                          subtitle: "The tune, worked out by ear from the recording — \(melody.count) notes. Labels show the string and fret.") {
                HStack(spacing: 8) {
                    Button { player.melodyOn.toggle() } label: {
                        Label(player.melodyOn ? "Melody On" : "Melody Off", systemImage: player.melodyOn ? "music.note" : "music.note.slash" )
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(player.playing)
                    .help("Play the melody on a second guitar along with the chords")
                    HearChordsButton(player: player, song: song, tempo: tempo, label: player.melodyOn ? "Hear with Melody" : "Hear the Chords")
                }
            }
            MelodyStrip(song: song, melody: melody, current: player.playing ? player.melodyNote : nil)
            Text("Rough draft: picked out automatically, so some notes may be off by a step or missing. Trust your ear.")
                .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
        }
        .card(padding: 20, radius: 20)
    }
}

struct MelodyStrip: View {
    var song: Song
    var melody: [MelodyNote]
    var current: Int?
    var beatWidth: CGFloat = 40
    var height: CGFloat = 132

    var body: some View {
        let meter = song.beatsPerBar
        let bars = max(1, Int((song.totalBeats / Double(meter)).rounded(.up)))
        let frets = MelodyExtractor.positions(melody)
        let lo = (melody.map(\.midi).min() ?? 60) - 1, hi = (melody.map(\.midi).max() ?? 72) + 1
        let chordAt = Self.chordsByBar(song)
        let currentBar = current.flatMap { melody.indices.contains($0) ? Int(melody[$0].start) / meter : nil }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<bars, id: \.self) { bar in
                        MelodyBar(melody: melody, bar: bar, meter: meter, lo: lo, hi: hi, frets: frets, chord: chordAt[bar],
                                  current: current, beatWidth: beatWidth, height: height)
                            .id(bar)
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: currentBar) { _, b in
                guard let b else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(max(0, b - 1), anchor: .leading) }
            }
        }
        .frame(height: height + 26)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
        .accessibilityLabel("Melody: \(melody.count) notes")
    }

    /// The chord sounding at the start of each bar (blank when it's the same as the bar before).
    static func chordsByBar(_ song: Song) -> [Int: String] {
        var out: [Int: String] = [:]
        var last = ""
        for e in song.events where !e.isNote {
            let bar = Int(e.start) / max(1, song.beatsPerBar)
            if out[bar] == nil, e.chord != last { out[bar] = e.chord }
            last = e.chord
        }
        return out
    }
}

/// One bar of the melody strip: the chord above, then each note at its pitch and length.
struct MelodyBar: View {
    var melody: [MelodyNote]
    var bar: Int
    var meter: Int
    var lo: Int
    var hi: Int
    var frets: [(string: Int, fret: Int)]
    var chord: String?
    var current: Int?
    var beatWidth: CGFloat = 40
    var height: CGFloat = 132

    var body: some View {
        let start = Double(bar * meter), end = start + Double(meter)
        let width = beatWidth * CGFloat(meter)
        let notes = melody.indices.filter { melody[$0].start < end && melody[$0].end > start }
        let cur = current
        let accent = Theme.accent, info = Theme.info, faint = Theme.textFaint, text = Theme.text, line = Theme.stroke
        return VStack(alignment: .leading, spacing: 2) {
            Text(chord ?? " ").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textDim).padding(.leading, 5)
            Canvas { ctx, size in
                // bar line and beat ticks
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(line))
                for b in 1..<max(2, meter) where b < meter {
                    ctx.fill(Path(CGRect(x: CGFloat(b) * beatWidth, y: size.height - 4, width: 1, height: 4)), with: .color(line))
                }
                let span = CGFloat(max(1, hi - lo))
                let rowH = max(4, min(10, (size.height - 18) / span))
                for i in notes {
                    let n = melody[i]
                    let x0 = CGFloat(n.start - start) * beatWidth + 1
                    let w = max(4, CGFloat(n.beats) * beatWidth - 2)
                    let y = 16 + (size.height - 22 - rowH) * CGFloat(hi - n.midi) / span
                    let playing = cur == i
                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: y, width: w, height: rowH), cornerRadius: rowH / 2),
                             with: .color(playing ? accent : info.opacity(0.75)))
                    // label where the note starts: string and fret (once for a run of the same note)
                    guard n.start >= start, frets.indices.contains(i) else { continue }
                    let p = frets[i]
                    if i > 0, frets[i - 1] == p, n.start - melody[i - 1].end < 0.5, !playing { continue }
                    let label = Text("\(Theory.stringNames[p.string])\(p.fret)")
                        .font(Theme.font(9.5, playing ? .bold : .medium))
                        .foregroundColor(playing ? text : faint)
                    // keep it inside the bar
                    if x0 + 22 > size.width {
                        ctx.draw(label, at: CGPoint(x: min(size.width - 1, x0 + w), y: y - 2), anchor: .bottomTrailing)
                    } else {
                        ctx.draw(label, at: CGPoint(x: x0 + 1, y: y - 2), anchor: .bottomLeading)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .padding(.top, 6)
    }
}
