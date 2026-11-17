import Foundation

/// One line of a song's lyrics, on the song's beat timeline (like `MelodyNote`), so it lines up
/// with the chords and the melody at any tempo.
struct LyricLine: Codable, Hashable {
    /// Song beat where the line starts.
    var start: Double
    /// About how long it's sung for, in beats (for the karaoke wipe).
    var beats: Double
    /// The words. Empty for an instrumental gap.
    var text: String
    var end: Double { start + beats }

    enum CodingKeys: String, CodingKey { case start = "b", beats = "d", text = "t" }
}

/// A line of an LRC file: seconds from the start of the full track.
struct TimedLyric: Hashable {
    var time: Double
    var text: String
}

/// Time-synced lyrics from LRCLIB (https://lrclib.net), a free, open lyrics database with a public
/// API that needs no account or key. Only the song's title, artist and length are sent.
enum Lyrics {
    enum Lookup {
        case synced([TimedLyric])
        /// LRCLIB knows the song but has no lyrics for it.
        case instrumental
        /// Words, but without timings (nothing to sing along to).
        case unsynced
        case notFound
        case failed
    }

    private struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    static let userAgent = "DontFret/1.1 (https://github.com/wmasse/dont-fret)"

    // MARK: fetching

    static func fetch(title: String, artist: String, duration: Double?) async -> Lookup {
        // 1. the exact signature (title, artist and length within a couple of seconds)
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        if let d = duration, d >= 1, d <= 3600 { c.queryItems?.append(.init(name: "duration", value: String(Int(d.rounded())))) }
        var exact: Record?
        switch await request(c.url!) {
        case .some((200, let data)): exact = try? JSONDecoder().decode(Record.self, from: data)
        case .some((404, _)): break
        default: return .failed
        }
        if let r = exact, let l = lookup(r) { return l }
        // 2. a search on title + artist (another release of the song may have slightly different length)
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard case .some((200, let data)) = await request(s.url!),
              let found = try? JSONDecoder().decode([Record].self, from: data) else {
            return exact.flatMap(lookup) ?? .notFound
        }
        let want = normalise(title)
        let candidates = found.filter { r in
            let n = normalise(r.trackName ?? "")
            let sameTitle = n == want || n.hasPrefix(want + " ") || want.hasPrefix(n + " ")
            let closeLength = duration.map { d in r.duration.map { abs($0 - d) <= 5 } ?? false } ?? true
            return sameTitle && closeLength
        }
        let synced = candidates.filter { !($0.syncedLyrics ?? "").isEmpty }
            .min { abs(($0.duration ?? 0) - (duration ?? 0)) < abs(($1.duration ?? 0) - (duration ?? 0)) }
        if let r = synced, let l = lookup(r) { return l }
        if let r = exact ?? candidates.first, let l = lookup(r) { return l }
        return .notFound
    }

    private static func lookup(_ r: Record) -> Lookup? {
        if r.instrumental == true { return .instrumental }
        if let s = r.syncedLyrics {
            let lines = parseLRC(s)
            if lines.filter({ !$0.text.isEmpty }).count >= 2 { return .synced(lines) }
        }
        if !(r.plainLyrics ?? "").isEmpty { return .unsynced }
        return nil
    }

    /// GET with the app's User-Agent; on 429/503 waits as long as the server asks (once).
    private static func request(_ url: URL) async -> (Int, Data)? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
            if [429, 503].contains(http.statusCode), attempt == 0 {
                let wait = min(10, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2)
                try? await Task.sleep(nanoseconds: UInt64(wait * Double.random(in: 1...1.3) * 1e9))
                continue
            }
            return (http.statusCode, data)
        }
        return nil
    }

    static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        // "(Remastered 2011)", "- Live", "[feat. X]"
        for open in ["(", "[", " - "] { if let r = t.range(of: open) { t = String(t[..<r.lowerBound]) } }
        t = t.replacingOccurrences(of: "&", with: "and")
        return t.filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").joined(separator: " ")
    }

    /// Parses LRC: `[mm:ss.xx] words`, several stamps per line allowed; metadata tags are skipped.
    static func parseLRC(_ s: String) -> [TimedLyric] {
        var out: [TimedLyric] = []
        var offset = 0.0
        for raw in s.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                    times.append(m * 60 + sec)
                } else if parts.count == 2, parts[0].lowercased() == "offset", let ms = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    // positive offset: lyrics come sooner
                    offset = -ms / 1000
                }
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(TimedLyric(time: t, text: text)) }
        }
        out = out.map { TimedLyric(time: max(0, $0.time + offset), text: $0.text) }
        out.sort { $0.time < $1.time }
        return out
    }

    // MARK: lining up with the recording

    /// About how long a line is sung for, in seconds: until the next line when that comes soon,
    /// otherwise a guess from the number of words.
    static func singingLength(_ lines: [TimedLyric], _ i: Int) -> Double {
        let gap = i + 1 < lines.count ? lines[i + 1].time - lines[i].time : 8
        if lines[i].text.isEmpty { return 0 }
        let words = Double(lines[i].text.split(separator: " ").count)
        let guess = min(9, 1.2 + words * 0.42)
        return max(0.4, gap <= 7 ? gap - 0.25 : min(gap - 0.25, guess))
    }

    struct Alignment {
        /// Seconds into the full track where the recording starts.
        var offset: Double
        /// Correlation between heard singing and when the lyrics say there's singing (−1…1).
        var score: Double
        /// How far ahead the best offset is of the best one more than 3 s away.
        var margin: Double
        /// Every offset that scored nearly as well puts the same words at the same moments
        /// (a repeated chorus), so it doesn't matter which one is right.
        var rivalsAgree = false
        /// A second way of reading the heard voice (weighted by how clearly each note stood out)
        /// lands within a second of the same place.
        var confirmed = false
        var trustworthy: Bool { confirmed && score >= 0.25 && (margin >= 0.025 || rivalsAgree) }
    }

    /// Finds where in the full track the recording starts by matching when the melody finder heard
    /// a voice against when the lyrics say there's singing. `range` limits where it may start.
    ///
    /// The melody finder also picks up guitar lines, so "a voice" is a rough signal: it's read two
    /// ways (any note, with breaths filled in; and notes weighted by strength, smoothed), and the
    /// result only counts as trustworthy when both agree and the best place stands out.
    static func align(_ lines: [TimedLyric], heard: [HeardNote], recordingSeconds: Double,
                      range: ClosedRange<Double>) -> Alignment? {
        let dt = 0.1
        let n = Int(recordingSeconds / dt)
        guard n > 50, lines.count >= 2, !heard.isEmpty, range.upperBound >= range.lowerBound else { return nil }
        // 1. any note, 0/1 per bin; a voice that only stops for a breath is still singing
        var plain = [Double](repeating: 0, count: n)
        for h in heard {
            let a = max(0, Int(h.start / dt)), b = min(n, Int((h.end / dt).rounded(.up)))
            if a < b { for k in a..<b { plain[k] = 1 } }
        }
        var filled = plain
        var lastOn = -100
        for k in 0..<n where plain[k] > 0 {
            if k - lastOn > 1 && k - lastOn <= 6 { for j in (lastOn + 1)..<k { filled[j] = 1 } }
            lastOn = k
        }
        // 2. notes weighted by strength, smoothed over half a second
        var weighted = [Double](repeating: 0, count: n)
        for h in heard {
            let a = max(0, Int(h.start / dt)), b = min(n, Int((h.end / dt).rounded(.up)))
            if a < b { for k in a..<b { weighted[k] += Double(h.strength) } }
        }
        var smooth = weighted
        for k in 0..<n { let lo = max(0, k - 2), hi = min(n - 1, k + 2); smooth[k] = weighted[lo...hi].reduce(0, +) / Double(hi - lo + 1) }

        // when the lyrics say there's singing, over the whole range the recording could cover
        let lo = Int((range.lowerBound / dt).rounded(.down)), hi = Int((range.upperBound / dt).rounded(.up))
        let m = hi - lo + n + 1
        var sung = [Double](repeating: 0, count: m)
        for i in lines.indices {
            let a = Int((lines[i].time / dt).rounded()) - lo
            let b = a + Int((singingLength(lines, i) / dt).rounded())
            for k in max(0, a)..<max(max(0, a), min(m, b)) { sung[k] = 1 }
        }
        var prefix = [0.0]
        for x in sung { prefix.append(prefix.last! + x) }   // sung is 0/1, so it's also the sum of squares

        /// Pearson correlation of `voice` against the lyrics at every offset.
        func correlate(_ voice: [Double]) -> [(o: Int, r: Double)]? {
            let vMean = voice.reduce(0, +) / Double(n)
            let vz = voice.map { $0 - vMean }
            let vVar = vz.reduce(0) { $0 + $1 * $1 }
            guard vVar > 1e-6 else { return nil }
            let on = (0..<n).filter { abs(vz[$0]) > 1e-12 }
            return (0...(hi - lo)).map { o in
                let s = prefix[o + n] - prefix[o]
                let lVar = s - s * s / Double(n)
                guard lVar > 1e-6 else { return (o, 0) }
                var dot = 0.0
                for k in on where sung[o + k] > 0 { dot += vz[k] }   // Σ vz·(sung − mean) = Σ vz·sung
                return (o, dot / sqrt(vVar * lVar))
            }
        }
        let plainScores = correlate(filled)
        guard let scores = plainScores ?? correlate(smooth),
              let best = scores.max(by: { $0.r < $1.r }) else { return nil }
        let away = scores.filter { abs($0.o - best.o) > Int(3 / dt) }.map(\.r).max() ?? -1
        // peaks nearly as good as the best, somewhere else in the song
        let w = Int(1 / dt)
        let rivals = scores.indices.filter { i in
            let x = scores[i]
            guard abs(x.o - best.o) > Int(3 / dt), x.r >= best.r - 0.05 else { return false }
            return scores[max(0, i - w)...min(scores.count - 1, i + w)].allSatisfy { $0.r <= x.r }
        }.map { Double(scores[$0].o + lo) * dt }
        let bestOffset = Double(best.o + lo) * dt
        let agree = rivals.allSatisfy { sameWords(lines, bestOffset, $0, seconds: recordingSeconds) }
        // the second reading must land in the same place (or on a rival that shows the same words)
        var confirmed = false
        if plainScores != nil, let other = correlate(smooth), let ob = other.max(by: { $0.r < $1.r }) {
            let o2 = Double(ob.o + lo) * dt
            confirmed = abs(o2 - bestOffset) <= 1 || (agree && rivals.contains { abs($0 - o2) <= 1 })
        }
        return Alignment(offset: bestOffset, score: best.r, margin: best.r - away, rivalsAgree: agree, confirmed: confirmed)
    }

    // MARK: lining up by the words that are sung

    struct WordAlignment {
        /// Seconds into the full track where the recording starts.
        var offset: Double
        /// Heard words that land on the same word of the lyrics at this offset.
        var matched: Int
        /// Words heard (fillers like "oh" and "yeah" left out).
        var heard: Int
        /// Weighted votes for this offset, and for the best offset more than 3 s away.
        var score: Double
        var runnerUp: Double
        /// Every offset that did nearly as well shows the same words at the same moments (a repeated chorus).
        var rivalsAgree: Bool
        var fraction: Double { heard > 0 ? Double(matched) / Double(heard) : 0 }
        /// The best place has to stand out from anywhere else. When most of what was heard is in the
        /// lyrics there, a smaller lead is enough: a second verse that shares most of its words with
        /// the first still loses on the words that differ.
        var trustworthy: Bool {
            guard matched >= 4, fraction >= 0.25 else { return false }
            if rivalsAgree || score >= runnerUp * 1.4 { return true }
            return matched >= 15 && fraction >= 0.6 && score >= runnerUp * 1.2
        }
        /// Plenty of words were heard but almost none are in these lyrics: they're for another song
        /// (or a different version), so showing them would be wrong.
        var mismatch: Bool { heard >= 12 && fraction < 0.12 }
    }

    /// A word reduced to letters and digits, so "Don't," and "dont" match.
    static func wordKey<S: StringProtocol>(_ s: S) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static let fillers: Set<String> = ["oh", "ooh", "ah", "aah", "yeah", "la", "na", "hey", "mm", "mmm", "whoa", "woah", "uh", "huh", "ha", "ay", "eh", "ooo", "oooh"]
    private static let common: Set<String> = ["the", "a", "an", "and", "i", "you", "to", "it", "in", "of", "me", "my", "is", "on", "be",
                                              "that", "so", "for", "we", "your", "im", "its", "dont", "but", "all", "with", "this", "at",
                                              "are", "was", "just", "like", "now", "what", "when", "can", "do", "no", "if", "up", "out",
                                              "el", "de", "que", "y", "en", "un", "una", "le", "les", "et", "je", "tu", "die", "der", "und"]

    /// Finds where in the full track the recording starts from the words the speech recogniser
    /// heard: each heard word votes for every offset that puts it on the same word in the lyrics,
    /// rarer words count for more, and the winner is refined on the words that start lines (whose
    /// times the LRC file gives exactly).
    static func alignWords(_ lines: [TimedLyric], heard: [HeardWord], recordingSeconds: Double,
                           range: ClosedRange<Double>) -> WordAlignment? {
        // the lyrics' words, each at about the time it's sung
        var lw: [(t: Double, w: String, first: Bool)] = []
        var counts: [String: Int] = [:]
        for i in lines.indices where !lines[i].text.isEmpty {
            let ws = lines[i].text.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { wordKey($0) }.filter { !$0.isEmpty }
            guard !ws.isEmpty else { continue }
            let len = singingLength(lines, i)
            for (j, w) in ws.enumerated() {
                lw.append((lines[i].time + len * (Double(j) + 0.3) / Double(ws.count), w, j == 0))
                counts[w, default: 0] += 1
            }
        }
        let hw = heard.map { (t: $0.time, w: wordKey($0.text)) }.filter { !$0.w.isEmpty && !fillers.contains($0.w) }
        guard lw.count >= 4, hw.count >= 3, range.upperBound >= range.lowerBound else { return nil }
        let byWord = Dictionary(grouping: lw.indices, by: { lw[$0].w })
        func weight(_ w: String) -> Double { (common.contains(w) ? 0.35 : 1) / sqrt(Double(counts[w] ?? 1)) }

        let dt = 0.1, tol = 1.6
        let lo = range.lowerBound
        let nBins = Int(((range.upperBound - lo) / dt).rounded(.up)) + 1
        var score = [Double](repeating: 0, count: nBins)
        var stamp = [Int](repeating: -1, count: nBins)
        for (k, h) in hw.enumerated() {
            guard let idx = byWord[h.w] else { continue }
            let wgt = weight(h.w)
            for i in idx {
                let o = lw[i].t - h.t
                let a = max(0, Int(((o - tol - lo) / dt).rounded(.up))), b = min(nBins - 1, Int(((o + tol - lo) / dt).rounded(.down)))
                guard a <= b else { continue }
                for j in a...b where stamp[j] != k { stamp[j] = k; score[j] += wgt }   // each heard word votes once per offset
            }
        }
        guard let bestBin = score.indices.max(by: { score[$0] < score[$1] }), score[bestBin] > 0 else {
            return WordAlignment(offset: 0, matched: 0, heard: hw.count, score: 0, runnerUp: 0, rivalsAgree: false)
        }
        // the middle of the best plateau
        var a = bestBin, b = bestBin
        while a > 0 && score[a - 1] >= score[bestBin] - 1e-9 { a -= 1 }
        while b < nBins - 1 && score[b + 1] >= score[bestBin] - 1e-9 { b += 1 }
        var offset = lo + Double(a + b) / 2 * dt

        // refine on the matched words; line starts are exact in the LRC, other words are estimates
        func matches(at o: Double) -> [(h: Double, l: Double, first: Bool)] {
            hw.compactMap { h in
                guard let idx = byWord[h.w],
                      let near = idx.min(by: { abs(lw[$0].t - (h.t + o)) < abs(lw[$1].t - (h.t + o)) }) else { return nil }
                return abs(lw[near].t - (h.t + o)) <= tol ? (h.t, lw[near].t, lw[near].first) : nil
            }
        }
        let firsts = matches(at: offset).filter(\.first).map { $0.l - $0.h }.sorted()
        if firsts.count >= 3 { offset = min(range.upperBound, max(lo, firsts[firsts.count / 2])) }
        let matched = matches(at: offset).count

        let bestScore = score[bestBin]
        let away = Int(3 / dt)
        let runnerUp = score.indices.filter { abs($0 - bestBin) > away }.map { score[$0] }.max() ?? 0
        // local peaks elsewhere that nearly tie: fine if they'd show the same words
        let w = Int(1 / dt)
        let rivals = score.indices.filter { i in
            guard abs(i - bestBin) > away, score[i] >= bestScore * 0.9 else { return false }
            return score[max(0, i - w)...min(nBins - 1, i + w)].allSatisfy { $0 <= score[i] }
        }.map { lo + Double($0) * dt }
        let agree = !rivals.isEmpty && rivals.allSatisfy { sameWords(lines, offset, $0, seconds: recordingSeconds) }
        return WordAlignment(offset: offset, matched: matched, heard: hw.count, score: bestScore, runnerUp: runnerUp, rivalsAgree: agree)
    }

    /// Whether the recording starting at `a` or at `b` in the track would show the same words at
    /// (nearly) the same moments.
    static func sameWords(_ lines: [TimedLyric], _ a: Double, _ b: Double, seconds: Double) -> Bool {
        func window(_ o: Double) -> [(t: Double, text: String)] {
            lines.filter { !$0.text.isEmpty && $0.time >= o - 1 && $0.time < o + seconds - 1 }.map { ($0.time - o, normalise($0.text)) }
        }
        let x = window(a), y = window(b)
        guard !x.isEmpty else { return y.isEmpty }
        let same = x.filter { l in y.contains { abs($0.t - l.t) < 1.2 && $0.text == l.text } }.count
        return Double(same) >= 0.75 * Double(max(x.count, y.count))
    }

    /// Lines placed on the song's beats. `offset` is where the recording starts in the full track.
    /// When a short preview's chords were repeated (`extended`), the lines heard in it repeat with them.
    static func place(_ lines: [TimedLyric], offset: Double, transcription t: Transcription, song s: Song,
                      extended: Bool) -> [LyricLine]? {
        guard t.beatTimes.count >= 2, !lines.isEmpty else { return nil }
        let length = s.totalBeats
        func beat(_ sec: Double) -> Double { MelodyExtractor.beatPosition(sec - offset, beatTimes: t.beatTimes) - t.songZeroBeat }
        let heardBeats = beat(offset + t.duration)
        let tile = extended && heardBeats < length - 1
        let period = tile ? Transcriber.repeatPeriod(s, heardBeats: heardBeats) : length
        var placed: [LyricLine] = []
        for i in lines.indices {
            let a = beat(lines[i].time)
            let b = beat(lines[i].time + singingLength(lines, i))
            let next = i + 1 < lines.count ? beat(lines[i + 1].time) : .infinity
            // a line already being sung when the song starts shows from the start
            if a < 0 {
                if next > 0.5 && b > 0.25 { placed.append(LyricLine(start: 0, beats: b, text: lines[i].text)) }
                continue
            }
            guard a < period else { break }
            placed.append(LyricLine(start: (a * 100).rounded() / 100, beats: max(0.25, ((b - a) * 100).rounded() / 100), text: lines[i].text))
        }
        if tile, !placed.isEmpty {
            // the preview's lines, again and again with its chords; the last one ends where the loop does
            var once = placed
            once[once.count - 1].beats = min(once[once.count - 1].beats, period - once[once.count - 1].start)
            placed = []
            var k = 0.0
            while k < length {
                placed += once.compactMap { l in
                    let st = l.start + k
                    return st < length ? LyricLine(start: st, beats: min(l.beats, length - st), text: l.text) : nil
                }
                k += period
            }
        }
        // two lines on the same spot: keep the later one
        var out: [LyricLine] = []
        for l in placed {
            if let last = out.last, abs(last.start - l.start) < 0.01 { out[out.count - 1] = l } else { out.append(l) }
        }
        return out.filter { !$0.text.isEmpty }.count >= 2 ? out : nil
    }

    /// Index of the line being sung (or just sung) at `beat`; nil before the first line.
    static func current(_ lines: [LyricLine], at beat: Double) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid].start <= beat { lo = mid + 1 } else { hi = mid } }
        return lo == 0 ? nil : lo - 1
    }
}
