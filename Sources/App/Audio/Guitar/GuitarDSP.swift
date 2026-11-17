import Foundation
import Accelerate

// MARK: - DSP building blocks for the guitar
//
// Everything here is allocation-free once constructed, so it can run on the audio thread:
// biquads, a partitioned FFT convolver for long impulse responses (guitar body + room, amp
// cabinet + room), a look-ahead peak limiter, a 4× oversampler for the overdrive, and a few
// init-time helpers (FFT, minimum-phase filters) used to build the impulse responses.

/// Deterministic random numbers, so the synthesized body and room are identical on every launch.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = (seed &* 0x9E37_79B9_7F4A_7C15) | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * uniform() }
    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(1e-12, uniform()), v = uniform()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

/// Second-order IIR section (RBJ cookbook designs).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
        var q = Biquad()
        q.b0 = Float(b0 / a0); q.b1 = Float(b1 / a0); q.b2 = Float(b2 / a0)
        q.a1 = Float(a1 / a0); q.a2 = Float(a2 / a0)
        return q
    }
    static func bandpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q)
        return make(al, 0, -al, 1 + al, -2 * cos(w), 1 - al)
    }
    static func lowpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
    }
    static func highpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
    }
    static func peak(_ f: Double, q: Double, db: Double, sr: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / sr, al = sin(w) / (2 * q), c = cos(w)
        return make(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A)
    }
    static func lowShelf(_ f: Double, db: Double, sr: Double, slope: Double = 1) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / sr, c = cos(w)
        let al = sin(w) / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2), r = 2 * sqrt(A) * al
        return make(A * ((A + 1) - (A - 1) * c + r), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - r),
                    (A + 1) + (A - 1) * c + r, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - r)
    }
    static func highShelf(_ f: Double, db: Double, sr: Double, slope: Double = 1) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / sr, c = cos(w)
        let al = sin(w) / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2), r = 2 * sqrt(A) * al
        return make(A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r),
                    (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r)
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    /// Magnitude response in dB at `f` (for design-time checks).
    func responseDB(_ f: Double, sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2, ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2, di = -(Double(a1) * s1 + Double(a2) * s2)
        return 10 * log10((nr * nr + ni * ni) / max(1e-30, dr * dr + di * di))
    }
}

// MARK: - Init-time spectral helpers

/// Complex FFT for building impulse responses (not used on the audio thread).
final class ComplexFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(log2n: Int) {
        self.log2n = vDSP_Length(log2n)
        n = 1 << log2n
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
                if inverse {
                    var k = 1 / Float(n)
                    vDSP_vsmul(rp.baseAddress!, 1, &k, rp.baseAddress!, 1, vDSP_Length(n))
                    vDSP_vsmul(ip.baseAddress!, 1, &k, ip.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
    }

    static func size(atLeast count: Int) -> Int {
        var l = 1
        while (1 << l) < count { l += 1 }
        return l
    }
}

enum Spectral {
    /// Linear convolution of two signals (FFT), truncated to `length` samples.
    static func convolve(_ a: [Float], _ b: [Float], length: Int? = nil) -> [Float] {
        let full = a.count + b.count - 1
        let fft = ComplexFFT(log2n: ComplexFFT.size(atLeast: full))
        var ar = a + [Float](repeating: 0, count: fft.n - a.count), ai = [Float](repeating: 0, count: fft.n)
        var br = b + [Float](repeating: 0, count: fft.n - b.count), bi = [Float](repeating: 0, count: fft.n)
        fft.transform(&ar, &ai, inverse: false)
        fft.transform(&br, &bi, inverse: false)
        for k in 0..<fft.n {
            let r = ar[k] * br[k] - ai[k] * bi[k], i = ar[k] * bi[k] + ai[k] * br[k]
            ar[k] = r; ai[k] = i
        }
        fft.transform(&ar, &ai, inverse: true)
        return Array(ar.prefix(min(length ?? full, full)))
    }

    /// Filters `x` with the minimum-phase filter whose magnitude response is `gainDB(Hz)`.
    /// Minimum phase means no pre-ringing: the filter only ever adds sound after the input.
    /// The result is `x.count + tail` samples long.
    static func minimumPhaseFilter(_ x: [Float], sr: Double, tail: Int = 0, gainDB: (Double) -> Double) -> [Float] {
        let len = x.count + tail
        let fft = ComplexFFT(log2n: ComplexFFT.size(atLeast: 2 * len))
        let n = fft.n
        // log magnitude on the full (symmetric) grid
        var cr = [Float](repeating: 0, count: n), ci = cr
        for k in 0...(n / 2) {
            let f = Double(k) * sr / Double(n)
            let lg = Float(gainDB(max(1, f)) / 20 * log(10))
            cr[k] = lg
            if k > 0 && k < n / 2 { cr[n - k] = lg }
        }
        // real cepstrum, folded to make it causal (minimum phase)
        fft.transform(&cr, &ci, inverse: true)
        for i in 1..<(n / 2) { cr[i] *= 2; ci[i] = 0 }
        for i in (n / 2 + 1)..<n { cr[i] = 0; ci[i] = 0 }
        ci[0] = 0; ci[n / 2] = 0
        fft.transform(&cr, &ci, inverse: false)
        // H = exp(cepstrum spectrum)
        var hr = [Float](repeating: 0, count: n), hi = hr
        for k in 0..<n {
            let m = exp(cr[k])
            hr[k] = m * cos(ci[k]); hi[k] = m * sin(ci[k])
        }
        var xr = x + [Float](repeating: 0, count: n - x.count), xi = [Float](repeating: 0, count: n)
        fft.transform(&xr, &xi, inverse: false)
        for k in 0..<n {
            let r = xr[k] * hr[k] - xi[k] * hi[k], i = xr[k] * hi[k] + xi[k] * hr[k]
            xr[k] = r; xi[k] = i
        }
        fft.transform(&xr, &xi, inverse: true)
        return Array(xr.prefix(len))
    }

    /// Smooth interpolation of a table of dB values given at log-spaced frequencies.
    static func interpolateDB(_ f: Double, freqs: [Double], db: [Double]) -> Double {
        guard let first = freqs.first, let last = freqs.last else { return 0 }
        if f <= first { return db[0] }
        if f >= last { return db[db.count - 1] }
        let lf = log(f)
        var i = 0
        while i < freqs.count - 2 && log(freqs[i + 1]) < lf { i += 1 }
        let t = (lf - log(freqs[i])) / (log(freqs[i + 1]) - log(freqs[i]))
        let s = t * t * (3 - 2 * t)          // smoothstep keeps the curve free of corners
        return db[i] + (db[i + 1] - db[i]) * s
    }
}

// MARK: - Partitioned convolution

/// One uniformly partitioned overlap-save FIR: mono in, stereo out, block size `B`.
/// Output for a block is available as soon as that block's input is complete.
final class PartitionedFIR {
    let B: Int
    private let P: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let hLr, hLi, hRr, hRi: UnsafeMutablePointer<Float>   // P × B each (packed real-FFT spectra)
    private let xr, xi: UnsafeMutablePointer<Float>                 // P × B frequency-domain delay line
    private var slot = 0
    private let input: UnsafeMutablePointer<Float>                  // 2B: previous block | current block
    private let accr, acci, time: UnsafeMutablePointer<Float>
    private let scale: Float

    init(left: ArraySlice<Float>, right: ArraySlice<Float>, block: Int) {
        B = block
        P = max(1, (max(left.count, right.count) + block - 1) / block)
        var l = 0
        while (1 << l) < 2 * block { l += 1 }
        log2n = vDSP_Length(l)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
        }
        hLr = buf(P * B); hLi = buf(P * B); hRr = buf(P * B); hRi = buf(P * B)
        xr = buf(P * B); xi = buf(P * B)
        input = buf(2 * B); accr = buf(B); acci = buf(B); time = buf(2 * B)
        // forward real FFT is ×2, inverse is ×N(=2B): a product of two forward spectra comes back ×(4·2B)
        scale = 1 / Float(8 * B)
        for (src, re, im) in [(left, hLr, hLi), (right, hRr, hRi)] {
            let a = Array(src)
            for p in 0..<P {
                for i in 0..<(2 * B) { time[i] = 0 }
                for i in 0..<B where p * B + i < a.count { time[i] = a[p * B + i] }
                forward(time, re + p * B, im + p * B)
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [hLr, hLi, hRr, hRi, xr, xi, input, accr, acci, time] { p.deallocate() }
    }

    private func forward(_ t: UnsafeMutablePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var s = DSPSplitComplex(realp: re, imagp: im)
        t.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ctoz($0, 2, &s, 1, vDSP_Length(B)) }
        vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    func reset() {
        for i in 0..<(P * B) { xr[i] = 0; xi[i] = 0 }
        for i in 0..<(2 * B) { input[i] = 0 }
    }

    /// Consumes `B` input samples and adds `B` output samples to `outL` / `outR`.
    func process(_ x: UnsafePointer<Float>, add outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        // slide the input window and transform it into the delay line
        for i in 0..<B { input[i] = input[B + i]; input[B + i] = x[i] }
        for i in 0..<(2 * B) { time[i] = input[i] }
        slot = (slot + P - 1) % P
        forward(time, xr + slot * B, xi + slot * B)
        for (hr, hi, out) in [(hLr, hLi, outL), (hRr, hRi, outR)] {
            for i in 0..<B { accr[i] = 0; acci[i] = 0 }
            var dc: Float = 0, ny: Float = 0
            var acc = DSPSplitComplex(realp: accr + 1, imagp: acci + 1)
            for p in 0..<P {
                let xs = ((slot + p) % P) * B
                // packed bin 0 holds two real values: DC (real part) and Nyquist (imaginary part)
                dc += xr[xs] * hr[p * B]; ny += xi[xs] * hi[p * B]
                var a = DSPSplitComplex(realp: xr + xs + 1, imagp: xi + xs + 1)
                var h = DSPSplitComplex(realp: hr + p * B + 1, imagp: hi + p * B + 1)
                vDSP_zvma(&a, 1, &h, 1, &acc, 1, &acc, 1, vDSP_Length(B - 1))
            }
            accr[0] = dc; acci[0] = ny
            var s = DSPSplitComplex(realp: accr, imagp: acci)
            vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(FFT_INVERSE))
            time.withMemoryRebound(to: DSPComplex.self, capacity: B) { vDSP_ztoc(&s, 1, $0, 2, vDSP_Length(B)) }
            for i in 0..<B { out[i] += time[B + i] * scale }
        }
    }
}

/// Long-impulse-response convolver: a short head partitioned at `block` samples for low latency,
/// and the rest of the response in 2048-sample partitions, which costs far less per sample.
/// Mono in, stereo out, `block` samples per call, no latency beyond the block itself.
final class Convolver {
    let block: Int
    private let head: PartitionedFIR
    private let tail: PartitionedFIR?
    private let split: Int                    // first tap handled by `tail`
    private let tailBlock = 2048
    private let tailIn: UnsafeMutablePointer<Float>
    private var tailFill = 0
    private let ring: UnsafeMutablePointer<Float>     // tail output waiting to be played (L then R)
    private let ringSize: Int
    private var clock = 0
    private let tmpL, tmpR: UnsafeMutablePointer<Float>
    let length: Int

    init(left: [Float], right: [Float], block: Int = 256) {
        self.block = block
        length = max(left.count, right.count)
        split = 2 * 2048
        let l = left + [Float](repeating: 0, count: max(0, length - left.count))
        let r = right + [Float](repeating: 0, count: max(0, length - right.count))
        head = PartitionedFIR(left: l.prefix(min(split, length)), right: r.prefix(min(split, length)), block: block)
        tail = length > split ? PartitionedFIR(left: l[split...], right: r[split...], block: tailBlock) : nil
        tailIn = .allocate(capacity: tailBlock); tailIn.initialize(repeating: 0, count: tailBlock)
        ringSize = 4 * tailBlock
        ring = .allocate(capacity: 2 * ringSize); ring.initialize(repeating: 0, count: 2 * ringSize)
        tmpL = .allocate(capacity: tailBlock); tmpR = .allocate(capacity: tailBlock)
        tmpL.initialize(repeating: 0, count: tailBlock); tmpR.initialize(repeating: 0, count: tailBlock)
        precondition(tailBlock % block == 0 && split >= 2 * tailBlock)
    }

    deinit { for p in [tailIn, ring, tmpL, tmpR] { p.deallocate() } }

    func reset() {
        head.reset(); tail?.reset()
        for i in 0..<(2 * ringSize) { ring[i] = 0 }
        tailFill = 0
    }

    /// `x`: `block` input samples. Writes (not adds) `block` samples to `outL` / `outR`.
    func process(_ x: UnsafePointer<Float>, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let pos = clock % ringSize
        for i in 0..<block {
            outL[i] = ring[pos + i]; outR[i] = ring[ringSize + pos + i]
            ring[pos + i] = 0; ring[ringSize + pos + i] = 0
        }
        head.process(x, add: outL, outR)
        if let tail {
            for i in 0..<block { tailIn[tailFill + i] = x[i] }
            tailFill += block
            if tailFill == tailBlock {
                // this tail block began at clock+block-tailBlock; its output belongs `split` samples later
                for i in 0..<tailBlock { tmpL[i] = 0; tmpR[i] = 0 }
                tail.process(tailIn, add: tmpL, tmpR)
                let start = clock + block - tailBlock + split
                for i in 0..<tailBlock {
                    let k = (start + i) % ringSize
                    ring[k] += tmpL[i]; ring[ringSize + k] += tmpR[i]
                }
                tailFill = 0
            }
        }
        clock += block
    }
}

// MARK: - Output stage

/// Transparent look-ahead peak limiter: does nothing at normal levels, never lets a peak past `ceiling`.
struct PeakLimiter {
    private let look: Int
    private var bufL: [Float], bufR: [Float]
    private var need: [Float]
    private var pos = 0
    private var gain: Float = 1
    private let attack: Float, release: Float
    let ceiling: Float

    init(sr: Double, ceiling: Float = 0.89, lookahead: Double = 0.0015, release: Double = 0.12) {
        look = max(2, Int(lookahead * sr))
        bufL = [Float](repeating: 0, count: look); bufR = bufL; need = [Float](repeating: 1, count: look)
        attack = Float(1 - exp(-5 / Double(look)))          // ~99% of the way within the look-ahead
        self.release = Float(1 - exp(-1 / (release * sr)))
        self.ceiling = ceiling
    }

    @inline(__always) mutating func process(_ l: inout Float, _ r: inout Float) {
        let peak = max(abs(l), abs(r))
        need[pos] = peak > ceiling ? ceiling / peak : 1
        // the quietest gain any sample still in the delay line needs
        var target: Float = 1
        for g in need where g < target { target = g }
        gain += (target - gain) * (target < gain ? attack : release)
        let dl = bufL[pos], dr = bufR[pos]
        bufL[pos] = l; bufR[pos] = r
        pos += 1; if pos == look { pos = 0 }
        // the smoothed gain can lag a sudden spike by a hair: never past the ceiling
        l = max(-ceiling, min(ceiling, dl * gain)); r = max(-ceiling, min(ceiling, dr * gain))
    }
}

/// Gentle program compressor, as on an acoustic guitar in a mix: a soft knee, an attack slow enough
/// to let the pick through, and a release that follows the strumming. A few dB of smoothing, no pumping.
struct GlueCompressor {
    private var env: Float = 0
    private let attack: Float, release: Float
    let thresholdDB: Float, ratio: Float, kneeDB: Float

    mutating func reset() { env = 0 }

    init(sr: Double, thresholdDB: Float, ratio: Float, kneeDB: Float = 8, attack: Double = 0.015, release: Double = 0.2) {
        self.thresholdDB = thresholdDB; self.ratio = ratio; self.kneeDB = kneeDB
        self.attack = Float(1 - exp(-1 / (attack * sr)))
        self.release = Float(1 - exp(-1 / (release * sr)))
    }

    /// Gain to apply to this stereo sample.
    @inline(__always) mutating func gain(_ l: Float, _ r: Float) -> Float {
        let p = max(l * l, r * r)
        env += (p - env) * (p > env ? attack : release)
        let over = 10 * log10(env + 1e-12) - thresholdDB
        let eff: Float
        if over <= -kneeDB / 2 { return 1 }
        else if over >= kneeDB / 2 { eff = over }
        else { let k = over + kneeDB / 2; eff = k * k / (2 * kneeDB) }
        return pow(10, -eff * (1 - 1 / ratio) / 20)
    }
}

/// 4× oversampling around a waveshaper, so overdrive harmonics don't fold back as harsh aliasing.
struct Oversampler4x {
    private static let design: [Float] = {
        // windowed-sinc low-pass at 0.45 × the original Nyquist, designed at the 4× rate (48 taps)
        let n = 48, fc = 0.45 / 4
        var h = (0..<n).map { i -> Double in
            let m = Double(i) - Double(n - 1) / 2
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return sinc * w
        }
        let s = h.reduce(0, +); h = h.map { $0 / s }
        return h.map(Float.init)
    }()
    private let taps = Oversampler4x.design                // copied at init, so the audio thread never builds it
    private var up = [Float](repeating: 0, count: 12)     // input history for the 4 polyphase branches
    private var down = [Float](repeating: 0, count: 48)
    private var upPos = 0, downPos = 0

    mutating func reset() {
        for i in 0..<up.count { up[i] = 0 }
        for i in 0..<down.count { down[i] = 0 }
    }

    /// Runs `shape` at 4× the sample rate on one input sample and returns one output sample.
    @inline(__always) mutating func process(_ x: Float, _ shape: (Float) -> Float) -> Float {
        up[upPos] = x
        var acc: Float = 0
        for phase in 0..<4 {
            // upsample: zero-stuffed input through the low-pass, one polyphase branch per sub-sample
            var y: Float = 0
            var k = phase, j = upPos
            while k < 48 {
                y += taps[k] * up[j]
                k += 4; j -= 1; if j < 0 { j = 11 }
            }
            down[downPos] = shape(y * 4)
            downPos += 1; if downPos == 48 { downPos = 0 }
        }
        // downsample: low-pass at the 4× rate, keep one sample in four
        var j = downPos - 1
        for k in 0..<48 {
            if j < 0 { j = 47 }
            acc += taps[k] * down[j]
            j -= 1
        }
        upPos += 1; if upPos == 12 { upPos = 0 }
        return acc
    }
}
