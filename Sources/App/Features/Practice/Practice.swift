import SwiftUI
import Combine
import QuartzCore

// MARK: - Shared listening helper

/// Listens for one target chord at a time and fires when it's held.
@Observable
final class ChordListener {
    var holdProgress: Double = 0
    var target: String? { didSet { hint = nil; fails = 0 } }
    var hint: String?
    @ObservationIgnored var strictness: Strictness = .normal
    @ObservationIgnored var onHit: (() -> Void)?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var fails = 0
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    func start() {
        bag.removeAll()
        AudioEngine.shared.frames.receive(on: RunLoop.main).sink { [weak self] f in self?.frame(f) }.store(in: &bag)
    }
    func stop() { bag.removeAll(); holdProgress = 0 }
    func reset() { frames = 0; fails = 0; holdProgress = 0; hint = nil }

    private func frame(_ f: AnalysisFrame) {
        guard let t = target, let sym = ChordSymbol.parse(t) else { return }
        let r = ChordTemplates.evaluate(sym, frame: f, strictness: strictness)
        frames = r.ok ? frames + 1 : max(0, frames - 1)
        if !r.ok && f.hasSound && r.score > 0.45 {
            fails += 1
            if fails > 28, hint == nil, let shape = ChordLibrary.displayShape(for: t) {
                hint = StringCheck.hint(shape, quiet: StringCheck.quietStrings(shape, frame: f))
            }
        } else if r.ok { fails = 0 }
        holdProgress = min(1, Double(frames) / Double(strictness.holdFrames))
        if frames >= strictness.holdFrames {
            frames = 0
            holdProgress = 0
            onHit?()
        }
    }
}

// MARK: - Chord Trainer

struct ChordTrainerView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
    @Environment(AudioEngine.self) var audio

    enum Phase { case setup, running, done }
    @State private var phase: Phase = .setup
    @State private var deckID = ""
    @State private var rounds = 10
    @State private var memoryMode = false
    @State private var pool: [String] = []
    @State private var round = 0
    @State private var current = ""
    @State private var roundStart = Date()
    @State private var results: [(chord: String, time: Double?)] = []
    @State private var flash: Color? = nil
    @State private var revealed = false
    @State private var listener = ChordListener()
    @State private var keys = KeyMonitor()
    @State private var sessionStart = Date()

    private var decks: [(id: String, name: String, icon: String, level: Int, chords: [String])] {
        var d = ChordLibrary.decks
        d.insert(("weak", "My Weak Spots", "scope", 0, progress.weakestChords(8)), at: 0)
        let due = progress.dueChords
        if !due.isEmpty { d.insert(("due", "Due for Review (\(due.count))", "clock.arrow.circlepath", 0, Array(due.prefix(12))), at: 0) }
        if let p = app.trainerPreset, !p.isEmpty { d.insert(("preset", "Selected Chords", "star.fill", 0, p), at: 0) }
        return d
    }

    var body: some View {
        Group {
            switch phase {
            case .setup: setup
            case .running: running
            case .done: summary
            }
        }
        .onAppear {
            if deckID.isEmpty { deckID = app.trainerPreset != nil ? "preset" : (progress.dueChords.isEmpty ? progress.skill.trainerDeck : "due") }
            memoryMode = progress.skill.rank >= 3
        }
        .onChange(of: app.trainerPreset) { _, p in if p != nil { deckID = "preset"; phase = .setup } }
        .onDisappear { endListening() }
    }

    private var setup: some View {
        Page {
            PageHeader(title: "Chord Trainer", subtitle: "A chord flashes up — play it as fast as you can. Weak chords come up more often.") {
                InputModePicker(mode: Bindable(app).inputMode)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                ForEach(decks, id: \.id) { d in
                    Button { deckID = d.id } label: { deckCard(d) }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ROUNDS").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    Segmented(options: [5, 10, 20], selection: $rounds) { "\($0)" }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("MEMORY MODE").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    Toggle("Hide diagrams (reveal for a hint)", isOn: $memoryMode).toggleStyle(.switch).font(Theme.font(13))
                }
                Spacer()
                Button { start() } label: { Label("Start Training", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .disabled(selectedChords.isEmpty)
            }
            .card(padding: 20, radius: 20)
        }
    }

    private var selectedChords: [String] { decks.first { $0.id == deckID }?.chords ?? [] }

    private func deckCard(_ d: (id: String, name: String, icon: String, level: Int, chords: [String])) -> some View {
        let sel = d.id == deckID
        let avg = d.chords.isEmpty ? 0 : Double(d.chords.map { progress.mastery($0) }.reduce(0, +)) / Double(d.chords.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sel ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface3))
                    Image(systemName: d.icon).font(.system(size: 15, weight: .bold)).foregroundStyle(sel ? .white : Theme.textDim)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(Theme.font(15, .bold)).foregroundStyle(Theme.text)
                    Text("\(d.chords.count) chords").font(Theme.font(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if d.id == progress.skill.trainerDeck {
                    Text("FOR YOU").font(Theme.font(9, .heavy)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
            }
            Text(d.chords.joined(separator: "  ")).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textDim).lineLimit(2)
            ProgressView(value: avg, total: 5).tint(Theme.success)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(sel ? Theme.accent : Theme.stroke, lineWidth: sel ? 2 : 1))
    }

    private var running: some View {
        VStack(spacing: 26) {
            HStack {
                Button { endListening(); phase = .setup } label: { Label("End", systemImage: "xmark") }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Text("Round \(round + 1) of \(rounds)").font(Theme.font(15, .semibold)).foregroundStyle(Theme.textDim)
                Spacer()
                if app.inputMode == .mic { MicStatusView() } else { Pill(icon: "keyboard", text: "Space = played it", tint: Theme.accent) }
            }
            HStack(spacing: 4) {
                ForEach(0..<rounds, id: \.self) { i in
                    Capsule().fill(i < results.count ? (results[i].time != nil ? Theme.success : Theme.danger) : (i == round ? Theme.accent : Theme.track))
                        .frame(height: 6)
                }
            }
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(flash ?? Theme.stroke, lineWidth: flash == nil ? 1 : 4)
                HStack(spacing: 60) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PLAY").font(Theme.font(13, .heavy)).tracking(1.8).foregroundStyle(Theme.accent)
                        Text(current).font(.system(size: 120, weight: .heavy)).foregroundStyle(Theme.text)
                        Text(ChordSymbol.parse(current)?.longName.capitalized ?? "").font(Theme.font(17)).foregroundStyle(Theme.textDim)
                        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                            Text(String(format: "%.1fs", ctx.date.timeIntervalSince(roundStart)))
                                .font(Theme.font(28, .bold)).foregroundStyle(Theme.textDim).monospacedDigit()
                        }
                        if app.inputMode == .mic {
                            HStack(spacing: 10) {
                                RingView(progress: listener.holdProgress, lineWidth: 5, gradient: Theme.greenGradient).frame(width: 26, height: 26)
                                Text(audio.detected.map { "Hearing \($0.name)" } ?? "Strum the chord and let it ring…")
                                    .font(Theme.font(14, .medium)).foregroundStyle(Theme.textDim)
                            }
                            if let h = listener.hint {
                                Label(h, systemImage: "exclamationmark.bubble.fill")
                                    .font(Theme.font(13, .semibold)).foregroundStyle(Theme.warn)
                                    .frame(maxWidth: 360, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    ZStack {
                        ChordDiagram(name: current, width: 210, dotColor: flash ?? Theme.accent)
                            .blur(radius: memoryMode && !revealed ? 14 : 0)
                            .opacity(memoryMode && !revealed ? 0.35 : 1)
                        if memoryMode && !revealed {
                            Button { revealed = true } label: { Label("Show hint", systemImage: "eye.fill") }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .padding(44)
            }
            .frame(maxWidth: 900, maxHeight: 420)
            .animation(.easeOut(duration: 0.2), value: flash)
            Spacer()
            HStack(spacing: 12) {
                if let s = ChordLibrary.displayShape(for: current) {
                    Button { GuitarSynth.shared.strum(s) } label: { Label("Hear it", systemImage: "speaker.wave.2.fill") }.buttonStyle(SecondaryButtonStyle())
                }
                Button { advance(hit: false) } label: { Label("Skip", systemImage: "forward.fill") }.buttonStyle(SecondaryButtonStyle())
                if app.inputMode == .manual {
                    Button { advance(hit: true) } label: { Label("I played it", systemImage: "checkmark") }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var summary: some View {
        let times = results.compactMap(\.time)
        let avg = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        return Page {
            PageHeader(title: "Session complete", subtitle: "\(times.count) of \(results.count) chords played · average \(String(format: "%.1f", avg))s") { EmptyView() }
            HStack(spacing: 14) {
                StatTile(icon: "checkmark.circle.fill", value: "\(times.count)/\(results.count)", label: "Correct", tint: Theme.success)
                StatTile(icon: "timer", value: String(format: "%.1fs", avg), label: "Avg. reaction", tint: Theme.info)
                StatTile(icon: "bolt.fill", value: String(format: "%.1fs", times.min() ?? 0), label: "Fastest", tint: Theme.accent)
                StatTile(icon: "sparkles", value: "+\(xpFor(times.count))", label: "XP earned", tint: Theme.violet)
            }
            VStack(spacing: 8) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 14) {
                        Image(systemName: r.time != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.time != nil ? Theme.success : Theme.danger)
                        ChordChip(name: r.chord, size: 14)
                        Spacer()
                        Text(r.time.map { String(format: "%.2fs", $0) } ?? "skipped").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textDim).monospacedDigit()
                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { i in Circle().fill(i < progress.mastery(r.chord) ? Theme.success : Theme.track).frame(width: 6, height: 6) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                }
            }
            HStack {
                Button("Back to decks") { phase = .setup }.buttonStyle(SecondaryButtonStyle(large: true))
                Button { start() } label: { Label("Go again", systemImage: "arrow.counterclockwise") }.buttonStyle(PrimaryButtonStyle(large: true))
            }
        }
    }

    private func xpFor(_ n: Int) -> Int { n * 6 + 10 }

    private func start() {
        pool = selectedChords
        guard !pool.isEmpty else { return }
        results = []
        round = 0
        sessionStart = Date()
        phase = .running
        listener.strictness = progress.strictness
        listener.onHit = { advance(hit: true) }
        if app.inputMode == .mic { audio.acquire(); listener.start() }
        keys.start { code in
            if code == Keys.space || code == Keys.returnKey { if app.inputMode == .manual { advance(hit: true) }; return true }
            if code == Keys.escape { endListening(); phase = .setup; return true }
            return false
        }
        next()
    }

    private func next() {
        let weights = pool.map { Double(6 - progress.mastery($0)) }
        var pick = current
        var guardCount = 0
        while (pick == current || pick.isEmpty) && guardCount < 20 {
            var r = Double.random(in: 0..<weights.reduce(0, +))
            for (i, w) in weights.enumerated() { r -= w; if r <= 0 { pick = pool[i]; break } }
            guardCount += 1
            if pool.count == 1 { pick = pool[0]; break }
        }
        current = pick
        revealed = false
        roundStart = Date()
        listener.reset()
        listener.target = current
    }

    private func advance(hit: Bool) {
        guard phase == .running, flash == nil else { return }
        let t = Date().timeIntervalSince(roundStart)
        results.append((current, hit ? t : nil))
        progress.recordChord(current, hit: hit && !(memoryMode && revealed && t > 4), time: hit ? t : nil)
        flash = hit ? Theme.success : Theme.danger
        listener.target = nil
        if hit, let s = ChordLibrary.displayShape(for: current), app.inputMode == .manual { GuitarSynth.shared.strum(s) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            flash = nil
            round += 1
            if round >= rounds {
                progress.addXP(xpFor(results.filter { $0.time != nil }.count))
                endListening()
                phase = .done
            } else { next() }
        }
    }

    private func endListening() {
        keys.stop()
        if listener.target != nil || phase == .running {
            listener.stop()
            listener.target = nil
            if app.inputMode == .mic && phase == .running { audio.release() }
            progress.addPractice(seconds: Date().timeIntervalSince(sessionStart))
        }
    }
}

// MARK: - 1-Minute Changes

struct ChangesView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
    @Environment(AudioEngine.self) var audio
    enum Phase { case setup, countdown, running, done }
    @State private var phase: Phase = .setup
    @State private var a = "G"
    @State private var b = "C"
    @State private var duration = 60
    @State private var count = 0
    @State private var expectA = true
    @State private var endTime = Date()
    @State private var countdown = 3
    @State private var wasBest = false
    @State private var listener = ChordListener()
    @State private var keys = KeyMonitor()
    @State private var ticker: Timer?

    private var pairKey: String { [a, b].sorted().joined(separator: "↔") }

    private var presets: [(String, String)] {
        switch progress.skill.rank {
        case 0, 1: return [("Em", "Am"), ("G", "C"), ("C", "D"), ("D", "A"), ("E", "A"), ("Am", "E"), ("G", "D"), ("D", "Em")]
        case 2: return [("C", "F"), ("G", "Bm"), ("A", "F#m"), ("D", "Bm"), ("Em7", "Cadd9"), ("E", "B7"), ("Am", "Dm"), ("F", "G")]
        default: return [("F", "Bb"), ("Bm", "F#m"), ("C#m", "B"), ("Cmaj7", "Fmaj7"), ("Dm7", "G7"), ("Bm7b5", "E9"), ("Gm", "Cm"), ("Cdim7", "Caug")]
        }
    }

    var body: some View {
        Group {
            if phase == .setup { setup } else { session }
        }
        .onDisappear { stopAll() }
    }

    private var setup: some View {
        Page {
            PageHeader(title: "1-Minute Changes", subtitle: "Switch between two chords as many times as you can. The fastest way to build muscle memory.") {
                InputModePicker(mode: Bindable(app).inputMode)
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Suggested pairs for \(progress.skill.title.lowercased()) players")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(presets, id: \.0) { p in
                        let key = [p.0, p.1].sorted().joined(separator: "↔")
                        let sel = a == p.0 && b == p.1
                        Button { a = p.0; b = p.1 } label: {
                            HStack {
                                Text("\(p.0)  ↔  \(p.1)").font(Theme.font(18, .bold)).foregroundStyle(Theme.text)
                                Spacer()
                                if let best = progress.data.changes[key] {
                                    Text("Best \(best)").font(Theme.font(12, .semibold)).foregroundStyle(Theme.success)
                                }
                            }
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(sel ? Theme.accent : Theme.stroke, lineWidth: sel ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 30) {
                chordPicker("First chord", $a)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.accent)
                chordPicker("Second chord", $b)
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text("DURATION").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    Segmented(options: [30, 60, 90], selection: $duration) { "\($0)s" }
                }
                Button { begin() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .disabled(a == b)
            }
            .card(padding: 22, radius: 20)
        }
    }

    private func chordPicker(_ label: String, _ v: Binding<String>) -> some View {
        HStack(spacing: 14) {
            ChordDiagram(name: v.wrappedValue, width: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased()).font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Picker("", selection: v) {
                    ForEach(ChordLibrary.shapes) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
    }

    private var session: some View {
        VStack(spacing: 30) {
            HStack {
                Button { stopAll(); phase = .setup } label: { Label("End", systemImage: "xmark") }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                if app.inputMode == .mic { MicStatusView() } else { Pill(icon: "keyboard", text: "Space each time you change", tint: Theme.accent) }
            }
            Spacer()
            if phase == .countdown {
                Text("\(countdown)").font(.system(size: 160, weight: .heavy)).foregroundStyle(Theme.accentGradient)
                Text("Get ready on \(a)").font(Theme.font(20, .medium)).foregroundStyle(Theme.textDim)
            } else {
                HStack(spacing: 40) {
                    changeCard(a, active: expectA && phase == .running)
                    VStack(spacing: 8) {
                        Text("\(count)").font(.system(size: 110, weight: .heavy)).foregroundStyle(Theme.text)
                            .contentTransition(.numericText()).animation(.snappy, value: count)
                        Text("changes").font(Theme.font(15, .semibold)).foregroundStyle(Theme.textDim)
                        if phase == .running {
                            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                                let left = max(0, endTime.timeIntervalSince(ctx.date))
                                ZStack {
                                    RingView(progress: left / Double(duration), lineWidth: 8)
                                    Text("\(Int(left.rounded(.up)))s").font(Theme.font(20, .bold)).foregroundStyle(Theme.text).monospacedDigit()
                                }
                                .frame(width: 90, height: 90)
                            }
                        } else {
                            VStack(spacing: 8) {
                                if wasBest { Label("New record!", systemImage: "trophy.fill").font(Theme.font(15, .bold)).foregroundStyle(Theme.warn) }
                                Text("Best: \(progress.data.changes[pairKey] ?? count)").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textDim)
                                HStack {
                                    Button("Change chords") { phase = .setup }.buttonStyle(SecondaryButtonStyle())
                                    Button { begin() } label: { Label("Again", systemImage: "arrow.counterclockwise") }.buttonStyle(PrimaryButtonStyle())
                                }
                            }
                        }
                    }
                    .frame(width: 260)
                    changeCard(b, active: !expectA && phase == .running)
                }
                if let tip = ChordLibrary.transitionTip(from: expectA ? b : a, to: expectA ? a : b) {
                    Label(tip, systemImage: "lightbulb.fill")
                        .font(Theme.font(14, .medium)).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: 640)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                }
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func changeCard(_ c: String, active: Bool) -> some View {
        VStack(spacing: 14) {
            Text(c).font(Theme.font(56, .heavy)).foregroundStyle(active ? Theme.text : Theme.textFaint)
            ChordDiagram(name: c, width: 170, dotColor: active ? Theme.accent : Theme.textFaint)
            if active && app.inputMode == .mic {
                RingView(progress: listener.holdProgress, lineWidth: 5, gradient: Theme.greenGradient).frame(width: 28, height: 28)
            } else { Color.clear.frame(height: 28) }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.stroke), lineWidth: active ? 3 : 1))
        .scaleEffect(active ? 1.04 : 0.96)
        .animation(.spring(response: 0.3), value: active)
    }

    private func begin() {
        count = 0
        expectA = true
        wasBest = false
        countdown = 3
        phase = .countdown
        listener.strictness = progress.strictness
        listener.onHit = { changed() }
        if app.inputMode == .mic { audio.acquire(); listener.start() }
        keys.start { code in
            if code == Keys.space || code == Keys.returnKey { if app.inputMode == .manual { changed() }; return true }
            return false
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if phase == .countdown {
                GuitarSynth.shared.click(accent: countdown == 1)
                countdown -= 1
                if countdown <= 0 {
                    phase = .running
                    endTime = Date().addingTimeInterval(Double(duration))
                    listener.target = b
                    expectA = false
                }
            } else if phase == .running, Date() >= endTime {
                t.invalidate()
                finish()
            }
        }
    }

    private func changed() {
        guard phase == .running else { return }
        count += 1
        expectA.toggle()
        listener.reset()
        listener.target = expectA ? a : b
    }

    private func finish() {
        phase = .done
        wasBest = progress.recordChanges(pairKey: pairKey, count: Int((Double(count) * 60 / Double(duration)).rounded()))
        progress.addXP(count * 2 + 10)
        progress.addPractice(seconds: Double(duration))
        progress.recordChord(a, hit: count >= 20, time: count >= 20 ? 60.0 / Double(max(1, count)) : nil)
        progress.recordChord(b, hit: count >= 20, time: count >= 20 ? 60.0 / Double(max(1, count)) : nil)
        releaseInput()
    }

    private func releaseInput() {
        keys.stop()
        if listener.target != nil {
            listener.stop()
            listener.target = nil
            if app.inputMode == .mic { audio.release() }
        }
    }

    private func stopAll() {
        ticker?.invalidate()
        if phase == .countdown || phase == .running { releaseInput() }
        if phase != .setup && phase != .done { phase = .setup }
    }
}

// MARK: - Strum Trainer

@Observable
final class StrumSession {
    var pattern: StrumPattern
    var bpm: Double
    var running = false
    var slot: Int? = nil
    var grades: [Int: StrumGrade] = [:]
    var lastBarAccuracy: Double? = nil
    var bars = 0
    var totalScore = 0.0
    var totalPossible = 0.0
    var avgOffsetMs: Double = 0
    var lastGrade: StrumGrade?
    var perfectBarsInRow = 0
    @ObservationIgnored var demo = false
    @ObservationIgnored var metronome = true
    @ObservationIgnored var chord: ChordShape?
    @ObservationIgnored var window: Double = 0.12
    @ObservationIgnored var useMic = true
    @ObservationIgnored var latency: Double = 0          // seconds to subtract from detected strum times
    @ObservationIgnored var checkDirection = false

    @ObservationIgnored private var t0: Double = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSlotGlobal = Int.min
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var offsets: [Double] = []
    @ObservationIgnored private(set) var activeSeconds: Double = 0

    init(pattern: StrumPattern, bpm: Double) { self.pattern = pattern; self.bpm = bpm }

    var slotDur: Double { 60 / bpm / Double(pattern.slotsPerBeat) }
    var barDur: Double { slotDur * Double(pattern.strokes.count) }
    var accuracy: Double { totalPossible > 0 ? totalScore / totalPossible : 0 }

    func start() {
        stop()
        grades = [:]; bars = 0; totalScore = 0; totalPossible = 0; lastBarAccuracy = nil; offsets = []; perfectBarsInRow = 0
        t0 = CACurrentMediaTime() + barDur   // one bar count-in
        lastSlotGlobal = Int.min
        running = true
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if useMic {
            AudioEngine.shared.onsets.receive(on: RunLoop.main).sink { [weak self] o in self?.onset(o.time, direction: o.direction) }.store(in: &bag)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        bag.removeAll()
        running = false
        slot = nil
    }

    func tap() { onset(CACurrentMediaTime(), direction: nil) }

    var inCountIn: Bool { CACurrentMediaTime() < t0 }

    private func tick() {
        let now = CACurrentMediaTime()
        let pos = now - t0
        let g = Int(floor(pos / slotDur))
        guard g != lastSlotGlobal else { return }
        let prevBar = lastSlotGlobal == Int.min ? Int.min : Int(floor(Double(lastSlotGlobal) / Double(pattern.strokes.count)))
        lastSlotGlobal = g
        let n = pattern.strokes.count
        let s = ((g % n) + n) % n
        let bar = Int(floor(Double(g) / Double(n)))
        if bar != prevBar && prevBar != Int.min && prevBar >= 0 { closeBar() }
        if bar != prevBar && bar >= 0 { grades = [:] }
        if pos >= 0 { activeSeconds += slotDur }
        slot = pos >= 0 ? s : nil
        if s % pattern.slotsPerBeat == 0 && (metronome || pos < 0) {
            GuitarSynth.shared.click(accent: s == 0)
        }
        if demo, pos >= 0, let c = chord {
            let st = pattern.strokes[s]
            if st.isStrum { GuitarSynth.shared.strum(c, stroke: st, ring: 1.2) }
        }
    }

    private func closeBar() {
        var score = 0.0, possible = 0.0, perfect = true
        for (i, st) in pattern.strokes.enumerated() where st.isStrum {
            possible += 1
            switch grades[i] {
            case .perfect: score += 1
            case .wrongWay: score += 0.5; perfect = false
            case .early, .late: score += 0.6; perfect = false
            default: perfect = false
            }
        }
        let extras = grades.values.filter { $0 == .extra }.count
        score = max(0, score - Double(extras) * 0.5)
        if extras > 0 { perfect = false }
        lastBarAccuracy = possible > 0 ? score / possible : 0
        totalScore += score; totalPossible += possible
        bars += 1
        perfectBarsInRow = perfect ? perfectBarsInRow + 1 : 0
    }

    private func onset(_ raw: Double, direction: StrumStroke?) {
        guard running, !demo else { return }
        let t = raw - latency
        let pos = t - t0
        guard pos > -slotDur * 0.5 else { return }
        let n = pattern.strokes.count
        let nearest = Int((pos / slotDur).rounded())
        let s = ((nearest % n) + n) % n
        let currentBar = Int(floor(Double(lastSlotGlobal) / Double(n)))
        let nearestBar = Int(floor(Double(nearest) / Double(n)))
        // only grade slots in the bar on screen
        guard nearestBar == currentBar else { return }
        let diff = pos - Double(nearest) * slotDur
        let stroke = pattern.strokes[s]
        if !stroke.isStrum || abs(diff) > window {
            if grades[s] == nil, !stroke.isStrum { grades[s] = .extra; lastGrade = .extra }
            return
        }
        guard grades[s] == nil else { return }
        var g: StrumGrade = abs(diff) <= window * 0.5 ? .perfect : (diff < 0 ? .early : .late)
        if checkDirection, let d = direction, stroke == .down || stroke == .up, d != stroke { g = .wrongWay }
        grades[s] = g
        lastGrade = g
        offsets.append(diff * 1000)
        if offsets.count > 24 { offsets.removeFirst() }
        avgOffsetMs = offsets.reduce(0, +) / Double(offsets.count)
    }
}

struct StrumTrainerView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
    @Environment(AudioEngine.self) var audio
    @State private var session = StrumSession(pattern: StrumPattern.library[2], bpm: 80)
    @State private var chordName = "G"
    @State private var demo = false
    @State private var metronome = true
    @State private var keys = KeyMonitor()
    @State private var micHeld = false

    var body: some View {
        Page {
            PageHeader(title: "Strum Trainer", subtitle: "Pick a pattern, strum along with the click, and get timing feedback on every stroke.") {
                InputModePicker(mode: Bindable(app).inputMode).disabled(session.running)
            }
            HStack(alignment: .top, spacing: 20) {
                patternList.frame(width: 260)
                VStack(spacing: 20) {
                    stage
                    controls
                }
            }
        }
        .onAppear {
            let pref = app.strumPreset ?? progress.skill.strumPattern
            if let p = StrumPattern.library.first(where: { $0.id == pref || $0.pattern == pref }) { session.pattern = p }
            else if let raw = app.strumPreset { session.pattern = StrumPattern.match(raw, beatsPerBar: raw.count == 6 ? 3 : 4) }
            if let c = app.strumChordPreset { chordName = c }
            app.strumPreset = nil; app.strumChordPreset = nil
            session.bpm = [60, 70, 85, 95, 100][progress.skill.rank]
        }
        .onDisappear { stop() }
    }

    private var patternList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PATTERNS").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint).padding(.bottom, 4)
            ForEach(StrumPattern.library) { p in
                let sel = p.pattern == session.pattern.pattern
                Button {
                    stop(); session.pattern = p
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                                if p.id == progress.skill.strumPattern {
                                    Text("FOR YOU").font(Theme.font(8, .heavy)).foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Theme.accent.opacity(0.15)))
                                }
                            }
                            Text(p.pattern.replacingOccurrences(of: "-", with: "·")).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        if let best = progress.data.strums[p.id] {
                            Text("\(best)%").font(Theme.font(11, .bold)).foregroundStyle(best >= 70 ? Theme.success : Theme.textDim)
                        }
                        DifficultyBadge(level: p.level, compact: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(sel ? Theme.accent.opacity(0.12) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(sel ? Theme.accent : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 14, radius: 20)
    }

    private var stage: some View {
        let p = session.pattern
        return VStack(spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(Theme.font(28, .heavy)).foregroundStyle(Theme.text)
                    Text("\(p.feel) · \(p.subdivisionName) · \(p.beatsPerBar)/4").font(Theme.font(14)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if let g = session.lastGrade, session.running {
                    Text(g.label).font(Theme.font(22, .heavy)).foregroundStyle(g.color).id(UUID())
                }
            }
            StrumPatternView(pattern: p, activeSlot: session.slot, grades: session.grades,
                             slotWidth: min(64, 640 / CGFloat(max(1, p.strokes.count))))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            if session.running && session.inCountIn {
                Text("Count-in… start on beat 1").font(Theme.font(14, .semibold)).foregroundStyle(Theme.warn)
            }
            Text(p.tip).font(Theme.font(13)).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatTile(icon: "percent", value: session.totalPossible > 0 ? "\(Int(session.accuracy * 100))%" : "—", label: "Accuracy", tint: Theme.success)
                StatTile(icon: "chart.bar.fill", value: session.lastBarAccuracy.map { "\(Int($0 * 100))%" } ?? "—", label: "Last bar", tint: Theme.info)
                StatTile(icon: "timer", value: session.totalPossible > 0 ? timingText : "—", label: "Timing", tint: Theme.warn)
                StatTile(icon: "flame.fill", value: "\(session.perfectBarsInRow)", label: "Perfect bars", tint: Theme.accent)
            }
        }
        .card(padding: 24, radius: 22)
    }

    private var timingText: String {
        let o = session.avgOffsetMs
        if abs(o) < 15 { return "On beat" }
        return o < 0 ? "\(Int(-o))ms early" : "\(Int(o))ms late"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CHORD").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Picker("", selection: $chordName) { ForEach(ChordLibrary.shapes) { Text($0.name).tag($0.name) } }
                    .labelsHidden().frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("TEMPO · \(Int(session.bpm)) BPM").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Slider(value: $session.bpm, in: 40...180, step: 1).frame(minWidth: 160, maxWidth: 260).disabled(session.running)
            }
            Spacer()
            if app.inputMode == .mic && session.running && !demo { MicStatusView() }
        }
        HStack(spacing: 18) {
            Toggle("Metronome", isOn: $metronome).toggleStyle(.switch).fixedSize()
            Toggle("Demo (hear it)", isOn: $demo).toggleStyle(.switch).fixedSize()
            Spacer()
            Button {
                session.running ? stop() : start()
            } label: {
                Label(session.running ? "Stop" : (demo ? "Play Demo" : "Start"), systemImage: session.running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
        }
        .font(Theme.font(13, .medium))
        }
        .card(padding: 20, radius: 20)
        .onChange(of: demo) { _, v in session.demo = v }
        .onChange(of: metronome) { _, v in session.metronome = v }
    }

    private func start() {
        session.chord = ChordLibrary.displayShape(for: chordName)
        session.demo = demo
        session.metronome = metronome
        session.window = progress.strictness.strumWindow
        session.latency = progress.latency(for: app.inputMode) / 1000
        session.checkDirection = progress.data.profile.checkDirection && app.inputMode == .mic
        session.useMic = app.inputMode == .mic
        if app.inputMode == .mic && !micHeld { audio.acquire(); micHeld = true }
        keys.start { code in
            if code == Keys.space { session.tap(); return true }
            if code == Keys.escape { stop(); return true }
            return false
        }
        session.start()
    }

    private func stop() {
        guard session.running || micHeld else { return }
        session.stop()
        keys.stop()
        if micHeld { audio.release(); micHeld = false }
        progress.addPractice(seconds: session.activeSeconds)
        if session.bars >= 2 && !demo {
            let pct = Int(session.accuracy * 100)
            let id = session.pattern.id
            progress.recordStrum(id: id, pct: pct)
            progress.addXP(session.bars * 2 + pct / 10)
        }
    }
}
