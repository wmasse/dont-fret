// "Does it sound like the song?" for the melody: note-level scores with timing, and renders to listen to.
//   build/selftest --melody-bench                  also prints the timing-aware scores below
//   build/selftest --melody-render build/listen    for each bench tune, writes
//       <tune>-app.wav      the 30 s preview, then the song as the app plays it (chords + melody guitar, ~1 min)
//       <tune>-overlay.wav  the preview with the melody guitar on top, at the recording's own timing
// The timing-aware scores need to know when each written note is sung. The first run stores anchors
// (written beat → second in the recording) per tune in build/bench/tune-*.anchors, from the notes the
// extractor got right; later runs reuse them, so every version of the code is judged on the same clock.
// Delete the .anchors files to make new ones.
#if SELFTEST
import Foundation
import AVFoundation

extension SelfTest {
    struct ListenScore {
        var played = 0, written = 0, hit = 0, hitClass = 0
        var voicedFrames = 0, rightFrames = 0, playedFrames = 0, wrongFrames = 0
        /// Played notes that hit nothing: no sung note starts near them / one does but it's another note / an octave off.
        var stray = 0, wrongPitch = 0, octaveOff = 0, reattack = 0, silentStray = 0
        /// Lengths (beats) of the played notes that hit, and of the strays.
        var hitBeats: [Double] = [], strayBeats: [Double] = []
        mutating func add(_ o: ListenScore) {
            stray += o.stray; reattack += o.reattack; silentStray += o.silentStray; wrongPitch += o.wrongPitch; octaveOff += o.octaveOff; hitBeats += o.hitBeats; strayBeats += o.strayBeats
            played += o.played; written += o.written; hit += o.hit; hitClass += o.hitClass
            voicedFrames += o.voicedFrames; rightFrames += o.rightFrames; playedFrames += o.playedFrames; wrongFrames += o.wrongFrames
        }
        func f1(_ h: Int) -> Double { played + written == 0 ? 0 : 2 * Double(h) / Double(played + written) }
        var summary: String {
            func p(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
            return "notes on time & pitch F1 \(String(format: "%.0f%%", 100 * f1(hit))) (precision \(p(hit, played)), recall \(p(hit, written)))"
                + " · any octave F1 \(String(format: "%.0f%%", 100 * f1(hitClass)))"
                + " · sung time on the right note \(p(rightFrames, voicedFrames)) · played time on a wrong note \(p(wrongFrames, playedFrames))"
        }
        var breakdown: String {
            func p(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
            func med(_ x: [Double]) -> String { x.isEmpty ? "-" : String(format: "%.2f", x.sorted()[x.count / 2]) }
            func short(_ x: [Double]) -> String { p(x.filter { $0 <= 0.5 }.count, x.count) }
            return "of the played notes: stray (nothing sung starts there) \(p(stray, played)) · wrong note \(p(wrongPitch, played)) · octave off \(p(octaveOff, played)) — strays that repeat the note being sung \(p(reattack, played)), in a gap between sung notes \(p(silentStray, played))"
                + " · median length right \(med(hitBeats)) / stray \(med(strayBeats)) beats · ≤½ beat: right \(short(hitBeats)), stray \(short(strayBeats))"
        }
    }

    /// Anchors for a tune: (beat of the written tune, three passes long; second in the recording), and the octave shift.
    static func listenAnchors(_ url: URL, rows: [Aligned], shift: Int) -> (anchors: [(Double, Double)], shift: Int) {
        if let txt = try? String(contentsOf: url, encoding: .utf8) {
            var lines = txt.split(separator: "\n")
            let sh = Int(lines.removeFirst()) ?? shift
            let a = lines.compactMap { l -> (Double, Double)? in
                let f = l.split(separator: " ").compactMap { Double($0) }
                return f.count == 2 ? (f[0], f[1]) : nil
            }
            return (a, sh)
        }
        var a: [(Double, Double)] = []
        for r in rows where r.verdict == .right || r.verdict == .octave {
            guard let t = r.truth, let h = r.heard else { continue }
            if let last = a.last {
                let slope = (h.start - last.1) / (t.beat - last.0)
                guard t.beat > last.0, h.start > last.1, slope > 0.2, slope < 2.0 else { continue }
            }
            a.append((t.beat, h.start))
        }
        let txt = "\(shift)\n" + a.map { String(format: "%.3f %.4f", $0.0, $0.1) }.joined(separator: "\n")
        try? txt.write(to: url, atomically: true, encoding: .utf8)
        return (a, shift)
    }

    /// Scores the notes the app plays (on the recording's clock) against the written tune.
    static func listenScore(_ played: [HeardNote], score raw: [ScoreNote], anchors: [(Double, Double)], shift: Int) -> ListenScore {
        var s = ListenScore()
        guard anchors.count >= 4, !raw.isEmpty else { return s }
        let period = raw.last!.beat + raw.last!.beats
        let score = (0..<3).flatMap { k in raw.map { ScoreNote(midi: $0.midi + shift, beat: $0.beat + Double(k) * period, beats: $0.beats) } }
        func time(_ b: Double) -> Double? {
            guard b >= anchors.first!.0, b <= anchors.last!.0 else { return nil }
            var i = 0
            while i + 2 < anchors.count && anchors[i + 1].0 < b { i += 1 }
            let (b0, t0) = anchors[i], (b1, t1) = anchors[i + 1]
            return t0 + (b - b0) / (b1 - b0) * (t1 - t0)
        }
        let span = (anchors.first!.1, anchors.last!.1)
        let beatSec = (span.1 - span.0) / (anchors.last!.0 - anchors.first!.0)
        let tol = max(0.1, 0.3 * beatSec)
        // written notes on the clock (a held note ends where the next starts, at the latest)
        var written: [(a: Double, b: Double, m: Int)] = []
        for n in score { if let a = time(n.beat), let b = time(min(n.beat + n.beats, anchors.last!.0)) ?? time(n.beat) { written.append((a, max(a + 0.05, b), n.midi)) } }
        let playedIn = played.filter { $0.start >= span.0 - tol && $0.start <= span.1 + tol }
        s.played = playedIn.count
        s.written = written.count
        // onsets: each played note may take one written note starting within the tolerance
        func matches(_ same: (Int, Int) -> Bool) -> Int {
            var used = Set<Int>(), hits = 0
            for p in playedIn {
                let best = written.indices.filter { !used.contains($0) && abs(written[$0].a - p.start) <= tol && same(written[$0].m, p.midi) }
                    .min { abs(written[$0].a - p.start) < abs(written[$1].a - p.start) }
                if let b = best { used.insert(b); hits += 1 }
            }
            return hits
        }
        s.hit = matches { $0 == $1 }
        for p in playedIn {
            let near = written.filter { abs($0.a - p.start) <= tol }
            let beats = (p.end - p.start) / beatSec
            if near.contains(where: { $0.m == p.midi }) { s.hitBeats.append(beats) }
            else if near.isEmpty {
                s.stray += 1; s.strayBeats.append(beats)
                let under = written.last { $0.a <= p.start && p.start < $0.b }
                if let u = under { if u.m == p.midi { s.reattack += 1 } } else { s.silentStray += 1 }
            }
            else if near.contains(where: { ($0.m - p.midi) % 12 == 0 }) { s.octaveOff += 1 }
            else { s.wrongPitch += 1 }
        }
        s.hitClass = matches { ($0 - $1) % 12 == 0 }
        // frames: what's sounding every 10 ms
        var t = span.0
        while t < span.1 {
            let w = written.last { $0.a <= t && t < $0.b }
            let p = played.last { $0.start <= t && t < $0.end }
            if let w { s.voicedFrames += 1; if p?.midi == w.m { s.rightFrames += 1 } }
            if let p { s.playedFrames += 1; if w == nil || (w!.m - p.midi) % 12 != 0 { s.wrongFrames += 1 } }
            t += 0.01
        }
        return s
    }

    /// For tuning: one line per note, `label start end midi strength`, label hit / stray / wrong / octave.
    static func listenLabels(_ notes: [HeardNote], score raw: [ScoreNote], anchors: [(Double, Double)], shift: Int) -> [String] {
        guard anchors.count >= 4, !raw.isEmpty else { return [] }
        let period = raw.last!.beat + raw.last!.beats
        let score = (0..<3).flatMap { k in raw.map { ScoreNote(midi: $0.midi + shift, beat: $0.beat + Double(k) * period, beats: $0.beats) } }
        func time(_ b: Double) -> Double? {
            guard b >= anchors.first!.0, b <= anchors.last!.0 else { return nil }
            var i = 0
            while i + 2 < anchors.count && anchors[i + 1].0 < b { i += 1 }
            let (b0, t0) = anchors[i], (b1, t1) = anchors[i + 1]
            return t0 + (b - b0) / (b1 - b0) * (t1 - t0)
        }
        let beatSec = (anchors.last!.1 - anchors.first!.1) / (anchors.last!.0 - anchors.first!.0)
        let tol = max(0.1, 0.3 * beatSec)
        let written = score.compactMap { n in time(n.beat).map { (a: $0, m: n.midi) } }
        return notes.compactMap { p in
            guard p.start >= anchors.first!.1 - tol, p.start <= anchors.last!.1 + tol else { return nil }
            let near = written.filter { abs($0.a - p.start) <= tol }
            let label = near.contains { $0.m == p.midi } ? "hit" : (near.isEmpty ? "stray" : (near.contains { ($0.m - p.midi) % 12 == 0 } ? "octave" : "wrong"))
            return String(format: "%@ %.3f %.3f %d %.3f %.3f", label, p.start, p.end, p.midi, Double(p.strength), beatSec)
        }
    }

    /// The song's melody (song beats) back on the recording's clock.
    static func melodyOnClock(_ song: Song, _ tr: Transcription) -> [HeardNote] {
        (song.melody ?? []).compactMap { n in
            func time(_ b: Double) -> Double? {
                let pos = b + tr.songZeroBeat
                let k = Int(pos.rounded(.down))
                guard k >= 0, k + 1 < tr.beatTimes.count else { return nil }
                return tr.beatTimes[k] + (pos - Double(k)) * (tr.beatTimes[k + 1] - tr.beatTimes[k])
            }
            guard let a = time(n.start), let b = time(n.end) else { return nil }
            return HeardNote(start: a, end: b, midi: n.midi + song.capo, strength: 1)
        }
    }

    // MARK: renders

    /// The melody guitar's events, as `ProgressionPlayer.playMelody` sends them.
    static func melodyEvents(_ melody: [MelodyNote], beat: Double, capo: Int, sr: Double = 44100) -> [GuitarCore.Event] {
        var ev: [GuitarCore.Event] = []
        for p in MelodyExtractor.picks(melody, beat: beat, capo: capo) {
            let at = Int(p.at * sr)
            ev += GuitarSynth.leadEvents(p.string, fret: p.fret, tech: p.tech, length: p.length, velocity: 0.85).map { var e = $0; e.delay += at; return e }
            if let r = p.release { ev.append(.damp(p.string, at: at + Int(r * sr), seconds: 0.12)) }
        }
        return ev
    }

    /// The chords, strummed on the song's pattern (a simplified `ProgressionPlayer` default feel).
    static func chordEvents(_ song: Song, beat: Double, sr: Double = 44100) -> [GuitarCore.Event] {
        var ev: [GuitarCore.Event] = []
        for e in song.events where !e.isNote {
            guard let base = ChordLibrary.displayShape(for: e.chord) else { continue }
            var shape = base
            if song.capo > 0 { shape.frets = base.frets.map { $0 < 0 ? $0 : $0 + song.capo } }
            let pattern = StrumPattern.match(e.strum, beatsPerBar: song.beatsPerBar)
            let per = Double(pattern.slotsPerBeat)
            let barPos = e.start.truncatingRemainder(dividingBy: Double(song.beatsPerBar))
            let first = Int((barPos * per).rounded())
            for k in 0..<max(1, Int((e.beats * per).rounded())) {
                let slot = (first + k) % max(1, pattern.strokes.count)
                let st = pattern.strokes.isEmpty ? .down : pattern.strokes[slot]
                let s: StrumStroke = (k == 0 && !st.isStrum) ? .down : st
                guard s.isStrum else { continue }
                let onBeat = slot % max(1, Int(per)) == 0
                let at = Int((e.start + Double(k) / per) * beat * sr)
                ev += GuitarSynth.events(for: shape, stroke: s, velocity: slot == 0 ? 0.95 : (onBeat ? 0.8 : 0.6)).map { var x = $0; x.delay += at; return x }
            }
        }
        return ev
    }

    static func renderEvents(_ ev: [GuitarCore.Event], seconds: Double) -> ([Float], [Float]) {
        let core = GuitarCore(sampleRate: 44100)
        core.tone = 0
        core.enqueue(ev)
        return renderCore(core, seconds: seconds)
    }

    static func readStereo44(_ url: URL) -> ([Float], [Float])? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), c = Int(file.processingFormat.channelCount)
        var l = Array(UnsafeBufferPointer(start: ch[0], count: n)), r = c > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        let sr = file.processingFormat.sampleRate
        if abs(sr - 44100) > 1 {
            func rs(_ x: [Float]) -> [Float] {
                let m = Int(Double(x.count) * 44100 / sr)
                return (0..<m).map { i in let p = Double(i) * sr / 44100; let k = Int(p); let f = Float(p - Double(k)); return k + 1 < x.count ? x[k] * (1 - f) + x[k + 1] * f : 0 }
            }
            l = rs(l); r = rs(r)
        }
        return (l, r)
    }

    /// How much each melody note stands out from the chords at its own pitch: the melody guitar's
    /// power over the chord guitar's at the note's first four harmonics, early in the note (dB).
    /// Low or negative means the tune is buried in the strumming.
    static func melodyAboveChords(_ picks: [MelodyExtractor.Pick], melody m: [Float], chords c: [Float], sr: Double = 44100) -> [Double] {
        let w = 4096
        let hann = (0..<w).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(w)) }
        func power(_ x: [Float], at start: Int, f: Double) -> Double {
            guard start >= 0, start + w <= x.count else { return 0 }
            var re = 0.0, im = 0.0
            let dphi = 2 * Double.pi * f / sr
            for i in 0..<w { let v = Double(x[start + i]) * hann[i]; re += v * cos(dphi * Double(i)); im -= v * sin(dphi * Double(i)) }
            return re * re + im * im
        }
        return picks.compactMap { p in
            let midi = Theory.openStrings[p.string] + p.fret
            let f0 = Theory.frequency(midi: Double(midi))
            let start = Int((p.at + 0.03) * sr)
            var mp = 0.0, cp = 0.0
            for h in 1...4 { mp += power(m, at: start, f: f0 * Double(h)); cp += power(c, at: start, f: f0 * Double(h)) }
            return mp > 0 ? 10 * log10(mp / max(1e-12, cp)) : nil
        }
    }

    static func melodyRender(into dir: String) {
        let bench = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench", isDirectory: true)
        let sr = 44100.0
        print("\nMelody renders → \(dir)")
        var standAll: [Double] = []
        defer {
            standAll.sort()
            print(String(format: "   ALL: melody over chords median %+.1f dB, %.0f%% of notes ≥ 6 dB above", standAll.isEmpty ? 0 : standAll[standAll.count / 2],
                         100 * Double(standAll.filter { $0 >= 6 }.count) / Double(max(1, standAll.count))))
        }
        for c in tuneCases {
            let slug = c.query.lowercased().filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "-")
            let audio = bench.appendingPathComponent("tune-" + slug + ".m4a")
            guard let (pl, pr) = readStereo44(audio), let tr = try? Transcriber.analyze(url: audio) else { print("   \(slug): no audio (run --melody-bench first)"); continue }
            // as the app plays it: the preview's song, repeated to about a minute
            let song = Transcriber.song(from: tr, title: "", artist: "", genre: "Pop", capo: 0)
            let beat = 60 / Double(song.bpm)
            let secs = song.totalBeats * beat + 2
            let (cl, cr) = renderEvents(chordEvents(song, beat: beat), seconds: secs)
            let (ml, mr) = renderEvents(melodyEvents(song.melody ?? [], beat: beat, capo: song.capo), seconds: secs)
            let picks = MelodyExtractor.picks(song.melody ?? [], beat: beat, capo: song.capo)
            let stand = melodyAboveChords(picks, melody: zip(ml, mr).map { 0.95 * ($0 + $1) }, chords: zip(cl, cr).map { 0.54 * ($0 + $1) }).sorted()
            standAll += stand
            let gap = Int(1.0 * sr)
            var L = pl.map { $0 * 0.8 } + [Float](repeating: 0, count: gap), R = pr.map { $0 * 0.8 } + [Float](repeating: 0, count: gap)
            L += zip(cl, ml).map { 0.9 * 0.6 * $0 + 0.95 * $1 }
            R += zip(cr, mr).map { 0.9 * 0.6 * $0 + 0.95 * $1 }
            writeWAV("\(dir)/\(slug)-app.wav", L, R, sampleRate: sr)
            // over the record: the same melody, at the recording's own timing
            let whole = Transcriber.song(from: tr, title: "", artist: "", genre: "Pop", capo: 0, wholeSong: true)
            let clock = melodyOnClock(whole, tr)
            var notes: [MelodyNote] = []
            for h in clock { notes.append(MelodyNote(start: h.start, beats: h.end - h.start, midi: h.midi)) }
            let (ol, or) = renderEvents(melodyEvents(notes, beat: 1, capo: 0), seconds: Double(pl.count) / sr)
            writeWAV("\(dir)/\(slug)-overlay.wav", zip(pl, ol).map { 0.55 * $0 + 0.9 * $1 }, zip(pr, or).map { 0.55 * $0 + 0.9 * $1 }, sampleRate: sr)
            let mids = (song.melody ?? []).map(\.midi).sorted()
            let medStand = stand.isEmpty ? 0 : stand[stand.count / 2]
            print(String(format: "   melody over chords: median %+.1f dB, %.0f%% of notes ≥ 6 dB above · ", medStand, 100 * Double(stand.filter { $0 >= 6 }.count) / Double(max(1, stand.count))), terminator: "")
            print("\(slug): \(song.melody?.count ?? 0) notes, \(mids.first.map { Theory.noteName(midi: $0) } ?? "-")–\(mids.last.map { Theory.noteName(midi: $0) } ?? "-"), \(song.bpm) BPM, \(Int(song.totalBeats)) beats")
        }
    }
}
#endif
