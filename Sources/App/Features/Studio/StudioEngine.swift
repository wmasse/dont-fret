import Foundation
import AVFoundation
import AppKit
import CoreMedia

// MARK: - Model

/// How a take is polished: trim, tone, space, dynamics and fades. Applied live while you listen and when exporting.
struct TakeEdit: Codable, Hashable {
    var trimStart: Double = 0
    /// nil = the end of the recording
    var trimEnd: Double? = nil
    /// Overall level in dB.
    var volume: Double = 0
    var bass: Double = 0
    var treble: Double = 0
    /// 0...100
    var reverb: Double = 8
    var space: Int = 0
    /// "Even out the volume" — a gentle compressor.
    var compress: Bool = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// Bring the finished track up to a full, consistent level.
    var normalize: Bool = true
    var preset: String = "Natural"
    /// Parts cut out of the middle. They're cut from every track, so layers stay lined up.
    var cuts: [Cut] = []

    static let spaces: [(String, AVAudioUnitReverbPreset)] = [("Room", .mediumRoom), ("Studio", .smallRoom), ("Hall", .largeHall), ("Plate", .plate), ("Church", .cathedral)]

    static let presets: [(name: String, icon: String, apply: (inout TakeEdit) -> Void)] = [
        ("Natural", "leaf", { $0.bass = 0; $0.treble = 0; $0.reverb = 8; $0.space = 0; $0.compress = false }),
        ("Warm", "flame", { $0.bass = 4; $0.treble = -3; $0.reverb = 14; $0.space = 0; $0.compress = true }),
        ("Bright", "sun.max", { $0.bass = -2; $0.treble = 5; $0.reverb = 10; $0.space = 1; $0.compress = false }),
        ("Live Room", "music.mic", { $0.bass = 1; $0.treble = 1; $0.reverb = 28; $0.space = 0; $0.compress = true }),
        ("Concert Hall", "building.columns", { $0.bass = 1; $0.treble = 0; $0.reverb = 42; $0.space = 2; $0.compress = false }),
        ("Radio Ready", "dot.radiowaves.left.and.right", { $0.bass = 3; $0.treble = 3; $0.reverb = 12; $0.space = 3; $0.compress = true; $0.normalize = true }),
        ("Lo-Fi", "cassette", { $0.bass = -5; $0.treble = -10; $0.reverb = 18; $0.space = 1; $0.compress = true })
    ]
}

extension TakeEdit {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = c.v(.trimStart, 0); trimEnd = c.v(.trimEnd, nil); volume = c.v(.volume, 0)
        bass = c.v(.bass, 0); treble = c.v(.treble, 0); reverb = c.v(.reverb, 8); space = c.v(.space, 0)
        compress = c.v(.compress, false); fadeIn = c.v(.fadeIn, 0); fadeOut = c.v(.fadeOut, 0)
        normalize = c.v(.normalize, true); preset = c.v(.preset, "Natural"); cuts = c.v(.cuts, [])
    }
}

/// A part of the recording that's been cut out (in seconds of the original recording).
struct Cut: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var start: Double
    var end: Double
    var length: Double { end - start }
}

/// An extra audio layer recorded while listening to the take (a second guitar, vocals, a solo).
struct Overdub: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var file: String
    /// Where in the take (seconds) the layer's first sample lands.
    var start: Double
    var length: Double
    var volume: Double = 1
    var muted = false
    /// -1 (left) ... 1 (right): spreading parts apart helps them sit together.
    var pan: Double = 0
    /// The part of the layer's own recording that's used (seconds into its file).
    var inPoint: Double = 0
    var outPoint: Double? = nil

    var used: (from: Double, to: Double) { (start + inPoint, start + min(length, outPoint ?? length)) }
}

extension Overdub {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID().uuidString); name = c.v(.name, "Layer"); file = c.v(.file, "")
        start = c.v(.start, 0); length = c.v(.length, 0); volume = c.v(.volume, 1); muted = c.v(.muted, false)
        pan = c.v(.pan, 0); inPoint = c.v(.inPoint, 0); outPoint = c.v(.outPoint, nil)
    }
}

struct Take: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var created: Date
    var isVideo: Bool
    /// The original recording (.m4a for audio, .mov for video).
    var file: String
    /// The take's sound as an audio file the mixer can read (same as `file` for audio takes).
    var audioFile: String
    var duration: Double
    var edit = TakeEdit()
    var layers: [Overdub] = []

    var end: Double { min(duration, edit.trimEnd ?? duration) }

    /// The parts of the original recording that are kept, in playing order (trim and cuts applied).
    var kept: [(from: Double, to: Double)] {
        var out: [(from: Double, to: Double)] = []
        var cur = edit.trimStart
        for c in edit.cuts.sorted(by: { $0.start < $1.start }) {
            let a = max(c.start, edit.trimStart), b = min(c.end, end)
            guard b > a else { continue }
            if a > cur + 0.001 { out.append((cur, a)) }
            cur = max(cur, b)
        }
        if end > cur + 0.001 { out.append((cur, end)) }
        return out
    }
    /// How long the finished take is.
    var length: Double { kept.reduce(0) { $0 + $1.to - $1.from } }

    /// Where a moment of the original recording lands in the finished take (a cut part jumps to what follows it).
    func outputTime(_ t: Double) -> Double {
        var acc = 0.0
        for k in kept {
            if t < k.from { return acc }
            if t <= k.to { return acc + t - k.from }
            acc += k.to - k.from
        }
        return acc
    }

    /// The moment of the original recording heard `o` seconds into the finished take.
    func takeTime(_ o: Double) -> Double {
        var acc = 0.0
        for k in kept {
            let len = k.to - k.from
            if o <= acc + len { return k.from + max(0, o - acc) }
            acc += len
        }
        return kept.last?.to ?? edit.trimStart
    }

    /// Cut a part out of every track (merging with cuts it touches).
    mutating func cut(_ a: Double, _ b: Double) {
        var lo = max(edit.trimStart, min(a, b)), hi = min(end, max(a, b))
        guard hi - lo > 0.02 else { return }
        var rest: [Cut] = []
        for c in edit.cuts {
            if c.end >= lo - 0.001 && c.start <= hi + 0.001 { lo = min(lo, c.start); hi = max(hi, c.end) } else { rest.append(c) }
        }
        rest.append(Cut(start: lo, end: hi))
        edit.cuts = rest.sorted { $0.start < $1.start }
    }

    /// Keep only `a...b`: everything before and after goes, and cuts outside it are dropped.
    mutating func keepOnly(_ a: Double, _ b: Double) {
        let lo = max(0, min(a, b)), hi = min(duration, max(a, b))
        guard hi - lo > 0.1 else { return }
        edit.trimStart = lo
        edit.trimEnd = hi >= duration - 0.01 ? nil : hi
        edit.cuts = edit.cuts.filter { $0.end > lo && $0.start < hi }
    }
}

extension Take {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID().uuidString); name = c.v(.name, "Take"); created = c.v(.created, Date())
        isVideo = c.v(.isVideo, false); file = c.v(.file, ""); audioFile = c.v(.audioFile, ""); duration = c.v(.duration, 0)
        edit = c.v(.edit, TakeEdit()); layers = c.v(.layers, [])
    }
}

func formatTime(_ s: Double, tenths: Bool = false) -> String {
    let t = max(0, s)
    let m = Int(t) / 60, sec = t - Double(m * 60)
    return tenths ? String(format: "%d:%04.1f", m, sec) : String(format: "%d:%02d", m, Int(sec))
}

// MARK: - Store

@Observable
final class StudioStore {
    static let shared = StudioStore()
    private(set) var takes: [Take] = []

    static var defaultFolder: URL { ProgressStore.folder.appendingPathComponent("Studio", isDirectory: true) }
    /// Where recordings and takes.json live.
    let folder: URL
    private var index: URL { folder.appendingPathComponent("takes.json") }
    func url(_ file: String) -> URL { folder.appendingPathComponent(file) }

    init(folder: URL = StudioStore.defaultFolder) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: index), let t = try? dec.decode([Take].self, from: d) {
            takes = t.filter { FileManager.default.fileExists(atPath: url($0.file).path) }
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(takes) { try? d.write(to: index, options: .atomic) }
    }

    func take(_ id: String) -> Take? { takes.first { $0.id == id } }

    func add(_ t: Take) { takes.insert(t, at: 0); save() }

    func update(_ t: Take) {
        guard let i = takes.firstIndex(where: { $0.id == t.id }), takes[i] != t else { return }
        takes[i] = t
        save()
    }

    var nextName: String {
        let used = Set(takes.map(\.name))
        var n = takes.count + 1
        while used.contains("Take \(n)") { n += 1 }
        return "Take \(n)"
    }

    /// Moves the take's files to the Trash (so it can be recovered) and forgets it.
    func delete(_ t: Take) {
        var files = Set([t.file, t.audioFile] + t.layers.map(\.file))
        // layers deleted earlier keep their files (so Undo can bring them back) until the take goes
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for n in names where n.hasPrefix(t.id + "-layer-") { files.insert(n) }
        for f in files where !f.isEmpty { try? FileManager.default.trashItem(at: url(f), resultingItemURL: nil) }
        takes.removeAll { $0.id == t.id }
        save()
    }
}

// MARK: - Recording

/// Records audio (to .m4a) or video with sound (to .mov) from the Mac's camera and microphone.
@Observable
final class StudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Mode: String, CaseIterable, Identifiable { case audio = "Audio Only", video = "Video + Audio"; var id: String { rawValue } }

    private(set) var mode: Mode = .audio
    private(set) var recording = false
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var running = false
    var error: String?
    private(set) var mics: [AVCaptureDevice] = []
    private(set) var cameras: [AVCaptureDevice] = []
    var micID: String?
    var cameraID: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "studio.capture")
    private let movieOut = AVCaptureMovieFileOutput()
    private let audioOut = AVCaptureAudioFileOutput()
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var startedAt: Date?
    /// Called on the main thread when recording really begins (for lining up layers) and when the file is finished.
    @ObservationIgnored var onStart: ((Date) -> Void)?
    @ObservationIgnored var onFinish: ((URL, Double) -> Void)?

    override init() {
        super.init()
        refreshDevices()
    }

    func refreshDevices() {
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                                   mediaType: .video, position: .unspecified).devices.filter { $0.deviceType != .deskViewCamera }
        if micID == nil || !mics.contains(where: { $0.uniqueID == micID }) { micID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? mics.first?.uniqueID }
        if cameraID == nil || !cameras.contains(where: { $0.uniqueID == cameraID }) { cameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID }
    }

    /// Ask for the camera / microphone if needed, then start the capture session in this mode.
    func prepare(_ mode: Mode) {
        self.mode = mode
        let needs: [AVMediaType] = mode == .video ? [.audio, .video] : [.audio]
        Task { @MainActor in
            for m in needs {
                if AVCaptureDevice.authorizationStatus(for: m) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: m) }
                if AVCaptureDevice.authorizationStatus(for: m) != .authorized {
                    self.error = m == .video
                        ? "Don't Fret isn't allowed to use the camera. Turn it on in System Settings → Privacy & Security → Camera."
                        : "Don't Fret isn't allowed to use the microphone. Turn it on in System Settings → Privacy & Security → Microphone."
                    return
                }
            }
            self.error = nil
            self.configure()
        }
    }

    private func configure() {
        let mode = self.mode
        let mic = mics.first { $0.uniqueID == micID } ?? AVCaptureDevice.default(for: .audio)
        let cam = cameras.first { $0.uniqueID == cameraID } ?? AVCaptureDevice.default(for: .video)
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.session
            s.beginConfiguration()
            for i in s.inputs { s.removeInput(i) }
            for o in s.outputs { s.removeOutput(o) }
            var problem: String?
            if let mic, let input = try? AVCaptureDeviceInput(device: mic), s.canAddInput(input) { s.addInput(input) } else { problem = "No microphone found." }
            if mode == .video {
                s.sessionPreset = .high
                if let cam, let input = try? AVCaptureDeviceInput(device: cam), s.canAddInput(input) { s.addInput(input) } else { problem = "No camera found." }
                if s.canAddOutput(self.movieOut) { s.addOutput(self.movieOut) }
            } else {
                if s.canAddOutput(self.audioOut) { s.addOutput(self.audioOut) }
                self.audioOut.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                               AVNumberOfChannelsKey: Self.channels(of: mic), AVEncoderBitRateKey: 256000]
            }
            s.commitConfiguration()
            if !s.isRunning { s.startRunning() }
            DispatchQueue.main.async {
                self.running = s.isRunning
                if let problem { self.error = problem }
                self.startMeter()
            }
        }
    }

    private static func channels(of d: AVCaptureDevice?) -> Int {
        guard let fd = d?.activeFormat.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return 1 }
        return max(1, min(2, Int(asbd.mChannelsPerFrame)))
    }

    func shutdown() {
        if recording { stop() }
        meter?.invalidate(); meter = nil
        queue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.running = false; self?.level = 0 }
        }
    }

    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let out: AVCaptureOutput = self.mode == .video ? self.movieOut : self.audioOut
            let db = out.connections.flatMap(\.audioChannels).map(\.averagePowerLevel).max() ?? -80
            let v = Float(max(0, min(1, (Double(db) + 55) / 55)))
            self.level = max(v, self.level * 0.85)
            if self.recording, let s = self.startedAt { self.elapsed = Date().timeIntervalSince(s) }
        }
    }

    func start(to url: URL) {
        guard !recording else { return }
        try? FileManager.default.removeItem(at: url)
        elapsed = 0
        recording = true
        queue.async { [weak self] in
            guard let self else { return }
            if self.mode == .video {
                self.movieOut.startRecording(to: url, recordingDelegate: self)
            } else {
                self.audioOut.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOut.isRecording { self.movieOut.stopRecording() }
            if self.audioOut.isRecording { self.audioOut.stopRecording() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = Date()
        DispatchQueue.main.async {
            self.startedAt = now
            self.onStart?(now)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        let seconds = output.recordedDuration.seconds
        DispatchQueue.main.async {
            self.recording = false
            self.startedAt = nil
            // a recording cut short (e.g. the disk filled up) is still usable
            let ok = FileManager.default.fileExists(atPath: url.path) && seconds.isFinite && seconds > 0.2
            if !ok, let error { self.error = "Recording failed: \(error.localizedDescription)"; return }
            if ok { self.onFinish?(url, seconds) }
        }
    }
}

// MARK: - Media helpers

enum StudioMedia {
    /// Pulls the sound out of a video so the mixer can play and process it.
    static func extractAudio(from movie: URL, to out: URL) async throws {
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: movie)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileWriteUnknown) }
        ex.outputURL = out
        ex.outputFileType = .m4a
        await ex.export()
        if let e = ex.error { throw e }
    }

    static func duration(_ url: URL) async -> Double {
        let d = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return d.isFinite ? d : 0
    }

    private static let thumbCache = NSCache<NSString, NSImage>()

    static func thumbnail(_ url: URL, at seconds: Double = 0.5) async -> NSImage? {
        let key = url.path as NSString
        if let i = thumbCache.object(forKey: key) { return i }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    private static let peakCache = NSCache<NSString, NSArray>()

    /// Loudness outline of a file in `bins` slices (0...1), for drawing waveforms.
    static func peaks(_ url: URL, bins: Int = 600) async -> [Float] {
        let key = "\(url.path)#\(bins)" as NSString
        if let c = peakCache.object(forKey: key) as? [Float] { return c }
        let result: [Float] = await Task.detached(priority: .userInitiated) {
            guard let f = try? AVAudioFile(forReading: url), f.length > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 16384) else { return [] }
            let total = Double(f.length)
            var out = [Float](repeating: 0, count: bins)
            var pos: AVAudioFramePosition = 0
            while pos < f.length {
                buf.frameLength = 0
                guard (try? f.read(into: buf)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData else { break }
                let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
                for i in stride(from: 0, to: n, by: 4) {
                    var v: Float = 0
                    for c in 0..<chans { v = max(v, abs(ch[c][i])) }
                    let b = min(bins - 1, Int(Double(pos + AVAudioFramePosition(i)) / total * Double(bins)))
                    if v > out[b] { out[b] = v }
                }
                pos += AVAudioFramePosition(n)
            }
            let peak = max(0.05, out.max() ?? 1)
            return out.map { min(1, $0 / peak) }
        }.value
        peakCache.setObject(result as NSArray, forKey: key)
        return result
    }

    static func forgetPeaks() { peakCache.removeAllObjects() }

    /// The take's picture with its trim and cuts applied, for playing in the editor.
    static func videoItem(_ t: Take, store: StudioStore) async -> AVPlayerItem? {
        let movie = AVURLAsset(url: store.url(t.file))
        guard let src = try? await movie.loadTracks(withMediaType: .video).first else { return nil }
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var at = CMTime.zero
        for k in t.kept {
            let r = CMTimeRange(start: CMTime(seconds: k.from, preferredTimescale: 600), end: CMTime(seconds: k.to, preferredTimescale: 600))
            try? v.insertTimeRange(r, of: src, at: at)
            at = at + r.duration
        }
        if let tr = try? await src.load(.preferredTransform) { v.preferredTransform = tr }
        return AVPlayerItem(asset: comp)
    }

    /// Rhythm outline of a file: how sharply the sound jumps up every 5 ms.
    private static func onsets(_ url: URL, hop: Double = 0.005) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return [] }
        let step = max(1, Int(f.processingFormat.sampleRate * hop))
        let n = Int(buf.frameLength)
        var env: [Float] = []
        env.reserveCapacity(n / step + 1)
        var i = 0
        while i + step <= n {
            var e: Float = 0
            for k in i..<(i + step) { e += ch[0][k] * ch[0][k] }
            env.append(log(1 + 1000 * e / Float(step)))
            i += step
        }
        var out = [Float](repeating: 0, count: env.count)
        for k in 1..<max(1, env.count) { out[k] = max(0, env[k] - env[k - 1]) }
        return out
    }

    /// Finds where a layer lines up best with the main take, by matching their rhythms
    /// (within ±0.15 s of where it is now — recording delay is never more, and a wider search would mistake one beat
    /// for the next in steady strumming). Returns the new start, or nil if there's no clear match.
    static func align(_ d: Overdub, main: URL, layer: URL) async -> Double? {
        await Task.detached(priority: .userInitiated) { () -> Double? in bestStart(d, main: main, layer: layer) }.value
    }

    private static func bestStart(_ d: Overdub, main: URL, layer: URL) -> Double? {
        let hop = 0.005
        let m: [Float] = onsets(main)
        let l: [Float] = onsets(layer)
        guard m.count > 100, l.count > 100 else { return nil }
        let usedEnd: Double = min(d.length, d.outPoint ?? d.length, d.inPoint + 40)
        let from = Int(d.inPoint / hop)
        let to = min(l.count, Int(usedEnd / hop))
        guard to - from > 100 else { return nil }
        let base = Int((d.start / hop).rounded())
        let maxLag = Int(0.15 / hop)
        var lags: [Int] = []
        var scores: [Float] = []
        for lag in -maxLag...maxLag {
            var total: Float = 0
            for k in from..<to {
                let mi = base + k + lag
                if mi >= 0 && mi < m.count { total += l[k] * m[mi] }
            }
            lags.append(lag)
            scores.append(total)
        }
        guard let bi = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[bi] > 0 else { return nil }
        let mean: Float = scores.reduce(0, +) / Float(scores.count)
        var v: Float = 0
        for x in scores { v += (x - mean) * (x - mean) }
        let sd: Float = sqrt(v / Float(scores.count))
        guard sd > 0, (scores[bi] - mean) / sd > 2.0 else { return nil }
        return d.start + Double(lags[bi]) * hop
    }
}

// MARK: - Mixer graph (shared by live playback and export)

/// Take + layers → tone (EQ) → "even out" compressor → reverb space.
final class StudioGraph {
    let mainFile: AVAudioFile
    let main = AVAudioPlayerNode()
    var layers: [(node: AVAudioPlayerNode, file: AVAudioFile, dub: Overdub)] = []
    let bus = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 2)
    let comp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let reverb = AVAudioUnitReverb()
    private var space = -1

    init(engine: AVAudioEngine, take: Take, store: StudioStore, output: AVAudioFormat) throws {
        mainFile = try AVAudioFile(forReading: store.url(take.audioFile))
        for n in [main, bus, eq, comp, reverb] as [AVAudioNode] { engine.attach(n) }
        engine.connect(main, to: bus, format: mainFile.processingFormat)
        for d in take.layers {
            guard let f = try? AVAudioFile(forReading: store.url(d.file)) else { continue }
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: bus, format: f.processingFormat)
            layers.append((n, f, d))
        }
        engine.connect(bus, to: eq, format: output)
        engine.connect(eq, to: comp, format: output)
        engine.connect(comp, to: reverb, format: output)
        engine.connect(reverb, to: engine.mainMixerNode, format: output)
        let low = eq.bands[0], high = eq.bands[1]
        low.filterType = .lowShelf; low.frequency = 180; low.bypass = false
        high.filterType = .highShelf; high.frequency = 4500; high.bypass = false
        let au = comp.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 7, 0)
    }

    func apply(_ e: TakeEdit, layers dubs: [Overdub], solo: Set<String> = []) {
        eq.globalGain = Float(max(-24, min(18, e.volume)))
        eq.bands[0].gain = Float(e.bass)
        eq.bands[1].gain = Float(e.treble)
        comp.bypass = !e.compress
        let s = max(0, min(TakeEdit.spaces.count - 1, e.space))
        if s != space { reverb.loadFactoryPreset(TakeEdit.spaces[s].1); space = s }
        reverb.wetDryMix = Float(max(0, min(100, e.reverb)) * 0.7)
        main.volume = solo.isEmpty || solo.contains("main") ? 1 : 0
        for i in layers.indices {
            if let d = dubs.first(where: { $0.id == layers[i].dub.id }) { layers[i].dub = d }
            let d = layers[i].dub
            let audible = !d.muted && (solo.isEmpty || solo.contains(d.id))
            layers[i].node.volume = audible ? Float(d.volume) : 0
            layers[i].node.pan = Float(max(-1, min(1, d.pan)))
        }
    }

    /// Queue these parts of the recording back to back, starting `skip` seconds in, with every layer lined up.
    func schedule(_ parts: [(from: Double, to: Double)], skip: Double = 0) {
        var out = 0.0
        for p in parts {
            let len = p.to - p.from
            defer { out += len }
            guard out + len > skip else { continue }
            let into = max(0, skip - out)
            let a = p.from + into, when = out + into - skip
            Self.queue(main, mainFile, from: a, to: p.to, at: when)
            for (node, file, d) in layers {
                let used = d.used
                let la = max(a, used.from), lb = min(p.to, used.to)
                if lb > la { Self.queue(node, file, from: la - d.start, to: lb - d.start, at: when + (la - a)) }
            }
        }
    }

    private static func queue(_ node: AVAudioPlayerNode, _ file: AVAudioFile, from: Double, to: Double, at: Double) {
        let sr = file.processingFormat.sampleRate
        let a = AVAudioFramePosition(max(0, from) * sr), b = min(file.length, AVAudioFramePosition(to * sr))
        guard b > a else { return }
        node.scheduleSegment(file, startingFrame: a, frameCount: AVAudioFrameCount(b - a),
                             at: AVAudioTime(sampleTime: AVAudioFramePosition((max(0, at) * sr).rounded()), atRate: sr))
    }

    func play(at t: AVAudioTime?) {
        main.play(at: t)
        for l in layers { l.node.play(at: t) }
    }

    func stop() {
        main.stop()
        for l in layers { l.node.stop() }
    }

    /// Seconds of the original recording played so far, counted from `from`.
    func elapsed() -> Double? {
        guard let nt = main.lastRenderTime, let pt = main.playerTime(forNodeTime: nt), pt.sampleTime >= 0 else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }
}

/// Fade multiplier for a moment `t` seconds into the trimmed take.
func fadeGain(_ t: Double, length: Double, edit e: TakeEdit) -> Float {
    var g = 1.0
    if e.fadeIn > 0.01, t < e.fadeIn { g = min(g, max(0, t / e.fadeIn)) }
    if e.fadeOut > 0.01, t > length - e.fadeOut { g = min(g, max(0, (length - t) / e.fadeOut)) }
    return Float(g * g)
}

// MARK: - Live playback

/// Plays a take with all its edits, live — move a slider and hear it change. Keeps a video in sync.
@Observable
final class StudioPlayback {
    private(set) var playing = false
    /// Where we are, in seconds of the original recording.
    private(set) var position: Double = 0
    var error: String?
    /// Tracks being soloed ("main" or a layer id). Empty = everything plays.
    var solo: Set<String> = [] { didSet { if let t = take { graph?.apply(t.edit, layers: t.layers, solo: solo) } } }
    /// Play this part over and over (seconds of the original recording).
    var loop: ClosedRange<Double>?
    let video = AVPlayer()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var graph: StudioGraph?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startOut = 0.0
    @ObservationIgnored private var raw = false
    @ObservationIgnored private var rawFrom = 0.0
    @ObservationIgnored private var take: Take?
    @ObservationIgnored private weak var store: StudioStore?
    @ObservationIgnored private var videoKey = ""

    init() {
        video.isMuted = true
        video.automaticallyWaitsToMinimizeStalling = false
    }

    /// Seconds into the finished take.
    var outputPosition: Double { take?.outputTime(position) ?? 0 }

    func load(_ t: Take, store: StudioStore) {
        take = t
        self.store = store
        if position < t.edit.trimStart || position > t.end { position = t.edit.trimStart }
        guard t.isVideo else { return }
        // the picture follows the edit: cut parts are skipped
        let key = t.file + t.kept.map { String(format: "%.3f-%.3f", $0.from, $0.to) }.joined(separator: ",")
        guard key != videoKey else { return }
        videoKey = key
        Task { @MainActor in
            guard let item = await StudioMedia.videoItem(t, store: store), self.videoKey == key else { return }
            self.video.replaceCurrentItem(with: item)
            if !self.playing { self.video.seek(to: CMTime(seconds: t.outputTime(self.position), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in } }
        }
    }

    func toggle(_ t: Take, store: StudioStore) {
        if playing { stop(); return }
        let from = loop.map { $0.contains(position) ? position : $0.lowerBound } ?? (t.outputTime(position) >= t.length - 0.05 ? t.edit.trimStart : position)
        play(t, store: store, from: from)
    }

    /// Play from `start` (seconds of the original recording). `raw` plays straight through, ignoring cuts —
    /// used while recording a layer so it lines up with the original.
    func play(_ t: Take, store: StudioStore, from start: Double, raw: Bool = false, after delay: Double = 0.12) {
        stop()
        take = t
        self.store = store
        let engine = AVAudioEngine()
        let out = engine.mainMixerNode.outputFormat(forBus: 0)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate > 0 ? out.sampleRate : 48000, channels: 2)!
        do {
            let g = try StudioGraph(engine: engine, take: t, store: store, output: fmt)
            g.apply(t.edit, layers: t.layers, solo: solo)
            let skip: Double
            if raw {
                let p = max(0, min(start, t.duration))
                g.schedule([(p, t.duration)])
                skip = 0
                rawFrom = p
                g.bus.outputVolume = 1
            } else {
                skip = t.outputTime(max(t.edit.trimStart, min(start, t.end)))
                g.schedule(t.kept, skip: skip)
                g.bus.outputVolume = fadeGain(skip, length: t.length, edit: t.edit)
            }
            engine.prepare()
            try engine.start()
            let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)
            g.play(at: AVAudioTime(hostTime: host))
            if t.isVideo && !raw && video.currentItem != nil {
                video.setRate(1, time: CMTime(seconds: skip, preferredTimescale: 600), atHostTime: CMClockMakeHostTimeFromSystemUnits(host))
            }
            self.engine = engine
            self.graph = g
            self.raw = raw
            startOut = skip
            position = raw ? rawFrom : t.takeTime(skip)
            playing = true
            error = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        } catch {
            self.error = "Couldn't play this take: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let t = take, let g = graph, let e = g.elapsed() else { return }
        if raw {
            position = rawFrom + e
            if position >= t.duration { stop() }
            return
        }
        let out = startOut + e
        position = t.takeTime(min(out, t.length))
        g.bus.outputVolume = fadeGain(out, length: t.length, edit: t.edit)
        if let l = loop, let store, position >= l.upperBound || out >= t.length {
            play(t, store: store, from: l.lowerBound, after: 0.02)
            return
        }
        if out >= t.length { stop(); position = t.end }
    }

    /// Edits made while playing are heard straight away.
    func update(_ t: Take) {
        take = t
        graph?.apply(t.edit, layers: t.layers, solo: solo)
    }

    func seek(_ t: Take, store: StudioStore, to s: Double) {
        let wasPlaying = playing && !raw
        position = max(t.edit.trimStart, min(t.end, s))
        if wasPlaying { play(t, store: store, from: position) } else if t.isVideo {
            video.seek(to: CMTime(seconds: t.outputTime(position), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        graph?.stop()
        engine?.stop()
        engine = nil; graph = nil
        video.pause()
        playing = false
    }

    deinit { timer?.invalidate() }
}

// MARK: - Mixdown & export

enum StudioRenderer {
    enum Format: String, CaseIterable, Identifiable { case m4a = "AAC (.m4a)", wav = "WAV — best quality"; var id: String { rawValue } }

    /// Renders the finished sound of a take — trimmed, mixed, processed, faded and levelled — into an audio file.
    /// Returns the peak level before normalising.
    @discardableResult
    static func render(_ t: Take, store: StudioStore, to out: URL, format: Format = .m4a, progress: ((Double) -> Void)? = nil) throws -> Float {
        let sr = 48000.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        let g = try StudioGraph(engine: engine, take: t, store: store, output: fmt)
        g.apply(t.edit, layers: t.layers)
        g.schedule(t.kept)
        try engine.start()
        g.play(at: nil)
        // let the reverb ring out unless the take fades out
        let tail = t.edit.fadeOut > 0.01 ? 0 : (t.edit.reverb > 1 ? 1.2 : 0.05)
        let body = Int(t.length * sr)
        let total = body + Int(tail * sr)
        var L = [Float](), R = [Float]()
        L.reserveCapacity(total); R.reserveCapacity(total)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while L.count < total {
            let n = AVAudioFrameCount(min(4096, total - L.count))
            let status = try engine.renderOffline(n, to: buf)
            switch status {
            case .success:
                let k = Int(buf.frameLength)
                guard let ch = buf.floatChannelData else { break }
                L.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: k))
                R.append(contentsOf: UnsafeBufferPointer(start: ch[min(1, Int(buf.format.channelCount) - 1)], count: k))
                progress?(Double(L.count) / Double(total))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw CocoaError(.fileWriteUnknown)
            @unknown default:
                throw CocoaError(.fileWriteUnknown)
            }
        }
        engine.stop()
        // fades
        for i in 0..<L.count {
            let tt = Double(i) / sr
            var gain = tt < t.length ? fadeGain(tt, length: t.length, edit: t.edit) : (t.edit.fadeOut > 0.01 ? 0 : 1)
            if i > total - 2400 { gain *= Float(total - i) / 2400 }  // no click at the very end
            if gain != 1 { L[i] *= gain; R[i] *= gain }
        }
        // smooth every join where a part was cut out, so there's no click
        var acc = 0.0
        let ramp = Int(0.006 * sr)
        for k in t.kept.dropLast() {
            acc += k.to - k.from
            let j = Int(acc * sr)
            for i in max(0, j - ramp)..<min(L.count, j + ramp) {
                let g = Float(abs(i - j)) / Float(ramp)
                L[i] *= g; R[i] *= g
            }
        }
        // level: bring the loudest moment to -1 dB (or just stop clipping)
        var peak: Float = 0
        for i in 0..<L.count { peak = max(peak, abs(L[i]), abs(R[i])) }
        let target: Float = 0.89
        let scale: Float = peak > 0.0001 ? (t.edit.normalize ? target / peak : (peak > 0.99 ? 0.98 / peak : 1)) : 1
        // write
        try? FileManager.default.removeItem(at: out)
        let settings: [String: Any] = format == .wav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256000]
        let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 8192
        let wb = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var i = 0
        while i < L.count {
            let n = min(chunk, L.count - i)
            for k in 0..<n {
                wb.floatChannelData![0][k] = L[i + k] * scale
                wb.floatChannelData![1][k] = R[i + k] * scale
            }
            wb.frameLength = AVAudioFrameCount(n)
            try file.write(from: wb)
            i += n
        }
        return peak
    }

    /// Exports a video take: the trimmed picture (with fades to black) and the finished, mixed sound.
    static func exportVideo(_ t: Take, store: StudioStore, to out: URL, progress: ((Double) -> Void)? = nil) async throws {
        let mix = FileManager.default.temporaryDirectory.appendingPathComponent("dontfret-mix-\(t.id).m4a")
        try render(t, store: store, to: mix) { progress?($0 * 0.4) }
        defer { try? FileManager.default.removeItem(at: mix) }
        let movie = AVURLAsset(url: store.url(t.file))
        let sound = AVURLAsset(url: mix)
        let comp = AVMutableComposition()
        guard let srcV = try await movie.loadTracks(withMediaType: .video).first,
              let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let srcA = try await sound.loadTracks(withMediaType: .audio).first,
              let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var at = CMTime.zero
        for k in t.kept {
            let r = CMTimeRange(start: CMTime(seconds: k.from, preferredTimescale: 600), end: CMTime(seconds: k.to, preferredTimescale: 600))
            try v.insertTimeRange(r, of: srcV, at: at)
            at = at + r.duration
        }
        v.preferredTransform = try await srcV.load(.preferredTransform)
        let soundLength = min(t.length, try await sound.load(.duration).seconds)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: soundLength, preferredTimescale: 48000)), of: srcA, at: .zero)

        try? FileManager.default.removeItem(at: out)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw CocoaError(.fileWriteUnknown) }
        ex.outputURL = out
        ex.outputFileType = .mp4
        if t.edit.fadeIn > 0.01 || t.edit.fadeOut > 0.01 {
            let size = try await srcV.load(.naturalSize)
            let transform = try await srcV.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            let vc = AVMutableVideoComposition()
            vc.renderSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
            layer.setTransform(transform, at: .zero)
            if t.edit.fadeIn > 0.01 {
                layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: t.edit.fadeIn, preferredTimescale: 600)))
            }
            if t.edit.fadeOut > 0.01 {
                let s = max(0, t.length - t.edit.fadeOut)
                layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), duration: CMTime(seconds: t.edit.fadeOut, preferredTimescale: 600)))
            }
            ins.layerInstructions = [layer]
            vc.instructions = [ins]
            ex.videoComposition = vc
        }
        let watch = Task {
            while !Task.isCancelled {
                progress?(0.4 + Double(ex.progress) * 0.6)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await ex.export()
        watch.cancel()
        if let e = ex.error { throw e }
        progress?(1)
    }
}
