import Foundation
import AppKit
import UniformTypeIdentifiers

/// Import/export for ChordPro (.cho, .chopro, .chordpro) and plain-text chord charts.
/// Only chords are kept — lyrics are ignored.
enum ChordPro {
    private static let sectionWords = ["intro", "verse", "pre-chorus", "prechorus", "chorus", "bridge", "outro", "solo", "interlude", "riff", "hook", "refrain", "coda"]

    static func parse(_ text: String, fallbackTitle: String) -> Song? {
        var title = fallbackTitle, artist = "Imported"
        var bpm = 90, capo = 0, beats = 4
        var sections: [SongSection] = []
        var current: [String] = []
        var name = "Verse"
        let bracket = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]")

        func flush() {
            if !current.isEmpty { sections.append(SongSection(name: name, chords: current.joined(separator: " "))); current = [] }
        }
        func isSectionLabel(_ s: String) -> Bool {
            let l = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return sectionWords.contains { l.hasPrefix($0) }
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("{") && line.hasSuffix("}") {
                let inner = String(line.dropFirst().dropLast())
                let parts = inner.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let key = parts.first?.lowercased() ?? ""
                let value = parts.count > 1 ? parts[1] : ""
                switch key {
                case "title", "t": title = value
                case "artist", "subtitle", "st": artist = value
                case "tempo": bpm = Int(value.filter(\.isNumber)) ?? bpm
                case "capo": capo = Int(value.filter(\.isNumber)) ?? capo
                case "time": beats = value.hasPrefix("3") || value.hasPrefix("6") ? 3 : 4
                case "start_of_chorus", "soc": flush(); name = value.isEmpty ? "Chorus" : value
                case "start_of_verse", "sov": flush(); name = value.isEmpty ? "Verse" : value
                case "start_of_bridge", "sob": flush(); name = value.isEmpty ? "Bridge" : value
                case "end_of_chorus", "eoc", "end_of_verse", "eov", "end_of_bridge", "eob": flush(); name = "Verse"
                case "comment", "c", "comment_italic", "ci":
                    if isSectionLabel(value) { flush(); name = value }
                default: break
                }
                continue
            }

            // "[Chorus]" or "Chorus:" style labels in plain-text charts
            let unwrapped = line.hasPrefix("[") && line.hasSuffix("]") ? String(line.dropFirst().dropLast()) : line
            if isSectionLabel(unwrapped) && ChordSymbol.parse(unwrapped) == nil && unwrapped.count < 30 {
                flush()
                name = unwrapped.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).capitalized
                continue
            }

            // inline [C] chords inside lyric lines
            let ns = line as NSString
            let matches = bracket.matches(in: line, range: NSRange(location: 0, length: ns.length))
            let inline = matches.map { ns.substring(with: $0.range(at: 1)) }.filter { ChordSymbol.parse($0) != nil }
            if !inline.isEmpty { current += inline; continue }

            // chord-only lines: "G  D  |  Em  C"
            let tokens = line.split(whereSeparator: { " \t|".contains($0) }).map(String.init).filter { !["-", "/", "%", "x"].contains($0) }
            if !tokens.isEmpty && tokens.allSatisfy({ ChordSymbol.parse($0) != nil }) { current += tokens }
        }
        flush()
        guard !sections.isEmpty else { return nil }

        // collapse identical consecutive sections into repeats
        var collapsed: [SongSection] = []
        for s in sections {
            if var last = collapsed.last, last.name == s.name, last.chords == s.chords {
                last.repeats += 1
                collapsed[collapsed.count - 1] = last
            } else { collapsed.append(s) }
        }
        return Song(id: "custom-\(UUID().uuidString.prefix(8))", title: title, artist: artist, genre: "Custom", bpm: bpm,
                    beatsPerBar: beats, capo: capo, strum: beats == 3 ? "D-DUDU" : "D-DU-UDU", sections: collapsed, isCustom: true)
    }

    static func export(_ song: Song) -> String {
        var out = ["{title: \(song.title)}", "{artist: \(song.artist)}", "{tempo: \(song.bpm)}", "{time: \(song.beatsPerBar)/4}"]
        if song.capo > 0 { out.append("{capo: \(song.capo)}") }
        out.append("")
        for sec in song.sections {
            let chorus = sec.name.lowercased().contains("chorus")
            out.append(chorus ? "{start_of_chorus: \(sec.name)}" : "{start_of_verse: \(sec.name)}")
            if let s = sec.strum { out.append("{comment: Strum \(s)}") }
            let line = sec.tokens(beatsPerBar: song.beatsPerBar).filter { !$0.chord.hasPrefix("~") }.map { "[\($0.chord)]" }.joined(separator: " ")
            for _ in 0..<max(1, sec.repeats) { out.append(line) }
            out.append(chorus ? "{end_of_chorus}" : "{end_of_verse}")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    @MainActor
    static func importWithPanel() -> [Song] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text] + ["cho", "chopro", "chordpro", "crd", "pro"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose ChordPro (.cho / .chordpro) or plain-text chord charts"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
            return parse(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        }
    }

    @MainActor
    static func exportWithPanel(_ song: Song) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = song.title.replacingOccurrences(of: "/", with: "-") + ".cho"
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? export(song).write(to: url, atomically: true, encoding: .utf8)
    }
}
