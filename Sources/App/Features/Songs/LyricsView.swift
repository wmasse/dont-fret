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
    var player: ProgressionPlayer
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
    var clock: PlayClock
    var lines: [LyricLine]
    var size: CGFloat = 24
    var body: some View {
        KaraokeLines(lines: lines, beat: clock.beat, size: size)
    }
}

/// A bar along the bottom of the song page while the song plays, so the words are on screen
/// whichever Hear button started it.
struct KaraokeBar: View {
    var player: ProgressionPlayer
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
    @Environment(ProgressStore.self) var progress
    var player: ProgressionPlayer
    var song: Song
    var tempo: Double = 1
    @State private var fixing = false

    var body: some View {
        let lines = song.lyrics ?? []
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Lyrics", subtitle: "Sing along — the words follow the song when you press Hear.") {
                HStack(spacing: 8) {
                    if song.isCustom {
                        Button { player.stop(); fixing = true } label: { Label("Fix Words", systemImage: "pencil") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Correct any misheard or wrong words")
                    }
                    HearChordsButton(player: player, song: song, tempo: tempo, label: "Sing Along")
                }
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
            Text(footnote).font(Theme.font(11)).foregroundStyle(song.lyricsHeard ? Theme.textDim : Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 20, radius: 20)
        .sheet(isPresented: $fixing) { LyricsFixSheet(songID: song.id).environment(progress) }
    }

    private var footnote: String {
        switch song.lyricsSource {
        case "heard": return "Written down from the words heard sung in the recording, on your Mac. Some may be misheard: tap Fix Words to correct them."
        case "edited": return "Written down from the recording and corrected by you."
        default: return "Time-synced lyrics from LRCLIB, a free community lyrics database, lined up with the recording automatically."
        }
    }
}

/// Correct a song's lyrics line by line. The timing of each line stays as it is; only the words change.
struct LyricsFixSheet: View {
    @Environment(ProgressStore.self) var progress
    @Environment(\.dismiss) var dismiss
    var songID: String
    @State private var texts: [String] = []
    @State private var loaded = false

    private var song: Song? { progress.song(id: songID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix Words").font(Theme.font(20, .bold)).foregroundStyle(Theme.text)
            Text("Change any word that's wrong. Each line keeps its place in the song; clear a line to hide it.")
                .font(Theme.font(12)).foregroundStyle(Theme.textDim)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(texts.indices, id: \.self) { i in
                        HStack(spacing: 10) {
                            Text(label(i)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textFaint).frame(width: 34, alignment: .trailing)
                            TextField("", text: $texts[i]).textFieldStyle(.roundedBorder).font(Theme.font(14))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260, maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
        .onAppear {
            guard !loaded, let s = song else { return }
            loaded = true
            texts = (s.lyrics ?? []).map(\.text)
        }
    }

    private func label(_ i: Int) -> String {
        guard let s = song, let lines = s.lyrics, i < lines.count else { return "" }
        return MelodyStrip.barLabel(lines[i].start, meter: s.beatsPerBar)
    }

    private func save() {
        guard var s = song, var lines = s.lyrics, lines.count == texts.count else { dismiss(); return }
        var changed = false
        for i in lines.indices {
            let t = texts[i].trimmingCharacters(in: .whitespaces)
            if t != lines[i].text { lines[i].text = t; changed = true }
        }
        if changed {
            s.lyrics = lines
            if s.lyricsSource == "heard" { s.lyricsSource = "edited" }
            progress.addCustomSong(s)
        }
        dismiss()
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
