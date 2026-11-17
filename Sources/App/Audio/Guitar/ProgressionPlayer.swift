import Foundation
import SwiftUI

/// Plays a song's chords in order with its strumming pattern, so you can hear how it should sound.
@MainActor
@Observable
final class ProgressionPlayer {
    private(set) var playing = false
    /// Index into `song.events` of the chord sounding now.
    private(set) var current: Int?
    /// (section index, chord position within that section) of the chord sounding now.
    private(set) var position: (section: Int, token: Int)?
    /// Play the song's melody (when it has one) on top of the chords.
    var melodyOn = true
    /// Index into `song.melody` of the melody note sounding now.
    private(set) var melodyNote: Int?
    /// Song beat playback started from, when it started, and seconds per beat — so views can work out
    /// where the song is between chords (lyrics follow this).
    @ObservationIgnored private(set) var startBeat: Double = 0
    @ObservationIgnored private(set) var startedAt: Date?
    @ObservationIgnored private(set) var beatSeconds: Double = 0.5
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var melodyTask: Task<Void, Never>?
    @ObservationIgnored private var chordVolume: Float?

    func toggle(_ song: Song, tempo: Double = 1, from start: Int = 0) {
        playing ? stop() : play(song, tempo: tempo, from: start)
    }

    func play(_ song: Song, tempo: Double = 1, from start: Int = 0) {
        stop()
        let events = song.events
        guard !events.isEmpty else { return }
        GuitarSynth.shared.tone = .acoustic
        let positions = Self.positions(song)
        let beat = 60 / (Double(song.bpm) * max(0.25, tempo))
        let capo = song.capo
        let feel = song.playFeel
        let meter = song.beatsPerBar
        startBeat = events[min(start, events.count - 1)].start
        beatSeconds = beat
        startedAt = Date()
        playing = true
        if melodyOn, MelodyExtractor.enabled, let melody = song.melody, !melody.isEmpty {
            playMelody(melody, from: events[min(start, events.count - 1)].start, beat: beat, capo: capo)
        }
        task = Task { [weak self] in
            let clock = ContinuousClock()
            let t0 = clock.now
            let offset = events[min(start, events.count - 1)].start
            func wait(_ sec: Double) async { try? await clock.sleep(until: t0 + .milliseconds(Int(sec * 1000))) }
            for (i, e) in events.enumerated() where i >= start {
                if Task.isCancelled { return }
                let at = (e.start - offset) * beat
                await wait(at)
                if Task.isCancelled { return }
                self?.current = i
                self?.position = positions.indices.contains(i) ? positions[i] : nil
                if e.isNote {
                    if let m = e.noteMidi { GuitarSynth.shared.pluck(midi: m + capo, seconds: min(2.4, e.beats * beat + 0.4)) }
                    continue
                }
                guard let base = ChordLibrary.displayShape(for: e.chord) else { continue }
                let shape = Self.withCapo(base, capo)
                let steps = Self.steps(feel: feel, pattern: StrumPattern.match(e.strum, beatsPerBar: meter), shape: base,
                                       start: e.start, beats: e.beats, meter: meter)
                for st in steps {
                    await wait(at + st.at * beat)
                    if Task.isCancelled { return }
                    st.play(shape)
                }
            }
            if let last = events.last {
                await wait((last.start + last.beats - offset) * beat + 1.5)
            }
            self?.finish()
        }
    }

    /// One thing the backing guitar does, `at` beats after the chord starts.
    struct Step {
        var at: Double
        var play: (ChordShape) -> Void
    }

    /// How a chord is played for its duration, in the song's style.
    static func steps(feel: String, pattern: StrumPattern, shape: ChordShape, start: Double, beats: Double, meter: Int) -> [Step] {
        let synth = GuitarSynth.shared
        let played = (0..<6).filter { shape.frets[$0] >= 0 }
        guard let bass = played.first else { return [] }
        let top = Array(played.suffix(4))
        let barPos = start.truncatingRemainder(dividingBy: Double(meter))
        var out: [Step] = []
        switch feel {
        case "boomchick":
            // bass note on the strong beats (alternating root and another bass string), strum on the others
            let alt = played.count > 1 ? played[min(played.count - 1, 1)] : bass
            var n = 0
            for b in 0..<max(1, Int(beats.rounded())) {
                let beatInBar = Int(barPos + Double(b)) % meter
                if beatInBar == 0 || (meter == 4 && beatInBar == 2) {
                    let s = n % 2 == 0 ? bass : alt
                    n += 1
                    out.append(Step(at: Double(b)) { sh in synth.pickString(s, fret: sh.frets[s], velocity: beatInBar == 0 ? 0.9 : 0.8) })
                } else {
                    out.append(Step(at: Double(b)) { sh in synth.strum(sh, stroke: .down, silent: true, velocity: 0.6, strings: top) })
                    let slot = (beatInBar * 2 + 1) % max(1, pattern.strokes.count)
                    if pattern.strokes.indices.contains(slot), pattern.strokes[slot] == .up {
                        out.append(Step(at: Double(b) + 0.5) { sh in synth.strum(sh, stroke: .up, silent: true, velocity: 0.45, strings: top) })
                    }
                }
            }
        case "picked":
            // fingerpicked arpeggio in eighths: the thumb takes the bass, the fingers go up and down the
            // treble strings, and the top string joins the thumb on the downbeat (a "pinch")
            let treble = Array(played.dropFirst().suffix(4))
            let seq = treble.isEmpty ? [bass] : [bass] + treble + treble.dropFirst().dropLast().reversed()
            for k in 0..<max(1, Int((beats * 2).rounded())) {
                let s = seq[k % seq.count]
                let strong = k % 4 == 0
                let touch: Touch = s == bass ? .thumb : .finger
                out.append(Step(at: Double(k) * 0.5) { sh in
                    synth.pickString(s, fret: sh.frets[s], velocity: strong ? 0.75 : 0.55, bright: touch == .thumb ? 0.45 : 0.55, touch: touch)
                    if k == 0, let top = treble.last {
                        synth.pickString(top, fret: sh.frets[top], velocity: 0.55, bright: 0.55, touch: .finger)
                    }
                })
            }
        case "power":
            // palm-muted eighths on the low strings; the first hit of each chord rings out
            let low = Array(played.prefix(3))
            for k in 0..<max(1, Int((beats * 2).rounded())) {
                let first = k == 0
                out.append(Step(at: Double(k) * 0.5) { sh in
                    for s in low { synth.pickString(s, fret: sh.frets[s], velocity: first ? 0.95 : 0.75, palmMute: !first, bright: 0.7) }
                })
            }
        case "reggae":
            // short choppy strums on the off-beats
            for b in 0..<max(1, Int(beats.rounded())) {
                out.append(Step(at: Double(b) + 0.5) { sh in synth.strum(sh, stroke: .up, silent: true, velocity: 0.7, strings: top, chop: 0.11) })
            }
        default:
            // follow the strum pattern, aligned to the bar, with natural accents
            let strokes = pattern.strokes
            let per = Double(pattern.slotsPerBeat)
            let first = Int((barPos * per).rounded())
            let slots = max(1, Int((beats * per).rounded()))
            var any = false
            for k in 0..<slots {
                let slot = (first + k) % max(1, strokes.count)
                let stroke = strokes.isEmpty ? .down : strokes[slot]
                let s: StrumStroke = (k == 0 && !stroke.isStrum) ? .down : stroke
                guard s.isStrum else { continue }
                any = true
                let onBeat = slot % max(1, Int(per)) == 0
                let accent: Float = slot == 0 ? 0.95 : (onBeat ? 0.8 : 0.6)
                out.append(Step(at: Double(k) / per) { sh in synth.strum(sh, stroke: s, silent: true, velocity: accent) })
            }
            if !any { out.append(Step(at: 0) { sh in synth.strum(sh, silent: true) }) }
        }
        return out
    }

    /// The melody on its own guitar (see `MelodyExtractor.picks` for how each note is played).
    private func playMelody(_ melody: [MelodyNote], from offset: Double, beat: Double, capo: Int) {
        let synth = GuitarSynth.melody
        synth.tone = .acoustic
        // the tune sits on top: the chords step back a little while it plays
        chordVolume = GuitarSynth.shared.volume
        GuitarSynth.shared.volume = (chordVolume ?? 0.9) * 0.6
        synth.volume = 0.95
        let picks = MelodyExtractor.picks(melody, from: offset, beat: beat, capo: capo)
        melodyTask = Task { [weak self] in
            let clock = ContinuousClock()
            let t0 = clock.now
            for p in picks {
                try? await clock.sleep(until: t0 + .milliseconds(Int(p.at * 1000)))
                if Task.isCancelled { return }
                self?.melodyNote = p.index
                synth.lead(p.string, fret: p.fret, tech: p.tech, length: p.length, velocity: 0.85)
                if let r = p.release { synth.damp(p.string, after: r) }
            }
            self?.melodyNote = nil
        }
    }

    func stop() {
        if task != nil { GuitarSynth.shared.silence() }
        if melodyTask != nil { GuitarSynth.melody.silence() }
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        melodyTask?.cancel()
        melodyTask = nil
        if let v = chordVolume { GuitarSynth.shared.volume = v; chordVolume = nil }
        playing = false
        startedAt = nil
        current = nil
        position = nil
        melodyNote = nil
    }

    /// The song beat being played at `date` (nil when stopped).
    func beat(at date: Date) -> Double? {
        guard playing, let t0 = startedAt else { return nil }
        return startBeat + date.timeIntervalSince(t0) / beatSeconds
    }

    /// The same shape played with a capo: every string sounds `capo` frets higher.
    static func withCapo(_ s: ChordShape, _ capo: Int) -> ChordShape {
        guard capo > 0 else { return s }
        var c = s
        c.frets = s.frets.map { $0 < 0 ? $0 : $0 + capo }
        return c
    }

    /// For each event: which section it belongs to and its position in that section's chord list.
    static func positions(_ song: Song) -> [(section: Int, token: Int)] {
        var out: [(Int, Int)] = []
        for (si, sec) in song.sections.enumerated() {
            let n = sec.tokens(beatsPerBar: song.beatsPerBar).count
            for _ in 0..<max(1, sec.repeats) { for t in 0..<n { out.append((si, t)) } }
        }
        return out
    }
}

/// A play/stop button for hearing a song's chords in order.
struct HearChordsButton: View {
    var player: ProgressionPlayer
    var song: Song
    var tempo: Double = 1
    var label = "Hear the Chords"
    var body: some View {
        Button { player.toggle(song, tempo: tempo) } label: {
            Label(player.playing ? "Stop" : label, systemImage: player.playing ? "stop.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Play every chord of the song in order, at its tempo and strumming pattern")
    }
}
