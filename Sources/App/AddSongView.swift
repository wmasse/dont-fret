import SwiftUI

/// Search any song → the app listens to its preview and writes the chords → check and add.
struct AddSongView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    @Environment(\.dismiss) var dismiss

    var initialQuery = ""

    enum Phase: Equatable {
        case search
        case working(CatalogTrack)
        case review(CatalogTrack)
        case paste(CatalogTrack?)
        case edit
    }

    @State private var phase: Phase = .search
    @State private var query = ""
    @State private var results: [CatalogTrack] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var player = PreviewPlayer()
    @StateObject private var chordPlayer = ProgressionPlayer()

    // analysis
    @State private var step = 0
    @State private var failure: String?
    @State private var transcription: Transcription?
    @State private var previewFile: URL?
    @State private var artFile: URL?
    @State private var useCapo = true
    @State private var draft: Song?
    /// Whole-song chords from a chord chart, lined up with the recording (nil: none found or not looked up).
    @State private var chartMatch: ChartMatch?
    @State private var chartLooked = false

    // paste
    @State private var pasted = ""

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            Group {
                switch phase {
                case .search: searchView
                case .working(let t): workingView(t)
                case .review(let t): reviewView(t)
                case .paste(let t): pasteView(t)
                case .edit:
                    if let d = draft {
                        SongEditorView(existing: d, embedded: true) { saved in
                            if let saved { finish(saved) } else { phase = transcription == nil ? .search : (lastTrack.map { .review($0) } ?? .search) }
                        }
                        .environmentObject(progress)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 660)
        .background(Theme.surface)
        .onAppear {
            if !initialQuery.isEmpty { query = initialQuery; runSearch(now: true) }
            searchFocused = true
        }
        .onDisappear { player.stop(); chordPlayer.stop(); searchTask?.cancel() }
    }

    @State private var lastTrack: CatalogTrack?

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            if phase != .search {
                Button { back() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(20, .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.font(12)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 30))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var title: String {
        switch phase {
        case .search: return "Add a song"
        case .working: return "Working out the chords…"
        case .review: return "Here's what we heard"
        case .paste: return "Paste the chords"
        case .edit: return "Fine-tune the chords"
        }
    }
    private var subtitle: String {
        switch phase {
        case .search: return "Search any song — Don't Fret listens to it and writes the chords for you."
        case .working: return "Listening to the 30-second preview. This takes a few seconds."
        case .review: return "Press Listen to hear the song with the chords lighting up. Fix anything that sounds off."
        case .paste: return "Copy a chord chart from any website and paste it below."
        case .edit: return "Click a chord to change it, or add new ones."
        }
    }

    private func back() {
        player.stop()
        switch phase {
        case .edit: if let t = lastTrack { phase = .review(t) } else { phase = .search }
        case .paste: if transcription != nil, let t = lastTrack { phase = .review(t) } else { phase = .search }
        default: phase = .search
        }
    }

    // MARK: search

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                TextField("Song title or artist — e.g. “Let It Be”", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.font(18, .medium))
                    .focused($searchFocused)
                    .onSubmit { runSearch(now: true) }
                    .onChange(of: query) { _, _ in runSearch(now: false) }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(searchFocused ? Theme.accent : Theme.strokeStrong, lineWidth: searchFocused ? 1.5 : 1))

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                howItWorks
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        let local = Array(progress.allSongs.filter { Self.looselyMatches($0, query) }.prefix(3))
                        if !local.isEmpty {
                            group("Already in Don't Fret") {
                                ForEach(local) { s in
                                    resultRow(art: AnyView(ArtworkView(seed: s.id, title: s.title, genre: s.genre, size: 48)),
                                              title: s.title, detail: "\(s.artist) · \(Difficulty.name(s.difficulty))", action: "Open") {
                                        dismiss(); app.openSong(s)
                                    }
                                }
                            }
                        }
                        if let e = searchError {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(e, systemImage: "wifi.exclamationmark").font(Theme.font(13, .medium)).foregroundStyle(Theme.warn)
                                Button("Try again") { runSearch(now: true) }.buttonStyle(SecondaryButtonStyle())
                            }
                        } else if !results.isEmpty {
                            group("Add from the music catalog") {
                                ForEach(results) { t in
                                    resultRow(art: AnyView(remoteArt(t.artworkURL, size: 48)), title: t.trackName,
                                              detail: [t.artistName, t.collectionName, t.lengthText].compactMap { $0 }.joined(separator: " · "),
                                              action: "Add") { pick(t) }
                                }
                            }
                        } else if searching {
                            Text("Searching…").font(Theme.font(13)).foregroundStyle(Theme.textDim)
                        } else {
                            Text("No songs found. Check the spelling, or try just the title.").font(Theme.font(13)).foregroundStyle(Theme.textDim)
                        }
                        otherWays
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(22)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                stepCard(1, "magnifyingglass", "Search", "Type any song or artist.")
                stepCard(2, "waveform", "We listen", "The app plays the song's preview and works out the beat, key and chords.")
                stepCard(3, "guitars.fill", "Play", "Check it by ear, fix anything, and start practising.")
            }
            Spacer()
            otherWays
        }
    }

    private func stepCard(_ n: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15))
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 42, height: 42)
            Text("\(n). \(title)").font(Theme.font(15, .bold)).foregroundStyle(Theme.text)
            Text(text).font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface2))
        .accessibilityElement(children: .combine)
    }

    private var otherWays: some View {
        HStack(spacing: 14) {
            Text("Other ways:").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textFaint)
            Button { draft = blankSong(); lastTrack = nil; transcription = nil; phase = .edit } label: { Label("Build it chord by chord", systemImage: "square.grid.2x2") }
            Button { phase = .paste(nil) } label: { Label("Paste a chord chart", systemImage: "doc.on.clipboard") }
            Button { importFile() } label: { Label("Import a file", systemImage: "square.and.arrow.down") }
        }
        .buttonStyle(.plain)
        .font(Theme.font(12, .semibold))
        .foregroundStyle(Theme.accent)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
            VStack(spacing: 6) { c() }
        }
    }

    private func resultRow(art: AnyView, title: String, detail: String, action: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                art.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer()
                Text(action).font(Theme.font(12, .bold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accentGradient))
            }
            .padding(8)
            .background(HoverBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint(action)
    }

    private func remoteArt(_ url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface3)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }

    /// Every word of the query appears in the title or artist ("im yours mraz" finds "I'm Yours").
    static func looselyMatches(_ s: Song, _ q: String) -> Bool {
        func norm(_ x: String) -> String {
            x.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber || $0 == " " }
        }
        let hay = norm(s.title + " " + s.artist)
        let words = norm(q).split(separator: " ")
        return !words.isEmpty && words.allSatisfy { hay.contains($0) }
    }

    private func runSearch(now: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; searchError = nil; searching = false; return }
        searching = true
        searchTask = Task {
            if !now { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            await MainActor.run { searching = true; searchError = nil }
            do {
                let r = try await SongFinder.search(q)
                guard !Task.isCancelled else { return }
                await MainActor.run { results = r; searching = false }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searching = false
                    searchError = "Couldn't reach the music catalog. Check your internet connection."
                }
            }
        }
    }

    // MARK: working

    private func pick(_ t: CatalogTrack) {
        lastTrack = t
        transcription = nil; failure = nil; step = 0; chartMatch = nil; chartLooked = false
        guard let p = t.previewUrl.flatMap(URL.init(string:)) else {
            phase = .paste(t)
            return
        }
        phase = .working(t)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dontfret-\(t.trackId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let audio = tmp.appendingPathComponent("preview.m4a"), art = tmp.appendingPathComponent("art.jpg")
        Task {
            do {
                try await SongFinder.download(p, to: audio)
                if let a = t.largeArtworkURL { try? await SongFinder.download(a, to: art) }
                await MainActor.run { step = 1; previewFile = audio; artFile = FileManager.default.fileExists(atPath: art.path) ? art : nil }
                let result = try await Task.detached(priority: .userInitiated) {
                    try Transcriber.analyze(url: audio) { s in Task { @MainActor in step = 1 + s } }
                }.value
                await MainActor.run { step = 4 }
                // the preview is only 30 s: look for a human-made chart of the whole song and line it up
                let seconds = t.trackTimeMillis.map { Double($0) / 1000 }
                let chart = await ChordCharts.find(title: t.trackName, artist: t.artistName)
                let match = chart.flatMap { ChordCharts.match($0, to: result, trackSeconds: seconds) }
                await MainActor.run {
                    transcription = result
                    chartMatch = match
                    chartLooked = true
                    let used = effective(result)
                    useCapo = used.capo > 0 && progress.skill.rank <= 2
                    step = 5
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if case .working(let cur) = phase, cur == t { phase = .review(t) }
                    }
                }
            } catch {
                await MainActor.run { failure = (error as? LocalizedError)?.errorDescription ?? "Couldn't download the preview." }
            }
        }
    }

    private func workingView(_ t: CatalogTrack) -> some View {
        VStack(spacing: 26) {
            Spacer()
            remoteArt(t.largeArtworkURL ?? t.artworkURL, size: 150).shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 4) {
                Text(t.trackName).font(Theme.font(22, .bold)).foregroundStyle(Theme.text)
                Text(t.artistName).font(Theme.font(14)).foregroundStyle(Theme.textDim)
            }
            if let f = failure {
                VStack(spacing: 12) {
                    Label(f, systemImage: "exclamationmark.triangle.fill").font(Theme.font(14, .semibold)).foregroundStyle(Theme.warn)
                    HStack {
                        Button("Try Again") { pick(t) }.buttonStyle(SecondaryButtonStyle())
                        Button("Paste Chords Instead") { phase = .paste(t) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    progressRow("Downloading the 30-second preview", done: step >= 1, active: step == 0)
                    progressRow("Finding the beat", done: step >= 2, active: step == 1)
                    progressRow("Listening for the chords", done: step >= 3, active: step == 2)
                    progressRow("Looking up a chord chart for the whole song", done: step >= 5, active: step == 4)
                    progressRow("Choosing the easiest way to play it", done: step >= 5, active: step == 4)
                }
                .frame(width: 330)
            }
            Spacer()
        }
        .padding(22)
    }

    private func progressRow(_ text: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
                else if active { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle").foregroundStyle(Theme.textFaint) }
            }
            .frame(width: 20)
            Text(text).font(Theme.font(14, active ? .semibold : .regular)).foregroundStyle(done || active ? Theme.text : Theme.textFaint)
        }
    }

    // MARK: review

    private func reviewView(_ t: CatalogTrack) -> some View {
        Group {
            if let raw = transcription {
                let tr = effective(raw)
                let song = builtSong(t, raw)
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top, spacing: 20) {
                                remoteArt(t.largeArtworkURL ?? t.artworkURL, size: 120)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(t.trackName).font(Theme.font(22, .bold)).foregroundStyle(Theme.text).lineLimit(2)
                                    Text(t.artistName).font(Theme.font(14)).foregroundStyle(Theme.textDim)
                                    FlowLayout(spacing: 6) {
                                        Pill(icon: "metronome.fill", text: "\(Int(tr.bpm.rounded())) BPM")
                                        Pill(icon: "key.fill", text: tr.keyName)
                                        Pill(icon: "music.note", text: "\(tr.beatsPerBar)/4")
                                        DifficultyBadge(level: song.difficulty)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(Capsule().fill(Theme.surface2))
                                        Pill(icon: "clock", text: song.durationText)
                                        Pill(icon: "checkmark.seal.fill", text: "\(tr.confidenceLabel) confidence",
                                             tint: tr.confidenceLabel == "High" ? Theme.success : (tr.confidenceLabel == "Medium" ? Theme.warn : Theme.danger))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            sourceCard(song)
                            if tr.capo > 0 { capoChoice(tr) }
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("STRUM HEARD").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                                    Text(StrumPattern.match(song.strum, beatsPerBar: tr.beatsPerBar).name == "Song Pattern" ? "From the recording" : StrumPattern.match(song.strum, beatsPerBar: tr.beatsPerBar).name)
                                        .font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                                    Text("Played \(song.feelName.lowercased())").font(Theme.font(11)).foregroundStyle(Theme.textDim)
                                }
                                StrumPatternView(pattern: StrumPattern.match(song.strum, beatsPerBar: tr.beatsPerBar),
                                                 slotWidth: min(30, 300 / CGFloat(max(1, song.strum.count))))
                                Spacer()
                                HearChordsButton(player: chordPlayer, song: song, label: "Hear Our Version")
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface2))
                            listenCard(tr, song)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("CHORDS").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                                HStack(spacing: 10) {
                                    ForEach(song.uniqueChords, id: \.self) { c in
                                        VStack(spacing: 6) {
                                            ChordChip(name: c, size: 13)
                                            ChordDiagram(name: c, width: 70)
                                        }
                                    }
                                }
                            }
                            structureCard(song)
                            if tr.confidenceLabel == "Low" {
                                Label("This one was hard to hear — busy recordings, effects or unusual chords confuse the listener. Check it against the preview, or paste a chord chart instead.", systemImage: "info.circle")
                                    .font(Theme.font(12)).foregroundStyle(Theme.textDim)
                            }
                        }
                        .padding(22)
                    }
                    Divider().overlay(Theme.stroke)
                    HStack {
                        Button("Not right? Paste chords instead") { player.stop(); phase = .paste(t) }
                            .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Button { player.stop(); draft = song; phase = .edit } label: { Label("Edit Chords", systemImage: "pencil") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { finish(song) } label: { Label("Add to My Songs", systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                }
            }
        }
    }

    private func capoChoice(_ tr: Transcription) -> some View {
        HStack(spacing: 10) {
            choice(selected: useCapo, title: "Capo on fret \(tr.capo)", detail: "Easier open-chord shapes · recommended for you", icon: "hand.thumbsup.fill") { useCapo = true }
            choice(selected: !useCapo, title: "No capo", detail: "The original chord shapes", icon: "guitars") { useCapo = false }
        }
    }

    private func choice(selected: Bool, title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(selected ? Theme.accent : Theme.textDim).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.font(11)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.1) : Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The preview's bars, lit up in time with the audio.
    private func listenCard(_ tr: Transcription, _ song: Song) -> some View {
        let shift = useCapo ? tr.capo : 0
        let current = player.playing ? tr.bars.lastIndex { $0.start <= player.time } : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { if let f = previewFile { player.toggle(f) } } label: {
                    Label(player.playing ? "Stop" : "Listen", systemImage: player.playing ? "stop.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                Text(player.playing ? "Follow the highlighted chord." : "Hear the preview with the chords it found.")
                    .font(Theme.font(12)).foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(tr.bars.count) bars heard").font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(Array(tr.bars.enumerated()), id: \.offset) { i, bar in
                    Text(shifted(bar.tokens, by: -shift))
                        .font(Theme.font(13, .bold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(i == current ? Theme.onAccent : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface2)))
                        .onTapGesture { if let f = previewFile { player.play(f, from: bar.start) } }
                        .accessibilityLabel("Bar \(i + 1): \(shifted(bar.tokens, by: -shift))")
                }
            }
            .animation(.easeOut(duration: 0.12), value: current)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bg.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func shifted(_ tokens: String, by semis: Int) -> String {
        tokens.split(separator: " ").map { tok -> String in
            let parts = tok.split(separator: ":")
            let name = String(parts[0])
            guard semis != 0, let sym = ChordSymbol.parse(name) else { return parts.count > 1 ? "\(name) (½)" : name }
            let n = sym.transposed(by: semis, preferFlat: false).displayName
            return parts.count > 1 ? "\(n) (½)" : n
        }.joined(separator: " ")
    }

    /// A chart is used only when it really fits the recording.
    private var usableChart: ChartMatch? {
        guard let m = chartMatch, m.quality != .poor else { return nil }
        return m
    }

    /// The analysis with the chart's whole-song chords in place, when there's a good chart.
    private func effective(_ tr: Transcription) -> Transcription {
        guard let m = chartMatch, m.quality != .poor else { return tr }
        return ChordCharts.apply(m, to: tr)
    }

    private func builtSong(_ t: CatalogTrack, _ raw: Transcription) -> Song {
        let tr = effective(raw)
        if let m = usableChart {
            return Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: useCapo ? tr.capo : 0,
                                    note: "Whole-song chords from a \(m.chart.source) chord chart by its contributors, lined up with the recording's key and tempo. Check them by ear and tap Edit to fix anything.",
                                    wholeSong: true)
        }
        return Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: useCapo ? tr.capo : 0)
    }

    /// Where the chords came from, and how much to trust them.
    private func sourceCard(_ song: Song) -> some View {
        let m = usableChart
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        if let m {
            icon = "doc.text.magnifyingglass"; tint = m.quality == .high ? Theme.success : Theme.warn
            title = "Whole-song chords from a chord chart"
            detail = "From a \(m.chart.source) chart, matched to this recording (fit: \(m.quality.rawValue)). \(song.sections.count) parts, \(song.durationText), in the recording's key."
                + (m.extended ? " The chart only wrote out part of the song, so its verse and chorus repeat to fill the full length." : "")
        } else if let c = chartMatch {
            icon = "exclamationmark.triangle.fill"; tint = Theme.warn
            title = "Chart didn't match this recording"
            detail = "A \(c.chart.source) chart was found but its chords don't fit what's heard, so it wasn't used. These chords come from the 30-second preview only and may not cover the whole song — check them, or paste a chart."
        } else {
            icon = "exclamationmark.triangle.fill"; tint = Theme.warn
            title = chartLooked ? "No chord chart found" : "Preview only"
            detail = "Chords worked out from the 30-second preview only, so they may not cover the whole song. Check them by ear, or paste a chord chart for the full song."
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let m = chartMatch {
                Button("View Chart") {
                    if let u = URL(string: "https://www.songsterr.com/a/wsa/song-chords-s\(m.chart.songId)") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.35)))
    }

    /// Every section of the song with its chords, as they'll be played.
    private func structureCard(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SONG STRUCTURE").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
            ForEach(Array(song.sections.enumerated()), id: \.offset) { _, sec in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sec.repeats > 1 ? "\(sec.name) ×\(sec.repeats)" : sec.name)
                        .font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
                    Text(sec.tokens(beatsPerBar: song.beatsPerBar).map { $0.beats == Double(song.beatsPerBar) ? $0.chord : "\($0.chord) (\(formatBeats($0.beats)))" }.joined(separator: "  "))
                        .font(Theme.font(13, .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface2))
    }

    // MARK: paste

    private func pasteView(_ t: CatalogTrack?) -> some View {
        let parsed = ChordPro.parse(pasted, fallbackTitle: t?.trackName ?? "My Song")
        return VStack(alignment: .leading, spacing: 16) {
            if let t {
                HStack(spacing: 14) {
                    remoteArt(t.artworkURL, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.trackName).font(Theme.font(16, .bold)).foregroundStyle(Theme.text)
                        Text(t.artistName).font(Theme.font(13)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    if t.previewUrl == nil {
                        Text("No preview available for this song, so it can't be listened to automatically.")
                            .font(Theme.font(11)).foregroundStyle(Theme.textFaint).frame(width: 220)
                    }
                }
            }
            HStack(spacing: 12) {
                Text("1").font(Theme.font(13, .heavy)).foregroundStyle(Theme.onAccent).frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
                Text("Find a chord chart and copy it (⌘A, ⌘C).").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button {
                    SongFinder.openChordSearch(title: t?.trackName ?? query, artist: t?.artistName ?? "")
                } label: { Label("Find Chords on the Web", systemImage: "safari") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 12) {
                Text("2").font(Theme.font(13, .heavy)).foregroundStyle(Theme.onAccent).frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
                Text("Paste it here — lyrics are fine, only the chords are kept.").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { if let s = NSPasteboard.general.string(forType: .string) { pasted = s } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            TextEditor(text: $pasted)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("[Verse]\nG        D         Em      C\nLyrics are ignored…").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textFaint).padding(15).allowsHitTesting(false)
                    }
                }
            HStack {
                if let p = parsed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Text("Found \(p.sections.count) section\(p.sections.count == 1 ? "" : "s") · \(p.uniqueChords.count) chords:")
                        .font(Theme.font(12, .semibold)).foregroundStyle(Theme.text)
                    ForEach(p.uniqueChords.prefix(8), id: \.self) { ChordChip(name: $0, size: 11) }
                } else if !pasted.isEmpty {
                    Label("No chords recognised yet.", systemImage: "questionmark.circle").font(Theme.font(12)).foregroundStyle(Theme.warn)
                }
                Spacer()
                Button("Continue") {
                    guard var s = parsed else { return }
                    if let t { s.title = t.trackName; s.artist = t.artistName; s.genre = t.genre }
                    if let tr = transcription { s.bpm = Int(tr.bpm.rounded()); s.beatsPerBar = tr.beatsPerBar }
                    s.note = nil
                    draft = s
                    phase = .edit
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(parsed == nil)
                .opacity(parsed == nil ? 0.5 : 1)
            }
        }
        .padding(22)
    }

    // MARK: finishing

    private func blankSong() -> Song {
        Song(id: "custom-\(UUID().uuidString.prefix(8))", title: query.isEmpty ? "" : query.capitalized, artist: "", genre: "Pop", bpm: 90,
             sections: [SongSection(name: "Verse", chords: "G D Em C")], isCustom: true)
    }

    private func finish(_ song: Song) {
        player.stop()
        progress.addCustomSong(song)
        if lastTrack != nil { SongMedia.store(art: artFile, preview: previewFile, for: song.id) }
        progress.toast(Toast(title: "Added \(song.title)", subtitle: "It's in your songs — let's play!", icon: "music.note"))
        dismiss()
        app.openSong(song)
    }

    private func importFile() {
        let songs = ChordPro.importWithPanel()
        guard !songs.isEmpty else { return }
        for s in songs { progress.addCustomSong(s) }
        dismiss()
        if let s = songs.first { app.openSong(s) }
    }
}

private struct HoverBackground: View {
    @State private var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover ? Theme.surface2 : Color.clear)
            .onHover { hover = $0 }
    }
}
