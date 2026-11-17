import Foundation
import SwiftUI

// MARK: - Model

/// One moment in a riff: a single note, a double stop / power chord, or a rest.
struct RiffNote: Hashable, Identifiable {
    struct Fret: Hashable { var string: Int; var fret: Int }
    var id: Int
    var start: Double
    var beats: Double
    var frets: [Fret]
    /// "" picked, "h" hammer-on, "p" pull-off, "/" slide in, "b" bend, "~" vibrato, "m" palm mute
    var tech: String
    var isRest: Bool { frets.isEmpty }
    var end: Double { start + beats }
    var midis: [Int] { frets.map { Theory.openStrings[$0.string] + $0.fret } }
}

struct Riff: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case riff = "Riffs", solo = "Solos", melody = "Melodies", exercise = "Exercises"
        var id: String { rawValue }
        var single: String { ["Riff", "Solo", "Melody", "Exercise"][Kind.allCases.firstIndex(of: self)!] }
        var icon: String { ["bolt.fill", "flame.fill", "music.note", "figure.strengthtraining.traditional"][Kind.allCases.firstIndex(of: self)!] }
    }
    var id: String
    var title: String
    var kind: Kind
    var style: String
    var level: Int
    var bpm: Int
    var meter = 4
    var swing = false
    /// Let notes ring into each other (fingerpicking, arpeggios).
    var ring = false
    var tone: GuitarSynth.Tone
    var about: String
    var tips: [String]
    var notes: [RiffNote]

    init(_ id: String, _ title: String, kind: Kind, style: String, level: Int, bpm: Int, meter: Int = 4, swing: Bool = false,
         ring: Bool = false, tone: GuitarSynth.Tone, unit: Double = 0.5, about: String, tips: [String], tab: String) {
        self.id = id; self.title = title; self.kind = kind; self.style = style; self.level = level; self.bpm = bpm
        self.meter = meter; self.swing = swing; self.ring = ring; self.tone = tone; self.about = about; self.tips = tips
        self.notes = Riff.parse(tab, unit: unit)
    }

    var totalBeats: Double { notes.last?.end ?? 0 }
    var bars: Int { Int((totalBeats / Double(meter)).rounded(.up)) }
    var duration: Double { totalBeats * 60 / Double(bpm) }
    var techniques: [String] {
        let names = ["h": "Hammer-ons", "p": "Pull-offs", "/": "Slides", "b": "Bends", "~": "Vibrato", "m": "Palm muting"]
        var seen = Set<String>(); var out: [String] = []
        for n in notes where !n.tech.isEmpty && !seen.contains(n.tech) { seen.insert(n.tech); if let v = names[n.tech] { out.append(v) } }
        if notes.contains(where: { $0.frets.count > 1 }) { out.append("Double stops") }
        return out
    }
    var frettedRange: ClosedRange<Int> {
        let f = notes.flatMap { $0.frets.map(\.fret) }.filter { $0 > 0 }
        return (f.min() ?? 0)...(f.max() ?? 0)
    }

    /// Where a beat really falls in time, in beats: swung eighths push every off-beat late.
    func swung(_ b: Double) -> Double {
        guard swing else { return b }
        let whole = b.rounded(.down), frac = b - whole
        return whole + (frac < 0.5 ? frac * 4 / 3 : 2.0 / 3 + (frac - 0.5) * 2 / 3)
    }

    /// Tab shorthand: `<string><fret><tech>[:beats][*repeat]`, strings E A D G B e,
    /// `+` joins notes played together, `r` is a rest, `|` is just for reading.
    static func parse(_ tab: String, unit: Double) -> [RiffNote] {
        var out: [RiffNote] = []
        var t = 0.0
        for raw in tab.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "|" }) {
            var tok = String(raw)
            var times = 1
            if let star = tok.firstIndex(of: "*") { times = Int(tok[tok.index(after: star)...]) ?? 1; tok = String(tok[..<star]) }
            var beats = unit
            if let colon = tok.firstIndex(of: ":") { beats = Double(tok[tok.index(after: colon)...]) ?? unit; tok = String(tok[..<colon]) }
            var frets: [RiffNote.Fret] = []
            var tech = ""
            if tok != "r" {
                for part in tok.split(separator: "+") {
                    guard let first = part.first, let s = Theory.stringNames.firstIndex(of: String(first)) else { continue }
                    let rest = part.dropFirst()
                    let digits = rest.prefix { $0.isNumber }
                    guard let f = Int(digits) else { continue }
                    let tc = String(rest.dropFirst(digits.count))
                    if !tc.isEmpty { tech = tc }
                    frets.append(.init(string: s, fret: f))
                }
            }
            for _ in 0..<max(1, times) {
                out.append(RiffNote(id: out.count, start: t, beats: beats, frets: frets, tech: tech))
                t += beats
            }
        }
        return out
    }

    /// The riff as a playable song, so the mic game can check each note.
    var asSong: Song {
        var toks: [String] = []
        var flat: [(midi: Int, at: RiffNote.Fret, beats: Double)] = []
        for n in notes {
            // the lowest note of a double stop; a bend is checked at the pitch it's bent up to
            if let low = n.frets.min(by: { $0.string < $1.string }) {
                let m = Theory.openStrings[low.string] + low.fret + (n.tech == "b" ? 2 : 0)
                flat.append((m, low, n.beats))
            } else if !flat.isEmpty { flat[flat.count - 1].beats += n.beats }
        }
        for f in flat {
            toks.append("~" + Theory.noteName(midi: f.midi) + "@" + Theory.stringNames[f.at.string] + "\(f.at.fret):" + formatBeats(max(0.25, f.beats)))
        }
        return Song(id: "riff-" + id, title: title, artist: kind.single, genre: style, bpm: bpm, beatsPerBar: meter,
                    strum: "D-------", sections: [SongSection(name: title, chords: toks.joined(separator: " "), repeats: 2)],
                    note: about)
    }
}

// MARK: - Content (all original, traditional or public-domain)

enum RiffLibrary {
    static let all: [Riff] = [
        Riff("gravel", "Gravel Road", kind: .riff, style: "Rock", level: 1, bpm: 100, tone: .drive,
             about: "A driving open-E rock riff: a power chord, two chugs, then a walk on the low strings.",
             tips: ["Rest the side of your picking hand on the strings by the bridge for the muted chugs (the PM notes).",
                    "Only the power chord rings — everything else stays short and tight.",
                    "Use down-picks for everything to start with."],
             tab: "E0+A2:1 E0m E0m E3 E0 A0 A2 | E0+A2:1 E0m E0m D0 D2 E3 E0 | E0+A2:1 E0m E0m E3 E0 A0 A2 | G0+D0:1 A2+D2:1 E0+A2:2"),
        Riff("pentabox", "E Minor Pentatonic", kind: .exercise, style: "Scales", level: 1, bpm: 80, tone: .acoustic,
             about: "The most useful scale in guitar — almost every rock and blues solo lives here. Open position, two notes per string.",
             tips: ["Use finger 1 for 2nd-fret notes and finger 3 for 3rd-fret notes.",
                    "Alternate your picking: down, up, down, up.",
                    "Once it's smooth, improvise: play these notes in any order over an Em chord."],
             tab: "E0 E3 A0 A2 D0 D2 G0 G2 B0 B3 e0 e3 | e0 B3 B0 G2 G0 D2 D0 A2 A0 E3 E0:1"),
        Riff("saints", "When the Saints", kind: .melody, style: "Traditional", level: 1, bpm: 120, tone: .acoustic, unit: 1,
             about: "The classic marching tune, played on the top two strings. A perfect first melody.",
             tips: ["Fret 1 on the B string is C — that's home.", "Let the long notes ring for their full count.",
                    "Hum along so you can hear when a note is wrong."],
             tab: "r B1 e0 e1 | e3:4 | r B1 e0 e1 | e3:4 | r B1 e0 e1 | e3:2 e0:2 | B1:2 e0:2 | B3:4 | r e0 e0 B3 | B1:3 B1 | e0:2 e3 e3 | e1:4 | r B1 e0 e1 | e3:2 e0:2 | B1:2 B3:2 | B1:4"),
        Riff("boogie", "Twelve-Bar Boogie", kind: .riff, style: "Blues", level: 2, bpm: 112, swing: true, tone: .clean,
             about: "The shuffle that powers a thousand blues and early rock songs, through a full 12-bar blues in A.",
             tips: ["Keep finger 1 planted on fret 2, and stretch finger 3 or 4 to frets 4 and 5.",
                    "It swings: long-short, long-short — like a heartbeat.",
                    "The open string does the work; only the higher note moves."],
             tab: boogie()),
        Riff("travis", "Travis Picking in C", kind: .riff, style: "Folk", level: 2, bpm: 90, ring: true, tone: .acoustic,
             about: "The fingerstyle pattern behind countless folk and country songs: the thumb keeps a steady bass while fingers fill in between.",
             tips: ["Your thumb plays every on-beat, alternating between two bass strings.",
                    "Fingers pick the off-beats — index on the G string, middle on the B.",
                    "Hold the whole chord shape down and let everything ring."],
             tab: "A3+e0 B1 D2 G0 A3 B1 D2 G0 | A0+e0 B1 D2 G2 A0 B1 D2 G2 | E3+e3 B0 D0 G0 E3 B0 D0 G0 | A3+e0 B1 D2 G0 A3 B1 D2:1"),
        Riff("tidal", "Tidal Tremolo", kind: .riff, style: "Surf", level: 2, bpm: 132, tone: .clean, unit: 0.25,
             about: "Surf-rock tremolo picking: pick one note as fast and evenly as you can while your fretting hand slides down the low string.",
             tips: ["Small, fast wrist motions — the pick barely leaves the string.", "Keep the picking even even when the left hand moves.",
                    "Start at half speed; tremolo is about evenness, not speed."],
             tab: "E5*4 E6*4 E5*4 E3*4 | E2*4 E0*4 E2*4 E3*4 | E5*4 E6*4 E8*4 E6*4 | E5*4 E3*4 E0+A2:2"),
        Riff("rising", "Rising Sun Arpeggio", kind: .riff, style: "Folk", level: 2, bpm: 80, meter: 3, ring: true, tone: .acoustic,
             about: "The famous folk arpeggio through Am, C, D, F and E — one chord per bar, every string picked in turn.",
             tips: ["Hold each chord shape for the whole bar and let the notes ring together.",
                    "Pick down toward the floor going up the strings, then back.", "Change chords on the last note of each bar to stay in time."],
             tab: "A0 D2 G2 B1 G2 D2 | A3 D2 G0 B1 G0 D2 | D0 G2 B3 e2 B3 G2 | D3 G2 B1 e1 B1 G2 | A0 D2 G2 B1 G2 D2 | A3 D2 G0 B1 G0 D2 | E0 A2 D2 G1 D2 A2 | E0 A2 D2 G1 D2 A2"),
        Riff("countrypick", "Chicken-Pickin' Lick", kind: .riff, style: "Country", level: 3, bpm: 108, tone: .clean,
             about: "A snappy country lick in G — muted 'clucks' between bright notes, ending on a big G chord.",
             tips: ["Lightly touch the muted notes so they 'cluck' rather than ring.", "Snap the bright notes with your middle finger if you can.",
                    "Great over any song in G."],
             tab: "B3 B5m G4 G5 D5 D5m G4 D5 | A5 A7 D4 D5 E3+D5+G4:2 | B3 B5m G4 G5 D5 D5m G4 D5 | A5 A7m A5 D4 E3+A2+D0+G0+B0+e3:2"),
        Riff("gallop", "Iron Gallop", kind: .riff, style: "Metal", level: 3, bpm: 120, tone: .drive, unit: 0.25,
             about: "The galloping 'da-da-dum' rhythm that drives classic heavy metal, on the open low E.",
             tips: ["Pick down-down-up (or down-up-down) and keep it steady.", "Palm mute hard so the chugs stay tight.",
                    "Let the power chords at the end of each bar ring out."],
             tab: "E0m:0.5 E0m E0m E0m:0.5 E0m E0m E0m:0.5 E0m E0m E3+A5:0.5 E5+A7:0.5 | E0m:0.5 E0m E0m E0m:0.5 E0m E0m E0m:0.5 E0m E0m E6+A8:0.5 E5+A7:0.5 | E0m:0.5 E0m E0m E0m:0.5 E0m E0m E0m:0.5 E0m E0m E3+A5:0.5 E5+A7:0.5 | E8+A10:1 E7+A9:1 E5+A7:2"),
        Riff("funk", "Sixteenth Funk", kind: .riff, style: "Funk", level: 3, bpm: 96, tone: .clean, unit: 0.25,
             about: "A tight single-note funk line in E minor with a chord stab — it's all about the gaps.",
             tips: ["Keep your picking hand moving in 16ths even through the rests.",
                    "Lift your fretting fingers slightly after each note so it stops dead.", "Play the stabs short and percussive."],
             tab: "A7 r A7m A5 D7 r A5 r A7 A7m r D5 D7 r A5:0.5 | G7+B8:0.5 r:0.5 G7+B8 r G7+B8:0.5 r:2 | A7 r A7m A5 D7 r A5 r A7 A7m r D5 D7 r A5:0.5 | G7+B8:0.5 r:0.5 G7+B8 r G9+B10:0.5 G7+B8:2"),
        Riff("phrygian", "Spanish Fire", kind: .riff, style: "Flamenco", level: 3, bpm: 100, tone: .acoustic,
             about: "A Spanish-flavoured riff using the Phrygian sound — that half-step from E up to F is what gives it the flamenco mood.",
             tips: ["Keep finger 1 on fret 1 and finger 3 on fret 3.", "Accent the first note of each group.",
                    "End with a full E major chord, strummed hard."],
             tab: "E0 E1 E0 E1 E3 E1 E0:1 | A0 A1 A3 A1 A0 E3 E1 E0 | E0 E1 E0 E1 E3 E1 E0:1 | E0+A2+D2+G1+B0+e0:4"),
        Riff("greensleeves", "Greensleeves", kind: .melody, style: "Traditional", level: 2, bpm: 96, meter: 3, tone: .acoustic, unit: 1,
             about: "The English folk melody from the 1500s — a beautiful first tune in 3/4 time, in A minor.",
             tips: ["Count 1-2-3, 1-2-3: the long notes take two beats.", "Fret 1 on the G string is G♯ — it leads back to A.",
                    "Play it slowly and let it sing."],
             tab: "r:2 G2 | B1:2 B3 | e0:1.5 e1:0.5 e0 | B3:2 B0 | G0:1.5 G2:0.5 B0 | B1:2 G2 | G2:1.5 G1:0.5 G2 | B0:2 G1 | D2:2 G2 | B1:2 B3 | e0:1.5 e1:0.5 e0 | B3:2 B0 | G0:1.5 G2:0.5 B0 | B1:1.5 B0:0.5 G2 | G1:1.5 D4:0.5 G1 | G2:3"),
        Riff("romance", "Spanish Romance (opening)", kind: .melody, style: "Classical", level: 4, bpm: 60, meter: 3, ring: true, tone: .acoustic, unit: 1.0 / 3,
             about: "The anonymous Romance — a classical guitar favourite. The melody is on the high e string while the open B and G strings shimmer underneath in triplets.",
             tips: ["Play the bass and the first melody note together with thumb and ring finger.",
                    "Every beat is a triplet: melody, B, G.", "Keep the melody notes a little louder than the open strings."],
             tab: romance()),
        Riff("bluessolo", "12-Bar Blues Solo in A", kind: .solo, style: "Blues", level: 3, bpm: 88, swing: true, tone: .clean,
             about: "A complete solo over a 12-bar blues in A, using the A minor pentatonic box at the 5th fret — bends, slides, vibrato and a classic turnaround.",
             tips: ["Bend the B-string notes with three fingers together for strength.",
                    "Vibrato is a gentle, even wobble — don't rush it.", "Leave space: the rests are part of the solo."],
             tab: "B8b:1 e5:1 B8 B5 G7~:1 | G5 G7 D7:1 D5 A7 A5:1 | G5 G7h G5p D7 D5 A7 A5:1 | A5 A7 D5 D7 G5 G6 G7:1 | B8b:2 B8 e5 B5:1 | G7 G5 D7~:2 r:1 | e8 e5 B8 B5 G7:1 G5:1 | D7~:3 r:1 | G9/:1 G7 G5 D7:2 | B8b:1 B8 B5 G7:1 G5:1 | D7 D5 A7 A5 E8 E5 A5:1 | G6 G5 D7 D6 A7:2"),
        Riff("majpenta", "Country Pentatonic in G", kind: .solo, style: "Country", level: 2, bpm: 96, tone: .acoustic,
             about: "A sweet, happy solo over G, C and D using the G major pentatonic — the sound of country and folk lead guitar.",
             tips: ["Stay in this one shape and the notes always fit.", "Slide into the first note of the last bar.",
                    "Try this over any G–C–D song in the library."],
             tab: "D5:1 G4 G2 D5 D2 A5:1 | B5:1 B3 G4 G2:2 | e5:1 e3 B5 B3:1 G2:1 | G4/:1 G2 D2 D5~:2"),
        Riff("rocksolo", "Rock Solo in E Minor", kind: .solo, style: "Rock", level: 4, bpm: 100, tone: .drive, unit: 0.25,
             about: "A big rock solo high up the neck in the 12th-fret E minor pentatonic: screaming bends, vibrato and a fast run.",
             tips: ["Bend in tune — the bent note should match the note two frets higher.", "Mute strings you're not playing with your palm.",
                    "Learn the fast run in groups of four, slowly."],
             tab: "G14b:1 G14:0.5 G12:0.5 B15:0.5 B12:0.5 e12~:1 | B15b:2 B15:0.5 B12:0.5 G14:1 | e15 e12 B15 B12 e15 e12 B15 B12 G14 G12 G14 G12 D14 D12 D14 D12 | G12:0.5 G14h:0.5 D14:0.5 D12:0.5 e12~:2 | e15b:1 e15b:1 e12:0.5 B15:0.5 B12:1 | e17b:2 e17:0.5 e15:0.5 e12:1 | e15 e12 B15 B12 B15 B12 G14 G12 G14 G12 D14 D12 D14 D12 A14 A12 | E0+A2+D2:4"),
        Riff("legato", "Legato Builder", kind: .exercise, style: "Technique", level: 3, bpm: 80, tone: .clean, unit: 0.25,
             about: "Hammer-ons and pull-offs on every string: pick only the first note and let your fretting hand do the rest.",
             tips: ["Hammer with the fingertip, hard and close to the fret.", "Pull off slightly downward — you're plucking with your fretting finger.",
                    "Every note should be as loud as the picked one."],
             tab: legato()),
        Riff("fours", "Pentatonic Fours", kind: .exercise, style: "Technique", level: 5, bpm: 100, tone: .drive, unit: 0.25,
             about: "A classic shred sequence: the A minor pentatonic in groups of four notes, up and back down. Builds speed and accuracy.",
             tips: ["Strict alternate picking.", "Start at 50% speed with the loop on, and only speed up when it's clean.",
                    "Accent the first note of each group of four."],
             tab: fours())
    ]

    static func boogie() -> String {
        func bar(_ low: String, _ up: String) -> String { ["2", "2", "4", "4", "5", "5", "4", "4"].map { "\(low)0+\(up)\($0)" }.joined(separator: " ") }
        let a = bar("A", "D"), d = bar("D", "G"), e = bar("E", "A")
        return [a, a, a, a, d, d, a, a, e, d, a, e].joined(separator: " | ")
    }

    static func romance() -> String {
        let mel = [[7, 7, 7], [7, 5, 3], [3, 2, 0], [0, 3, 7], [12, 12, 12], [12, 10, 8], [8, 7, 5], [5, 7, 8]]
        return mel.enumerated().map { i, beats in
            let bass = i < 4 ? "E0" : "A0"
            let inner = i < 4 ? ["B0", "G0"] : ["B1", "G2"]
            return beats.enumerated().map { b, f in
                (b == 0 ? bass + "+e\(f)" : "e\(f)") + " " + inner.joined(separator: " ")
            }.joined(separator: " ")
        }.joined(separator: " | ")
    }

    static func legato() -> String {
        ["e", "B", "G", "D"].map { s in
            ([s + "5"] + (0..<15).map { k in s + ["7h", "8h", "7p", "5p"][k % 4] }).joined(separator: " ")
        }.joined(separator: " | ")
    }

    static func fours() -> String {
        let box = ["E5", "E8", "A5", "A7", "D5", "D7", "G5", "G7", "B5", "B8", "e5", "e8"]
        var groups: [String] = []
        for i in 0...(box.count - 4) { groups.append(box[i..<(i + 4)].joined(separator: " ")) }
        let rev = Array(box.reversed())
        for i in 0...(rev.count - 4) { groups.append(rev[i..<(i + 4)].joined(separator: " ")) }
        return groups.joined(separator: " ") + " E5+A7+D7:2"
    }
}

// MARK: - Player

/// Plays a riff note by note on the synth, with techniques, swing and an optional loop.
@MainActor
@Observable
final class RiffPlayer {
    private(set) var playing = false
    private(set) var current: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    func toggle(_ riff: Riff, speed: Double, loop: Bool) { playing ? stop() : play(riff, speed: speed, loop: loop) }

    func play(_ riff: Riff, speed: Double, loop: Bool, from start: Int = 0) {
        stop()
        guard !riff.notes.isEmpty else { return }
        let beat = 60 / (Double(riff.bpm) * max(0.25, speed))
        playing = true
        task = Task { [weak self] in
            let clock = ContinuousClock()
            var first = start
            repeat {
                let t0 = clock.now
                let offset = riff.swung(riff.notes[first].start)
                var sounding = Set<Int>()
                for n in riff.notes[first...] {
                    let at = (riff.swung(n.start) - offset) * beat
                    try? await clock.sleep(until: t0 + .milliseconds(Int(at * 1000)))
                    if Task.isCancelled { return }
                    self?.current = n.id
                    Self.sound(n, riff: riff, beat: beat, sounding: &sounding)
                }
                let endAt = (riff.swung(riff.totalBeats) - offset) * beat
                try? await clock.sleep(until: t0 + .milliseconds(Int(endAt * 1000)))
                first = 0
            } while loop && !Task.isCancelled
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(1200))
            self?.finish()
        }
    }

    /// Play a single note (tapping it in the TAB).
    func audition(_ n: RiffNote, riff: Riff) {
        var s = Set<Int>()
        Self.sound(n, riff: riff, beat: 60 / Double(riff.bpm), sounding: &s)
    }

    private static func sound(_ n: RiffNote, riff: Riff, beat: Double, sounding: inout Set<Int>) {
        let synth = GuitarSynth.shared
        let length = (riff.swung(n.end) - riff.swung(n.start)) * beat
        let strings = Set(n.frets.map(\.string))
        if !riff.ring || n.isRest {
            // a lead player stops the last note when moving to another string
            for s in sounding where !strings.contains(s) { synth.damp(s) }
            sounding.subtract(sounding.subtracting(strings))
        }
        let vel: Float = n.frets.count > 1 ? 0.7 : 0.82
        for f in n.frets { synth.lead(f.string, fret: f.fret, tech: n.tech, length: length, velocity: vel, touch: touch(for: riff, string: f.string)) }
        sounding.formUnion(strings)
    }

    /// Fingerstyle pieces on the acoustic (let-ring arpeggios, classical, flamenco) are played with the
    /// thumb on the bass strings and the fingers on the treble; everything else with a pick.
    nonisolated static func touch(for riff: Riff, string: Int) -> Touch {
        guard riff.tone == .acoustic, riff.ring || riff.style == "Classical" || riff.style == "Flamenco" else { return .pick }
        return string < 3 ? .thumb : .finger
    }

    func stop() {
        if task != nil { GuitarSynth.shared.silence() }
        task?.cancel()
        task = nil
        finish()
    }

    private func finish() {
        playing = false
        current = nil
    }
}

// MARK: - Library page

struct RiffLibraryView: View {
    @Environment(ProgressStore.self) var progress
    @Environment(AppState.self) var app
    @State private var kind: Riff.Kind? = nil
    @State private var level: Int? = nil
    @State private var open: Riff?

    private var riffs: [Riff] {
        RiffLibrary.all.filter { (kind == nil || $0.kind == kind) && (level == nil || $0.level == level) }
            .sorted { ($0.level, $0.title) < ($1.level, $1.title) }
    }
    private var songRiffs: [Song] { progress.allSongs.filter(\.hasRiff) }

    var body: some View {
        if let open {
            RiffDetailView(riff: open) { self.open = nil }
                .id(open.id)
        } else {
            library
        }
    }

    private var library: some View {
        Page {
            PageHeader(title: "Riffs & Solos", subtitle: "Learn lead guitar note by note — in TAB, with techniques, on acoustic or electric.") { EmptyView() }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Chip(title: "All", selected: kind == nil) { kind = nil }
                    ForEach(Riff.Kind.allCases) { k in
                        Chip(title: k.rawValue, icon: k.icon, selected: kind == k) { kind = kind == k ? nil : k }
                    }
                }
                HStack(spacing: 8) {
                    Chip(title: "Any level", selected: level == nil) { level = nil }
                    ForEach(1...5, id: \.self) { l in
                        Chip(title: Difficulty.name(l), selected: level == l, tint: Theme.levelColor(l)) { level = level == l ? nil : l }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                ForEach(riffs) { r in
                    Button { open = r } label: { RiffCard(riff: r) }.buttonStyle(.plain)
                }
            }
            if riffs.isEmpty {
                Text("Nothing at this level yet — try another filter.").font(Theme.font(14)).foregroundStyle(Theme.textDim)
            }
            if kind == nil || kind == .riff, !songRiffs.isEmpty {
                SectionHeader(title: "Riffs inside your songs", subtitle: "These songs include a single-note riff you can learn in the song game.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                    ForEach(songRiffs) { s in
                        Button { app.openSong(s) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(seed: s.id, title: s.title, genre: s.genre, size: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(s.artist).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textFaint)
                            }
                            .card(padding: 12, radius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct RiffCard: View {
    var riff: Riff
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(riff.kind.single, systemImage: riff.kind.icon).font(Theme.font(11, .heavy)).foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: riff.tone.icon).font(.system(size: 12)).foregroundStyle(Theme.textDim).help(riff.tone.name)
            }
            Text(riff.title).font(Theme.font(18, .bold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(riff.about).font(Theme.font(12.5)).foregroundStyle(Theme.textDim).lineLimit(2).frame(height: 34, alignment: .top)
            MiniTab(riff: riff).frame(height: 44)
            HStack {
                DifficultyBadge(level: riff.level)
                Spacer()
                Text("\(riff.style) · \(riff.bpm) BPM").font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textFaint)
            }
        }
        .card(padding: 16, radius: 16)
        .contentShape(Rectangle())
    }
}

/// A tiny preview of the first notes, as dots on six lines.
struct MiniTab: View {
    var riff: Riff
    var body: some View {
        Canvas { ctx, size in
            let lineGap = size.height / 5
            for s in 0..<6 {
                let y = CGFloat(5 - s) * lineGap
                ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) }, with: .color(Theme.text.opacity(0.15)), lineWidth: 1)
            }
            let shown = riff.notes.prefix(24)
            let span = max(1, (shown.last?.end ?? 1))
            for n in shown {
                for f in n.frets {
                    let x = CGFloat(n.start / span) * (size.width - 6) + 3
                    let y = CGFloat(5 - f.string) * lineGap
                    ctx.fill(Path(ellipseIn: .init(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(Theme.accent))
                }
            }
        }
    }
}

// MARK: - Riff page

struct RiffDetailView: View {
    @Environment(AppState.self) var app
    var riff: Riff
    var onBack: () -> Void
    @State private var player = RiffPlayer()
    @State private var tone: GuitarSynth.Tone = .acoustic
    @State private var speed = 0.75
    @State private var loop = true

    var body: some View {
        Page {
            Button(action: onBack) { Label("Riffs & Solos", systemImage: "chevron.left") }
                .buttonStyle(.plain).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textDim)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(riff.kind.single, systemImage: riff.kind.icon).font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.accent)
                    Text(riff.title).font(Theme.font(32, .bold)).foregroundStyle(Theme.text)
                    Text(riff.about).font(Theme.font(15)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        DifficultyBadge(level: riff.level)
                        Pill(icon: "metronome", text: "\(riff.bpm) BPM\(riff.swing ? " · swing" : "")")
                        Pill(icon: "music.quarternote.3", text: "\(riff.meter)/4 · \(riff.bars) bars")
                        Pill(icon: "hand.raised.fingers.spread", text: riff.frettedRange.upperBound == 0 ? "Open strings" : "Frets \(riff.frettedRange.lowerBound)–\(riff.frettedRange.upperBound)")
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }

            controls

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "TAB", subtitle: "Each line is a string (high e on top); numbers are frets. Click any note to hear it.")
                TabView(riff: riff, current: player.current) { player.audition($0, riff: riff) }
                legend
            }
            .card()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("HOW TO PLAY IT").font(Theme.font(11, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    ForEach(riff.tips, id: \.self) { t in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).padding(.top, 2)
                            Text(t).font(Theme.font(14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                if !riff.techniques.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TECHNIQUES").font(Theme.font(11, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                        ForEach(riff.techniques, id: \.self) { t in
                            Label(t, systemImage: "checkmark.circle.fill").font(Theme.font(14, .medium)).foregroundStyle(Theme.text)
                        }
                    }
                    .frame(width: 220, alignment: .leading)
                    .card()
                }
            }
        }
        .onAppear { tone = riff.tone }
        .onChange(of: tone) { _, t in GuitarSynth.shared.tone = t; restartIfPlaying() }
        .onChange(of: speed) { _, _ in restartIfPlaying() }
        .onDisappear {
            player.stop()
            GuitarSynth.shared.tone = .acoustic
        }
    }

    private func restartIfPlaying() {
        if player.playing { player.play(riff, speed: speed, loop: loop) }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                GuitarSynth.shared.tone = tone
                player.toggle(riff, speed: speed, loop: loop)
            } label: {
                Label(player.playing ? "Stop" : "Listen", systemImage: player.playing ? "stop.fill" : "play.fill")
                    .frame(minWidth: 62)
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize()
            .keyboardShortcut(.space, modifiers: [])

            Button { app.play(riff.asSong, mode: .practice, tempo: speed) } label: {
                Label("Practice with Mic", systemImage: "mic.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            .help("Play it note by note — the app waits for each note it hears")

            Divider().frame(height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text("SOUND").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Picker("Sound", selection: $tone) {
                    ForEach(GuitarSynth.Tone.allCases) { t in Label(t.name, systemImage: t.icon).tag(t) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(minWidth: 260, maxWidth: 330)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SPEED").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Picker("Speed", selection: $speed) {
                    ForEach([0.5, 0.75, 0.9, 1.0], id: \.self) { s in Text("\(Int(s * 100))%").tag(s) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(minWidth: 180, maxWidth: 220)
            }
            Toggle(isOn: $loop) { Label("Loop", systemImage: "repeat") }
                .toggleStyle(.button)
                .onChange(of: loop) { _, _ in restartIfPlaying() }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach([("h", "hammer-on"), ("p", "pull-off"), ("/", "slide in"), ("b", "bend up"), ("~", "vibrato"), ("PM", "palm mute")], id: \.0) { k, v in
                HStack(spacing: 4) {
                    Text(k).font(Theme.font(12, .heavy)).foregroundStyle(Theme.accent)
                    Text(v).font(Theme.font(12)).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

/// Six-line guitar TAB with technique marks, bar lines, beat counts and a moving highlight.
struct TabView: View {
    var riff: Riff
    var current: Int?
    var onTap: (RiffNote) -> Void

    private let row: CGFloat = 22
    private func width(_ n: RiffNote) -> CGFloat { max(30, CGFloat(n.beats) * 64) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Text(" ").font(Theme.font(10)).frame(height: 16)
                        ForEach((0..<6).reversed(), id: \.self) { s in
                            Text(Theory.stringNames[s]).font(Theme.font(12, .bold)).foregroundStyle(Theme.textFaint).frame(width: 22, height: row)
                        }
                        Text(" ").font(Theme.font(10)).frame(height: 18)
                    }
                    ForEach(riff.notes) { n in
                        column(n).id(n.id)
                    }
                    Rectangle().fill(Theme.text.opacity(0.5)).frame(width: 2, height: row * 5).padding(.top, 16 + row / 2)
                }
                .padding(.bottom, 6)
            }
            .onChange(of: current) { _, c in
                if let c { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(c, anchor: .center) } }
            }
        }
    }

    private func column(_ n: RiffNote) -> some View {
        let active = current == n.id
        let barStart = n.start > 0 && abs(n.start / Double(riff.meter) - (n.start / Double(riff.meter)).rounded()) < 0.001
        let w = width(n)
        return VStack(spacing: 0) {
            Text(n.tech == "m" ? "PM" : " ").font(Theme.font(9, .heavy)).foregroundStyle(Theme.textFaint).frame(height: 16)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in
                        Rectangle().fill(Theme.text.opacity(0.28)).frame(height: 1).frame(height: row)
                    }
                }
                VStack(spacing: 0) {
                    ForEach((0..<6).reversed(), id: \.self) { s in
                        ZStack {
                            if let f = n.frets.first(where: { $0.string == s }) {
                                Text(label(f.fret, n.tech))
                                    .font(Theme.font(13, .bold)).monospacedDigit()
                                    .foregroundStyle(active ? Theme.onAccent : Theme.text)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface)))
                            } else if n.isRest && s == 3 {
                                Text("·").font(Theme.font(14, .bold)).foregroundStyle(Theme.textFaint)
                            }
                        }
                        .frame(height: row)
                    }
                }
            }
            .background(active ? Theme.accent.opacity(0.12) : Color.clear)
            Text(count(n)).font(Theme.font(10, .semibold)).foregroundStyle(Theme.textFaint).frame(height: 18)
        }
        .frame(width: w)
        .overlay(alignment: .leading) {
            if barStart { Rectangle().fill(Theme.text.opacity(0.35)).frame(width: 1.5, height: row * 5).padding(.top, 16 + row / 2 - row * 0.5 + row / 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !n.isRest { onTap(n) } }
        .accessibilityElement()
        .accessibilityLabel(n.isRest ? "Rest" : n.frets.map { "\(Theory.stringLabels[$0.string]) fret \($0.fret)" }.joined(separator: ", "))
    }

    private func label(_ fret: Int, _ tech: String) -> String {
        switch tech {
        case "h": return "h\(fret)"
        case "p": return "p\(fret)"
        case "/": return "/\(fret)"
        case "b": return "\(fret)b"
        case "~": return "\(fret)~"
        default: return "\(fret)"
        }
    }

    /// Beat numbers under on-beat notes ("1 & 2 &" style counting).
    private func count(_ n: RiffNote) -> String {
        let inBar = n.start.truncatingRemainder(dividingBy: Double(riff.meter))
        if abs(inBar - inBar.rounded()) < 0.01 { return "\(Int(inBar.rounded()) + 1)" }
        if abs(inBar - inBar.rounded(.down) - 0.5) < 0.01 { return "&" }
        return ""
    }
}
