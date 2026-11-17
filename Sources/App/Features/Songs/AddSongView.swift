import SwiftUI
import UniformTypeIdentifiers

/// Search any song → the app listens to its preview and writes the chords → check and add.
struct AddSongView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
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
    @State private var player = PreviewPlayer()
    @State private var chordPlayer = ProgressionPlayer()

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
    /// Chords worked out from the whole song (listened to while it played, or from an audio file).
    @State private var wholeAudio: Transcription?
    @State private var wholeFromFile = false
    @State private var wholeFile: URL?
    @State private var wholeError: String?
    @State private var listener = WholeSongListener()
    /// Time-synced lyrics from LRCLIB (nil: not looked up yet).
    @State private var lyricsFound: Lyrics.Lookup?
    /// Where the analysed recording starts in the full track, when the lyrics could be lined up with it.
    @State private var lyricsOffset: Double?
    /// Which version of the heard chords to build (when there's no chord chart).
    @State private var level: ChordArranger.Level = .advanced
    @State private var levelChosen = false

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
                        .environment(progress)
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
        .onDisappear { player.stop(); chordPlayer.stop(); searchTask?.cancel(); listener.cancel() }
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
        listener.cancel()
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
        transcription = nil; failure = nil; step = 0; chartMatch = nil; chartLooked = false; levelChosen = false
        wholeAudio = nil; wholeFile = nil; wholeError = nil; listener.cancel()
        lyricsFound = nil; lyricsOffset = nil
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
                var result = try await Task.detached(priority: .userInitiated) {
                    try Transcriber.analyze(url: audio) { s in Task { @MainActor in step = 1 + s } }
                }.value
                await MainActor.run { step = 4 }
                // the preview is only 30 s: look for a human-made chart of the whole song and line it up
                let seconds = t.trackTimeMillis.map { Double($0) / 1000 }
                async let lyrics = Lyrics.fetch(title: t.trackName, artist: t.artistName, duration: seconds)
                let chart = await ChordCharts.find(title: t.trackName, artist: t.artistName)
                let match = chart.flatMap { ChordCharts.match($0, to: result, trackSeconds: seconds) }
                let found = await lyrics
                // the sung words: to line the lyrics up by what's sung, or to write them down when
                // there are no lyrics to line up
                var language: String?
                if case .synced(let lines) = found { language = WordListener.language(of: lines) }
                result.heardWords = await WordListener.words(url: audio, language: language, hints: [t.trackName, t.artistName])
                await MainActor.run {
                    transcription = result
                    chartMatch = match
                    chartLooked = true
                    lyricsFound = found
                    lyricsOffset = lyricsStart(in: result, whole: false, t)
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
                    progressRow(ChordCharts.enabled ? "Looking up a chord chart and the lyrics" : "Looking up the lyrics",
                                done: step >= 5, active: step == 4)
                    progressRow("Choosing the easiest way to play it", done: step >= 5, active: false)
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
        reviewBody(t).onAppear { if !levelChosen { level = defaultLevel } }
    }

    private func reviewBody(_ t: CatalogTrack) -> some View {
        Group {
            if let raw = wholeAudio ?? transcription {
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
                            if wholeAudio != nil || usableChart == nil { levelPicker }
                            if wholeAudio == nil && usableChart == nil { wholeSongPanel(t) }
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
                            if MelodyExtractor.enabled, let m = song.melody, !m.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("MELODY HEARD").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                                        Text("\(m.count) notes\(wholeAudio == nil && usableChart == nil ? " · repeats with the preview's chords" : "")")
                                            .font(Theme.font(11)).foregroundStyle(Theme.textDim)
                                    }
                                    MelodyStrip(song: song, melody: m, current: chordPlayer.playing ? chordPlayer.melodyNote : nil, height: 96)
                                }
                            }
                            lyricsCard(song)
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
        // bars line up with the preview, or with the chosen audio file; a listened-to song has nothing to replay
        let audio: URL? = wholeAudio == nil ? previewFile : wholeFile
        let current = player.playing ? tr.bars.lastIndex { $0.start <= player.time } : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if audio != nil {
                    Button { if let f = audio { player.toggle(f) } } label: {
                        Label(player.playing ? "Stop" : "Listen", systemImage: player.playing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Text(audio == nil ? "Every bar heard while the song played." : (player.playing ? "Follow the highlighted chord." : (wholeAudio == nil ? "Hear the preview with the chords it found." : "Hear your audio file with the chords it found.")))
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
                        .onTapGesture { if let f = audio { player.play(f, from: bar.start) } }
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
    /// A good chord chart's whole-song chords as written; otherwise the heard chords, arranged for the chosen version.
    private func effective(_ tr: Transcription) -> Transcription {
        guard wholeAudio == nil, let m = chartMatch, m.quality != .poor else { return ChordArranger.arrange(tr, level: level) }
        return ChordCharts.apply(m, to: tr)
    }

    /// The version that suits the player's level, until they choose one.
    private var defaultLevel: ChordArranger.Level {
        progress.skill.rank <= 1 ? .beginner : (progress.skill.rank <= 2 ? .middle : .advanced)
    }

    /// Beginner, Middle or Advanced: the same heard song, arranged three ways.
    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHOOSE YOUR VERSION").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
            HStack(spacing: 10) {
                ForEach(ChordArranger.Level.allCases) { l in
                    choice(selected: level == l, title: l.rawValue, detail: l.blurb, icon: l.icon) {
                        chordPlayer.stop()
                        level = l
                        levelChosen = true
                        useCapo = true
                    }
                }
            }
        }
    }

    private func builtSong(_ t: CatalogTrack, _ raw: Transcription) -> Song {
        var s = songWithoutLyrics(t, raw)
        let extended = wholeAudio == nil && usableChart == nil
        if case .synced(let lines)? = lyricsFound, let offset = lyricsOffset {
            s.lyrics = Lyrics.place(lines, offset: offset, transcription: effective(raw), song: s, extended: extended)
        }
        // no lyrics that line up: write down what's sung in the recording instead
        if s.lyrics == nil, let heard = Lyrics.heardLines(raw.heardWords) {
            s.lyrics = Lyrics.place(heard, offset: 0, transcription: effective(raw), song: s, extended: extended)
            if s.lyrics != nil { s.lyricsSource = "heard" }
        }
        return s
    }

    private func songWithoutLyrics(_ t: CatalogTrack, _ raw: Transcription) -> Song {
        let tr = effective(raw)
        if wholeAudio != nil {
            return Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: useCapo ? tr.capo : 0,
                                    note: (wholeFromFile ? "\(level.rawValue) version, worked out from the whole song in your audio file. "
                                        : "\(level.rawValue) version, worked out from the whole song as it played on your Mac. ")
                                        + "Check it by ear and tap Edit to fix anything.",
                                    wholeSong: true)
        }
        if let m = usableChart {
            return Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: useCapo ? tr.capo : 0,
                                    note: "Whole-song chords from a \(m.chart.source) chord chart by its contributors, lined up with the recording's key and tempo. Check them by ear and tap Edit to fix anything.",
                                    wholeSong: true)
        }
        return Transcriber.song(from: tr, title: t.trackName, artist: t.artistName, genre: t.genre, capo: useCapo ? tr.capo : 0,
                                note: "\(level.rawValue) version, worked out from the song's 30-second preview. Check it by ear and tap Edit to fix anything.")
    }

    /// The language the found lyrics are in, for picking out the sung words.
    private var lyricsLanguage: String? {
        if case .synced(let lines)? = lyricsFound { return WordListener.language(of: lines) }
        return nil
    }

    /// Where in the full track a recording starts.
    ///
    /// 1. By the sung words (macOS 26+): the speech recogniser's words matched against the lyrics'
    ///    words. If plenty was heard and it isn't in these lyrics, they're for another song or
    ///    version, and none are shown.
    /// 2. Otherwise by when someone seems to be singing, matched against the lyrics' timings.
    /// A whole-song recording that can't be matched is taken to start with the song; a preview that
    /// can't be matched gets no lyrics rather than wrong ones.
    private func lyricsStart(in tr: Transcription, whole: Bool, _ t: CatalogTrack) -> Double? {
        guard case .synced(let lines)? = lyricsFound, let last = lines.last else { return nil }
        let total = t.trackTimeMillis.map { Double($0) / 1000 } ?? last.time + 15
        let range = whole ? -3.0...max(3, total - tr.duration + 3) : 0.0...max(0, total - tr.duration)
        if let w = Lyrics.alignWords(lines, heard: tr.heardWords, recordingSeconds: tr.duration, range: range) {
            if w.trustworthy { return w.offset }
            if w.mismatch { return nil }
            // enough was heard to know the words don't settle it: the voice-timing match is less
            // reliable than that, so only a whole song falls back (to starting with the track)
            if w.heard >= 8 { return whole ? 0 : nil }
        }
        let a = Lyrics.align(lines, heard: tr.heardMelody, recordingSeconds: tr.duration, range: range)
        if let a, a.trustworthy { return a.offset }
        return whole ? 0 : nil
    }

    /// The lyrics, karaoke-style while "Hear Our Version" plays — or why there aren't any.
    @ViewBuilder private func lyricsCard(_ song: Song) -> some View {
        if let lines = song.lyrics, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LYRICS").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    Text("\(lines.filter { !$0.text.isEmpty }.count) lines, lined up with the recording"
                         + (wholeAudio == nil && usableChart == nil ? " · repeat with the preview's chords" : ""))
                        .font(Theme.font(11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(song.lyricsHeard ? "heard in the recording" : "from LRCLIB").font(Theme.font(10)).foregroundStyle(Theme.textFaint)
                }
                if song.lyricsHeard {
                    Label("No lyrics to line up for this song, so these are the words Don't Fret heard sung. Some may be misheard: you can fix them on the song page after adding it.",
                          systemImage: "ear").font(Theme.font(11)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                }
                PlayerKaraoke(player: chordPlayer, lines: lines, size: 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
            }
        } else if let found = lyricsFound {
            let note: String? = {
                switch found {
                case .synced: return wholeAudio == nil
                    ? "Lyrics found, but we couldn't tell which part of the song the preview is. Get the whole song to sing along."
                    : "Lyrics found, but they didn't line up with this recording."
                case .instrumental: return nil
                case .unsynced, .notFound: return "No time-synced lyrics for this song yet, so it's chords only."
                case .failed: return "Couldn't reach the lyrics database, so it's chords only."
                }
            }()
            if let note {
                Label(note, systemImage: "text.bubble").font(Theme.font(12)).foregroundStyle(Theme.textDim)
            }
        }
    }

    /// Where the chords came from, and how much to trust them.
    private func sourceCard(_ song: Song) -> some View {
        let m = usableChart
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        if wholeAudio != nil {
            icon = "waveform"; tint = Theme.success
            title = wholeFromFile ? "Whole-song chords from your audio file" : "Whole-song chords from listening"
            detail = "Worked out from the full recording: \(song.sections.count) part\(song.sections.count == 1 ? "" : "s"), \(song.durationText). Listening by ear can miss quick changes — check them and tap Edit to fix anything."
        } else if let m {
            icon = "doc.text.magnifyingglass"; tint = m.quality == .high ? Theme.success : Theme.warn
            title = "Whole-song chords from a chord chart"
            detail = "From a \(m.chart.source) chart, matched to this recording (fit: \(m.quality.rawValue)). \(song.sections.count) parts, \(song.durationText), in the recording's key."
                + (m.extended ? " The chart only wrote out part of the song, so its verse and chorus repeat to fill the full length." : "")
        } else {
            icon = "waveform.badge.magnifyingglass"; tint = Theme.accent
            title = "Chords from the 30-second preview"
            detail = (!ChordCharts.enabled
                      ? "These chords come from the song's preview."
                      : chartMatch != nil
                      ? "The chord chart we found doesn't fit this recording, so these chords come from the preview."
                      : "There's no ready-made chord chart for this song yet, so these chords come from the preview.")
                + " They're ready to play now, and you can get the whole song in one step below."
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

    // MARK: whole song by ear

    /// Get the whole song when there's no chart: listen while it plays on the Mac, or read an audio file.
    private func wholeSongPanel(_ t: CatalogTrack) -> some View {
        let trackSeconds = t.trackTimeMillis.map { Double($0) / 1000 }
        return VStack(alignment: .leading, spacing: 12) {
            switch listener.stage {
            case .listening:
                HStack(spacing: 12) {
                    Image(systemName: "ear.fill").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Listening… play “\(t.trackName)” on your Mac now").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                        Text(trackSeconds.map { "\(clock(listener.seconds)) of \(clock($0)). Stops by itself when the song ends." } ?? "\(clock(listener.seconds)). Press Done when the song ends.")
                            .font(Theme.font(12)).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { listener.cancel() }.buttonStyle(SecondaryButtonStyle())
                    Button { listener.stop() } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(listener.heardSeconds < 20)
                        .opacity(listener.heardSeconds < 20 ? 0.5 : 1)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule().fill(Theme.accentGradient)
                            .frame(width: g.size.width * CGFloat(min(1, listener.seconds / max(1, trackSeconds ?? 240))))
                    }
                }
                .frame(height: 6)
                HStack(spacing: 3) {
                    ForEach(0..<24, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Float(i) / 24 < listener.level ? Theme.success : Theme.surface2)
                            .frame(width: 8, height: 10)
                    }
                    Text(listener.level > 0.02 ? "Hearing the song" : "Silent").font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint).padding(.leading, 6)
                }
                if listener.seconds > 8 && listener.heardSeconds < 1 {
                    HStack(spacing: 10) {
                        Label("Nothing heard yet. Start the song in Spotify, Music or your browser, with the volume up. If it's playing, Don't Fret may need permission to hear your Mac's sound.", systemImage: "info.circle")
                            .font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Settings") { WholeSongListener.openPrivacySettings() }
                            .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
                    }
                }
            case .analysing:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).frame(width: 24)
                    Text("Working out the chords for the whole song…").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                }
            default:
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "music.note.list").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Get the whole song").font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                        Text("Play it on your Mac in Spotify, Music or YouTube and Don't Fret listens along" + (trackSeconds.map { " (about \(clock($0)))" } ?? "") + ". Or choose an audio file of the song.")
                            .font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Button { startListening(t) } label: { Label("Listen While It Plays", systemImage: "ear") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!WholeSongListener.isSupported)
                    Button { chooseAudioFile(t) } label: { Label("Choose Audio File…", systemImage: "doc.badge.plus") }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
                if case .failed(let msg) = listener.stage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill").font(Theme.font(12)).foregroundStyle(Theme.warn)
                } else if let e = wholeError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(Theme.font(12)).foregroundStyle(Theme.warn)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.3)))
    }

    private func clock(_ s: Double) -> String {
        let n = max(0, Int(s.rounded()))
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    private func startListening(_ t: CatalogTrack) {
        player.stop(); chordPlayer.stop()
        wholeError = nil
        listener.start(songSeconds: t.trackTimeMillis.map { Double($0) / 1000 }, language: lyricsLanguage, hints: [t.trackName, t.artistName]) { result in useWhole(result, fromFile: false, file: nil, t) }
    }

    private func chooseAudioFile(_ t: CatalogTrack) {
        player.stop(); chordPlayer.stop()
        wholeError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file of “\(t.trackName)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let language = lyricsLanguage
        Task {
            do {
                var result = try await Task.detached(priority: .userInitiated) { try Transcriber.analyze(url: url) }.value
                result.heardWords = await WordListener.words(url: url, language: language, hints: [t.trackName, t.artistName])
                await MainActor.run { useWhole(result, fromFile: true, file: url, t) }
            } catch {
                await MainActor.run {
                    wholeError = (error as? TranscribeError) == .unreadable
                        ? "Couldn't read that file. Songs bought or downloaded from streaming apps are often protected — try Listen While It Plays instead."
                        : ((error as? LocalizedError)?.errorDescription ?? "Couldn't work out the chords from that file.")
                }
            }
        }
    }

    private func useWhole(_ result: Transcription, fromFile: Bool, file: URL?, _ t: CatalogTrack) {
        // a few seconds of audio isn't the whole song: keep the preview's chords
        guard result.duration >= 45 else {
            wholeError = "Only \(Int(result.duration)) seconds were heard — play more of the song to get all of it."
            return
        }
        wholeAudio = result
        lyricsOffset = lyricsStart(in: result, whole: true, t)
        wholeFromFile = fromFile
        wholeFile = file
        if transcription == nil { transcription = result }
        if !levelChosen { level = defaultLevel }
        useCapo = true
        if case .review = phase {} else { phase = .review(t) }
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
                        Text("There's no preview to listen to, so play the whole song on your Mac below, or paste its chords.")
                            .font(Theme.font(11)).foregroundStyle(Theme.textFaint).frame(width: 220)
                    }
                }
                if t.previewUrl == nil { wholeSongPanel(t) }
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
