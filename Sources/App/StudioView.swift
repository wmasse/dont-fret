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
                let take = Take(id: id, name: store.nextName, created: Date(), isVideo: isVideo, file: file, audioFile: audio,
                                duration: real > 0 ? real : seconds)
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
                Text(formatTime(take.length)).font(Theme.font(11, .bold)).monospacedDigit()
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
    @StateObject private var playback = StudioPlayback()
    @StateObject private var dubber = StudioRecorder()
    @State private var name = ""
    @State private var layerStart: Double?
    @State private var armed = false
    @State private var format: StudioRenderer.Format = .m4a
    @State private var exporting: Double?
    @State private var exported: URL?
    @State private var exportError: String?
    @State private var confirmDelete = false

    private var take: Take { store.take(takeID) ?? Take(id: takeID, name: "", created: Date(), isVideo: false, file: "", audioFile: "", duration: 0) }

    private func change(_ f: (inout Take) -> Void) {
        var t = take
        f(&t)
        store.update(t)
        playback.update(t)
    }

    private func editBinding<V>(_ kp: WritableKeyPath<TakeEdit, V>, custom: Bool = true) -> Binding<V> {
        Binding(get: { take.edit[keyPath: kp] }, set: { v in change { $0.edit[keyPath: kp] = v; if custom { $0.edit.preset = "Custom" } } })
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
            HStack(alignment: .top, spacing: 16) {
                soundCard.frame(maxWidth: .infinity)
                exportCard.frame(width: 320)
            }
        }
        .onAppear {
            name = take.name
            playback.load(take, store: store)
        }
        .onDisappear {
            playback.stop()
            if dubber.recording { dubber.stop() }
            dubber.shutdown()
        }
        .onChange(of: playback.playing) { _, p in if !p && dubber.recording { dubber.stop() } }
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
                    .onSubmit { change { $0.name = name.isEmpty ? "Untitled" : name } }
                    .onChange(of: name) { _, n in if !n.isEmpty { change { $0.name = n } } }
                HStack(spacing: 8) {
                    Pill(icon: take.isVideo ? "video" : "mic", text: take.isVideo ? "Video" : "Audio")
                    Pill(icon: "clock", text: "\(formatTime(take.length)) of \(formatTime(take.duration))")
                    Pill(icon: "square.3.layers.3d", text: "\(take.layers.count + 1) track\(take.layers.isEmpty ? "" : "s")")
                    Text(take.created.formatted(date: .abbreviated, time: .shortened)).font(Theme.font(12)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle()).help("Delete this take")
        }
    }

    // MARK: timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { playback.toggle(take, store: store) } label: {
                    Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill").frame(minWidth: 60)
                }
                .buttonStyle(PrimaryButtonStyle()).fixedSize()
                .disabled(dubber.recording)
                Button { playback.seek(take, store: store, to: take.edit.trimStart) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(IconButtonStyle()).help("Back to the start")
                Text("\(formatTime(playback.position - take.edit.trimStart, tenths: true)) / \(formatTime(take.length, tenths: true))")
                    .font(Theme.font(14, .semibold)).monospacedDigit().foregroundStyle(Theme.textDim)
                Spacer()
                if let e = playback.error ?? dubber.error {
                    Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn).lineLimit(2)
                }
                Button(action: toggleLayer) {
                    HStack(spacing: 7) {
                        Image(systemName: dubber.recording ? "stop.fill" : "plus.circle.fill")
                        Text(dubber.recording ? "Stop Layer" : (armed ? "Getting ready…" : "Record a Layer"))
                    }
                    .font(Theme.font(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(recordRed))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Play the take and record another part over it — a second guitar, vocals, a solo. Wear headphones.")
            }
            TimelineLanes(take: take, store: store, position: playback.position,
                          seek: { playback.seek(take, store: store, to: $0) },
                          setTrim: { s, e in change { $0.edit.trimStart = s; $0.edit.trimEnd = e } },
                          setLayer: { l in change { t in if let i = t.layers.firstIndex(where: { $0.id == l.id }) { t.layers[i] = l } } },
                          deleteLayer: { l in store.deleteLayer(l, from: take); playback.load(take, store: store) })
            Text("Drag the handles on the main track to trim. Drag a layer to line it up; click anywhere to jump there.")
                .font(Theme.font(12)).foregroundStyle(Theme.textFaint)
        }
        .card()
    }

    private func toggleLayer() {
        if dubber.recording { dubber.stop(); playback.stop(); return }
        armed = true
        if dubber.running { beginLayer() } else { dubber.prepare(.audio) }
    }

    private func beginLayer() {
        armed = false
        let id = UUID().uuidString
        let file = "\(takeID)-layer-\(id.prefix(8)).m4a"
        let t = take
        var playAt = Date()
        dubber.onStart = { recordedAt in
            // the take starts playing a moment after the recorder; remember the gap to line the layer up
            playAt = Date().addingTimeInterval(0.12)
            playback.play(t, store: store, from: t.edit.trimStart, after: 0.12)
            layerStart = t.edit.trimStart - playAt.timeIntervalSince(recordedAt)
        }
        dubber.onFinish = { url, seconds in
            playback.stop()
            let n = take.layers.count + 1
            let layer = Overdub(id: id, name: "Layer \(n)", file: file, start: layerStart ?? t.edit.trimStart, length: seconds)
            change { $0.layers.append(layer) }
            playback.load(take, store: store)
        }
        dubber.start(to: store.url(file))
    }

    // MARK: sound

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Sound", subtitle: "Pick a starting point, then fine-tune. Changes play live.")
            FlowLayout(spacing: 8) {
                ForEach(TakeEdit.presets, id: \.name) { p in
                    Chip(title: p.name, icon: p.icon, selected: take.edit.preset == p.name) {
                        change { p.apply(&$0.edit); $0.edit.preset = p.name }
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
            Text("Exports use your trim, layers, sound settings and fades\(take.isVideo ? " — fades also fade the picture to black" : "").")
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

/// The main track (with trim handles) and any layers, on one shared time ruler.
struct TimelineLanes: View {
    var take: Take
    @ObservedObject var store: StudioStore
    var position: Double
    var seek: (Double) -> Void
    var setTrim: (Double, Double?) -> Void
    var setLayer: (Overdub) -> Void
    var deleteLayer: (Overdub) -> Void

    @State private var peaks: [String: [Float]] = [:]
    @State private var dragStart: Double?
    @State private var layerDrag: (id: String, from: Double)?

    private let laneHeight: CGFloat = 78
    private let layerHeight: CGFloat = 46
    private var total: Double { max(take.duration, take.layers.map { $0.start + $0.length }.max() ?? 0, 0.5) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 160
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    laneLabel("Main", icon: take.isVideo ? "video" : "mic", sub: "Your take")
                    mainLane(width: w)
                }
                ForEach(take.layers) { l in
                    HStack(spacing: 10) {
                        layerControls(l)
                        layerLane(l, width: w)
                    }
                }
            }
        }
        .frame(height: laneHeight + CGFloat(take.layers.count) * (layerHeight + 8))
        .task(id: [take.audioFile] + take.layers.map(\.file)) {
            for f in [take.audioFile] + take.layers.map(\.file) where peaks[f] == nil {
                peaks[f] = await StudioMedia.peaks(store.url(f), bins: 500)
            }
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / total) * w }

    private func laneLabel(_ title: String, icon: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
            Text(sub).font(Theme.font(11)).foregroundStyle(Theme.textFaint)
        }
        .frame(width: 150, alignment: .leading)
    }

    private func mainLane(width w: CGFloat) -> some View {
        let s = take.edit.trimStart, e = take.end
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface2)
            WaveformShape(peaks: peaks[take.audioFile] ?? [])
                .fill(Theme.accent.opacity(0.85))
                .frame(width: x(take.duration, w), height: laneHeight - 16).offset(y: 8)
            // trimmed-away parts
            Rectangle().fill(Theme.bg.opacity(0.72)).frame(width: max(0, x(s, w)), height: laneHeight)
            Rectangle().fill(Theme.bg.opacity(0.72)).frame(width: max(0, w - x(e, w)), height: laneHeight).offset(x: x(e, w))
            handle(at: x(s, w), w: w, isStart: true)
            handle(at: x(e, w), w: w, isStart: false)
            playhead(w)
        }
        .frame(width: w, height: laneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in seek(Double(v.location.x / w) * total) })
        .accessibilityElement()
        .accessibilityLabel("Main track, trimmed from \(formatTime(s)) to \(formatTime(e))")
    }

    private func handle(at px: CGFloat, w: CGFloat, isStart: Bool) -> some View {
        ZStack {
            Rectangle().fill(Theme.accent).frame(width: 3)
            RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 14, height: 30)
                .overlay(Image(systemName: "line.3.vertical").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onAccent))
        }
        .frame(width: 16, height: laneHeight)
        .contentShape(Rectangle())
        .offset(x: px - 8)
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            let base = dragStart ?? (isStart ? take.edit.trimStart : take.end)
            if dragStart == nil { dragStart = base }
            let t = max(0, min(take.duration, base + Double(v.translation.width / w) * total))
            if isStart { setTrim(min(t, take.end - 0.5), take.edit.trimEnd) }
            else { let end = max(t, take.edit.trimStart + 0.5); setTrim(take.edit.trimStart, end >= take.duration - 0.01 ? nil : end) }
        }.onEnded { _ in dragStart = nil })
        .help(isStart ? "Drag to trim the start" : "Drag to trim the end")
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func playhead(_ w: CGFloat) -> some View {
        Rectangle().fill(Theme.text).frame(width: 2, height: laneHeight).offset(x: x(position, w) - 1)
            .allowsHitTesting(false)
    }

    private func layerControls(_ l: Overdub) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(l.name).font(Theme.font(12.5, .semibold)).foregroundStyle(l.muted ? Theme.textFaint : Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Button { var m = l; m.muted.toggle(); setLayer(m) } label: { Image(systemName: l.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.plain).foregroundStyle(l.muted ? Theme.warn : Theme.textDim).help(l.muted ? "Unmute" : "Mute")
                Button { deleteLayer(l) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Delete this layer")
            }
            Slider(value: Binding(get: { l.volume }, set: { v in var m = l; m.volume = v; setLayer(m) }), in: 0...1.5)
                .controlSize(.mini)
        }
        .frame(width: 150)
    }

    private func layerLane(_ l: Overdub, width w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2.opacity(0.6))
            WaveformShape(peaks: peaks[l.file] ?? [])
                .fill((l.muted ? Theme.textFaint : Theme.accent2).opacity(0.85))
                .frame(width: max(4, x(l.length, w)), height: layerHeight - 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent2.opacity(0.12)))
                .offset(x: x(l.start, w))
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    if layerDrag?.id != l.id { layerDrag = (l.id, l.start) }
                    var m = l
                    m.start = max(-l.length + 0.2, (layerDrag?.from ?? l.start) + Double(v.translation.width / w) * total)
                    setLayer(m)
                }.onEnded { _ in layerDrag = nil })
                .help("Drag to line this layer up with the main track")
            Rectangle().fill(Theme.text).frame(width: 2, height: layerHeight).offset(x: x(position, w) - 1).allowsHitTesting(false)
        }
        .frame(width: w, height: layerHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
