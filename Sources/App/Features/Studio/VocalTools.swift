import Foundation
import AVFoundation
import Accelerate
import Observation

// MARK: - Settings

/// The notes a voice is pulled towards.
enum VocalScale: String, Codable, CaseIterable, Identifiable {
    case major = "Major", minor = "Minor", majorPentatonic = "Major Pentatonic", minorPentatonic = "Minor Pentatonic",
         blues = "Blues", chromatic = "Chromatic"
    var id: String { rawValue }
    var steps: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        case .chromatic: return Array(0..<12)
        }
    }
}

/// A second, pitch-shifted voice that sings along in the key.
enum VocalHarmony: String, Codable, CaseIterable, Identifiable {
    case off = "Off", thirdUp = "3rd above", thirdDown = "3rd below", fifthUp = "5th above", octaveDown = "Octave below"
    var id: String { rawValue }
}

/// Vocal tools for one track (the main take or a layer). Rendered offline into a cached copy of the track's file,
/// which live playback and the mixdown both play instead of the original.
struct VocalFX: Codable, Hashable {
    /// Pitch correction ("Auto-Tune").
    var tune = false
    /// Key root as a pitch class (0 = C). nil = work it out from the singing.
    var root: Int? = nil
    var scale: VocalScale = .major
    /// 0 = natural (slow, keeps vibrato) ... 100 = hard, instant snapping (the robotic "T-Pain" sound).
    var speed: Double = 70
    /// How much of the correction is applied, 0...100 %.
    var amount: Double = 100
    /// High-pass, de-esser, compressor and presence EQ (plus a plate reverb in the mixer).
    var chain = false
    /// Two slightly detuned, slightly late copies spread left and right.
    var double = false
    var harmony: VocalHarmony = .off

    var needsPitch: Bool { tune || double || harmony != .off }
    var isActive: Bool { needsPitch || chain }

    /// Everything that changes the rendered file, as a stable string.
    var renderKey: String {
        guard isActive else { return "" }
        var k = "v\(VocalProcessor.version)|c\(chain ? 1 : 0)"
        if needsPitch { k += "|r\(root ?? -1)|s\(scale.rawValue)|d\(double ? 1 : 0)|h\(harmony.rawValue)" }
        if tune { k += "|t\(Int(speed.rounded()))|a\(Int(amount.rounded()))" }
        return k
    }
}

extension VocalFX {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tune = c.v(.tune, false); root = c.v(.root, nil); scale = c.v(.scale, .major)
        speed = c.v(.speed, 70); amount = c.v(.amount, 100); chain = c.v(.chain, false)
        double = c.v(.double, false); harmony = c.v(.harmony, .off)
    }
}

/// The detected pitch of a recording, every 10 ms.
struct PitchTrack {
    let sampleRate: Double
    let hop: Int
    /// Hz; 0 = no clear pitch (silence, breath, consonants).
    let f0: [Float]
    var frameSeconds: Double { Double(hop) / sampleRate }
    /// MIDI note number per frame (NaN = no pitch).
    var midi: [Float] { f0.map { $0 > 0 ? 69 + 12 * log2($0 / 440) : .nan } }
}

// MARK: - Processing

enum VocalProcessor {
    /// Bump when the algorithm changes, so cached renders are redone.
    static let version = 1

    static func folder(_ store: StudioStore) -> URL {
        let u = store.folder.appendingPathComponent("Vocal", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func stem(_ file: String) -> String { (file as NSString).deletingPathExtension }

    /// FNV-1a: stable between launches (Swift's Hasher isn't).
    private static func fingerprint(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func processedURL(_ file: String, fx: VocalFX, store: StudioStore) -> URL {
        folder(store).appendingPathComponent("\(stem(file))-\(fingerprint(fx.renderKey)).caf")
    }

    /// The file to play for a track: its vocal render once it's ready, otherwise the original.
    static func playableURL(_ file: String, fx: VocalFX, store: StudioStore) -> URL {
        if fx.isActive {
            let p = processedURL(file, fx: fx, store: store)
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        return store.url(file)
    }

    /// Which files a take plays right now (changes when a vocal render finishes or is switched off).
    static func playableKey(_ t: Take, store: StudioStore) -> String {
        ([playableURL(t.audioFile, fx: t.edit.vocal, store: store)] + t.layers.map { playableURL($0.file, fx: $0.vocal, store: store) })
            .map(\.lastPathComponent).joined(separator: ",")
    }

    static func isReady(_ file: String, fx: VocalFX, store: StudioStore) -> Bool {
        !fx.isActive || FileManager.default.fileExists(atPath: processedURL(file, fx: fx, store: store).path)
    }

    /// Render whatever a take needs before a mixdown (export waits for this).
    static func prepare(_ t: Take, store: StudioStore) {
        for (file, fx) in [(t.audioFile, t.edit.vocal)] + t.layers.filter({ !$0.muted }).map({ ($0.file, $0.vocal) }) where fx.isActive {
            _ = try? render(file, fx: fx, store: store)
        }
    }

    /// Delete the cached renders and pitch of these recordings.
    static func forget(_ files: [String], store: StudioStore) {
        let dir = folder(store)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let stems = Set(files.filter { !$0.isEmpty }.map(stem))
        for n in names where stems.contains(where: { n.hasPrefix($0 + "-") || n == $0 + ".pitch" }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    // MARK: files

    /// The recording mixed down to one channel.
    static func loadMono(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 32768) else { return nil }
        // read in chunks: one big read can stop short of the end
        let chans = Int(buf.format.channelCount), s = 1 / Float(chans)
        var out: [Float] = []
        out.reserveCapacity(Int(f.length))
        while true {
            buf.frameLength = 0
            guard (try? f.read(into: buf)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData else { break }
            let n = Int(buf.frameLength), at = out.count
            out.append(contentsOf: repeatElement(0, count: n))
            for c in 0..<chans { let p = ch[c]; for i in 0..<n { out[at + i] += p[i] * s } }
        }
        return out.isEmpty ? nil : (out, f.processingFormat.sampleRate)
    }

    static func write(_ channels: [[Float]], sampleRate sr: Double, to url: URL) throws {
        // the pool makes sure the file is closed (and fully written) before anyone reads it
        try autoreleasepool {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: channels.count,
                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let n = channels.first?.count ?? 0
            let chunk = 16384
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
            var i = 0
            while i < n {
                let k = min(chunk, n - i)
                for c in channels.indices { channels[c].withUnsafeBufferPointer { p in buf.floatChannelData![c].update(from: p.baseAddress! + i, count: k) } }
                buf.frameLength = AVAudioFrameCount(k)
                try file.write(from: buf)
                i += k
            }
            if #available(macOS 15.0, *) { file.close() }
        }
    }

    private final class TrackBox { let track: PitchTrack; init(_ t: PitchTrack) { track = t } }
    private static let trackCache = NSCache<NSString, TrackBox>()

    /// A pitch track already worked out (in memory or on disk), without analysing anything.
    static func cachedTrack(_ file: String, store: StudioStore) -> PitchTrack? {
        let url = folder(store).appendingPathComponent(stem(file) + ".pitch")
        if let b = trackCache.object(forKey: url.path as NSString) { return b.track }
        guard let d = try? Data(contentsOf: url), d.count >= 12 else { return nil }
        let floats: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard Int(floats[2]) == version, floats[0] > 0, floats[1] > 0 else { return nil }
        let t = PitchTrack(sampleRate: Double(floats[0]), hop: Int(floats[1]), f0: Array(floats[3...]))
        trackCache.setObject(TrackBox(t), forKey: url.path as NSString)
        return t
    }

    /// The pitch of a recording: cached, or analysed now.
    static func pitchTrack(_ file: String, store: StudioStore, audio: (samples: [Float], sampleRate: Double)? = nil,
                           progress: ((Double) -> Void)? = nil, cancelled: () -> Bool = { false }) -> PitchTrack? {
        if let t = cachedTrack(file, store: store) { return t }
        guard let a = audio ?? loadMono(store.url(file)) else { return nil }
        let t = analyze(a.samples, sampleRate: a.sampleRate, progress: progress, cancelled: cancelled)
        if cancelled() { return nil }
        let url = folder(store).appendingPathComponent(stem(file) + ".pitch")
        let floats = [Float(t.sampleRate), Float(t.hop), Float(version)] + t.f0
        try? floats.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url, options: .atomic)
        trackCache.setObject(TrackBox(t), forKey: url.path as NSString)
        return t
    }

    /// Renders a track's vocal processing into its cached file (unless it's there already).
    @discardableResult
    static func render(_ file: String, fx: VocalFX, store: StudioStore, progress: ((Double) -> Void)? = nil,
                       cancelled: @escaping () -> Bool = { false }) throws -> URL {
        let dest = processedURL(file, fx: fx, store: store)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let audio = loadMono(store.url(file)) else { throw CocoaError(.fileReadCorruptFile) }
        var track: PitchTrack?
        if fx.needsPitch {
            track = pitchTrack(file, store: store, audio: audio, progress: { progress?($0 * 0.75) }, cancelled: cancelled)
        }
        if cancelled() { throw CancellationError() }
        let out = process(audio.samples, sampleRate: audio.sampleRate, track: track, fx: fx, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        let tmp = folder(store).appendingPathComponent(".\(UUID().uuidString).caf")
        try write(out, sampleRate: audio.sampleRate, to: tmp)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        tidy(file, keep: dest, store: store)
        progress?(1)
        return dest
    }

    /// Keep only the few most recent renders of a recording (enough for Undo to be instant).
    private static func tidy(_ file: String, keep: URL, store: StudioStore) {
        let dir = folder(store)
        let prefix = stem(file) + "-"
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "caf" && $0 != keep }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (u, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(3) { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: pitch analysis

    /// Pitch every 10 ms with YIN (the tuner's estimator), then cleaned up: octave slips fixed, blips smoothed,
    /// tiny gaps filled and stray fragments dropped.
    static func analyze(_ x: [Float], sampleRate sr: Double, progress: ((Double) -> Void)? = nil, cancelled: () -> Bool = { false }) -> PitchTrack {
        let hop = max(64, Int((sr * 0.01).rounded()))
        let w = 2048
        let tauMax = Int(sr / 60)
        let n = w + tauMax + 2            // so YIN's window starts at sample 1 of the slice
        let centre = 1 + w / 2 + 64       // the middle of what YIN looks at
        let frames = x.count / hop + 1
        var raw = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        let gate = max(0.0015, peak * 0.025)
        var slice = [Float](repeating: 0, count: n)
        for i in 0..<frames {
            if i % 250 == 0 {
                if cancelled() { break }
                progress?(Double(i) / Double(frames))
            }
            let s0 = i * hop - centre
            var any = false
            for k in 0..<n {
                let j = s0 + k
                let v: Float = j >= 0 && j < x.count ? x[j] : 0
                slice[k] = v
                if v != 0 { any = true }
            }
            guard any else { continue }
            var ms: Float = 0
            slice.withUnsafeBufferPointer { p in vDSP_measqv(p.baseAddress! + centre - 512, 1, &ms, 1024) }
            guard sqrt(ms) > gate else { continue }
            if let f = AudioEngine.yin(slice, sampleRate: sr, n: n), f > 70, f < 1100 { raw[i] = Float(f) }
        }
        return PitchTrack(sampleRate: sr, hop: hop, f0: clean(raw))
    }

    static func clean(_ raw: [Float]) -> [Float] {
        let n = raw.count
        guard n > 2 else { return raw }
        var m = raw.map { $0 > 0 ? 69 + 12 * log2($0 / 440) : Float.nan }
        // octave slips: compare with the local median
        var fixed = m
        for i in 0..<n where !m[i].isNaN {
            var near: [Float] = []
            for j in max(0, i - 6)...min(n - 1, i + 6) where !m[j].isNaN { near.append(m[j]) }
            near.sort()
            let med = near[near.count / 2]
            if abs(m[i] - med) > 7 {
                let alt = m[i] + 12 * ((med - m[i]) / 12).rounded()
                fixed[i] = abs(alt - med) < 2 ? alt : .nan
            }
        }
        m = fixed
        // single-frame blips
        var smooth = m
        for i in 1..<(n - 1) where !m[i - 1].isNaN && !m[i].isNaN && !m[i + 1].isNaN {
            smooth[i] = [m[i - 1], m[i], m[i + 1]].sorted()[1]
        }
        m = smooth
        // fill gaps of up to 30 ms inside a note
        var i = 0
        while i < n {
            guard m[i].isNaN else { i += 1; continue }
            var j = i
            while j < n && m[j].isNaN { j += 1 }
            if i > 0, j < n, j - i <= 3, abs(m[i - 1] - m[j]) < 2 {
                for k in i..<j { m[k] = m[i - 1] + (m[j] - m[i - 1]) * Float(k - i + 1) / Float(j - i + 1) }
            }
            i = j
        }
        // drop fragments shorter than 50 ms
        i = 0
        while i < n {
            guard !m[i].isNaN else { i += 1; continue }
            var j = i
            while j < n && !m[j].isNaN { j += 1 }
            if j - i < 5 { for k in i..<j { m[k] = .nan } }
            i = j
        }
        return m.map { $0.isNaN ? 0 : 440 * pow(2, ($0 - 69) / 12) }
    }

    /// Best-fitting major or minor key for the notes sung (Krumhansl–Kessler key profiles).
    static func detectKey(_ t: PitchTrack) -> (root: Int, scale: VocalScale)? {
        var hist = [Double](repeating: 0, count: 12)
        var count = 0
        for v in t.midi where !v.isNaN {
            hist[((Int(v.rounded()) % 12) + 12) % 12] += 1
            count += 1
        }
        guard count >= 30 else { return nil }
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / sqrt(da * db) : 0
        }
        var best = (root: 0, scale: VocalScale.major, r: -2.0)
        for root in 0..<12 {
            let rotated = (0..<12).map { hist[($0 + root) % 12] }
            let a = corr(rotated, major), b = corr(rotated, minor)
            if a > best.r { best = (root, .major, a) }
            if b > best.r { best = (root, .minor, b) }
        }
        return (best.root, best.scale)
    }

    static func key(for fx: VocalFX, track: PitchTrack?) -> (root: Int, scale: VocalScale) {
        if let r = fx.root { return (r, fx.scale) }
        return track.flatMap(detectKey) ?? (0, fx.scale)
    }

    // MARK: correction plan

    struct Plan {
        /// Per 10 ms frame, as MIDI note numbers (NaN = no pitch): what was sung, what the lead becomes,
        /// the note it was pulled to and the harmony voice.
        var input: [Float]
        var lead: [Float]
        var target: [Float]
        var harmony: [Float]?
    }

    /// The nearest note in the scale, sticking with the current note until another is clearly closer.
    static func snap(_ m: [Float], root: Int, scale: VocalScale) -> [Float] {
        let pcs = Set(scale.steps.map { ($0 + root) % 12 })
        var out = [Float](repeating: .nan, count: m.count)
        var prev: Int?
        for i in m.indices {
            let v = m[i]
            guard !v.isNaN else { prev = nil; continue }
            let c = Int(v.rounded())
            var best = c, d = Float.infinity
            for k in (c - 6)...(c + 6) where pcs.contains(((k % 12) + 12) % 12) {
                if abs(Float(k) - v) < d { d = abs(Float(k) - v); best = k }
            }
            if let p = prev, p != best, abs(v - Float(p)) <= d + 0.2 { out[i] = Float(p); continue }
            prev = best
            out[i] = Float(best)
        }
        return out
    }

    /// Semitones from a scale note to the harmony note above or below it.
    static func harmonyInterval(_ note: Int, _ h: VocalHarmony, root: Int, scale: VocalScale) -> Int {
        if h == .octaveDown { return -12 }
        if h == .off { return 0 }
        let ideal: Double = h == .thirdUp ? 3.5 : (h == .thirdDown ? -3.5 : 7)
        if scale == .chromatic { return h == .thirdUp ? 4 : (h == .thirdDown ? -3 : 7) }
        let pcs = Set(scale.steps.map { ($0 + root) % 12 })
        if scale.steps.count == 7, pcs.contains(((note % 12) + 12) % 12) {
            // diatonic: two or four scale steps away
            let degrees = h == .thirdUp ? 2 : (h == .thirdDown ? -2 : 4)
            var k = note, moved = 0
            let dir = degrees > 0 ? 1 : -1
            while moved < abs(degrees) { k += dir; if pcs.contains(((k % 12) + 12) % 12) { moved += 1 } }
            return k - note
        }
        var best = Int(ideal.rounded()), d = Double.infinity
        for s in (Int(ideal) - 2)...(Int(ideal) + 2) where pcs.contains((((note + s) % 12) + 12) % 12) {
            if abs(Double(s) - ideal) < d { d = abs(Double(s) - ideal); best = s }
        }
        return best
    }

    static func plan(_ track: PitchTrack, fx: VocalFX, key: (root: Int, scale: VocalScale)) -> Plan {
        let m = track.midi
        let target = snap(m, root: key.root, scale: key.scale)
        var lead = m
        if fx.tune {
            // the correction, eased in at the retune speed (zero-phase, so it doesn't lag behind the singing)
            var c = zip(target, m).map { $0 - $1 }
            let s = max(0, min(100, fx.speed)) / 100
            let tau = 0.4 * (1 - s) * (1 - s)
            if tau > 0.0015 {
                let a = Float(exp(-track.frameSeconds / tau))
                var i = 0
                while i < c.count {
                    guard !c[i].isNaN else { i += 1; continue }
                    var j = i
                    while j < c.count && !c[j].isNaN { j += 1 }
                    var y = c[i]
                    for k in i..<j { y = a * y + (1 - a) * c[k]; c[k] = y }
                    y = c[j - 1]
                    for k in stride(from: j - 1, through: i, by: -1) { y = a * y + (1 - a) * c[k]; c[k] = y }
                    i = j
                }
            }
            let amt = Float(max(0, min(100, fx.amount)) / 100)
            for i in m.indices where !m[i].isNaN { lead[i] = m[i] + c[i] * amt }
        }
        var harmony: [Float]?
        if fx.harmony != .off {
            var h = [Float](repeating: .nan, count: m.count)
            for i in m.indices where !lead[i].isNaN && !target[i].isNaN {
                h[i] = lead[i] + Float(harmonyInterval(Int(target[i]), fx.harmony, root: key.root, scale: key.scale))
            }
            harmony = h
        }
        return Plan(input: m, lead: lead, target: target, harmony: harmony)
    }

    // MARK: PSOLA pitch shifting

    /// One mark per cycle of the voice, on the peak of each cycle (so every grain is cut at the same point in its cycle).
    static func pitchMarks(_ x: [Float], sampleRate sr: Double, hop: Int, input: [Float]) -> (marks: [Double], periods: [Double]) {
        var lp = x
        VocalFilter.lowpass(1000, sr: sr).filtfilt(&lp)
        let n = x.count
        var marks: [Double] = [], periods: [Double] = []
        func period(_ t: Double) -> Double {
            let fi = t / Double(hop)
            let i0 = max(0, min(input.count - 1, Int(fi))), i1 = min(input.count - 1, i0 + 1)
            let a = input[i0], b = input[i1]
            let v: Float = a.isNaN ? b : (b.isNaN ? a : a + (b - a) * Float(fi - Double(i0)))
            return sr / (440 * pow(2, Double(v - 69) / 12))
        }
        func peak(_ lo: Double, _ hi: Double) -> Double? {
            let a = max(1, Int(lo.rounded(.up))), b = min(n - 2, Int(hi.rounded(.down)))
            guard b > a else { return nil }
            var bi = a
            for k in a...b where lp[k] > lp[bi] { bi = k }
            // parabolic refinement
            let y0 = lp[bi - 1], y1 = lp[bi], y2 = lp[bi + 1]
            let den = y0 - 2 * y1 + y2
            let off = den != 0 ? Double(0.5 * (y0 - y2) / den) : 0
            return Double(bi) + max(-0.5, min(0.5, off))
        }
        var i = 0
        while i < input.count {
            guard !input[i].isNaN else { i += 1; continue }
            var j = i
            while j + 1 < input.count && !input[j + 1].isNaN { j += 1 }
            let a0 = max(0, Double(i * hop - hop / 2)), a1 = min(Double(n - 1), Double(j * hop + hop / 2))
            var p = period(a0)
            var a = peak(a0, a0 + p) ?? a0
            while a <= a1 {
                p = period(a)
                marks.append(a); periods.append(p)
                let pred = a + p
                var b = peak(pred - 0.3 * p, pred + 0.3 * p) ?? pred
                if b < a + 0.5 * p { b = pred }
                a = b
            }
            i = j + 1
        }
        return (marks, periods)
    }

    /// TD-PSOLA: cut the voice into two-cycle grains at its pitch marks and lay them back down at the new pitch's spacing.
    /// Each grain keeps its own shape, so the voice's formants (its character) stay put. Unpitched sound passes through.
    static func psola(_ x: [Float], sampleRate sr: Double, hop: Int, input: [Float], output: [Float],
                      marks: (marks: [Double], periods: [Double]), cancelled: () -> Bool = { false }) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n)
        var wsum = [Float](repeating: 0, count: n)
        let frames = input.count
        let unvoiced = Double(hop) / 2
        out.withUnsafeMutableBufferPointer { op in
        wsum.withUnsafeMutableBufferPointer { wp in
        x.withUnsafeBufferPointer { xp in
            func grain(_ src: Double, _ dst: Double, _ half: Double) {
                let lo = max(0, Int((dst - half).rounded(.up))), hi = min(n - 1, Int((dst + half).rounded(.down)))
                guard hi >= lo else { return }
                let k = Double.pi / half
                for j in lo...hi {
                    let d = Double(j) - dst
                    let w = Float(0.5 + 0.5 * cos(k * d))
                    let sp = src + d
                    let i0 = Int(sp.rounded(.down))
                    guard i0 >= 0 && i0 + 1 < n else { continue }
                    let f = Float(sp - Double(i0))
                    op[j] += w * (xp[i0] + (xp[i0 + 1] - xp[i0]) * f)
                    wp[j] += w
                }
            }
            /// Input and output pitch at a moment (nil where there's no pitch).
            func pitch(_ t: Double) -> (Float, Float)? {
                let fi = t / Double(hop)
                let r = min(frames - 1, Int(fi.rounded()))
                guard r >= 0, !input[r].isNaN, !output[r].isNaN else { return nil }
                let i0 = min(frames - 1, Int(fi)), i1 = min(frames - 1, i0 + 1)
                if !input[i0].isNaN, !input[i1].isNaN, !output[i0].isNaN, !output[i1].isNaN {
                    let f = Float(fi - Double(i0))
                    return (input[i0] + (input[i1] - input[i0]) * f, output[i0] + (output[i1] - output[i0]) * f)
                }
                return (input[r], output[r])
            }
            var ts = 0.0
            var k = 0
            var steps = 0
            let ms = marks.marks, ps = marks.periods
            while ts < Double(n) {
                steps += 1
                if steps % 4096 == 0, cancelled() { return }
                if !ms.isEmpty, let (mi, mo) = pitch(ts) {
                    while k + 1 < ms.count && abs(ms[k + 1] - ts) <= abs(ms[k] - ts) { k += 1 }
                    if abs(ms[k] - ts) <= ps[k] {
                        let pin = sr / (440 * pow(2, Double(mi - 69) / 12))
                        let spacing = pin / pow(2, Double(mo - mi) / 12)
                        grain(ms[k], ts, ps[k])
                        ts += max(16, spacing)
                        continue
                    }
                }
                grain(ts, ts, unvoiced)
                ts += unvoiced
            }
        } } }
        // even out the overlap (more grains per second when shifting up); pitched-down gaps stay as they are
        for j in 0..<n { out[j] /= max(0.7, wsum[j]) }
        return out
    }

    // MARK: the whole chain

    /// Pitch correction, doubling, harmony and the vocal chain. Returns one channel, or two when voices are spread out.
    static func process(_ x: [Float], sampleRate sr: Double, track: PitchTrack?, fx: VocalFX, cancelled: () -> Bool = { false }) -> [[Float]] {
        var channels: [[Float]] = [x]
        if fx.needsPitch, let track {
            let p = plan(track, fx: fx, key: key(for: fx, track: track))
            let marks = pitchMarks(x, sampleRate: sr, hop: track.hop, input: p.input)
            let lead = fx.tune ? psola(x, sampleRate: sr, hop: track.hop, input: p.input, output: p.lead, marks: marks, cancelled: cancelled) : x
            if cancelled() { return [x] }
            var L = lead, R = lead
            var extra: Float = 0
            if fx.double {
                // each copy wanders a few cents and comes in a little late, like a second take
                for (side, (delay, phase)) in [(0.017, 0.0), (0.026, 2.1)].enumerated() {
                    var out = p.lead
                    for i in out.indices where !out[i].isNaN {
                        let t = Double(i) * track.frameSeconds
                        out[i] += Float(0.06 * sin(2 * .pi * 0.31 * t + phase) + 0.04 * sin(2 * .pi * 0.73 * t + phase * 1.7)) + (side == 0 ? 0.03 : -0.03)
                    }
                    let v = psola(x, sampleRate: sr, hop: track.hop, input: p.input, output: out, marks: marks, cancelled: cancelled)
                    let d = Int(delay * sr)
                    if side == 0 { for i in d..<x.count { L[i] += 0.55 * v[i - d] } } else { for i in d..<x.count { R[i] += 0.55 * v[i - d] } }
                }
                extra += 0.4
            }
            if let h = p.harmony {
                var v = psola(x, sampleRate: sr, hop: track.hop, input: p.input, output: h, marks: marks, cancelled: cancelled)
                // the harmony only sings where there's a note (no doubled consonants)
                var g: Float = 0
                let att = Float(exp(-1 / (0.01 * sr)))
                for i in v.indices {
                    let fi = min(h.count - 1, i / track.hop)
                    let on: Float = h[fi].isNaN ? 0 : 1
                    g = att * g + (1 - att) * on
                    v[i] *= g
                }
                for i in v.indices { L[i] += 0.5 * v[i]; R[i] += 0.5 * v[i] }
                extra += 0.35
            }
            if cancelled() { return [x] }
            if extra > 0 {
                let s = 1 / (1 + extra)
                for i in L.indices { L[i] *= s; R[i] *= s }
                channels = [L, R]
            } else {
                channels = [lead]
            }
        }
        if fx.chain { vocalChain(&channels, sampleRate: sr) }
        // never clip
        var peak: Float = 0
        for c in channels { var m: Float = 0; vDSP_maxmgv(c, 1, &m, vDSP_Length(c.count)); peak = max(peak, m) }
        if peak > 0.98 {
            let s = 0.98 / peak
            for c in channels.indices { for i in channels[c].indices { channels[c][i] *= s } }
        }
        return channels
    }

    /// High-pass (rumble and pops), de-esser (tames harsh "s" sounds), compressor (steady level) and presence EQ (clarity and air).
    static func vocalChain(_ ch: inout [[Float]], sampleRate sr: Double) {
        guard let n = ch.first?.count, n > 0 else { return }
        // 1. high-pass at 90 Hz, 24 dB/octave
        for c in ch.indices {
            VocalFilter.highpass(90, sr: sr).run(&ch[c])
            VocalFilter.highpass(90, sr: sr).run(&ch[c])
        }
        // 2. de-esser: turn the 5.5 kHz+ band down while it's much louder than the rest
        var mono = [Float](repeating: 0, count: n)
        for c in ch { for i in 0..<n { mono[i] += c[i] } }
        var hiMono = mono
        VocalFilter.highpass(5500, sr: sr).run(&hiMono)
        VocalFilter.highpass(5500, sr: sr).run(&hiMono)
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(n))
        let fast = Float(exp(-1 / (0.0008 * sr))), slow = Float(exp(-1 / (0.06 * sr)))
        var eS: Float = 0, eX: Float = 0, g: Float = 1
        var gains = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let s = abs(hiMono[i]), v = abs(mono[i])
            eS = s > eS ? fast * eS + (1 - fast) * s : slow * eS + (1 - slow) * s
            eX = v > eX ? fast * eX + (1 - fast) * v : slow * eX + (1 - slow) * v
            var want: Float = 1
            if eS > peak * 0.02 {
                let ratio = eS / (eX + 1e-6)
                if ratio > 0.4 { want = max(0.3, 0.4 / ratio) }
            }
            g = want < g ? fast * g + (1 - fast) * want : slow * g + (1 - slow) * want
            gains[i] = g
        }
        for c in ch.indices {
            var hi = ch[c]
            VocalFilter.highpass(5500, sr: sr).run(&hi)
            VocalFilter.highpass(5500, sr: sr).run(&hi)
            for i in 0..<n { ch[c][i] += (gains[i] - 1) * hi[i] }
        }
        // 3. compressor, 3:1 with a soft knee, 15 dB below the loudest moment
        mono = [Float](repeating: 0, count: n)
        for c in ch { for i in 0..<n { mono[i] += c[i] } }
        let rmsA = Float(exp(-1 / (0.01 * sr)))
        var e2: Float = 0
        var level = [Float](repeating: -120, count: n)
        var top: Float = -120
        let norm = 1 / Float(ch.count)
        for i in 0..<n {
            let v = mono[i] * norm
            e2 = rmsA * e2 + (1 - rmsA) * v * v
            level[i] = 10 * log10(e2 + 1e-12)
            top = max(top, level[i])
        }
        let thr = top - 15, ratio: Float = 3, knee: Float = 6
        let makeup = 15 * (1 - 1 / ratio) * 0.55
        let att = Float(exp(-1 / (0.005 * sr))), rel = Float(exp(-1 / (0.12 * sr)))
        var gr: Float = 0
        for i in 0..<n {
            let over = level[i] - thr
            var want: Float = 0
            if over > knee / 2 { want = over * (1 - 1 / ratio) } else if over > -knee / 2 {
                let x = over + knee / 2
                want = (1 - 1 / ratio) * x * x / (2 * knee)
            }
            gr = want > gr ? att * gr + (1 - att) * want : rel * gr + (1 - rel) * want
            let gain = pow(10, (makeup - gr) / 20)
            for c in ch.indices { ch[c][i] *= gain }
        }
        // 4. presence: less mud, more clarity and air
        for c in ch.indices {
            VocalFilter.peaking(300, gain: -2, q: 1, sr: sr).run(&ch[c])
            VocalFilter.peaking(3500, gain: 3, q: 0.9, sr: sr).run(&ch[c])
            VocalFilter.highShelf(10000, gain: 2.5, sr: sr).run(&ch[c])
        }
    }
}

// MARK: - Filters

/// A second-order filter (RBJ cookbook).
struct VocalFilter {
    var b0, b1, b2, a1, a2: Double

    private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> VocalFilter {
        VocalFilter(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func lowpass(_ f: Double, q: Double = 0.7071, sr: Double) -> VocalFilter {
        let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
    }

    static func highpass(_ f: Double, q: Double = 0.7071, sr: Double) -> VocalFilter {
        let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
    }

    static func peaking(_ f: Double, gain: Double, q: Double, sr: Double) -> VocalFilter {
        let A = pow(10, gain / 40), w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A)
    }

    static func highShelf(_ f: Double, gain: Double, sr: Double) -> VocalFilter {
        let A = pow(10, gain / 40), w = 2 * .pi * f / sr, c = cos(w), al = sin(w) / 2 * sqrt(2)
        let r = 2 * sqrt(A) * al
        return make(A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r),
                    (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r)
    }

    func run(_ x: inout [Float]) {
        var z1 = 0.0, z2 = 0.0
        for i in x.indices {
            let v = Double(x[i])
            let y = b0 * v + z1
            z1 = b1 * v - a1 * y + z2
            z2 = b2 * v - a2 * y
            x[i] = Float(y)
        }
    }

    /// Forwards then backwards: no delay, so features stay exactly where they are.
    func filtfilt(_ x: inout [Float]) {
        run(&x)
        x.reverse()
        run(&x)
        x.reverse()
    }
}

// MARK: - Background rendering for the editor

/// Keeps every track's vocal render up to date while you edit, in the background.
@Observable
final class VocalWork {
    /// Recording file → progress (0...1) while it's being processed.
    private(set) var busy: [String: Double] = [:]
    /// Recording file → its pitch, once known (for the pitch graph).
    private(set) var tracks: [String: PitchTrack] = [:]
    private(set) var failed: [String: String] = [:]
    /// Called on the main thread when a render finishes, so playback can switch to it.
    @ObservationIgnored var onReady: (() -> Void)?

    private final class Flag { private let lock = NSLock(); private var v = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func cancel() { lock.lock(); v = true; lock.unlock() } }
    @ObservationIgnored private var jobs: [String: (key: String, flag: Flag)] = [:]
    @ObservationIgnored private var analysing: Set<String> = []

    /// Start (or cancel) renders so they match the take's settings.
    func sync(_ t: Take, store: StudioStore) {
        let wanted = [(t.audioFile, t.edit.vocal)] + t.layers.map { ($0.file, $0.vocal) }
        for (file, job) in jobs where !wanted.contains(where: { $0.0 == file }) { job.flag.cancel(); jobs[file] = nil; busy[file] = nil }
        for (file, fx) in wanted {
            if fx.needsPitch { loadTrack(file, store: store, analyse: false) }
            let key = fx.renderKey
            if let j = jobs[file] {
                if j.key == key { continue }
                j.flag.cancel()
                jobs[file] = nil
                busy[file] = nil
            }
            guard fx.isActive, !VocalProcessor.isReady(file, fx: fx, store: store) else { continue }
            let flag = Flag()
            jobs[file] = (key, flag)
            busy[file] = 0
            failed[file] = nil
            Task.detached(priority: .userInitiated) { [weak self] in
                // wait until a slider settles
                try? await Task.sleep(for: .milliseconds(350))
                guard !flag.cancelled else { return }
                let report: (Double) -> Void = { p in Task { @MainActor in if self?.jobs[file]?.flag === flag { self?.busy[file] = p } } }
                let problem: String?
                do { try VocalProcessor.render(file, fx: fx, store: store, progress: report, cancelled: { flag.cancelled }); problem = nil }
                catch is CancellationError { problem = nil } catch { problem = error.localizedDescription }
                let track = fx.needsPitch ? VocalProcessor.cachedTrack(file, store: store) : nil
                await MainActor.run {
                    guard let self, self.jobs[file]?.flag === flag else { return }
                    self.jobs[file] = nil
                    self.busy[file] = nil
                    if let track { self.tracks[file] = track }
                    if let problem { self.failed[file] = problem }
                    self.onReady?()
                }
            }
        }
    }

    /// Get a recording's pitch for the graph: from the cache, or (with `analyse`) by working it out.
    func loadTrack(_ file: String, store: StudioStore, analyse: Bool) {
        guard tracks[file] == nil, !analysing.contains(file) else { return }
        if let t = VocalProcessor.cachedTrack(file, store: store) { tracks[file] = t; return }
        guard analyse else { return }
        analysing.insert(file)
        busy[file] = busy[file] ?? 0
        Task.detached(priority: .userInitiated) { [weak self] in
            let report: (Double) -> Void = { p in Task { @MainActor in if self?.analysing.contains(file) == true { self?.busy[file] = p } } }
            let t = VocalProcessor.pitchTrack(file, store: store, progress: report)
            await MainActor.run {
                guard let self else { return }
                self.analysing.remove(file)
                if self.jobs[file] == nil { self.busy[file] = nil }
                if let t { self.tracks[file] = t } else { self.failed[file] = "Couldn't read this recording." }
            }
        }
    }

    func cancelAll() {
        for (_, j) in jobs { j.flag.cancel() }
        jobs = [:]
    }
}
