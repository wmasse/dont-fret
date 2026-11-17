import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

private let recordRed = Color(hex: 0xFF4D5E)

/// Recording studio: record audio or video takes, then trim, mix, polish and export them.
struct StudioView: View {
    @ObservedObject private var store = StudioStore.shared
    @State private var open: String?

    var body: some View {
        if let id = open, store.take(id) != nil {
            TakeEditorView(takeID: id, store: store) { open = nil }
                .id(id)
        } else {
            StudioHome(store: store) { open = $0 }
        }
    }
}

// MARK: - Record + takes

/// A steady click to play along with while recording.
final class StudioClick: ObservableObject {
    @Published var on = false
    @Published var bpm = 90
    private var task: Task<Void, Never>?

    func start() {
        stop()
        let gap = 60.0 / Double(max(30, bpm))
        task = Task.detached {
            let clock = ContinuousClock()
            var next = clock.now
            var beat = 0
            while !Task.isCancelled {
                GuitarSynth.shared.click(accent: beat % 4 == 0)
                beat += 1
                next = next + .milliseconds(Int(gap * 1000))
                try? await clock.sleep(until: next)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}

struct StudioHome: View {
    @EnvironmentObject var progress: ProgressStore
    @ObservedObject var store: StudioStore
    var onOpen: (String) -> Void
    @StateObject private var recorder = StudioRecorder()
    @StateObject private var click = StudioClick()
    @StateObject private var backing = ProgressionPlayer()
    @State private var mode: StudioRecorder.Mode = .audio
    @State private var backingID = ""
    @State private var saving = false

    var body: some View {
        Page {
            PageHeader(title: "Studio", subtitle: "Record yourself playing — audio or video — then trim, mix, polish and export it.") { EmptyView() }
            recordPanel
            if saving {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Saving your take…").font(Theme.font(13)).foregroundStyle(Theme.textDim) }
            }
            SectionHeader(title: "Your takes", subtitle: store.takes.isEmpty ? "Nothing recorded yet — your recordings will appear here." : "\(store.takes.count) recording\(store.takes.count == 1 ? "" : "s") · click one to edit and export it")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                ForEach(store.takes) { t in
                    Button { onOpen(t.id) } label: { TakeCard(take: t, store: store) }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { recorder.prepare(mode) }
        .onDisappear {
            recorder.shutdown()
            click.stop()
            backing.stop()
        }
        .onChange(of: mode) { _, m in recorder.prepare(m) }
        .onChange(of: recorder.micID) { _, _ in if !recorder.recording { recorder.prepare(mode) } }
        .onChange(of: recorder.cameraID) { _, _ in if !recorder.recording && mode == .video { recorder.prepare(mode) } }
    }

    private var recordPanel: some View {
        HStack(alignment: .top, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.85))
                if mode == .video, recorder.running {
                    CameraPreview(session: recorder.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: mode == .video ? "video.fill" : "mic.fill")
                            .font(.system(size: 40)).foregroundStyle(.white.opacity(0.85))
                        LevelBars(level: recorder.level).frame(width: 220, height: 34)
                    }
                }
                VStack {
                    HStack {
                        if recorder.recording {
                            HStack(spacing: 6) {
                                Circle().fill(recordRed).frame(width: 9, height: 9)
                                Text("REC \(formatTime(recorder.elapsed))").font(Theme.font(13, .heavy)).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.55)))
                        }
                        Spacer()
                        if mode == .video { LevelBars(level: recorder.level).frame(width: 90, height: 14) }
                    }
                    Spacer()
                }
                .padding(12)
            }
            .frame(width: 420, height: 236)

            VStack(alignment: .leading, spacing: 14) {
                Picker("Record", selection: $mode) {
                    ForEach(StudioRecorder.Mode.allCases) { m in Label(m.rawValue, systemImage: m == .audio ? "waveform" : "video").tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .disabled(recorder.recording)

                HStack(spacing: 10) {
                    Picker("Microphone", selection: Binding(get: { recorder.micID ?? "" }, set: { recorder.micID = $0 })) {
                        ForEach(recorder.mics, id: \.uniqueID) { d in Text(d.localizedName).tag(d.uniqueID) }
                    }
                    .frame(width: 260)
                    if mode == .video {
                        Picker("Camera", selection: Binding(get: { recorder.cameraID ?? "" }, set: { recorder.cameraID = $0 })) {
                            ForEach(recorder.cameras, id: \.uniqueID) { d in Text(d.localizedName).tag(d.uniqueID) }
                        }
                        .frame(width: 240)
                    }
                }
                .disabled(recorder.recording)

                HStack(spacing: 14) {
                    Toggle(isOn: $click.on) { Label("Click", systemImage: "metronome") }
                    Stepper("\(click.bpm) BPM", value: $click.bpm, in: 40...220, step: 2).disabled(!click.on)
                    Picker("Play along with", selection: $backingID) {
                        Text("No backing").tag("")
                        ForEach(progress.allSongs.sorted { $0.title < $1.title }) { s in Text(s.title).tag(s.id) }
                    }
                    .frame(width: 240)
                }
                .font(Theme.font(13))
                .disabled(recorder.recording)

                HStack(spacing: 14) {
                    Button(action: toggleRecord) {
                        HStack(spacing: 8) {
                            Image(systemName: recorder.recording ? "stop.fill" : "record.circle.fill")
                            Text(recorder.recording ? "Stop" : "Record")
                        }
                        .font(Theme.font(16, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Capsule().fill(recordRed))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!recorder.running || saving)
                    .help(recorder.recording ? "Stop recording" : "Start recording")
                    VStack(alignment: .leading, spacing: 3) {
                        if let e = recorder.error {
                            Text(e).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(recorder.recording ? "Recording… play your heart out." : (recorder.running ? "Ready when you are." : "Getting the \(mode == .video ? "camera" : "microphone") ready…"))
                                .font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                            Text("Using the click or a backing? Wear headphones so it isn't recorded too.")
                                .font(Theme.font(12)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func toggleRecord() {
        if recorder.recording {
            recorder.stop()
            click.stop()
            backing.stop()
            return
        }
        let id = UUID().uuidString
        let isVideo = mode == .video
        let file = id + (isVideo ? ".mov" : ".m4a")
        recorder.onStart = { _ in
            if click.on { click.start() }
            if let s = progress.allSongs.first(where: { $0.id == backingID }) { backing.play(s) }
        }
        recorder.onFinish = { url, seconds in
            saving = true
            Task { @MainActor in
                var audio = file
                if isVideo {
                    audio = id + "-sound.m4a"
                    try? await StudioMedia.extractAudio(from: url, to: store.url(audio))
                }
                let real = await StudioMedia.duration(store.url(audio))
                var take = Take(id: id, name: store.nextName, created: Date(), isVideo: isVideo, file: file, audioFile: audio,
                                duration: real > 0 ? real : seconds)
                take.song = backingID.isEmpty ? nil : backingID
                store.add(take)
                saving = false
                onOpen(id)
            }
        }
        recorder.start(to: store.url(file))
    }
}

struct LevelBars: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    let on = Float(i) / 16 < level
                    RoundedRectangle(cornerRadius: 2)
                        .fill(on ? (i > 13 ? recordRed : (i > 10 ? Theme.warn : Theme.accent)) : Color.white.opacity(0.12))
                        .frame(width: max(2, (g.size.width - 45) / 16))
                }
            }
        }
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Input level")
    }
}

struct TakeCard: View {
    var take: Take
    @ObservedObject var store: StudioStore
    @State private var thumb: NSImage?
    @State private var peaks: [Float] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2)
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if !peaks.isEmpty {
                    WaveformShape(peaks: peaks).fill(Theme.accent.opacity(0.8)).padding(14)
                }
                Text(formatTime(take.length, tenths: take.length < 10)).font(Theme.font(11, .bold)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6))).padding(8)
            }
            .frame(height: 130)
            .clipped()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(take.name).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(take.created.formatted(date: .abbreviated, time: .shortened)).font(Theme.font(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                if !take.layers.isEmpty {
                    Label("\(take.layers.count + 1)", systemImage: "square.3.layers.3d").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textDim)
                        .help("\(take.layers.count) extra layer\(take.layers.count == 1 ? "" : "s")")
                }
                Image(systemName: take.isVideo ? "video.fill" : "waveform").foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 12, radius: 16)
        .contentShape(Rectangle())
        .task(id: take.id) {
            if take.isVideo { thumb = await StudioMedia.thumbnail(store.url(take.file), at: max(0.3, take.edit.trimStart + 0.3)) }
            else { peaks = await StudioMedia.peaks(store.url(take.audioFile), bins: 120) }
        }
    }
}

struct WaveformShape: Shape {
    var peaks: [Float]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !peaks.isEmpty else { return p }
        let w = r.width / CGFloat(peaks.count)
        for (i, v) in peaks.enumerated() {
            let h = max(1, CGFloat(v) * r.height)
            p.addRect(CGRect(x: r.minX + CGFloat(i) * w, y: r.midY - h / 2, width: max(1, w * 0.7), height: h))
        }
        return p
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

// MARK: - Editor

struct TakeEditorView: View {
    let takeID: String
    @ObservedObject var store: StudioStore
    var onBack: () -> Void
    @EnvironmentObject var progress: ProgressStore
    @StateObject private var playback = StudioPlayback()
    @StateObject private var vocals = VocalWork()
    @StateObject private var dubber = StudioRecorder()
    @State private var name = ""
    @State private var layerStart: Double?
    @State private var armed = false
    @State private var punch: ClosedRange<Double>?
    @State private var selection: ClosedRange<Double>?
    @State private var selectedLayer: String?
    @State private var zoom: Double = 1
    @State private var history: [Take] = []
    @State private var future: [Take] = []
    @State private var lastKey = ""
    @State private var lastChange = Date.distantPast
    @State private var notice: String?
    @State private var aligning: String?
    @State private var format: StudioRenderer.Format = .m4a
    @State private var exporting: Double?
    @State private var exported: URL?
    @State private var exportError: String?
    @State private var confirmDelete = false

    private var take: Take { store.take(takeID) ?? Take(id: takeID, name: "", created: Date(), isVideo: false, file: "", audioFile: "", duration: 0) }

    /// What decides when and where audio plays: if it changes while playing, playback is re-queued.
    private func timingKey(_ t: Take) -> String {
        t.kept.map { String(format: "%.3f-%.3f", $0.from, $0.to) }.joined(separator: ",") + "|" +
        t.layers.map { "\($0.id)@\(String(format: "%.3f/%.3f/%.3f", $0.start, $0.inPoint, $0.outPoint ?? -1))" }.joined(separator: ",")
    }

    /// Every edit goes through here so it can be undone. Quick repeats of the same edit (dragging a slider) are one step.
    private func change(_ key: String = "", _ f: (inout Take) -> Void) {
        let before = take
        var t = before
        f(&t)
        guard t != before else { return }
        let now = Date()
        if key.isEmpty || key != lastKey || now.timeIntervalSince(lastChange) > 0.8 {
            history.append(before)
            if history.count > 200 { history.removeFirst() }
        }
        lastKey = key
        lastChange = now
        future.removeAll()
        apply(t, from: before)
    }

    private func apply(_ t: Take, from before: Take) {
        store.update(t)
        playback.update(t)
        vocals.sync(t, store: store)
        if timingKey(before) != timingKey(t) {
            playback.load(t, store: store)
            if playback.playing && !dubber.recording { playback.play(t, store: store, from: playback.position, after: 0.03) }
        } else {
            playback.refreshFiles(t, store: store)
        }
        if let s = selectedLayer, !t.layers.contains(where: { $0.id == s }) { selectedLayer = nil }
    }

    private func undo() {
        guard let prev = history.popLast() else { return }
        let now = take
        future.append(now)
        lastKey = ""
        apply(prev, from: now)
        name = prev.name
    }

    private func redo() {
        guard let next = future.popLast() else { return }
        let now = take
        history.append(now)
        lastKey = ""
        apply(next, from: now)
        name = next.name
    }

    private func editBinding<V>(_ kp: WritableKeyPath<TakeEdit, V>, custom: Bool = true) -> Binding<V> {
        Binding(get: { take.edit[keyPath: kp] }, set: { v in change("\(kp)") { $0.edit[keyPath: kp] = v; if custom { $0.edit.preset = "Custom" } } })
    }

    var body: some View {
        Page {
            Button { playback.stop(); onBack() } label: { Label("Studio", systemImage: "chevron.left") }
                .buttonStyle(.plain).font(Theme.font(13, .semibold)).foregroundStyle(Theme.textDim)
            header
            if take.isVideo {
                VideoSurface(player: playback.video)
                    .frame(maxWidth: .infinity).frame(height: 360)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            timelineCard
            vocalCard
            HStack(alignment: .top, spacing: 16) {
                soundCard.frame(maxWidth: .infinity)
                exportCard.frame(width: 320)
            }
        }
        .onAppear {
            name = take.name
            playback.load(take, store: store)
            vocals.onReady = { playback.refreshFiles(take, store: store) }
            vocals.sync(take, store: store)
        }
        .onDisappear {
            vocals.cancelAll()
            playback.stop()
            if dubber.recording { dubber.stop() }
            dubber.shutdown()
        }
        .onChange(of: playback.playing) { _, p in if !p && dubber.recording { dubber.stop() } }
        .onChange(of: playback.position) { _, p in
            // recording over a selected part stops shortly after it ends
            if dubber.recording, let r = punch, p >= r.upperBound + 0.5 { dubber.stop(); playback.stop() }
        }
        .onChange(of: dubber.running) { _, r in if r && armed { beginLayer() } }
        .confirmationDialog("Delete \(take.name)?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { playback.stop(); store.delete(take); onBack() }
        } message: { Text("The recording and its layers go to the Trash, so you can still get them back from there.") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: take.isVideo ? "video.fill" : "waveform")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.onAccent)
                .frame(width: 46, height: 46).background(RoundedRectangle(cornerRadius: 12).fill(Theme.accentGradient))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).font(Theme.font(28, .bold)).foregroundStyle(Theme.text)
                    .onSubmit { change("name") { $0.name = name.isEmpty ? "Untitled" : name } }
                    .onChange(of: name) { _, n in if !n.isEmpty { change("name") { $0.name = n } } }
                HStack(spacing: 8) {
                    Pill(icon: take.isVideo ? "video" : "mic", text: take.isVideo ? "Video" : "Audio")
                    Pill(icon: "clock", text: "\(formatTime(take.length, tenths: take.duration < 60)) of \(formatTime(take.duration, tenths: take.duration < 60))")
                    Pill(icon: "square.3.layers.3d", text: "\(take.layers.count + 1) track\(take.layers.isEmpty ? "" : "s")")
                    if !take.edit.cuts.isEmpty { Pill(icon: "scissors", text: "\(take.edit.cuts.count) cut\(take.edit.cuts.count == 1 ? "" : "s")") }
                    if take.edit.vocal.isActive || take.layers.contains(where: { $0.vocal.isActive }) { Pill(icon: "waveform.and.mic", text: "Vocal tools") }
                    Text(take.created.formatted(date: .abbreviated, time: .shortened)).font(Theme.font(12)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle()).disabled(history.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)").accessibilityLabel("Undo")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle()).disabled(future.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle()).help("Delete this take").accessibilityLabel("Delete this take")
        }
    }

    // MARK: timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { playback.toggle(take, store: store) } label: {
                    Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill").frame(minWidth: 60)
                }
                .buttonStyle(PrimaryButtonStyle()).fixedSize()
                .disabled(dubber.recording)
                Button { playback.seek(take, store: store, to: take.edit.trimStart) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(IconButtonStyle()).help("Back to the start")
                    .accessibilityLabel("Back to the start")
                Text("\(formatTime(playback.outputPosition, tenths: true)) / \(formatTime(take.length, tenths: true))")
                    .font(Theme.font(14, .semibold)).monospacedDigit().foregroundStyle(Theme.textDim)
                if playback.loop != nil {
                    Label("Looping", systemImage: "repeat").font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
                }
                Spacer()
                if let e = playback.error ?? dubber.error {
                    Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Button { zoom = max(1, zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(IconButtonStyle(size: 30)).disabled(zoom <= 1).help("Zoom out").accessibilityLabel("Zoom out")
                    Text("\(Int(zoom))×").font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(Theme.textDim).frame(width: 28)
                    Button { zoom = min(16, zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(IconButtonStyle(size: 30)).disabled(zoom >= 16).help("Zoom in for fine edits").accessibilityLabel("Zoom in")
                }
                Button(action: toggleLayer) {
                    HStack(spacing: 7) {
                        Image(systemName: dubber.recording ? "stop.fill" : "plus.circle.fill")
                        Text(dubber.recording ? "Stop Layer" : (armed ? "Getting ready…" : (selection == nil ? "Record a Layer" : "Record Over Selection")))
                    }
                    .font(Theme.font(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(recordRed))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Play the take and record another part over it — a second guitar, vocals, a solo. Wear headphones.")
            }
            if let sel = selection { selectionBar(sel) } else {
                Text("Drag across the tracks to select a part — then cut it out, keep only it, loop it or record a new layer over it. Click to jump.")
                    .font(Theme.font(12)).foregroundStyle(Theme.textFaint)
            }
            TimelineLanes(take: take, store: store, playback: playback, selection: $selection, selectedLayer: $selectedLayer,
                          zoom: zoom, aligning: aligning,
                          change: { key, f in change(key, f) },
                          seek: { playback.seek(take, store: store, to: $0) },
                          align: autoAlign)
            if let notice {
                Label(notice, systemImage: "info.circle").font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textDim)
            }
            if dubber.recording {
                Label("Recording a layer — cut parts still play while you record, so everything stays lined up.", systemImage: "record.circle")
                    .font(Theme.font(12.5, .medium)).foregroundStyle(recordRed)
            }
        }
        .card()
    }

    private func selectionBar(_ sel: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "selection.pin.in.out").foregroundStyle(Theme.accent)
            Text("\(formatTime(sel.lowerBound, tenths: true)) – \(formatTime(sel.upperBound, tenths: true))  ·  \(String(format: "%.1f", sel.upperBound - sel.lowerBound)) s")
                .font(Theme.font(12.5, .semibold)).monospacedDigit().foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Button { playback.loop = nil; playback.play(take, store: store, from: sel.lowerBound) } label: { Label("Play It", systemImage: "play.fill") }
                .buttonStyle(ToolButtonStyle())
            Button {
                if playback.loop == nil { playback.loop = sel; playback.play(take, store: store, from: sel.lowerBound) } else { playback.loop = nil }
            } label: { Label(playback.loop == nil ? "Loop" : "Stop Loop", systemImage: "repeat") }
                .buttonStyle(ToolButtonStyle(tint: playback.loop == nil ? nil : Theme.accent))
            Button {
                playback.loop = nil
                change { $0.cut(sel.lowerBound, sel.upperBound) }
                selection = nil
                notice = "Cut out \(String(format: "%.1f", sel.upperBound - sel.lowerBound)) s from every track. Undo (⌘Z) or Restore brings it back."
            } label: { Label("Cut Out", systemImage: "scissors") }
                .buttonStyle(ToolButtonStyle(tint: recordRed))
                .help("Remove this part from the main track and every layer")
            Button {
                playback.loop = nil
                change { $0.keepOnly(sel.lowerBound, sel.upperBound) }
                selection = nil
            } label: { Label("Keep Only This", systemImage: "crop") }
                .buttonStyle(ToolButtonStyle())
                .help("Trim everything before and after this part")
            Button { selection = nil; playback.loop = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(ToolButtonStyle()).help("Clear the selection").accessibilityLabel("Clear the selection")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.08)))
    }

    private func toggleLayer() {
        if dubber.recording { dubber.stop(); playback.stop(); return }
        playback.loop = nil
        punch = selection
        notice = nil
        armed = true
        if dubber.running { beginLayer() } else { dubber.prepare(.audio) }
    }

    private func beginLayer() {
        armed = false
        let id = UUID().uuidString
        let file = "\(takeID)-layer-\(id.prefix(8)).m4a"
        let t = take
        let range = punch
        // a selected part gets two seconds of run-up; otherwise start where the playhead is
        let from: Double = range.map { max(0, $0.lowerBound - 2) }
            ?? (t.outputTime(playback.position) >= t.length - 0.1 ? t.edit.trimStart : playback.position)
        dubber.onStart = { recordedAt in
            // the take starts a moment after the recorder; the gap lines the layer up
            let playAt = Date().addingTimeInterval(0.12)
            playback.play(t, store: store, from: from, raw: true, after: 0.12)
            layerStart = from - playAt.timeIntervalSince(recordedAt)
        }
        dubber.onFinish = { _, seconds in
            playback.stop()
            let start = layerStart ?? from
            var layer = Overdub(id: id, name: "Layer \(take.layers.count + 1)", file: file, start: start, length: seconds)
            if let r = range {
                layer.inPoint = max(0, r.lowerBound - start)
                layer.outPoint = min(seconds, max(layer.inPoint + 0.1, r.upperBound - start))
            }
            change { $0.layers.append(layer) }
            selectedLayer = id
            punch = nil
        }
        dubber.start(to: store.url(file))
    }

    private func autoAlign(_ l: Overdub) {
        aligning = l.id
        notice = nil
        let t = take
        Task { @MainActor in
            let r = await StudioMedia.align(l, main: store.url(t.audioFile), layer: store.url(l.file))
            aligning = nil
            guard let r else {
                notice = "Couldn't find a clear beat to line \(l.name) up with — drag it, or nudge it with the arrows."
                return
            }
            let ms = Int(((r - l.start) * 1000).rounded())
            if abs(ms) < 3 { notice = "\(l.name) is already lined up."; return }
            change { tk in if let i = tk.layers.firstIndex(where: { $0.id == l.id }) { tk.layers[i].start = r } }
            notice = "Lined up \(l.name): moved it \(abs(ms)) ms \(ms < 0 ? "earlier" : "later"). Undo (⌘Z) if it sounds wrong."
        }
    }

    // MARK: sound

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Sound", subtitle: "Pick a starting point, then fine-tune. Changes play live.")
            FlowLayout(spacing: 8) {
                ForEach(TakeEdit.presets, id: \.name) { p in
                    Chip(title: p.name, icon: p.icon, selected: take.edit.preset == p.name) {
                        change("preset") { p.apply(&$0.edit); $0.edit.preset = p.name; $0.edit.vocal.chain = p.name == "Vocal" }
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                sliderRow("Volume", "speaker.wave.2", editBinding(\.volume), -12...12, unit: "dB")
                sliderRow("Bass", "dial.low", editBinding(\.bass), -12...12, unit: "dB")
                sliderRow("Treble", "dial.high", editBinding(\.treble), -12...12, unit: "dB")
                sliderRow("Reverb", "sparkles", editBinding(\.reverb), 0...100, unit: "%")
                GridRow {
                    Label("Space", systemImage: "building.2").font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                    Picker("Space", selection: editBinding(\.space)) {
                        ForEach(TakeEdit.spaces.indices, id: \.self) { i in Text(TakeEdit.spaces[i].0).tag(i) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("")
                }
                sliderRow("Fade in", "arrow.up.right", editBinding(\.fadeIn, custom: false), 0...6, unit: "s")
                sliderRow("Fade out", "arrow.down.right", editBinding(\.fadeOut, custom: false), 0...6, unit: "s")
            }
            HStack(spacing: 20) {
                Toggle(isOn: editBinding(\.compress)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Even out the volume").font(Theme.font(13, .semibold))
                        Text("Quiet bits come up, loud bits come down").font(Theme.font(11.5)).foregroundStyle(Theme.textDim)
                    }
                }
                Toggle(isOn: editBinding(\.normalize, custom: false)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Full loudness on export").font(Theme.font(13, .semibold))
                        Text("Brings the finished track up to a strong level").font(Theme.font(11.5)).foregroundStyle(Theme.textDim)
                    }
                }
            }
            .toggleStyle(.switch)
        }
        .card()
    }

    private func sliderRow(_ title: String, _ icon: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String) -> some View {
        GridRow {
            Label(title, systemImage: icon).font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
            Slider(value: value, in: range)
            Text(unit == "s" ? String(format: "%.1f s", value.wrappedValue) : (unit == "%" ? "\(Int(value.wrappedValue))%" : String(format: "%+.0f dB", value.wrappedValue)))
                .font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 56, alignment: .trailing)
        }
    }

    // MARK: vocals

    /// The track the Vocals card is working on: the selected layer, or the main take.
    private var vocalLayer: Overdub? { selectedLayer.flatMap { id in take.layers.first { $0.id == id } } }
    private var vocalFile: String { vocalLayer?.file ?? take.audioFile }
    private var vocalFX: VocalFX { vocalLayer?.vocal ?? take.edit.vocal }

    private func setVocal(_ key: String, _ f: (inout VocalFX) -> Void) {
        let id = vocalLayer?.id
        change("vocal-\(key)-\(id ?? "main")") { t in
            if let id, let i = t.layers.firstIndex(where: { $0.id == id }) { f(&t.layers[i].vocal) } else { f(&t.edit.vocal) }
        }
    }

    private func vocalBinding<V>(_ kp: WritableKeyPath<VocalFX, V>) -> Binding<V> {
        Binding(get: { vocalFX[keyPath: kp] }, set: { v in setVocal("\(kp)") { $0[keyPath: kp] = v } })
    }

    /// The key of the song played as a backing while recording, if there was one.
    private var songKey: (root: Int, scale: VocalScale, name: String)? {
        guard let id = take.song, let k = progress.allSongs.first(where: { $0.id == id })?.key,
              let first = k.split(separator: " ").first, let pc = Theory.pitchClass(of: String(first)) else { return nil }
        return (pc, k.hasSuffix("minor") ? .minor : .major, k)
    }

    private var tuneBinding: Binding<Bool> {
        Binding(get: { vocalFX.tune }, set: { on in
            let song = songKey
            setVocal("tune") { fx in
                fx.tune = on
                // start in the song's key; without one, it's worked out from the singing
                if on, fx.root == nil, let song { fx.root = song.root; fx.scale = song.scale }
            }
        })
    }

    private var chainBinding: Binding<Bool> {
        Binding(get: { vocalFX.chain }, set: { on in
            guard vocalLayer == nil else { setVocal("chain") { $0.chain = on }; return }
            // on the main track the chain is the Vocal sound preset (its plate comes from the Space)
            change("preset") { t in
                if on, let p = TakeEdit.presets.first(where: { $0.name == "Vocal" }) { p.apply(&t.edit); t.edit.preset = p.name }
                else if !on, t.edit.preset == "Vocal", let p = TakeEdit.presets.first { p.apply(&t.edit); t.edit.preset = p.name }
                t.edit.vocal.chain = on
            }
        })
    }

    private func speedName(_ v: Double) -> String {
        v >= 92 ? "Hard" : (v >= 65 ? "Fast" : (v >= 35 ? "Medium" : "Natural"))
    }

    private var vocalCard: some View {
        let fx = vocalFX, file = vocalFile
        let track = vocals.tracks[file]
        let detected = track.flatMap(VocalProcessor.detectKey)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Vocals", subtitle: "Pitch correction, a vocal chain, doubling and harmony. Rendered in the background, then heard live and in exports.") {
                if let p = vocals.busy[file] {
                    HStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 110)
                        Text(fx.isActive ? "Processing…" : "Reading pitch…").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
                    }
                } else if let e = vocals.failed[file] {
                    Label(e, systemImage: "exclamationmark.triangle").font(Theme.font(12)).foregroundStyle(Theme.warn).lineLimit(1)
                } else if fx.isActive {
                    Label("Ready", systemImage: "checkmark.circle.fill").font(Theme.font(12, .semibold)).foregroundStyle(Theme.success)
                }
            }
            if !take.layers.isEmpty {
                Picker("Track", selection: Binding(get: { vocalLayer?.id ?? "main" }, set: { selectedLayer = $0 == "main" ? nil : $0 })) {
                    Text("Main").tag("main")
                    ForEach(take.layers) { l in Text(l.name).tag(l.id) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: tuneBinding) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pitch correction").font(Theme.font(13, .semibold))
                            Text("Pulls each note to the nearest note in the key").font(Theme.font(11.5)).foregroundStyle(Theme.textDim)
                        }
                    }
                    .toggleStyle(.switch)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Label("Key", systemImage: "music.note").font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                            HStack(spacing: 8) {
                                Picker("Key", selection: Binding(get: { fx.root ?? -1 }, set: { v in setVocal("root") { $0.root = v < 0 ? nil : v } })) {
                                    Text(detected.map { "Auto (\(Theory.name($0.root, flat: Theory.flatKeys.contains($0.root))))" } ?? "Auto").tag(-1)
                                    Divider()
                                    ForEach(0..<12, id: \.self) { pc in Text(Theory.name(pc, flat: Theory.flatKeys.contains(pc))).tag(pc) }
                                }
                                .labelsHidden().frame(width: 110)
                                Picker("Scale", selection: vocalBinding(\.scale)) {
                                    ForEach(VocalScale.allCases) { sc in Text(sc.rawValue).tag(sc) }
                                }
                                .labelsHidden().frame(width: 160)
                            }
                            Text("")
                        }
                        GridRow {
                            Label("Retune speed", systemImage: "speedometer").font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                            VStack(spacing: 2) {
                                Slider(value: vocalBinding(\.speed), in: 0...100)
                                HStack {
                                    Text("Natural").font(Theme.font(10.5)).foregroundStyle(Theme.textFaint)
                                    Spacer()
                                    Text("Hard · robotic").font(Theme.font(10.5)).foregroundStyle(Theme.textFaint)
                                }
                            }
                            Text(speedName(fx.speed)).font(Theme.font(12, .semibold)).foregroundStyle(Theme.text).frame(width: 56, alignment: .trailing)
                        }
                        GridRow {
                            Label("Amount", systemImage: "dial.medium").font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                            Slider(value: vocalBinding(\.amount), in: 0...100)
                            Text("\(Int(fx.amount.rounded()))%").font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 56, alignment: .trailing)
                        }
                    }
                    .disabled(!fx.tune).opacity(fx.tune ? 1 : 0.45)
                    Text(keyHint(fx, detected: detected)).font(Theme.font(11.5)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: chainBinding) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Vocal chain").font(Theme.font(13, .semibold))
                            Text("High-pass, de-esser, compressor, presence EQ and a plate reverb").font(Theme.font(11.5)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: vocalBinding(\.double)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Double").font(Theme.font(13, .semibold))
                            Text("Two slightly different copies, spread left and right").font(Theme.font(11.5)).foregroundStyle(Theme.textDim)
                        }
                    }
                    HStack(spacing: 10) {
                        Label("Harmony", systemImage: "music.quarternote.3").font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                        Picker("Harmony", selection: vocalBinding(\.harmony)) {
                            ForEach(VocalHarmony.allCases) { h in Text(h.rawValue).tag(h) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
                .toggleStyle(.switch)
                .frame(width: 320, alignment: .leading)
            }
            pitchView(file: file, fx: fx, track: track)
        }
        .card()
    }

    private func keyHint(_ fx: VocalFX, detected: (root: Int, scale: VocalScale)?) -> String {
        var parts: [String] = []
        if let s = songKey { parts.append("Song key: \(s.name) (from the backing you played along with).") }
        if let d = detected { parts.append("Heard in your singing: \(Theory.name(d.root, flat: Theory.flatKeys.contains(d.root))) \(d.scale.rawValue.lowercased()).") }
        if fx.tune && fx.speed >= 92 { parts.append("Hard speed snaps instantly — the robotic effect.") }
        return parts.isEmpty ? "Auto works the key out from the notes you sing." : parts.joined(separator: " ")
    }

    @ViewBuilder
    private func pitchView(file: String, fx: VocalFX, track: PitchTrack?) -> some View {
        let offset = vocalLayer?.start ?? 0
        let span: ClosedRange<Double> = vocalLayer.map { $0.used.from...max($0.used.from + 0.1, $0.used.to) }
            ?? take.edit.trimStart...max(take.edit.trimStart + 0.1, take.end)
        if let track {
            let key = VocalProcessor.key(for: fx, track: track)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Text("PITCH").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    legend(Theme.textDim, "What you sang")
                    if fx.tune { legend(Theme.accent, "Corrected") }
                    if fx.harmony != .off { legend(pitchHarmonyColor, "Harmony") }
                    Spacer()
                    Text("Lines are the notes of \(Theory.name(key.root, flat: Theory.flatKeys.contains(key.root))) \(key.scale.rawValue.lowercased()) · click to jump")
                        .font(Theme.font(11)).foregroundStyle(Theme.textFaint)
                }
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        PitchGraph(id: file, track: track, fx: fx, root: key.root, scale: key.scale, offset: offset, range: span, cuts: take.edit.cuts)
                            .equatable()
                        let px = PitchGraph.gutter + CGFloat((playback.position - span.lowerBound) / (span.upperBound - span.lowerBound)) * (g.size.width - PitchGraph.gutter)
                        if px >= PitchGraph.gutter && px <= g.size.width {
                            Rectangle().fill(Theme.text).frame(width: 2, height: g.size.height).offset(x: px - 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in
                        let f = Double((v.location.x - PitchGraph.gutter) / max(1, g.size.width - PitchGraph.gutter))
                        playback.seek(take, store: store, to: span.lowerBound + max(0, min(1, f)) * (span.upperBound - span.lowerBound))
                    })
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2.opacity(0.6)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Pitch graph")
            }
        } else if vocals.busy[file] == nil {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(Theme.accent)
                Text(fx.needsPitch ? "Reading the pitch of this track…" : "See every note you sang against the notes of the key.")
                    .font(Theme.font(12.5)).foregroundStyle(Theme.textDim)
                if !fx.needsPitch {
                    Button { vocals.loadTrack(file, store: store, analyse: true) } label: { Label("Show Pitch", systemImage: "chart.xyaxis.line") }
                        .buttonStyle(ToolButtonStyle())
                }
            }
        }
    }

    private func legend(_ c: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 14, height: 3)
            Text(title).font(Theme.font(11, .medium)).foregroundStyle(Theme.textDim)
        }
    }

    // MARK: export

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Export", subtitle: "Save the finished version anywhere — share it, post it, keep it.")
            if !take.isVideo {
                Picker("Format", selection: $format) {
                    ForEach(StudioRenderer.Format.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            if take.isVideo {
                Button { export(video: true) } label: { Label("Export Video (.mp4)…", systemImage: "film") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(exporting != nil)
                Button { export(video: false) } label: { Label("Export Sound Only (.m4a)…", systemImage: "waveform") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(exporting != nil)
            } else {
                Button { export(video: false) } label: { Label("Export Audio…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(exporting != nil)
            }
            if let p = exporting {
                ProgressView(value: p) { Text("Mixing and exporting…").font(Theme.font(12)) }
            }
            if let e = exportError {
                Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if let u = exported {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Saved \(u.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .font(Theme.font(13, .semibold)).foregroundStyle(Theme.accent).lineLimit(2)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            Text("Exports use your trim, layers, sound settings, vocal tools and fades\(take.isVideo ? " — fades also fade the picture to black" : "").")
                .font(Theme.font(11.5)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func export(video: Bool) {
        let t = take
        let panel = NSSavePanel()
        let ext = video ? "mp4" : (take.isVideo || format == .m4a ? "m4a" : "wav")
        panel.allowedContentTypes = [video ? .mpeg4Movie : (ext == "wav" ? .wav : .mpeg4Audio)]
        panel.nameFieldStringValue = "\(t.name).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playback.stop()
        exporting = 0
        exported = nil
        exportError = nil
        let fmt: StudioRenderer.Format = ext == "wav" ? .wav : .m4a
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let report: (Double) -> Void = { p in Task { @MainActor in if exporting != nil { exporting = p } } }
            do {
                if video {
                    try await StudioRenderer.exportVideo(t, store: store, to: url, progress: report)
                } else {
                    try StudioRenderer.render(t, store: store, to: url, format: fmt, progress: report)
                }
                await MainActor.run { exporting = nil; exported = url }
            } catch {
                await MainActor.run { exporting = nil; exportError = "Export failed: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - Timeline

struct ToolButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(12.5, .semibold))
            .foregroundStyle(tint ?? Theme.text)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill((tint ?? Theme.text).opacity(configuration.isPressed ? 0.22 : 0.1)))
            .contentShape(Capsule())
    }
}

private let layerColors: [Color] = [Color(hex: 0xB78CFF), Color(hex: 0x3DD68C), Color(hex: 0xF5B83D), Color(hex: 0xFF7AB6), Color(hex: 0x5CC8FF)]

/// The main track and its layers on one shared time ruler: select, cut, trim, move and mix.
struct TimelineLanes: View {
    var take: Take
    @ObservedObject var store: StudioStore
    @ObservedObject var playback: StudioPlayback
    @Binding var selection: ClosedRange<Double>?
    @Binding var selectedLayer: String?
    var zoom: Double
    var aligning: String?
    var change: (String, (inout Take) -> Void) -> Void
    var seek: (Double) -> Void
    var align: (Overdub) -> Void

    @State private var peaks: [String: [Float]] = [:]
    @State private var dragBase: Double?
    @State private var layerBase: Overdub?

    private let ruler: CGFloat = 20
    private let mainH: CGFloat = 84
    private let layerH: CGFloat = 76
    private let gap: CGFloat = 8
    private var total: Double { max(take.duration, take.layers.map { $0.start + $0.length }.max() ?? 0, 0.5) }
    private var height: CGFloat { ruler + gap + mainH + CGFloat(take.layers.count) * (layerH + gap) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            headers.frame(width: 250)
            GeometryReader { g in
                let w = max(100, g.size.width * CGFloat(zoom))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: zoom > 1) {
                        lanes(w)
                            .frame(width: w, height: height, alignment: .topLeading)
                            .overlay(alignment: .topLeading) {
                                Color.clear.frame(width: 1, height: 1).offset(x: x(playback.position, w)).id("playhead")
                            }
                    }
                    .onChange(of: zoom) { _, _ in proxy.scrollTo("playhead", anchor: .center) }
                }
            }
            .frame(height: height + (zoom > 1 ? 14 : 0))
        }
        .task(id: [take.audioFile] + take.layers.map(\.file)) {
            for f in [take.audioFile] + take.layers.map(\.file) where peaks[f] == nil {
                peaks[f] = await StudioMedia.peaks(store.url(f), bins: f == take.audioFile ? 1600 : 800)
            }
        }
    }

    // MARK: geometry & snapping

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / total) * w }
    private func time(_ px: CGFloat, _ w: CGFloat) -> Double { max(0, min(total, Double(px / w) * total)) }

    /// Edges worth lining things up with.
    private func snapPoints(skipLayer: String? = nil, withSelection: Bool = true) -> [Double] {
        var p = [0, take.duration, take.edit.trimStart, take.end, playback.position]
        for c in take.edit.cuts { p += [c.start, c.end] }
        for l in take.layers where l.id != skipLayer { p += [l.used.from, l.used.to] }
        if withSelection, let s = selection { p += [s.lowerBound, s.upperBound] }
        return p
    }

    private func snap(_ t: Double, _ w: CGFloat, skipLayer: String? = nil, withSelection: Bool = true) -> Double {
        let tolerance = 7 / Double(w) * total
        var best = t, d = tolerance
        for p in snapPoints(skipLayer: skipLayer, withSelection: withSelection) where abs(p - t) < d { best = p; d = abs(p - t) }
        return best
    }

    /// Drag to select a part; click to jump there.
    private func selectGesture(_ w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lanes"))
            .onChanged { v in
                guard abs(v.translation.width) >= 3 else { return }
                let lo = take.edit.trimStart, hi = take.end
                let a = max(lo, min(hi, snap(time(v.startLocation.x, w), w, withSelection: false)))
                let b = max(lo, min(hi, snap(time(v.location.x, w), w, withSelection: false)))
                selection = min(a, b)...max(a, b)
            }
            .onEnded { v in
                if abs(v.translation.width) < 3 {
                    selection = nil
                    playback.loop = nil
                    seek(time(v.location.x, w))
                } else if let s = selection, s.upperBound - s.lowerBound < 0.05 {
                    selection = nil
                }
            }
    }

    // MARK: headers

    private var headers: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack {
                Text("TRACKS").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Spacer()
                if !playback.solo.isEmpty {
                    Button("Clear solo") { playback.solo = [] }.buttonStyle(.plain).font(Theme.font(11, .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(height: ruler)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: take.isVideo ? "video.fill" : "mic.fill").foregroundStyle(Theme.accent)
                    Text("Main").font(Theme.font(13.5, .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    soloButton("main")
                }
                Text(take.layers.isEmpty ? "Your take. Drag its edges to trim. Press Record a Layer to stack another part on top." : "Your take. Drag its edges to trim.")
                    .font(Theme.font(11)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(height: mainH, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2.opacity(0.5)))
            ForEach(Array(take.layers.enumerated()), id: \.element.id) { i, l in
                layerHeader(l, color: layerColors[i % layerColors.count])
            }
        }
    }

    private func soloButton(_ id: String) -> some View {
        let on = playback.solo.contains(id)
        return Button {
            if on { playback.solo.remove(id) } else { playback.solo.insert(id) }
        } label: {
            Text("S").font(Theme.font(11, .heavy)).frame(width: 20, height: 18)
                .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.warn : Theme.text.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(on ? "Stop soloing" : "Solo: hear only soloed tracks")
        .accessibilityLabel(on ? "Solo on" : "Solo")
    }

    private func setLayer(_ id: String, key: String, _ f: @escaping (inout Overdub) -> Void) {
        change(key + id) { t in if let i = t.layers.firstIndex(where: { $0.id == id }) { f(&t.layers[i]) } }
    }

    private func layerHeader(_ l: Overdub, color: Color) -> some View {
        let selected = selectedLayer == l.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                TextField("Layer name", text: Binding(get: { l.name }, set: { v in setLayer(l.id, key: "name") { $0.name = v } }))
                    .textFieldStyle(.plain).font(Theme.font(13, .semibold)).foregroundStyle(l.muted ? Theme.textFaint : Theme.text)
                Button { setLayer(l.id, key: "") { $0.muted.toggle() } } label: {
                    Text("M").font(Theme.font(11, .heavy)).frame(width: 20, height: 18)
                        .foregroundStyle(l.muted ? Theme.onAccent : Theme.textDim)
                        .background(RoundedRectangle(cornerRadius: 4).fill(l.muted ? recordRed : Theme.text.opacity(0.08)))
                }
                .buttonStyle(.plain).help(l.muted ? "Unmute" : "Mute").accessibilityLabel(l.muted ? "Unmute" : "Mute")
                soloButton(l.id)
                Button { align(l) } label: {
                    if aligning == l.id { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim).frame(width: 18)
                .help("Auto-align: line this layer up with the main track's rhythm").accessibilityLabel("Auto-align")
                Button { change("") { t in t.layers.removeAll { $0.id == l.id } } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Delete this layer (Undo brings it back)").accessibilityLabel("Delete layer")
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").font(.system(size: 10)).foregroundStyle(Theme.textFaint).frame(width: 14)
                Slider(value: Binding(get: { l.volume }, set: { v in setLayer(l.id, key: "vol") { $0.volume = v } }), in: 0...1.5)
                    .controlSize(.mini)
                Text("\(Int((l.volume * 100).rounded()))%").font(Theme.font(10.5, .semibold)).monospacedDigit().foregroundStyle(Theme.textDim).frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text("L").font(Theme.font(10, .bold)).foregroundStyle(Theme.textFaint).frame(width: 14)
                Slider(value: Binding(get: { l.pan }, set: { v in setLayer(l.id, key: "pan") { $0.pan = abs(v) < 0.06 ? 0 : v } }), in: -1...1)
                    .controlSize(.mini)
                Text("R").font(Theme.font(10, .bold)).foregroundStyle(Theme.textFaint)
                Button { setLayer(l.id, key: "nudge") { $0.start -= 0.01 } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Nudge 10 ms earlier").accessibilityLabel("Nudge earlier")
                Button { setLayer(l.id, key: "nudge") { $0.start += 0.01 } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Nudge 10 ms later").accessibilityLabel("Nudge later")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(height: layerH, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? color.opacity(0.14) : Theme.surface2.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? color.opacity(0.7) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { selectedLayer = l.id }
    }

    // MARK: lanes

    private func lanes(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: gap) {
                rulerView(w).frame(height: ruler)
                mainLane(w).frame(height: mainH)
                ForEach(Array(take.layers.enumerated()), id: \.element.id) { i, l in
                    layerLane(l, color: layerColors[i % layerColors.count], w).frame(height: layerH)
                }
            }
            overlays(w).allowsHitTesting(false)
        }
        .coordinateSpace(name: "lanes")
    }

    private func rulerView(_ w: CGFloat) -> some View {
        let pps = Double(w) / total
        let step = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60].first { $0 * pps >= 56 } ?? 120
        return Canvas { ctx, size in
            var t = 0.0
            while t <= total + 0.001 {
                let px = CGFloat(t * pps)
                ctx.fill(Path(CGRect(x: px, y: size.height - 6, width: 1, height: 6)), with: .color(Theme.text.opacity(0.3)))
                ctx.draw(Text(step < 1 ? formatTime(t, tenths: true) : formatTime(t)).font(Theme.font(9.5, .medium)).foregroundColor(Theme.textFaint),
                         at: CGPoint(x: px + 3, y: 6), anchor: .topLeading)
                t += step
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in seek(time(v.location.x, w)) })
        .help("Click to jump")
    }

    private func mainLane(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface2)
            WaveformShape(peaks: peaks[take.audioFile] ?? [])
                .fill(Theme.accent.opacity(0.85))
                .frame(width: x(take.duration, w), height: mainH - 16).offset(y: 8)
            ForEach(take.edit.cuts) { c in
                cutMark(c, w)
            }
            trimHandle(isStart: true, w)
            trimHandle(isStart: false, w)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(selectGesture(w))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main track")
    }

    private func cutMark(_ c: Cut, _ w: CGFloat) -> some View {
        let width = max(3, x(c.end, w) - x(c.start, w))
        return VStack(spacing: 0) {
            Button { change("") { t in t.edit.cuts.removeAll { $0.id == c.id } } } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                    if width > 70 { Text("Restore") }
                }
                .font(Theme.font(10, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(recordRed))
            }
            .buttonStyle(.plain)
            .help("Bring this cut part back")
            .accessibilityLabel("Restore cut part")
            .padding(.top, 5)
            Spacer()
        }
        .frame(width: width, height: mainH)
        .offset(x: x(c.start, w))
    }

    private func trimHandle(isStart: Bool, _ w: CGFloat) -> some View {
        let px = x(isStart ? take.edit.trimStart : take.end, w)
        return ZStack {
            Rectangle().fill(Theme.accent).frame(width: 3)
            RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 14, height: 30)
                .overlay(Image(systemName: "line.3.vertical").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onAccent))
        }
        .frame(width: 16, height: mainH)
        .contentShape(Rectangle())
        .offset(x: px - 8)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes")).onChanged { v in
            let t = max(0, min(take.duration, snap(time(v.location.x, w), w)))
            change("trim") { tk in
                if isStart { tk.edit.trimStart = min(t, tk.end - 0.3) }
                else { let e = max(t, tk.edit.trimStart + 0.3); tk.edit.trimEnd = e >= tk.duration - 0.01 ? nil : e }
            }
        })
        .help(isStart ? "Drag to trim the start" : "Drag to trim the end")
        .accessibilityLabel(isStart ? "Trim start" : "Trim end")
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func layerLane(_ l: Overdub, color: Color, _ w: CGFloat) -> some View {
        let p = peaks[l.file] ?? []
        let used = l.used
        let fullW = max(4, x(l.length, w))
        let usedW = max(4, x(used.to - used.from, w))
        let slice: [Float] = {
            guard !p.isEmpty, l.length > 0 else { return [] }
            let a = max(0, min(p.count, Int(l.inPoint / l.length * Double(p.count))))
            let b = max(a, min(p.count, Int((used.to - l.start) / l.length * Double(p.count))))
            return Array(p[a..<b])
        }()
        let selected = selectedLayer == l.id
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2.opacity(0.45))
                .contentShape(Rectangle())
                .gesture(selectGesture(w))
            // the whole recording, faint; the part in use is bright
            WaveformShape(peaks: p).fill(Theme.textFaint.opacity(0.35))
                .frame(width: fullW, height: layerH - 18).offset(x: x(l.start, w), y: 9)
                .allowsHitTesting(false)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(color.opacity(selected ? 0.22 : 0.13))
                RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(selected ? 0.95 : 0.4), lineWidth: selected ? 2 : 1)
                WaveformShape(peaks: slice).fill((l.muted ? Theme.textFaint : color).opacity(0.95)).padding(.vertical, 6)
                Text(l.name).font(Theme.font(10.5, .bold)).foregroundStyle(color).padding(.leading, 6).padding(.top, 3)
                    .frame(maxHeight: .infinity, alignment: .top).allowsHitTesting(false)
            }
            .frame(width: usedW, height: layerH - 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lanes")).onChanged { v in
                if layerBase?.id != l.id { layerBase = l }
                selectedLayer = l.id
                guard abs(v.translation.width) >= 2, let base = layerBase else { return }
                // move it, snapping its start (or end) to nearby edges
                let raw = base.start + Double(v.translation.width / w) * total
                let lead = base.inPoint, tail = base.used.to - base.start
                let s1 = snap(raw + lead, w, skipLayer: l.id) - lead
                let s2 = snap(raw + tail, w, skipLayer: l.id) - tail
                let start = abs(s1 - raw) <= abs(s2 - raw) && s1 != raw ? s1 : (s2 != raw ? s2 : raw)
                setLayer(l.id, key: "move") { $0.start = start }
            }.onEnded { _ in layerBase = nil })
            .overlay(alignment: .leading) { layerEdge(l, isIn: true, w) }
            .overlay(alignment: .trailing) { layerEdge(l, isIn: false, w) }
            .offset(x: x(used.from, w), y: 3)
            .help("Drag to move this layer; drag its edges to trim it")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(l.name) track")
    }

    private func layerEdge(_ l: Overdub, isIn: Bool, _ w: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .overlay(Capsule().fill(Theme.text.opacity(0.5)).frame(width: 3, height: 18))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes")).onChanged { v in
                let t = snap(time(v.location.x, w), w, skipLayer: l.id) - l.start
                setLayer(l.id, key: isIn ? "in" : "out") { d in
                    if isIn { d.inPoint = max(0, min(t, (d.outPoint ?? d.length) - 0.1)) }
                    else { let o = min(d.length, max(t, d.inPoint + 0.1)); d.outPoint = o >= d.length - 0.005 ? nil : o }
                }
            })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help(isIn ? "Drag to trim the start of this layer" : "Drag to trim the end of this layer")
    }

    /// Dimmed trimmed-off parts, cut parts, the selection and the playhead, across every track.
    private func overlays(_ w: CGFloat) -> some View {
        let top = ruler + gap
        let h = height - top
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.bg.opacity(0.7)).frame(width: max(0, x(take.edit.trimStart, w)), height: h).offset(y: top)
            Rectangle().fill(Theme.bg.opacity(0.7)).frame(width: max(0, w - x(take.end, w)), height: h).offset(x: x(take.end, w), y: top)
            ForEach(take.edit.cuts) { c in
                let cw = max(3, x(c.end, w) - x(c.start, w))
                ZStack {
                    Rectangle().fill(Theme.bg.opacity(0.55))
                    Rectangle().fill(recordRed.opacity(0.16))
                    HStack {
                        Rectangle().fill(recordRed.opacity(0.8)).frame(width: 1.5)
                        Spacer(minLength: 0)
                        Rectangle().fill(recordRed.opacity(0.8)).frame(width: 1.5)
                    }
                    Image(systemName: "scissors").font(.system(size: 11, weight: .bold)).foregroundStyle(recordRed.opacity(0.9))
                        .opacity(cw > 18 ? 1 : 0).offset(y: h / 2 - 14)
                }
                .frame(width: cw, height: h).offset(x: x(c.start, w), y: top)
            }
            if let s = selection {
                let sw = max(2, x(s.upperBound, w) - x(s.lowerBound, w))
                ZStack {
                    Rectangle().fill(Theme.accent.opacity(0.16))
                    HStack {
                        Rectangle().fill(Theme.accent).frame(width: 2)
                        Spacer(minLength: 0)
                        Rectangle().fill(Theme.accent).frame(width: 2)
                    }
                }
                .frame(width: sw, height: h + gap).offset(x: x(s.lowerBound, w), y: top - gap)
            }
            Rectangle().fill(Theme.text).frame(width: 2, height: height).offset(x: x(playback.position, w) - 1)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(Theme.text)
                .offset(x: x(playback.position, w) - 5, y: ruler - 10)
        }
    }
}

// MARK: - Pitch graph

private let pitchHarmonyColor = Color(hex: 0xB78CFF)

/// What was sung against what it's corrected to, on a grid of the key's notes.
struct PitchGraph: View, Equatable {
    static let gutter: CGFloat = 38
    let id: String
    let track: PitchTrack
    let fx: VocalFX
    let root: Int
    let scale: VocalScale
    /// Where (in take time) the recording's first sample lands.
    let offset: Double
    /// The part of the take shown.
    let range: ClosedRange<Double>
    let cuts: [Cut]

    static func == (a: PitchGraph, b: PitchGraph) -> Bool {
        a.id == b.id && a.track.f0.count == b.track.f0.count && a.fx == b.fx && a.root == b.root && a.scale == b.scale
            && a.offset == b.offset && a.range == b.range && a.cuts == b.cuts
    }

    var body: some View {
        let plan = VocalProcessor.plan(track, fx: fx, key: (root, scale))
        let fs = track.frameSeconds
        let first = max(0, Int(((range.lowerBound - offset) / fs).rounded(.down)))
        let last = min(plan.input.count - 1, Int(((range.upperBound - offset) / fs).rounded(.up)))
        let pcs = Set(scale.steps.map { ($0 + root) % 12 })
        return Canvas { ctx, size in
            guard last > first else { return }
            var seen: [Float] = []
            for i in first...last where !plan.input[i].isNaN { seen.append(plan.input[i]) }
            if seen.isEmpty {
                ctx.draw(Text("No sung notes here").font(Theme.font(12)).foregroundColor(Theme.textFaint), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            seen.sort()
            var lo = Double(seen[seen.count / 50]), hi = Double(seen[seen.count - 1 - seen.count / 50])
            if let h = plan.harmony, fx.harmony != .off {
                let hv = h[first...last].filter { !$0.isNaN }
                if let a = hv.min(), let b = hv.max() { lo = min(lo, Double(a)); hi = max(hi, Double(b)) }
            }
            lo = lo.rounded(.down) - 1; hi = hi.rounded(.up) + 1
            if hi - lo < 9 { let c = (hi + lo) / 2; lo = c - 4.5; hi = c + 4.5 }
            let w = size.width - Self.gutter, h = size.height
            func y(_ m: Double) -> CGFloat { CGFloat(1 - (m - lo) / (hi - lo)) * (h - 12) + 6 }
            func x(_ t: Double) -> CGFloat { Self.gutter + CGFloat((t - range.lowerBound) / (range.upperBound - range.lowerBound)) * w }
            // the key's notes
            let rowGap = (h - 12) / CGFloat(hi - lo)
            for n in Int(lo.rounded(.up))...Int(hi.rounded(.down)) {
                let pc = ((n % 12) + 12) % 12
                guard pcs.contains(pc) else { continue }
                let yy = y(Double(n))
                ctx.fill(Path(CGRect(x: Self.gutter, y: yy, width: w, height: pc == root ? 1 : 0.5)),
                         with: .color(Theme.text.opacity(pc == root ? 0.22 : 0.1)))
                if rowGap * CGFloat(scale.steps.count == 12 ? 1 : 1.6) >= 9 || pc == root {
                    ctx.draw(Text(Theory.noteName(midi: n, flat: Theory.flatKeys.contains(root))).font(Theme.font(9.5, pc == root ? .bold : .medium))
                                .foregroundColor(pc == root ? Theme.textDim : Theme.textFaint),
                             at: CGPoint(x: Self.gutter - 5, y: yy), anchor: .trailing)
                }
            }
            // cut parts
            for c in cuts where c.end > range.lowerBound && c.start < range.upperBound {
                let a = x(max(c.start, range.lowerBound)), b = x(min(c.end, range.upperBound))
                ctx.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: h)), with: .color(Color(hex: 0xFF4D5E).opacity(0.1)))
            }
            let step = max(1, (last - first) / max(1, Int(w * 1.5)))
            func curve(_ v: [Float]) -> Path {
                var p = Path()
                var pen = false
                for i in stride(from: first, through: last, by: step) {
                    let m = v[i]
                    if m.isNaN { pen = false; continue }
                    let pt = CGPoint(x: x(offset + Double(i) * fs), y: y(Double(m)))
                    if pen { p.addLine(to: pt) } else { p.move(to: pt); pen = true }
                }
                return p
            }
            ctx.stroke(curve(plan.input), with: .color(Theme.textDim.opacity(fx.tune ? 0.7 : 1)), lineWidth: 1.5)
            if let hv = plan.harmony, fx.harmony != .off {
                ctx.stroke(curve(hv), with: .color(pitchHarmonyColor), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
            }
            if fx.tune { ctx.stroke(curve(plan.lead), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)) }
        }
    }
}
