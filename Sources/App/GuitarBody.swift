import Foundation

// MARK: - Guitar body, microphones and room
//
// The strings produce the force on the bridge. Everything after that (the wooden body, two
// microphones, the room) is linear, so it is one stereo impulse response per tone, built here at
// launch from physical descriptions. No audio files ship with the app.
//
//  • Body: a modal model of a dreadnought. The low modes follow published measurements of
//    steel-string flat tops (air "A0" resonance ≈ 100 Hz, top T(1,1) ≈ 190–200 Hz, back ≈ 235 Hz,
//    T(1,2)/T(3,1) plate modes up to 1 kHz); above 1 kHz the modes are too dense to list, so they're
//    drawn statistically (spacing, Q and level ranges from the same measurements).
//  • Microphones: a stereo pair as in a studio — one aimed near the 12th fret (brighter, less boom)
//    and one at the lower bout (fuller). Same body, different weights per mode, so the image is
//    wide but mono-compatible.
//  • Room: early reflections and a smooth, frequency-dependent decaying tail (no metallic combs).
//  • Calibration: a 1/3-octave curve fitted so the whole instrument matches the long-term
//    spectrum of professional studio recordings (GuitarSet, Neumann U-87; see scripts/soundlab).

enum GuitarBody {
    /// 1/3-octave band centres, 20 Hz … 20 kHz.
    static let bandCentres: [Double] = (-17...13).map { 1000 * pow(2, Double($0) / 3) }

    /// Correction (dB per 1/3-octave band) that makes the modeled acoustic match the long-term spectrum
    /// of the GuitarSet U-87 recordings, re-synthesized note for note. Produced by
    /// `scripts/soundlab/calibrate.py`; see docs/DEVELOPING.md → Guitar sound.
    static let acousticCalibration: [Double] = [6.9, 6.9, 6.9, 6.9, 6.9, 6.9, 6.5, 6.9, 8.6, 8.4, 6.2, 0.4, 0.9, 2.0, -1.1, -2.0,
                                                 0.5, 1.3, 0.9, 2.5, 2.2, -2.6, -2.8, 3.2, 6.0, 5.2, 4.7, 6.8, 10.8, 6.0, 6.0]

    /// Mix polish on top of the calibrated sound, as an engineer would EQ an acoustic for a record:
    /// clear the sub-rumble below the low E, take a little "box" out of the low mids, add some air.
    static func acousticPolish(_ f: Double) -> Double {
        highpassDB(f, 62, order: 2) - 1.5 * bell(f, 320, octaves: 1.0) + 1.8 * shelf(f, 9500, width: 1.2)
    }

    // MARK: Building blocks for magnitude curves (dB)

    /// Butterworth high-pass magnitude in dB.
    static func highpassDB(_ f: Double, _ fc: Double, order: Double) -> Double { -10 * log10(1 + pow(fc / f, 2 * order)) }
    static func lowpassDB(_ f: Double, _ fc: Double, order: Double) -> Double { -10 * log10(1 + pow(f / fc, 2 * order)) }
    /// A bell of unit height, `octaves` wide (between the half-height points) on a log-frequency axis.
    static func bell(_ f: Double, _ fc: Double, octaves: Double) -> Double {
        let x = log2(f / fc) / (octaves / 2)
        return exp(-0.693 * x * x)
    }
    /// 0 below `fc`, 1 well above, a smooth step `width` octaves wide.
    static func shelf(_ f: Double, _ fc: Double, width: Double) -> Double { 1 / (1 + exp(-4 * log2(f / fc) / width)) }

    // MARK: Impulse responses (cached per sample rate)

    private static var cache: [String: (l: [Float], r: [Float])] = [:]
    private static let cacheLock = NSLock()
    /// 1 = the room as designed, 0 = dry (body and mics only; the sound lab measures the instrument this way).
    static var roomAmount: Double = 1
    /// 1 = with the mix polish, 0 = the calibrated instrument alone (what the calibration is fitted on).
    static var polishAmount: Double = 1
    /// The sound lab can try a calibration curve without rebuilding.
    static var calibrationOverride: [Double]?

    static func impulseResponse(tone: Int, sr: Double) -> (l: [Float], r: [Float]) {
        let key = "\(tone)@\(Int(sr))@\(roomAmount)@\(polishAmount)@\(GuitarTuning.bodyHighModes)@\(calibrationOverride ?? [])"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let ir = cache[key] { return ir }
        let ir: (l: [Float], r: [Float])
        switch tone {
        case 1: ir = electric(sr: sr, drive: false)
        case 2: ir = electric(sr: sr, drive: true)
        default: ir = acoustic(sr: sr)
        }
        cache[key] = ir
        return ir
    }

    // MARK: Acoustic

    struct Mode { var f: Double; var q: Double; var db: Double; var sign: Double; var micL: Double; var micR: Double }

    /// The body's vibration modes with their level at each microphone.
    static func bodyModes(seed: UInt64 = 0xB0D1) -> [Mode] {
        var rng = SeededRandom(seed: seed)
        // (frequency Hz, Q, level dB) — low modes of a spruce-top dreadnought
        let low: [(Double, Double, Double)] = [
            (98, 15, 0),        // A0: the air in the body breathing through the sound hole
            (114, 10, -9),
            (188, 20, -1.5),    // T(1,1)₁: the top moving as a whole, coupled with the air
            (206, 24, -6),
            (234, 22, -4),      // back plate / T(1,1)₂
            (281, 26, -9),
            (322, 28, -10),     // T(2,1): cross-dipole
            (381, 30, -6),      // T(1,1)₃
            (415, 30, -9),
            (466, 32, -9),      // T(1,2)
            (528, 34, -11),
            (592, 34, -10),     // T(3,1)
            (664, 36, -12),
            (742, 38, -12),
            (826, 40, -13),
            (912, 40, -13),
            (1004, 42, -14),
        ]
        var modes = low.map { m -> Mode in
            // below ~600 Hz both mics see nearly the same modes (keeps the low end solid in mono)
            let spread = m.0 < 600 ? 0.6 : 2.0
            return Mode(f: m.0, q: m.1, db: m.2, sign: rng.uniform() < 0.5 ? 1 : -1,
                        micL: -1.5 + spread * rng.gaussian() * 0.5 - (m.0 < 130 ? 2.5 : 0),
                        micR: spread * rng.gaussian() * 0.5)
        }
        // dense modes above 1 kHz: spacing grows with frequency, levels follow a smooth envelope
        var f = 1060.0
        while f < 17000 {
            let env = Spectral.interpolateDB(f, freqs: [1000, 2000, 3500, 6000, 10000, 16000], db: [-14, -13, -13, -14, -17, -22])
            modes.append(Mode(f: f, q: rng.uniform(26...58), db: env + 3.2 * rng.gaussian() + 20 * log10(max(1e-3, 1 + GuitarTuning.bodyHighModes)), sign: rng.uniform() < 0.5 ? 1 : -1,
                              micL: 1.2 + 2.5 * rng.gaussian(), micR: -1.2 + 2.5 * rng.gaussian()))
            f += (20 + 0.011 * f) * (0.35 + 1.3 * rng.uniform())
        }
        return modes
    }

    /// Body impulse response at one microphone: a sum of decaying resonances, all excited by the same tap.
    static func bodyResponse(_ modes: [Mode], left: Bool, sr: Double, seconds: Double = 0.5) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Double](repeating: 0, count: n)
        for m in modes {
            let sigma = Double.pi * m.f / m.q          // decay rate (1/s); spectral peak ≈ amplitude / sigma
            let amp = pow(10, (m.db + (left ? m.micL : m.micR)) / 20) * sigma * m.sign
            let len = min(n, Int(9.2 / sigma * sr))     // until −80 dB
            let w = 2 * Double.pi * m.f / sr, r = exp(-sigma / sr)
            let cw = cos(w) * r, sw = sin(w) * r
            var c = 1.0, s = 0.0
            for i in 0..<len {
                out[i] += amp * c
                (c, s) = (c * cw - s * sw, c * sw + s * cw)
            }
        }
        return out.map { Float($0) }
    }

    /// A stereo room: direct sound, early reflections and a smooth decaying tail.
    /// `rt` gives the reverberation time (seconds to −60 dB) at 125 Hz … 16 kHz in octaves.
    static func room(sr: Double, seed: UInt64, seconds: Double, predelay: Double, rt: [Double],
                     earlyDB: Double, tailDB: Double) -> (l: [Float], r: [Float]) {
        if roomAmount <= 0 { return ([1], [1]) }
        let earlyDB = earlyDB + 20 * log10(roomAmount), tailDB = tailDB + 20 * log10(roomAmount)
        let n = Int(seconds * sr)
        var rng = SeededRandom(seed: seed)
        func channel(_ side: Double) -> [Float] {
            var early = [Double](repeating: 0, count: n)
            // early reflections: floor, near walls, ceiling; each a little duller and quieter
            for k in 0..<14 {
                let t = predelay * 0.55 + 0.004 + 0.034 * pow(rng.uniform(), 1.3) + 0.0007 * Double(k) * side
                let i = Int(t * sr)
                guard i < n else { continue }
                early[i] += pow(10, (earlyDB - 9 * (t / 0.04)) / 20) * (rng.uniform() < 0.5 ? 1 : -1) * rng.uniform(0.6...1.0)
            }
            var lp = 0.0
            for i in 0..<n { lp += 0.45 * (early[i] - lp); early[i] = lp }
            // late tail: noise in octave bands, each band decaying at its own rate
            let centres: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            var tail = [Double](repeating: 0, count: n)
            let start = Int(predelay * sr)
            let noise = (0..<n).map { _ in Float(rng.gaussian()) }
            for (b, fc) in centres.enumerated() {
                var bp1 = Biquad.bandpass(fc, q: 1.1, sr: sr), bp2 = Biquad.bandpass(fc, q: 1.1, sr: sr)
                let step = exp(-6.91 / max(0.05, rt[min(b, rt.count - 1)]) / sr)
                var env = 1.0
                for i in start..<n {
                    let t = Double(i - start) / sr
                    let y = Double(bp2.process(bp1.process(noise[i])))
                    let fadeIn = min(1, t / 0.03)
                    tail[i] += y * env * fadeIn * fadeIn
                    env *= step
                }
            }
            // scale early and tail relative to the direct sound (energy)
            let eE = early.reduce(0) { $0 + $1 * $1 }, tE = tail.reduce(0) { $0 + $1 * $1 }
            let tg = tE > 0 ? sqrt(pow(10, tailDB / 10) / tE) : 0
            var out = [Float](repeating: 0, count: n)
            out[0] = 1
            let eg = eE > 0 ? sqrt(pow(10, (earlyDB + 3) / 10) / eE) : 0
            for i in 0..<n { out[i] += Float(early[i] * eg + tail[i] * tg) }
            // fade the last 10% so the response ends cleanly
            let f0 = Int(Double(n) * 0.9)
            for i in f0..<n { out[i] *= Float(0.5 + 0.5 * cos(Double.pi * Double(i - f0) / Double(n - f0))) }
            return out
        }
        return (channel(-1), channel(1))
    }

    static func acoustic(sr: Double) -> (l: [Float], r: [Float]) {
        let modes = bodyModes()
        let bl = bodyResponse(modes, left: true, sr: sr), br = bodyResponse(modes, left: false, sr: sr)
        // a warm, open studio room: 12 ms pre-delay, ~1.3 s in the mids, darker as it decays
        let rm = room(sr: sr, seed: 0x5EED, seconds: 1.7, predelay: 0.012,
                      rt: [1.35, 1.35, 1.3, 1.2, 1.05, 0.85, 0.6, 0.4], earlyDB: -13, tailDB: -15)
        let length = Int(1.8 * sr)
        var l = Spectral.convolve(bl, rm.l, length: length), r = Spectral.convolve(br, rm.r, length: length)
        let cal = calibrationOverride ?? acousticCalibration
        let polish = polishAmount
        let eq: (Double) -> Double = { f in Spectral.interpolateDB(f, freqs: bandCentres, db: cal) + polish * acousticPolish(f) }
        l = Spectral.minimumPhaseFilter(l, sr: sr, gainDB: eq)
        r = Spectral.minimumPhaseFilter(r, sr: sr, gainDB: eq)
        return normalized(l, r)
    }

    // MARK: Electric: speaker cabinet + room

    static func electric(sr: Double, drive: Bool) -> (l: [Float], r: [Float]) {
        var rng = SeededRandom(seed: drive ? 0xCAB2 : 0xCAB1)
        // cone break-up: a few irregular peaks and dips above 1.2 kHz
        let ripple: [(Double, Double, Double)] = (0..<9).map { _ in
            (exp(rng.uniform(log(1200)...log(7000))), rng.uniform(0.15...0.4), rng.uniform(-3...3))
        }
        let cab: (Double) -> Double = { f in
            var g: Double
            if drive {
                // closed-back 4×12 with a dynamic mic on the cone edge
                g = highpassDB(f, 75, order: 2) + 4 * bell(f, 115, octaves: 0.8) + 2.5 * bell(f, 1900, octaves: 0.9)
                    + 4.5 * bell(f, 3100, octaves: 0.7) + lowpassDB(f, 5200, order: 4)
            } else {
                // open-back 2×12 combo: looser low end, more top
                g = highpassDB(f, 70, order: 2) + 2 * bell(f, 105, octaves: 1.0) + 2 * bell(f, 2400, octaves: 1.0)
                    + 3 * bell(f, 4000, octaves: 0.8) + lowpassDB(f, 6800, order: 4)
            }
            for (fc, w, db) in ripple { g += db * bell(f, fc, octaves: w) }
            return g
        }
        var impulse = [Float](repeating: 0, count: Int(0.05 * sr)); impulse[0] = 1
        let cabIR = Spectral.minimumPhaseFilter(impulse, sr: sr, gainDB: cab)
        let rm = room(sr: sr, seed: drive ? 0x2002 : 0x2001, seconds: 1.3, predelay: 0.010,
                      rt: [1.0, 1.0, 0.95, 0.9, 0.8, 0.65, 0.45, 0.3], earlyDB: -12, tailDB: drive ? -19 : -16)
        let length = Int(1.3 * sr)
        return normalized(Spectral.convolve(cabIR, rm.l, length: length), Spectral.convolve(cabIR, rm.r, length: length))
    }

    /// Scales a stereo response to unit energy per channel (on average), so tones are comparable.
    static func normalized(_ l: [Float], _ r: [Float]) -> (l: [Float], r: [Float]) {
        let e = (l.reduce(0) { $0 + Double($1 * $1) } + r.reduce(0) { $0 + Double($1 * $1) }) / 2
        let g = Float(1 / sqrt(max(1e-12, e)))
        return (l.map { $0 * g }, r.map { $0 * g })
    }
}
