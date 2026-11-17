import Foundation

// MARK: - Strumming

enum StrumStroke: Character {
    case down = "D", up = "U", rest = "-", mute = "x"
    var isStrum: Bool { self != .rest }
}

struct StrumPattern: Identifiable, Hashable {
    var id: String
    var name: String
    /// One character per slot across one bar: D, U, - (rest), x (muted chuck).
    var pattern: String
    var beatsPerBar: Int = 4
    var level: Int
    var feel: String
    var tip: String

    var strokes: [StrumStroke] { pattern.compactMap { StrumStroke(rawValue: $0) } }
    var slotsPerBeat: Int { max(1, strokes.count / max(1, beatsPerBar)) }
    var subdivisionName: String {
        switch slotsPerBeat {
        case 1: return "Quarter notes"
        case 2: return "Eighth notes"
        case 3: return "Triplets / swing"
        default: return "Sixteenth notes"
        }
    }
    /// Counting syllables for each slot.
    var counts: [String] {
        let per = slotsPerBeat
        let subs: [String]
        switch per {
        case 1: subs = [""]
        case 2: subs = ["", "&"]
        case 3: subs = ["", "&", "a"]
        default: subs = ["", "e", "&", "a"]
        }
        var out: [String] = []
        for b in 0..<beatsPerBar { for s in 0..<per { out.append(s == 0 ? "\(b + 1)" : subs[s]) } }
        return out
    }

    static let library: [StrumPattern] = [
        StrumPattern(id: "downs", name: "Steady Downs", pattern: "D-D-D-D-", level: 1, feel: "Solid & simple",
                     tip: "One down-strum per beat. Keep your wrist loose and count out loud: 1, 2, 3, 4."),
        StrumPattern(id: "eighths", name: "Down-Up Eighths", pattern: "DUDUDUDU", level: 1, feel: "Driving",
                     tip: "Your hand moves down on the numbers and up on the '&'. Never stop the pendulum."),
        StrumPattern(id: "campfire", name: "Campfire Classic", pattern: "D-DU-UDU", level: 2, feel: "Folk / pop",
                     tip: "The most useful strum in the world. Keep the hand moving on the rests — just miss the strings."),
        StrumPattern(id: "pop", name: "Pop Push", pattern: "D-DUDUDU", level: 2, feel: "Upbeat pop",
                     tip: "Accent beat 1, then let the eighths roll. Lighten the up-strums."),
        StrumPattern(id: "ballad", name: "Slow Ballad", pattern: "D---D-DU", level: 1, feel: "Spacious",
                     tip: "Let the first strum ring for two beats. Great for slow, emotional songs."),
        StrumPattern(id: "rockchuck", name: "Rock Chuck", pattern: "D-xUDUxU", level: 3, feel: "Percussive",
                     tip: "On the 'x', relax your fretting hand so the strings go dead — a snare-like chuck on 2 and 4."),
        StrumPattern(id: "reggae", name: "Island Offbeat", pattern: "-U-U-U-U", level: 2, feel: "Reggae skank",
                     tip: "Only strum the '&'s with short, choppy up-strokes. Release pressure right after each one."),
        StrumPattern(id: "power", name: "Power Eighths", pattern: "DDDDDDDD", level: 1, feel: "Punk / rock",
                     tip: "All down-strokes, palm resting lightly near the bridge for that chunky sound."),
        StrumPattern(id: "syncopated", name: "Syncopated Groove", pattern: "D-DU-UD-", level: 3, feel: "Funky pop",
                     tip: "The skipped down-strum on beat 3 creates the push. Count every '&' in your head."),
        StrumPattern(id: "waltz", name: "Waltz", pattern: "D-DUDU", beatsPerBar: 3, level: 2, feel: "3/4 time",
                     tip: "Three beats per bar: strong 1, lighter 2 and 3. ONE-two-three, ONE-two-three."),
        StrumPattern(id: "shuffle", name: "Blues Shuffle", pattern: "D-UD-UD-UD-U", level: 3, feel: "Swing",
                     tip: "Long-short, long-short. Each beat is split into three — strum the first and the last."),
        StrumPattern(id: "funk16", name: "16th Funk", pattern: "DUDUxUDUDUDUxUDU", level: 4, feel: "Funk",
                     tip: "Fast 16ths from the wrist, chucks on 2 and 4. Stay relaxed — tension kills groove."),
        StrumPattern(id: "travis", name: "Gallop", pattern: "D-DUD-DUD-DUD-DU", level: 4, feel: "Rock gallop",
                     tip: "Down, down-up repeated on each beat. Think horse hooves."),
    ]

    static func match(_ raw: String, beatsPerBar: Int) -> StrumPattern {
        if let p = library.first(where: { $0.pattern == raw }) { return p }
        return StrumPattern(id: "custom-\(raw)", name: "Song Pattern", pattern: raw, beatsPerBar: beatsPerBar, level: 2,
                            feel: "Custom", tip: "Follow the arrows. Keep your strumming hand moving even on rests.")
    }
}

// MARK: - Songs

extension KeyedDecodingContainer {
    /// Decode a value if it's present and valid, otherwise use the default — so older or newer saves never fail to load.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

struct SongSection: Codable, Hashable, Identifiable {
    var name: String
    var chords: String
    var repeats: Int = 1
    /// Optional strum pattern for just this section.
    var strum: String? = nil
    var id: String { name + chords + "\(repeats)" + (strum ?? "") }

    /// Parsed tokens. "G:2" = 2 beats, "~E3:1.5" = a single note. Default length is one bar.
    func tokens(beatsPerBar: Int) -> [(chord: String, beats: Double)] {
        chords.split(whereSeparator: { $0 == " " || $0 == "|" || $0 == "," }).compactMap { t in
            let parts = t.split(separator: ":")
            let name = String(parts[0])
            guard !name.isEmpty else { return nil }
            let beats = parts.count > 1 ? (Double(parts[1]) ?? Double(beatsPerBar)) : Double(beatsPerBar)
            return (name, max(0.25, beats))
        }
    }
}

extension SongSection {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "Part")
        chords = c.v(.chords, "")
        repeats = c.v(.repeats, 1)
        strum = c.v(.strum, nil)
    }
}

struct ChordEvent: Hashable, Identifiable {
    var id: Int
    var chord: String
    var start: Double
    var beats: Double
    var section: String
    var sectionIndex: Int
    var bar: Int
    var strum: String
    var end: Double { start + beats }
    var isNote: Bool { chord.hasPrefix("~") }
    /// Single notes are "~G4", optionally with where to play them: "~G4@B8" (B string, fret 8).
    private var noteParts: (name: String, pos: String?) {
        let body = chord.dropFirst()
        guard let at = body.firstIndex(of: "@") else { return (String(body), nil) }
        return (String(body[..<at]), String(body[body.index(after: at)...]))
    }
    var noteMidi: Int? { isNote ? Theory.midi(noteName: noteParts.name) : nil }
    /// Where to fret the note: the song's own position if it gives one, otherwise the easiest spot.
    var notePosition: (string: Int, fret: Int)? {
        guard let m = noteMidi else { return nil }
        if let p = noteParts.pos, let first = p.first, let s = Theory.stringNames.firstIndex(of: String(first)), let f = Int(p.dropFirst()) {
            return (s, f)
        }
        return Theory.position(midi: m)
    }
    var label: String { isNote ? noteParts.name : chord }
}

func formatBeats(_ b: Double) -> String {
    b == b.rounded() ? "\(Int(b))" : String(format: "%g", b)
}

struct Song: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var genre: String
    var bpm: Int
    var beatsPerBar: Int = 4
    var capo: Int = 0
    var strum: String = "D-DU-UDU"
    var sections: [SongSection]
    var isCustom: Bool = false
    var note: String? = nil
    /// How the backing guitar plays it: "strum", "boomchick", "picked", "power" or "reggae". nil = work it out.
    var feel: String? = nil
    /// The tune, worked out from the recording (searched songs). Plays along with the chords.
    var melody: [MelodyNote]? = nil

    static let feelNames: [(String, String)] = [("strum", "Strummed"), ("boomchick", "Bass note + strum"), ("picked", "Fingerpicked"),
                                                ("power", "Power chords"), ("reggae", "Reggae chops")]
    var feelName: String { Self.feelNames.first { $0.0 == playFeel }?.1 ?? "Strummed" }

    /// The playing feel, from the song's own setting or its genre, chords and pattern.
    var playFeel: String {
        if let f = feel { return f }
        let chords = uniqueChords
        if !chords.isEmpty && chords.allSatisfy({ $0.hasSuffix("5") }) { return "power" }
        if strum.hasPrefix("-U-U") || genre == "Reggae" { return "reggae" }
        if genre == "Country" || genre == "Traditional" { return "boomchick" }
        return "strum"
    }

    var events: [ChordEvent] {
        var out: [ChordEvent] = []
        var beat = 0.0
        var i = 0
        for (si, sec) in sections.enumerated() {
            let toks = sec.tokens(beatsPerBar: beatsPerBar)
            for r in 0..<max(1, sec.repeats) {
                for t in toks {
                    out.append(ChordEvent(id: i, chord: t.chord, start: beat, beats: t.beats,
                                          section: sec.repeats > 1 ? "\(sec.name) · \(r + 1)/\(sec.repeats)" : sec.name,
                                          sectionIndex: si, bar: Int(beat) / beatsPerBar, strum: sec.strum ?? strum))
                    beat += t.beats
                    i += 1
                }
            }
        }
        return out
    }

    var totalBeats: Double { events.last?.end ?? 0 }
    var duration: Double { totalBeats * 60 / Double(bpm) }
    var durationText: String {
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var allTokens: [String] { sections.flatMap { $0.tokens(beatsPerBar: beatsPerBar).map(\.chord) } }

    var uniqueChords: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in allTokens where !c.hasPrefix("~") && !seen.contains(c) { seen.insert(c); out.append(c) }
        return out
    }
    var hasRiff: Bool { allTokens.contains { $0.hasPrefix("~") } }
    var uniqueNotes: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in allTokens where c.hasPrefix("~") && !seen.contains(c) { seen.insert(c); out.append(String(c.dropFirst().prefix { $0 != "@" })) }
        return out
    }

    var strumPattern: StrumPattern { StrumPattern.match(strum, beatsPerBar: beatsPerBar) }
    func strumPattern(for e: ChordEvent?) -> StrumPattern { StrumPattern.match(e?.strum ?? strum, beatsPerBar: beatsPerBar) }
    var sectionStrums: [String] {
        var seen = Set<String>(); var out: [String] = []
        for p in [strum] + sections.compactMap(\.strum) where !seen.contains(p) { seen.insert(p); out.append(p) }
        return out
    }

    var changesPerMinute: Double {
        let ev = events
        guard ev.count > 1, duration > 0 else { return 0 }
        var changes = 0
        for i in 1..<ev.count where ev[i].chord != ev[i - 1].chord { changes += 1 }
        return Double(changes) / (duration / 60)
    }

    /// Auto-rated difficulty 1...5 from chord complexity, change speed and rhythm.
    var difficulty: Int {
        let levels = uniqueChords.map { Double(ChordLibrary.level(of: $0)) }
        if levels.isEmpty {
            // single-note riffs: rate by note speed
            return max(1, min(5, 1 + Int((changesPerMinute / 60).rounded())))
        }
        let maxL = levels.max() ?? 1
        let avg = levels.reduce(0, +) / Double(levels.count)
        var score = (maxL - 1) * 1.0 + (avg - 1) * 0.8
        score += min(1.2, max(0, changesPerMinute - 10) / 30)
        if levels.count > 5 { score += 0.3 }
        let slots = sectionStrums.map { $0.count / max(1, beatsPerBar) }.max() ?? 2
        if slots >= 4 { score += 0.6 } else if slots == 3 { score += 0.3 }
        if hasRiff { score += 0.4 }
        return max(1, min(5, 1 + Int(score.rounded())))
    }

    /// Best guess at the home key, from the chord that gets the most time (or the one that starts and ends the song).
    var key: String? {
        let ev = events.filter { !$0.isNote }
        guard let first = ev.first, let last = ev.last else { return nil }
        var weight: [String: Double] = [:]
        for e in ev { weight[e.chord, default: 0] += e.beats }
        let tonic = first.chord == last.chord ? first.chord : (weight.max { $0.value < $1.value }?.key ?? first.chord)
        guard let sym = ChordSymbol.parse(tonic) else { return nil }
        let minor = [.minor, .min7, .m7b5].contains(sym.quality)
        return sym.rootName + (minor ? " minor" : " major")
    }

    /// Shift every chord and note by `semis` semitones.
    func transposed(by semis: Int) -> Song {
        guard semis % 12 != 0 else { return self }
        var s = self
        let firstRoot = ChordSymbol.parse(uniqueChords.first ?? "C")?.root ?? 0
        let flat = Theory.flatKeys.contains(((firstRoot + semis) % 12 + 12) % 12)
        s.sections = sections.map { sec in
            var out = sec
            out.chords = sec.tokens(beatsPerBar: beatsPerBar).map { t in
                var name = t.chord
                if name.hasPrefix("~"), let m = Theory.midi(noteName: String(name.dropFirst().prefix { $0 != "@" })) {
                    name = "~" + Theory.noteName(midi: m + semis, flat: flat)
                } else if let sym = ChordSymbol.parse(name) {
                    name = sym.transposed(by: semis, preferFlat: flat).displayName
                }
                return Double(beatsPerBar) == t.beats ? name : name + ":" + formatBeats(t.beats)
            }.joined(separator: " ")
            return out
        }
        s.melody = melody?.map { var n = $0; n.midi += semis; return n }
        return s
    }

    func matches(_ q: String) -> Bool {
        let query = q.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        let l = query.lowercased()
        if title.lowercased().contains(l) || artist.lowercased().contains(l) || genre.lowercased().contains(l) { return true }
        if l == "riff" || l == "riffs" { return hasRiff }
        // chord search, e.g. "Am" or "Am G"
        let parts = query.split(separator: " ").map(String.init)
        let chordSet = Set(uniqueChords.map { $0.lowercased() })
        if parts.allSatisfy({ ChordSymbol.parse($0) != nil }) {
            return parts.allSatisfy { chordSet.contains($0.lowercased()) }
        }
        return false
    }
}

extension Song {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "custom-\(UUID().uuidString.prefix(8))")
        title = c.v(.title, "Untitled")
        artist = c.v(.artist, "Me")
        genre = c.v(.genre, "Custom")
        bpm = max(30, c.v(.bpm, 90))
        beatsPerBar = c.v(.beatsPerBar, 4)
        capo = c.v(.capo, 0)
        strum = c.v(.strum, "D-DU-UDU")
        sections = c.v(.sections, [])
        isCustom = c.v(.isCustom, true)
        note = c.v(.note, nil)
        feel = c.v(.feel, nil)
        melody = c.v(.melody, nil)
    }
}

enum SongCatalog {
    private static func s(_ title: String, _ artist: String, _ genre: String, bpm: Int, beats: Int = 4, capo: Int = 0,
                          strum: String = "D-DU-UDU", note: String? = nil, _ sections: [(String, String, Int)],
                          sectionStrums: [String: String] = [:]) -> Song {
        let slug = (title + "-" + artist).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let n = note ?? (artist == lessons ? nil : "Simplified arrangement — chords only. Spot something off? Use Edit a Copy.")
        return Song(id: slug, title: title, artist: artist, genre: genre, bpm: bpm, beatsPerBar: beats, capo: capo,
                    strum: strum, sections: sections.map { SongSection(name: $0.0, chords: $0.1, repeats: $0.2, strum: sectionStrums[$0.0]) },
                    note: n, feel: feels[title])
    }

    /// How each song's guitar part is usually played, so "Hear the Chords" sounds like the record.
    private static let feels: [String: String] = [
        // fingerpicked / arpeggiated
        "Hallelujah": "picked", "Hotel California": "picked", "House of the Rising Sun": "picked",
        "Sweet Home Alabama": "picked", "Hey There Delilah": "picked", "Someone Like You": "picked",
        "Fast Car": "picked", "Every Breath You Take": "picked", "Jolene": "picked",
        "Can't Help Falling in Love": "picked", "Tennessee Whiskey": "picked", "Hurt": "picked",
        "Wish You Were Here": "strum", "Dust in the Wind": "picked",
        // bass note + strum
        "Leaving on a Jet Plane": "boomchick", "Ring of Fire": "boomchick", "Country Roads": "boomchick",
        "Wagon Wheel": "boomchick", "Blowin' in the Wind": "boomchick", "Bad Moon Rising": "boomchick",
        "Amazing Grace": "boomchick", "Happy Birthday": "boomchick", "Waltz in G": "boomchick",
        // distorted, palm-muted rock
        "Seven Nation Army (Power)": "power", "Smells Like Teen Spirit": "power", "Sweet Child (Rhythm)": "power",
        "Back in Black (Rhythm)": "power", "Smoke on the Water (Power)": "power", "Power Chord Drive": "power",
        // off-beat chops
        "Three Little Birds": "reggae", "Island Groove": "reggae",
        // strummed even though the genre suggests otherwise
        "Hey Joe": "strum", "Jolene (Strum)": "strum"
    ]

    static let lessons = "Don’t Fret Lessons"

    static let songs: [Song] = [
        // ——— Lessons / exercises ———
        s("First Steps: Em to Am", lessons, "Exercise", bpm: 66, strum: "D-D-D-D-", [("Warm-up", "Em Em Am Am", 4)]),
        s("Two-Chord Rock", lessons, "Exercise", bpm: 80, strum: "D-D-D-D-", [("Groove", "E E A A", 3), ("Turn", "E A E E", 1)]),
        s("Campfire Trio", lessons, "Exercise", bpm: 80, [("Verse", "G C D G", 3), ("Ending", "C D G G", 1)]),
        s("Minor Mood", lessons, "Exercise", bpm: 76, strum: "D---D-DU", [("A", "Am Dm E Am", 2), ("B", "Dm Am E E", 2)]),
        s("Sevenths Workout", lessons, "Exercise", bpm: 84, [("A", "A7 D7 E7 A7", 2), ("B", "E7 A7 B7 E7", 2), ("C", "G7 C7 D7 G7", 1)]),
        s("12-Bar Blues in A", lessons, "Blues", bpm: 92, strum: "D-UD-UD-UD-U",
          [("12 Bars", "A7 A7 A7 A7 D7 D7 A7 A7 E7 D7 A7 E7", 3)]),
        s("12-Bar Blues in E", lessons, "Blues", bpm: 96, strum: "D-UD-UD-UD-U",
          [("12 Bars", "E7 E7 E7 E7 A7 A7 E7 E7 B7 A7 E7 B7", 3)]),
        s("Power Chord Drive", lessons, "Exercise", bpm: 112, strum: "DDDDDDDD",
          [("Riff", "E5 E5 G5 A5", 2), ("Lift", "C5 D5 E5 E5", 2)]),
        s("Barre Bootcamp", lessons, "Exercise", bpm: 66, strum: "D---D-DU",
          [("E-Shape", "F F F#m F#m G G Gm Gm", 1), ("A-Shape", "Bm Bm B B C#m C#m Bb Bb", 1)]),
        s("Colour Chords", lessons, "Exercise", bpm: 72, strum: "D---D-DU",
          [("Dreamy", "Cmaj7 Fmaj7 Am7 Em7", 2), ("Bridge", "Dm7 G7 Cmaj7 Cmaj7", 1)]),
        s("Sus Shimmer", lessons, "Exercise", bpm: 82, [("D", "D Dsus4 D Dsus2", 2), ("A", "A Asus4 A Asus2", 2)]),
        s("Jazz Corner: ii–V–I", lessons, "Exercise", bpm: 100, strum: "D-D-D-D-",
          [("Major", "Dm7 G7 Cmaj7 Cmaj7", 2), ("Minor", "Bm7b5 E7 Am7 Am7", 2)]),
        s("Diminished Passing Tones", lessons, "Exercise", bpm: 88, strum: "D-D-D-D-",
          [("A", "C Cdim7 Dm7 G7", 2), ("B", "C Caug C6 C9", 2)]),
        s("Neo-Soul Ninths", lessons, "Exercise", bpm: 78, strum: "D-xUDUxU",
          [("Loop", "Fmaj7 E9 Am7 C6", 3), ("Turn", "Dm7 E9 Am7 Am7", 1)]),
        s("16th Funk Lab", lessons, "Exercise", bpm: 92, strum: "DUDUxUDUDUDUxUDU",
          [("Groove", "E9 E9 A9 A9", 3)]),

        // ——— Songs (simplified arrangements: chords only) ———
        s("Knockin' on Heaven's Door", "Bob Dylan", "Rock", bpm: 69, [("Verse", "G D Am Am", 2), ("Chorus", "G D C C", 2)]),
        s("Let It Be", "The Beatles", "Pop", bpm: 72, strum: "D-D-DUDU", [("Verse", "C G Am F", 1), ("Verse", "C G F C", 1), ("Chorus", "Am G F C", 1), ("Chorus", "C G F C", 1)],
          sectionStrums: ["Chorus": "DUDUDUDU"]),
        s("Stand By Me", "Ben E. King", "Soul", bpm: 118, [("Verse", "G G Em Em C D G G", 2)]),
        s("Wonderwall", "Oasis", "Rock", bpm: 87, capo: 2, strum: "DUDUDUDU",
          [("Verse", "Em7 G Dsus4 A7sus4", 4), ("Pre-Chorus", "C D Em7 Em7", 2), ("Chorus", "C Em7 G Em7", 2)],
          sectionStrums: ["Pre-Chorus": "D-D-D-D-"]),
        s("Riptide", "Vance Joy", "Indie", bpm: 102, [("Verse", "Am G C C", 4), ("Chorus", "Am G C F", 2)]),
        s("Hallelujah", "Leonard Cohen", "Folk", bpm: 56, beats: 3, strum: "D-DUDU",
          [("Verse", "C Am C Am F G C G", 1), ("Verse", "C F G Am F G E Am", 1), ("Chorus", "F Am F C G C", 1)]),
        s("Brown Eyed Girl", "Van Morrison", "Rock", bpm: 150, [("Verse", "G C G D", 4), ("Chorus", "C D G Em C D G D", 1)]),
        s("Free Fallin'", "Tom Petty", "Rock", bpm: 84, capo: 3, strum: "DUDUDUDU",
          [("Verse", "D:2 Dsus4:2 D:2 A:2", 4)]),
        s("Sweet Home Alabama", "Lynyrd Skynyrd", "Rock", bpm: 98, [("Riff", "D:4 C:2 G:2", 6)]),
        s("Wish You Were Here", "Pink Floyd", "Rock", bpm: 60, strum: "D-DU-UDU",
          [("Verse", "C D Am G", 1), ("Verse", "D C Am G", 1), ("Intro", "Em G Em G Em A Em A G", 1)]),
        s("Hotel California", "Eagles", "Rock", bpm: 74, strum: "D-DU-UDU",
          [("Verse", "Bm F# A E G D Em F#", 2), ("Chorus", "G D F# Bm G D Em F#", 1)]),
        s("House of the Rising Sun", "Traditional", "Traditional", bpm: 117, beats: 3, strum: "D-DUDU",
          [("Verse", "Am C D F Am C E E", 1), ("Verse", "Am C D F Am E Am E", 2)]),
        s("Leaving on a Jet Plane", "John Denver", "Folk", bpm: 100, [("Verse", "G C G C G C D D", 2), ("Chorus", "G C G C G Em D D", 1)]),
        s("Three Little Birds", "Bob Marley", "Reggae", bpm: 74, strum: "-U-U-U-U",
          [("Chorus", "A A D A A A D A", 1), ("Verse", "A E A D A E D A", 1)]),
        s("Zombie", "The Cranberries", "Rock", bpm: 84, strum: "D-DUDUDU", [("Verse", "Em C G D/F#", 4)]),
        s("Perfect", "Ed Sheeran", "Pop", bpm: 63, beats: 3, capo: 1, strum: "D-DUDU",
          [("Verse", "G Em C D", 2), ("Pre", "Em C G D", 1), ("Chorus", "Em C G D Em C D D", 1)]),
        s("Country Roads", "John Denver", "Country", bpm: 82, [("Verse", "G Em D C", 2), ("Chorus", "G D Em C G D C G", 1)]),
        s("Hey Joe", "Jimi Hendrix", "Rock", bpm: 84, strum: "D-DUDUDU", [("Cycle", "C G D A E E", 3)]),
        s("Seven Nation Army (Power)", "The White Stripes", "Rock", bpm: 124, strum: "DDDDDDDD",
          [("Riff", "E5:6 G5:2 E5:4 D5:2 C5:2 B5:8", 2)]),
        s("Smells Like Teen Spirit", "Nirvana", "Grunge", bpm: 117, strum: "DDDDDDDD",
          [("Riff", "F5:2 Bb5:2 Ab5:2 Db5:2", 6)]),
        s("Creep", "Radiohead", "Indie", bpm: 92, strum: "D-DUDUDU", [("Verse", "G B C Cm", 4)]),
        s("Losing My Religion", "R.E.M.", "Rock", bpm: 125, strum: "DUDUDUDU",
          [("Intro", "F Dm G Am", 1), ("Verse", "Am Em Am Em Am Em Dm G", 2)]),
        s("Good Riddance", "Green Day", "Rock", bpm: 95, strum: "DUDUDUDU",
          [("Verse", "G G Cadd9 D", 4), ("Chorus", "Em D C G Em D C G", 1)],
          sectionStrums: ["Chorus": "D-DU-UDU"]),
        s("Hey There Delilah", "Plain White T's", "Pop", bpm: 104,
          [("Verse", "D F#m D F#m Bm A G A", 2), ("Chorus", "D Bm D Bm", 1)],
          sectionStrums: ["Chorus": "DUDUDUDU"]),
        s("I'm Yours", "Jason Mraz", "Pop", bpm: 151, strum: "D-xUDUxU", [("Verse", "G D Em C", 4)]),
        s("Someone Like You", "Adele", "Pop", bpm: 67, strum: "DUDUDUDU",
          [("Verse", "A E F#m D", 4), ("Chorus", "A E F#m D A E F#m D", 1)]),
        s("Blowin' in the Wind", "Bob Dylan", "Folk", bpm: 88,
          [("Verse", "G C D G G C D D", 2), ("Chorus", "C D G Em C D G G", 1)]),
        s("Imagine", "John Lennon", "Pop", bpm: 75, strum: "D-D-DUDU",
          [("Verse", "C Cmaj7 F F", 4), ("Pre", "F Am Dm F G G G7 G7", 1)]),
        s("Fast Car", "Tracy Chapman", "Folk", bpm: 104, capo: 2, strum: "DUDUDUDU", [("Riff", "Cmaj7 G Em D", 6)]),
        s("Sweet Child (Rhythm)", "Guns N' Roses", "Rock", bpm: 125, strum: "D-DUDUDU",
          [("Verse", "D D C C G G D D", 2), ("Chorus", "A A C C D D D D", 1)]),
        s("Back in Black (Rhythm)", "AC/DC", "Rock", bpm: 94, strum: "D-D-D-D-", [("Riff", "E5:2 D5:1 A5:5", 6)]),
        s("Twist and Shout", "The Isley Brothers", "Rock", bpm: 126, [("Riff", "D:2 G:2 A:4", 8)]),
        s("La Bamba", "Ritchie Valens", "Rock", bpm: 150, strum: "DUDUDUDU", [("Riff", "C:2 F:2 G:4", 8)]),
        s("Bad Moon Rising", "Creedence Clearwater Revival", "Rock", bpm: 179,
          [("Verse", "D A:2 G:2 D D", 4), ("Chorus", "G G D D A G D D", 2)]),
        s("Every Breath You Take", "The Police", "Rock", bpm: 117, strum: "DUDUDUDU",
          [("Verse", "G G Em Em C D G G", 2), ("Bridge", "C C G G A A D D", 1)]),
        s("Have You Ever Seen the Rain", "Creedence Clearwater Revival", "Rock", bpm: 116,
          [("Verse", "C C G C", 2), ("Chorus", "F G C Am F G C C", 2)]),
        s("Ring of Fire", "Johnny Cash", "Country", bpm: 105, [("Verse", "G C G G G D G G", 2), ("Chorus", "D C G G D C G G", 1)]),
        s("Jolene", "Dolly Parton", "Country", bpm: 111, strum: "DUDUDUDU", [("Chorus", "Am C G Am G Em Am Am", 3)]),
        s("Wild Thing", "The Troggs", "Rock", bpm: 106, [("Riff", "A:2 D:2 E:2 D:2", 6)]),
        s("Johnny B. Goode (Rhythm)", "Chuck Berry", "Rock", bpm: 168, strum: "D-UD-UD-UD-U",
          [("12 Bars", "A A A A D D A A E D A A", 3)]),
        s("Amazing Grace", "Traditional", "Traditional", bpm: 80, beats: 3, strum: "D-DUDU",
          [("Verse", "G G7 C G G G D D", 1), ("Verse", "G G7 C G G D G G", 1)]),
        s("Happy Birthday", "Traditional", "Traditional", bpm: 100, beats: 3, strum: "D-DUDU",
          [("Song", "G D D G G C G:3 D:3 G G", 1)]),
        s("Wake Me Up", "Avicii", "Pop", bpm: 124, strum: "D-DUDUDU", [("Verse", "Bm G D A", 4)]),
        s("Counting Stars", "OneRepublic", "Pop", bpm: 122, capo: 4, strum: "D-DU-UD-", [("Loop", "Am C G F", 6)]),
        s("Shape of You", "Ed Sheeran", "Pop", bpm: 96, capo: 4, strum: "D-DU-UD-", [("Loop", "Am Dm F G", 6)]),
        s("Boulevard of Broken Dreams", "Green Day", "Rock", bpm: 83, strum: "D-DUDUDU",
          [("Verse", "Em G D A", 4), ("Chorus", "C G D Em C G D D", 1)],
          sectionStrums: ["Chorus": "DDDDDDDD"]),
        s("Viva la Vida", "Coldplay", "Pop", bpm: 138, capo: 1, strum: "D-DUDUDU", [("Loop", "C D G Em", 6)]),
        s("Chasing Cars", "Snow Patrol", "Indie", bpm: 104, strum: "DDDDDDDD", [("Verse", "A E D D", 4)]),
        s("Ain't No Sunshine", "Bill Withers", "Soul", bpm: 78, strum: "D---D-DU", [("Verse", "Am Em G Am", 4)]),
        s("Can't Help Falling in Love", "Elvis Presley", "Pop", bpm: 68, beats: 3, strum: "D-DUDU",
          [("Verse", "C Em Am Am F C G G", 1), ("Verse", "F G Am F C G C C", 1)]),
        s("Tennessee Whiskey", "Chris Stapleton", "Country", bpm: 50, strum: "D---D-DU", [("Groove", "A A Bm Bm", 4)]),
        s("Smoke on the Water (Power)", "Deep Purple", "Rock", bpm: 112, strum: "D-D-D-D-",
          [("Riff", "G5:3 Bb5:3 C5:2 G5:3 Bb5:2 Db5:1 C5:2", 4)]),
        s("Hurt", "Johnny Cash", "Country", bpm: 92, strum: "D---D-DU",
          [("Verse", "Am C D Am C D", 2), ("Chorus", "G Am F C G Am F G", 1)],
          sectionStrums: ["Chorus": "D-DUDUDU"]),
        s("Mad World", "Gary Jules", "Indie", bpm: 88, strum: "D---D-DU", [("Verse", "Em G D A", 4)]),
        s("Wonderful Tonight", "Eric Clapton", "Rock", bpm: 95, strum: "D-D-DUDU", [("Verse", "G D C D", 4)]),
        s("Wagon Wheel", "Old Crow Medicine Show", "Country", bpm: 145, [("Loop", "G D Em C G D C C", 4)]),
        s("Redemption-Style Folk Loop", lessons, "Folk", bpm: 90, [("Verse", "G Em C G/B Am D G G", 2)]),
        s("Island Groove", lessons, "Reggae", bpm: 80, strum: "-U-U-U-U", [("Loop", "C F G F", 4)]),
        s("Waltz in G", lessons, "Exercise", bpm: 90, beats: 3, strum: "D-DUDU", [("Verse", "G C D G Em C D G", 2)]),
        s("Funky Nine", lessons, "Exercise", bpm: 98, strum: "D-xUDUxU", [("Groove", "E9 E9 A9 E9", 4)]),
        s("Seven Nation Army (Riff)", "The White Stripes", "Rock", bpm: 124, strum: "D-D-D-D-",
          [("Riff", "~E3:1.5 ~E3:0.5 ~G3:0.75 ~E3:0.75 ~D3:0.5 ~C3:2 ~B2:2", 4)]),
        s("Smoke on the Water (Riff)", "Deep Purple", "Rock", bpm: 112, strum: "D-D-D-D-",
          [("Riff", "~G3:1 ~Bb3:1 ~C4:2 ~G3:1 ~Bb3:1 ~Db4:0.5 ~C4:2.5 ~G3:1 ~Bb3:1 ~C4:2 ~Bb3:1 ~G3:3", 2)]),
        s("Riff Lab: E Minor Pentatonic", lessons, "Exercise", bpm: 80, strum: "D-D-D-D-",
          [("Up", "~E2:1 ~G2:1 ~A2:1 ~B2:1 ~D3:1 ~E3:1 ~G3:1 ~A3:1", 2), ("Down", "~A3:1 ~G3:1 ~E3:1 ~D3:1 ~B2:1 ~A2:1 ~G2:1 ~E2:1", 2)]),
        s("Ode to Joy (Melody)", "Ludwig van Beethoven", "Traditional", bpm: 100, strum: "D-D-D-D-",
          [("Phrase A", "~E4:1 ~E4:1 ~F4:1 ~G4:1 ~G4:1 ~F4:1 ~E4:1 ~D4:1 ~C4:1 ~C4:1 ~D4:1 ~E4:1 ~E4:1.5 ~D4:0.5 ~D4:2", 2)]),
        s("Happy Birthday (Melody)", "Traditional", "Traditional", bpm: 110, beats: 3, strum: "D-DUDU",
          [("Melody", "~G3:0.75 ~G3:0.25 ~A3:1 ~G3:1 ~C4:1 ~B3:2 ~G3:0.75 ~G3:0.25 ~A3:1 ~G3:1 ~D4:1 ~C4:2 ~G3:0.75 ~G3:0.25 ~G4:1 ~E4:1 ~C4:1 ~B3:1 ~A3:2 ~F4:0.75 ~F4:0.25 ~E4:1 ~C4:1 ~D4:1 ~C4:2", 1)]),
        s("Slash Walkdown", lessons, "Exercise", bpm: 76, strum: "D---D-DU", [("Walk", "G D/F# Em C G/B Am D G", 2)]),
    ]

    static let genres: [String] = Array(Set(songs.map(\.genre))).sorted()
}
