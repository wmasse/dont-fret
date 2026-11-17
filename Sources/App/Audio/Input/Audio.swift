import AVFoundation
import Accelerate
import Combine
import CoreAudio
import QuartzCore

struct ChordMatch: Identifiable, Equatable {
    let symbol: ChordSymbol
    let score: Float
    var id: String { symbol.key }
    var name: String { symbol.displayName }
}

struct AnalysisFrame {
    var chroma: [Float]
    var bass: Int?
    var rms: Float
    var time: Double
    var hasSound: Bool
    /// Strength of each MIDI note (index = midi number), 0...1.
    var noteEnergy: [Float] = []
    var f0: Double? = nil

    func energy(_ midi: Int) -> Float { midi >= 0 && midi < noteEnergy.count ? noteEnergy[midi] : 0 }
}

struct Onset {
    var time: Double
    /// Detected strum direction, when the sound gives a clear answer.
    var direction: StrumStroke?
}

/// Chord templates with harmonic weighting so overtones of a real guitar match well.
enum ChordTemplates {
    struct Entry { let symbol: ChordSymbol; let vector: [Float] }

    static let all: [Entry] = {
        var out: [Entry] = []
        for q in ChordQuality.allCases {
            for root in 0..<12 {
                let flat = [1, 3, 8, 10].contains(root)
                out.append(Entry(symbol: ChordSymbol(root: root, quality: q, bass: nil, flat: flat), vector: vector(root: root, quality: q)))
            }
        }
        return out
    }()

    static func vector(root: Int, quality: ChordQuality) -> [Float] {
        var v = [Float](repeating: 0, count: 12)
        let harmonics: [(Int, Float)] = [(0, 1.0), (0, 0.5), (7, 0.33), (0, 0.25), (4, 0.2)]
        for (i, iv) in quality.intervals.enumerated() {
            let pc = (root + iv) % 12
            let toneWeight: Float = i == 0 ? 1.15 : (iv == 2 || iv == 9 ? 0.85 : 1.0)
            for (off, w) in harmonics { v[(pc + off) % 12] += w * toneWeight }
        }
        return normalized(v)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<12 { s += a[i] * b[i] }
        return s
    }

    static func rank(_ frame: AnalysisFrame) -> [ChordMatch] {
        let c = normalized(frame.chroma)
        return all.map { e in
            var s = cosine(c, e.vector) - e.symbol.quality.detectionPenalty
            if let b = frame.bass, b == e.symbol.root { s += 0.03 }
            return ChordMatch(symbol: e.symbol, score: s)
        }.sorted { $0.score > $1.score }
    }

    /// Does the frame sound like `target`? Returns the match score and pass/fail.
    ///
    /// Passing takes four things, so a near-miss, a half-strummed chord or room noise doesn't count:
    /// the sound is close to the chord's template, no other chord fits better, every tone that
    /// defines the chord (all but the fifth) can be heard, and little energy sits on notes the
    /// chord doesn't contain.
    static func evaluate(_ target: ChordSymbol, frame: AnalysisFrame, strictness: Strictness) -> (score: Float, ok: Bool) {
        guard frame.hasSound else { return (0, false) }
        let c = normalized(frame.chroma)
        let tv = vector(root: target.root, quality: target.quality)
        var ts = cosine(c, tv)
        if let b = frame.bass, b == target.root || b == target.bass { ts += 0.03 }
        guard ts >= strictness.threshold else { return (ts, false) }

        let tones = Set(target.quality.intervals.map { (target.root + $0) % 12 })
        // the defining tones must ring: the fifth is optional (it's often weak or left out)
        let mx = max(frame.chroma.max() ?? 0, 1e-6)
        let defining = target.quality.intervals.filter { $0 != 7 || target.quality == .power }
        for iv in defining where frame.chroma[(target.root + iv) % 12] / mx < strictness.minTone { return (ts, false) }
        // energy on notes outside the chord (allowing each tone's fifth, its loudest overtone)
        var allowed = tones.union(tones.map { ($0 + 7) % 12 })
        // a bare power chord has no third, so the root's own 5th harmonic (a major third) is loud
        if target.quality == .power { allowed.insert((target.root + 4) % 12) }
        let total = frame.chroma.reduce(0, +)
        var foreign: Float = 0
        for pc in 0..<12 where !allowed.contains(pc) { foreign += frame.chroma[pc] }
        if total > 0, foreign / total > strictness.maxForeign { return (ts, false) }

        // no other chord may fit better, including the plain chord inside the target (G for Gmaj7:
        // overtones can fake a 7th) and a richer one around it (Gmaj7 ringing when G is asked for).
        // A same-root sibling that differs only in a colour tone (Gadd9 next to Gmaj7) gets a little
        // more room, since the tone check already heard the target's own colour tone.
        var best: Float = 0
        for e in all where e.symbol.key != target.key {
            let pcs = Set(e.symbol.pitchClasses)
            var s = cosine(c, e.vector) - max(0, e.symbol.quality.detectionPenalty - target.quality.detectionPenalty)
            if let b = frame.bass, b == e.symbol.root { s += 0.03 }
            if e.symbol.root == target.root && !pcs.isSubset(of: tones) && !tones.isSubset(of: pcs) { s -= 0.03 }
            best = max(best, s)
        }
        return (ts, ts >= best - strictness.margin)
    }
}

/// Single-note matching for riffs and melodies.
enum NoteMatcher {
    static func evaluate(_ midi: Int, frame: AnalysisFrame) -> Bool {
        guard frame.hasSound else { return false }
        if let f = frame.f0 {
            let m = Theory.midi(frequency: f)
            for oct in [-12.0, 0, 12] where abs(m - Double(midi) - oct) < 0.5 { return true }
        }
        // fallback: the target (or its octave, which is often louder on guitar) leads the spectrum
        let top = frame.noteEnergy.max() ?? 0
        guard top > 0 else { return false }
        let e = frame.energy(midi) / top, oct = frame.energy(midi + 12) / top
        guard e >= 0.2 else { return false }
        // a stronger note that is not one of this note's own overtones means something else was played
        let overtones: Set<Int> = [midi, midi + 12, midi + 19, midi + 24, midi + 28, midi + 31, midi + 36]
        let rival = frame.noteEnergy.indices.filter { !overtones.contains($0) && frame.noteEnergy[$0] / top > max(e, oct) * 0.9 }
        guard rival.isEmpty else { return false }
        return e >= 0.6 || (e >= 0.3 && oct >= 0.5) || oct >= 0.8
    }
}

/// Finds strings that should be ringing for a chord shape but aren't.
enum StringCheck {
    /// Strings whose note can be heard on its own — not hidden under another string's overtones.
    static func checkable(_ shape: ChordShape) -> [Int] {
        let ringing = (0..<6).filter { shape.frets[$0] >= 0 }
        let notes = ringing.map { Theory.openStrings[$0] + shape.frets[$0] }
        return ringing.filter { s in
            let m = Theory.openStrings[s] + shape.frets[s]
            let others = notes.enumerated().filter { ringing[$0.offset] != s }.map(\.element)
            return !others.contains { o in [0, 12, 19, 24, 28, 31].contains(m - o) }
        }
    }

    static func quietStrings(_ shape: ChordShape, frame: AnalysisFrame) -> [Int] {
        guard frame.hasSound, !frame.noteEnergy.isEmpty else { return [] }
        return checkable(shape).filter { s in frame.energy(Theory.openStrings[s] + shape.frets[s]) < 0.02 }
    }

    /// A string sounding the wrong note: `heard` is the fret it seems to be on.
    struct WrongString: Equatable { let string: Int; let heard: Int }

    /// Strings fretted a fret or two off (or touched when they should ring open). A string is
    /// flagged when a clearly heard note sits one or two frets from where that string should be,
    /// isn't in the chord at all (so another voicing of the same chord never trips it), and
    /// isn't an overtone of the notes that should be ringing.
    static func wrongStrings(_ shape: ChordShape, frame: AnalysisFrame, level: Float = 0.3) -> [WrongString] {
        guard frame.hasSound, !frame.noteEnergy.isEmpty, let sym = shape.symbol else { return [] }
        let chordPCs = Set(sym.pitchClasses).union(sym.bass.map { [$0] } ?? [])
        let ringing = (0..<6).filter { shape.frets[$0] >= 0 }
        let intended = ringing.map { Theory.openStrings[$0] + shape.frets[$0] }
        let overtones: Set<Int> = [0, 12, 19, 24, 28, 31, 34, 36]
        // overtones of the shape's notes, and of anything else clearly ringing: another voicing,
        // or a string left over from the last chord. A wrong fret is a fundamental, not an overtone.
        let heardTones = frame.noteEnergy.indices.filter { frame.noteEnergy[$0] >= ($0 < 52 ? 0.1 : 0.2) }  // low fundamentals read weak
        func explained(_ n: Int) -> Bool {
            intended.contains { overtones.contains(n - $0) } || heardTones.contains { $0 != n && overtones.contains(n - $0) }
        }
        // a note's strength, counting its octave too: low fundamentals are weak on a real guitar
        func strength(_ m: Int) -> Float { max(frame.energy(m), explained(m + 12) ? 0 : frame.energy(m + 12) * 0.8) }

        // a note a muted string could make low on the neck is more likely that string ringing on
        // from the last chord than a fretted string being off, so it doesn't blame a fretted string
        let muted = (0..<6).filter { shape.frets[$0] < 0 }.map { Theory.openStrings[$0] }
        func fromMuted(_ n: Int) -> Bool { muted.contains { (0...5).contains(n - $0) } }

        var found: [(WrongString, Float)] = []
        for s in ringing {
            let fret = shape.frets[s], m = Theory.openStrings[s] + fret
            // when another string's overtone lands on this note, its strength says nothing about this string
            let masked = intended.contains { $0 != m && overtones.contains(m - $0) && m - $0 > 0 }
            let expected = masked ? 0 : strength(m)
            var bestN: (fret: Int, e: Float)? = nil
            for d in [-2, -1, 1, 2] {
                let f = fret + d, n = m + d
                guard f >= 0, f <= 15, !chordPCs.contains(((n % 12) + 12) % 12), !explained(n), !fromMuted(n) else { continue }
                let e = strength(n)
                if e >= max(level, expected * 1.5), e > (bestN?.e ?? 0) { bestN = (f, e) }
            }
            if let b = bestN { found.append((WrongString(string: s, heard: b.fret), b.e)) }
        }
        // one wrong note can sit next to two strings' notes: blame the string whose own note is missing
        var seen = Set<Int>(), out: [WrongString] = []
        for (w, _) in found.sorted(by: { $0.1 > $1.1 }) {
            let n = Theory.openStrings[w.string] + w.heard
            if seen.insert(n).inserted { out.append(w) }
        }
        return out
    }

    static func wrongHint(_ shape: ChordShape, wrong: [WrongString]) -> String? {
        guard let w = wrong.first else { return nil }
        let str = Theory.stringLabels[w.string], fret = shape.frets[w.string]
        if fret == 0 {
            return "The \(str) string should ring open, but it sounds fretted. Keep your fingers off it."
        }
        let finger = shape.fingers[w.string] > 0 ? "finger \(shape.fingers[w.string])" : "your finger"
        let way = w.heard > fret ? "too high" : "too low"
        let off = abs(w.heard - fret) == 1 ? "a fret" : "two frets"
        return "The \(str) string sounds \(off) \(way). Put \(finger) on fret \(fret)."
    }

    static func hint(_ shape: ChordShape, quiet: [Int]) -> String? {
        guard let s = quiet.first else { return nil }
        let str = Theory.stringLabels[s]
        if shape.frets[s] == 0 { return "The open \(str) string isn't ringing — make sure no finger is touching it." }
        let finger = shape.fingers[s] > 0 ? "finger \(shape.fingers[s])" : "your finger"
        return "The \(str) string isn't ringing — press \(finger) firmly just behind fret \(shape.frets[s])."
    }
}

// MARK: - Devices

struct InputDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var deviceID: AudioDeviceID
}

enum OutputKind { case speakers, headphones, external }

enum AudioDevices {
    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func inputDevices() -> [InputDevice] {
        allDevices().compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(id: uid, name: string(id, kAudioObjectPropertyName) ?? "Input", deviceID: id)
        }
    }

    static func deviceID(uid: String) -> AudioDeviceID? { inputDevices().first { $0.id == uid }?.deviceID }

    private static func uint32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = address(sel, scope)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// Is sound coming out of the Mac's own speakers (which the mic can hear)?
    static func outputKind() -> OutputKind {
        guard let out = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal) else { return .speakers }
        let transport = uint32(out, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) ?? 0
        if transport != kAudioDeviceTransportTypeBuiltIn { return .external }
        if let src = uint32(out, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput), src == 0x6864_706E /* 'hdpn' */ {
            return .headphones
        }
        return .speakers
    }
}

// MARK: - Engine

@Observable
final class AudioEngine {
    static let shared = AudioEngine()

    var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var isListening = false
    private(set) var level: Float = 0
    private(set) var chroma = [Float](repeating: 0, count: 12)
    private(set) var detected: ChordMatch?
    private(set) var candidates: [ChordMatch] = []
    private(set) var pitch: Double?
    var errorMessage: String?
    private(set) var deviceName = "System default"

    let frames = PassthroughSubject<AnalysisFrame, Never>()
    let onsets = PassthroughSubject<Onset, Never>()

    private let engine = AVAudioEngine()
    @ObservationIgnored private var users = 0
    private let n = 8192
    private let hop = 2048
    @ObservationIgnored private var ring: [Float]
    @ObservationIgnored private var ringWrite = 0
    @ObservationIgnored private var sinceHop = 0
    @ObservationIgnored private var sampleRate: Double = 48000
    @ObservationIgnored private var fftSetup: FFTSetup?
    @ObservationIgnored private var window: [Float]
    @ObservationIgnored private var smoothChroma = [Float](repeating: 0, count: 12)
    @ObservationIgnored private var pendingTop: String?
    @ObservationIgnored private var pendingCount = 0
    @ObservationIgnored private var pitchHistory: [Double] = []
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    // calibration & self-sound filtering (shared with the tap thread)
    private let lock = NSLock()
    @ObservationIgnored private var gate: Float = 0.006
    @ObservationIgnored private var clickBleed: Float = 0
    @ObservationIgnored private var deviceUID: String?
    @ObservationIgnored private var suppressUntil: Double = 0
    @ObservationIgnored private var clickTimes: [Double] = []
    @ObservationIgnored private var rmsHistory: [(Double, Float)] = []

    // onset & direction state (tap thread only)
    @ObservationIgnored private var envSlow: Float = 0
    @ObservationIgnored private var prevBlock: Float = 0
    @ObservationIgnored private var lastOnset: Double = 0
    @ObservationIgnored private var lowState: Float = 0
    @ObservationIgnored private var highBase: Float = 0
    @ObservationIgnored private var bandBlocks: [(low: Float, high: Float)] = []
    @ObservationIgnored private var blockIndex = 0
    @ObservationIgnored private var pendingOnsets: [(time: Double, block: Int)] = []

    private init() {
        ring = [Float](repeating: 0, count: n)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(vDSP_Length(13), FFTRadix(kFFTRadix2))
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.users > 0 else { return }
            self.stopEngine()
            self.startEngine()
        }
    }

    // MARK: configuration

    func configure(gate g: Float?, clickBleed b: Float?, deviceUID uid: String?) {
        lock.lock()
        gate = g ?? 0.006
        clickBleed = b ?? 0
        let changed = uid != deviceUID
        deviceUID = uid
        lock.unlock()
        if changed && engine.isRunning {
            DispatchQueue.main.async { self.stopEngine(); self.startEngine() }
        }
    }

    /// Ignore the microphone while the app itself is playing a chord through the speakers.
    func suppressSelfSound(for seconds: Double) {
        guard AudioDevices.outputKind() == .speakers || AudioDevices.outputKind() == .external else { return }
        lock.lock(); suppressUntil = max(suppressUntil, CACurrentMediaTime() + seconds); lock.unlock()
    }

    func noteClick() {
        lock.lock()
        clickTimes.append(CACurrentMediaTime())
        if clickTimes.count > 8 { clickTimes.removeFirst() }
        lock.unlock()
    }

    // MARK: calibration

    /// Average loudness of the room (call while the player is silent).
    func measureNoise(seconds: Double = 2.5, completion: @escaping (Float) -> Void) {
        let start = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            self.lock.lock()
            let vals = self.rmsHistory.filter { $0.0 >= start }.map(\.1).sorted()
            self.lock.unlock()
            completion(vals.isEmpty ? 0.002 : vals[Int(Double(vals.count - 1) * 0.8)])
        }
    }

    /// Plays metronome clicks and measures how loud they are at the microphone.
    func measureClickBleed(completion: @escaping (Float) -> Void) {
        var times: [Double] = []
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.5) {
                times.append(CACurrentMediaTime())
                GuitarSynth.shared.click(accent: i % 2 == 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            self.lock.lock()
            let hist = self.rmsHistory
            self.lock.unlock()
            let peaks = times.map { t in hist.filter { $0.0 >= t && $0.0 <= t + 0.15 }.map(\.1).max() ?? 0 }.sorted()
            completion(peaks.isEmpty ? 0 : peaks[peaks.count / 2])
        }
    }

    // MARK: lifecycle (reference counted so screens can share the mic)

    func acquire() {
        users += 1
        if users == 1 { requestAndStart() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { stopEngine() }
    }

    func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permission = .authorized
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permission = granted ? .authorized : .denied
                    if granted && self.users > 0 { self.startEngine() }
                }
            }
        default:
            permission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func startEngine() {
        guard !engine.isRunning else { isListening = true; return }
        let input = engine.inputNode
        lock.lock(); let uid = deviceUID; lock.unlock()
        deviceName = "System default"
        if let uid, let dev = AudioDevices.inputDevices().first(where: { $0.id == uid }), let au = input.audioUnit {
            var id = dev.deviceID
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr { deviceName = dev.name }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            errorMessage = "No microphone input found."
            return
        }
        sampleRate = fmt.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, when in
            self?.process(buf, when: when)
        }
        do {
            engine.prepare()
            try engine.start()
            isListening = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            isListening = false
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isListening = false
        level = 0
        detected = nil
        candidates = []
        pitch = nil
        chroma = [Float](repeating: 0, count: 12)
        smoothChroma = chroma
    }

    // MARK: processing (audio tap thread)

    private func process(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let count = Int(buf.frameLength)
        let startTime = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
        lock.lock()
        let g = gate, bleed = clickBleed, quietUntil = suppressUntil, clicks = clickTimes
        lock.unlock()

        let aLow = Float(1 - exp(-2 * Double.pi * 300 / sampleRate))
        let aHigh = Float(1 - exp(-2 * Double.pi * 1500 / sampleRate))
        let block = 256
        var b = 0
        var newRms: [(Double, Float)] = []
        while b < count {
            let len = min(block, count - b)
            var eL: Float = 0, eH: Float = 0, sq: Float = 0
            for i in b..<(b + len) {
                let x = ch[i]
                lowState += aLow * (x - lowState)
                highBase += aHigh * (x - highBase)
                let h = x - highBase
                eL += lowState * lowState
                eH += h * h
                sq += x * x
            }
            let r = sqrt(sq / Float(len))
            let t = startTime + Double(b) / sampleRate
            newRms.append((t, r))
            bandBlocks.append((eL, eH))
            if bandBlocks.count > 64 { bandBlocks.removeFirst() }
            blockIndex += 1

            let nearClick = clicks.contains { t >= $0 - 0.01 && t <= $0 + 0.09 }
            let clickOK = !nearClick || bleed <= 0 || r > bleed * 2.2
            if r > g * 2, r > prevBlock * 1.5 + 0.002, r > envSlow * 1.7, t - lastOnset > 0.085, t > quietUntil, clickOK {
                lastOnset = t
                pendingOnsets.append((t, blockIndex - 1))
            }
            envSlow = envSlow * 0.93 + r * 0.07
            prevBlock = r
            b += block
        }
        resolveOnsets()

        lock.lock()
        rmsHistory.append(contentsOf: newRms)
        let cutoff = CACurrentMediaTime() - 4
        if let firstKeep = rmsHistory.firstIndex(where: { $0.0 >= cutoff }), firstKeep > 0 { rmsHistory.removeFirst(firstKeep) }
        lock.unlock()

        for i in 0..<count {
            ring[ringWrite] = ch[i]
            ringWrite = (ringWrite + 1) % n
        }
        sinceHop += count
        if sinceHop >= hop {
            sinceHop = 0
            analyze(time: startTime, gate: g, suppressed: CACurrentMediaTime() < quietUntil)
        }
    }

    /// Strum direction: a down-strum hits the low strings first, an up-strum the high strings.
    /// Compare the low/high balance in the first ~10 ms of the attack with the following ~20 ms.
    private func resolveOnsets() {
        while let p = pendingOnsets.first, blockIndex - p.block >= 7 {
            pendingOnsets.removeFirst()
            let back = blockIndex - p.block
            guard back <= bandBlocks.count else { continue }
            let base = bandBlocks.count - back
            func ratio(_ r: Range<Int>) -> Float {
                var l: Float = 1e-9, h: Float = 1e-9
                for i in r where i >= 0 && i < bandBlocks.count { l += bandBlocks[i].low; h += bandBlocks[i].high }
                return l / h
            }
            let early = ratio(base..<(base + 2)), late = ratio((base + 2)..<(base + 6))
            let d = log(early / late)
            let dir: StrumStroke? = d > 0.3 ? .down : (d < -0.3 ? .up : nil)
            let onset = Onset(time: p.time, direction: dir)
            DispatchQueue.main.async { self.onsets.send(onset) }
        }
    }

    private func analyze(time: Double, gate g: Float, suppressed: Bool) {
        guard let setup = fftSetup else { return }
        var samples = [Float](repeating: 0, count: n)
        let tail = n - ringWrite
        for i in 0..<tail { samples[i] = ring[ringWrite + i] }
        for i in 0..<ringWrite { samples[tail + i] = ring[i] }

        var ms: Float = 0
        samples.withUnsafeBufferPointer { p in vDSP_measqv(p.baseAddress! + (n - hop), 1, &ms, vDSP_Length(hop)) }
        let rms = sqrt(ms)
        let hasSound = rms > g && !suppressed

        let f0 = hasSound ? Self.yin(samples, sampleRate: sampleRate, n: n) : nil

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(13), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        let spec = hasSound ? Self.analyzeSpectrum(mags, sampleRate: sampleRate, n: n)
                            : ([Float](repeating: 0, count: 12), nil, [Float](repeating: 0, count: 128))
        for i in 0..<12 {
            smoothChroma[i] = hasSound ? smoothChroma[i] * 0.5 + spec.0[i] * 0.5 : smoothChroma[i] * 0.7
        }
        let frame = AnalysisFrame(chroma: smoothChroma, bass: spec.1, rms: rms, time: time, hasSound: hasSound, noteEnergy: spec.2, f0: f0)
        let ranked = hasSound ? Array(ChordTemplates.rank(frame).prefix(4)) : []

        DispatchQueue.main.async {
            self.publish(frame: frame, ranked: ranked, f0: f0)
        }
    }

    /// Backwards-compatible wrapper used by the self-test.
    static func chroma(fromSpectrum mags: [Float], sampleRate: Double, n: Int) -> ([Float], Int?) {
        let r = analyzeSpectrum(mags, sampleRate: sampleRate, n: n)
        return (r.0, r.1)
    }

    /// Peak-picked chromagram, lowest strong note, and per-MIDI-note energy.
    static func analyzeSpectrum(_ mags: [Float], sampleRate: Double, n: Int) -> ([Float], Int?, [Float]) {
        let half = n / 2
        let binHz = Float(sampleRate) / Float(n)
        let kMin = max(2, Int(75 / binHz))
        let kMax = min(half - 2, Int(2100 / binHz))
        var maxMag: Float = 0
        for k in kMin...kMax { maxMag = max(maxMag, mags[k]) }

        var raw = [Float](repeating: 0, count: 12)
        var notes = [Float](repeating: 0, count: 128)
        var bass: Int? = nil
        if maxMag > 0 {
            let thresh = maxMag * 0.02
            for k in kMin...kMax {
                let m = mags[k]
                guard m > thresh, m > mags[k - 1], m >= mags[k + 1] else { continue }
                let a = mags[k - 1], g = mags[k + 1]
                let denom = a - 2 * m + g
                let p: Float = denom != 0 ? 0.5 * (a - g) / denom : 0
                let f = (Float(k) + p) * binHz
                let midi = 69 + 12 * log2(f / 440)
                let rounded = midi.rounded()
                let dev = abs(midi - rounded)
                let closeness = max(0, 1 - dev * 1.6)
                let mi = Int(rounded)
                if mi >= 0 && mi < 128 { notes[mi] = max(notes[mi], (m / maxMag) * closeness) }
                guard m > maxMag * 0.05 else { continue }
                let pc = ((mi % 12) + 12) % 12
                // fundamentals live low; higher peaks are mostly overtones, so weigh them less
                let fw: Float = f < 450 ? 1 : 450 / f
                raw[pc] += sqrt(m / maxMag) * closeness * fw
                if bass == nil, f < 260, m > maxMag * 0.18 { bass = pc }
            }
        }
        let mx = raw.max() ?? 0
        if mx > 0 { raw = raw.map { $0 / mx } }
        return (raw, bass, notes)
    }

    private func publish(frame: AnalysisFrame, ranked: [ChordMatch], f0: Double?) {
        let lvl = min(1, max(0, (20 * log10(max(frame.rms, 1e-5)) + 60) / 50))
        // Only assign values that changed: each assignment redraws every view reading that property,
        // and in silence most of these stay put frame after frame.
        let smoothed = level * 0.5 + lvl * 0.5
        let newLevel = smoothed < 1e-3 ? 0 : smoothed  // settle on exactly 0 in silence
        if newLevel != level { level = newLevel }
        if frame.chroma != chroma { chroma = frame.chroma }
        if ranked != candidates { candidates = ranked }
        // the "Hearing …" label: a clear winner (not a near-tie with a different chord), held ~130 ms
        let runnerUp = ranked.dropFirst().first { Set($0.symbol.pitchClasses) != Set(ranked[0].symbol.pitchClasses) }
        if let top = ranked.first, top.score > 0.74, top.score - (runnerUp?.score ?? 0) >= 0.02 {
            if pendingTop == top.id { pendingCount += 1 } else { pendingTop = top.id; pendingCount = 1 }
            if pendingCount >= 3, detected != top { detected = top }
        } else if !frame.hasSound {
            if detected != nil { detected = nil }
            pendingTop = nil
        }
        if let f0 {
            pitchHistory.append(f0)
            if pitchHistory.count > 5 { pitchHistory.removeFirst() }
            let median = pitchHistory.sorted()[pitchHistory.count / 2]
            if median != pitch { pitch = median }
        } else if !frame.hasSound {
            pitchHistory.removeAll()
            if pitch != nil { pitch = nil }
        }
        frames.send(frame)
    }

    /// YIN fundamental-frequency estimator — accurate enough for a tuner.
    static func yin(_ s: [Float], sampleRate: Double, n: Int) -> Double? {
        let w = 2048
        let tauMin = Int(sampleRate / 1200)
        let tauMax = min(Int(sampleRate / 60), n - w - 2)
        let start = n - w - tauMax - 1
        var d = [Float](repeating: 0, count: tauMax + 2)
        s.withUnsafeBufferPointer { p in
            let base = p.baseAddress! + start
            var tmp = [Float](repeating: 0, count: w)
            for tau in 1...tauMax {
                vDSP_vsub(base + tau, 1, base, 1, &tmp, 1, vDSP_Length(w))
                var sum: Float = 0
                vDSP_svesq(tmp, 1, &sum, vDSP_Length(w))
                d[tau] = sum
            }
        }
        var cmnd = [Float](repeating: 1, count: tauMax + 2)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        var tauEst = -1
        var tau = tauMin
        while tau < tauMax {
            if cmnd[tau] < 0.15 {
                while tau + 1 < tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEst = tau
                break
            }
            tau += 1
        }
        guard tauEst > 1, tauEst < tauMax else { return nil }
        let a = cmnd[tauEst - 1], b = cmnd[tauEst], c = cmnd[tauEst + 1]
        let denom = a + c - 2 * b
        let shift: Float = denom != 0 ? 0.5 * (a - c) / denom : 0
        return sampleRate / Double(Float(tauEst) + shift)
    }
}
