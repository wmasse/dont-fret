import SwiftUI

/// The line being sung, karaoke-style: the words fill with colour as the line goes by, with the
/// next line underneath. `beat` is the song beat playing now (nil: stopped).
struct KaraokeLines: View {
    var lines: [LyricLine]
    var beat: Double?
    var size: CGFloat = 22
    var alignment: HorizontalAlignment = .center

    var body: some View {
        let idx = beat.flatMap { Lyrics.current(lines, at: $0) }
        let line = idx.map { lines[$0] }
        // between lines (or before the first): show what's coming
        let singing = line.map { !$0.text.isEmpty && (beat ?? 0) < $0.end + 1 } ?? false
        let upcoming = lines[((idx ?? -1) + 1)...].first { !$0.text.isEmpty }
        let progress = line.map { l in min(1, max(0, ((beat ?? 0) - l.start) / max(0.25, l.beats))) } ?? 0
        VStack(alignment: alignment, spacing: 6) {
            if singing, let line {
                wipe(line.text, progress: progress)
                    .id(idx)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                Text(beat == nil ? "♪" : "♪  ♪  ♪").font(Theme.font(size, .bold)).foregroundStyle(Theme.textFaint)
            }
            Text(upcoming?.text ?? " ")
                .font(Theme.font(size * 0.62, .medium)).foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .animation(.easeOut(duration: 0.18), value: idx)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(singing ? (line?.text ?? "") : "Instrumental")
    }

    private func wipe(_ text: String, progress: Double) -> some View {
        Text(text).font(Theme.font(size, .bold)).foregroundStyle(Theme.textDim)
            .lineLimit(2)
            .overlay {
                GeometryReader { g in
                    Text(text).font(Theme.font(size, .bold)).foregroundStyle(Theme.accent)
                        .lineLimit(2)
                        .frame(width: g.size.width, height: g.size.height, alignment: Alignment(horizontal: alignment, vertical: .center))
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * progress) }
                }
            }
    }
}

/// Karaoke lines that follow a `ProgressionPlayer` (Hear the Chords).
struct PlayerKaraoke: View {
    @ObservedObject var player: ProgressionPlayer
    var lines: [LyricLine]
    var size: CGFloat = 22
    var alignment: HorizontalAlignment = .center

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.playing)) { ctx in
            KaraokeLines(lines: lines, beat: player.beat(at: ctx.date), size: size, alignment: alignment)
        }
    }
}

/// Karaoke lines that follow the Play Along clock.
struct GameKaraoke: View {
    @ObservedObject var clock: PlayClock
    var lines: [LyricLine]
    var size: CGFloat = 24
    var body: some View {
        KaraokeLines(lines: lines, beat: clock.beat, size: size)
    }
}

/// A bar along the bottom of the song page while the song plays, so the words are on screen
/// whichever Hear button started it.
struct KaraokeBar: View {
    @ObservedObject var player: ProgressionPlayer
    var lines: [LyricLine]
    var body: some View {
        if player.playing {
            PlayerKaraoke(player: player, lines: lines, size: 22)
                .padding(.vertical, 14).padding(.horizontal, 24)
                .frame(maxWidth: 760)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(.bottom, 16).padding(.horizontal, 36)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The whole lyrics on the song page, the line being sung highlighted as the song plays.
struct LyricsCard: View {
    @ObservedObject var player: ProgressionPlayer
    var song: Song
    var tempo: Double = 1

    var body: some View {
        let lines = song.lyrics ?? []
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Lyrics", subtitle: "Sing along — the words follow the song when you press Hear.") {
                HearChordsButton(player: player, song: song, tempo: tempo, label: "Sing Along")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !player.playing)) { ctx in
                let cur = player.beat(at: ctx.date).flatMap { Lyrics.current(lines, at: $0) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                if !l.text.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(MelodyStrip.barLabel(l.start, meter: song.beatsPerBar))
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textFaint)
                                            .frame(width: 34, alignment: .trailing)
                                        Text(l.text).font(Theme.font(14, i == cur ? .bold : .regular))
                                            .foregroundStyle(i == cur ? Theme.accent : Theme.text)
                                    }
                                    .id(i)
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    .onChange(of: cur) { _, c in
                        guard let c else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(c, anchor: UnitPoint(x: 0, y: 0.35)) }
                    }
                }
            }
            Text("Time-synced lyrics from LRCLIB, a free community lyrics database, lined up with the recording automatically.")
                .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
        }
        .card(padding: 20, radius: 20)
    }
}

extension MelodyStrip {
    /// "12" for a line starting on bar 12; "12.3" on its third beat.
    static func barLabel(_ beat: Double, meter: Int) -> String {
        let bar = Int(beat) / max(1, meter) + 1
        let b = Int(beat) % max(1, meter) + 1
        return b == 1 ? "\(bar)" : "\(bar).\(b)"
    }
}
