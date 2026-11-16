import SwiftUI
import Combine
import QuartzCore

enum HitGrade: String {
    case perfect, great, good, miss
    var points: Int { [300, 200, 100, 0][index] }
    var label: String { ["Perfect!", "Great", "Good", "Miss"][index] }
    var color: Color { [Theme.success, Theme.teal, Theme.info, Theme.danger][index] }
    private var index: Int { ["perfect", "great", "good", "miss"].firstIndex(of: rawValue)! }
}

struct HitResult { var grade: HitGrade; var delta: Double }

struct Feedback: Equatable {
    var id = UUID()
    var text: String
    var color: Color
    var sub: String?
}

/// The fast-changing playhead lives in its own object so only the views that move redraw every frame.
final class PlayClock: ObservableObject {
    @Published var beat: Double
    init(_ b: Double) { beat = b }
}

final class PlayEngine: ObservableObject {
    let song: Song
    let events: [ChordEvent]
    let mode: PlayMode
    let input: InputMode
    let countIn: Double
    let clock: PlayClock
    var strictness: Strictness = .normal
    var maxTempo: Double = 1.25
    @Published var tempo: Double
    @Published var metronome: Bool

    @Published private(set) var countingIn = true
    @Published private(set) var index = 0
    @Published private(set) var results: [HitResult?]
    @Published private(set) var score = 0
    @Published private(set) var streak = 0
    @Published private(set) var maxStreak = 0
    @Published var paused = false
    @Published private(set) var finished = false
    @Published private(set) var feedback: Feedback?
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var waiting = false
    @Published private(set) var hint: String?
    @Published var autoScroll = true
    // section looping
    @Published private(set) var loop: ClosedRange<Int>?
    @Published var autoRamp = true
    @Published private(set) var loopPasses = 0
    @Published private(set) var loopCleanPasses = 0
    var onSpeedUp: (() -> Void)?

    private(set) var activeSeconds: Double = 0
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastClickBeat = Int.min
    private var holdFrames = 0
    private var failFrames = 0
    private var lastOnsetBeat = -Double.infinity
    private var waitStart: CFTimeInterval?
    private var bag = Set<AnyCancellable>()

    init(config: GameConfig) {
        song = config.song
        events = config.song.events
        mode = config.mode
        input = config.input
        tempo = config.tempo
        metronome = config.metronome
        countIn = Double(config.song.beatsPerBar)
        clock = PlayClock(-Double(config.song.beatsPerBar))
        results = Array(repeating: nil, count: config.song.events.count)
        if let si = config.loopSection, let r = sectionRange(containing: events.firstIndex { $0.sectionIndex == si }) {
            loop = r
            index = r.lowerBound
            clock.beat = events[r.lowerBound].start - countIn
        }
    }

    var beat: Double { clock.beat }
    var bpm: Double { Double(song.bpm) * tempo }
    var multiplier: Int { 1 + min(3, streak / 4) }
    var scoring: Bool { mode != .sheet }
    var current: ChordEvent? { index < events.count ? events[index] : nil }
    var next: ChordEvent? { index + 1 < events.count ? events[index + 1] : nil }
    var upcoming: [ChordEvent] { Array(events.dropFirst(index + 2).prefix(3)) }
    var hits: Int { results.compactMap { $0 }.filter { $0.grade != .miss }.count }
    var accuracy: Double { events.isEmpty ? 0 : Double(hits) / Double(events.count) }
    var stars: Int { accuracy >= 0.95 ? 3 : (accuracy >= 0.8 ? 2 : (accuracy >= 0.6 ? 1 : 0)) }
    func count(_ g: HitGrade) -> Int { results.compactMap { $0 }.filter { $0.grade == g }.count }
    var currentPattern: StrumPattern { song.strumPattern(for: current) }

    /// The event the player should be playing right now (allows changing a little early).
    var target: Int? {
        guard index < events.count else { return nil }
        if results[index] == nil { return beat >= events[index].start - 0.75 ? index : nil }
        let n = index + 1
        if let loop, n > loop.upperBound { return nil }
        if n < events.count, results[n] == nil, beat >= events[n].start - 0.75 { return n }
        return nil
    }

    var troubleChords: [String] {
        var misses: [String: Int] = [:]
        for (i, r) in results.enumerated() where r?.grade == .miss { misses[events[i].label, default: 0] += 1 }
        return misses.sorted { $0.value > $1.value }.prefix(4).map(\.key)
    }

    private func sectionRange(containing i: Int?) -> ClosedRange<Int>? {
        guard let i, i < events.count else { return nil }
        let label = events[i].section
        var lo = i, hi = i
        while lo > 0 && events[lo - 1].section == label { lo -= 1 }
        while hi + 1 < events.count && events[hi + 1].section == label { hi += 1 }
        return lo...hi
    }

    func start() {
        stop()
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if input == .mic {
            AudioEngine.shared.frames.receive(on: RunLoop.main).sink { [weak self] f in self?.onFrame(f) }.store(in: &bag)
            AudioEngine.shared.onsets.receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.lastOnsetBeat = self.beat
            }.store(in: &bag)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bag.removeAll()
    }

    func restart() {
        index = loop?.lowerBound ?? 0
        clock.beat = (loop.map { events[$0.lowerBound].start } ?? 0) - countIn
        results = Array(repeating: nil, count: events.count)
        score = 0; streak = 0; maxStreak = 0
        finished = false; paused = false; feedback = nil; hint = nil
        holdFrames = 0; holdProgress = 0; waiting = false; countingIn = true
        loopPasses = 0; loopCleanPasses = 0
        lastClickBeat = Int.min
        start()
    }

    func togglePause() {
        guard !finished else { return }
        paused.toggle()
        lastTick = CACurrentMediaTime()
    }

    func seek(toEvent i: Int) {
        guard i >= 0, i < events.count else { return }
        clock.beat = events[i].start
        index = i
        lastClickBeat = Int(floor(beat))
        waiting = false
    }

    func toggleLoop() {
        if loop != nil {
            loop = nil
            feedback = Feedback(text: "Loop off", color: Theme.textDim, sub: nil)
        } else if let r = sectionRange(containing: index) {
            loop = r
            loopPasses = 0; loopCleanPasses = 0
            feedback = Feedback(text: "Looping \(events[r.lowerBound].section)", color: Theme.accent, sub: autoRamp ? "speeds up when you play it clean" : nil)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        guard !paused, !finished else { return }
        activeSeconds += dt
        var nb = beat + dt * bpm / 60

        if mode == .practice, index < events.count, results[index] == nil, nb >= events[index].start {
            nb = events[index].start
            if !waiting { waiting = true; waitStart = now }
        } else if waiting {
            waiting = false
        }

        let bi = Int(floor(nb))
        if bi > lastClickBeat {
            lastClickBeat = bi
            if (metronome || countingIn) && !waiting {
                let pos = ((bi % song.beatsPerBar) + song.beatsPerBar) % song.beatsPerBar
                GuitarSynth.shared.click(accent: pos == 0)
            }
        }

        if let loop, nb >= events[loop.upperBound].end {
            finishLoopPass(loop)
            return
        }

        while index < events.count && nb >= events[index].end {
            if results[index] == nil && mode == .perform {
                results[index] = HitResult(grade: .miss, delta: 0)
                streak = 0
                feedback = Feedback(text: "Miss", color: Theme.danger, sub: events[index].label)
            }
            index += 1
            holdFrames = 0; failFrames = 0; hint = nil
        }
        clock.beat = nb
        let ci = nb < (loop.map { events[$0.lowerBound].start } ?? 0)
        if ci != countingIn { countingIn = ci }
        if index >= events.count { finish() }
    }

    private func finishLoopPass(_ r: ClosedRange<Int>) {
        if mode == .perform {
            for i in r where results[i] == nil { results[i] = HitResult(grade: .miss, delta: 0) }
        }
        let clean = r.allSatisfy { results[$0].map { $0.grade != .miss } ?? false }
        loopPasses += 1
        if clean {
            loopCleanPasses += 1
            if autoRamp && tempo < maxTempo - 0.001 {
                tempo = min(maxTempo, tempo + 0.05)
                onSpeedUp?()
                feedback = Feedback(text: "Clean! Speeding up", color: Theme.success, sub: "\(Int((tempo * 100).rounded()))% tempo")
            } else {
                feedback = Feedback(text: "Clean pass!", color: Theme.success, sub: "\(loopCleanPasses) in a row")
            }
        } else {
            loopCleanPasses = 0
            feedback = Feedback(text: "Again!", color: Theme.warn, sub: "nail every change to speed up")
        }
        for i in r { results[i] = nil }
        index = r.lowerBound
        clock.beat = events[r.lowerBound].start - Double(song.beatsPerBar)
        lastClickBeat = Int(floor(beat)) - 1
        holdFrames = 0; failFrames = 0; hint = nil
    }

    private func onFrame(_ f: AnalysisFrame) {
        guard !paused, !finished, let t = target else {
            holdProgress = 0
            return
        }
        let e = events[t]
        var ok = false
        var score: Float = 0
        if let midi = e.noteMidi {
            ok = NoteMatcher.evaluate(midi, frame: f) && lastOnsetBeat >= e.start - 0.9
            score = ok ? 1 : 0
        } else if let sym = ChordSymbol.parse(e.chord) {
            let r = ChordTemplates.evaluate(sym, frame: f, strictness: strictness)
            ok = r.ok
            score = r.score
        }
        let need = e.isNote ? 1 : strictness.holdFrames
        if ok { holdFrames += 1; failFrames = 0 } else { holdFrames = max(0, holdFrames - 1) }
        holdProgress = min(1, Double(holdFrames) / Double(need))
        if holdFrames >= need {
            holdFrames = 0
            register(t)
            return
        }
        // they're playing something, but it isn't landing — look for a dead string
        if !ok && f.hasSound && !e.isNote && score > 0.45 {
            failFrames += 1
            if failFrames > 28, hint == nil, let shape = ChordLibrary.displayShape(for: e.chord) {
                hint = StringCheck.hint(shape, quiet: StringCheck.quietStrings(shape, frame: f))
            }
        }
    }

    func manualHit() {
        guard !paused, !finished, let t = target else { return }
        register(t)
    }

    private func register(_ t: Int) {
        guard results[t] == nil else { return }
        let delta = beat - events[t].start
        var grade: HitGrade
        if mode == .practice {
            let waited = waitStart.map { CACurrentMediaTime() - $0 } ?? 0
            grade = waiting ? (waited < 1.5 ? .great : .good) : .perfect
        } else {
            let a = abs(delta)
            grade = a <= 0.6 ? .perfect : (a <= 1.25 ? .great : .good)
        }
        results[t] = HitResult(grade: grade, delta: delta)
        streak += 1
        maxStreak = max(maxStreak, streak)
        let pts = grade.points * multiplier
        score += pts
        holdProgress = 0
        hint = nil
        failFrames = 0
        if waiting && t == index { waiting = false; waitStart = nil }
        feedback = Feedback(text: grade.label, color: grade.color, sub: scoring ? "+\(pts)" : nil)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stop()
    }
}

// MARK: - Container

struct GameContainer: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var audio: AudioEngine
    let config: GameConfig
    @StateObject private var engine: PlayEngine
    @State private var keys = KeyMonitor()
    @State private var saved = false
    @State private var xpEarned = 0
    @State private var newBest = false

    init(config: GameConfig) {
        self.config = config
        _engine = StateObject(wrappedValue: PlayEngine(config: config))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ArtworkView(seed: config.song.id, title: "", genre: config.song.genre, size: 900)
                .blur(radius: 120).opacity(0.22).ignoresSafeArea().allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                GameTopBar(engine: engine, clock: engine.clock, onClose: close)
                if config.mode == .sheet {
                    SheetModeView(engine: engine)
                } else {
                    HighwayModeView(engine: engine)
                }
            }

            if engine.countingIn && !engine.paused {
                CountInOverlay(clock: engine.clock, startBeat: engine.loop.map { engine.events[$0.lowerBound].start } ?? 0)
            }
            if engine.paused && !engine.finished {
                PauseOverlay(engine: engine, onQuit: close)
            }
            if engine.finished {
                ResultsOverlay(engine: engine, xp: xpEarned, newBest: newBest,
                               onAgain: { saved = false; engine.restart() },
                               onWait: { app.play(config.song, mode: .practice, tempo: engine.tempo) },
                               onClose: close)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.finished)
        .animation(.easeOut(duration: 0.2), value: engine.paused)
        .onAppear {
            engine.strictness = progress.strictness
            engine.maxTempo = progress.skill.unlocksTempoAbove100 ? 1.25 : 1.0
            engine.onSpeedUp = { progress.recordLoopSpeedUp() }
            if config.input == .mic { audio.acquire() }
            engine.start()
            keys.start { code in
                switch code {
                case Keys.space, Keys.returnKey:
                    if engine.input == .manual { engine.manualHit() } else { engine.togglePause() }
                    return true
                case Keys.escape:
                    if engine.finished { close() } else { engine.togglePause() }
                    return true
                case Keys.l:
                    engine.toggleLoop()
                    return true
                default: return false
                }
            }
        }
        .onDisappear {
            keys.stop()
            engine.stop()
            if config.input == .mic { audio.release() }
            progress.addPractice(seconds: engine.activeSeconds)
        }
        .onChange(of: engine.finished) { _, done in
            guard done, !saved else { return }
            saved = true
            if engine.scoring {
                newBest = progress.recordSong(config.song, score: engine.score, accuracy: engine.accuracy, stars: engine.stars,
                                              tempo: engine.tempo, mode: engine.mode)
                var chordHits: [String: (Int, Int)] = [:]
                for (i, r) in engine.results.enumerated() where !engine.events[i].isNote {
                    let c = engine.events[i].chord
                    var v = chordHits[c] ?? (0, 0)
                    v.1 += 1
                    if let r, r.grade != .miss { v.0 += 1 }
                    chordHits[c] = v
                }
                for (c, v) in chordHits {
                    let rate = Double(v.0) / Double(max(1, v.1))
                    progress.recordChord(c, hit: rate >= 0.75, time: rate >= 0.75 ? 2.0 : nil)
                }
                xpEarned = engine.score / 25 + engine.stars * 20 + (engine.mode == .practice ? 10 : 25)
            } else {
                xpEarned = 15 + Int(config.song.duration / 20)
                _ = progress.recordSong(config.song, score: 0, accuracy: 0, stars: 0, tempo: engine.tempo, mode: .sheet)
            }
            progress.addXP(xpEarned)
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.25)) { app.activeGame = nil }
    }
}

struct SongProgressBar: View {
    @ObservedObject var clock: PlayClock
    var total: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accentGradient).frame(width: g.size.width * max(0, min(1, clock.beat / max(1, total))))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Song progress")
        .accessibilityValue("\(Int(max(0, min(1, clock.beat / max(1, total))) * 100)) percent")
    }
}

struct GameTopBar: View {
    @EnvironmentObject var audio: AudioEngine
    @ObservedObject var engine: PlayEngine
    let clock: PlayClock
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle(size: 36))
                .help("Quit (Esc pauses)").accessibilityLabel("Quit song")
            ArtworkView(seed: engine.song.id, title: engine.song.title, genre: engine.song.genre, size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.song.title).font(Theme.font(16, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(engine.song.artist) · \(engine.current?.section ?? "Intro")")
                    .font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)

            VStack(spacing: 6) {
                SongProgressBar(clock: clock, total: engine.song.totalBeats)
                HStack {
                    Text(engine.mode.title).font(Theme.font(11, .semibold)).foregroundStyle(Theme.textFaint)
                    if engine.loop != nil {
                        Text("· Loop pass \(engine.loopPasses + 1)\(engine.loopCleanPasses > 0 ? " · \(engine.loopCleanPasses) clean" : "")")
                            .font(Theme.font(11, .semibold)).foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text("\(Int(engine.bpm)) BPM · \(Int((engine.tempo * 100).rounded()))%").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textFaint)
                }
            }
            .frame(maxWidth: .infinity)

            Button { engine.toggleLoop() } label: {
                Label(engine.loop == nil ? "Loop section" : "Looping", systemImage: "repeat")
            }
            .buttonStyle(engine.loop == nil ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
            .help("Loop the current section (L). With auto speed-up, every clean pass adds 5% tempo.")

            if engine.input == .mic { MicStatusView() }
            else { Pill(icon: "keyboard", text: "Space to strum", tint: Theme.accent) }

            if engine.scoring {
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(engine.score.formatted()).font(Theme.font(22, .heavy)).foregroundStyle(Theme.text).monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: engine.score)
                        Text("SCORE").font(Theme.font(9, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    }
                    VStack(spacing: 0) {
                        Text("×\(engine.multiplier)").font(Theme.font(19, .heavy))
                            .foregroundStyle(engine.multiplier > 1 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textDim))
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill").font(.system(size: 9))
                            Text("\(engine.streak)").font(Theme.font(10, .bold))
                        }
                        .foregroundStyle(engine.streak > 0 ? Theme.accent : Theme.textFaint)
                    }
                    .frame(width: 42)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Score \(engine.score), multiplier \(engine.multiplier), streak \(engine.streak)")
            }
            Button { engine.togglePause() } label: { Image(systemName: engine.paused ? "play.fill" : "pause.fill") }
                .buttonStyle(IconButtonStyle(size: 36))
                .accessibilityLabel(engine.paused ? "Resume" : "Pause")
        }
        .padding(.horizontal, 22)
        .padding(.top, 32)
        .padding(.bottom, 14)
    }
}

/// Type-erased button style so we can switch styles conditionally.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Small clock-driven pieces

struct StrumStrip: View {
    @ObservedObject var clock: PlayClock
    var pattern: StrumPattern
    var beatsPerBar: Int
    var waiting: Bool
    var slotWidth: CGFloat
    var showCounts = true

    var body: some View {
        let bar = Double(beatsPerBar)
        let pos = clock.beat.truncatingRemainder(dividingBy: bar)
        let slot: Int? = clock.beat >= 0 && !waiting ? min(pattern.strokes.count - 1, Int(pos * Double(pattern.slotsPerBeat))) : nil
        StrumPatternView(pattern: pattern, activeSlot: slot, slotWidth: slotWidth, showCounts: showCounts)
    }
}

struct BeatDots: View {
    @ObservedObject var clock: PlayClock
    var beatsPerBar: Int
    var waiting: Bool
    var body: some View {
        let pos = clock.beat >= 0 ? Int(floor(clock.beat)) % beatsPerBar : -1
        HStack(spacing: 10) {
            ForEach(0..<beatsPerBar, id: \.self) { i in
                Circle()
                    .fill(i == pos && !waiting ? AnyShapeStyle(i == 0 ? Theme.accentGradient : LinearGradient(colors: [Theme.text, Theme.text], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.track))
                    .frame(width: i == 0 ? 18 : 14, height: i == 0 ? 18 : 14)
                    .scaleEffect(i == pos ? 1.15 : 1)
            }
        }
        .animation(.easeOut(duration: 0.06), value: pos)
        .accessibilityHidden(true)
    }
}

struct BeatsAway: View {
    @ObservedObject var clock: PlayClock
    var start: Double
    var body: some View {
        Text("in \(Int(max(0, start - clock.beat).rounded(.up))) beats")
            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim).monospacedDigit()
    }
}

/// A one-string tab showing where to fret a single note.
struct NoteTabView: View {
    var midi: Int
    var position: (string: Int, fret: Int)? = nil
    var width: CGFloat = 200
    var body: some View {
        let pos = position ?? Theory.position(midi: midi)
        VStack(alignment: .leading, spacing: 0) {
            ForEach((0..<6).reversed(), id: \.self) { s in
                HStack(spacing: 8) {
                    Text(Theory.stringNames[s]).font(Theme.font(11, .bold)).foregroundStyle(Theme.textFaint).frame(width: 14)
                    ZStack {
                        Rectangle().fill(Theme.text.opacity(0.3)).frame(height: 1.2)
                        if pos?.string == s {
                            Text("\(pos!.fret)").font(Theme.font(15, .heavy)).foregroundStyle(Theme.onAccent)
                                .frame(width: 30, height: 24)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accentGradient))
                        }
                    }
                }
                .frame(height: 24)
            }
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel(pos.map { "\(Theory.stringLabels[$0.string]) string, fret \($0.fret)" } ?? "")
    }
}

// MARK: - Highway (Play Along & Wait Mode)

struct HighwayModeView: View {
    @EnvironmentObject var audio: AudioEngine
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject var engine: PlayEngine

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center, spacing: 20) {
                nowCard
                nextCard
                VStack(alignment: .leading, spacing: 10) {
                    Text("THEN").font(Theme.font(10, .heavy)).tracking(1.4).foregroundStyle(Theme.textFaint)
                    ForEach(engine.upcoming) { e in
                        Text(e.label).font(Theme.font(22, .bold)).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 70, height: 300, alignment: .topLeading)
                .accessibilityElement(children: .combine)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 28) {
                if engine.current?.isNote == true {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill").foregroundStyle(Theme.accent)
                        Text("Pick single notes — one clean note each time").font(Theme.font(13, .semibold)).foregroundStyle(Theme.textDim)
                    }
                } else {
                    let p = engine.currentPattern
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down").foregroundStyle(Theme.accent)
                            Text("Strum: \(p.name)").font(Theme.font(13, .semibold)).foregroundStyle(Theme.textDim)
                        }
                        StrumStrip(clock: engine.clock, pattern: p, beatsPerBar: engine.song.beatsPerBar, waiting: engine.waiting,
                                   slotWidth: min(40, 360 / CGFloat(max(1, p.strokes.count))))
                    }
                }
                Spacer()
                BeatDots(clock: engine.clock, beatsPerBar: engine.song.beatsPerBar, waiting: engine.waiting)
            }
            .padding(.horizontal, 30)

            ChordHighway(engine: engine, clock: engine.clock)
                .frame(height: 112)
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
        }
    }

    private var nowCard: some View {
        let e = engine.current
        let label = e?.label ?? ""
        let hit = engine.results.indices.contains(engine.index) ? engine.results[engine.index] : nil
        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(hit != nil ? AnyShapeStyle(hit!.grade.color) : AnyShapeStyle(Theme.accentGradient), lineWidth: 2.5)
                .opacity(hit != nil || engine.waiting ? 1 : 0.5)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(engine.countingIn ? "GET READY" : (engine.waiting ? "PLAY IT TO CONTINUE" : "NOW"))
                        .font(Theme.font(12, .heavy)).tracking(1.6)
                        .foregroundStyle(engine.waiting ? Theme.warn : Theme.accent)
                    if e?.isNote == true {
                        Text(label).font(.system(size: 84, weight: .heavy)).foregroundStyle(Theme.text)
                        if let p = e?.notePosition {
                            Text("\(Theory.stringLabels[p.string].capitalized) string · fret \(p.fret)")
                                .font(Theme.font(15, .medium)).foregroundStyle(Theme.textDim)
                        }
                    } else {
                        ChordChipLarge(name: label)
                        Text(ChordSymbol.parse(label)?.longName.capitalized ?? "")
                            .font(Theme.font(15, .medium)).foregroundStyle(Theme.textDim)
                    }
                    if let h = engine.hint {
                        Label(h, systemImage: "exclamationmark.bubble.fill")
                            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 280, alignment: .leading)
                    } else if engine.input == .mic {
                        HStack(spacing: 8) {
                            ZStack {
                                RingView(progress: engine.holdProgress, lineWidth: 4, gradient: Theme.greenGradient)
                                Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textDim)
                            }
                            .frame(width: 24, height: 24)
                            Text(e?.isNote == true ? "Listening for \(label)…" : (audio.detected.map { "Hearing \($0.name)" } ?? "Listening…"))
                                .font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                        }
                        .padding(.top, 6)
                    } else {
                        Text("Play it, then press Space")
                            .font(Theme.font(13, .medium)).foregroundStyle(Theme.textFaint).padding(.top, 6)
                    }
                }
                Spacer(minLength: 0)
                if let m = e?.noteMidi {
                    NoteTabView(midi: m, position: e?.notePosition, width: 190)
                } else {
                    ChordDiagram(name: label, width: 165, dotColor: hit?.grade.color ?? Theme.accent)
                }
            }
            .padding(28)

            if let f = engine.feedback {
                VStack(spacing: 2) {
                    Text(f.text).font(Theme.font(28, .heavy)).foregroundStyle(f.color)
                    if let s = f.sub { Text(s).font(Theme.font(14, .bold)).foregroundStyle(f.color.opacity(0.8)) }
                }
                .shadow(color: f.color.opacity(0.5), radius: 16)
                .id(f.id)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: -22)
                .modifier(AutoHide(id: f.id))
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(minWidth: 460, maxWidth: 580, minHeight: 300, maxHeight: 300)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: engine.feedback)
    }

    private var nextCard: some View {
        let n = engine.next
        let tip: String? = {
            guard let c = engine.current, let n, !c.isNote, !n.isNote else { return nil }
            return ChordLibrary.transitionTip(from: c.chord, to: n.chord)
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NEXT").font(Theme.font(12, .heavy)).tracking(1.6).foregroundStyle(Theme.textFaint)
                Spacer()
                if let n { BeatsAway(clock: engine.clock, start: n.start) }
            }
            if let n {
                if n.isNote {
                    Text(n.label).font(Theme.font(34, .heavy)).foregroundStyle(Theme.text)
                    if let m = n.noteMidi { NoteTabView(midi: m, position: n.notePosition, width: 190) }
                } else {
                    ChordChip(name: n.chord, size: 26)
                    ChordDiagram(name: n.chord, width: 112, dotColor: Theme.info)
                        .frame(maxWidth: .infinity)
                }
                if let tip {
                    Text(tip).font(Theme.font(11, .medium)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            } else {
                Spacer()
                Text(engine.loop != nil ? "Loop restarts" : "Last chord!").font(Theme.font(18, .bold)).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 250, height: 300)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct AutoHide: ViewModifier {
    var id: UUID
    @State private var visible = true
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .onAppear {
                visible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation(.easeOut(duration: 0.3)) { visible = false } }
            }
    }
}

struct ChordChipLarge: View {
    var name: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Text(name.isEmpty ? "—" : name)
                .font(.system(size: 92, weight: .heavy))
                .foregroundStyle(Theme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Click for the fingering")
        .accessibilityLabel("\(ChordSymbol.parse(name)?.longName ?? name) chord. Show fingering")
        .popover(isPresented: $show) { ChordPopover(name: name) }
    }
}

struct ChordHighway: View {
    @ObservedObject var engine: PlayEngine
    @ObservedObject var clock: PlayClock
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pxPerBeat = w / 16
            let playX = w * 0.16
            let beat = clock.beat
            let target = engine.target
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface.opacity(0.9))
                if let loop = engine.loop {
                    let x1 = playX + (engine.events[loop.lowerBound].start - beat) * pxPerBeat
                    let x2 = playX + (engine.events[loop.upperBound].end - beat) * pxPerBeat
                    Rectangle().fill(Theme.accent.opacity(0.08))
                        .frame(width: max(0, x2 - x1), height: h)
                        .offset(x: x1)
                }
                Canvas { ctx, size in
                    let first = Int(floor(beat - playX / pxPerBeat)) - 1
                    let last = Int(ceil(beat + (size.width - playX) / pxPerBeat)) + 1
                    for b in first...last {
                        let x = playX + (Double(b) - beat) * pxPerBeat
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 12)); p.addLine(to: CGPoint(x: x, y: size.height - 12))
                        let isBar = b % engine.song.beatsPerBar == 0
                        ctx.stroke(p, with: .color(Theme.text.opacity(isBar ? 0.16 : 0.05)), lineWidth: isBar ? 1.5 : 1)
                    }
                }
                ForEach(visible(beat: beat, w: w, playX: playX, pxPerBeat: pxPerBeat)) { e in
                    let x = playX + (e.start - beat) * pxPerBeat
                    let r = engine.results[e.id]
                    let isTarget = target == e.id
                    HStack(spacing: 6) {
                        Text(e.label).font(Theme.font(e.isNote ? 16 : 20, .heavy)).lineLimit(1)
                        if let r { Image(systemName: r.grade == .miss ? "xmark" : "checkmark").font(.system(size: 12, weight: .heavy)) }
                    }
                    .foregroundStyle(r == nil ? (isTarget ? Theme.onAccent : Theme.text) : .white)
                    .padding(.horizontal, e.beats * pxPerBeat > 60 ? 14 : 6)
                    .frame(width: max(24, e.beats * pxPerBeat - 6), height: h - 34, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(r.map { AnyShapeStyle($0.grade.color.opacity(0.85)) } ?? (isTarget ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface3)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                    .offset(x: x + 3, y: 17)
                }
                Rectangle().fill(Theme.text).frame(width: 3, height: h - 8)
                    .shadow(color: Theme.accent, radius: 8)
                    .offset(x: playX - 1.5, y: 4)
                Text("♩ \(Int(engine.bpm))").font(Theme.font(10, .bold)).foregroundStyle(Theme.textFaint)
                    .offset(x: 12, y: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
        }
        .accessibilityElement()
        .accessibilityLabel("Chord timeline")
        .accessibilityValue(engine.current.map { "Now \($0.label)" } ?? "")
    }

    private func visible(beat: Double, w: Double, playX: Double, pxPerBeat: Double) -> [ChordEvent] {
        let lo = beat - playX / pxPerBeat - 8
        let hi = beat + (w - playX) / pxPerBeat + 1
        // events are sorted by start, so a binary search keeps this cheap for long songs
        let ev = engine.events
        var a = 0, b = ev.count
        while a < b { let m = (a + b) / 2; if ev[m].end < lo { a = m + 1 } else { b = m } }
        var out: [ChordEvent] = []
        var i = a
        while i < ev.count && ev[i].start <= hi { out.append(ev[i]); i += 1 }
        return out
    }
}

// MARK: - Auto-scroll chord sheet

struct BarProgress: View {
    @ObservedObject var clock: PlayClock
    var event: ChordEvent
    var isCurrent: Bool
    var past: Bool
    var body: some View {
        let frac = isCurrent ? max(0, min(1, (clock.beat - event.start) / event.beats)) : (past ? 1 : 0)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(isCurrent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textFaint.opacity(0.4)))
                    .frame(width: g.size.width * frac)
            }
        }
        .frame(height: 4)
    }
}

struct SheetModeView: View {
    @ObservedObject var engine: PlayEngine

    private struct Block: Identifiable { let id: Int; let title: String; let events: [ChordEvent] }

    private var blocks: [Block] {
        var out: [Block] = []
        var cur: [ChordEvent] = []
        var title = ""
        for e in engine.events {
            if e.section != title, !cur.isEmpty { out.append(Block(id: out.count, title: title, events: cur)); cur = [] }
            title = e.section
            cur.append(e)
        }
        if !cur.isEmpty { out.append(Block(id: out.count, title: title, events: cur)) }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(blocks) { b in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(b.title.uppercased()).font(Theme.font(12, .heavy)).tracking(1.4).foregroundStyle(Theme.accent)
                                    if let first = b.events.first, first.strum != engine.song.strum {
                                        Text("strum \(first.strum)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textFaint)
                                    }
                                }
                                let rows = stride(from: 0, to: b.events.count, by: 4).map { Array(b.events[$0..<min($0 + 4, b.events.count)]) }
                                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: 10) {
                                        ForEach(row) { e in barCell(e) }
                                        ForEach(0..<(4 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 86) }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 260)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
                .onChange(of: engine.index) { _, i in
                    guard engine.autoScroll, i < engine.events.count else { return }
                    withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.35)) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.stroke))

            sidePanel.frame(width: 290)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func barCell(_ e: ChordEvent) -> some View {
        let isCurrent = e.id == engine.index && !engine.countingIn
        let past = e.id < engine.index
        let hit = engine.results[e.id] != nil
        let inLoop = engine.loop?.contains(e.id) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if e.isNote {
                    Text(e.label).font(Theme.font(18, .bold)).foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                } else {
                    ChordChip(name: e.chord, size: 20, highlighted: isCurrent, dimmed: past && !isCurrent)
                }
                Spacer()
                if hit { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityLabel("Played") }
                if e.beats != Double(engine.song.beatsPerBar) {
                    Text("\(formatBeats(e.beats)) beats").font(Theme.font(10, .semibold)).foregroundStyle(Theme.textFaint)
                }
            }
            BarProgress(clock: engine.clock, event: e, isCurrent: isCurrent, past: past)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isCurrent ? Theme.accent.opacity(0.12) : (inLoop ? Theme.accent.opacity(0.05) : Theme.surface2.opacity(past ? 0.4 : 1))))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isCurrent ? Theme.accent : Theme.stroke, lineWidth: isCurrent ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { engine.seek(toEvent: e.id) }
        .help("Double-click to jump here")
        .id(e.id)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(engine.countingIn ? "STARTING" : "NOW").font(Theme.font(11, .heavy)).tracking(1.4).foregroundStyle(Theme.accent)
                HStack(alignment: .top) {
                    Text(engine.current?.label ?? "—").font(Theme.font(44, .heavy)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.5)
                    Spacer()
                    if let n = engine.next {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("NEXT").font(Theme.font(10, .heavy)).foregroundStyle(Theme.textFaint)
                            Text(n.label).font(Theme.font(22, .bold)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                if let m = engine.current?.noteMidi {
                    NoteTabView(midi: m, position: engine.current?.notePosition, width: 230)
                } else {
                    ChordDiagram(name: engine.current?.chord ?? "", width: 140).frame(maxWidth: .infinity)
                }
            }
            .card(padding: 18, radius: 20)

            if engine.current?.isNote != true {
                VStack(alignment: .leading, spacing: 10) {
                    Text("STRUM · \(engine.currentPattern.name.uppercased())").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    StrumStrip(clock: engine.clock, pattern: engine.currentPattern, beatsPerBar: engine.song.beatsPerBar, waiting: false,
                               slotWidth: min(30, 240 / CGFloat(max(1, engine.currentPattern.strokes.count))))
                }
                .card(padding: 18, radius: 20)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("SCROLL SPEED").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                HStack(spacing: 10) {
                    Button { engine.tempo = max(0.4, engine.tempo - 0.05) } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Slower")
                    VStack(spacing: 0) {
                        Text("\(Int((engine.tempo * 100).rounded()))%").font(Theme.font(22, .heavy)).foregroundStyle(Theme.text).monospacedDigit()
                        Text("\(Int(engine.bpm)) BPM").font(Theme.font(11, .medium)).foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    Button { engine.tempo = min(1.5, engine.tempo + 0.05) } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Faster")
                }
                Toggle("Auto-scroll", isOn: $engine.autoScroll).toggleStyle(.switch).font(Theme.font(13, .medium))
                Toggle("Metronome", isOn: $engine.metronome).toggleStyle(.switch).font(Theme.font(13, .medium))
                Text("Double-click any bar to jump there. Press L to loop the current section.")
                    .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
            }
            .card(padding: 18, radius: 20)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Overlays

struct CountInOverlay: View {
    @ObservedObject var clock: PlayClock
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var startBeat: Double
    var body: some View {
        let n = Int(ceil(startBeat - clock.beat))
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("\(max(1, n))")
                    .font(.system(size: 160, weight: .heavy))
                    .foregroundStyle(Theme.accentGradient)
                    .id(n)
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.4).combined(with: .opacity))
                Text("Get your fingers ready…").font(Theme.font(18, .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .animation(.easeOut(duration: 0.18), value: n)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Count in \(max(1, n))")
    }
}

struct PauseOverlay: View {
    @ObservedObject var engine: PlayEngine
    var onQuit: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Paused").font(Theme.font(34, .heavy)).foregroundStyle(Theme.text)
                VStack(spacing: 6) {
                    Text("TEMPO").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    Segmented(options: [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25], selection: $engine.tempo) { "\(Int(($0 * 100).rounded()))%" }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Metronome click", isOn: $engine.metronome)
                    Toggle("Speed up 5% after each clean loop", isOn: $engine.autoRamp)
                }
                .toggleStyle(.switch).font(Theme.font(14, .medium)).frame(width: 320)
                HStack(spacing: 12) {
                    Button("Quit", action: onQuit).buttonStyle(SecondaryButtonStyle(large: true))
                    Button(engine.loop == nil ? "Loop This Section" : "Stop Looping") { engine.toggleLoop() }.buttonStyle(SecondaryButtonStyle(large: true))
                    Button("Restart") { engine.restart() }.buttonStyle(SecondaryButtonStyle(large: true))
                    Button("Resume") { engine.togglePause() }.buttonStyle(PrimaryButtonStyle(large: true))
                }
                Text(engine.input == .manual ? "Esc to resume · L to loop" : "Space or Esc to resume · L to loop").font(Theme.font(12)).foregroundStyle(Theme.textFaint)
            }
            .padding(36)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

struct ResultsOverlay: View {
    @ObservedObject var engine: PlayEngine
    var xp: Int
    var newBest: Bool
    var onAgain: () -> Void
    var onWait: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 22) {
                if engine.scoring {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { i in
                            Image(systemName: i < engine.stars ? "star.fill" : "star")
                                .font(.system(size: i == 1 ? 54 : 42, weight: .bold))
                                .foregroundStyle(i < engine.stars ? AnyShapeStyle(LinearGradient(colors: [Theme.warn, Theme.accent], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.textFaint))
                                .offset(y: i == 1 ? -10 : 0)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(engine.stars) of 3 stars")
                    Text(headline).font(Theme.font(32, .heavy)).foregroundStyle(Theme.text)
                    if newBest {
                        Label("New personal best!", systemImage: "trophy.fill")
                            .font(Theme.font(13, .bold)).foregroundStyle(Theme.warn)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.warn.opacity(0.15)))
                    }
                    HStack(spacing: 14) {
                        stat(engine.score.formatted(), "Score")
                        stat("\(Int(engine.accuracy * 100))%", "Accuracy")
                        stat("\(engine.maxStreak)", "Best streak")
                        stat("+\(xp)", "XP")
                    }
                    HStack(spacing: 16) {
                        gradeCount(.perfect); gradeCount(.great); gradeCount(.good); gradeCount(.miss)
                    }
                    if !engine.troubleChords.isEmpty {
                        VStack(spacing: 8) {
                            Text("Work on these").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
                            HStack(spacing: 8) {
                                ForEach(engine.troubleChords, id: \.self) { c in
                                    if ChordSymbol.parse(c) != nil { ChordChip(name: c, size: 15) }
                                    else { Text(c).font(Theme.font(15, .bold)).foregroundStyle(Theme.text) }
                                }
                            }
                            Text("Tip: pause and press “Loop This Section” on the part that tripped you up.")
                                .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                } else {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Theme.greenGradient)
                    Text("Song complete").font(Theme.font(32, .heavy)).foregroundStyle(Theme.text)
                    Text("+\(xp) XP · \(engine.hits) of \(engine.events.count) chords heard").font(Theme.font(15)).foregroundStyle(Theme.textDim)
                }
                HStack(spacing: 12) {
                    Button("Done", action: onClose).buttonStyle(SecondaryButtonStyle(large: true))
                    if engine.scoring && engine.mode == .perform && engine.accuracy < 0.6 {
                        Button("Try Wait Mode", action: onWait).buttonStyle(SecondaryButtonStyle(large: true))
                    }
                    Button { onAgain() } label: { Label("Play Again", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                }
            }
            .padding(40)
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
    }

    private var headline: String {
        switch engine.stars {
        case 3: return "Flawless!"
        case 2: return "Great job!"
        case 1: return "Nice work!"
        default: return "Keep practising!"
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(Theme.font(22, .heavy)).foregroundStyle(Theme.text).monospacedDigit()
            Text(l).font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface2))
        .accessibilityElement(children: .combine)
    }

    private func gradeCount(_ g: HitGrade) -> some View {
        HStack(spacing: 5) {
            Circle().fill(g.color).frame(width: 8, height: 8)
            Text("\(g.label.replacingOccurrences(of: "!", with: "")) \(engine.count(g))").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
        }
    }
}
