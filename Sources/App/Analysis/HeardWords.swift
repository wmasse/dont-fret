import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// A word the speech recogniser heard sung in a recording, in seconds of the recording.
struct HeardWord: Hashable {
    var time: Double
    var text: String
    /// How sure the recogniser was of the word (0–1), when it says.
    var confidence: Double? = nil
}

/// Picks the sung words out of a recording with Apple's on-device speech recogniser (macOS 26+),
/// so lyrics can be lined up by what is sung rather than only by when someone seems to be singing.
/// Nothing leaves the Mac. On older systems, or when the language isn't supported, it hears nothing
/// and the lyrics fall back to the voice-timing match in `Lyrics.align`.
enum WordListener {
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The language the lyrics are written in (BCP-47, e.g. "en", "es"), so the recogniser listens for it.
    static func language(of lines: [TimedLyric]) -> String? {
        let text = lines.map(\.text).joined(separator: " ")
        guard text.count >= 40 else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    /// Words heard in an audio file.
    /// `hints` are words likely to be sung (the song's title and artist), so the recogniser spells them right.
    static func words(url: URL, language: String?, hints: [String] = []) async -> [HeardWord] {
        guard #available(macOS 26, *) else { return [] }
        return (try? await transcribe(url: url, language: language, hints: hints)) ?? []
    }

    /// Words heard in raw samples (mono, any sample rate).
    static func words(samples: [Float], sampleRate: Double, language: String?, hints: [String] = []) async -> [HeardWord] {
        guard #available(macOS 26, *), samples.count > Int(sampleRate * 4) else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dontfret-words-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
            // the file must be closed (released) before it's read back
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buf)
            }
            return try await transcribe(url: url, language: language, hints: hints)
        } catch {
            return []
        }
    }

    @available(macOS 26, *)
    private static func transcribe(url: URL, language: String?, hints: [String]) async throws -> [HeardWord] {
        let wanted = Locale(identifier: language.map { $0 == "en" ? "en-US" : $0 } ?? "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return [] }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        // the language model is a one-time system download (shared with dictation)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let hintWords = hints.filter { !$0.isEmpty }
        if !hintWords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hintWords
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> [HeardWord] in
            var out: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    let confidence = run.transcriptionConfidence
                    for w in text.split(whereSeparator: { $0.isWhitespace }) where !w.isEmpty {
                        out.append(HeardWord(time: range.start.seconds, text: String(w), confidence: confidence))
                    }
                }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        return try await collect.value.sorted { $0.time < $1.time }
    }
}
