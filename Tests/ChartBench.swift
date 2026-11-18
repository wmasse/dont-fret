// Real-song benchmark for Add Any Song: downloads (once) the iTunes preview and the Songsterr chart
// for well-known songs whose real chords are known, then compares preview-only transcription with
// chart + preview matching. Cached in $BENCH_DIR so later runs work offline.
// Run: build/selftest --chart-bench   (BENCH_DIR defaults to ./build/bench)
#if SELFTEST
import Foundation

extension SelfTest {
    struct BenchSong { var title: String; var artist: String; var core: [String]; var extra: [String] = []; var key: String }

    static let benchSongs: [BenchSong] = [
        .init(title: "I'm Yours", artist: "Jason Mraz", core: ["B", "F#", "G#m", "E"], extra: ["C#m", "D#m"], key: "B"),
        .init(title: "Wonderwall", artist: "Oasis", core: ["F#m", "A", "E", "B"], extra: ["D", "C#m"], key: "F#m"),
        .init(title: "Let It Be", artist: "The Beatles", core: ["C", "G", "Am", "F"], extra: ["Em", "Dm", "Bb"], key: "C"),
        .init(title: "Someone Like You", artist: "Adele", core: ["A", "E", "F#m", "D"], extra: ["C#m", "Bm"], key: "A"),
        .init(title: "Stand By Me", artist: "Ben E. King", core: ["A", "F#m", "D", "E"], key: "A"),
        .init(title: "Knockin' On Heaven's Door", artist: "Bob Dylan", core: ["G", "D", "Am", "C"], key: "G"),
        .init(title: "Perfect", artist: "Ed Sheeran", core: ["Ab", "Fm", "Db", "Eb"], extra: ["Cm", "Bbm"], key: "Ab"),
        .init(title: "Zombie", artist: "The Cranberries", core: ["Em", "C", "G", "D"], key: "Em"),
        .init(title: "Take Me Home, Country Roads", artist: "John Denver", core: ["A", "E", "F#m", "D"], extra: ["C#m", "Bm"], key: "A"),
        .init(title: "Sweet Home Alabama", artist: "Lynyrd Skynyrd", core: ["D", "C", "G"], extra: ["F"], key: "D"),
        .init(title: "Creep", artist: "Radiohead", core: ["G", "B", "C", "Cm"], key: "G"),
        .init(title: "Riptide", artist: "Vance Joy", core: ["Bbm", "Ab", "Db"], extra: ["Gb", "Eb", "Fm"], key: "Db"),
        .init(title: "Brown Eyed Girl", artist: "Van Morrison", core: ["G", "C", "D"], extra: ["Em"], key: "G"),
        .init(title: "Smells Like Teen Spirit", artist: "Nirvana", core: ["F", "Bb", "Ab", "Db"], key: "F"),
        .init(title: "A Horse With No Name", artist: "America", core: ["Em", "D"], key: "Em"),
        .init(title: "The Adults Are Talking", artist: "The Strokes", core: [], key: ""),
        .init(title: "Just", artist: "Radiohead", core: [], key: "")
    ]

    /// "F#m7" → "F#m", "D6/9" → "D", "Bb5" → "Bb" (pitch-class + minor flag, spelled with sharps).
    static func reduce(_ name: String) -> String? {
        let first = String(name.split(separator: "/").first ?? "")
        guard let sym = ChordSymbol.parse(first) ?? ChordSymbol.parse(ChordCharts.playable(first) ?? "") else { return nil }
        let minor = [.minor, .min7, .m7b5, .dim, .dim7].contains(sym.quality)
        return Theory.name(sym.root, flat: false) + (minor ? "m" : "")
    }

    static func sync<T>(_ f: @escaping () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        var out: T?
        Task.detached { out = await f(); sem.signal() }
        sem.wait()
        return out!
    }

    static func chartBench() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows: [String] = []
        var n = 0, audioKey = 0, chartKey = 0, chartFound = 0, audioRecall = 0.0, chartRecall = 0.0, audioPrec = 0.0, chartPrec = 0.0
        var lengthErr: [Double] = []
        var usedChart = 0, chartWrongKeyUsed = 0
        var finalKey = 0, finalRecall = 0.0, finalPrec = 0.0
        var beatSongs = 0, beatRight = 0, beatRoot = 0, beatNear = 0, beatTotal = 0
        var sameSongs = 0, sameRight = 0, sameNear = 0, sameTotal = 0, sameTemplateRight = 0, sameSkipped = 0
        for b in benchSongs {
            let slug = ChordCharts.normTitle(b.title).replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "")
            let trackFile = dir.appendingPathComponent(slug + ".track.json")
            let audio = dir.appendingPathComponent(slug + ".m4a")
            let chartFile = dir.appendingPathComponent(slug + ".chart.json")
            // 1. the store track and its preview
            var track: CatalogTrack? = (try? Data(contentsOf: trackFile)).flatMap { try? JSONDecoder().decode(CatalogTrack.self, from: $0) }
            if track == nil {
                let found = sync { (try? await SongFinder.search("\(b.title) \(b.artist)")) ?? [] }
                track = found.first { ChordCharts.normTitle($0.trackName) == ChordCharts.normTitle(b.title) } ?? found.first
                if let t = track, let d = try? JSONEncoder().encode(t) { try? d.write(to: trackFile) }
            }
            guard let t = track else { rows.append("\(b.title): not in the store"); continue }
            if !FileManager.default.fileExists(atPath: audio.path), let p = t.previewUrl.flatMap(URL.init(string:)) {
                _ = sync { (try? await SongFinder.download(p, to: audio)) != nil }
            }
            guard let tr = try? Transcriber.analyze(url: audio) else { rows.append("\(b.title): couldn't analyse"); continue }
            // 2. the chart
            var chart: ChordChart? = (try? Data(contentsOf: chartFile)).flatMap { try? JSONDecoder().decode(ChordChart.self, from: $0) }
            if chart == nil && !FileManager.default.fileExists(atPath: chartFile.path + ".none") {
                chart = sync { await ChordCharts.find(title: t.trackName, artist: t.artistName) }
                if let c = chart, let d = try? JSONEncoder().encode(c) { try? d.write(to: chartFile) } else { FileManager.default.createFile(atPath: chartFile.path + ".none", contents: nil) }
            }
            let trackSeconds = t.trackTimeMillis.map { Double($0) / 1000 }
            let m = chart.flatMap { ChordCharts.match($0, to: tr, trackSeconds: trackSeconds) }
            // beat by beat: the chord the transcriber heard against the chart's chord on that beat,
            // where the chart lines up well (the chart is a human transcription, so it's the reference)
            var beatLine = ""
            if let m, m.quality == .high, m.beatChords.count == tr.beatPath.count {
                let med = tr.beatRMS.sorted()[tr.beatRMS.count / 2]
                var right = 0, root = 0, near = 0, total = 0
                var confusions: [String: Int] = [:]
                for i in tr.beatPath.indices where tr.beatRMS[i] >= med * 0.35 {
                    guard let want = m.beatChords[i] else { continue }
                    total += 1
                    let got = tr.beatPath[i]
                    if got == want { right += 1 }
                    if got % 12 == want % 12 { root += 1 }
                    // the right chord, just a beat early or late (a timing slip, not a wrong chord)
                    if got == want || (i > 0 && m.beatChords[i - 1] == got) || (i + 1 < m.beatChords.count && m.beatChords[i + 1] == got) { near += 1 }
                    else { confusions["\(Transcriber.chordName(want, flatKey: false))→\(Transcriber.chordName(got, flatKey: false))", default: 0] += 1 }
                }
                if total > 0 {
                    beatSongs += 1; beatRight += right; beatRoot += root; beatNear += near; beatTotal += total
                    let top = confusions.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                    beatLine = String(format: "\n      beat by beat vs the chart: %.0f%% right chord, %.0f%% right root, %.0f%% within a beat (%d beats); wrong: %@", 100 * Double(right) / Double(total), 100 * Double(root) / Double(total), 100 * Double(near) / Double(total), total, top)
                }
            }
            // with ChordNet on, the chart lines up against this run's own chords (meter and the quality check
            // use them); also score it against the chart as the template run lines it up, so the reference is the same
            if ChordNet.enabled, let chart {
                ChordNet.forceEnabled = false
                let ref = try? Transcriber.analyze(url: audio)
                ChordNet.forceEnabled = nil
                if let ref, let mr = ChordCharts.match(chart, to: ref, trackSeconds: trackSeconds), mr.quality == .high,
                   mr.beatChords.count == ref.beatPath.count {
                    if ref.beatTimes == tr.beatTimes {
                        let med = ref.beatRMS.sorted()[ref.beatRMS.count / 2]
                        var right = 0, near = 0, total = 0, tRight = 0
                        for i in ref.beatPath.indices where ref.beatRMS[i] >= med * 0.35 {
                            guard let want = mr.beatChords[i] else { continue }
                            total += 1
                            let got = tr.beatPath[i]
                            if got == want { right += 1 }
                            if ref.beatPath[i] == want { tRight += 1 }
                            if got == want || (i > 0 && mr.beatChords[i - 1] == got) || (i + 1 < mr.beatChords.count && mr.beatChords[i + 1] == got) { near += 1 }
                        }
                        sameSongs += 1; sameRight += right; sameNear += near; sameTotal += total; sameTemplateRight += tRight
                        beatLine += String(format: "\n      same reference (chart lined up by the template run): ChordNet %.0f%% right, %.0f%% within a beat; templates %.0f%% right (%d beats)",
                                           100 * Double(right) / Double(max(1, total)), 100 * Double(near) / Double(max(1, total)), 100 * Double(tRight) / Double(max(1, total)), total)
                    } else {
                        beatLine += "\n      same reference: beats differ from the template run (tempo folded differently)"
                        sameSkipped += 1
                    }
                }
            }

            func chords(_ secs: [SongSection], meter: Int) -> [(String, Double)] {
                secs.flatMap { s in Array(repeating: s.tokens(beatsPerBar: meter), count: max(1, s.repeats)).flatMap { $0 } }
                    .compactMap { tok in reduce(tok.chord).map { ($0, tok.beats) } }
            }
            func grade(_ secs: [SongSection], meter: Int) -> (recall: Double, precision: Double, set: [String]) {
                let all = chords(secs, meter: meter)
                let set = Array(Set(all.map(\.0)))
                let core = Set(b.core.compactMap(reduce)), allowed = core.union(b.extra.compactMap(reduce))
                let recall = core.isEmpty ? 0 : Double(core.intersection(set).count) / Double(core.count)
                let total = all.reduce(0) { $0 + $1.1 }
                let good = all.filter { allowed.contains($0.0) }.reduce(0) { $0 + $1.1 }
                return (recall, total > 0 ? good / total : 0, set.sorted())
            }
            func keyOK(_ root: Int, _ minor: Bool) -> Bool {
                guard let sym = ChordSymbol.parse(b.key) else { return false }
                let wantMinor = sym.quality == .minor
                let rel = wantMinor ? (sym.root + 3) % 12 : sym.root
                let got = minor ? (root + 3) % 12 : root
                return rel == got
            }
            let a = grade(tr.sections, meter: tr.beatsPerBar)
            var line = "\(b.title) — \(Int(tr.bpm.rounded())) BPM\n      preview only: key \(tr.keyName)\(b.key.isEmpty ? "" : keyOK(tr.keyRoot, tr.minorKey) ? " ✓" : " ✗"), chords \(a.set.joined(separator: " "))"
            if !b.core.isEmpty {
                n += 1
                if keyOK(tr.keyRoot, tr.minorKey) { audioKey += 1 }
                audioRecall += a.recall; audioPrec += a.precision
                line += String(format: "  (found %.0f%% of the real chords, %.0f%% of the time on a right chord)", a.recall * 100, a.precision * 100)
            }
            // what the user actually gets: the chart when it's trusted, otherwise the preview's chords
            if !b.core.isEmpty {
                if let m, m.quality != .poor {
                    let c = grade(m.sections, meter: tr.beatsPerBar)
                    finalRecall += c.recall; finalPrec += c.precision; if keyOK(m.keyRoot, m.minorKey) { finalKey += 1 }
                } else {
                    finalRecall += a.recall; finalPrec += a.precision; if keyOK(tr.keyRoot, tr.minorKey) { finalKey += 1 }
                }
            }
            if let m {
                let c = grade(m.sections, meter: tr.beatsPerBar)
                let parts = m.sections.map { "\($0.name)×\($0.repeats)" }.joined(separator: ", ")
                line += "\n      chart: shift \(m.shift) (chart capo \(m.chart.capo)), fit \(String(format: "%.2f", m.fit))/\(String(format: "%.2f", m.audioFit)) = \(String(format: "%.0f%%", m.ratio * 100)), other key \(String(format: "%.2f", m.otherKeyFit)), \(m.quality.rawValue)\(m.unexpectedKey ? " (unexpected key)" : "")\n      fit by shift: \(m.shiftFits.map { String(format: "%.2f", $0) }.joined(separator: " "))"
                line += "\n      chart song: \(Int(m.seconds))s vs track \(Int(trackSeconds ?? 0))s, lines \(m.lineBars) bar(s)\(m.extended ? ", extended" : ""), chords \(c.set.joined(separator: " ")); \(parts)"
                if !b.core.isEmpty {
                    chartFound += 1
                    let k = keyOK(m.keyRoot, m.minorKey)
                    if k { chartKey += 1 }
                    chartRecall += c.recall; chartPrec += c.precision
                    line += String(format: "\n      chart result: key %@, %.0f%% of real chords, %.0f%% of the time right", k ? "✓" : "✗", c.recall * 100, c.precision * 100)
                    if m.quality != .poor { usedChart += 1; if c.precision < 0.7 { chartWrongKeyUsed += 1 } }
                }
                if let ts = trackSeconds { lengthErr.append(abs(m.seconds - ts) / ts) }
            } else {
                line += "\n      chart: \(chart == nil ? "none found" : "couldn't line up")"
            }
            rows.append(line + beatLine)
        }
        // wrong chart on purpose: should come out Poor and not be used
        var wrongUsed = 0, wrongTotal = 0
        var wrongLines: [String] = []
        let ids = ["wonderwall", "let-it-be", "creep", "zombie", "im-yours", "stand-by-me", "someone-like-you", "knockin-on-heavens-door"]
        for (i, a) in ids.enumerated() {
            let other = ids[(i + 3) % ids.count]
            guard let c = (try? Data(contentsOf: dir.appendingPathComponent(other + ".chart.json"))).flatMap({ try? JSONDecoder().decode(ChordChart.self, from: $0) }),
                  let tr = try? Transcriber.analyze(url: dir.appendingPathComponent(a + ".m4a")),
                  let m = ChordCharts.match(c, to: tr, trackSeconds: nil) else { continue }
            wrongTotal += 1
            if m.quality != .poor { wrongUsed += 1 }
            wrongLines.append("\(other) chart on \(a): shift \(m.shift) \(String(format: "%.0f%%", m.ratio * 100)) \(m.quality.rawValue)")
        }
        func pct(_ x: Double) -> String { String(format: "%.0f%%", 100 * x) }
        print("\nReal-song benchmark (\(n) songs with known chords)")
        print("   preview only : key right \(audioKey)/\(n), real chords found \(pct(audioRecall / Double(max(1, n)))), time on a right chord \(pct(audioPrec / Double(max(1, n))))")
        print("   beat by beat : right chord on \(pct(Double(beatRight) / Double(max(1, beatTotal)))) of beats, right root on \(pct(Double(beatRoot) / Double(max(1, beatTotal)))), right chord within a beat \(pct(Double(beatNear) / Double(max(1, beatTotal)))) (\(beatTotal) beats in \(beatSongs) songs with a well-matched chart)")
        if ChordNet.enabled {
            print("   same chart   : ChordNet right chord on \(pct(Double(sameRight) / Double(max(1, sameTotal)))) of beats, within a beat \(pct(Double(sameNear) / Double(max(1, sameTotal)))); templates \(pct(Double(sameTemplateRight) / Double(max(1, sameTotal)))) (\(sameTotal) beats in \(sameSongs) songs, charts lined up by the template run; \(sameSkipped) skipped)")
        }
        print("   chart found  : \(chartFound)/\(n); used (fit not poor) \(usedChart), of which wrong \(chartWrongKeyUsed)")
        print("   chart+audio  : key right \(chartKey)/\(chartFound), real chords found \(pct(chartRecall / Double(max(1, chartFound)))), time on a right chord \(pct(chartPrec / Double(max(1, chartFound))))")
        print("   what you get : key right \(finalKey)/\(n), real chords found \(pct(finalRecall / Double(max(1, n)))), time on a right chord \(pct(finalPrec / Double(max(1, n)))), whole song for \(usedChart)/\(n)")
        if !lengthErr.isEmpty { print("   song length  : median error \(pct(lengthErr.sorted()[lengthErr.count / 2])) vs the real track") }
        print("   wrong chart  : accepted \(wrongUsed)/\(wrongTotal) — " + wrongLines.joined(separator: "; "))
        for r in rows { print("   " + r) }
    }
}
#endif

/// Whole-song listening: a preview looped to song length (with silence around it, as a real
/// listen would have) must come back as one song of the right length, quickly.
func wholeBench() {
    let dir = ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "bench"
    for name in ["riptide", "perfect", "wonderwall", "creep"] {
        let url = URL(fileURLWithPath: "\(dir)/\(name).m4a")
        guard let (x, sr) = try? Transcriber.readMono(url) else { print("   \(name): no file"); continue }
        // loop a whole number of 4-bar phrases, so the beat runs on steadily like a real song
        guard let pre = try? Transcriber.analyze(samples: x, sampleRate: sr), pre.bars.count >= 8 else { print("   \(name): preview failed"); continue }
        let phrases = pre.bars.count / 4 * 4
        let clip = Array(x[Int(pre.bars[0].start * sr)..<min(x.count, Int(pre.bars[phrases - 1].end * sr))])
        let silence = [Float](repeating: 0, count: Int(sr * 3))
        var long = silence
        while Double(long.count) / sr < 200 { long += clip }
        long += silence
        let t0 = Date()
        let trimmed = WholeSongListener.trimSilence(long)
        guard let t = try? Transcriber.analyze(samples: trimmed, sampleRate: sr) else { print("   \(name): analysis failed"); continue }
        let s = Transcriber.song(from: t, title: name, artist: "", genre: "Pop", wholeSong: true)
        print(String(format: "   %@: heard %.0f s (trimmed from %.0f), song %@, %d bars, %d parts, key %@, %.1f s to analyse",
                     name, t.duration, Double(long.count) / sr, s.durationText, t.bars.count, s.sections.count, t.keyName, Date().timeIntervalSince(t0)))
        print("      " + s.sections.map { "\($0.name)×\($0.repeats): \($0.chords)" }.joined(separator: " | "))
    }
}
