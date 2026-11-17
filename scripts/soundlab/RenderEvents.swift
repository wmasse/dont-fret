// Stand-alone renderer for the sound lab: compiles with just the guitar engine, in seconds.
//   swiftc -O -parse-as-library Sources/App/Audio/Guitar/Guitar{DSP,Body,Engine}.swift scripts/soundlab/RenderEvents.swift -o build/render-events
//   build/render-events events.txt out.wav [--room 0…1] [--polish 0…1] [--set name=value,…]  (see GuitarTuning)
// Event format: see scripts/soundlab/resynth.py (same as `selftest --render-events`).
import Foundation
import AVFoundation

@main
struct RenderEvents {
    static func main() {
        var args = CommandLine.arguments.filter { $0 != "--render-events" }
        for (flag, set) in [("--room", { GuitarBody.roomAmount = $0 }), ("--polish", { GuitarBody.polishAmount = $0 })] as [(String, (Double) -> Void)] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                set(Double(args[i + 1]) ?? 1)
                args.removeSubrange(i...(i + 1))
            }
        }
        guard args.count >= 3, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
            print("usage: render-events events.txt out.wav"); exit(1)
        }
        if let i = args.firstIndex(of: "--cal"), i + 1 < args.count {
            GuitarBody.calibrationOverride = args[i + 1].split(separator: ",").compactMap { Double($0) }
            args.removeSubrange(i...(i + 1))
        }
        if let i = args.firstIndex(of: "--set"), i + 1 < args.count {
            GuitarTuning.set(args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        let sr = 44100.0
        var tone = 0, end = 0.0
        var events: [GuitarCore.Event] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if f.first == "#" { if f.count >= 3, f[1] == "tone" { tone = Int(f[2]) ?? 0 }; continue }
            guard f.count >= 12, let t = Double(f[0]) else { continue }
            let kind: GuitarCore.Kind = ["p": .pluck, "d": .damp, "c": .chuck, "r": .retune, "h": .hold][f[1]] ?? .pluck
            var e = GuitarCore.Event(kind: kind, string: Int(f[2]) ?? 0, midi: Int(f[3]) ?? 40, velocity: Float(f[5]) ?? 0.8,
                                     bright: Float(f[6]) ?? 0.6, delay: Int(t * sr), pick: Float(f[7]) ?? 0.15)
            e.detune = Float(f[4]) ?? 0
            e.touch = Touch(rawValue: UInt8(f[8]) ?? 0) ?? .pick
            e.mute = Float(f[9]) ?? 0
            e.decay = Float(f[10]) ?? 0
            e.keep = Float(f[11]) ?? 0.12
            events.append(e)
            end = max(end, t)
        }
        let core = GuitarCore(sampleRate: sr)
        core.tone = tone
        core.enqueue(events)
        let total = Int((end + 2.5) * sr)
        var l = [Float](repeating: 0, count: total), r = l
        var i = 0
        while i < total {
            let n = min(512, total - i)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in _ = core.render(lp.baseAddress! + i, rp.baseAddress! + i, n) } }
            i += n
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)) else { print("can't write \(args[2])"); exit(1) }
        buf.frameLength = AVAudioFrameCount(total)
        l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: total) }
        r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: total) }
        try? file.write(from: buf)
    }
}
