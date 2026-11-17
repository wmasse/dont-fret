import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings: microphone, timing, backup

struct MicSettingsCard: View {
    @Environment(ProgressStore.self) var progress
    @State private var devices: [InputDevice] = []
    @State private var output: OutputKind = .speakers
    @State private var showRoom = false
    @State private var showLatency = false

    private func update(_ f: (inout Profile) -> Void) {
        var d = progress.data
        f(&d.profile)
        progress.data = d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Microphone & timing", subtitle: "Calibrate once and detection gets noticeably more reliable.")
            row("Input", "Which microphone or audio interface to listen to.") {
                Picker("", selection: Binding(get: { progress.data.profile.inputDeviceUID ?? "" },
                                              set: { v in update { $0.inputDeviceUID = v.isEmpty ? nil : v } })) {
                    Text("System default").tag("")
                    ForEach(devices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden().frame(width: 240)
                .accessibilityLabel("Input device")
            }
            Divider().overlay(Theme.stroke)
            row("Output", outputDetail) {
                Label(outputName, systemImage: output == .headphones ? "headphones" : "hifispeaker.fill")
                    .font(Theme.font(13, .semibold)).foregroundStyle(output == .headphones ? Theme.success : Theme.textDim)
            }
            Divider().overlay(Theme.stroke)
            row("Room & metronome", roomDetail) {
                Button("Calibrate…") { showRoom = true }.buttonStyle(SecondaryButtonStyle())
            }
            Divider().overlay(Theme.stroke)
            row("Timing offset", latencyDetail) {
                Button("Calibrate…") { showLatency = true }.buttonStyle(SecondaryButtonStyle())
            }
            Divider().overlay(Theme.stroke)
            row("Prefer easy chord shapes", "Show simplified fingerings (e.g. mini F instead of the barre) on diagrams.") {
                Toggle("", isOn: Binding(get: { progress.preferEasyShapes }, set: { v in update { $0.preferEasyShapes = v } }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("Prefer easy chord shapes")
            }
            Divider().overlay(Theme.stroke)
            row("Check strum direction (beta)", "In the Strum Trainer, try to hear whether you strummed down or up.") {
                Toggle("", isOn: Binding(get: { progress.data.profile.checkDirection }, set: { v in update { $0.checkDirection = v } }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("Check strum direction")
            }
        }
        .card(padding: 22)
        .onAppear { devices = AudioDevices.inputDevices(); output = AudioDevices.outputKind() }
        .sheet(isPresented: $showRoom) { RoomCalibrationSheet().environment(progress) }
        .sheet(isPresented: $showLatency) { LatencyCalibrationSheet().environment(progress) }
    }

    private var outputName: String {
        switch output { case .headphones: "Headphones"; case .speakers: "Speakers"; case .external: "External speakers" }
    }
    private var outputDetail: String {
        output == .headphones
            ? "Great — the mic won't hear the app's own sounds."
            : "The mic is muted for a moment while the app plays chords, so it doesn't grade itself. Headphones work best."
    }
    private var roomDetail: String {
        if let n = progress.data.profile.noiseFloor {
            return "Calibrated · room noise \(String(format: "%.1f", Double(n) * 1000)), click bleed \(String(format: "%.1f", Double(progress.data.profile.clickBleed ?? 0) * 1000))"
        }
        return "Not calibrated — measures background noise and how loud the metronome is at the mic."
    }
    private var latencyDetail: String {
        let m = progress.data.profile.latencyMicMs, t = progress.data.profile.latencyTapMs
        if m == nil && t == nil { return "Not calibrated — lines up your playing with the beat for fairer timing grades." }
        return [m.map { "Mic \(Int($0)) ms" }, t.map { "Keys \(Int($0)) ms" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }
}

struct BackupCard: View {
    @Environment(ProgressStore.self) var progress
    @State private var message: String?

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Back up & restore").font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                Text("Save your progress, settings and custom songs to a file. Save it in iCloud Drive to move it to another Mac.")
                    .font(Theme.font(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { backup() } label: { Label("Back Up…", systemImage: "externaldrive.badge.plus") }.buttonStyle(SecondaryButtonStyle())
            Button { restore() } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }.buttonStyle(SecondaryButtonStyle())
        }
        .card(padding: 22)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func backup() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Don't Fret Backup \(day).json"
        panel.allowedContentTypes = [.json]
        panel.message = "Tip: choose iCloud Drive to reach this backup from your other Macs."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        progress.exportBackup(to: url)
        message = "Backup saved."
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Don't Fret backup. Your current progress will be replaced."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = progress.importBackup(from: url) ? "Progress restored." : "That file isn't a Don't Fret backup."
    }
}

// MARK: - Room calibration

struct RoomCalibrationSheet: View {
    @Environment(ProgressStore.self) var progress
    @Environment(AudioEngine.self) var audio
    @Environment(\.dismiss) var dismiss
    enum Step { case intro, noise, bleed, done }
    @State private var step: Step = .intro
    @State private var noise: Float = 0
    @State private var bleed: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate your room").font(Theme.font(24, .bold)).foregroundStyle(Theme.text)
            switch step {
            case .intro:
                Text("Two quick steps, about 6 seconds:\n1. Stay quiet so the app can hear your room.\n2. The app plays a few metronome clicks to learn how loud they are at the mic, so it won't mistake them for your strums.")
                    .font(Theme.font(14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            case .noise:
                Label("Listening to the room… stay quiet", systemImage: "ear").font(Theme.font(15, .semibold)).foregroundStyle(Theme.accent)
                LevelMeter(level: audio.level).frame(height: 10)
            case .bleed:
                Label("Playing clicks…", systemImage: "metronome.fill").font(Theme.font(15, .semibold)).foregroundStyle(Theme.accent)
                LevelMeter(level: audio.level).frame(height: 10)
            case .done:
                Label("All set", systemImage: "checkmark.circle.fill").font(Theme.font(16, .bold)).foregroundStyle(Theme.success)
                Text(bleed > noise * 4
                     ? "The metronome is loud at the mic. That's handled now, but headphones will give the best results."
                     : "Your room is quiet and the metronome barely reaches the mic. Detection is tuned to match.")
                    .font(Theme.font(13)).foregroundStyle(Theme.textDim)
            }
            HStack {
                Spacer()
                Button(step == .done ? "Done" : "Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                if step == .intro {
                    Button("Start") { run() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(Theme.surface)
        .onAppear { audio.acquire() }
        .onDisappear { audio.release() }
    }

    private func run() {
        step = .noise
        // give the engine a moment to start if it was idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            audio.measureNoise { n in
                noise = n
                step = .bleed
                audio.measureClickBleed { b in
                    bleed = b
                    var d = progress.data
                    d.profile.noiseFloor = n
                    d.profile.clickBleed = b > n * 2 ? b : 0
                    progress.data = d
                    step = .done
                }
            }
        }
    }
}

// MARK: - Latency calibration

struct LatencyCalibrationSheet: View {
    @Environment(ProgressStore.self) var progress
    @Environment(AudioEngine.self) var audio
    @Environment(\.dismiss) var dismiss
    @State private var input: InputMode = .mic
    @State private var running = false
    @State private var beat = -1
    @State private var clicks: [Double] = []
    @State private var hits: [Double] = []
    @State private var result: Double?
    @State private var failed = false
    @State private var bag = Set<AnyCancellable>()
    @State private var keys = KeyMonitor()

    private let bpm = 90.0
    private let count = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate timing").font(Theme.font(24, .bold)).foregroundStyle(Theme.text)
            Text("Mics, Bluetooth and audio buffers add a small delay. Play along with \(count) clicks and the app will learn your offset.")
                .font(Theme.font(14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Segmented(options: InputMode.allCases, selection: $input) { $0 == .mic ? "Strum (mic)" : "Tap Space" }
                .disabled(running)
            HStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i == beat ? Theme.accent : (i < beat ? Theme.accent.opacity(0.35) : Theme.track))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            Group {
                if let r = result {
                    Label("Offset: \(Int(r)) ms — saved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                } else if failed {
                    Label("Didn't catch enough hits — try again a little louder.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                } else if running {
                    Text(input == .mic ? "Strum a muted chord on every click" : "Press Space on every click")
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Use headphones if you can, so the mic hears your guitar and not the clicks.").foregroundStyle(Theme.textFaint)
                }
            }
            .font(Theme.font(14, .semibold))
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(result == nil ? "Start" : "Again") { start() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(running)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.surface)
        .onAppear { audio.acquire() }
        .onDisappear { audio.release(); keys.stop(); bag.removeAll() }
    }

    private func start() {
        running = true; failed = false; result = nil; beat = -1; clicks = []; hits = []
        bag.removeAll()
        if input == .mic {
            audio.onsets.receive(on: RunLoop.main).sink { o in hits.append(o.time) }.store(in: &bag)
        } else {
            keys.start { code in
                guard code == Keys.space else { return false }
                hits.append(CACurrentMediaTime())
                return true
            }
        }
        let gap = 60 / bpm
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(i) * gap) {
                beat = i
                clicks.append(CACurrentMediaTime())
                AudioEngine.shared.noteClick()
                GuitarSynth.shared.click(accent: i % 4 == 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(count) * gap + 0.3) { finish() }
    }

    private func finish() {
        running = false
        keys.stop(); bag.removeAll()
        let gap = 60 / bpm
        // skip the first two clicks while the player finds the beat
        let offsets: [Double] = clicks.dropFirst(2).compactMap { c in
            hits.map { $0 - c }.filter { abs($0) < gap / 2 }.min { abs($0) < abs($1) }
        }.sorted()
        guard offsets.count >= 4 else {
            result = nil
            failed = true
            beat = -1
            return
        }
        let median = offsets[offsets.count / 2] * 1000
        let ms = max(-150, min(400, median)).rounded()
        var d = progress.data
        if input == .mic { d.profile.latencyMicMs = ms } else { d.profile.latencyTapMs = ms }
        progress.data = d
        result = ms
    }
}
