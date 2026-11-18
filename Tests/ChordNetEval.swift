// ChordNet checks against labelled audio (a held-out split of the training sources, see scripts/chordnet).
//   build/selftest --chordnet-eval <dir> [max songs]   every <name>.wav with a <name>.lab (and <name>.key):
//                                                       the full Transcriber, templates vs ChordNet, beat by beat
//   build/selftest --chordnet-features <wav> <out.f32>  dump the Swift features (parity with features.py)
#if SELFTEST
import Foundation

extension SelfTest {
    static func chordNetTools(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--chordnet-features"), args.count > i + 2 {
            guard let (x, sr) = try? Transcriber.readMono(URL(fileURLWithPath: args[i + 1])) else { print("can't read"); return true }
            let tuning = args.count > i + 3 ? Double(args[i + 3]) ?? 0 : 0
            let (f, T) = ChordNet.features(x, sampleRate: sr, tuning: tuning)
            f.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: URL(fileURLWithPath: args[i + 2])) }
            print("features \(T) × \(ChordNet.bins) → \(args[i + 2])")
            return true
        }
        if let i = args.firstIndex(of: "--chordnet-eval"), args.count > i + 1 {
            let limit = args.count > i + 2 ? Int(args[i + 2]) ?? Int.max : Int.max
            chordNetEval(dir: args[i + 1], limit: limit)
            return true
        }
        return false
    }

    struct EvalTally {
        var right = 0, near = 0, root = 0, total = 0, keyRight = 0, keyRel = 0, keySongs = 0, songs = 0
        var confusions: [String: Int] = [:]
        func line(_ name: String) -> String {
            func p(_ a: Int, _ b: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(1, b))) }
            let top = confusions.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            return "   \(name): right chord \(p(right, total)), within a beat \(p(near, total)), right root \(p(root, total)) (\(total) beats, \(songs) songs); key \(keyRight)/\(keySongs) exact, \(keyRel)/\(keySongs) same or relative; wrong: \(top)"
        }
    }

    static func chordNetEval(dir: String, limit: Int) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            .map { String($0.dropLast(4)) }.filter { fm.fileExists(atPath: "\(dir)/\($0).lab") }.prefix(limit)
        let modes = ChordNet.available ? ["templates", "chordnet"] : ["templates"]
        if !ChordNet.available { print("ChordNet model not found (set CHORDNET_MODEL): templates only") }
        var tallies: [String: EvalTally] = ["templates": EvalTally(), "chordnet": EvalTally()]
        var perGroup: [String: [String: EvalTally]] = [:]
        let t0 = Date()
        for name in names {
            guard let (x, side, sr) = try? Transcriber.readStereo(URL(fileURLWithPath: "\(dir)/\(name).wav")) else { continue }
            let lab: [(Double, Double, Int)] = ((try? String(contentsOfFile: "\(dir)/\(name).lab", encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { l in
                    let f = l.split(separator: " ")
                    guard f.count >= 3, let a = Double(f[0]), let b = Double(f[1]), let c = Int(f[2]) else { return nil }
                    return (a, b, c)
                }
            let keyLine = (try? String(contentsOfFile: "\(dir)/\(name).key", encoding: .utf8))?.split(separator: " ")
            let group = name.hasPrefix("syn_") ? "synthetic" : "guitarset"
            for mode in modes {
                ChordNet.forceEnabled = mode == "chordnet"
                guard let tr = try? Transcriber.analyze(samples: x, side: side, sampleRate: sr) else { continue }
                var t = tallies[mode]!, g = perGroup[group]?[mode] ?? EvalTally()
                // the chord on each beat: the label covering most of it (beats with no majority, no chord or a
                // chord outside major/minor are skipped)
                var want: [Int?] = []
                for i in tr.beatPath.indices {
                    let a = tr.beatTimes[i], b = i + 1 < tr.beatTimes.count ? tr.beatTimes[i + 1] : a + 60 / tr.bpm
                    var cover: [Int: Double] = [:]
                    for (s, e, c) in lab { let o = min(b, e) - max(a, s); if o > 0 { cover[c, default: 0] += o } }
                    if let best = cover.max(by: { $0.value < $1.value }), best.value > 0.5 * (b - a), best.key >= 0, best.key < 24 { want.append(best.key) } else { want.append(nil) }
                }
                for i in tr.beatPath.indices {
                    guard let w = want[i] else { continue }
                    let got = tr.beatPath[i]
                    for k in [0, 1] {
                        var u = k == 0 ? t : g
                        u.total += 1
                        if got == w { u.right += 1 }
                        if got % 12 == w % 12 { u.root += 1 }
                        if got == w || (i > 0 && want[i - 1] == got) || (i + 1 < want.count && want[i + 1] == got) { u.near += 1 }
                        else { u.confusions["\(Transcriber.chordName(w, flatKey: false))→\(Transcriber.chordName(got, flatKey: false))", default: 0] += 1 }
                        if k == 0 { t = u } else { g = u }
                    }
                }
                t.songs += 1; g.songs += 1
                if let kl = keyLine, kl.count >= 2, let root = Int(kl[0]) {
                    let minor = kl[1].hasPrefix("minor")
                    let exact = tr.keyRoot == root && tr.minorKey == minor
                    let rel = exact || ((minor ? (root + 3) % 12 : root) == (tr.minorKey ? (tr.keyRoot + 3) % 12 : tr.keyRoot))
                    t.keySongs += 1; g.keySongs += 1
                    if exact { t.keyRight += 1; g.keyRight += 1 }
                    if rel { t.keyRel += 1; g.keyRel += 1 }
                }
                tallies[mode] = t
                perGroup[group, default: [:]][mode] = g
            }
        }
        ChordNet.forceEnabled = nil
        print(String(format: "\nChordNet held-out check: %d recordings in %.0f s (scale %.2f, key weight %.2f)", names.count, Date().timeIntervalSince(t0), ChordNet.emissionScale, ChordNet.keyWeight))
        for mode in modes { print(tallies[mode]!.line("all " + mode)) }
        for (group, d) in perGroup.sorted(by: { $0.key < $1.key }) {
            for mode in ["templates", "chordnet"] { if let t = d[mode] { print(t.line("\(group) \(mode)")) } }
        }
    }
}
#endif
