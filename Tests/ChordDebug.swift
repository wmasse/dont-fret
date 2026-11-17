// build/selftest --chord-debug   per bench preview: chords on the beat path, the bars, the sections
#if SELFTEST
import Foundation

extension SelfTest {
    static func chordDebug() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench", isDirectory: true)
        var list = benchSongs.filter { !$0.core.isEmpty }.map { b in
            (b, dir.appendingPathComponent(ChordCharts.normTitle(b.title).replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "") + ".m4a"))
        }
        if let f = ProcessInfo.processInfo.environment["CHORD_FILE"] {
            list = [(BenchSong(title: f, artist: "", core: [], key: ""), URL(fileURLWithPath: f))]
        }
        for (b, url) in list {
            guard let tr = try? Transcriber.analyze(url: url) else { continue }
            let flat = Theory.flatKeys.contains(tr.minorKey ? (tr.keyRoot + 3) % 12 : tr.keyRoot)
            var counts: [String: Int] = [:]
            for c in tr.beatPath { counts[Transcriber.chordName(c, flatKey: flat), default: 0] += 1 }
            print("\(b.title) [real \(b.core.joined(separator: " ")) | key \(b.key)] got key \(tr.keyName), \(Int(tr.bpm)) BPM, meter \(tr.beatsPerBar)")
            print("   beats: " + counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
            print("   path:  " + tr.beatPath.map { Transcriber.chordName($0, flatKey: flat) }.joined(separator: " "))
            print("   bars:  " + tr.bars.map(\.tokens).joined(separator: " | "))
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            for c in Set(tr.beatPath).sorted() {
                let idx = tr.beatPath.indices.filter { tr.beatPath[$0] == c && $0 < tr.beatTreble.count }
                var t = [Float](repeating: 0, count: 12), b = t
                for i in idx { for k in 0..<12 { t[k] += tr.beatTreble[i][k] / Float(idx.count); b[k] += tr.beatBass[i][k] / Float(idx.count) } }
                func top(_ x: [Float]) -> String { x.indices.sorted { x[$0] > x[$1] }.prefix(5).map { names[$0] + String(format: "%.2f", x[$0]) }.joined(separator: " ") }
                print("   \(Transcriber.chordName(c, flatKey: flat)): treble \(top(t)) | bass \(top(b))")
            }
            let app = Transcriber.song(from: tr, title: "", artist: "", genre: "Pop", capo: 0)
            let heard = MelodyExtractor.beatPosition(tr.duration, beatTimes: tr.beatTimes) - tr.songZeroBeat
            print("   app song: \(Int(app.totalBeats)) beats in \(app.sections.count) parts; heard \(String(format: "%.1f", heard)) beats; lyrics/melody repeat every \(Transcriber.repeatPeriod(app, heardBeats: heard)) beats (old: \(max(4, (heard / 4).rounded(.down) * 4)))")
            print("   song:  " + tr.sections.map { "\($0.name)×\($0.repeats): \($0.chords)" }.joined(separator: " / "))
        }
    }
}
#endif
