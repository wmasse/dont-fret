import Foundation
import SwiftUI

enum SkillLevel: String, CaseIterable, Codable, Identifiable {
    case brandNew, beginner, intermediate, advanced, pro
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brandNew: return "Brand New"
        case .beginner: return "Beginner"
        case .intermediate: return "Intermediate"
        case .advanced: return "Advanced"
        case .pro: return "Pro"
        }
    }
    var blurb: String {
        switch self {
        case .brandNew: return "I've never really played. Start me from zero."
        case .beginner: return "I know a few open chords like G, C and Em."
        case .intermediate: return "I can play songs and I'm working on barre chords."
        case .advanced: return "Barre chords are fine. I want speed and colour chords."
        case .pro: return "I gig or teach. Give me hard harmony and tight timing."
        }
    }
    var icon: String {
        switch self {
        case .brandNew: return "leaf.fill"
        case .beginner: return "music.note"
        case .intermediate: return "guitars.fill"
        case .advanced: return "flame.fill"
        case .pro: return "crown.fill"
        }
    }
    var rank: Int { SkillLevel.allCases.firstIndex(of: self)! }
    var songRange: ClosedRange<Int> {
        switch self {
        case .brandNew: return 1...1
        case .beginner: return 1...2
        case .intermediate: return 2...3
        case .advanced: return 3...5
        case .pro: return 4...5
        }
    }
    var defaultTempo: Double { [0.7, 0.85, 1.0, 1.0, 1.1][rank] }
    var defaultStrictness: Strictness { [.relaxed, .relaxed, .normal, .normal, .strict][rank] }
    var recommendedMode: PlayMode { rank <= 1 ? .practice : .perform }
    var trainerDeck: String { ["first", "first", "sevenths", "barre", "jazz"][rank] }
    var strumPattern: String { ["downs", "campfire", "pop", "shuffle", "funk16"][rank] }
    var dailyGoalMinutes: Int { [10, 15, 20, 30, 45][rank] }
    var unlocksTempoAbove100: Bool { rank >= 3 }

    var path: [PathStep] {
        switch self {
        case .brandNew:
            return [
                PathStep(title: "Tune your guitar", detail: "Use the tuner to get all six strings in tune.", kind: .tune),
                PathStep(title: "Learn Em and Am", detail: "Two easy shapes that sound great together.", kind: .chords(["Em", "Am"])),
                PathStep(title: "Steady down-strums", detail: "One strum per beat with the metronome.", kind: .strum("downs")),
                PathStep(title: "Play your first song", detail: "Em to Am in Wait Mode — no rush.", kind: .song("First Steps: Em to Am")),
                PathStep(title: "Add E and A", detail: "The two-chord rock shapes.", kind: .chords(["E", "A"])),
                PathStep(title: "G, C and D", detail: "The campfire trio unlocks hundreds of songs.", kind: .chords(["G", "C", "D"])),
                PathStep(title: "Play Campfire Trio", detail: "Your first 3-chord song.", kind: .song("Campfire Trio")),
            ]
        case .beginner:
            return [
                PathStep(title: "Lock in the open chords", detail: "G, C, D, Em, Am — fast and clean.", kind: .chords(["G", "C", "D", "Em", "Am"])),
                PathStep(title: "The Campfire Strum", detail: "D - D U - U D U. The pattern of a thousand songs.", kind: .strum("campfire")),
                PathStep(title: "Knockin' on Heaven's Door", detail: "Four friendly chords, slow tempo.", kind: .song("Knockin' on Heaven's Door")),
                PathStep(title: "Your first sevenths", detail: "A7, D7, E7 add bluesy colour.", kind: .chords(["A7", "D7", "E7"])),
                PathStep(title: "Stand By Me", detail: "A classic G–Em–C–D progression.", kind: .song("Stand By Me")),
                PathStep(title: "Meet the F chord", detail: "Your first barre — take it slow.", kind: .chords(["F"])),
            ]
        case .intermediate:
            return [
                PathStep(title: "Barre chord bootcamp", detail: "F, Bm, F#m, B and C#m.", kind: .chords(["F", "Bm", "F#m", "B", "C#m"])),
                PathStep(title: "Pop Push strum", detail: "Accents that make pop songs bounce.", kind: .strum("pop")),
                PathStep(title: "Wonderwall", detail: "Colour chords with a constant strum.", kind: .song("Wonderwall")),
                PathStep(title: "Hey There Delilah", detail: "Barre chords in a real song.", kind: .song("Hey There Delilah")),
                PathStep(title: "Rock Chuck", detail: "Add percussive mutes on 2 and 4.", kind: .strum("rockchuck")),
                PathStep(title: "Hotel California", detail: "The big one. Bm, F# and friends.", kind: .song("Hotel California")),
            ]
        case .advanced:
            return [
                PathStep(title: "Colour & sus voicings", detail: "maj7, m7, sus and add9 shapes.", kind: .chords(["Cmaj7", "Fmaj7", "Am7", "Dsus4", "Cadd9"])),
                PathStep(title: "Blues Shuffle", detail: "Swing your strumming hand.", kind: .strum("shuffle")),
                PathStep(title: "12-Bar Blues in E", detail: "Shuffle through the 12-bar form.", kind: .song("12-Bar Blues in E")),
                PathStep(title: "Jazz ii–V–I", detail: "The most important progression in jazz.", kind: .song("Jazz Corner: ii–V–I")),
                PathStep(title: "Hotel California at full speed", detail: "Aim for 3 stars.", kind: .song("Hotel California")),
            ]
        case .pro:
            return [
                PathStep(title: "Extended harmony", detail: "m7♭5, dim7, 9ths and 6/9.", kind: .chords(["Bm7b5", "Cdim7", "E9", "C9", "D6/9"])),
                PathStep(title: "16th Funk", detail: "Tight 16ths with chucks.", kind: .strum("funk16")),
                PathStep(title: "16th Funk Lab", detail: "Ninths over a funk groove.", kind: .song("16th Funk Lab")),
                PathStep(title: "Diminished Passing Tones", detail: "Voice-leading with dim and aug.", kind: .song("Diminished Passing Tones")),
                PathStep(title: "Neo-Soul Ninths", detail: "Smooth extended voicings.", kind: .song("Neo-Soul Ninths")),
            ]
        }
    }
}

struct PathStep: Identifiable, Hashable {
    enum Kind: Hashable { case chords([String]), song(String), strum(String), tune }
    var title: String
    var detail: String
    var kind: Kind
    var id: String { title }
    var icon: String {
        switch kind {
        case .chords: return "hand.point.up.left.fill"
        case .song: return "music.note"
        case .strum: return "arrow.up.arrow.down"
        case .tune: return "tuningfork"
        }
    }
}

enum Strictness: String, CaseIterable, Codable, Identifiable {
    case relaxed, normal, strict
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var threshold: Float { [0.66, 0.74, 0.82][index] }
    var margin: Float { [0.10, 0.05, 0.02][index] }
    var holdFrames: Int { [2, 2, 3][index] }
    var strumWindow: Double { [0.16, 0.12, 0.08][index] }
    private var index: Int { Strictness.allCases.firstIndex(of: self)! }
    var detail: String {
        switch self {
        case .relaxed: return "Forgiving. Great while your fingers are still learning."
        case .normal: return "Balanced accuracy for most players."
        case .strict: return "Every note has to ring clean, timing must be tight."
        }
    }
}

struct Profile: Codable, Equatable {
    var onboarded = false
    var name = ""
    var skill: SkillLevel = .beginner
    var themeID = "sunset"
    var genres: [String] = []
    var strictness: Strictness? = nil
    var dailyGoal: Int? = nil
    var leftHanded = false
    // microphone & timing
    var inputDeviceUID: String? = nil
    var noiseFloor: Float? = nil
    var clickBleed: Float? = nil
    var latencyMicMs: Double? = nil
    var latencyTapMs: Double? = nil
    var checkDirection = false
    var preferEasyShapes: Bool? = nil
}

extension Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Profile()
        onboarded = c.v(.onboarded, d.onboarded)
        name = c.v(.name, d.name)
        skill = c.v(.skill, d.skill)
        themeID = c.v(.themeID, d.themeID)
        genres = c.v(.genres, d.genres)
        strictness = c.v(.strictness, d.strictness)
        dailyGoal = c.v(.dailyGoal, d.dailyGoal)
        leftHanded = c.v(.leftHanded, d.leftHanded)
        inputDeviceUID = c.v(.inputDeviceUID, d.inputDeviceUID)
        noiseFloor = c.v(.noiseFloor, d.noiseFloor)
        clickBleed = c.v(.clickBleed, d.clickBleed)
        latencyMicMs = c.v(.latencyMicMs, d.latencyMicMs)
        latencyTapMs = c.v(.latencyTapMs, d.latencyTapMs)
        checkDirection = c.v(.checkDirection, d.checkDirection)
        preferEasyShapes = c.v(.preferEasyShapes, d.preferEasyShapes)
    }
}

struct Attempt: Codable, Hashable {
    var date = Date()
    var score = 0
    var accuracy = 0.0
    var tempo = 1.0
    var mode = "perform"
}

extension Attempt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.v(.date, Date()); score = c.v(.score, 0); accuracy = c.v(.accuracy, 0)
        tempo = c.v(.tempo, 1); mode = c.v(.mode, "perform")
    }
}

struct SongRecord: Codable {
    var bestScore = 0
    var bestAccuracy = 0.0
    var stars = 0
    var plays = 0
    var lastPlayed = Date()
    var history: [Attempt] = []
}

extension SongRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestScore = c.v(.bestScore, 0); bestAccuracy = c.v(.bestAccuracy, 0); stars = c.v(.stars, 0)
        plays = c.v(.plays, 0); lastPlayed = c.v(.lastPlayed, Date()); history = c.v(.history, [])
    }
}

struct ChordStat: Codable {
    var attempts = 0
    var hits = 0
    var bestTime: Double? = nil
    var avgTime: Double? = nil
    var mastery = 0
    var due: Date? = nil
    var lastPracticed: Date? = nil
}

extension ChordStat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempts = c.v(.attempts, 0); hits = c.v(.hits, 0); bestTime = c.v(.bestTime, nil); avgTime = c.v(.avgTime, nil)
        mastery = c.v(.mastery, 0); due = c.v(.due, nil); lastPracticed = c.v(.lastPracticed, nil)
    }
}

struct ProgressData: Codable {
    var profile = Profile()
    var xp = 0
    var songs: [String: SongRecord] = [:]
    var chords: [String: ChordStat] = [:]
    var practice: [String: Double] = [:]
    var changes: [String: Int] = [:]
    var strums: [String: Int] = [:]
    var customSongs: [Song] = []
    var tunerUses = 0
    var achievements: [String: Date] = [:]
    var dailyDone: [String] = []
    var loopSpeedUps = 0
}

extension ProgressData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = c.v(.profile, Profile()); xp = c.v(.xp, 0); songs = c.v(.songs, [:]); chords = c.v(.chords, [:])
        practice = c.v(.practice, [:]); changes = c.v(.changes, [:]); strums = c.v(.strums, [:])
        customSongs = c.v(.customSongs, []); tunerUses = c.v(.tunerUses, 0); achievements = c.v(.achievements, [:])
        dailyDone = c.v(.dailyDone, []); loopSpeedUps = c.v(.loopSpeedUps, 0)
    }
}

// MARK: - Achievements & challenges

struct Achievement: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String

    static let all: [Achievement] = [
        Achievement(id: "first-song", title: "First Song", detail: "Finish any song.", icon: "music.note"),
        Achievement(id: "three-stars", title: "Flawless", detail: "Get 3 stars on a song.", icon: "star.fill"),
        Achievement(id: "ten-songs", title: "Setlist", detail: "Play 10 different songs.", icon: "music.note.list"),
        Achievement(id: "riff", title: "Riff Raff", detail: "Finish a single-note riff.", icon: "waveform.path"),
        Achievement(id: "full-speed", title: "Full Speed", detail: "2+ stars at 100% tempo or faster.", icon: "hare.fill"),
        Achievement(id: "loop-ramp", title: "Speed Builder", detail: "Speed up a looped section 3 times.", icon: "arrow.up.right.circle.fill"),
        Achievement(id: "streak-3", title: "On a Roll", detail: "Practise 3 days in a row.", icon: "flame"),
        Achievement(id: "streak-7", title: "Week Warrior", detail: "Practise 7 days in a row.", icon: "flame.fill"),
        Achievement(id: "streak-30", title: "Dedicated", detail: "Practise 30 days in a row.", icon: "crown.fill"),
        Achievement(id: "master-5", title: "Chord Collector", detail: "Master 5 chords.", icon: "hand.raised.fill"),
        Achievement(id: "master-20", title: "Chord Encyclopedia", detail: "Master 20 chords.", icon: "books.vertical.fill"),
        Achievement(id: "barre", title: "Barre None", detail: "Master a barre chord.", icon: "hand.point.up.left.fill"),
        Achievement(id: "changes-30", title: "Quick Hands", detail: "30+ changes in one minute.", icon: "bolt.fill"),
        Achievement(id: "changes-60", title: "Lightning Hands", detail: "60+ changes in one minute.", icon: "bolt.circle.fill"),
        Achievement(id: "strum-90", title: "Groove Machine", detail: "90% in the Strum Trainer.", icon: "metronome.fill"),
        Achievement(id: "tuned", title: "In Tune", detail: "Tune up with the tuner.", icon: "tuningfork"),
        Achievement(id: "daily", title: "Daily Player", detail: "Complete a daily challenge.", icon: "calendar"),
        Achievement(id: "songwriter", title: "Songwriter", detail: "Add or import your own song.", icon: "pencil"),
        Achievement(id: "level-5", title: "Level 5", detail: "Reach level 5.", icon: "5.circle.fill"),
        Achievement(id: "level-10", title: "Level 10", detail: "Reach level 10.", icon: "10.circle.fill"),
    ]
    static func named(_ id: String) -> Achievement? { all.first { $0.id == id } }
}

struct Toast: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subtitle: String
    var icon: String
}

struct DailyChallenge {
    enum Kind { case song(String, stars: Int), changes(String, String, count: Int), strum(String, pct: Int), review(count: Int) }
    var kind: Kind
    var title: String
    var detail: String
    var icon: String
}

@Observable
final class ProgressStore {
    var data: ProgressData {
        didSet {
            applyEnvironment()
            scheduleSave()
        }
    }
    var toasts: [Toast] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DontFret", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { folder.appendingPathComponent("progress.json") }

    private static func decode(_ d: Data) -> ProgressData? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ProgressData.self, from: d)
    }

    init() {
        var loaded = ProgressData()
        if let d = try? Data(contentsOf: Self.fileURL) {
            if let p = Self.decode(d) {
                loaded = p
            } else {
                // never silently lose progress: keep the unreadable file aside
                let stamp = Int(Date().timeIntervalSince1970)
                try? FileManager.default.copyItem(at: Self.fileURL, to: Self.folder.appendingPathComponent("progress-unreadable-\(stamp).json"))
            }
        }
        data = loaded
        applyEnvironment()
    }

    private func applyEnvironment() {
        Theme.palette = Palette.named(data.profile.themeID)
        ChordDiagramView.leftHanded = data.profile.leftHanded
        ChordLibrary.preferEasy = preferEasyShapes
        AudioEngine.shared.configure(gate: data.profile.noiseFloor.map { max(0.003, $0 * 3) },
                                     clickBleed: data.profile.clickBleed,
                                     deviceUID: data.profile.inputDeviceUID)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = data
        let w = DispatchWorkItem { Self.write(snapshot, to: Self.fileURL) }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private static func write(_ d: ProgressData, to url: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let bytes = try? enc.encode(d) { try? bytes.write(to: url, options: .atomic) }
    }

    // MARK: Backup / restore (use iCloud Drive to move progress between Macs)
    func exportBackup(to url: URL) { Self.write(data, to: url) }
    func importBackup(from url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let p = Self.decode(d) else { return false }
        data = p
        return true
    }

    // MARK: Profile helpers
    var profile: Profile { data.profile }
    var skill: SkillLevel { data.profile.skill }
    var strictness: Strictness { data.profile.strictness ?? skill.defaultStrictness }
    var dailyGoal: Int { data.profile.dailyGoal ?? skill.dailyGoalMinutes }
    var preferEasyShapes: Bool { data.profile.preferEasyShapes ?? (skill.rank <= 1) }
    func latency(for input: InputMode) -> Double { (input == .mic ? data.profile.latencyMicMs : data.profile.latencyTapMs) ?? 0 }

    // MARK: Toasts
    func toast(_ t: Toast) {
        toasts.append(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in self?.toasts.removeAll { $0.id == t.id } }
    }

    func unlock(_ id: String) {
        guard data.achievements[id] == nil, let a = Achievement.named(id) else { return }
        data.achievements[id] = Date()
        data.xp += 40
        toast(Toast(title: "Achievement: \(a.title)", subtitle: a.detail + "  +40 XP", icon: a.icon))
    }

    func checkAchievements() {
        let played = data.songs.values.filter { $0.plays > 0 }
        if !played.isEmpty { unlock("first-song") }
        if played.contains(where: { $0.stars >= 3 }) { unlock("three-stars") }
        if played.count >= 10 { unlock("ten-songs") }
        if streak >= 3 { unlock("streak-3") }
        if streak >= 7 { unlock("streak-7") }
        if streak >= 30 { unlock("streak-30") }
        let mastered = masteredChords
        if mastered.count >= 5 { unlock("master-5") }
        if mastered.count >= 20 { unlock("master-20") }
        if mastered.contains(where: { ChordLibrary.shape(for: $0)?.barre != nil }) { unlock("barre") }
        if (data.changes.values.max() ?? 0) >= 30 { unlock("changes-30") }
        if (data.changes.values.max() ?? 0) >= 60 { unlock("changes-60") }
        if (data.strums.values.max() ?? 0) >= 90 { unlock("strum-90") }
        if data.tunerUses > 0 { unlock("tuned") }
        if !data.customSongs.isEmpty { unlock("songwriter") }
        if data.loopSpeedUps >= 3 { unlock("loop-ramp") }
        if level >= 5 { unlock("level-5") }
        if level >= 10 { unlock("level-10") }
    }

    // MARK: Songs
    var allSongs: [Song] { SongCatalog.songs + data.customSongs }
    func song(id: String) -> Song? { allSongs.first { $0.id == id } }
    func song(titled t: String) -> Song? { allSongs.first { $0.title == t } }

    func recommendedSongs(limit: Int = 8) -> [Song] {
        let range = skill.songRange
        let liked = Set(data.profile.genres)
        let pool = allSongs.filter { range.contains($0.difficulty) && !$0.isCustom }
        let sorted = pool.sorted { a, b in
            let sa = (liked.contains(a.genre) ? 0 : 1, data.songs[a.id]?.stars ?? 0, a.difficulty)
            let sb = (liked.contains(b.genre) ? 0 : 1, data.songs[b.id]?.stars ?? 0, b.difficulty)
            return sa < sb
        }
        return Array(sorted.prefix(limit))
    }

    func addCustomSong(_ s: Song) {
        data.customSongs.removeAll { $0.id == s.id }
        data.customSongs.append(s)
        checkAchievements()
    }
    func deleteCustomSong(_ s: Song) {
        data.customSongs.removeAll { $0.id == s.id }
        SongMedia.remove(s.id)
    }

    // MARK: XP & levels
    static func xpFor(level n: Int) -> Int { 150 * (n - 1) * n / 2 }
    var level: Int {
        var n = 1
        while Self.xpFor(level: n + 1) <= data.xp { n += 1 }
        return n
    }
    var levelProgress: Double {
        let a = Self.xpFor(level: level), b = Self.xpFor(level: level + 1)
        return Double(data.xp - a) / Double(max(1, b - a))
    }
    var xpToNext: Int { Self.xpFor(level: level + 1) - data.xp }

    func addXP(_ n: Int) {
        let before = level
        data.xp += max(0, n)
        if level > before {
            toast(Toast(title: "Level up! You're level \(level)", subtitle: "Keep going — \(xpToNext) XP to the next one.", icon: "arrow.up.circle.fill"))
        }
        checkAchievements()
    }

    // MARK: Practice time
    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static var todayKey: String { dayFormatter.string(from: Date()) }
    func addPractice(seconds: Double) {
        guard seconds > 0 else { return }
        data.practice[Self.todayKey, default: 0] += seconds
    }
    var todayMinutes: Double { (data.practice[Self.todayKey] ?? 0) / 60 }
    var totalMinutes: Double { data.practice.values.reduce(0, +) / 60 }
    var streak: Int {
        var count = 0
        var day = Date()
        if (data.practice[Self.dayFormatter.string(from: day)] ?? 0) < 1 {
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        while (data.practice[Self.dayFormatter.string(from: day)] ?? 0) >= 1 {
            count += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }
    func lastDays(_ n: Int) -> [(label: String, minutes: Double)] {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return (0..<n).reversed().map { off in
            let d = Calendar.current.date(byAdding: .day, value: -off, to: Date())!
            return (f.string(from: d), (data.practice[Self.dayFormatter.string(from: d)] ?? 0) / 60)
        }
    }

    // MARK: Records
    @discardableResult
    func recordSong(_ song: Song, score: Int, accuracy: Double, stars: Int, tempo: Double = 1, mode: PlayMode = .perform) -> Bool {
        var r = data.songs[song.id] ?? SongRecord()
        let isBest = score > r.bestScore
        r.plays += 1
        r.bestScore = max(r.bestScore, score)
        r.bestAccuracy = max(r.bestAccuracy, accuracy)
        r.stars = max(r.stars, stars)
        r.lastPlayed = Date()
        if mode != .sheet {
            r.history.append(Attempt(date: Date(), score: score, accuracy: accuracy, tempo: tempo, mode: mode.rawValue))
            if r.history.count > 60 { r.history.removeFirst(r.history.count - 60) }
        }
        data.songs[song.id] = r
        if song.hasRiff && mode != .sheet && stars >= 1 { unlock("riff") }
        if tempo >= 1 && stars >= 2 && mode == .perform { unlock("full-speed") }
        if case .song(let id, let need) = dailyChallenge.kind, id == song.id, stars >= need { completeDaily() }
        checkAchievements()
        return isBest
    }

    func recordChanges(pairKey: String, count: Int) -> Bool {
        let prev = data.changes[pairKey] ?? 0
        if count > prev { data.changes[pairKey] = count }
        if case .changes(let a, let b, let need) = dailyChallenge.kind, [a, b].sorted().joined(separator: "↔") == pairKey, count >= need { completeDaily() }
        checkAchievements()
        return count > prev
    }

    func recordStrum(id: String, pct: Int) {
        data.strums[id] = max(data.strums[id] ?? 0, pct)
        if case .strum(let pid, let need) = dailyChallenge.kind, pid == id, pct >= need { completeDaily() }
        checkAchievements()
    }

    func recordLoopSpeedUp() {
        data.loopSpeedUps += 1
        checkAchievements()
    }

    // MARK: Spaced repetition
    static let reviewIntervals: [Double] = [0, 1, 2, 4, 7, 14]   // days, by mastery

    func recordChord(_ name: String, hit: Bool, time: Double?) {
        var s = data.chords[name] ?? ChordStat()
        s.mastery = mastery(name)       // apply any decay before updating
        s.attempts += 1
        if hit, let t = time {
            s.hits += 1
            s.bestTime = min(s.bestTime ?? t, t)
            s.avgTime = s.avgTime.map { $0 * 0.7 + t * 0.3 } ?? t
            if t < 2.5 { s.mastery = min(5, s.mastery + 1) }
        } else {
            s.mastery = max(0, s.mastery - 1)
        }
        s.lastPracticed = Date()
        s.due = Date().addingTimeInterval(Self.reviewIntervals[s.mastery] * 86400)
        data.chords[name] = s
        if case .review(let need) = dailyChallenge.kind, reviewedToday >= need { completeDaily() }
        if hit { checkAchievements() }
    }

    /// Mastery with forgetting: it drops one level for each review interval you've let slip past.
    func mastery(_ chord: String) -> Int {
        guard let s = data.chords[chord] else { return 0 }
        guard s.mastery > 0, let due = s.due else { return s.mastery }
        let overdue = Date().timeIntervalSince(due) / 86400
        guard overdue > 0 else { return s.mastery }
        let interval = max(1, Self.reviewIntervals[s.mastery])
        return max(0, s.mastery - Int(overdue / interval))
    }

    var dueChords: [String] {
        data.chords.filter { $0.value.attempts > 0 && ($0.value.due ?? .distantPast) <= Date() }
            .sorted { ($0.value.due ?? .distantPast) < ($1.value.due ?? .distantPast) }.map(\.key)
    }

    var reviewedToday: Int {
        data.chords.values.filter { $0.lastPracticed.map { Calendar.current.isDateInToday($0) } ?? false }.count
    }

    var masteredChords: [String] { data.chords.keys.filter { mastery($0) >= 3 } }

    func weakestChords(_ n: Int) -> [String] {
        let pool = ChordLibrary.shapes.filter { $0.level <= max(1, min(3, skill.rank)) }.map(\.name)
        return Array(pool.sorted { mastery($0) < mastery($1) }.prefix(n))
    }

    // MARK: Daily challenge
    var dailyChallenge: DailyChallenge {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let r = skill.rank
        switch day % 4 {
        case 0:
            let pool = recommendedSongs(limit: 12)
            let s = pool.isEmpty ? SongCatalog.songs[0] : pool[day % pool.count]
            let stars = r <= 1 ? 1 : 2
            return DailyChallenge(kind: .song(s.id, stars: stars), title: "Play \(s.title)",
                                  detail: "Get \(stars) star\(stars == 1 ? "" : "s") in Play Along or Wait Mode.", icon: "music.note")
        case 1:
            let pairs = [[("Em", "Am"), ("G", "C"), ("D", "A")], [("G", "C"), ("C", "D"), ("Am", "E")], [("C", "F"), ("G", "Bm"), ("A", "F#m")],
                         [("F", "Bb"), ("Bm", "F#m"), ("Cmaj7", "Fmaj7")], [("Dm7", "G7"), ("Bm7b5", "E9"), ("Gm", "Cm")]][r]
            let p = pairs[day % pairs.count]
            let need = [12, 20, 30, 40, 50][r]
            return DailyChallenge(kind: .changes(p.0, p.1, count: need), title: "\(p.0) ↔ \(p.1) changes",
                                  detail: "Hit \(need) changes in a 1-Minute Changes round.", icon: "arrow.left.arrow.right")
        case 2:
            let pct = [60, 70, 75, 80, 85][r]
            let p = StrumPattern.library.first { $0.id == skill.strumPattern } ?? StrumPattern.library[0]
            return DailyChallenge(kind: .strum(p.id, pct: pct), title: "Strum: \(p.name)",
                                  detail: "Reach \(pct)% accuracy in the Strum Trainer.", icon: "arrow.up.arrow.down")
        default:
            let need = [5, 8, 10, 12, 15][r]
            return DailyChallenge(kind: .review(count: need), title: "Chord review",
                                  detail: "Practise \(need) different chords in the Chord Trainer today.", icon: "target")
        }
    }

    var dailyDoneToday: Bool { data.dailyDone.contains(Self.todayKey) }

    private func completeDaily() {
        guard !dailyDoneToday else { return }
        data.dailyDone.append(Self.todayKey)
        data.xp += 50
        toast(Toast(title: "Daily challenge complete!", subtitle: "+50 XP · come back tomorrow for a new one", icon: "checkmark.seal.fill"))
        unlock("daily")
    }

    func isComplete(_ step: PathStep) -> Bool {
        switch step.kind {
        case .chords(let c): return c.allSatisfy { mastery($0) >= 3 }
        case .song(let title): return (song(titled: title).flatMap { data.songs[$0.id]?.stars } ?? 0) >= 1
        case .strum(let id): return (data.strums[id] ?? 0) >= 70
        case .tune: return data.tunerUses > 0
        }
    }
}
