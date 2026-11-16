import Foundation
import AppKit

/// Real album covers for the built-in songs, looked up once in Apple's public music catalog
/// (the same free, key-less search Add Any Song uses) and cached in the Artwork folder.
/// Lessons and exercises keep their generated artwork.
@MainActor
final class AlbumArt: ObservableObject {
    static let shared = AlbumArt()

    /// Bumped whenever a new cover arrives so artwork views refresh.
    @Published private(set) var version = 0

    private var images: [String: NSImage] = [:]
    private var queue: [Song] = []
    private var queued = Set<String>()
    private var running = false
    private var missing: [String: Date] = [:]
    private let missingURL = SongMedia.artFolder.appendingPathComponent("not-found.json")

    private init() {
        if let d = try? Data(contentsOf: missingURL), let m = try? JSONDecoder().decode([String: Date].self, from: d) { missing = m }
    }

    /// The cover for a song id, if one is cached (custom songs keep the art saved when they were added).
    func image(for id: String) -> NSImage? {
        if id.hasPrefix("custom-") { return SongMedia.image(for: id) }
        if let i = images[id] { return i }
        let url = SongMedia.artURL(id)
        guard FileManager.default.fileExists(atPath: url.path), let i = NSImage(contentsOf: url) else { return nil }
        images[id] = i
        return i
    }

    /// Ask for a cover; it's fetched in the background if we don't have it yet.
    func request(_ id: String) {
        guard !id.hasPrefix("custom-"), !queued.contains(id), image(for: id) == nil,
              let song = SongCatalog.songs.first(where: { $0.id == id }), Self.eligible(song) else { return }
        // songs the catalog didn't have are retried after a week
        if let when = missing[id], Date().timeIntervalSince(when) < 7 * 86400 { return }
        queued.insert(id)
        queue.append(song)
        pump()
    }

    /// Fetch every built-in song's cover in the background (polite pace).
    func prefetchAll() {
        for s in SongCatalog.songs { request(s.id) }
    }

    static func eligible(_ s: Song) -> Bool {
        s.genre != "Exercise" && s.artist != SongCatalog.lessons && s.artist != "Don’t Fret"
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let song = queue.removeFirst()
        Task {
            let result = await Self.fetch(song)
            switch result {
            case .found(let img):
                images[song.id] = img
                version += 1
            case .notFound:
                missing[song.id] = Date()
                if let d = try? JSONEncoder().encode(missing) { try? d.write(to: missingURL) }
            case .offline:
                // try again another time
                queued.remove(song.id)
            }
            // Apple asks for roughly 20 searches a minute at most
            try? await Task.sleep(for: .milliseconds(3200))
            running = false
            pump()
        }
    }

    private enum Result { case found(NSImage), notFound, offline }

    private static func fetch(_ song: Song) async -> Result {
        let title = cleanTitle(song.title)
        let traditional = song.artist == "Traditional"
        let term = traditional ? title : "\(title) \(song.artist)"
        guard let tracks = try? await SongFinder.search(term) else { return .offline }
        let best = tracks.first { t in
            let titleOK = norm(t.trackName).hasPrefix(norm(title)) || norm(title).hasPrefix(norm(cleanTitle(t.trackName)))
            let artistOK = traditional || norm(t.artistName).contains(norm(song.artist)) || norm(song.artist).contains(norm(t.artistName))
            return titleOK && artistOK && t.largeArtworkURL != nil
        }
        guard let url = best?.largeArtworkURL else { return .notFound }
        let dest = SongMedia.artURL(song.id)
        do {
            try await SongFinder.download(url, to: dest)
        } catch {
            return .offline
        }
        guard let img = NSImage(contentsOf: dest) else { return .notFound }
        return .found(img)
    }

    /// "Sweet Child (Rhythm)" → "Sweet Child"
    static func cleanTitle(_ t: String) -> String {
        var s = t
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber }
    }
}
