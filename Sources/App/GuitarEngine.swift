import Foundation
import Accelerate
import os

// MARK: - Guitar engine
//
// Six modal strings → bridge → body/mics/room (acoustic) or pickups → amp → cabinet/room (electric).
//
// Each string is a bank of resonators, one per harmonic and per polarization, so every partial's
// frequency and decay can match measurements of real steel strings (GuitarSet, see
// scripts/soundlab/measure.py):
//  • Inharmonicity: partial k sits at k·f0·√(1 + B·k²), with B measured per string.
//  • Decay: each partial loses (d0 + d1·f) dB/s, measured per string, so highs ring like steel.
//  • Two polarizations: vertical motion pushes the top hard and dies fast; horizontal motion barely
//    moves the top and rings on. Together they give a real string's punchy start and long, gently
//    beating tail ("two-stage decay").
//  • Pluck: the bridge force of a string released at a point (amplitudes sin(kπβ)/k) through the
//    touch's softness — a plectrum, the flesh of a thumb or a fingertip.
//  • Sympathetic resonance: free strings pick up the bridge motion and ring along.

/// What plucks the string.
enum Touch: UInt8 { case pick, thumb, finger }

/// Knobs the sound lab sweeps when matching the model to real recordings (scripts/soundlab).
/// The app always uses these defaults; they're only changed by the offline renderer, before rendering.
enum GuitarTuning {
    /// Level of the pick / finger contact noise.
    static var burstLevel: Float = 1
    /// Multiplies the cut-off of the pick's / the fingers' softness filter.
    static var pickBrightness = 1.0, fingerBrightness = 1.0
    /// Multiplies how fast high partials lose energy.
    static var highDecay = 1.0
    /// Level of the horizontal polarization at the bridge.
    static var horizontalWeight: Float = 0.32
    /// Level of the body's dense high-frequency modes (its own "knock"), as a gain offset (0 = as designed).
    static var bodyHighModes = 0.0
    /// Multiplies the extra loss of vertical vibration at the body's resonances (StringPhysics.bridgeLoss).
    static var bridgeLoss = 1.0
    /// Multiplies the vertical polarization's extra high-frequency loss (StringPhysics.verticalHighLoss).
    static var verticalHighDecay = 1.0

    /// Applies `name=value,name=value` (unknown names are reported).
    static func set(_ spec: String) {
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "="), v = kv.count == 2 ? Double(kv[1]) : nil
            switch (kv.first.map(String.init), v) {
            case ("burstLevel", let v?): burstLevel = Float(v)
            case ("pickBrightness", let v?): pickBrightness = v
            case ("fingerBrightness", let v?): fingerBrightness = v
            case ("highDecay", let v?): highDecay = v
            case ("horizontalWeight", let v?): horizontalWeight = Float(v)
            case ("bodyHighModes", let v?): bodyHighModes = v
            case ("bridgeLoss", let v?): bridgeLoss = v
            case ("verticalHighDecay", let v?): verticalHighDecay = v
            default: print("unknown tuning \(pair)")
            }
        }
    }
}

/// Behaviour of the six steel strings (standard light gauge, 25.4" scale), measured from GuitarSet.
enum StringPhysics {
    static let openMidi: [Int] = [40, 45, 50, 55, 59, 64]
    /// Inharmonicity coefficient of each open string. Fretting shortens the string: B grows with (f/f_open)².
    static let inharmonicity: [Double] = [8.0e-5, 5.6e-5, 5.0e-5, 2.9e-5, 5.6e-5, 2.2e-5]
    /// Partial decay in dB/s = base + slope · f(kHz). The slope is the string's own (internal and air)
    /// loss, the same for both polarizations; the base is mostly loss into the bridge, which depends on direction.
    static let decayBase: [Double] = [7.5, 7.5, 8.5, 9.5, 8.5, 9.5]
    static let decaySlope: [Double] = [7.5, 8.0, 9.5, 7.5, 8.5, 7.0]
    /// The bridge gives way more easily up and down: vertical motion loses its energy faster, horizontal rings on.
    static let verticalDecay = 1.6, horizontalDecay = 0.45
    /// Extra loss (dB/s) of vertical vibration at the body's main resonances (see `bridgeMobility`): the
    /// punchy start of a note that settles into the aftersound. Fitted to GuitarSet strum attacks.
    static let bridgeLoss = 80.0
    /// The vertical polarization also loses its highs faster, so the brilliance of a pluck fades in two
    /// stages like a real string's. Fitted to GuitarSet.
    static let verticalHighLoss = 2.0
    /// How much of the horizontal motion reaches the soundboard, relative to the vertical.
    static var horizontalWeight: Float { GuitarTuning.horizontalWeight }
    /// Frequency split between the polarizations, in Hz: a fraction of a hertz that differs from partial to
    /// partial, so they beat slowly and independently (never in lock-step, which would sound like a chorus pedal).
    static func polarizationSplit(string: Int, partial k: Int, frequency f: Double) -> Double {
        let h = sin(Double(k) * 12.9898 + Double(string) * 78.233) * 43758.5453
        // smaller on the lowest partials, so the note's pitch stays steady
        return (0.08 + 0.45 * (h - h.rounded(.down))) * min(1, f / 400)
    }
    /// Electric strings on a solid body ring longer.
    static let electricSustain = 0.62
    /// A tuner hears the slightly sharp upper partials, so a string tuned to read exactly right has its
    /// fundamental a touch flat: by about this many cents per unit of inharmonicity (measured with the
    /// app's own YIN tuner on the modeled strings).
    static let tunerCompensation = 56_000.0

    /// How easily the bridge moves up and down at `f`, relative to its easiest (the body's air and top
    /// resonances). Vertical string vibration near these frequencies drains into the body quickly: the
    /// punchy "prompt" part of a note, which then settles into the longer aftersound.
    static func bridgeMobility(_ f: Double) -> Double {
        var y = 0.06
        for (fm, q, g) in mobilityPeaks { let x = q * (f / fm - fm / f); y += g / (1 + x * x) }
        return min(1, y)
    }
    /// (frequency, Q, weight) of the resonances that make the bridge mobile; same modes as GuitarBody's.
    private static let mobilityPeaks: [(Double, Double, Double)] = [(98, 7, 1.0), (190, 9, 0.85), (234, 9, 0.6), (381, 10, 0.4), (466, 10, 0.3)]
    static let highestPartial = 16000.0
}

/// One string: resonators for both polarizations, laid out [vertical modes | horizontal modes].
final class ModalString {
    static let capacity = 208                      // modes per polarization (multiple of 8)
    let index: Int
    let sr: Double
    let re, im, cr, ci, w, g, freq, alpha: UnsafeMutablePointer<Float>
    private let scratchA, scratchB, scratchC: UnsafeMutablePointer<Float>
    /// Active modes per polarization (multiple of 8).
    private(set) var modes = 0
    /// Modes still worth computing (top ones die first).
    var live = 0
    /// Lowest `live` allowed: the modes that can still pick up sympathetic vibration.
    private var minLive = 0
    private(set) var baseMidi: Double
    private(set) var pitch: Double
    private var target: Double
    private var glide = 0.0                         // semitones per sample
    private var tension = 0.0                       // pitch rise after a hard pluck (semitones)
    private var tensionDecay = 1.0
    private var dampA = 0.0, dampB = 0.0            // extra loss, nepers/s: A + B·f(kHz)
    private(set) var damped = false
    private var dirty = true
    var energy: Float = 0
    var quietBlocks = 0
    // pick noise
    var burst: UnsafePointer<Float>?
    var burstLen = 0, burstPos = 0
    var burstGain: Float = 0

    init(index: Int, sr: Double) {
        self.index = index
        self.sr = sr
        func buf() -> UnsafeMutablePointer<Float> {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: 2 * Self.capacity * 4, alignment: 32)
            let p = raw.bindMemory(to: Float.self, capacity: 2 * Self.capacity)
            p.initialize(repeating: 0, count: 2 * Self.capacity)
            return p
        }
        re = buf(); im = buf(); cr = buf(); ci = buf(); w = buf(); g = buf(); freq = buf(); alpha = buf()
        scratchA = buf(); scratchB = buf(); scratchC = buf()
        baseMidi = Double(StringPhysics.openMidi[index]); pitch = baseMidi; target = baseMidi
    }

    deinit { for p in [re, im, cr, ci, w, g, freq, alpha, scratchA, scratchB, scratchC] { p.deallocate() } }

    var isGliding: Bool { glide != 0 || abs(tension) > 0.0005 }

    /// Lays out the partials for a new pitch. `keep` scales the vibration already on the string;
    /// `legato` keeps it as is (hammer-ons, pull-offs: the same vibration on a new length).
    func setPitch(_ midi: Double, tone: Int, keep: Float, legato: Bool) {
        let nominal = 440 * pow(2, (midi - 69) / 12)
        let fOpen = 440 * pow(2, (Double(StringPhysics.openMidi[index]) - 69) / 12)
        let B = StringPhysics.inharmonicity[index] * pow(max(1, nominal / fOpen), 2)
        let f0 = nominal * pow(2, -StringPhysics.tunerCompensation * B / 1200)
        let top = min(StringPhysics.highestPartial, 0.45 * sr)
        var count = 0
        while count < Self.capacity {
            let k = Double(count + 1)
            if k * f0 * sqrt(1 + B * k * k) > top { break }
            count += 1
        }
        let old = modes
        modes = max(8, (count + 7) / 8 * 8)
        let ln = log(10.0) / 20
        let sustain = tone == 0 ? 1 : StringPhysics.electricSustain
        for k in 0..<modes {
            let v = k, h = Self.capacity + k
            if k < count {
                let kk = Double(k + 1)
                let f = kk * f0 * sqrt(1 + B * kk * kk)
                let base = StringPhysics.decayBase[index] * ln * sustain
                let slope = StringPhysics.decaySlope[index] * f / 1000 * ln * sustain * GuitarTuning.highDecay
                // the long-ringing horizontal motion is exactly on pitch (a tuner hears the tail);
                // the fast-dying vertical motion sits a fraction of a hertz below
                let split = StringPhysics.polarizationSplit(string: index, partial: k, frequency: f)
                freq[v] = Float(f - split); freq[h] = Float(f)
                let bridge = StringPhysics.bridgeLoss * GuitarTuning.bridgeLoss * StringPhysics.bridgeMobility(f) * ln * (tone == 0 ? 1 : 0)
                let vh = StringPhysics.verticalHighLoss * GuitarTuning.verticalHighDecay
                alpha[v] = Float(base * StringPhysics.verticalDecay + slope * vh + bridge)
                alpha[h] = Float(base * StringPhysics.horizontalDecay + slope * 0.92 / vh.squareRoot() + bridge * 0.1)
            } else {
                freq[v] = 0; freq[h] = 0; alpha[v] = 1e4; alpha[h] = 1e4
            }
            if !legato || k >= old || k >= count {
                let s: Float = (legato && k < old && k < count) ? 1 : (k < old && k < count ? keep : 0)
                re[v] *= s; im[v] *= s; re[h] *= s; im[h] *= s
            }
        }
        for k in modes..<Self.capacity { re[k] = 0; im[k] = 0; re[Self.capacity + k] = 0; im[Self.capacity + k] = 0 }
        setWeights(tone: tone)
        var sym = 0
        while sym < count && Double(freq[sym]) < 3500 { sym += 1 }
        minLive = tone == 0 ? min(modes, (sym + 7) / 8 * 8) : 0
        live = modes
        baseMidi = midi; pitch = midi; target = midi; glide = 0; tension = 0
        dirty = true
    }

    /// How each mode reaches the output: the bridge (acoustic) or the pickups (electric).
    func setWeights(tone: Int) {
        for k in 0..<modes {
            let kk = Double(k + 1)
            var pickup = 1.0
            if tone == 1 {
                // neck + middle single coils: warm, a little hollow
                pickup = 0.6 * sin(kk * .pi * 0.22) + 0.4 * sin(kk * .pi * 0.15)
            } else if tone == 2 {
                // bridge humbucker: two coils 18 mm apart, near the bridge, bright and thick
                pickup = 0.5 * (sin(kk * .pi * 0.068) + sin(kk * .pi * 0.096)) * 2.2
            }
            let active: Float = freq[k] > 0 ? 1 : 0
            w[k] = Float(pickup) * active
            w[Self.capacity + k] = Float(pickup) * (tone == 0 ? StringPhysics.horizontalWeight : 0.8) * active
            // sympathetic pick-up follows the same bridge coupling as the output
            g[k] = w[k]; g[Self.capacity + k] = w[Self.capacity + k] * 0.5
        }
        if tone != 0 { minLive = 0 }
    }

    func addExcitation(amplitudes a: UnsafePointer<Float>, vertical: Float, horizontal: Float) {
        for k in 0..<modes {
            re[k] += a[k] * vertical
            re[Self.capacity + k] += a[k] * horizontal
        }
        live = modes
    }

    func clearDamping() { dampA = 0; dampB = 0; damped = false; dirty = true }

    /// Extra losses: `lowDB` dB/s at low frequencies, plus `perKHz` dB/s for every kHz.
    func setDamping(lowDB: Double, perKHz: Double, stopped: Bool) {
        let ln = log(10.0) / 20
        dampA = lowDB * ln; dampB = perKHz * ln
        damped = stopped
        dirty = true
    }

    /// A finger resting on the string: it's quiet after `seconds` (to −60 dB), the highs a little sooner.
    func stop(seconds: Double) {
        let r = 60 / max(0.01, seconds)
        setDamping(lowDB: r * 0.8, perKHz: r * 0.25, stopped: true)
    }

    func glide(to midi: Double, seconds: Double) {
        target = midi
        let steps = max(1, seconds * sr)
        glide = (target - pitch) / steps
        if glide == 0 { pitch = target }
    }

    func startTension(semitones: Double, seconds: Double) {
        tension = semitones
        tensionDecay = exp(-1 / max(1, seconds * sr))
        dirty = true
    }

    /// Advances glides by `n` samples; recomputes the resonators if anything moved.
    func advance(_ n: Int) {
        if glide != 0 {
            pitch += glide * Double(n)
            if (glide > 0 && pitch >= target) || (glide < 0 && pitch <= target) { pitch = target; glide = 0 }
            dirty = true
        }
        if tension != 0 {
            tension *= pow(tensionDecay, Double(n))
            if abs(tension) < 0.0005 { tension = 0 }
            dirty = true
        }
    }

    func updateCoefficients() {
        guard dirty, modes > 0 else { return }
        dirty = false
        let ratio = pow(2, (pitch + tension - baseMidi) / 12)
        let ph = Float(2 * Double.pi * ratio / sr), inv = Float(-1 / sr)
        let a = Float(dampA), b = Float(dampB / 1000)
        var n = Int32(modes)
        for off in stride(from: 0, through: Self.capacity, by: Self.capacity) {   // vertical, then horizontal
            for k in 0..<modes {
                scratchA[k] = freq[off + k] * ph
                scratchB[k] = (alpha[off + k] + a + b * freq[off + k]) * inv
            }
            vvexpf(scratchC, scratchB, &n)
            vvsincosf(scratchB, scratchA, scratchA, &n)          // sin → B, cos → A
            for k in 0..<modes {
                cr[off + k] = scratchC[k] * scratchA[k]
                ci[off + k] = scratchC[k] * scratchB[k]
            }
        }
    }

    /// Adds `n` samples of this string's output to `out`. `force` (optional) drives the resonators
    /// with the bridge motion caused by the other strings.
    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int, force: UnsafePointer<Float>?, coupling: Float) {
        guard live > 0 else { return }
        for off in stride(from: 0, through: Self.capacity, by: Self.capacity) {   // vertical, then horizontal
            var k = 0
            while k < live {
                let o = off + k
                var zr = UnsafeRawPointer(re + o).load(as: SIMD8<Float>.self)
                var zi = UnsafeRawPointer(im + o).load(as: SIMD8<Float>.self)
                let c = UnsafeRawPointer(cr + o).load(as: SIMD8<Float>.self)
                let s = UnsafeRawPointer(ci + o).load(as: SIMD8<Float>.self)
                let wv = UnsafeRawPointer(w + o).load(as: SIMD8<Float>.self)
                if let force {
                    let gv = UnsafeRawPointer(g + o).load(as: SIMD8<Float>.self) * coupling
                    for i in 0..<n {
                        out[i] += (zr * wv).sum()
                        let nr = zr * c - zi * s + gv * force[i]
                        zi = zr * s + zi * c
                        zr = nr
                    }
                } else {
                    for i in 0..<n {
                        out[i] += (zr * wv).sum()
                        let nr = zr * c - zi * s
                        zi = zr * s + zi * c
                        zr = nr
                    }
                }
                UnsafeMutableRawPointer(re + o).storeBytes(of: zr, as: SIMD8<Float>.self)
                UnsafeMutableRawPointer(im + o).storeBytes(of: zi, as: SIMD8<Float>.self)
                k += 8
            }
        }
    }

    /// Measures what's left and stops computing partials that have died away.
    func prune(forced: Bool) {
        var e: Float = 0
        var top = 0
        var k = 0
        while k < live {
            var m: Float = 0
            for j in k..<(k + 8) {
                let a = re[j] * re[j] + im[j] * im[j], b = re[Self.capacity + j] * re[Self.capacity + j] + im[Self.capacity + j] * im[Self.capacity + j]
                m = max(m, max(a, b))
                e += a * w[j] * w[j] + b * w[Self.capacity + j] * w[Self.capacity + j]
            }
            if m > 1e-11 { top = k + 8 }       // ~ −110 dB: inaudible, stop computing it
            k += 8
        }
        energy = e
        let floor = forced ? minLive : 0
        if top < live { live = max(top, floor) }
        if e < 1e-18 {
            // silent: clear exactly (decaying values would otherwise end up as slow denormals)
            for j in 0..<Self.capacity { re[j] = 0; im[j] = 0; re[Self.capacity + j] = 0; im[Self.capacity + j] = 0 }
            live = floor
            energy = 0
        }
    }

    /// Back to an open, untouched string (the hand has left it).
    func release(tone: Int) {
        setPitch(Double(StringPhysics.openMidi[index]), tone: tone, keep: 0, legato: false)
        live = minLive
        clearDamping()
        updateCoefficients()
    }
}

/// Everything the audio thread needs. Events are queued from any thread and picked up at the start
/// of each block; they then fire on their exact sample.
final class GuitarCore {
    enum Kind: UInt8 {
        case pluck
        /// Stop a string. `decay` = seconds until it's quiet (0 = a quick finger touch).
        case damp
        /// A dead, fretting-hand-muted string hit by the pick (percussive "chick").
        case chuck
        /// Change the pitch of a ringing string without picking it (bends, slides, vibrato).
        case retune
        /// The fretting hand now holds this string at `midi`; if it was ringing at another pitch it stops.
        case hold
    }
    struct Event {
        var kind: Kind; var string: Int; var midi: Int; var velocity: Float; var bright: Float; var delay: Int; var pick: Float
        /// Extra pitch in semitones (bends, slides, vibrato, real-world tuning).
        var detune: Float = 0
        /// How much of the string's current vibration survives a new pluck (≥ 0.5 = legato: hammer-on/pull-off).
        var keep: Float = 0.12
        /// What plucks the string.
        var touch: Touch = .pick
        /// Palm mute for this note: 0 open … 1 fully muted at the bridge.
        var mute: Float = 0
        /// For `.damp`: seconds until the string is quiet.
        var decay: Float = 0

        static func damp(_ string: Int, at delay: Int, seconds: Float = 0) -> Event {
            Event(kind: .damp, string: string, midi: 0, velocity: 0, bright: 0, delay: delay, pick: 0, decay: seconds)
        }
    }

    static let block = 256
    let sr: Double
    /// 0 = acoustic, 1 = electric clean, 2 = electric overdrive. Read at the start of each block.
    var tone = 0
    private var activeTone = 0
    private let strings: [ModalString]
    private var convolvers: [Convolver?] = [nil, nil, nil]
    private var ampModels: [AmpModel]
    private var compressors: [GlueCompressor]
    private var limiter: PeakLimiter
    private let src, force, prevTotal, outL, outR, amps: UnsafeMutablePointer<Float>
    private let own: [UnsafeMutablePointer<Float>]
    private let prevOwn: [UnsafeMutablePointer<Float>]
    private var outPos = GuitarCore.block
    private var quietBlocks = 1 << 30
    /// Pick, finger, thumb and chuck noises, one contiguous pool: (touch or 3 for chuck) → (offset, length)s.
    private let burstPool: UnsafeMutablePointer<Float>
    private let burstIndex: [[(offset: Int, length: Int)]]

    private var lock = os_unfair_lock()
    private var incoming: [Event] = []
    private var pending: [(at: Int, e: Event)] = []
    private var clock = 0
    private var rng = SeededRandom(seed: UInt64.random(in: 1...UInt64.max))

    /// Overall level per tone, matched to the previous engine's loudness so the app's volume is unchanged
    /// (acoustic, electric clean, electric drive).
    private let outputGain: [Float] = [0.42, 0.39, 0.095]
    /// Strength of sympathetic coupling between strings.
    private let coupling: Float = 2.2e-6

    init(sampleRate: Double) {
        sr = sampleRate
        strings = (0..<6).map { ModalString(index: $0, sr: sampleRate) }
        func buf(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
        }
        let b = GuitarCore.block
        src = buf(b); force = buf(b); prevTotal = buf(b); outL = buf(b); outR = buf(b); amps = buf(ModalString.capacity)
        own = (0..<6).map { _ in buf(b) }
        prevOwn = (0..<6).map { _ in buf(b) }
        ampModels = (0..<3).map { AmpModel(sr: sampleRate, tone: $0) }
        compressors = (0..<3).map { Self.makeCompressor(tone: $0, sr: sampleRate) }
        limiter = PeakLimiter(sr: sampleRate, release: 0.05)
        let banks = [Self.makeBursts(sr: sampleRate, touch: .pick), Self.makeBursts(sr: sampleRate, touch: .thumb),
                     Self.makeBursts(sr: sampleRate, touch: .finger), Self.makeChuckBursts(sr: sampleRate)]
        let pool = buf(banks.joined().reduce(0) { $0 + $1.count })
        var offset = 0
        var index: [[(offset: Int, length: Int)]] = []
        for bank in banks {
            var entries: [(offset: Int, length: Int)] = []
            for b in bank {
                for (i, v) in b.enumerated() { pool[offset + i] = v }
                entries.append((offset, b.count))
                offset += b.count
            }
            index.append(entries)
        }
        burstPool = pool
        burstIndex = index
        incoming.reserveCapacity(128)
        pending.reserveCapacity(512)
        for t in 0..<3 { convolvers[t] = makeConvolver(t) }
        for s in strings { s.release(tone: 0) }
    }

    deinit {
        for p in [src, force, prevTotal, outL, outR, amps, burstPool] + own + prevOwn { p.deallocate() }
    }

    /// Compression per tone. The acoustic gets none: compressing it lifts the tail of every strum,
    /// which measurably moved its decay away from the studio recordings (scripts/soundlab), so it keeps
    /// a real recording's dynamics and only the limiter shaves the first milliseconds of the loudest
    /// strums. The clean electric gets a little glue; the overdrive is compressed by its own clipping.
    private static func makeCompressor(tone: Int, sr: Double) -> GlueCompressor {
        switch tone {
        case 1: return GlueCompressor(sr: sr, thresholdDB: -18, ratio: 2, attack: 0.006, release: 0.15)
        case 2: return GlueCompressor(sr: sr, thresholdDB: -12, ratio: 1.5)
        default: return GlueCompressor(sr: sr, thresholdDB: 0, ratio: 1)
        }
    }

    private func makeConvolver(_ t: Int) -> Convolver {
        let ir = GuitarBody.impulseResponse(tone: t, sr: sr)
        return Convolver(left: ir.l, right: ir.r, block: Self.block)
    }

    func enqueue(_ events: [Event]) {
        os_unfair_lock_lock(&lock)
        incoming += events
        os_unfair_lock_unlock(&lock)
    }

    /// Renders `count` stereo frames. Returns false when the output is silent.
    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ count: Int) -> Bool {
        if os_unfair_lock_trylock(&lock) {
            for e in incoming { pending.append((clock + e.delay, e)) }
            incoming.removeAll(keepingCapacity: true)
            os_unfair_lock_unlock(&lock)
        }
        let tail = (convolvers[activeTone]?.length ?? 0) + Int(0.25 * sr)
        if pending.isEmpty && outPos == Self.block && quietBlocks * Self.block > tail {
            for i in 0..<count { L[i] = 0; R[i] = 0 }
            return false
        }
        var i = 0
        while i < count {
            if outPos == Self.block { synthBlock(); outPos = 0 }
            let n = min(count - i, Self.block - outPos)
            for k in 0..<n { L[i + k] = outL[outPos + k]; R[i + k] = outR[outPos + k] }
            outPos += n; i += n
        }
        return true
    }

    // MARK: Block synthesis

    private func synthBlock() {
        let B = Self.block
        if tone != activeTone, (0..<3).contains(tone) {
            activeTone = tone
            // everything was built up front: switching only clears state (nothing allocates here)
            convolvers[tone]?.reset()
            ampModels[tone].reset()
            compressors[tone].reset()
            for s in strings { s.setWeights(tone: tone) }
        }
        for k in 0..<B { src[k] = 0 }
        for s in 0..<6 { for k in 0..<B { own[s][k] = 0 } }
        let acoustic = activeTone == 0
        var t = 0
        while t < B {
            fireDue(clock + t)
            var end = B
            for p in pending where p.at - clock < end && p.at - clock > t { end = p.at - clock }
            if strings.contains(where: { $0.isGliding }) { end = min(end, t + 32) }
            let n = end - t
            for (s, st) in strings.enumerated() {
                st.updateCoefficients()
                let free = acoustic && !st.damped
                if free {
                    for k in 0..<n { force[k] = prevTotal[t + k] - prevOwn[s][t + k] }
                }
                st.render(own[s] + t, n, force: free ? UnsafePointer(force) : nil, coupling: coupling)
                st.advance(n)
                if let b = st.burst {
                    var k = 0
                    while k < n && st.burstPos < st.burstLen {
                        src[t + k] += b[st.burstPos] * st.burstGain
                        st.burstPos += 1; k += 1
                    }
                    if st.burstPos >= st.burstLen { st.burst = nil }
                }
            }
            t = end
        }
        // sum the strings; remember this block for sympathetic coupling in the next one
        for k in 0..<B { prevTotal[k] = 0 }
        for s in 0..<6 {
            let o = own[s]
            for k in 0..<B { src[k] += o[k]; prevTotal[k] += o[k]; prevOwn[s][k] = o[k] }
        }
        var loud: Float = 0
        for k in 0..<B { loud = max(loud, abs(src[k])) }
        for st in strings {
            st.prune(forced: acoustic && !st.damped)
            if st.damped && st.energy < 1e-12 {
                st.quietBlocks += 1
                if st.quietBlocks * B > Int(1.5 * sr) { st.release(tone: activeTone); st.quietBlocks = 0 }
            } else { st.quietBlocks = 0 }
        }
        // the final stage: body + mics + room, or amp + cabinet + room
        if activeTone != 0 { for k in 0..<B { src[k] = ampModels[activeTone].process(src[k]) } }
        if let conv = convolvers[activeTone] { conv.process(src, outL, outR) } else { for k in 0..<B { outL[k] = src[k]; outR[k] = src[k] } }
        let gain = outputGain[activeTone]
        for k in 0..<B {
            var l = outL[k] * gain, r = outR[k] * gain
            let g = compressors[activeTone].gain(l, r)
            l *= g; r *= g
            limiter.process(&l, &r)
            outL[k] = l; outR[k] = r
        }
        quietBlocks = loud > 1e-6 || strings.contains(where: { $0.energy > 1e-12 }) ? 0 : quietBlocks + 1
        clock += B
    }

    private func fireDue(_ now: Int) {
        var k = 0
        // events at the same time fire in the order they were queued
        while k < pending.count {
            if pending[k].at <= now {
                let e = pending.remove(at: k).e
                apply(e)
            } else { k += 1 }
        }
    }

    private func apply(_ e: Event) {
        guard (0..<6).contains(e.string) else { return }
        let st = strings[e.string]
        switch e.kind {
        case .damp:
            st.stop(seconds: e.decay > 0 ? Double(e.decay) : 0.09)
        case .hold:
            if st.energy > 1e-9 && abs(st.pitch - Double(e.midi)) > 0.4 { st.stop(seconds: 0.07) }
        case .chuck:
            chuck(e)
        case .pluck:
            pluck(e)
        case .retune:
            st.glide(to: Double(e.midi) + Double(e.detune), seconds: 0.012)
        }
    }

    private func pluck(_ e: Event) {
        let st = strings[e.string]
        let midi = Double(e.midi) + Double(e.detune)
        let legato = e.keep >= 0.5 && st.energy > 1e-10
        st.setPitch(midi, tone: activeTone, keep: e.keep, legato: legato)
        st.clearDamping()
        let mute = Double(max(0, min(1, e.mute)))
        if mute > 0 {
            // the palm rests on the strings at the bridge: short notes, the highs go first
            st.setDamping(lowDB: 95 * mute, perKHz: 85 * mute, stopped: false)
        }
        let v = Double(max(0.02, min(1.2, e.velocity)))
        excite(st, velocity: v, beta: Double(e.pick), bright: Double(e.bright), touch: e.touch, mute: mute)
        // a hard pluck stretches the string: the pitch starts up to ~2 cents sharp and settles
        st.startTension(semitones: 0.02 * v * v * (1.1 - 0.1 * Double(e.string)), seconds: 0.16)
        st.updateCoefficients()
        // noise of the pick or finger meeting the string
        startBurst(st, bank: Int(e.touch.rawValue), gain: Float(v) * (e.touch == .pick ? 0.010 : 0.006) * (0.5 + e.bright) * Float(1 - 0.6 * mute) * GuitarTuning.burstLevel)
    }

    /// Adds the pluck's vibration to the string's resonators.
    private func excite(_ st: ModalString, velocity v: Double, beta: Double, bright: Double, touch: Touch, mute: Double) {
        let beta = max(0.04, min(0.5, beta * rng.uniform(0.93...1.07)))
        var fc: Double, order: Double, vertical: Double
        switch touch {
        case .pick:   fc = (1900 + 6000 * bright * (0.5 + 0.5 * v)) * GuitarTuning.pickBrightness; order = 0.85; vertical = 0.45
        case .finger: fc = (1100 + 3200 * bright * (0.55 + 0.45 * v)) * GuitarTuning.fingerBrightness; order = 1.1; vertical = 0.68
        case .thumb:  fc = (520 + 1600 * bright * (0.55 + 0.45 * v)) * GuitarTuning.fingerBrightness; order = 1.4; vertical = 0.6
        }
        fc *= 1 - 0.55 * mute
        let horizontal = sqrt(1 - vertical * vertical)
        var norm = 0.0
        for k in 1...8 { let s = sin(Double(k) * .pi * beta) / Double(k); norm += s * s }
        let a0 = v / sqrt(norm)
        for k in 0..<ModalString.capacity { amps[k] = 0 }
        for k in 0..<st.modes where st.freq[k] > 0 {
            let kk = Double(k + 1)
            let f = Double(st.freq[k])
            let soft = 1 / (1 + pow(f / fc, 2 * order) * 0.5 + pow(f / fc, order) * 0.5)
            amps[k] = Float(a0 * sin(kk * .pi * beta) / kk * soft)
        }
        st.addExcitation(amplitudes: amps, vertical: Float(vertical), horizontal: Float(horizontal))
    }

    private func chuck(_ e: Event) {
        let st = strings[e.string]
        // the fretting hand goes slack on the string: whatever was ringing stops, the pick thuds
        st.setPitch(Double(e.midi) + Double(e.detune), tone: activeTone, keep: 0.05, legato: false)
        st.setDamping(lowDB: 420, perKHz: 260, stopped: true)
        let v = Double(max(0.02, min(1.2, e.velocity)))
        excite(st, velocity: v * 0.55, beta: Double(e.pick), bright: 0.3, touch: .pick, mute: 0.5)
        st.updateCoefficients()
        startBurst(st, bank: 3, gain: Float(v) * 0.022)
    }

    private func startBurst(_ st: ModalString, bank: Int, gain: Float) {
        let options = burstIndex[bank]
        guard !options.isEmpty else { return }
        let b = options[Int(rng.next() % UInt64(options.count))]
        st.burst = UnsafePointer(burstPool + b.offset)
        st.burstLen = b.length; st.burstPos = 0; st.burstGain = gain
    }

    // MARK: Pick and finger noise

    /// Short noise bursts: the click of a plectrum, the soft brush of a fingertip, the thump of a thumb.
    private static func makeBursts(sr: Double, touch: Touch) -> [[Float]] {
        var rng = SeededRandom(seed: 0x9C1C + UInt64(touch.rawValue))
        return (0..<6).map { _ in
            let n = Int(0.03 * sr)
            var a: Biquad, b: Biquad, tau: Double, attack: Double
            switch touch {
            case .pick:   a = .highpass(1400, q: 0.7, sr: sr); b = .peak(4200, q: 0.9, db: 6, sr: sr); tau = 0.0016; attack = 0.0002
            case .finger: a = .bandpass(1100, q: 0.6, sr: sr); b = .lowpass(3200, q: 0.7, sr: sr); tau = 0.0028; attack = 0.0006
            case .thumb:  a = .lowpass(700, q: 0.7, sr: sr); b = .highpass(90, q: 0.7, sr: sr); tau = 0.0045; attack = 0.0008
            }
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(i) / sr
                let env = (1 - exp(-t / attack)) * (exp(-t / tau) + 0.08 * exp(-t / (tau * 5)))
                out[i] = b.process(a.process(Float(rng.gaussian() * env)))
            }
            let peak = out.map(abs).max() ?? 1
            return out.map { $0 / max(1e-6, peak) }
        }
    }

    /// The scratch of a pick dragged across muted strings.
    private static func makeChuckBursts(sr: Double) -> [[Float]] {
        var rng = SeededRandom(seed: 0xC4C)
        return (0..<6).map { _ in
            let n = Int(0.045 * sr)
            var a = Biquad.bandpass(2300, q: 0.55, sr: sr), b = Biquad.peak(5200, q: 1, db: 4, sr: sr), c = Biquad.lowpass(9000, q: 0.7, sr: sr)
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(i) / sr
                let env = (1 - exp(-t / 0.0012)) * exp(-t / 0.011)
                out[i] = c.process(b.process(a.process(Float(rng.gaussian() * env))))
            }
            let peak = out.map(abs).max() ?? 1
            return out.map { $0 / max(1e-6, peak) }
        }
    }
}

// MARK: - Electric: pickups into an amplifier

/// Pickup resonance, preamp and tone stack. Overdrive runs 4× oversampled so it stays smooth.
struct AmpModel {
    private var res: Biquad, pre1: Biquad, pre2: Biquad, post: Biquad
    private var low: Biquad, mid: Biquad, high: Biquad, dc: Biquad
    private var os = Oversampler4x()
    private let tone: Int

    init(sr: Double, tone: Int) {
        self.tone = tone
        if tone == 2 {
            res = .peak(2600, q: 1.2, db: 3, sr: sr)          // humbucker resonance
            pre1 = .highpass(380, q: 0.6, sr: sr)              // tighten the lows before clipping
            pre2 = .peak(760, q: 0.8, db: 9, sr: sr)           // classic overdrive mid push
            post = .lowpass(6500, q: 0.7, sr: sr)
            low = .lowShelf(120, db: 5, sr: sr); mid = .peak(480, q: 0.8, db: -3, sr: sr); high = .highShelf(3000, db: 1.5, sr: sr)
        } else {
            res = .peak(3600, q: 1.6, db: 4, sr: sr)           // single-coil resonance
            pre1 = .highpass(40, q: 0.7, sr: sr)
            pre2 = .peak(700, q: 0.7, db: 0, sr: sr)
            post = .lowpass(8000, q: 0.7, sr: sr)
            low = .lowShelf(150, db: 1, sr: sr); mid = .peak(700, q: 0.7, db: -1.5, sr: sr); high = .highShelf(3500, db: 2, sr: sr)
        }
        dc = .highpass(20, q: 0.7, sr: sr)
    }

    mutating func reset() {
        for i in 0..<8 { withFilter(i) { $0.reset() } }
        os.reset()
    }

    private mutating func withFilter(_ i: Int, _ f: (inout Biquad) -> Void) {
        switch i {
        case 0: f(&res)
        case 1: f(&pre1)
        case 2: f(&pre2)
        case 3: f(&post)
        case 4: f(&low)
        case 5: f(&mid)
        case 6: f(&high)
        default: f(&dc)
        }
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        var y = res.process(x)
        if tone == 2 {
            y = pre2.process(pre1.process(y)) * 30
            y = os.process(y) { v in
                // two asymmetric triode-like stages
                let a = tanh(v + 0.18) - 0.178
                return tanh(a * 2.2) * 0.9
            }
            y = post.process(y)
        } else {
            y *= 2.4
            y = tanh(y * 0.8) / 0.8 + 0.035 * y * y           // gentle tube colour, mostly clean
            y = post.process(y)
        }
        y = dc.process(y)
        return high.process(mid.process(low.process(y)))
    }
}
