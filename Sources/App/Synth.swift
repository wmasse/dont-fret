import Foundation
import AVFoundation
import os

// MARK: - Acoustic guitar model
//
// Six persistent strings (extended Karplus–Strong with fractional-delay tuning, pick-position
// filtering, frequency-dependent loss), a spruce-top body made of resonant modes, a stereo
// spread across the strings and a small room. Strings ring into each other like a real guitar:
// re-striking a string replaces its vibration, unplayed strings are muted by the fretting hand.

/// One string as a delay-line waveguide.
struct StringVoice {
    static let capacity = 4096
    var buf: UnsafeMutablePointer<Float>
    var w = 0
    var n = 100                    // integer part of the loop delay
    var apC: Float = 0             // allpass coefficient for the fractional part
    var apX: Float = 0, apY: Float = 0
    var prev: Float = 0
    var gain: Float = 0.996        // per-period loss
    var bright: Float = 0.5        // loop-filter balance; lower = brighter
    var damp: Float = 1            // extra loss while muting
    var energy: Float = 0
    var pan: Float = 0             // -1 left … 1 right

    init() {
        buf = .allocate(capacity: Self.capacity)
        buf.initialize(repeating: 0, count: Self.capacity)
    }

    mutating func tune(freq f: Double, sr: Double, sustain: Double = 1) {
        // the two-point loop filter adds half a sample of delay
        let total = sr / f - 0.5
        var ni = Int(total)
        var frac = total - Double(ni)
        if frac < 0.15 { ni -= 1; frac += 1 }        // keep the allpass well-behaved
        n = max(2, min(Self.capacity - 2, ni))
        apC = Float((1 - frac) / (1 + frac))
        // decay: bass strings ring longer than treble (seconds to −60 dB for the fundamental)
        let t60 = max(2.6, min(7.5, 7.5 - 4.6 * (f - 82) / 580)) * sustain
        gain = Float(pow(10, -3 / (f * t60)))
        bright = Float(0.5 - min(0.12, 0.12 * (f - 82) / 500))
    }

    @inline(__always) mutating func tick() -> Float {
        var r = w - n
        if r < 0 { r += Self.capacity }
        let x = buf[r]
        // frequency-dependent loss (one-zero lowpass)
        let lp = (gain * damp) * ((1 - bright) * x + bright * prev)
        prev = x
        // fractional delay
        let y = apC * lp + apX - apC * apY
        apX = lp; apY = y
        buf[w] = y
        w += 1
        if w == Self.capacity { w = 0 }
        energy = energy * 0.9995 + abs(y) * 0.0005
        return y
    }
}

/// Biquad band-pass (constant 0 dB peak) used for body modes.
struct Biquad {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func bandpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w0 = 2 * Double.pi * f / sr, alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float(alpha / a0); b.b1 = 0; b.b2 = Float(-alpha / a0)
        b.a1 = Float(-2 * cos(w0) / a0); b.a2 = Float((1 - alpha) / a0)
        return b
    }
    static func lowpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w0 = 2 * Double.pi * f / sr, alpha = sin(w0) / (2 * q), a0 = 1 + alpha, c = cos(w0)
        var b = Biquad()
        b.b0 = Float((1 - c) / 2 / a0); b.b1 = Float((1 - c) / a0); b.b2 = b.b0
        b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - alpha) / a0)
        return b
    }
    static func highpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w0 = 2 * Double.pi * f / sr, alpha = sin(w0) / (2 * q), a0 = 1 + alpha, c = cos(w0)
        var b = Biquad()
        b.b0 = Float((1 + c) / 2 / a0); b.b1 = Float(-(1 + c) / a0); b.b2 = b.b0
        b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - alpha) / a0)
        return b
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// A small stereo room (Schroeder/Freeverb style), allocation-free on the audio thread.
final class Room {
    private struct Line { let buf: UnsafeMutablePointer<Float>; let len: Int; var i = 0; var store: Float = 0 }
    private var combs: [Line]       // 0–3 left, 4–7 right
    private var aps: [Line]         // 0–1 left, 2–3 right
    private let feedback: Float = 0.74, dampK: Float = 0.38

    init(sr: Double) {
        let s = sr / 44100
        func line(_ n: Int) -> Line {
            let len = max(8, Int(Double(n) * s))
            let p = UnsafeMutablePointer<Float>.allocate(capacity: len)
            p.initialize(repeating: 0, count: len)
            return Line(buf: p, len: len)
        }
        combs = [1116, 1188, 1277, 1356, 1139, 1211, 1300, 1379].map(line)
        aps = [556, 441, 579, 464].map(line)
    }

    @inline(__always) func process(_ x: Float) -> (Float, Float) {
        var l: Float = 0, r: Float = 0
        combs.withUnsafeMutableBufferPointer { c in
            for k in 0..<8 {
                let y = c[k].buf[c[k].i]
                c[k].store = y * (1 - dampK) + c[k].store * dampK
                c[k].buf[c[k].i] = x + c[k].store * feedback
                c[k].i += 1; if c[k].i == c[k].len { c[k].i = 0 }
                if k < 4 { l += y } else { r += y }
            }
        }
        aps.withUnsafeMutableBufferPointer { a in
            for k in 0..<4 {
                let input = k < 2 ? l : r
                let bv = a[k].buf[a[k].i]
                let out = -input + bv
                a[k].buf[a[k].i] = input + bv * 0.5
                a[k].i += 1; if a[k].i == a[k].len { a[k].i = 0 }
                if k < 2 { l = out } else { r = out }
            }
        }
        return (l * 0.25, r * 0.25)
    }
}

/// Everything the audio thread needs. Events are queued from any thread and picked up
/// at the start of each render block.
final class GuitarCore {
    enum Kind: UInt8 { case pluck, damp, chuck, retune }
    struct Event {
        var kind: Kind; var string: Int; var midi: Int; var velocity: Float; var bright: Float; var delay: Int; var pick: Float
        /// Extra pitch in semitones (bends, slides, vibrato).
        var detune: Float = 0
        /// How much of the string's current vibration survives a new pluck (legato keeps most of it).
        var keep: Float = 0.12
    }

    let sr: Double
    /// 0 = acoustic, 1 = electric clean, 2 = electric overdrive. Read on the audio thread.
    var tone = 0
    private var cab1: Biquad, cab2: Biquad, cabHP: Biquad, amp: Biquad
    private var strings: [StringVoice]
    private var body: [Biquad]
    private let bodyGain: [Float] = [0.9, 0.75, 0.45, 0.28, 0.16, 0.10]
    private var hpL: Biquad, hpR: Biquad, toneL: Biquad, toneR: Biquad
    private let room: Room
    private var pickNoise: [Float] = []      // short pick transient per string
    private var pickPos: [Int] = [Int](repeating: 0, count: 6)
    private var pickAmp: [Float] = [Float](repeating: 0, count: 6)
    private var chuckLeft = 0
    private var chuckLP: Float = 0
    private var excite: UnsafeMutablePointer<Float>

    private var lock = os_unfair_lock()
    private var incoming: [Event] = []
    private var pending: [(at: Int, e: Event)] = []
    private var clock = 0
    private var rng = SystemRandomNumberGenerator()
    private var silentFor = 0

    init(sampleRate: Double) {
        sr = sampleRate
        strings = (0..<6).map { i in
            var v = StringVoice()
            v.pan = Float(i) / 5 * 0.7 - 0.35          // low strings a little left, treble a little right
            v.tune(freq: Theory.frequency(midi: Double(Theory.openStrings[i])), sr: sampleRate)
            return v
        }
        // spruce-top dreadnought: air (Helmholtz), top plate, back, and higher plate modes
        body = [Biquad.bandpass(102, q: 9, sr: sampleRate), Biquad.bandpass(196, q: 11, sr: sampleRate),
                Biquad.bandpass(228, q: 8, sr: sampleRate), Biquad.bandpass(405, q: 7, sr: sampleRate),
                Biquad.bandpass(640, q: 5, sr: sampleRate), Biquad.bandpass(1250, q: 3, sr: sampleRate)]
        hpL = Biquad.highpass(70, q: 0.7, sr: sampleRate)
        hpR = Biquad.highpass(70, q: 0.7, sr: sampleRate)
        toneL = Biquad.lowpass(7200, q: 0.6, sr: sampleRate)
        toneR = Biquad.lowpass(7200, q: 0.6, sr: sampleRate)
        room = Room(sr: sampleRate)
        cab1 = Biquad.lowpass(4200, q: 0.8, sr: sampleRate)
        cab2 = Biquad.lowpass(5200, q: 0.6, sr: sampleRate)
        cabHP = Biquad.highpass(95, q: 0.7, sr: sampleRate)
        amp = Biquad.bandpass(650, q: 0.7, sr: sampleRate)
        excite = .allocate(capacity: StringVoice.capacity)
        excite.initialize(repeating: 0, count: StringVoice.capacity)
        incoming.reserveCapacity(64)
        pending.reserveCapacity(256)
        var p: Float = 0
        pickNoise = (0..<Int(sampleRate * 0.004)).map { i in
            let w = Float.random(in: -1...1)
            let hpv = w - p; p = w
            return hpv * exp(-Float(i) / Float(sampleRate * 0.0009))
        }
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
        if pending.isEmpty && silentFor > Int(sr * 3) {
            for i in 0..<count { L[i] = 0; R[i] = 0 }
            clock += count
            return false
        }
        var loud = false
        for i in 0..<count {
            if !pending.isEmpty { fire(at: clock + i) }
            var l: Float = 0, r: Float = 0, mono: Float = 0
            strings.withUnsafeMutableBufferPointer { st in
            for s in 0..<6 {
                var y = st[s].tick()
                if pickAmp[s] > 0.0001, pickPos[s] < pickNoise.count {
                    y += pickNoise[pickPos[s]] * pickAmp[s]
                    pickPos[s] += 1
                }
                mono += y
                l += y * (0.5 - st[s].pan * 0.5)
                r += y * (0.5 + st[s].pan * 0.5)
            }
            }
            if chuckLeft > 0 {
                chuckLeft -= 1
                let env = Float(chuckLeft) / Float(sr * 0.05)
                chuckLP += 0.18 * (Float.random(in: -1...1, using: &rng) - chuckLP)
                let c = chuckLP * env * env * 0.6
                mono += c; l += c * 0.5; r += c * 0.5
            }
            if tone != 0 {
                // electric: pickups straight into an amp and speaker cabinet
                var x = mono
                if tone == 2 {
                    let pre = x * 7 + amp.process(x) * 6
                    x = tanh(pre) * 0.55 + 0.06 * tanh(pre) * tanh(pre)
                } else {
                    x = x * 1.4
                    x = x / (1 + abs(x) * 0.35)
                }
                x = cabHP.process(cab2.process(cab1.process(x)))
                let (rl, rr) = room.process(x * 0.18)
                // soft limiter: unchanged at normal levels, never past 0.95
                L[i] = 0.95 * tanh((x * 0.8 + rl) * 0.6 / 0.95)
                R[i] = 0.95 * tanh((x * 0.8 + rr) * 0.6 / 0.95)
                if abs(x) > 0.0005 { loud = true }
                continue
            }
            // the guitar body colours the sound
            var b: Float = 0
            body.withUnsafeMutableBufferPointer { bq in
                for k in 0..<bq.count { b += bq[k].process(mono) * bodyGain[k] }
            }
            let dryL = hpL.process(l + b * 0.5)
            let dryR = hpR.process(r + b * 0.5)
            let (rl, rr) = room.process(mono * 0.12)
            var outL = toneL.process(dryL) * 0.9 + rl
            var outR = toneR.process(dryR) * 0.9 + rr
            // gentle saturation keeps loud strums from clipping
            outL = outL / (1 + abs(outL) * 0.6)
            outR = outR / (1 + abs(outR) * 0.6)
            L[i] = outL * 0.55
            R[i] = outR * 0.55
            if abs(outL) > 0.0005 { loud = true }
        }
        clock += count
        silentFor = loud ? 0 : silentFor + count
        return true
    }

    private func fire(at t: Int) {
        var k = 0
        while k < pending.count {
            if pending[k].at <= t {
                apply(pending[k].e)
                pending.swapAt(k, pending.count - 1)
                pending.removeLast()
            } else { k += 1 }
        }
    }

    private func apply(_ e: Event) {
        switch e.kind {
        case .damp:
            // `bright` carries how quickly the string is stopped (closer to 1 = gentler)
            strings[e.string].damp = e.bright > 0 ? e.bright : 0.9965
        case .chuck:
            for s in 0..<6 { strings[s].damp = 0.97 }
            chuckLeft = Int(sr * 0.05)
        case .pluck:
            pluck(e)
        case .retune:
            // change the pitch of a ringing string without picking it (bends, slides, vibrato)
            strings[e.string].tune(freq: Theory.frequency(midi: Double(e.midi) + Double(e.detune)), sr: sr, sustain: tone == 0 ? 1 : 1.5)
            strings[e.string].damp = 1
        }
    }

    private func pluck(_ e: Event) {
        var v = strings[e.string]
        v.damp = 1
        v.tune(freq: Theory.frequency(midi: Double(e.midi) + Double(e.detune)), sr: sr, sustain: tone == 0 ? 1 : 1.5)
        let n = v.n
        // excitation: the pick pulls the string into a triangle peaking at the pick point, plus a
        // little noise for the pick's texture; harder/brighter picks keep more high end
        let apex = max(1, min(n - 2, Int(Float(n) * e.pick)))
        var lp: Float = 0
        let a = min(0.98, 0.6 + 0.45 * e.bright * e.velocity)
        for k in 0..<n {
            let tri: Float = k <= apex ? Float(k) / Float(apex) : Float(n - k) / Float(n - apex)
            let raw = tri + 0.12 * Float.random(in: -1...1, using: &rng)
            lp += a * (raw - lp)
            excite[k] = lp
        }
        // remove DC so the string doesn't thump
        var mean: Float = 0
        for k in 0..<n { mean += excite[k] }
        mean /= Float(n)
        var peak: Float = 0.0001
        for k in 0..<n { excite[k] -= mean; peak = max(peak, abs(excite[k])) }
        let amp = e.velocity * 1.15 / peak
        // load it into the part of the delay line that's read next; the old vibration fades out
        for k in 0..<n {
            var idx = v.w - n + k
            if idx < 0 { idx += StringVoice.capacity }
            v.buf[idx] = v.buf[idx] * e.keep + excite[k] * amp
        }
        if e.keep < 0.5 { v.prev = 0; v.apX = 0; v.apY = 0 }
        strings[e.string] = v
        // pick click
        pickPos[e.string] = 0
        pickAmp[e.string] = 0.05 * e.velocity * e.bright
    }
}

// MARK: - Public synth

final class GuitarSynth {
    static let shared = GuitarSynth()
    /// A second guitar for a song's melody, so the tune doesn't cut off the strings of the chords.
    static let melody = GuitarSynth()
    private let engine = AVAudioEngine()
    private let clickPlayer = AVAudioPlayerNode()
    private let sr: Double = 44100
    private let core: GuitarCore
    private var source: AVAudioSourceNode!
    private let clickFormat: AVAudioFormat
    private var clickHi: AVAudioPCMBuffer?
    private var clickLo: AVAudioPCMBuffer?
    var volume: Float = 0.9 { didSet { source.volume = volume } }

    enum Tone: Int, CaseIterable, Identifiable {
        case acoustic, clean, drive
        var id: Int { rawValue }
        var name: String { ["Acoustic", "Electric Clean", "Electric Drive"][rawValue] }
        var icon: String { ["guitars", "bolt", "flame.fill"][rawValue] }
    }
    var tone: Tone = .acoustic { didSet { core.tone = tone.rawValue } }

    private init() {
        core = GuitarCore(sampleRate: sr)
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let c = core
        source = AVAudioSourceNode(format: stereo) { isSilence, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let sounding = c.render(l, r, Int(frames))
            if !sounding { isSilence.pointee = true }
            return noErr
        }
        engine.attach(source)
        engine.attach(clickPlayer)
        engine.connect(source, to: engine.mainMixerNode, format: stereo)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: clickFormat)
        source.volume = volume
        clickHi = makeClick(freq: 1760, gain: 0.55)
        clickLo = makeClick(freq: 1175, gain: 0.35)
    }

    private func ensureRunning() {
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    /// Strum a chord shape like a person would: strings a few milliseconds apart, a little
    /// variation in timing and force, lighter up-strums that only catch the top strings.
    /// - Parameters:
    ///   - ring: kept for compatibility; strings now ring naturally until struck again.
    ///   - silent: when true the microphone keeps listening (used by demos that aren't scored).
    ///   - velocity: 0…1 how hard the strum is.
    /// - strings: only strum these strings (e.g. the top four for a light "chick").
    /// - chop: stop the strings this many seconds later (reggae chops, staccato).
    func strum(_ shape: ChordShape, stroke: StrumStroke = .down, ring: Double = 2.2, silent: Bool = false, velocity: Float = 0.9,
               strings: [Int]? = nil, chop: Double? = nil) {
        if !silent && stroke != .rest { AudioEngine.shared.suppressSelfSound(for: min(ring, 1.6)) }
        ensureRunning()
        var ev = Self.events(for: shape, stroke: stroke, velocity: velocity, strings: strings)
        if let chop {
            let at = Int(chop * 44100)
            ev += ev.filter { $0.kind == .pluck }.map { .init(kind: .damp, string: $0.string, midi: 0, velocity: 0, bright: 0.995, delay: $0.delay + at, pick: 0) }
        }
        core.enqueue(ev)
    }

    /// Pick one string at a fret. `palmMute` rests the hand on the strings for a short, chunky note.
    func pickString(_ string: Int, fret: Int, velocity: Float = 0.75, palmMute: Bool = false, bright: Float = 0.6) {
        ensureRunning()
        let s = max(0, min(5, string))
        var ev: [GuitarCore.Event] = [.init(kind: .pluck, string: s, midi: Theory.openStrings[s] + max(0, fret),
                                            velocity: velocity * Float.random(in: 0.92...1.05), bright: palmMute ? bright * 0.6 : bright,
                                            delay: Int(Double.random(in: 0...0.004) * 44100), pick: Float.random(in: 0.12...0.2))]
        if palmMute { ev.append(.init(kind: .damp, string: s, midi: 0, velocity: 0, bright: 0.9994, delay: ev[0].delay + 1, pick: 0)) }
        core.enqueue(ev)
    }

    /// Lead-guitar techniques on one string. `tech`: "" pick, "h" hammer-on, "p" pull-off,
    /// "/" slide in, "b" bend up a whole step, "~" vibrato, "m" palm mute. `length` is in seconds.
    func lead(_ string: Int, fret: Int, tech: String, length: Double, velocity: Float = 0.8) {
        ensureRunning()
        core.enqueue(Self.leadEvents(string, fret: fret, tech: tech, length: length, velocity: velocity))
    }

    static func leadEvents(_ string: Int, fret: Int, tech: String, length: Double, velocity: Float = 0.8, sampleRate sr: Double = 44100) -> [GuitarCore.Event] {
        let s = max(0, min(5, string))
        let midi = Theory.openStrings[s] + max(0, fret)
        let start = Int(Double.random(in: 0...0.003) * sr)
        var ev: [GuitarCore.Event] = []
        let vel = velocity * Float.random(in: 0.92...1.05)
        switch tech {
        case "h", "p":
            // the fretting hand changes the note: the string keeps ringing, with a soft attack
            ev.append(.init(kind: .pluck, string: s, midi: midi, velocity: vel * 0.35, bright: 0.45, delay: start, pick: 0.2, keep: 0.85))
        case "/":
            ev.append(.init(kind: .pluck, string: s, midi: midi - 2, velocity: vel, bright: 0.6, delay: start, pick: 0.15))
            for k in 1...6 {
                ev.append(.init(kind: .retune, string: s, midi: midi - 2, velocity: 0, bright: 0, delay: start + Int(Double(k) * 0.012 * sr), pick: 0, detune: Float(k) / 3))
            }
        default:
            ev.append(.init(kind: .pluck, string: s, midi: midi, velocity: vel, bright: tech == "m" ? 0.35 : 0.62, delay: start, pick: Float.random(in: 0.12...0.2)))
        }
        if tech == "b" {
            // push the string up a whole step, a moment after picking
            let steps = 10
            for k in 1...steps {
                let t = 0.05 + Double(k) * min(0.16, length * 0.4) / Double(steps)
                ev.append(.init(kind: .retune, string: s, midi: midi, velocity: 0, bright: 0, delay: start + Int(t * sr), pick: 0,
                                detune: 2 * Float(sin(Double(k) / Double(steps) * .pi / 2))))
            }
        }
        if tech == "~" {
            // vibrato: a gentle pitch wobble that grows a little
            var t = 0.12
            while t < length - 0.03 {
                let depth = Float(min(1, (t - 0.12) / 0.3)) * 0.28
                ev.append(.init(kind: .retune, string: s, midi: midi, velocity: 0, bright: 0, delay: start + Int(t * sr), pick: 0,
                                detune: depth * Float(sin(2 * .pi * 5.5 * t))))
                t += 0.025
            }
        }
        if tech == "m" {
            ev.append(.init(kind: .damp, string: s, midi: 0, velocity: 0, bright: 0.9994, delay: start + 1, pick: 0))
        }
        return ev
    }

    /// Stop one string gently (between notes of a riff).
    func damp(_ string: Int, after seconds: Double = 0) {
        core.enqueue([.init(kind: .damp, string: max(0, min(5, string)), midi: 0, velocity: 0, bright: 0.998, delay: Int(seconds * 44100), pick: 0)])
    }

    /// Stop every string (e.g. when playback stops).
    func silence() {
        core.enqueue((0..<6).map { .init(kind: .damp, string: $0, midi: 0, velocity: 0, bright: 0.997, delay: 0, pick: 0) })
    }

    /// Single note on its most natural string.
    func pluck(midi: Int, seconds: Double = 2.6, velocity: Float = 0.85) {
        AudioEngine.shared.suppressSelfSound(for: min(seconds, 2.0))
        ensureRunning()
        let s = Theory.position(midi: midi)?.string ?? max(0, min(5, (midi - 40) / 5))
        core.enqueue([.init(kind: .pluck, string: s, midi: midi, velocity: velocity, bright: 0.55, delay: 0, pick: 0.14)])
    }

    func click(accent: Bool) {
        ensureRunning()
        AudioEngine.shared.noteClick()
        guard let b = accent ? clickHi : clickLo else { return }
        clickPlayer.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        if !clickPlayer.isPlaying { clickPlayer.play() }
    }

    static func events(for shape: ChordShape, stroke: StrumStroke, velocity: Float, strings only: [Int]? = nil, sampleRate sr: Double = 44100) -> [GuitarCore.Event] {
        let frets = shape.frets
        let played = (0..<6).filter { frets.indices.contains($0) && frets[$0] >= 0 && (only?.contains($0) ?? true) }
        let fretted = (0..<6).filter { frets.indices.contains($0) && frets[$0] >= 0 }
        let jitter = Int(Double.random(in: 0...0.006) * sr)
        let vel = max(0.05, min(1, velocity * Float.random(in: 0.88...1.06)))
        switch stroke {
        case .rest:
            return []
        case .mute:
            return [.init(kind: .chuck, string: 0, midi: 0, velocity: vel, bright: 0.5, delay: jitter, pick: 0.15)]
        case .down, .up:
            let down = stroke == .down
            // the fretting hand mutes strings that aren't part of the chord
            var out: [GuitarCore.Event] = (0..<6).filter { !fretted.contains($0) }
                .map { .init(kind: .damp, string: $0, midi: 0, velocity: 0, bright: 0, delay: jitter, pick: 0) }
            let order = down ? played : Array(played.suffix(4).reversed())
            let spreadTotal = Double.random(in: down ? 0.016...0.03 : 0.012...0.022)
            let step = spreadTotal / Double(max(1, order.count - 1))
            for (k, s) in order.enumerated() {
                let midi = Theory.openStrings[s] + frets[s]
                // the pick slows slightly as it goes through the strings
                let t = Double(k) * step * (1 + 0.15 * Double(k) / Double(max(1, order.count)))
                // down-strums hit the bass harder; up-strums are lighter and brighter
                let shape: Float = down ? (1 - 0.06 * Float(k)) : (0.8 - 0.05 * Float(k))
                let v = max(0.05, vel * shape * Float.random(in: 0.9...1.05))
                out.append(.init(kind: .pluck, string: s, midi: midi, velocity: v,
                                 bright: down ? Float.random(in: 0.55...0.7) : Float.random(in: 0.7...0.85),
                                 delay: jitter + Int(t * sr), pick: Float.random(in: 0.11...0.17)))
            }
            return out
        }
    }

    private func makeClick(freq: Double, gain: Float) -> AVAudioPCMBuffer? {
        let total = Int(sr * 0.035)
        let s: [Float] = (0..<total).map { i in
            let t = Double(i) / sr
            return Float(sin(2 * .pi * freq * t) * exp(-t / 0.008)) * gain
        }
        guard let b = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: AVAudioFrameCount(s.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { p in b.floatChannelData![0].update(from: p.baseAddress!, count: s.count) }
        return b
    }
}
