// The Beginner, Middle and Advanced versions of a few real previews, as the app would build them.
// Needs preview audio files in $BENCH_DIR (default ./build/bench), named like wonderwall.m4a.
// Run: build/selftest --versions
#if SELFTEST
import Foundation
/// The three versions of a few heard songs, as they'd be built.
func versionsBench() {
    let dir = ProcessInfo.processInfo.environment["BENCH_DIR"] ?? "build/bench"
    for name in ["wonderwall", "a-horse-with-no-name", "smells-like-teen-spirit", "riptide", "brown-eyed-girl"] {
        guard let t = try? Transcriber.analyze(url: URL(fileURLWithPath: "\(dir)/\(name).m4a")) else { continue }
        print("   \(name) — heard strum \(t.strum), \(Int(t.bpm.rounded())) BPM, key \(t.keyName)")
        for l in ChordArranger.Level.allCases {
            let a = ChordArranger.arrange(t, level: l)
            let s = Transcriber.song(from: a, title: name, artist: "", genre: "Rock", capo: a.capo)
            print("      \(l.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) capo \(s.capo)  strum \(s.strum)  feel \(s.playFeel)  difficulty \(s.difficulty)  chords \(s.uniqueChords.joined(separator: " "))")
        }
    }
}
#endif
