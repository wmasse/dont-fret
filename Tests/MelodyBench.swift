// Real-recording melody benchmark: well-known public-domain tunes whose melody we know note for
// note, in real (copyrighted) recordings from the store's 30 s previews. The extracted melody is
// aligned to the written tune (any key, any tempo, any starting point) and every difference is
// classified. Run: build/selftest --melody-bench   (previews are cached in build/bench)
#if SELFTEST
import Foundation

extension SelfTest {
    struct TuneCase {
        var query: String
        /// Who sings it: "m" man, "f" woman, "k" child, "i" an instrument plays the tune. Fixes the octave.
        var voice: String
        /// The tune written as "NOTE:beats" (beats default 1), any key; "r:beats" is a rest.
        var score: String
    }

    static let silentNight = "G4:1.5 A4:0.5 G4 E4:3 G4:1.5 A4:0.5 G4 E4:3 D5:2 D5 B4:3 C5:2 C5 G4:3 A4:2 A4 C5:1.5 B4:0.5 A4 G4:1.5 A4:0.5 G4 E4:3 A4:2 A4 C5:1.5 B4:0.5 A4 G4:1.5 A4:0.5 G4 E4:3 D5:2 D5 F5:1.5 D5:0.5 B4 C5:3 E5:3 C5 G4 E4 G4:1.5 F4:0.5 D4 C4:6"
    static let amazingGrace = "D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 G4:2 E4 D4:2 D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 D5:5 B4 D5:1.5 B4:0.5 D5:0.5 B4:0.5 G4:2 D4 E4:1.5 G4:0.5 G4:0.5 E4:0.5 D4:2 D4 G4:2 B4:0.5 G4:0.5 B4:2 A4 G4:5"
    static let twinkle = "C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2 G4 G4 F4 F4 E4 E4 D4:2 G4 G4 F4 F4 E4 E4 D4:2 C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2"
    static let jingleBells = "D4 B4 A4 G4 D4:3 D4:0.5 D4:0.5 D4 B4 A4 G4 E4:4 E4 C5 B4 A4 F#4:4 D5 D5 C5 A4 B4:4 D4 B4 A4 G4 D4:4 D4 B4 A4 G4 E4:4 E4 C5 B4 A4 D5 D5 D5 D5 E5 D5 C5 A4 G4:2 D5:2 " +
        "B4 B4 B4:2 B4 B4 B4:2 B4 D5 G4:1.5 A4:0.5 B4:4 C5 C5 C5:1.5 C5:0.5 C5 B4 B4 B4:0.5 B4:0.5 B4 A4 A4 B4 A4:2 D5:2 " +
        "B4 B4 B4:2 B4 B4 B4:2 B4 D5 G4:1.5 A4:0.5 B4:4 C5 C5 C5:1.5 C5:0.5 C5 B4 B4 B4:0.5 B4:0.5 D5 D5 C5 A4 G4:4"
    static let joyToTheWorld = "D5:2 C#5:1.5 B4:0.5 A4:3 G4 F#4:2 E4:2 D4:3 A4 B4:3 B4 C#5:3 C#5 D5:7 D5 D5 C#5 B4 A4 A4:1.5 G4:0.5 F#4 D5 D5 C#5 B4 A4 A4:1.5 G4:0.5 F#4 " +
        "F#4 F#4 F#4 F#4 F#4:0.5 G4:0.5 A4:3 G4:0.5 F#4:0.5 E4 E4 E4 E4:0.5 F#4:0.5 G4:3 F#4:0.5 E4:0.5 D4 D5:2 B4 A4:1.5 G4:0.5 F#4 G4 F#4:2 E4:2 D4:4"
    static let deckTheHalls = "G4:1.5 F4:0.5 E4 D4 C4 D4 E4 C4 D4:0.5 E4:0.5 F4:0.5 D4:0.5 E4:1.5 D4:0.5 C4 B3 C4:2 G4:1.5 F4:0.5 E4 D4 C4 D4 E4 C4 D4:0.5 E4:0.5 F4:0.5 D4:0.5 E4:1.5 D4:0.5 C4 B3 C4:2 " +
        "D4:1.5 E4:0.5 F4 D4 E4:1.5 F4:0.5 G4 D4 E4:0.5 F#4:0.5 G4 A4:0.5 B4:0.5 C5 B4 A4 G4:2 G4:1.5 F4:0.5 E4 D4 C4 D4 E4 C4 A4:0.5 A4:0.5 A4:0.5 A4:0.5 G4:1.5 F4:0.5 E4 D4 C4:2"
    static let saints = "C4 E4 F4 G4:4 C4 E4 F4 G4:4 C4 E4 F4 G4:2 E4:2 C4:2 E4:2 D4:4 E4 E4 D4 C4:3 C4 E4:2 G4:2 G4 F4:3 E4 F4 G4:2 E4:2 C4:2 D4:2 C4:4"
    static let odeToJoy = "E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4:1.5 D4:0.5 D4:2 E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:1.5 C4:0.5 C4:2 " +
        "D4 D4 E4 C4 D4 E4:0.5 F4:0.5 E4 C4 D4 E4:0.5 F4:0.5 E4 D4 C4 D4 G3:2 E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:1.5 C4:0.5 C4:2"
    static let happyBirthday = "G4:0.75 G4:0.25 A4 G4 C5 B4:2 G4:0.75 G4:0.25 A4 G4 D5 C5:2 G4:0.75 G4:0.25 G5 E5 C5 B4 A4:2 F5:0.75 F5:0.25 E5 C5 D5 C5:2"
    static let weWishYou = "D4 G4 G4:0.5 A4:0.5 G4:0.5 F#4:0.5 E4 E4 E4 A4 A4:0.5 B4:0.5 A4:0.5 G4:0.5 F#4 D4 D4 B4 B4:0.5 C5:0.5 B4:0.5 A4:0.5 G4 E4 D4:0.5 D4:0.5 E4 A4 F#4 G4:2 " +
        "D4 G4 G4 G4 F#4:2 F#4 G4 F#4 E4 D4:2 A4 B4 A4 G4 D5 D4 D4:0.5 D4:0.5 E4 A4 F#4 G4:2"

    static let tuneCases: [TuneCase] = [
        TuneCase(query: "Silent Night Bing Crosby", voice: "m", score: silentNight),
        TuneCase(query: "Silent Night Kelly Clarkson", voice: "f", score: silentNight),
        TuneCase(query: "Amazing Grace Elvis Presley", voice: "m", score: amazingGrace),
        TuneCase(query: "Amazing Grace Judy Collins", voice: "f", score: amazingGrace),
        TuneCase(query: "Twinkle Twinkle Little Star Super Simple Songs", voice: "k", score: twinkle),
        TuneCase(query: "Jingle Bells Michael Buble", voice: "m", score: jingleBells),
        TuneCase(query: "Jingle Bells Frank Sinatra", voice: "m", score: jingleBells),
        TuneCase(query: "Joy to the World Nat King Cole", voice: "m", score: joyToTheWorld),
        TuneCase(query: "Deck the Halls Nat King Cole", voice: "m", score: deckTheHalls),
        TuneCase(query: "When the Saints Go Marching In Louis Armstrong", voice: "m", score: saints),
        TuneCase(query: "Happy Birthday Super Simple Songs", voice: "k", score: happyBirthday),
        TuneCase(query: "We Wish You a Merry Christmas Super Simple Songs", voice: "k", score: weWishYou),
        TuneCase(query: "Silent Night Mariah Carey", voice: "f", score: silentNight),
    ]

    struct ScoreNote { var midi: Int; var beat: Double; var beats: Double }

    static func parseScore(_ s: String) -> [ScoreNote] {
        var out: [ScoreNote] = []
        var beat = 0.0
        for tok in s.split(separator: " ") {
            let p = tok.split(separator: ":")
            let len = p.count > 1 ? Double(p[1])! : 1
            if p[0] != "r", let m = Theory.midi(noteName: String(p[0])) { out.append(ScoreNote(midi: m, beat: beat, beats: len)) }
            beat += len
        }
        return out
    }

    enum Verdict: String { case right = "ok", octave = "octave", semitone = "±1", tone = "±2", wrong = "wrong", extra = "extra", missed = "missed" }

    struct Aligned { var heard: HeardNote?; var truth: ScoreNote?; var verdict: Verdict; var timeError: Double? }

    /// Aligns heard notes to the tune (repeated, any transposition) and classifies each pairing.
    static func alignToScore(_ heard: [HeardNote], score raw: [ScoreNote], voice: String) -> (shift: Int, rows: [Aligned]) {
        guard !heard.isEmpty, !raw.isEmpty else { return (0, []) }
        // the preview can start anywhere and run past the end: three passes of the tune
        let period = (raw.last!.beat + raw.last!.beats)
        let score = (0..<3).flatMap { k in raw.map { ScoreNote(midi: $0.midi, beat: $0.beat + Double(k) * period, beats: $0.beats) } }
        let n = heard.count, m = score.count
        let gap = 0.75
        func cost(_ h: Int, _ s: Int, _ k: Int) -> Double {
            let d = ((heard[h].midi - score[s].midi - k) % 12 + 12) % 12
            return d == 0 ? 0 : (d == 1 || d == 11 || d == 2 || d == 10 ? 0.6 : 1)
        }
        // alignment: every heard note is matched or extra; score notes may be skipped; free start/end in the score
        func align(_ k: Int) -> (Double, [(Int?, Int?)]) {
            var D = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
            var B = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
            for j in 0...m { D[0][j] = 0 }
            for i in 1...n { D[i][0] = Double(i) * gap; B[i][0] = 1 }
            for i in 1...n { for j in 1...m {
                let a = D[i - 1][j - 1] + cost(i - 1, j - 1, k), b = D[i - 1][j] + gap, c = D[i][j - 1] + gap
                if a <= b && a <= c { D[i][j] = a; B[i][j] = 0 } else if b <= c { D[i][j] = b; B[i][j] = 1 } else { D[i][j] = c; B[i][j] = 2 }
            } }
            var j = (0...m).min { D[n][$0] < D[n][$1] }!
            let total = D[n][j]
            var i = n
            var path: [(Int?, Int?)] = []
            while i > 0 {
                switch B[i][j] {
                case 0: path.append((i - 1, j - 1)); i -= 1; j -= 1
                case 1: path.append((i - 1, nil)); i -= 1
                default: path.append((nil, j - 1)); j -= 1
                }
            }
            // score notes skipped inside the matched span count as missed
            return (total, path.reversed())
        }
        let best = (0..<12).map { k in (k, align(k)) }.min { $0.1.0 < $1.1.0 }!
        // the octave the singer is in: the one that makes the most pairings exactly right (a whole song
        // an octave out is still the right tune; notes that jump out of that octave count as octave slips)
        let pairs = best.1.1.compactMap { p -> (Int, Int)? in if let h = p.0, let s = p.1 { return (h, s) } else { return nil } }
        let shift = stride(from: best.0 - 36, through: best.0 + 36, by: 12).max { a, b in
            pairs.filter { heard[$0.0].midi == score[$0.1].midi + a }.count < pairs.filter { heard[$0.0].midi == score[$0.1].midi + b }.count
        } ?? best.0
        var rows: [Aligned] = []
        for (h, s) in best.1.1 {
            switch (h, s) {
            case let (h?, s?):
                let d = heard[h].midi - (score[s].midi + shift)
                let v: Verdict = d == 0 ? .right : (d % 12 == 0 ? .octave : (abs(d) == 1 ? .semitone : (abs(d) == 2 ? .tone : .wrong)))
                rows.append(Aligned(heard: heard[h], truth: score[s], verdict: v))
            case let (h?, nil): rows.append(Aligned(heard: heard[h], truth: nil, verdict: .extra))
            case let (nil, s?): rows.append(Aligned(heard: nil, truth: score[s], verdict: .missed))
            default: break
            }
        }
        // trim score notes skipped before the first / after the last heard note (outside the preview)
        while rows.first?.verdict == .missed { rows.removeFirst() }
        while rows.last?.verdict == .missed { rows.removeLast() }
        // timing: fit seconds = a + b·beat over pitch-right matches (robust: median of pairwise slopes), then onset error in beats
        let pts = rows.compactMap { r -> (Double, Double)? in r.verdict == .right || r.verdict == .octave ? (r.truth!.beat, r.heard!.start) : nil }
        if pts.count >= 4 {
            var slopes: [Double] = []
            for i in 0..<pts.count { for j in (i + 1)..<pts.count where pts[j].0 - pts[i].0 > 1 { slopes.append((pts[j].1 - pts[i].1) / (pts[j].0 - pts[i].0)) } }
            slopes.sort()
            let b = slopes.isEmpty ? 0.5 : slopes[slopes.count / 2]
            let a = pts.map { $0.1 - b * $0.0 }.sorted()[pts.count / 2]
            for i in rows.indices { if let h = rows[i].heard, let t = rows[i].truth, b > 0 { rows[i].timeError = (h.start - (a + b * t.beat)) / b } }
        }
        return (shift, rows)
    }

    static func melodyBench() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let verbose = CommandLine.arguments.contains("--verbose")
        var totals: [Verdict: Int] = [:]
        var placedRight = 0, placedWritten = 0
        var allTiming: [Double] = []
        var listenTotal = ListenScore()
        var rowsOut: [String] = []
        for c in tuneCases {
            let slug = c.query.lowercased().filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "-")
            let audio = dir.appendingPathComponent("tune-" + slug + ".m4a")
            let info = dir.appendingPathComponent("tune-" + slug + ".txt")
            if !FileManager.default.fileExists(atPath: audio.path) {
                let found = sync { (try? await SongFinder.search(c.query)) ?? [] }
                let words = c.query.lowercased().split(separator: " ").prefix(2)
                guard let t = found.first(where: { tr in words.allSatisfy { tr.trackName.lowercased().contains($0) } }) ?? found.first,
                      let p = t.previewUrl.flatMap(URL.init(string:)) else { rowsOut.append("\(c.query): not found"); continue }
                _ = sync { (try? await SongFinder.download(p, to: audio)) != nil }
                try? "\(t.trackName) — \(t.artistName)".write(to: info, atomically: true, encoding: .utf8)
            }
            let name = (try? String(contentsOf: info, encoding: .utf8)) ?? c.query
            guard let tr = try? Transcriber.analyze(url: audio) else { rowsOut.append("\(name): couldn't analyse"); continue }
            let (shift, rows) = alignToScore(tr.heardMelody, score: parseScore(c.score), voice: c.voice)
            // the melody as the app keeps it (snapped to the song's beats), back on the recording's clock
            let song = Transcriber.song(from: tr, title: "", artist: "", genre: "Pop", capo: 0, wholeSong: true)
            let placed: [HeardNote] = (song.melody ?? []).compactMap { n in
                func time(_ b: Double) -> Double? {
                    let pos = b + tr.songZeroBeat
                    let k = Int(pos.rounded(.down))
                    guard k >= 0, k + 1 < tr.beatTimes.count else { return nil }
                    return tr.beatTimes[k] + (pos - Double(k)) * (tr.beatTimes[k + 1] - tr.beatTimes[k])
                }
                guard let a = time(n.start), let b = time(n.end) else { return nil }
                return HeardNote(start: a, end: b, midi: n.midi, strength: 1)
            }
            let placedRows = alignToScore(placed, score: parseScore(c.score), voice: c.voice).rows
            let anchors = listenAnchors(dir.appendingPathComponent("tune-" + slug + ".anchors"), rows: rows, shift: shift)
            let listen = listenScore(placed, score: parseScore(c.score), anchors: anchors.anchors, shift: anchors.shift)
            listenTotal.add(listen)
            if let out = ProcessInfo.processInfo.environment["MELODY_LABELS"] {
                let lines = listenLabels(tr.heardMelody, score: parseScore(c.score), anchors: anchors.anchors, shift: anchors.shift)
                let placedLines = listenLabels(placed, score: parseScore(c.score), anchors: anchors.anchors, shift: anchors.shift)
                try? ("# \(slug) \(tr.keyRoot) \(tr.minorKey ? 1 : 0) \(listen.written)\n" + placedLines.joined(separator: "\n") + "\n").write(toFile: out + "/placed-" + slug + ".txt", atomically: true, encoding: .utf8)
                try? ("# \(slug) \(tr.keyRoot) \(tr.minorKey ? 1 : 0) \(listen.written)\n" + lines.joined(separator: "\n") + "\n").write(toFile: out + "/" + slug + ".txt", atomically: true, encoding: .utf8)
            }
            let pr = placedRows.filter { $0.verdict == .right }.count, pw = placedRows.filter { $0.truth != nil }.count
            placedRight += pr; placedWritten += pw
            var counts: [Verdict: Int] = [:]
            for r in rows { counts[r.verdict, default: 0] += 1; totals[r.verdict, default: 0] += 1 }
            let timing = rows.compactMap { $0.verdict == .right ? $0.timeError.map(abs) : nil }.sorted()
            allTiming += timing
            let truthCount = rows.filter { $0.truth != nil }.count
            let right = counts[.right] ?? 0
            func cnt(_ v: Verdict) -> Int { counts[v] ?? 0 }
            let pctRight = 100 * Double(right) / Double(max(1, truthCount))
            let onset = timing.isEmpty ? 0 : timing[timing.count / 2]
            let sung = parseScore(c.score).map { $0.midi + shift }.sorted()
            let register = sung.isEmpty ? "" : Theory.noteName(midi: sung.first!) + "–" + Theory.noteName(midi: sung.last!)
            var line = "\(name) [\(c.voice), sung \(register), \(Int(tr.bpm.rounded())) BPM, \(tr.keyName)]: "
            line += "\(tr.heardMelody.count) heard / \(truthCount) written · right \(Int(pctRight.rounded()))%"
            line += " · octave \(cnt(.octave)) · ±1 \(cnt(.semitone)) · ±2 \(cnt(.tone))"
            line += " · wrong \(cnt(.wrong)) · extra \(cnt(.extra)) · missed \(cnt(.missed))"
            line += String(format: " · onset err %.2f beat", onset)
            line += " · after snapping to beats: right \(Int((100 * Double(pr) / Double(max(1, pw))).rounded()))%"
            rowsOut.append(line)
            rowsOut.append("      as played: " + listen.summary)
            if verbose {
                for r in rows {
                    var h = String(repeating: " ", count: 25)
                    if let x = r.heard { h = String(format: "%6.2fs %-4@ %.2f %3.0fms", x.start, Theory.noteName(midi: x.midi), Double(x.strength), (x.end - x.start) * 1000) }
                    var t = ""
                    if let x = r.truth { t = String(format: "beat %5.1f %-4@", x.beat, Theory.noteName(midi: x.midi + shift)) }
                    rowsOut.append("      \(h)  \(t)  \(r.verdict.rawValue)\(r.timeError.map { String(format: " %+.2f", $0) } ?? "")")
                }
            }
        }
        func tot(_ v: Verdict) -> Int { totals[v] ?? 0 }
        var written = tot(.right) + tot(.octave) + tot(.semitone)
        written += tot(.tone) + tot(.wrong) + tot(.missed)
        let heard: Int = written - tot(.missed) + tot(.extra)
        func pct(_ v: Verdict, _ of: Int) -> String { String(format: "%.0f%%", 100 * Double(totals[v] ?? 0) / Double(max(1, of))) }
        print("\nMelody on real recordings (\(tuneCases.count) previews of tunes with known melodies):")
        print("   of the written notes: right \(pct(.right, written)) · octave off \(pct(.octave, written)) · semitone off \(pct(.semitone, written)) · tone off \(pct(.tone, written)) · other wrong \(pct(.wrong, written)) · missed \(pct(.missed, written))")
        print("   of the heard notes: extra \(pct(.extra, heard))   (onset error per song below: only meaningful at a steady tempo)")
        print("   after snapping to the song's beats (what the app plays): right \(Int((100 * Double(placedRight) / Double(max(1, placedWritten))).rounded()))% of the written notes")
        print("   as played, on the recording's clock: " + listenTotal.summary)
        print("      " + listenTotal.breakdown)
        for r in rowsOut { print("   " + r) }
    }
}
#endif
