// Time-synced lyrics: LRC parsing, finding where a recording sits in the track, and placing lines
// on the song's beats. `lyricsChecks` runs offline in the self-test; `build/selftest --lyrics-bench`
// tries real previews (iTunes + LRCLIB, cached in $BENCH_DIR like --chart-bench).
#if SELFTEST
import Foundation

extension SelfTest {
    static func lyricsChecks() {
        var fails: [String] = []
        // 1. LRC parsing: several stamps on a line, metadata, an offset tag, blank lines
        let lrc = """
        [ar:Someone]
        [offset:+500]
        [00:12.50]First line
        [00:15.00][01:15.00]Chorus line
        [00:18.20]
        [00:20,00] Last line
        """
        let parsed = Lyrics.parseLRC(lrc)
        if parsed.map(\.text) != ["First line", "Chorus line", "", "Last line", "Chorus line"] { fails.append("LRC lines: \(parsed.map(\.text))") }
        if abs((parsed.first?.time ?? 0) - 12.0) > 0.001 { fails.append("LRC offset tag: \(parsed.first?.time ?? -1)") }
        if Lyrics.normalise("Yesterday (Remastered 2009)") != "yesterday" { fails.append("title normalise") }

        // 2. a made-up 3-minute song: lines of singing with gaps; a 30 s "preview" from somewhere in it
        var rng = Lcg(s: 7)
        var lines: [TimedLyric] = []
        var t = 14.0
        while t < 175 {
            for _ in 0..<4 {
                let len = 2 + rng.next() * 3
                lines.append(TimedLyric(time: t, text: "la la la la la"))
                t += len + 0.3 + rng.next() * 1.2
            }
            t += 3 + rng.next() * 9
        }
        var aligned = 0, cases = 0
        for start in [5.0, 31.4, 58.0, 92.7, 120.0, 141.3] {
            cases += 1
            // what the melody finder hears: the lines, sung with small timing errors and breaks, plus stray notes
            var heard: [HeardNote] = []
            for (i, l) in lines.enumerated() {
                let a = l.time - start + (rng.next() - 0.5) * 0.3
                let e = a + Lyrics.singingLength(lines, i) * (0.7 + rng.next() * 0.3)
                var x = a
                while x < e { let d = 0.2 + rng.next() * 0.5; if x >= 0 && x + d <= 30 { heard.append(HeardNote(start: x, end: x + d * 0.85, midi: 64, strength: 0.5)) }; x += d }
            }
            for _ in 0..<6 { let x = rng.next() * 29; heard.append(HeardNote(start: x, end: x + 0.3, midi: 60, strength: 0.2)) }
            heard.sort { $0.start < $1.start }
            if let a = Lyrics.align(lines, heard: heard, recordingSeconds: 30, range: 0...150), abs(a.offset - start) <= 0.5, a.trustworthy {
                aligned += 1
            } else {
                let a = Lyrics.align(lines, heard: heard, recordingSeconds: 30, range: 0...150)
                fails.append(String(format: "preview at %.1f s found at %.1f s (score %.2f, margin %.2f)", start, a?.offset ?? -1, a?.score ?? 0, a?.margin ?? 0))
            }
        }

        // 3. placing on the beats: steady 120 BPM recording starting 40 s into the track, song beat 0 on recording beat 2
        var tr = Transcription(bpm: 120, beatsPerBar: 4, keyRoot: 0, minorKey: false, bars: [], sections: [SongSection(name: "Verse", chords: "C G Am F")],
                               confidence: 1, capo: 0, duration: 30)
        tr.beatTimes = (0..<60).map { 0.25 + Double($0) * 0.5 }
        tr.songZeroBeat = 2
        let song = Song(id: "x", title: "x", artist: "x", genre: "Pop", bpm: 120, sections: [SongSection(name: "Verse", chords: "C G Am F", repeats: 4)])
        let few = [TimedLyric(time: 39, text: "before"), TimedLyric(time: 41.75, text: "one"), TimedLyric(time: 44.25, text: "two"), TimedLyric(time: 80, text: "late")]
        let placed = Lyrics.place(few, offset: 40, transcription: tr, song: song, extended: false) ?? []
        // 41.75 s → recording 1.75 s → recording beat 3 → song beat 1
        if placed.map(\.text) != ["before", "one", "two"] { fails.append("placed lines: \(placed.map(\.text))") }
        if let one = placed.first(where: { $0.text == "one" }), abs(one.start - 1) > 0.01 { fails.append("line on beat \(one.start), want 1") }
        if Lyrics.current(placed, at: 0.5) != 0 || Lyrics.current(placed, at: 6) != 2 { fails.append("current line lookup") }
        // a preview whose chords repeat: lines heard in it repeat with them
        var short = tr; short.beatTimes = Array(tr.beatTimes.prefix(20)); short.duration = 10
        let looped = Lyrics.place(few, offset: 40, transcription: short, song: song, extended: true) ?? []
        if looped.filter({ $0.text == "one" }).count < 2 { fails.append("lines don't repeat with a looped preview: \(looped.map(\.text))") }

        print("\nLyrics: LRC parsing, placing lines on beats; recording found in the track \(aligned)/\(cases)")
        for f in fails { print("   FAIL: " + f) }
    }

    static func lyricsBench() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var found = 0, trusted = 0
        var wordTrusted = 0, wordMismatch = 0, bothTrusted = 0, bothAgree = 0
        var wordOffset: [String: Double] = [:]
        var heardBySong: [(title: String, words: [HeardWord], duration: Double, seconds: Double)] = []
        var linesBySong: [[TimedLyric]] = []
        for b in benchSongs {
            let slug = ChordCharts.normTitle(b.title).replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "")
            let trackFile = dir.appendingPathComponent(slug + ".track.json")
            let audio = dir.appendingPathComponent(slug + ".m4a")
            let lrcFile = dir.appendingPathComponent(slug + ".lrc")
            var track: CatalogTrack? = (try? Data(contentsOf: trackFile)).flatMap { try? JSONDecoder().decode(CatalogTrack.self, from: $0) }
            if track == nil {
                let res = sync { (try? await SongFinder.search("\(b.title) \(b.artist)")) ?? [] }
                track = res.first { ChordCharts.normTitle($0.trackName) == ChordCharts.normTitle(b.title) } ?? res.first
                if let t = track, let d = try? JSONEncoder().encode(t) { try? d.write(to: trackFile) }
            }
            guard let t = track else { print("\(b.title): not in the store"); continue }
            if !FileManager.default.fileExists(atPath: audio.path), let p = t.previewUrl.flatMap(URL.init(string:)) {
                _ = sync { (try? await SongFinder.download(p, to: audio)) != nil }
            }
            let seconds = t.trackTimeMillis.map { Double($0) / 1000 } ?? 240
            var lines: [TimedLyric]? = (try? String(contentsOf: lrcFile, encoding: .utf8)).map(Lyrics.parseLRC)
            if lines == nil {
                let r = sync { await Lyrics.fetch(title: t.trackName, artist: t.artistName, duration: seconds) }
                if case .synced(let l) = r {
                    lines = l
                    let text = l.map { String(format: "[%02d:%05.2f]%@", Int($0.time) / 60, $0.time.truncatingRemainder(dividingBy: 60), $0.text) }.joined(separator: "\n")
                    try? text.write(to: lrcFile, atomically: true, encoding: .utf8)
                } else { print("\(b.title): no synced lyrics (\(r))"); continue }
                Thread.sleep(forTimeInterval: 0.4)
            }
            guard let lines, let tr = try? Transcriber.analyze(url: audio) else { print("\(b.title): couldn't analyse"); continue }
            found += 1
            // the words the speech recogniser hears, lined up against the lyrics' words
            let words = sync { await WordListener.words(url: audio, language: WordListener.language(of: lines)) }
            heardBySong.append((b.title, words, tr.duration, seconds)); linesBySong.append(lines)
            let wa = Lyrics.alignWords(lines, heard: words, recordingSeconds: tr.duration, range: 0...max(0, seconds - tr.duration))
            if let wa {
                if wa.trustworthy { wordTrusted += 1; wordOffset[b.title] = wa.offset }
                if wa.mismatch { wordMismatch += 1 }
                // check by eye: a few heard words next to the lyric line the track has at that moment
                let sample = words.filter { Lyrics.wordKey($0.text).count >= 4 }.prefix(3).map { w -> String in
                    let line = lines.last { $0.time <= w.time + wa.offset + 0.4 && !$0.text.isEmpty }?.text ?? "-"
                    return String(format: "“%@” @%.1f → %@", w.text, w.time, String(line.prefix(38)))
                }
                print(String(format: "   words: %d heard, %d on the lyrics (%.0f%%), offset %.1f s, votes %.1f vs %.1f elsewhere%@ → %@", wa.heard, wa.matched, wa.fraction * 100,
                             wa.offset, wa.score, wa.runnerUp, wa.rivalsAgree ? " (rivals show the same words)" : "", wa.trustworthy ? "TRUSTED" : (wa.mismatch ? "MISMATCH" : "not trusted")))
                print("      " + sample.joined(separator: "  |  "))
            } else { print("   words: \(words.count) heard, no alignment") }
            guard let a = Lyrics.align(lines, heard: tr.heardMelody, recordingSeconds: tr.duration, range: 0...max(0, seconds - tr.duration)) else {
                print("\(b.title): no alignment (heard \(tr.heardMelody.count) notes, \(lines.count) lines, \(tr.duration) s)"); continue
            }
            if a.trustworthy {
                trusted += 1
                if let w = wordOffset[b.title] { bothTrusted += 1; if abs(w - a.offset) <= 1 { bothAgree += 1 } }
            }
            // independent check: at the right offset, lines with more syllables get more heard notes
            func syllables(_ t: String) -> Double {
                var n = 0.0; var prevVowel = false
                for ch in t.lowercased() { let v = "aeiouy".contains(ch); if v && !prevVowel { n += 1 }; prevVowel = v }
                return n
            }
            func syllableFit(_ off: Double) -> Double {
                var xs: [Double] = [], ys: [Double] = []
                for (i, l) in lines.enumerated() where !l.text.isEmpty {
                    let a0 = l.time - off, a1 = a0 + Lyrics.singingLength(lines, i)
                    guard a0 >= 0, a1 <= tr.duration else { continue }
                    xs.append(syllables(l.text)); ys.append(Double(tr.heardMelody.filter { $0.start >= a0 && $0.start < a1 }.count))
                }
                guard xs.count >= 3 else { return .nan }
                let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
                let c = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
                let vx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }, vy = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
                return c / max(1e-9, sqrt(vx * vy))
            }
            let fit = syllableFit(a.offset)
            let others = stride(from: 0.0, through: max(0, seconds - tr.duration), by: 2.0).filter { abs($0 - a.offset) > 4 }.map(syllableFit).filter { !$0.isNaN }
            let beaten = others.filter { $0 >= fit }.count
            if a.trustworthy {
                // what Add Song does: build the song (chords repeated to about a minute), place the lines on its beats
                let song = Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: 0)
                let placed = Lyrics.place(lines, offset: a.offset, transcription: tr, song: song, extended: true) ?? []
                let secPerBeat = 60 / Double(song.bpm)
                let shown = stride(from: 0.0, to: song.duration, by: 5.0).map { sec -> String in
                    let i = Lyrics.current(placed, at: sec / secPerBeat)
                    return String(format: "%2.0fs %@", sec, i.map { String(placed[$0].text.prefix(26)) } ?? "♪")
                }
                print("   \(placed.count) lines over \(Int(song.duration)) s; playing: " + shown.joined(separator: " | "))
            }
            let inside = lines.filter { $0.time >= a.offset && $0.time < a.offset + tr.duration && !$0.text.isEmpty }
            print(String(format: "%@: preview at %.1f s of %.0f (score %.2f, margin %.2f%@; syllables↔notes r=%.2f, beaten by %d/%d other offsets) — first line %@ %@", b.title, a.offset, seconds, a.score, a.margin,
                         a.trustworthy ? "" : (a.confirmed ? ", NOT trusted" : ", NOT trusted, unconfirmed"), fit, beaten, others.count, inside.first.map { String(format: "%.1f s", $0.time - a.offset) } ?? "-",
                         inside.first?.text ?? ""))
        }
        print("\nSynced lyrics for \(found)/\(benchSongs.count) songs; lined up confidently \(trusted)/\(found)")
        print("By the sung words: lined up confidently \(wordTrusted)/\(found); same place as the voice-timing match \(bothAgree)/\(bothTrusted) where both were sure")
        // another song's lyrics must never be lined up (that would show the wrong words)
        var wrongTrusted: [String] = [], wrongFlagged = 0
        for i in heardBySong.indices where heardBySong.count > 1 {
            let h = heardBySong[i], other = linesBySong[(i + 1) % linesBySong.count]
            guard let wa = Lyrics.alignWords(other, heard: h.words, recordingSeconds: h.duration, range: 0...max(0, (other.last?.time ?? 200) + 10 - h.duration)) else { continue }
            if wa.trustworthy { wrongTrusted.append("\(heardBySong[(i + 1) % heardBySong.count].title) lyrics on \(h.title)") }
            if wa.mismatch { wrongFlagged += 1 }
        }
        print("Another song's lyrics: wrongly lined up \(wrongTrusted.count)/\(heardBySong.count)\(wrongTrusted.isEmpty ? "" : " — " + wrongTrusted.joined(separator: ", ")); recognised as the wrong lyrics \(wrongFlagged)/\(heardBySong.count)")
    }
}
#endif
