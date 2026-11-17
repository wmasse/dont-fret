import Foundation

/// Turns what the listener heard into three playable versions of a song:
/// Beginner (open triads, capo for easy shapes, one strum per beat), Middle (common 7ths and sus
/// chords, the song's strum on an 8th-note grid) and Advanced (the fuller chords heard in the
/// recording — 7ths, sus, add9, power and slash chords — in the recorded key, with the recorded strum).
enum ChordArranger {
    enum Level: String, CaseIterable, Identifiable {
        case beginner = "Beginner", middle = "Middle", advanced = "Advanced"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .beginner: return "leaf.fill"
            case .middle: return "flame.fill"
            case .advanced: return "star.fill"
            }
        }
        var blurb: String {
            switch self {
            case .beginner: return "Open chords, capo for easy shapes, one strum per beat"
            case .middle: return "Adds the song's 7th and sus chords and its strum pattern"
            case .advanced: return "As close to the record as we can hear: full chords, slash bass, real strum"
            }
        }
    }

    // MARK: hearing the chord qualities

    /// Chroma levels around a triad, relative to the triad's own notes.
    struct Colour {
        var third: Float, second: Float, fourth: Float, flat7: Float, maj7: Float, sixth: Float
        var bassNote: Int, bassLead: Float
    }

    static func colour(root r: Int, minor: Bool, treble t: [Float], bass b: [Float]) -> Colour {
        func at(_ i: Int) -> Float { t[((r + i) % 12 + 12) % 12] }
        let third = at(minor ? 3 : 4)
        let ref = max(1e-4, (at(0) + at(7) + max(third, max(at(5), at(2)))) / 3)
        let bassNote = b.indices.max { b[$0] < b[$1] } ?? r
        let bassLead = b[bassNote] / max(1e-4, b[r])
        return Colour(third: third / ref, second: at(2) / ref, fourth: at(5) / ref, flat7: at(10) / ref, maj7: at(11) / ref,
                      sixth: at(9) / ref, bassNote: bassNote, bassLead: bassLead)
    }

    /// The fullest chord the recording supports for a heard triad. Conservative: an extra note has
    /// to be clearly present across the whole song, not just leak in from a melody.
    static func refine(root r: Int, minor: Bool, treble: [Float], bass: [Float]) -> ChordSymbol.Parts {
        let c = colour(root: r, minor: minor, treble: treble, bass: bass)
        var q: ChordQuality = minor ? .minor : .major
        let strongSus4 = c.fourth > 0.7 && c.third < 0.75 * c.fourth
        let strongSus2 = c.second > 0.85 && c.third < 0.5 * c.second
        if c.third < 0.32 && c.fourth < 0.45 && c.second < 0.45 {
            q = .power
        } else if strongSus4 {
            q = c.flat7 > 0.7 ? .sevenSus4 : .sus4
        } else if strongSus2 {
            q = .sus2
        } else if minor {
            if c.flat7 > 0.8 { q = .min7 }
        } else if c.flat7 > 0.72 && c.flat7 > c.maj7 * 1.4 {
            q = .dom7
        } else if c.maj7 > 0.72 && c.maj7 > c.flat7 * 1.4 {
            q = .maj7
        } else if c.second > 0.75 && c.third > 0.6 {
            q = .add9
        }
        // a bass note that isn't the root: an inversion or a walking bass (D/F#, G/B, C/G, Am/G)
        var bassNote: Int? = nil
        let rel = ((c.bassNote - r) % 12 + 12) % 12
        // (not the fifth: that's usually just an alternating bass)
        let allowed: Set<Int> = minor ? [3, 10] : [4, 10, 11, 2]
        if c.bassLead > 1.6 && allowed.contains(rel) && q != .power { bassNote = c.bassNote }
        return .init(root: r, quality: q, bass: bassNote)
    }

    /// Every heard triad (0–11 major, 12–23 minor) mapped to its fuller name, pooled over the whole song.
    static func fullerNames(_ t: Transcription) -> [Int: ChordSymbol.Parts] {
        guard !t.beatPath.isEmpty, t.beatPath.count == t.beatTreble.count, t.beatBass.count == t.beatTreble.count else { return [:] }
        var tre: [Int: [Float]] = [:], bas: [Int: [Float]] = [:], n: [Int: Int] = [:]
        for (i, c) in t.beatPath.enumerated() where i < t.beatRMS.count ? t.beatRMS[i] > 0 : true {
            tre[c, default: Array(repeating: 0, count: 12)] = zip(tre[c] ?? Array(repeating: 0, count: 12), t.beatTreble[i]).map(+)
            bas[c, default: Array(repeating: 0, count: 12)] = zip(bas[c] ?? Array(repeating: 0, count: 12), t.beatBass[i]).map(+)
            n[c, default: 0] += 1
        }
        var out: [Int: ChordSymbol.Parts] = [:]
        for (c, count) in n where count >= 4 {
            func norm(_ v: [Float]) -> [Float] { let m = v.max() ?? 1; return v.map { $0 / max(1e-6, m) } }
            out[c] = refine(root: c % 12, minor: c >= 12, treble: norm(tre[c]!), bass: norm(bas[c]!))
        }
        return out
    }

    // MARK: the three versions

    /// A transcription rewritten for one level. Chord names stay in the recording's key (the capo is applied when the song is built).
    static func arrange(_ t: Transcription, level: Level) -> Transcription {
        var out = t
        let flatKey = Theory.flatKeys.contains(t.minorKey ? (t.keyRoot + 3) % 12 : t.keyRoot)
        let fuller = fullerNames(t)
        // same spelling rule as the listener's own chord names
        func flatFor(_ pc: Int, minor: Bool) -> Bool { flatKey || pc == 10 || pc == 3 || (pc == 8 && !minor) }
        func rename(_ name: String) -> String {
            guard let sym = ChordSymbol.parse(name), [.major, .minor].contains(sym.quality), sym.bass == nil else { return name }
            let idx = sym.root + (sym.quality == .minor ? 12 : 0)
            guard let p = fuller[idx] else { return name }
            switch level {
            case .beginner:
                return name
            case .middle:
                // only the extra colours with friendly open shapes; no slash bass, no power chords
                guard [.dom7, .min7, .maj7, .sus2, .sus4, .add9].contains(p.quality) else { return name }
                return ChordSymbol(root: p.root, quality: p.quality, bass: nil, flat: flatFor(p.root, minor: sym.quality == .minor)).displayName
            case .advanced:
                return ChordSymbol(root: p.root, quality: p.quality, bass: p.bass, flat: flatFor(p.root, minor: sym.quality == .minor)).displayName
            }
        }
        func renameTokens(_ s: String) -> String {
            s.split(separator: " ").map { tok -> String in
                let parts = tok.split(separator: ":", maxSplits: 1)
                let n = rename(String(parts[0]))
                return parts.count > 1 ? n + ":" + parts[1] : n
            }.joined(separator: " ")
        }
        out.bars = t.bars.map { var b = $0; b.tokens = renameTokens(b.tokens); return b }
        out.sections = t.sections.map { var s = $0; s.chords = renameTokens(s.chords); return s }

        var chords = Set(out.sections.flatMap { $0.tokens(beatsPerBar: t.beatsPerBar).map(\.chord) })
        // a strum we barely heard (fewer strums than beats) isn't worth copying: use the everyday pattern
        let heard = t.strum.filter { $0 != "-" }.count >= t.beatsPerBar
        let everyday = t.beatsPerBar == 3 ? "D-DUDU" : "D-DU-UDU"
        switch level {
        case .beginner:
            out.capo = beginnerCapo(chords)
            out.strum = t.beatsPerBar == 3 ? "D-D-D-" : "D-D-D-D-"
            out.feel = "strum"
            // one simple strum for the whole song, whatever each part does on the record
            out.sections = out.sections.map { var s = $0; s.strum = nil; return s }
        case .middle:
            out.capo = beginnerCapo(chords)
            // keep a coloured chord only if it has a comfortable shape with that capo
            let keep = Set(chords.filter { name in
                guard let sym = ChordSymbol.parse(name) else { return false }
                if [.major, .minor].contains(sym.quality) { return true }
                let shape = sym.transposed(by: -out.capo, preferFlat: false).displayName
                return ChordLibrary.shape(for: shape) != nil && ChordLibrary.level(of: shape) <= 2
            })
            if keep.count < chords.count {
                func plain(_ s: String) -> String {
                    s.split(separator: " ").map { tok -> String in
                        let parts = tok.split(separator: ":", maxSplits: 1)
                        let n = String(parts[0])
                        guard !keep.contains(n), let sym = ChordSymbol.parse(n) else { return String(tok) }
                        let minor = [.minor, .min7].contains(sym.quality)
                        let base = ChordSymbol(root: sym.root, quality: minor ? .minor : .major, bass: nil, flat: sym.flat).displayName
                        return parts.count > 1 ? base + ":" + parts[1] : base
                    }.joined(separator: " ")
                }
                out.bars = out.bars.map { var b = $0; b.tokens = plain(b.tokens); return b }
                out.sections = out.sections.map { var s = $0; s.chords = plain(s.chords); return s }
                chords = Set(out.sections.flatMap { $0.tokens(beatsPerBar: t.beatsPerBar).map(\.chord) })
                out.capo = beginnerCapo(chords)
            }
            out.strum = heard ? eighths(t.strum) : everyday
            out.feel = t.feel
            // parts that are strummed differently keep their own pattern, on the same 8th-note grid
            out.sections = out.sections.map { var s = $0; s.strum = heard ? s.strum.map(eighths) : nil; return s }
        case .advanced:
            // the capo that turns the full chords into open shapes is most likely how the record was played
            out.capo = Transcriber.easiestCapo(chords)
            out.strum = heard ? t.strum : everyday
            if !heard { out.sections = out.sections.map { var s = $0; s.strum = nil; return s } }
            let powerShare = Double(chords.filter { $0.hasSuffix("5") }.count) / Double(max(1, chords.count))
            out.feel = powerShare >= 0.5 ? "power" : t.feel
        }
        return out
    }

    /// For beginners any capo that avoids barre chords is worth it.
    static func beginnerCapo(_ chords: Set<String>) -> Int {
        func cost(_ c: Int) -> Int {
            chords.reduce(0) { sum, name in
                guard let sym = ChordSymbol.parse(name) else { return sum }
                let shape = sym.transposed(by: -c, preferFlat: false).displayName
                let l = ChordLibrary.shape(for: shape) == nil ? 4 : ChordLibrary.level(of: shape)
                return sum + l * l
            }
        }
        var best = 0, bestCost = cost(0)
        for c in 1...7 where cost(c) < bestCost { best = c; bestCost = cost(c) }
        return best
    }

    /// A 16th-note pattern brought down to 8th notes (one character per half beat).
    static func eighths(_ p: String) -> String {
        let chars = Array(p)
        guard chars.count >= 12 else { return p }
        return String(stride(from: 0, to: chars.count, by: 2).map { i -> Character in
            // keep an up-strum heard on the "e" or "a" next to an empty 8th
            if chars[i] == "-" && i + 1 < chars.count && chars[i + 1] != "-" && i % 4 == 2 { return "U" }
            return chars[i] == "D" || chars[i] == "U" ? (i % 4 == 0 ? "D" : "U") : "-"
        })
    }
}

extension ChordSymbol {
    /// Root, quality and optional bass, before choosing sharps or flats.
    struct Parts: Hashable { var root: Int; var quality: ChordQuality; var bass: Int? }
}
