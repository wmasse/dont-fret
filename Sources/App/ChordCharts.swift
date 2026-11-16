import Foundation

// Whole-song chords from a human-made chord chart (Songsterr), lined up with the recording.
//
// The 30-second preview only tells us part of a song. A chord chart covers the whole thing —
// verses, choruses, bridge — but has no timing and may be written in another key (often with a
// capo). So: fetch the chart, lay it out in bars, then slide it over the preview's beats in all
// 12 keys. The best fit gives the real key and shows whether the chart really is this song.
// Only chord names and their positions are kept; lyrics are never stored or shown.

/// A chord chart: sections of lines, each line a few chords at character positions in the lyric.
struct ChordChart: Hashable, Codable {
    struct Chord: Hashable, Codable { var name: String; var pos: Int }
    struct Line: Hashable, Codable {
        var chords: [Chord]
        /// Length of the line's lyric (0 for chord-only lines).
        var textLength: Int
    }
    struct Section: Hashable, Codable { var name: String; var lines: [Line] }

    var songId: Int
    var title: String
    var artist: String
    /// Capo the chart's shapes assume (0 = none).
    var capo: Int
    var sections: [Section]

    var chordCount: Int { sections.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.chords.count } } }
    var source: String { "Songsterr" }
}

/// A chart laid out in time: one chord per beat, plus the sections it came from.
struct ArrangedChart {
    struct Part { var name: String; var chords: [(name: String, beats: Int)] }
    var parts: [Part]
    var beats: [String]
}

/// How a chart was lined up with the recording.
struct ChartMatch {
    var chart: ChordChart
    /// Semitones from the chart's chord names to what the recording sounds.
    var shift: Int
    /// Line length (bars) and chords per bar used to lay the chart out.
    var lineBars: Int
    var chordsPerBar: Int
    /// Beat of the chart where the preview starts.
    var offset: Int
    /// Mean template fit of the chart over the preview, and of the best free chord path (the ceiling).
    var fit: Double
    var audioFit: Double
    /// Best fit in any *other* key (how clearly the key stood out).
    var otherKeyFit: Double
    var sections: [SongSection]
    var previewBars: [Transcription.Bar]
    var seconds: Double
    var trackSeconds: Double?
    var keyRoot: Int
    var minorKey: Bool
    /// The chart only wrote out part of the song, so its verse/chorus cycle was continued to the track's length.
    var extended = false
    /// The chart only fits after moving it to a key it wasn't written in (not its capo or a tuning).
    var unexpectedKey = false
    /// The chart fits best a half-step above how it's written.
    var nearKey = false
    /// Best fit at each key shift (for diagnostics).
    var shiftFits: [Double] = []

    /// Share of the best possible fit that the chart reaches on the preview.
    var ratio: Double { audioFit > 0 ? fit / audioFit : 0 }
    var quality: Quality {
        if unexpectedKey { return .poor }
        if nearKey { return ratio >= 0.95 && fit - otherKeyFit >= 0.03 ? .medium : .poor }
        if ratio >= 0.86 && fit - otherKeyFit > 0.04 { return .high }
        if ratio >= 0.80 && fit - otherKeyFit > 0.02 { return .medium }
        return .poor
    }
    enum Quality: String { case high = "High", medium = "Medium", poor = "Poor" }
}

enum ChordCharts {

    // MARK: lookup

    struct Hit: Hashable { var songId: Int; var title: String; var artist: String; var hasChords: Bool }

    private static func state(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh) DontFret", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try parseState(String(decoding: data, as: UTF8.self))
    }

    /// The page's embedded app state: `<script id="state" type="application/json">…</script>`.
    static func parseState(_ html: String) throws -> [String: Any] {
        guard let open = html.range(of: "<script id=\"state\" type=\"application/json\">"),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let obj = try JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }
        return obj
    }

    /// Searches Songsterr's public search page (not its API).
    static func search(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://www.songsterr.com/")!
        c.queryItems = [.init(name: "pattern", value: query)]
        let st = try await state(c.url!)
        return hits(fromState: st)
    }

    static func hits(fromState st: [String: Any]) -> [Hit] {
        let list = ((st["songs"] as? [String: Any])?["songs"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let id = d["songId"] as? Int, let t = d["title"] as? String, let a = d["artist"] as? String else { return nil }
            return Hit(songId: id, title: t, artist: a, hasChords: d["hasChords"] as? Bool ?? false)
        }
    }

    static func fetch(_ hit: Hit) async throws -> ChordChart {
        let st = try await state(URL(string: "https://www.songsterr.com/a/wsa/song-chords-s\(hit.songId)")!)
        guard let chart = chart(fromState: st, hit: hit), chart.chordCount >= 3 else { throw URLError(.cannotParseResponse) }
        return chart
    }

    static func chart(fromState st: [String: Any], hit: Hit) -> ChordChart? {
        guard let items = (st["chordpro"] as? [String: Any])?["current"] as? [[String: Any]] else { return nil }
        var capo = 0
        var sections: [ChordChart.Section] = []
        var current = ChordChart.Section(name: "Intro", lines: [])
        func flush() { if !current.lines.isEmpty { sections.append(current) } }
        for it in items {
            switch it["type"] as? String {
            case "capo":
                capo = Int(String(describing: it["text"] ?? "0").filter(\.isNumber)) ?? 0
            case "section":
                flush()
                let raw = (it["text"] as? String ?? "Part").trimmingCharacters(in: .whitespacesAndNewlines)
                current = ChordChart.Section(name: raw.isEmpty ? "Part" : String(raw.prefix(24)), lines: [])
            case "line":
                var chords: [ChordChart.Chord] = []
                var pos = 0
                for part in it["line"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "chord", let c = part["chord"] as? [String: Any], let n = chordName(c) {
                        chords.append(.init(name: n, pos: pos))
                    } else if let text = part["text"] as? String {
                        pos += text.count
                    }
                }
                let lyric = pos
                // skip blank lines and stray instructions with nothing to play
                if chords.isEmpty && lyric < 3 { continue }
                current.lines.append(.init(chords: chords, textLength: lyric))
            default: break
            }
        }
        flush()
        let chart = ChordChart(songId: hit.songId, title: hit.title, artist: hit.artist, capo: max(0, min(11, capo)), sections: sections)
        return chart.sections.isEmpty ? nil : chart
    }

    /// A chart with no section headings: 4-line parts, identical parts share a name (Part A, Part B…).
    static func splitUnlabelled(_ lines: [ChordChart.Line]) -> [ChordChart.Section] {
        var names: [String: String] = [:]
        var out: [ChordChart.Section] = []
        for start in stride(from: 0, to: lines.count, by: 4) {
            let chunk = Array(lines[start..<min(lines.count, start + 4)])
            let key = chunk.map { $0.chords.map(\.name).joined(separator: " ") }.joined(separator: "|")
            if names[key] == nil { names[key] = "Part \(Character(UnicodeScalar(65 + min(25, names.count))!))" }
            out.append(.init(name: names[key]!, lines: chunk))
        }
        return out
    }

    private static func chordName(_ c: [String: Any]) -> String? {
        guard let base = (c["baseNote"] as? [String: Any])?["name"] as? String else { return nil }
        let suffix = (c["chordType"] as? [String: Any])?["suffix"] as? String ?? ""
        var n = base + suffix
        if let first = (c["firstNote"] as? [String: Any])?["name"] as? String, first != base { n += "/" + first }
        return n
    }

    /// Finds the chart for a song: same title, same artist, has chords; skips covers and "easy" versions.
    static func find(title: String, artist: String) async -> ChordChart? {
        let wanted = normTitle(title), who = normArtist(artist)
        guard !wanted.isEmpty else { return nil }
        var tried = Set<Int>()
        func artistMatches(_ a: String) -> Bool {
            let n = normArtist(a)
            return n == who || n.contains(who) || who.contains(n)
        }
        for q in ["\(wanted) \(who)", wanted] {
            guard let hits = try? await search(q) else { continue }
            // exact title first; then titles that only add words at the end ("…in Love" vs "…in Love with You")
            let exact = hits.filter { !tried.contains($0.songId) && normTitle($0.title) == wanted && artistMatches($0.artist) }
            let longer = hits.filter { h in
                !tried.contains(h.songId) && normTitle(h.title).hasPrefix(wanted + " ") && normArtist(h.artist) == who
                    && !["live", "acoustic", "cover", "instrumental", "fingerstyle", "solo", "bass", "drum", "easy"].contains { normTitle(h.title).contains($0) }
            }
            // the search's "has chords" flag isn't reliable, so try matching songs anyway (flagged ones first)
            for h in exact.sorted(by: { $0.hasChords && !$1.hasChords }).prefix(3) + longer.prefix(2) {
                tried.insert(h.songId)
                if let c = try? await fetch(h) { return c }
            }
        }
        return nil
    }

    /// "Wonderwall (Remastered 2014)" → "wonderwall"; "Hey Jude - 2015 Mix" → "hey jude";
    /// "Señorita" → "senorita"; "Don’t Stop Believin'" → "dont stop believin".
    static func normTitle(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        for sep in [" (", " [", " - ", " feat.", " ft.", " featuring "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
        t = t.replacingOccurrences(of: "&", with: "and")
        return t.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    static func normArtist(_ s: String) -> String {
        var a = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        for sep in [" & ", " feat", " ft.", ", ", " and ", " x ", " with "] { if let r = a.range(of: sep) { a = String(a[..<r.lowerBound]) } }
        if a.hasPrefix("the ") { a.removeFirst(4) }
        return a.filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    // MARK: chord names the app can play

    /// A name the app can parse and draw: keeps it if possible, else drops the bass note, then extensions.
    static func playable(_ name: String) -> String? {
        let cleaned = name.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        if let sym = ChordSymbol.parse(cleaned), ChordLibrary.displayShape(for: sym.displayName) != nil { return sym.displayName }
        let noBass = String(cleaned.split(separator: "/").first ?? "")
        if let sym = ChordSymbol.parse(noBass), ChordLibrary.displayShape(for: sym.displayName) != nil { return sym.displayName }
        // root + major/minor only
        guard let first = noBass.first, "ABCDEFG".contains(first) else { return nil }
        var root = String(first)
        let rest = noBass.dropFirst()
        if let acc = rest.first, acc == "#" || acc == "b" { root.append(acc) }
        let tail = noBass.dropFirst(root.count)
        let minor = tail.hasPrefix("m") && !tail.hasPrefix("maj")
        let dim = tail.hasPrefix("dim") || tail.hasPrefix("°")
        let name = root + (minor || dim ? "m" : "")
        return ChordSymbol.parse(name) != nil ? name : nil
    }

    // MARK: laying the chart out in time

    /// Fills in lines and sections the chart left without chords, then gives every chord a length in beats.
    /// Each lyric line lasts `lineBars` bars (longer if it holds more chords than `chordsPerBar` allows);
    /// chords fall where they sit in the lyric. Chord-only lines give each chord half a line.
    static func arrange(_ chart: ChordChart, meter: Int, lineBars: Int, chordsPerBar: Int) -> ArrangedChart {
        // 0. a chart with no section headings: split it into parts
        var source = chart.sections
        if source.count == 1, source[0].name == "Intro", source[0].lines.count > 6 { source = splitUnlabelled(source[0].lines) }
        // 1. fill gaps
        var filled: [ChordChart.Section] = []
        for sec in source {
            var s = sec
            let type = sectionType(sec.name)
            let ref = filled.last { $0.name.lowercased() == sec.name.lowercased() && $0.lines.contains { !$0.chords.isEmpty } }
                ?? filled.last { sectionType($0.name) == type && $0.lines.contains { !$0.chords.isEmpty } }
            if !s.lines.contains(where: { !$0.chords.isEmpty }) {
                if let ref { s.lines = ref.lines } else if let prev = filled.last { s.lines = prev.lines } else { continue }
            } else {
                for i in s.lines.indices where s.lines[i].chords.isEmpty {
                    if let ref, ref.lines.indices.contains(i), !ref.lines[i].chords.isEmpty {
                        s.lines[i].chords = ref.lines[i].chords
                        s.lines[i].textLength = ref.lines[i].textLength
                    } else if let prev = s.lines[..<i].last(where: { !$0.chords.isEmpty }) {
                        s.lines[i].chords = prev.chords
                        s.lines[i].textLength = prev.textLength
                    }
                }
                s.lines.removeAll { $0.chords.isEmpty }
            }
            if !s.lines.isEmpty { filled.append(s) }
        }

        // 2. durations
        var parts: [ArrangedChart.Part] = []
        var beats: [String] = []
        let half = meter % 2 == 0 ? meter / 2 : 1
        for sec in filled {
            var chords: [(String, Int)] = []
            for line in sec.lines {
                let names = line.chords.compactMap { playable($0.name) }
                guard !names.isEmpty else { continue }
                let n = names.count
                var bars = lineBars
                let need = Int((Double(n) / Double(chordsPerBar)).rounded(.up))
                while bars < need { bars *= 2 }
                let total = bars * meter
                let quantum = n <= bars ? meter : (n <= bars * 2 ? half : 1)
                var lengths: [Int]
                if line.textLength > 0 && n > 1 {
                    // place each chord where it sits in the lyric, rounded to the grid
                    let p0 = line.chords[0].pos
                    let span = max(1, line.textLength - p0)
                    var bounds = [0]
                    for k in 1..<n {
                        let frac = Double(line.chords[k].pos - p0) / Double(span)
                        var b = Int((frac * Double(total) / Double(quantum)).rounded()) * quantum
                        b = max(bounds.last! + quantum, min(total - (n - k) * quantum, b))
                        bounds.append(b)
                    }
                    bounds.append(total)
                    lengths = (0..<n).map { bounds[$0 + 1] - bounds[$0] }
                    if lengths.contains(where: { $0 <= 0 }) { lengths = equal(total, n, quantum) }
                } else {
                    lengths = equal(total, n, quantum)
                }
                for (name, len) in zip(names, lengths) {
                    if let last = chords.last, last.0 == name, last.1 < meter, last.1 + len <= meter {
                        chords[chords.count - 1].1 += len
                    } else {
                        chords.append((name, len))
                    }
                    beats += Array(repeating: name, count: len)
                }
            }
            if !chords.isEmpty { parts.append(.init(name: sec.name, chords: chords)) }
        }
        return ArrangedChart(parts: parts, beats: beats)
    }

    private static func equal(_ total: Int, _ n: Int, _ quantum: Int) -> [Int] {
        let slots = max(n, total / quantum)
        var out = [Int](repeating: 0, count: n)
        for k in 0..<slots { out[k * n / slots] += quantum }
        let sum = out.reduce(0, +)
        if sum != total { out[n - 1] += total - sum }
        return out
    }

    static func sectionType(_ name: String) -> String {
        let l = name.lowercased()
        for t in ["pre-chorus", "prechorus", "chorus", "verse", "bridge", "intro", "outro", "solo", "interlude", "refrain"] where l.contains(t) {
            return t == "prechorus" ? "pre-chorus" : t
        }
        return l
    }

    // MARK: matching against the recording

    /// Template score of a chord on one beat: the same idea as the transcriber's Viterbi emission,
    /// but using the chord's real notes (7ths, sus, add9…) and its bass note.
    static func template(_ name: String) -> (tones: [Float], bass: Int)? {
        guard let sym = ChordSymbol.parse(name) else { return nil }
        var t = [Float](repeating: 0, count: 12)
        for (i, pc) in sym.pitchClasses.enumerated() { t[pc] = max(t[pc], i == 0 ? 1 : (i < 3 ? 0.8 : 0.55)) }
        let norm = sqrt(t.reduce(0) { $0 + $1 * $1 })
        return (t.map { $0 / norm }, sym.bass ?? sym.root)
    }

    static func score(_ tpl: (tones: [Float], bass: Int), treble: [Float], bass: [Float]) -> Float {
        let n = sqrt(treble.reduce(0) { $0 + $1 * $1 })
        guard n > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<12 { dot += treble[i] / n * tpl.tones[i] }
        return dot + 0.18 * bass[tpl.bass]
    }

    /// Lines the chart up with the preview and builds the whole song in the recording's key.
    static var lengthWeight: Float = 0.12

    static func match(_ chart: ChordChart, to tr: Transcription, trackSeconds: Double?) -> ChartMatch? {
        let meter = tr.beatsPerBar
        let n = tr.beatTreble.count
        guard n >= 8 else { return nil }
        // beats worth listening to (skip fade-in/out and silence)
        let medianRMS = tr.beatRMS.sorted()[n / 2]
        let valid = (0..<n).map { tr.beatRMS[$0] >= medianRMS * 0.35 }
        let validCount = valid.filter { $0 }.count
        guard validCount >= 8 else { return nil }

        // the ceiling: how well the transcriber's own free choice of chords fits each beat
        var audioFit: Float = 0
        for i in 0..<n where valid[i] {
            let c = tr.beatPath.indices.contains(i) ? tr.beatPath[i] : 0
            let name = Transcriber.chordName(c, flatKey: false)
            if let tpl = template(name) { audioFit += score(tpl, treble: tr.beatTreble[i], bass: tr.beatBass[i]) }
        }
        audioFit /= Float(validCount)

        struct Best { var fit: Float; var shift: Int; var offset: Int; var lineBars: Int; var cpb: Int; var total: Float }
        // best layout for each key shift
        var perShift = [Best?](repeating: nil, count: 12)
        var bestPerShift = [Float](repeating: -1, count: 12)
        let bpm = tr.bpm
        for lineBars in [1, 2, 4] {
            for cpb in [1, 2] {
                let arr = arrange(chart, meter: meter, lineBars: lineBars, chordsPerBar: cpb)
                let seq = arr.beats
                guard seq.count >= meter * 4 else { continue }
                let names = Array(Set(seq)).sorted()
                let idx = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
                let s = seq.map { idx[$0]! }
                // emission table per key shift: [shift][chord][beat]
                var table = [[[Float]]](repeating: [], count: 12)
                for shift in 0..<12 {
                    table[shift] = names.map { name -> [Float] in
                        guard let sym = ChordSymbol.parse(name), let tpl = template(sym.transposed(by: shift).displayName) else {
                            return [Float](repeating: 0, count: n)
                        }
                        return (0..<n).map { valid[$0] ? score(tpl, treble: tr.beatTreble[$0], bass: tr.beatBass[$0]) : 0 }
                    }
                }
                // how close the laid-out song is to the real track length
                let seconds = Double(seq.count) * 60 / bpm
                var lengthPenalty: Float = 0
                if let ts = trackSeconds, ts > 30 { lengthPenalty = Float(abs(log(seconds / ts))) * lengthWeight }
                let maxOffset = max(0, s.count - n / 2)
                for shift in 0..<12 {
                    // charts written for capo usually need exactly that shift: a small nudge towards it
                    let prior: Float = shift == chart.capo % 12 ? 0.006 : 0
                    for o in stride(from: 0, through: maxOffset, by: 1) {
                        var sum: Float = 0, cnt = 0
                        var i = 0
                        while i < n && o + i < s.count {
                            if valid[i] { sum += table[shift][s[o + i]][i]; cnt += 1 }
                            i += 1
                        }
                        guard cnt >= validCount * 3 / 5 else { continue }
                        let fit = sum / Float(cnt)
                        bestPerShift[shift] = max(bestPerShift[shift], fit)
                        let total = fit - lengthPenalty
                        if perShift[shift] == nil || total > perShift[shift]!.total {
                            perShift[shift] = Best(fit: fit + prior, shift: shift, offset: o, lineBars: lineBars, cpb: cpb, total: total)
                        }
                    }
                }
            }
        }
        // the key is decided by how well the chords fit, never traded against song length.
        // A real chart is written in the recording's key, for its capo, or a half-step off (tuned-down
        // guitars). Common progressions fit almost anything once moved to an arbitrary key, so a chart
        // that only fits after such a move is not trusted.
        let expected = Set([0, chart.capo % 12, 11, (chart.capo + 11) % 12])
        guard let top = (0..<12).filter({ perShift[$0] != nil }).max(by: { bestPerShift[$0] < bestPerShift[$1] }),
              var b = perShift[top] else { return nil }
        if !expected.contains(b.shift),
           let alt = expected.compactMap({ perShift[$0] }).max(by: { bestPerShift[$0.shift] < bestPerShift[$1.shift] }),
           bestPerShift[alt.shift] >= bestPerShift[b.shift] - 0.03 {
            b = alt
        }
        b.fit = bestPerShift[b.shift]
        let other = bestPerShift.enumerated().filter { $0.offset != b.shift }.map(\.element).max() ?? 0
        // a half-step up is also plausible (chart written a semitone low), but needs a very clear fit
        let nearKey = [1, (chart.capo + 1) % 12].contains(b.shift) && !expected.contains(b.shift)
        let unexpectedKey = !expected.contains(b.shift) && !nearKey

        // build the song in the recording's key
        var arr = arrange(chart, meter: meter, lineBars: b.lineBars, chordsPerBar: b.cpb)
        var extended = false
        if let ts = trackSeconds, ts > 60 {
            let secPerBeat = 60 / bpm
            let body = arr.parts.filter { !["intro", "outro"].contains(sectionType($0.name)) }
            let cycle = body.isEmpty ? arr.parts : body
            var k = 0
            while Double(arr.beats.count) * secPerBeat < ts * 0.8, !cycle.isEmpty, k < 40 {
                let part = cycle[k % cycle.count]
                let beats = part.chords.flatMap { Array(repeating: $0.name, count: $0.beats) }
                if Double(arr.beats.count + beats.count) * secPerBeat > ts * 1.1 { break }
                // keep an outro at the end
                if let last = arr.parts.last, sectionType(last.name) == "outro" {
                    arr.parts.insert(part, at: arr.parts.count - 1)
                } else {
                    arr.parts.append(part)
                }
                arr.beats += beats
                extended = true
                k += 1
            }
        }
        let flat = preferFlats(arr.beats, shift: b.shift)
        func sounding(_ name: String) -> String {
            guard let sym = ChordSymbol.parse(name) else { return name }
            return sym.transposed(by: b.shift, preferFlat: flat).displayName
        }
        var sections: [SongSection] = []
        for part in arr.parts {
            let tokens = part.chords.map { c -> String in
                let n = sounding(c.name)
                if c.beats == meter { return n }
                // whole bars read better written out bar by bar
                if c.beats % meter == 0 { return Array(repeating: n, count: c.beats / meter).joined(separator: " ") }
                return n + ":" + String(c.beats)
            }.joined(separator: " ")
            if var last = sections.last, last.chords == tokens, sectionType(last.name) == sectionType(part.name) {
                last.repeats += 1
                sections[sections.count - 1] = last
            } else {
                sections.append(SongSection(name: part.name, chords: tokens))
            }
        }
        // the preview's bars, read from the chart where it lines up
        var bars: [Transcription.Bar] = []
        var i = ((tr.barPhase % meter) + meter) % meter
        // keep the chart's own bar lines: shift the first bar so chart beat (offset + i) is a downbeat
        while (b.offset + i) % meter != 0 && i < n { i += 1 }
        while i + meter <= n && b.offset + i + meter <= arr.beats.count {
            let seg = (0..<meter).map { sounding(arr.beats[b.offset + i + $0]) }
            let tokens: String
            if Set(seg).count == 1 { tokens = seg[0] }
            else if meter == 4, seg[0] == seg[1], seg[2] == seg[3] { tokens = "\(seg[0]):2 \(seg[2]):2" }
            else { tokens = seg[0] }
            let start = tr.beatTimes[i]
            let end = i + meter < tr.beatTimes.count ? tr.beatTimes[i + meter] : start + Double(meter) * 60 / bpm
            if valid[i] || valid[min(n - 1, i + meter - 1)] { bars.append(.init(start: start, end: end, tokens: tokens)) }
            i += meter
        }
        // key from the chart's chords, weighted by time
        var path: [Int] = []
        for name in arr.beats {
            guard let sym = ChordSymbol.parse(sounding(name)) else { continue }
            let minor = [.minor, .min7, .m7b5, .dim, .dim7].contains(sym.quality)
            path.append(sym.root + (minor ? 12 : 0))
        }
        var chroma = [Float](repeating: 0, count: 12)
        for (k, tb) in tr.beatTreble.enumerated() where valid[k] { for j in 0..<12 { chroma[j] += tb[j] } }
        var key = Transcriber.refineKey(path: path, chroma: chroma)
        // the recording's own key wins when its home chord is one of the chart's two main chords
        var weight: [Int: Int] = [:]
        for c in path { weight[c, default: 0] += 1 }
        let main = weight.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        if main.contains(tr.minorKey ? 12 + tr.keyRoot : tr.keyRoot) { key = (tr.keyRoot, tr.minorKey) }

        return ChartMatch(chart: chart, shift: b.shift, lineBars: b.lineBars, chordsPerBar: b.cpb, offset: b.offset,
                          fit: Double(b.fit), audioFit: Double(audioFit), otherKeyFit: Double(other),
                          sections: sections, previewBars: bars, seconds: Double(arr.beats.count) * 60 / bpm,
                          trackSeconds: trackSeconds, keyRoot: key.0, minorKey: key.1, extended: extended,
                          unexpectedKey: unexpectedKey, nearKey: nearKey, shiftFits: bestPerShift.map(Double.init))
    }

    /// Flat spellings when the sounding key is a flat key (F, Bb, Eb, Ab, Db).
    private static func preferFlats(_ beats: [String], shift: Int) -> Bool {
        var count: [Int: Int] = [:]
        for name in beats { if let sym = ChordSymbol.parse(name) { count[(sym.root + shift) % 12, default: 0] += 1 } }
        guard let tonic = count.max(by: { $0.value < $1.value })?.key else { return false }
        return Theory.flatKeys.contains(tonic)
    }

    /// The transcription with the chart's whole-song chords in place of the preview-only guess.
    static func apply(_ m: ChartMatch, to tr: Transcription) -> Transcription {
        var t = tr
        t.sections = m.sections
        if !m.previewBars.isEmpty { t.bars = m.previewBars }
        t.keyRoot = m.keyRoot
        t.minorKey = m.minorKey
        t.capo = Transcriber.easiestCapo(Set(m.sections.flatMap { $0.tokens(beatsPerBar: tr.beatsPerBar).map(\.chord) }))
        t.confidence = m.quality == .high ? 0.8 : 0.55
        return t
    }
}
