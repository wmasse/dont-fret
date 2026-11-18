import Foundation
import Accelerate
import AVFoundation
import CoreML

/// Neural chord recogniser (prototype, off by default). A small CNN + bidirectional GRU, trained by
/// `scripts/chordnet` on GuitarSet and synthetic band mixes, reads a log-frequency spectrogram and gives
/// every frame a probability for each of 24 major/minor chords and "no chord". `Transcriber.viterbi` can
/// use its per-beat probabilities in place of the chroma-template scores; beats, key and structure are
/// worked out as before. Without the model (or with the flag off) the template path is used.
///
/// Turn it on with the `chordNet` user default or `DONTFRET_CHORDNET=1`.
/// The model is `ChordNet.mlmodelc` in the app's resources, or `CHORDNET_MODEL=<path>` (.mlmodelc or .mlpackage).
enum ChordNet {
    // must match scripts/chordnet/features.py
    static let sampleRate = 44100.0
    static let nFFT = 16384
    static let hop = 2048
    static let midiLow = 28.0
    static let binsPerSemitone = 2.0
    static let bins = 150
    static var fps: Double { sampleRate / Double(hop) }

    nonisolated(unsafe) static var forceEnabled: Bool? = nil
    static var enabled: Bool {
        if let f = forceEnabled { return f }
        if ProcessInfo.processInfo.environment["DONTFRET_CHORDNET"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "chordNet")
    }

    /// How strongly the network's log-probabilities count against the change costs (in nats per template-score unit × 14),
    /// and how much of the key prior is kept on top of them. Picked on held-out GuitarSet (scripts/chordnet/sweep.sh):
    /// 0.6 → 78.1% of beats right, 1.0 → 79.9%, 1.6 → 81.6%, 2.5 → 81.8%, 4.0 → 81.6%; key weight 0.25–1.0 barely matters.
    nonisolated(unsafe) static var emissionScale: Float = Float(ProcessInfo.processInfo.environment["CHORDNET_SCALE"] ?? "") ?? 1.6
    nonisolated(unsafe) static var keyWeight: Float = Float(ProcessInfo.processInfo.environment["CHORDNET_KEY"] ?? "") ?? 0.5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var cached: MLModel?

    static var model: MLModel? {
        lock.lock(); defer { lock.unlock() }
        if loaded { return cached }
        loaded = true
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["CHORDNET_MODEL"] { candidates.append(URL(fileURLWithPath: p)) }
        if let u = Bundle.main.url(forResource: "ChordNet", withExtension: "mlmodelc") { candidates.append(u) }
        candidates.append(URL(fileURLWithPath: "build/ChordNet.mlmodelc"))
        candidates.append(URL(fileURLWithPath: "Resources/ChordNet.mlpackage"))
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU      // flexible-length input isn't supported on the Neural Engine path
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            var u = url
            if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
                guard let c = try? MLModel.compileModel(at: url) else { continue }
                u = c
            }
            if let m = try? MLModel(contentsOf: u, configuration: config) { cached = m; return m }
        }
        return nil
    }

    static var available: Bool { model != nil }

    // MARK: features

    private static let window: [Float] = (0..<nFFT).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nFFT)) }

    /// Sparse triangular filters: for each output bin, the first FFT bin and its weights.
    static func filterbank(tuning: Double) -> [(start: Int, w: [Float])] {
        let df = sampleRate / Double(nFFT)
        return (0..<bins).map { b in
            let m = midiLow + Double(b) / binsPerSemitone + tuning
            let fc = 440 * pow(2, (m - 69) / 12)
            let hw = max(fc * (pow(2, 1.0 / 24) - 1), df)
            let lo = max(0, Int(((fc - hw) / df).rounded(.down))), hi = min(nFFT / 2 - 1, Int(((fc + hw) / df).rounded(.up)))
            var w: [Double] = []
            for k in lo...hi { w.append(max(0, 1 - abs(Double(k) * df - fc) / hw)) }
            let s = w.reduce(0, +)
            return (lo, w.map { Float($0 / max(1e-12, s)) })
        }
    }

    /// Log-frequency spectrogram, `T × bins` row-major. `tuning` in semitones (the recording's offset from A440).
    static func features(_ x: [Float], sampleRate sr: Double, tuning: Double = 0) -> (data: [Float], frames: Int) {
        let y = sr == sampleRate ? x : resample(x, from: sr, to: sampleRate)
        let pad = nFFT / 2
        let frames = 1 + y.count / hop
        var xp = [Float](repeating: 0, count: (frames - 1) * hop + nFFT)
        xp.withUnsafeMutableBufferPointer { p in y.withUnsafeBufferPointer { q in (p.baseAddress! + pad).update(from: q.baseAddress!, count: min(q.count, p.count - pad)) } }
        let fb = filterbank(tuning: tuning)
        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = nFFT / 2
        var re = [Float](repeating: 0, count: half), im = re, mags = re, w = [Float](repeating: 0, count: nFFT)
        var out = [Float](repeating: 0, count: frames * bins)
        for j in 0..<frames {
            xp.withUnsafeBufferPointer { p in vDSP_vmul(p.baseAddress! + j * hop, 1, window, 1, &w, 1, vDSP_Length(nFFT)) }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            } }
            for b in 0..<bins {
                let f = fb[b]
                var s: Float = 0
                mags.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress! + f.start, 1, f.w, 1, &s, vDSP_Length(f.w.count)) }
                out[j * bins + b] = s
            }
        }
        // normalise by the 99th percentile, then log(1 + 100 x)
        let sorted = out.sorted()
        let ref = max(sorted.isEmpty ? 1 : sorted[Int(0.99 * Double(sorted.count - 1))], 1e-9)
        var scale = 100 / ref
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(out.count))
        var n = Int32(out.count)
        vvlog1pf(&out, out, &n)
        return (out, frames)
    }

    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(x.count)) else { return x }
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let cap = AVAudioFrameCount(Double(x.count) * to / from + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return x }
        var fed = false
        _ = conv.convert(to: outBuf, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    // MARK: inference

    /// Per-frame probabilities, `T × 25` (0–11 major, 12–23 minor, 24 no chord), frame j at j / fps seconds.
    static func frameProbabilities(_ x: [Float], sampleRate sr: Double, tuning: Double = 0) -> [[Float]]? {
        guard let model else { return nil }
        let (data, T) = features(x, sampleRate: sr, tuning: tuning)
        guard T >= 16, let arr = try? MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: bins)], dataType: .float32) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: data.count)
        data.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: data.count) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["spec": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: input),
              let lp = out.featureValue(for: "logp")?.multiArrayValue else { return nil }
        let strides = lp.strides.map(\.intValue)
        var rows = [[Float]](repeating: [Float](repeating: 0, count: 25), count: T)
        // the shipped model outputs float32; anything else goes through NSNumber (no Float16: Intel builds lack it)
        let f32 = lp.dataType == .float32 ? lp.dataPointer.bindMemory(to: Float.self, capacity: lp.count) : nil
        for t in 0..<T { for c in 0..<25 {
            let v: Float = f32.map { $0[t * strides[1] + c * strides[2]] } ?? lp[[0, NSNumber(value: t), NSNumber(value: c)]].floatValue
            rows[t][c] = exp(v)
        } }
        return rows
    }

    /// Log-probability of each of the 24 chords on each beat: frame probabilities averaged over the beat,
    /// "no chord" left out and the rest renormalised.
    static func beatScores(_ frames: [[Float]], beatTimes: [Double], lastBeat: Double) -> [[Float]] {
        beatTimes.indices.map { i in
            let a = beatTimes[i], b = i + 1 < beatTimes.count ? beatTimes[i + 1] : a + lastBeat
            var lo = Int((a * fps).rounded(.up)), hi = Int((b * fps).rounded(.up))
            lo = max(0, min(frames.count - 1, lo)); hi = max(lo + 1, min(frames.count, hi))
            var acc = [Float](repeating: 0, count: 24)
            for t in lo..<hi { for c in 0..<24 { acc[c] += frames[t][c] } }
            let s = max(1e-12, acc.reduce(0, +))
            return acc.map { log(max(1e-4, $0 / s)) }
        }
    }
}
