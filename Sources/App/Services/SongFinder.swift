import Foundation
import AppKit
import AVFoundation

/// A song found in Apple's public music catalog (iTunes Search API — free, no account or key).
struct CatalogTrack: Identifiable, Codable, Hashable {
    var trackId: Int
    var trackName: String
    var artistName: String
    var collectionName: String?
    var primaryGenreName: String?
    var trackTimeMillis: Int?
    var previewUrl: String?
    var artworkUrl100: String?

    var id: Int { trackId }
    var lengthText: String? {
        guard let ms = trackTimeMillis else { return nil }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    var artworkURL: URL? { artworkUrl100.flatMap { URL(string: $0) } }
    var largeArtworkURL: URL? { artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) } }

    /// Maps the store's genre onto the app's genre list.
    var genre: String {
        let g = (primaryGenreName ?? "").lowercased()
        if g.contains("alternative") || g.contains("indie") { return "Indie" }
        if g.contains("rock") || g.contains("metal") || g.contains("punk") { return "Rock" }
        if g.contains("country") { return "Country" }
        if g.contains("folk") || g.contains("singer") || g.contains("acoustic") { return "Folk" }
        if g.contains("blues") { return "Blues" }
        if g.contains("reggae") { return "Reggae" }
        if g.contains("r&b") || g.contains("soul") || g.contains("funk") { return "Soul" }
        return "Pop"
    }
}

enum SongFinder {
    private struct Response: Decodable { var results: [CatalogTrack] }

    static func search(_ query: String) async throws -> [CatalogTrack] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            .init(name: "term", value: query),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "25")
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        var seen = Set<String>()
        // the store lists many versions of the same song; keep the first of each title + artist
        return try JSONDecoder().decode(Response.self, from: data).results.filter { t in
            let key = (t.trackName + "|" + t.artistName).lowercased()
            return seen.insert(key).inserted
        }
    }

    static func download(_ url: URL, to dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Opens a web search for chord charts of this song in the user's browser.
    static func openChordSearch(title: String, artist: String) {
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [.init(name: "q", value: "\(title) \(artist) chords")]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Per-song media (album art and the 30-second preview)

enum SongMedia {
    static var artFolder: URL { folder("Artwork") }
    static var previewFolder: URL { folder("Previews") }

    private static func folder(_ name: String) -> URL {
        let u = ProgressStore.folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func artURL(_ id: String) -> URL { artFolder.appendingPathComponent(id + ".jpg") }
    static func previewURL(_ id: String) -> URL { previewFolder.appendingPathComponent(id + ".m4a") }

    private static let cache = NSCache<NSString, NSImage>()
    private static var missing = Set<String>()
    private static let lock = NSLock()

    static func image(for id: String) -> NSImage? {
        guard id.hasPrefix("custom-") else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let i = cache.object(forKey: id as NSString) { return i }
        if missing.contains(id) { return nil }
        if let i = NSImage(contentsOf: artURL(id)) { cache.setObject(i, forKey: id as NSString); return i }
        missing.insert(id)
        return nil
    }

    /// Copies downloaded media into place under the song's id.
    static func store(art: URL?, preview: URL?, for id: String) {
        let fm = FileManager.default
        if let art {
            try? fm.removeItem(at: artURL(id))
            try? fm.copyItem(at: art, to: artURL(id))
            lock.lock(); missing.remove(id); cache.removeObject(forKey: id as NSString); lock.unlock()
        }
        if let preview {
            try? fm.removeItem(at: previewURL(id))
            try? fm.copyItem(at: preview, to: previewURL(id))
        }
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: artURL(id))
        try? FileManager.default.removeItem(at: previewURL(id))
    }

    static func hasPreview(_ id: String) -> Bool { FileManager.default.fileExists(atPath: previewURL(id).path) }
}

/// Plays a preview clip and reports the playhead so the chord chart can follow along.
@Observable
final class PreviewPlayer {
    private(set) var playing = false
    private(set) var time: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func toggle(_ url: URL) { playing ? stop() : play(url) }

    func play(_ url: URL, from start: Double = 0) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.currentTime = start
        p.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.time = p.currentTime
            if !p.isPlaying { self.stop() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playing = false
    }

    deinit { timer?.invalidate() }
}
