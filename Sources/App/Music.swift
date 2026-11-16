import Foundation

enum Theory {
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    /// Standard tuning, low E to high e, as MIDI notes.
    static let openStrings = [40, 45, 50, 55, 59, 64]
    static let stringNames = ["E", "A", "D", "G", "B", "e"]

    static func name(_ pc: Int, flat: Bool = false) -> String {
        let i = ((pc % 12) + 12) % 12
        return flat ? flatNames[i] : sharpNames[i]
    }

    static func pitchClass(of note: String) -> Int? {
        guard let first = note.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first).uppercased()] else { return nil }
        var pc = base
        for c in note.dropFirst() {
            if c == "#" || c == "♯" { pc += 1 } else if c == "b" || c == "♭" { pc -= 1 } else { break }
        }
        return (pc + 12) % 12
    }

    static func frequency(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    static func midi(frequency f: Double) -> Double { 69 + 12 * log2(f / 440) }
}

enum ChordQuality: String, CaseIterable, Codable {
    case major, minor, power, dom7, maj7, min7, sus2, sus4, add9, six, sevenSus4, dom9, sixNine, m7b5, dim, dim7, aug

    var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .power: return [0, 7]
        case .dom7: return [0, 4, 7, 10]
        case .maj7: return [0, 4, 7, 11]
        case .min7: return [0, 3, 7, 10]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .add9: return [0, 4, 7, 2]
        case .six: return [0, 4, 7, 9]
        case .sevenSus4: return [0, 5, 7, 10]
        case .dom9: return [0, 4, 7, 10, 2]
        case .sixNine: return [0, 4, 7, 9, 2]
        case .m7b5: return [0, 3, 6, 10]
        case .dim: return [0, 3, 6]
        case .dim7: return [0, 3, 6, 9]
        case .aug: return [0, 4, 8]
        }
    }

    /// Accepted suffixes. First is canonical.
    var suffixes: [String] {
        switch self {
        case .major: return ["", "maj", "M"]
        case .minor: return ["m", "min", "-"]
        case .power: return ["5"]
        case .dom7: return ["7"]
        case .maj7: return ["maj7", "M7", "Δ7", "Δ"]
        case .min7: return ["m7", "min7", "-7"]
        case .sus2: return ["sus2"]
        case .sus4: return ["sus4", "sus"]
        case .add9: return ["add9", "add2"]
        case .six: return ["6"]
        case .sevenSus4: return ["7sus4", "7sus"]
        case .dom9: return ["9"]
        case .sixNine: return ["6/9", "69"]
        case .m7b5: return ["m7b5", "ø", "ø7"]
        case .dim: return ["dim", "°"]
        case .dim7: return ["dim7", "°7"]
        case .aug: return ["aug", "+"]
        }
    }

    var longName: String {
        switch self {
        case .major: return "major"
        case .minor: return "minor"
        case .power: return "power chord"
        case .dom7: return "dominant 7th"
        case .maj7: return "major 7th"
        case .min7: return "minor 7th"
        case .sus2: return "suspended 2nd"
        case .sus4: return "suspended 4th"
        case .add9: return "add 9"
        case .six: return "major 6th"
        case .sevenSus4: return "7th suspended 4th"
        case .dom9: return "dominant 9th"
        case .sixNine: return "6/9"
        case .m7b5: return "half-diminished"
        case .dim: return "diminished"
        case .dim7: return "diminished 7th"
        case .aug: return "augmented"
        }
    }

    var intervalNames: [String] {
        let map = [0: "R", 2: "9", 3: "♭3", 4: "3", 5: "4", 6: "♭5", 7: "5", 8: "♯5", 9: "6", 10: "♭7", 11: "7"]
        return intervals.map { map[$0] ?? "?" }
    }

    /// 1 = simple, 2 = colour/7ths, 3 = advanced harmony.
    var tier: Int {
        switch self {
        case .major, .minor, .power: return 1
        case .dom7, .maj7, .min7, .sus2, .sus4, .add9, .sevenSus4: return 2
        case .six, .dom9, .sixNine, .m7b5, .dim, .dim7, .aug: return 3
        }
    }

    /// Small prior used when guessing freely: simpler chords win close calls.
    var detectionPenalty: Float {
        switch tier {
        case 1: return 0
        case 2: return 0.05
        default: return 0.075
        }
    }

    var category: ChordCategory {
        switch self {
        case .major: return .major
        case .minor: return .minor
        case .power: return .power
        case .dom7, .dom9: return .seventh
        case .maj7, .six, .sixNine: return .maj7
        case .min7, .m7b5: return .min7
        case .sus2, .sus4, .add9, .sevenSus4: return .susAdd
        case .dim, .dim7, .aug: return .dimAug
        }
    }
}

enum ChordCategory: String, CaseIterable, Identifiable {
    case major = "Major", minor = "Minor", seventh = "7th & 9th", maj7 = "Maj7 & 6th", min7 = "Minor 7th", susAdd = "Sus & Add", power = "Power", dimAug = "Dim & Aug"
    var id: String { rawValue }
}

struct ChordSymbol: Hashable {
    var root: Int
    var quality: ChordQuality
    var bass: Int?
    var flat: Bool

    static func parse(_ raw: String) -> ChordSymbol? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, "ABCDEFG".contains(first.uppercased()) else { return nil }
        var idx = s.index(after: s.startIndex)
        var flat = false
        if idx < s.endIndex, s[idx] == "#" || s[idx] == "b" || s[idx] == "♯" || s[idx] == "♭" {
            flat = s[idx] == "b" || s[idx] == "♭"
            idx = s.index(after: idx)
        }
        guard let root = Theory.pitchClass(of: String(s[s.startIndex..<idx])) else { return nil }
        var rest = String(s[idx...])
        var bass: Int? = nil
        if let slash = rest.lastIndex(of: "/"), !rest.hasSuffix("6/9") {
            let b = String(rest[rest.index(after: slash)...])
            bass = Theory.pitchClass(of: b)
            if bass == nil { return nil }
            rest = String(rest[..<slash])
        }
        for q in ChordQuality.allCases where q.suffixes.contains(rest) {
            return ChordSymbol(root: root, quality: q, bass: bass, flat: flat)
        }
        return nil
    }

    var pitchClasses: [Int] { quality.intervals.map { (root + $0) % 12 } }
    var noteNames: [String] { pitchClasses.map { Theory.name($0, flat: flat) } }
    var rootName: String { Theory.name(root, flat: flat) }
    var displayName: String {
        var n = rootName + quality.suffixes[0]
        if let bass { n += "/" + Theory.name(bass, flat: flat) }
        return n
    }
    var longName: String {
        var n = "\(rootName) \(quality.longName)"
        if let bass { n += " over \(Theory.name(bass, flat: flat))" }
        return n
    }
    /// Matching key ignoring the bass note.
    var key: String { "\(root)-\(quality.rawValue)" }
}

struct ChordShape: Identifiable, Hashable {
    var name: String
    /// Low E → high e. -1 = muted, 0 = open.
    var frets: [Int]
    var fingers: [Int]
    var barre: Int? = nil
    var id: String { name }

    var symbol: ChordSymbol? { ChordSymbol.parse(name) }

    var baseFret: Int {
        let fretted = frets.filter { $0 > 0 }
        guard let maxF = fretted.max(), let minF = fretted.min() else { return 1 }
        return maxF > 4 ? minF : 1
    }

    var span: Int {
        let fretted = frets.filter { $0 > 0 }
        guard let a = fretted.min(), let b = fretted.max() else { return 0 }
        return b - a + 1
    }

    var midiNotes: [Int] {
        frets.enumerated().compactMap { i, f in f < 0 ? nil : Theory.openStrings[i] + f }
    }

    var level: Int {
        let q = symbol?.quality.tier ?? 2
        var lvl = q
        if barre != nil { lvl = max(lvl, 3) }
        if span >= 4 { lvl = min(3, lvl + 1) }
        if q == 1 && barre == nil && frets.filter({ $0 > 0 }).count <= 3 { lvl = 1 }
        return lvl
    }

    var levelName: String { ["Beginner", "Intermediate", "Advanced"][max(0, min(2, level - 1))] }

    var tips: String {
        if barre != nil {
            return "Roll your index finger slightly onto its bony edge for the barre and keep your thumb low behind the neck. Press just behind the fret wire."
        }
        if frets.first == -1 && frets.dropFirst().first == -1 {
            return "Strum only the top four strings — start your strum from the D string."
        }
        if frets.first == -1 {
            return "Skip the low E string. Start your strum from the A string."
        }
        if symbol?.quality == .power {
            return "Mute the other strings with the underside of your fingers. Great with distortion and down-picking."
        }
        return "Arch your fingers so open strings ring clearly. Use your fingertips, close to the fret wire."
    }
}

enum ChordLibrary {
    static let shapes: [ChordShape] = [
        // Open majors
        ChordShape(name: "C", frets: [-1, 3, 2, 0, 1, 0], fingers: [0, 3, 2, 0, 1, 0]),
        ChordShape(name: "D", frets: [-1, -1, 0, 2, 3, 2], fingers: [0, 0, 0, 1, 3, 2]),
        ChordShape(name: "E", frets: [0, 2, 2, 1, 0, 0], fingers: [0, 2, 3, 1, 0, 0]),
        ChordShape(name: "G", frets: [3, 2, 0, 0, 0, 3], fingers: [2, 1, 0, 0, 0, 3]),
        ChordShape(name: "A", frets: [-1, 0, 2, 2, 2, 0], fingers: [0, 0, 1, 2, 3, 0]),
        // Barre majors
        ChordShape(name: "F", frets: [1, 3, 3, 2, 1, 1], fingers: [1, 3, 4, 2, 1, 1], barre: 1),
        ChordShape(name: "B", frets: [-1, 2, 4, 4, 4, 2], fingers: [0, 1, 2, 3, 4, 1], barre: 2),
        ChordShape(name: "Bb", frets: [-1, 1, 3, 3, 3, 1], fingers: [0, 1, 2, 3, 4, 1], barre: 1),
        ChordShape(name: "F#", frets: [2, 4, 4, 3, 2, 2], fingers: [1, 3, 4, 2, 1, 1], barre: 2),
        ChordShape(name: "Ab", frets: [4, 6, 6, 5, 4, 4], fingers: [1, 3, 4, 2, 1, 1], barre: 4),
        ChordShape(name: "Db", frets: [-1, 4, 6, 6, 6, 4], fingers: [0, 1, 2, 3, 4, 1], barre: 4),
        ChordShape(name: "Eb", frets: [-1, 6, 8, 8, 8, 6], fingers: [0, 1, 2, 3, 4, 1], barre: 6),
        // Minors
        ChordShape(name: "Am", frets: [-1, 0, 2, 2, 1, 0], fingers: [0, 0, 2, 3, 1, 0]),
        ChordShape(name: "Em", frets: [0, 2, 2, 0, 0, 0], fingers: [0, 2, 3, 0, 0, 0]),
        ChordShape(name: "Dm", frets: [-1, -1, 0, 2, 3, 1], fingers: [0, 0, 0, 2, 3, 1]),
        ChordShape(name: "Bm", frets: [-1, 2, 4, 4, 3, 2], fingers: [0, 1, 3, 4, 2, 1], barre: 2),
        ChordShape(name: "F#m", frets: [2, 4, 4, 2, 2, 2], fingers: [1, 3, 4, 1, 1, 1], barre: 2),
        ChordShape(name: "C#m", frets: [-1, 4, 6, 6, 5, 4], fingers: [0, 1, 3, 4, 2, 1], barre: 4),
        ChordShape(name: "Gm", frets: [3, 5, 5, 3, 3, 3], fingers: [1, 3, 4, 1, 1, 1], barre: 3),
        ChordShape(name: "Cm", frets: [-1, 3, 5, 5, 4, 3], fingers: [0, 1, 3, 4, 2, 1], barre: 3),
        ChordShape(name: "Fm", frets: [1, 3, 3, 1, 1, 1], fingers: [1, 3, 4, 1, 1, 1], barre: 1),
        ChordShape(name: "Bbm", frets: [-1, 1, 3, 3, 2, 1], fingers: [0, 1, 3, 4, 2, 1], barre: 1),
        ChordShape(name: "G#m", frets: [4, 6, 6, 4, 4, 4], fingers: [1, 3, 4, 1, 1, 1], barre: 4),
        ChordShape(name: "Ebm", frets: [-1, 6, 8, 8, 7, 6], fingers: [0, 1, 3, 4, 2, 1], barre: 6),
        // Dominant 7ths
        ChordShape(name: "A7", frets: [-1, 0, 2, 0, 2, 0], fingers: [0, 0, 2, 0, 3, 0]),
        ChordShape(name: "B7", frets: [-1, 2, 1, 2, 0, 2], fingers: [0, 2, 1, 3, 0, 4]),
        ChordShape(name: "C7", frets: [-1, 3, 2, 3, 1, 0], fingers: [0, 3, 2, 4, 1, 0]),
        ChordShape(name: "D7", frets: [-1, -1, 0, 2, 1, 2], fingers: [0, 0, 0, 2, 1, 3]),
        ChordShape(name: "E7", frets: [0, 2, 0, 1, 0, 0], fingers: [0, 2, 0, 1, 0, 0]),
        ChordShape(name: "G7", frets: [3, 2, 0, 0, 0, 1], fingers: [3, 2, 0, 0, 0, 1]),
        ChordShape(name: "F7", frets: [1, 3, 1, 2, 1, 1], fingers: [1, 3, 1, 2, 1, 1], barre: 1),
        ChordShape(name: "Bb7", frets: [-1, 1, 3, 1, 3, 1], fingers: [0, 1, 3, 1, 4, 1], barre: 1),
        ChordShape(name: "F#7", frets: [2, 4, 2, 3, 2, 2], fingers: [1, 3, 1, 2, 1, 1], barre: 2),
        ChordShape(name: "C#7", frets: [-1, 4, 6, 4, 6, 4], fingers: [0, 1, 3, 1, 4, 1], barre: 4),
        // Major 7ths & 6ths
        ChordShape(name: "Cmaj7", frets: [-1, 3, 2, 0, 0, 0], fingers: [0, 3, 2, 0, 0, 0]),
        ChordShape(name: "Dmaj7", frets: [-1, -1, 0, 2, 2, 2], fingers: [0, 0, 0, 1, 2, 3]),
        ChordShape(name: "Fmaj7", frets: [-1, -1, 3, 2, 1, 0], fingers: [0, 0, 3, 2, 1, 0]),
        ChordShape(name: "Gmaj7", frets: [3, 2, 0, 0, 0, 2], fingers: [3, 2, 0, 0, 0, 1]),
        ChordShape(name: "Amaj7", frets: [-1, 0, 2, 1, 2, 0], fingers: [0, 0, 2, 1, 3, 0]),
        ChordShape(name: "Emaj7", frets: [0, 2, 1, 1, 0, 0], fingers: [0, 3, 1, 2, 0, 0]),
        ChordShape(name: "Bbmaj7", frets: [-1, 1, 3, 2, 3, 1], fingers: [0, 1, 3, 2, 4, 1], barre: 1),
        ChordShape(name: "C6", frets: [-1, 3, 2, 2, 1, 0], fingers: [0, 4, 2, 3, 1, 0]),
        ChordShape(name: "A6", frets: [-1, 0, 2, 2, 2, 2], fingers: [0, 0, 1, 1, 1, 1]),
        ChordShape(name: "G6", frets: [3, 2, 0, 0, 0, 0], fingers: [2, 1, 0, 0, 0, 0]),
        ChordShape(name: "D6", frets: [-1, -1, 0, 2, 0, 2], fingers: [0, 0, 0, 2, 0, 3]),
        // Minor 7ths
        ChordShape(name: "Am7", frets: [-1, 0, 2, 0, 1, 0], fingers: [0, 0, 2, 0, 1, 0]),
        ChordShape(name: "Em7", frets: [0, 2, 2, 0, 3, 0], fingers: [0, 1, 2, 0, 3, 0]),
        ChordShape(name: "Dm7", frets: [-1, -1, 0, 2, 1, 1], fingers: [0, 0, 0, 2, 1, 1]),
        ChordShape(name: "Bm7", frets: [-1, 2, 4, 2, 3, 2], fingers: [0, 1, 3, 1, 2, 1], barre: 2),
        ChordShape(name: "F#m7", frets: [2, 4, 2, 2, 2, 2], fingers: [1, 3, 1, 1, 1, 1], barre: 2),
        ChordShape(name: "Gm7", frets: [3, 5, 3, 3, 3, 3], fingers: [1, 3, 1, 1, 1, 1], barre: 3),
        ChordShape(name: "Cm7", frets: [-1, 3, 5, 3, 4, 3], fingers: [0, 1, 3, 1, 2, 1], barre: 3),
        ChordShape(name: "C#m7", frets: [-1, 4, 6, 4, 5, 4], fingers: [0, 1, 3, 1, 2, 1], barre: 4),
        ChordShape(name: "Bm7b5", frets: [-1, 2, 3, 2, 3, -1], fingers: [0, 1, 3, 2, 4, 0]),
        // Sus & add
        ChordShape(name: "Dsus2", frets: [-1, -1, 0, 2, 3, 0], fingers: [0, 0, 0, 1, 3, 0]),
        ChordShape(name: "Dsus4", frets: [-1, -1, 0, 2, 3, 3], fingers: [0, 0, 0, 1, 3, 4]),
        ChordShape(name: "Asus2", frets: [-1, 0, 2, 2, 0, 0], fingers: [0, 0, 1, 2, 0, 0]),
        ChordShape(name: "Asus4", frets: [-1, 0, 2, 2, 3, 0], fingers: [0, 0, 1, 2, 3, 0]),
        ChordShape(name: "Esus4", frets: [0, 2, 2, 2, 0, 0], fingers: [0, 2, 3, 4, 0, 0]),
        ChordShape(name: "Csus2", frets: [-1, 3, 0, 0, 3, 3], fingers: [0, 2, 0, 0, 3, 4]),
        ChordShape(name: "Csus4", frets: [-1, 3, 3, 0, 1, 1], fingers: [0, 3, 4, 0, 1, 1]),
        ChordShape(name: "Gsus4", frets: [3, -1, 0, 0, 1, 3], fingers: [2, 0, 0, 0, 1, 3]),
        ChordShape(name: "A7sus4", frets: [-1, 0, 2, 0, 3, 0], fingers: [0, 0, 2, 0, 3, 0]),
        ChordShape(name: "E7sus4", frets: [0, 2, 0, 2, 0, 0], fingers: [0, 2, 0, 3, 0, 0]),
        ChordShape(name: "Cadd9", frets: [-1, 3, 2, 0, 3, 3], fingers: [0, 2, 1, 0, 3, 4]),
        ChordShape(name: "Gadd9", frets: [3, 2, 0, 2, 0, 3], fingers: [2, 1, 0, 3, 0, 4]),
        ChordShape(name: "Eadd9", frets: [0, 2, 4, 1, 0, 0], fingers: [0, 2, 4, 1, 0, 0]),
        ChordShape(name: "Aadd9", frets: [-1, 0, 2, 4, 2, 0], fingers: [0, 0, 1, 4, 2, 0]),
        // 9ths & jazz colours
        ChordShape(name: "E9", frets: [0, 2, 0, 1, 3, 2], fingers: [0, 2, 0, 1, 4, 3]),
        ChordShape(name: "C9", frets: [-1, 3, 2, 3, 3, -1], fingers: [0, 2, 1, 3, 4, 0]),
        ChordShape(name: "A9", frets: [-1, 0, 2, 4, 2, 3], fingers: [0, 0, 1, 3, 1, 2]),
        ChordShape(name: "D6/9", frets: [-1, 5, 4, 4, 5, 5], fingers: [0, 2, 1, 1, 3, 4], barre: 4),
        // Diminished & augmented
        ChordShape(name: "Bdim", frets: [-1, 2, 3, 4, 3, -1], fingers: [0, 1, 2, 4, 3, 0]),
        ChordShape(name: "Cdim7", frets: [-1, 3, 4, 2, 4, -1], fingers: [0, 2, 3, 1, 4, 0]),
        ChordShape(name: "Bdim7", frets: [-1, 2, 3, 1, 3, -1], fingers: [0, 2, 3, 1, 4, 0]),
        ChordShape(name: "Caug", frets: [-1, 3, 2, 1, 1, 0], fingers: [0, 4, 3, 1, 1, 0]),
        ChordShape(name: "Eaug", frets: [0, 3, 2, 1, 1, 0], fingers: [0, 4, 3, 1, 1, 0]),
        // Slash chords
        ChordShape(name: "D/F#", frets: [2, -1, 0, 2, 3, 2], fingers: [1, 0, 0, 2, 4, 3]),
        ChordShape(name: "G/B", frets: [-1, 2, 0, 0, 3, 3], fingers: [0, 1, 0, 0, 3, 4]),
        ChordShape(name: "C/G", frets: [3, 3, 2, 0, 1, 0], fingers: [3, 4, 2, 0, 1, 0]),
        // Power chords
        ChordShape(name: "E5", frets: [0, 2, 2, -1, -1, -1], fingers: [0, 1, 2, 0, 0, 0]),
        ChordShape(name: "A5", frets: [-1, 0, 2, 2, -1, -1], fingers: [0, 0, 1, 2, 0, 0]),
        ChordShape(name: "D5", frets: [-1, -1, 0, 2, 3, -1], fingers: [0, 0, 0, 1, 3, 0]),
        ChordShape(name: "G5", frets: [3, 5, 5, -1, -1, -1], fingers: [1, 3, 4, 0, 0, 0]),
        ChordShape(name: "C5", frets: [-1, 3, 5, 5, -1, -1], fingers: [0, 1, 3, 4, 0, 0]),
        ChordShape(name: "F5", frets: [1, 3, 3, -1, -1, -1], fingers: [1, 3, 4, 0, 0, 0]),
        ChordShape(name: "B5", frets: [-1, 2, 4, 4, -1, -1], fingers: [0, 1, 3, 4, 0, 0]),
        ChordShape(name: "Bb5", frets: [-1, 1, 3, 3, -1, -1], fingers: [0, 1, 3, 4, 0, 0]),
        ChordShape(name: "F#5", frets: [2, 4, 4, -1, -1, -1], fingers: [1, 3, 4, 0, 0, 0]),
        ChordShape(name: "Ab5", frets: [4, 6, 6, -1, -1, -1], fingers: [1, 3, 4, 0, 0, 0]),
        ChordShape(name: "Db5", frets: [-1, 4, 6, 6, -1, -1], fingers: [0, 1, 3, 4, 0, 0]),
    ]

    private static let byName: [String: ChordShape] = Dictionary(shapes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    private static let byKey: [String: ChordShape] = {
        var d: [String: ChordShape] = [:]
        for s in shapes { if let sym = s.symbol, sym.bass == nil, d[sym.key] == nil { d[sym.key] = s } }
        return d
    }()

    /// Finds a shape for any spelling: "A#" → Bb, "D/F#" → slash shape or plain D.
    static func shape(for name: String) -> ChordShape? {
        if let s = byName[name] { return s }
        guard let sym = ChordSymbol.parse(name) else { return nil }
        if let s = byName[sym.displayName] { return s }
        return byKey[sym.key]
    }

    /// 1...3 difficulty for any chord name.
    static func level(of name: String) -> Int {
        if let s = shape(for: name) {
            var l = s.level
            if ChordSymbol.parse(name)?.bass != nil, byName[name] == nil { l = min(3, l + 1) }
            return l
        }
        return min(3, (ChordSymbol.parse(name)?.quality.tier ?? 2) + 1)
    }

    static let decks: [(id: String, name: String, icon: String, level: Int, chords: [String])] = [
        ("first", "First Chords", "leaf.fill", 1, ["Em", "Am", "E", "A", "D", "G", "C", "Dm"]),
        ("power", "Power Chords", "bolt.fill", 1, ["E5", "A5", "D5", "G5", "C5", "F5", "B5"]),
        ("sevenths", "Sevenths", "7.circle.fill", 2, ["A7", "B7", "C7", "D7", "E7", "G7"]),
        ("color", "Colour Chords", "paintpalette.fill", 2, ["Cmaj7", "Fmaj7", "Am7", "Em7", "Dm7", "Dsus2", "Dsus4", "Asus2", "Asus4", "Cadd9"]),
        ("barre", "Barre Chords", "hand.raised.fill", 3, ["F", "Bm", "B", "F#m", "C#m", "Bb", "Gm", "Cm"]),
        ("jazz", "Jazz & Advanced", "music.note", 3, ["Bm7b5", "E9", "C9", "Cdim7", "Caug", "C6", "Bm7", "F#m7", "Gm7", "D6/9"]),
    ]
}

// MARK: - Notes, transposition, voicings & transition tips

extension Theory {
    static let stringLabels = ["low E", "A", "D", "G", "B", "high e"]

    /// "E3", "F#2", "Bb3" → MIDI number.
    static func midi(noteName s: String) -> Int? {
        guard let first = s.first, "ABCDEFG".contains(first.uppercased()) else { return nil }
        var i = s.index(after: s.startIndex)
        if i < s.endIndex, s[i] == "#" || s[i] == "b" { i = s.index(after: i) }
        guard let pc = pitchClass(of: String(s[..<i])), let oct = Int(s[i...]) else { return nil }
        return (oct + 1) * 12 + pc
    }

    static func noteName(midi m: Int, flat: Bool = false) -> String { name(m % 12, flat: flat) + "\(m / 12 - 1)" }

    /// Easiest place to fret a single note in standard tuning.
    static func position(midi m: Int) -> (string: Int, fret: Int)? {
        let options = openStrings.enumerated().compactMap { s, open -> (Int, Int)? in
            let f = m - open
            return (0...15).contains(f) ? (s, f) : nil
        }
        return options.min { a, b in
            let pa = a.1 > 7 ? 100 + a.1 : a.1, pb = b.1 > 7 ? 100 + b.1 : b.1
            return pa == pb ? a.0 > b.0 : pa < pb
        }
    }

    static let flatKeys: Set<Int> = [5, 10, 3, 8, 1]
}

extension ChordSymbol {
    func transposed(by semis: Int, preferFlat: Bool? = nil) -> ChordSymbol {
        var s = self
        s.root = ((root + semis) % 12 + 12) % 12
        if let b = bass { s.bass = ((b + semis) % 12 + 12) % 12 }
        s.flat = preferFlat ?? flat
        return s
    }
}

extension ChordLibrary {
    /// Simplified shapes for players who aren't ready for full barre chords.
    static let easyShapes: [String: ChordShape] = {
        let list = [
            ChordShape(name: "F", frets: [-1, -1, 3, 2, 1, 1], fingers: [0, 0, 3, 2, 1, 1], barre: 1),
            ChordShape(name: "Bm", frets: [-1, -1, 4, 4, 3, 2], fingers: [0, 0, 3, 4, 2, 1]),
            ChordShape(name: "B", frets: [-1, -1, 4, 4, 4, 2], fingers: [0, 0, 2, 3, 4, 1]),
            ChordShape(name: "F#m", frets: [-1, -1, 4, 2, 2, 2], fingers: [0, 0, 3, 1, 1, 1], barre: 2),
            ChordShape(name: "F#", frets: [-1, -1, 4, 3, 2, 2], fingers: [0, 0, 3, 2, 1, 1], barre: 2),
            ChordShape(name: "C#m", frets: [-1, -1, 2, 1, 2, 0], fingers: [0, 0, 2, 1, 3, 0]),
            ChordShape(name: "Bb", frets: [-1, -1, 3, 3, 3, 1], fingers: [0, 0, 2, 3, 4, 1]),
            ChordShape(name: "Gm", frets: [-1, -1, 0, 3, 3, 3], fingers: [0, 0, 0, 2, 3, 4]),
            ChordShape(name: "Fm", frets: [-1, -1, 3, 1, 1, 1], fingers: [0, 0, 3, 1, 1, 1], barre: 1),
            ChordShape(name: "Eb", frets: [-1, -1, 1, 3, 4, 3], fingers: [0, 0, 1, 2, 4, 3]),
            ChordShape(name: "G", frets: [-1, -1, 0, 0, 0, 3], fingers: [0, 0, 0, 0, 0, 3]),
            ChordShape(name: "Bm7", frets: [-1, 2, 0, 2, 0, 2], fingers: [0, 1, 0, 2, 0, 3]),
            ChordShape(name: "F#m7", frets: [-1, -1, 2, 2, 2, 2], fingers: [0, 0, 1, 1, 1, 1], barre: 2),
        ]
        return Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    static var preferEasy = false

    static func easyShape(for name: String) -> ChordShape? {
        if let e = easyShapes[name] { return e }
        guard let sym = ChordSymbol.parse(name), sym.bass == nil else { return nil }
        return easyShapes.values.first { $0.symbol?.key == sym.key }
    }

    /// The shape the app should draw, honouring "prefer easy shapes" and falling back to a generated voicing.
    static func displayShape(for name: String) -> ChordShape? {
        if preferEasy, let e = easyShape(for: name) { return e }
        if let s = shape(for: name) { return s }
        return generated(for: name).first
    }

    static func voicings(for name: String) -> [(label: String, shape: ChordShape)] {
        var out: [(String, ChordShape)] = []
        if let s = shape(for: name) { out.append(("Standard", s)) }
        if let e = easyShape(for: name), !out.contains(where: { $0.1.frets == e.frets }) { out.append(("Easy", e)) }
        var alt = 1
        for g in generated(for: name) where !out.contains(where: { $0.1.frets == g.frets }) && out.count < 5 {
            out.append((out.isEmpty ? "Standard" : "Alt \(alt)", g))
            if !out.isEmpty && out.count > 1 { alt += 1 }
        }
        return out
    }

    private static var generatedCache: [String: [ChordShape]] = [:]
    private static let cacheLock = NSLock()

    /// Searches the fretboard for playable voicings of any chord symbol.
    static func generated(for name: String) -> [ChordShape] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = generatedCache[name] { return c }
        guard let sym = ChordSymbol.parse(name) else { generatedCache[name] = []; return [] }
        let tones = Set(sym.pitchClasses)
        var required = tones
        if sym.quality.intervals.count >= 4 { required.remove((sym.root + 7) % 12) }
        let bassPC = sym.bass ?? sym.root
        var found: [(Double, ChordShape)] = []
        var seen = Set<[Int]>()

        for base in 1...9 {
            let window = base...(base + 3)
            let options: [[Int]] = Theory.openStrings.map { open in
                var o = [-1]
                if tones.contains(open % 12) { o.append(0) }
                for f in window where tones.contains((open + f) % 12) { o.append(f) }
                return o
            }
            var combo = [Int](repeating: -1, count: 6)
            func rec(_ s: Int) {
                if s == 6 { evaluate(combo); return }
                for f in options[s] { combo[s] = f; rec(s + 1) }
            }
            func evaluate(_ frets: [Int]) {
                let sounding = (0..<6).filter { frets[$0] >= 0 }
                guard sounding.count >= min(4, max(3, tones.count)), let lo = sounding.first, let hi = sounding.last else { return }
                // no muted strings in the middle of the chord
                if (lo...hi).contains(where: { frets[$0] < 0 }) { return }
                if (Theory.openStrings[lo] + frets[lo]) % 12 != bassPC { return }
                let pcs = Set(sounding.map { (Theory.openStrings[$0] + frets[$0]) % 12 })
                guard required.isSubset(of: pcs) else { return }
                let fretted = sounding.filter { frets[$0] > 0 }
                let minF = fretted.map { frets[$0] }.min() ?? 0
                let maxF = fretted.map { frets[$0] }.max() ?? 0
                if maxF - minF > 3 { return }
                var barre = false
                var fingers = fretted.count
                if fingers > 4 {
                    let atMin = fretted.filter { frets[$0] == minF }
                    guard atMin.count >= 2, let a = atMin.first, let z = atMin.last,
                          (a...z).allSatisfy({ frets[$0] >= minF }) else { return }
                    barre = true
                    fingers = 1 + fretted.filter { frets[$0] > minF }.count
                    if fingers > 4 { return }
                }
                guard !seen.contains(frets) else { return }
                seen.insert(frets)
                let opens = sounding.filter { frets[$0] == 0 }.count
                let score = Double(maxF - minF) * 0.8 + Double(minF) * 0.35 + Double(fingers) * 0.5
                    + Double(6 - sounding.count) * 0.5 + (barre ? 1.4 : 0) - Double(opens) * 0.25
                found.append((score, makeShape(name: name, frets: frets, barre: barre ? minF : nil)))
            }
            rec(0)
        }
        let result = found.sorted { $0.0 < $1.0 }.prefix(4).map(\.1)
        generatedCache[name] = Array(result)
        return Array(result)
    }

    private static func makeShape(name: String, frets: [Int], barre: Int?) -> ChordShape {
        var fingers = [Int](repeating: 0, count: 6)
        var next = 1
        if let b = barre {
            for s in 0..<6 where frets[s] == b { fingers[s] = 1 }
            next = 2
        }
        let rest = (0..<6).filter { frets[$0] > 0 && fingers[$0] == 0 }.sorted { frets[$0] == frets[$1] ? $0 < $1 : frets[$0] < frets[$1] }
        for s in rest { fingers[s] = min(4, next); next += 1 }
        return ChordShape(name: name, frets: frets, fingers: fingers, barre: barre)
    }

    /// A practical tip for moving between two chord shapes.
    static func transitionTip(from a: String, to b: String) -> String? {
        guard a != b, let sa = displayShape(for: a), let sb = displayShape(for: b) else { return nil }
        let anchors = (0..<6).filter { sa.frets[$0] > 0 && sa.frets[$0] == sb.frets[$0] && sa.fingers[$0] > 0 && sa.fingers[$0] == sb.fingers[$0] }
        if !anchors.isEmpty {
            let parts = anchors.prefix(2).map { "finger \(sa.fingers[$0]) on the \(Theory.stringLabels[$0]) string (fret \(sa.frets[$0]))" }
            return "Anchor: keep \(parts.joined(separator: " and ")) pressed down — move only the others."
        }
        for s in 0..<6 where sa.fingers[s] > 0 && sa.fingers[s] == sb.fingers[s] && sa.frets[s] > 0 && sb.frets[s] > 0 {
            return "Guide finger: slide finger \(sa.fingers[s]) along the \(Theory.stringLabels[s]) string from fret \(sa.frets[s]) to \(sb.frets[s]) without lifting it."
        }
        let sharedStrings = (0..<6).filter { sa.frets[$0] > 0 && sb.frets[$0] > 0 }
        if sharedStrings.count >= 3 {
            let deltas = Set(sharedStrings.map { sb.frets[$0] - sa.frets[$0] })
            if deltas.count == 1, let d = deltas.first, d != 0, sa.fingers == sb.fingers {
                return "Same shape: keep your hand locked and slide it \(abs(d)) fret\(abs(d) == 1 ? "" : "s") \(d > 0 ? "towards the body" : "towards the headstock")."
            }
        }
        if let low = (0..<6).first(where: { sb.frets[$0] >= 0 }), sb.frets[low] > 0, sb.fingers[low] > 0 {
            return "Lead with the bass: land finger \(sb.fingers[low]) on the \(Theory.stringLabels[low]) string (fret \(sb.frets[low])) first — it's the note you strum first."
        }
        return "Start moving on the last '&' of the bar — it's fine if the last strum rings open."
    }
}
