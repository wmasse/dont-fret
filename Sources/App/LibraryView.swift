import SwiftUI

// MARK: - My Songs: the list of songs the player can play

extension ProgressData {
    /// The starting list for saves made before My Songs existed: the songs you added yourself,
    /// then the ones you've finished in Play Along or Wait Mode (most recent first).
    static func seedMySongs(custom: [Song], records: [String: SongRecord]) -> [String] {
        var out = custom.map(\.id)
        let finished = records
            .filter { $0.value.plays > 0 && (!$0.value.history.isEmpty || $0.value.bestScore > 0) }
            .sorted { $0.value.lastPlayed > $1.value.lastPlayed }
            .map(\.key)
        for id in finished where !out.contains(id) { out.append(id) }
        return out
    }
}

extension ProgressStore {
    /// My Songs in the player's own order (songs that no longer exist are skipped).
    var mySongs: [Song] {
        let byID = Dictionary(allSongs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return data.mySongs.compactMap { byID[$0] }
    }

    func isInMySongs(_ id: String) -> Bool { data.mySongs.contains(id) }

    /// Called when a song is added or finished. Songs the player removed by hand stay removed.
    func autoAddToMySongs(_ id: String) {
        guard !data.mySongs.contains(id), !data.mySongsRemoved.contains(id) else { return }
        data.mySongs.append(id)
    }

    /// The player put this song on the list themselves. `after` places it right below another song.
    func addToMySongs(_ id: String, after other: String? = nil) {
        var d = data
        d.mySongsRemoved.removeAll { $0 == id }
        if !d.mySongs.contains(id) {
            if let other, let i = d.mySongs.firstIndex(of: other) { d.mySongs.insert(id, at: i + 1) }
            else { d.mySongs.append(id) }
        }
        data = d
    }

    func removeFromMySongs(_ id: String) {
        var d = data
        d.mySongs.removeAll { $0 == id }
        if !d.mySongsRemoved.contains(id) { d.mySongsRemoved.append(id) }
        data = d
    }

    /// Move a song one place up (-1) or down (+1) among the songs that are shown.
    func moveMySong(_ id: String, by delta: Int) {
        let shown = mySongs.map(\.id)
        guard let i = shown.firstIndex(of: id), shown.indices.contains(i + delta),
              let a = data.mySongs.firstIndex(of: id), let b = data.mySongs.firstIndex(of: shown[i + delta]) else { return }
        var d = data
        d.mySongs.swapAt(a, b)
        data = d
    }

    func moveMySongToTop(_ id: String) {
        guard let i = data.mySongs.firstIndex(of: id), i > 0 else { return }
        var d = data
        d.mySongs.remove(at: i)
        d.mySongs.insert(id, at: 0)
        data = d
    }

    /// Drag and drop: the dragged song takes the place of the one it was dropped on.
    func moveMySong(_ id: String, onto target: String) {
        guard id != target, let from = data.mySongs.firstIndex(of: id), let to = data.mySongs.firstIndex(of: target) else { return }
        var d = data
        d.mySongs.remove(at: from)
        d.mySongs.insert(id, at: to)
        data = d
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case manual = "My order", recent = "Recently played", title = "Title", artist = "Artist"
    case easiest = "Easiest first", hardest = "Hardest first", best = "Best score"
    var id: String { rawValue }
}

/// The My Songs page with its own back stack, so opening a song keeps you in My Songs.
struct MySongsPage: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    var body: some View {
        NavigationStack(path: $app.libraryPath) {
            LibraryView()
                .navigationDestination(for: Song.self) { SongDetailView(song: $0) }
        }
        // a song deleted from its own page shouldn't stay open
        .onChange(of: progress.data.customSongs.count) { _, _ in
            app.libraryPath.removeAll { progress.song(id: $0.id) == nil }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    @AppStorage("mySongsSort") private var sortRaw = LibrarySort.manual.rawValue
    @State private var query = ""
    @State private var adding = false
    @State private var addRequest: AddRequest?
    @State private var editing: Song?
    /// When editing a copy of a built-in song: the song it was copied from.
    @State private var copyOf: String?
    @State private var width: CGFloat = 900

    static let dragPrefix = "dontfret-song:"

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .manual }

    private func sorted(_ songs: [Song], levels: [String: Int]) -> [Song] {
        let rec = progress.data.songs
        func played(_ s: Song) -> Date? { rec[s.id].flatMap { $0.plays > 0 ? $0.lastPlayed : nil } }
        func level(_ s: Song) -> Int { levels[s.id] ?? 1 }
        switch sort {
        case .manual: return songs
        case .recent:
            return songs.sorted { a, b in
                switch (played(a), played(b)) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.title < b.title
                }
            }
        case .title: return songs.sorted { $0.title < $1.title }
        case .artist: return songs.sorted { $0.artist == $1.artist ? $0.title < $1.title : $0.artist < $1.artist }
        case .easiest: return songs.sorted { level($0) == level($1) ? $0.title < $1.title : level($0) < level($1) }
        case .hardest: return songs.sorted { level($0) == level($1) ? $0.title < $1.title : level($0) > level($1) }
        case .best:
            return songs.sorted { a, b in
                let ra = rec[a.id] ?? SongRecord(), rb = rec[b.id] ?? SongRecord()
                if ra.stars != rb.stars { return ra.stars > rb.stars }
                if ra.bestAccuracy != rb.bestAccuracy { return ra.bestAccuracy > rb.bestAccuracy }
                if ra.bestScore != rb.bestScore { return ra.bestScore > rb.bestScore }
                return a.title < b.title
            }
        }
    }

    var body: some View {
        let all = progress.mySongs
        let levels = Dictionary(all.map { ($0.id, $0.difficulty) }, uniquingKeysWith: { a, _ in a })
        let shown = sorted(all.filter { $0.matches(query) }, levels: levels)
        let canReorder = sort == .manual && query.trimmingCharacters(in: .whitespaces).isEmpty
        Page {
            PageHeader(title: "My Songs", subtitle: subtitle(all)) {
                Button { adding = true } label: { Label("Add Songs", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .help("Pick songs from the catalog or your own songs")
            }

            if all.isEmpty {
                VStack(spacing: 4) {
                    EmptyStateView(icon: "heart", title: "No songs here yet",
                                   message: "This is your own list of songs you can play. Songs you add yourself and songs you finish in Play Along or Wait Mode show up here, or pick some now.")
                    Button { adding = true } label: { Label("Add Songs", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)
            } else {
                HStack(spacing: 14) {
                    SearchField(text: $query, prompt: "Search My Songs…")
                        .frame(maxWidth: 420)
                    Menu {
                        ForEach(LibrarySort.allCases) { s in
                            Button { sortRaw = s.rawValue } label: {
                                if s == sort { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) }
                            }
                        }
                    } label: {
                        Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(shown.count == all.count ? "\(all.count) song\(all.count == 1 ? "" : "s")" : "\(shown.count) of \(all.count)")
                        .font(Theme.font(13, .medium)).foregroundStyle(Theme.textFaint)
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width }
                        .onChange(of: g.size.width) { _, w in width = w }
                })

                if shown.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Nothing matches “\(query)”",
                                   message: "It isn't in My Songs. Use Add Songs to put it on the list.")
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Divider().overlay(Theme.stroke).padding(.leading, canReorder ? 112 : 80) }
                            LibraryRow(song: s, level: levels[s.id] ?? 1, record: progress.data.songs[s.id],
                                       wide: width >= 850, canReorder: canReorder,
                                       isFirst: i == 0, isLast: i == shown.count - 1,
                                       onOpen: { app.libraryPath.append(s) },
                                       onPlay: { app.play(s, mode: progress.skill.recommendedMode, tempo: progress.skill.defaultTempo) },
                                       onEdit: { edit(s) })
                        }
                    }
                    .card(padding: 6, radius: 18)
                    if canReorder && all.count > 1 {
                        Text("Drag the handle on the left to put songs in your own order, or use Move Up and Move Down in the ⋯ menu.")
                            .font(Theme.font(12)).foregroundStyle(Theme.textFaint)
                            .padding(.top, -14)
                    }
                }
            }
        }
        .sheet(isPresented: $adding) {
            LibraryAddSheet { q in
                adding = false
                // let the picker close before the search sheet opens
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addRequest = AddRequest(query: q) }
            }
            .environmentObject(progress)
        }
        .sheet(item: $addRequest) { r in
            AddSongView(initialQuery: r.query)
                .environmentObject(app)
                .environmentObject(progress)
        }
        .sheet(item: $editing) { e in
            SongEditorView(existing: e, onDone: { saved in
                if let saved {
                    progress.addCustomSong(saved)
                    // a new copy sits right under the song it came from
                    if let from = copyOf, from != saved.id, progress.isInMySongs(saved.id) {
                        progress.removeFromMySongs(saved.id)
                        progress.addToMySongs(saved.id, after: from)
                    }
                }
                editing = nil
                copyOf = nil
            })
            .environmentObject(progress)
        }
    }

    private func subtitle(_ all: [Song]) -> String {
        guard !all.isEmpty else { return "The songs you can play, all in one place." }
        let rec = progress.data.songs
        let starred = all.filter { (rec[$0.id]?.stars ?? 0) >= 3 }.count
        let minutes = Int((all.reduce(0) { $0 + $1.duration } / 60).rounded())
        var parts = ["\(all.count) song\(all.count == 1 ? "" : "s") you can play", "\(minutes) min of music"]
        if starred > 0 { parts.append("\(starred) with 3 stars") }
        return parts.joined(separator: " · ")
    }

    /// Your own songs open in the editor; built-in songs open as a copy you can change.
    private func edit(_ s: Song) {
        if s.isCustom {
            copyOf = nil
            editing = s
        } else {
            var c = s
            c.id = "custom-\(UUID().uuidString.prefix(8))"
            c.title = s.title + " (My Version)"
            c.isCustom = true
            c.note = nil
            copyOf = s.id
            editing = c
        }
    }
}

/// One song in My Songs: cover, title, artist, chords, difficulty, best score and when it was last played.
struct LibraryRow: View {
    @EnvironmentObject var progress: ProgressStore
    var song: Song
    var level: Int
    var record: SongRecord?
    var wide: Bool
    var canReorder: Bool
    var isFirst: Bool
    var isLast: Bool
    var onOpen: () -> Void
    var onPlay: () -> Void
    var onEdit: () -> Void
    @State private var hover = false
    @State private var targeted = false

    private var played: SongRecord? { record.flatMap { $0.plays > 0 ? $0 : nil } }
    private var scored: SongRecord? { played.flatMap { $0.bestScore > 0 || $0.stars > 0 || !$0.history.isEmpty ? $0 : nil } }

    static func lastPlayedText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "\(days) days ago" }
        if days < 35 { return days / 7 == 1 ? "1 week ago" : "\(days / 7) weeks ago" }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    var body: some View {
        HStack(spacing: 12) {
            if canReorder { grip }
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    ArtworkView(seed: song.id, title: song.title, genre: song.genre, size: 54, radius: 9)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(song.title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            if song.isCustom {
                                Text("Mine").font(Theme.font(10, .semibold)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.accent.opacity(0.15)))
                                    .fixedSize()
                            }
                        }
                        Text(song.artist).font(Theme.font(12.5)).foregroundStyle(Theme.textDim).lineLimit(1)
                        chords
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if wide {
                        DifficultyBadge(level: level).frame(width: 128, alignment: .leading)
                        scoreColumn.frame(width: 132, alignment: .leading)
                        lastColumn.frame(width: 98, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            DifficultyBadge(level: level, compact: true)
                            scoreColumn
                            Text(played.map { Self.lastPlayedText($0.lastPlayed) } ?? "Not played yet")
                                .font(Theme.font(11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                        .frame(width: 132, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the song")

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accentGradient))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play \(song.title) now")
            .accessibilityLabel("Play \(song.title)")

            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 28, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Edit, move or remove")
            .accessibilityLabel("Options for \(song.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(hover ? Theme.fill : Color.clear))
        .overlay(alignment: .top) {
            if targeted { Capsule().fill(Theme.accent).frame(height: 3).padding(.horizontal, 8) }
        }
        .onHover { hover = $0 }
        .contextMenu { menuItems }
        .dropDestination(for: String.self) { items, _ in
            guard canReorder, let raw = items.first, raw.hasPrefix(LibraryView.dragPrefix) else { return false }
            let id = String(raw.dropFirst(LibraryView.dragPrefix.count))
            guard id != song.id, progress.isInMySongs(id) else { return false }
            progress.moveMySong(id, onto: song.id)
            return true
        } isTargeted: { targeted = $0 && canReorder }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hover ? Theme.textDim : Theme.textFaint)
            .frame(width: 20, height: 44)
            .contentShape(Rectangle())
            .draggable(LibraryView.dragPrefix + song.id) {
                Text(song.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.surface2))
            }
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }

    @ViewBuilder private var chords: some View {
        let names = song.uniqueChords
        if names.isEmpty {
            Text("Riff · \(song.uniqueNotes.count) notes").font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint)
        } else {
            let limit = wide ? 7 : 5
            HStack(spacing: 4) {
                ForEach(names.prefix(limit), id: \.self) { c in
                    Text(c).font(Theme.font(11, .bold)).foregroundStyle(Theme.textDim)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.fill))
                }
                if names.count > limit {
                    Text("+\(names.count - limit)").font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint).fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var scoreColumn: some View {
        if let r = scored {
            VStack(alignment: .leading, spacing: 4) {
                StarRow(stars: r.stars, size: 11)
                Text("Best \(r.bestScore.formatted()) · \(Int((r.bestAccuracy * 100).rounded()))%")
                    .font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textDim).lineLimit(1).monospacedDigit()
            }
        } else {
            Text(played == nil ? "No score yet" : "Played, not scored")
                .font(Theme.font(11.5, .medium)).foregroundStyle(Theme.textFaint).lineLimit(1)
        }
    }

    private var lastColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LAST PLAYED").font(Theme.font(9, .heavy)).tracking(1).foregroundStyle(Theme.textFaint)
            Text(played.map { Self.lastPlayedText($0.lastPlayed) } ?? "Not yet")
                .font(Theme.font(12, .medium)).foregroundStyle(played == nil ? Theme.textFaint : Theme.textDim).lineLimit(1)
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open", action: onOpen)
        Button("Play Now", action: onPlay)
        Divider()
        Button(song.isCustom ? "Edit…" : "Edit a Copy…", action: onEdit)
        if canReorder {
            Divider()
            Button("Move to Top") { progress.moveMySongToTop(song.id) }.disabled(isFirst)
            Button("Move Up") { progress.moveMySong(song.id, by: -1) }.disabled(isFirst)
            Button("Move Down") { progress.moveMySong(song.id, by: 1) }.disabled(isLast)
        }
        Divider()
        Button("Remove from My Songs", role: .destructive) { progress.removeFromMySongs(song.id) }
    }

    private var accessibilityText: String {
        var t = "\(song.title) by \(song.artist). \(Difficulty.name(level))."
        if !song.uniqueChords.isEmpty { t += " Chords: \(song.uniqueChords.prefix(7).joined(separator: ", "))." }
        if let r = scored { t += " \(r.stars) of 3 stars, best score \(r.bestScore)." }
        t += played.map { " Last played \(Self.lastPlayedText($0.lastPlayed).lowercased())." } ?? " Not played yet."
        return t
    }
}

/// Pick songs for My Songs from the catalog and your own songs.
struct LibraryAddSheet: View {
    @EnvironmentObject var progress: ProgressStore
    @Environment(\.dismiss) private var dismiss
    /// Search all music for a song that isn't in the app yet.
    var onFindAny: (String) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All songs", level = "For my level", mine = "My own songs", played = "Played before"
        var id: String { rawValue }
    }
    @State private var query = ""
    @State private var filter: Filter = .all

    private var results: [Song] {
        let range = progress.skill.songRange
        let rec = progress.data.songs
        return progress.allSongs.filter { s in
            guard s.matches(query) else { return false }
            switch filter {
            case .all: return true
            case .level: return range.contains(s.difficulty)
            case .mine: return s.isCustom
            case .played: return (rec[s.id]?.plays ?? 0) > 0
            }
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let res = results
        let q = query.trimmingCharacters(in: .whitespaces)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to My Songs").font(Theme.font(22, .bold)).foregroundStyle(Theme.text)
                        Text("Tick the songs you can play.").font(Theme.font(13)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                }
                SearchField(text: $query, prompt: "Search songs, artists or chords…")
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        Chip(title: f.rawValue, selected: filter == f) { filter = f }
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(res) { s in row(s) }
                    if res.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "No songs found",
                                       message: q.isEmpty ? "Nothing fits this filter yet." : "“\(q)” isn't in the app yet. Search all music to add it.")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            Divider().overlay(Theme.stroke)
            HStack(spacing: 10) {
                Button { onFindAny(q) } label: { Label(q.isEmpty ? "Find Any Song…" : "Search all music for “\(q)”", systemImage: "plus.magnifyingglass") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Search any song — the app works out the chords for you")
                Spacer()
                Text("\(progress.mySongs.count) in My Songs").font(Theme.font(12, .medium)).foregroundStyle(Theme.textFaint)
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 640, height: 680)
        .background(Theme.surface)
    }

    private func row(_ s: Song) -> some View {
        let added = progress.isInMySongs(s.id)
        return Button {
            if added { progress.removeFromMySongs(s.id) } else { progress.addToMySongs(s.id) }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(seed: s.id, title: s.title, genre: s.genre, size: 42, radius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(s.artist).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(s.uniqueChords.isEmpty ? "Riff" : "\(s.uniqueChords.count) chords")
                    .font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint)
                DifficultyBadge(level: s.difficulty, compact: true).frame(width: 44)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(added ? Theme.success : Theme.textDim)
                    .frame(width: 28)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(added ? Theme.success.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.title) by \(s.artist)")
        .accessibilityValue(added ? "In My Songs" : "Not in My Songs")
        .accessibilityHint(added ? "Removes it from My Songs" : "Adds it to My Songs")
    }
}
