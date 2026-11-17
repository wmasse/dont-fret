import SwiftUI
import Charts

enum SongSort: String, CaseIterable, Identifiable {
    case forYou = "Best for me", title = "Title", artist = "Artist", easiest = "Easiest first", hardest = "Hardest first", tempo = "Tempo"
    var id: String { rawValue }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font(15))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strokeStrong))
    }
}

struct AddRequest: Identifiable { var id = UUID(); var query: String }

struct SongLibraryView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    @State private var query = ""
    @State private var difficulty: Int? = nil
    @State private var genre: String? = nil
    @State private var sort: SongSort = .forYou
    @State private var knownOnly = false
    @State private var forMe = false
    @State private var addRequest: AddRequest?
    @State private var importMessage: String?

    private var results: [Song] {
        let known = Set(progress.masteredChords)
        let range = progress.skill.songRange
        var list = progress.allSongs.filter { s in
            s.matches(query)
            && (difficulty == nil || s.difficulty == difficulty)
            && (genre == nil || s.genre == genre)
            && (!forMe || range.contains(s.difficulty))
            && (!knownOnly || s.uniqueChords.allSatisfy { known.contains($0) })
        }
        switch sort {
        case .forYou:
            let mid = Double(range.lowerBound + range.upperBound) / 2
            let liked = Set(progress.data.profile.genres)
            list.sort { a, b in
                let da = abs(Double(a.difficulty) - mid) - (liked.contains(a.genre) ? 0.4 : 0)
                let db = abs(Double(b.difficulty) - mid) - (liked.contains(b.genre) ? 0.4 : 0)
                return da == db ? a.title < b.title : da < db
            }
        case .title: list.sort { $0.title < $1.title }
        case .artist: list.sort { $0.artist == $1.artist ? $0.title < $1.title : $0.artist < $1.artist }
        case .easiest: list.sort { $0.difficulty == $1.difficulty ? $0.title < $1.title : $0.difficulty < $1.difficulty }
        case .hardest: list.sort { $0.difficulty == $1.difficulty ? $0.title < $1.title : $0.difficulty > $1.difficulty }
        case .tempo: list.sort { $0.bpm < $1.bpm }
        }
        return list
    }

    var body: some View {
        let res = results
        Page {
            PageHeader(title: "Songs", subtitle: "\(progress.allSongs.count) songs · search by title, artist, genre or chords (try \"Am G\")") {
                Button { addRequest = AddRequest(query: "") } label: { Label("Add Any Song", systemImage: "plus.magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Search any song — the app works out the chords for you")
            }

            VStack(alignment: .leading, spacing: 14) {
                SearchField(text: $query, prompt: "Search songs, artists or chords…")
                HStack(spacing: 8) {
                    Chip(title: "For my level", icon: progress.skill.icon, selected: forMe) { forMe.toggle() }
                    Rectangle().fill(Theme.stroke).frame(width: 1, height: 20).padding(.horizontal, 4)
                    Chip(title: "Any level", selected: difficulty == nil) { difficulty = nil }
                    ForEach(1...5, id: \.self) { d in
                        Chip(title: Difficulty.name(d), selected: difficulty == d, tint: Theme.levelColor(d)) { difficulty = difficulty == d ? nil : d }
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Menu {
                        Button("All genres") { genre = nil }
                        Divider()
                        ForEach(Array(Set(progress.allSongs.map(\.genre))).sorted(), id: \.self) { g in
                            Button(g) { genre = g }
                        }
                    } label: {
                        Label(genre ?? "All genres", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Menu {
                        ForEach(SongSort.allCases) { s in Button(s.rawValue) { sort = s } }
                    } label: {
                        Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Toggle("Only chords I've mastered", isOn: $knownOnly).toggleStyle(.checkbox)
                        .font(Theme.font(13))
                    Spacer()
                    Text("\(res.count) results").font(Theme.font(13, .medium)).foregroundStyle(Theme.textFaint)
                }
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.textDim)
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty && !knownOnly {
                Button { addRequest = AddRequest(query: query) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Theme.accentGradient)
                            Image(systemName: "plus.magnifyingglass").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        }
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(res.isEmpty ? "“\(query)” isn't in your songs yet — add it" : "Looking for a different “\(query)”? Search all music")
                                .font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                            Text("Don't Fret finds the song and works out its chords for you.").font(Theme.font(12)).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textFaint)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if res.isEmpty {
                if knownOnly {
                    EmptyStateView(icon: "music.note.list", title: "No songs found", message: "Master more chords in the Chord Trainer to unlock songs here.")
                        .frame(maxWidth: .infinity)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 230), spacing: 16)], spacing: 16) {
                    ForEach(res) { s in
                        Button { app.songPath.append(s) } label: { SongCard(song: s) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $addRequest) { r in
            AddSongView(initialQuery: r.query)
                .environmentObject(app)
                .environmentObject(progress)
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func importSongs() {
        let songs = ChordPro.importWithPanel()
        for s in songs { progress.addCustomSong(s) }
        if songs.count == 1, let s = songs.first { app.songPath.append(s) }
        else if !songs.isEmpty { importMessage = "Imported \(songs.count) songs." }
        else { importMessage = nil }
    }
}

struct SongDetailView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore
    var song: Song
    @State private var mode: PlayMode = .perform
    @State private var tempo: Double = 1
    @State private var metronome = true
    @State private var editing: Song?
    @State private var confirmDelete = false
    @State private var didInit = false
    @State private var transpose = 0
    @State private var capo = 0
    @StateObject private var hear = ProgressionPlayer()
    @StateObject private var original = PreviewPlayer()

    private var tempos: [Double] {
        var t: [Double] = [0.5, 0.7, 0.85, 1.0]
        if progress.skill.unlocksTempoAbove100 { t += [1.1, 1.25] }
        return t
    }

    private var base: Song { progress.song(id: song.id) ?? song }
    /// The song as the player will actually play it, after transposing and moving the capo.
    private var effective: Song {
        var s = base.transposed(by: base.capo + transpose - capo)
        s.capo = capo
        return s
    }

    var body: some View {
        let s = effective
        Page {
            header(s)
            playCard(s)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    chordsCard(s)
                    VStack(spacing: 18) { keyCard(s); strumCard(s) }.frame(width: 400)
                }
                VStack(spacing: 18) { chordsCard(s); keyCard(s); strumCard(s) }
            }
            tricksCard(s)
            if let r = progress.data.songs[base.id], r.history.count >= 2 { historyCard(r) }
            if let m = s.melody, !m.isEmpty { MelodyCard(player: hear, song: s, tempo: tempo) }
            structureCard(s)
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            mode = progress.skill.recommendedMode
            tempo = progress.skill.defaultTempo
            capo = base.capo
        }
        .sheet(item: $editing) { e in SongEditorView(existing: e).environmentObject(progress) }
        .onDisappear { hear.stop(); original.stop() }
        .onChange(of: app.activeGame?.id) { _, _ in hear.stop(); original.stop() }
        .alert("Delete \"\(base.title)\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { progress.deleteCustomSong(base); app.songPath = [] }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func header(_ s: Song) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(seed: s.id, title: s.title, genre: s.genre, size: 200)
                .background(AmbientArt(seed: s.id, title: s.title, genre: s.genre, opacity: 0.4).frame(width: 520, height: 360).offset(x: 120))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: Genre.icon(s.genre))
                    Text(s.genre)
                    if s.hasRiff { Text("· Riff") }
                }
                .font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.accent)
                Text(s.title).font(Theme.font(34, .bold)).foregroundStyle(Theme.text).lineLimit(2)
                Text(s.artist).font(Theme.font(17, .regular)).foregroundStyle(Theme.textDim)
                FlowLayout(spacing: 8) {
                    DifficultyBadge(level: s.difficulty)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surface2))
                    Pill(icon: "metronome.fill", text: "\(s.bpm) BPM")
                    Pill(icon: "music.note", text: "\(s.beatsPerBar)/4")
                    Pill(icon: "clock.fill", text: s.durationText)
                    if let k = soundingKey(s) { Pill(icon: "key.fill", text: k) }
                    if !s.uniqueChords.isEmpty { Pill(icon: "square.grid.3x3.fill", text: "\(s.uniqueChords.count) chords") }
                    if s.capo > 0 { Pill(icon: "pin.fill", text: "Capo \(s.capo)", tint: Theme.warn) }
                }
                if let r = progress.data.songs[base.id], r.plays > 0 {
                    HStack(spacing: 10) {
                        StarRow(stars: r.stars, size: 14)
                        Text("Best \(r.bestScore.formatted()) · \(Int(r.bestAccuracy * 100))% · \(r.plays) plays")
                            .font(Theme.font(13, .medium)).foregroundStyle(Theme.textDim)
                    }
                }
                if let n = base.note {
                    Text(n).font(Theme.font(12)).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if base.isCustom {
                    Button { editing = base } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(SecondaryButtonStyle())
                    Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button { editing = copyForEditing() } label: { Label("Edit a Copy", systemImage: "square.on.square") }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Make your own editable version — fix chords, change sections or strums")
                }
                Button { ChordPro.exportWithPanel(s) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Save as a ChordPro chord chart")
            }
        }
    }

    private func copyForEditing() -> Song {
        var c = effective
        c.id = "custom-\(UUID().uuidString.prefix(8))"
        c.title = base.title + " (My Version)"
        c.isCustom = true
        c.note = nil
        return c
    }

    private func soundingKey(_ s: Song) -> String? {
        guard let k = s.key, let sym = ChordSymbol.parse(k.components(separatedBy: " ").first ?? "") else { return s.key }
        let sounding = sym.transposed(by: s.capo, preferFlat: Theory.flatKeys.contains((sym.root + s.capo) % 12))
        return "Key of \(sounding.rootName) \(k.hasSuffix("minor") ? "minor" : "major")"
    }

    private func playCard(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ForEach(PlayMode.allCases) { m in modeButton(m) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { playControls; Spacer(minLength: 12); playActions(s) }
                VStack(alignment: .leading, spacing: 14) { playControls; HStack { Spacer(); playActions(s) } }
            }
        }
        .card(padding: 20, radius: 20)
    }

    private var playControls: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TEMPO").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Segmented(options: tempos, selection: $tempo) { "\(Int(($0 * 100).rounded()))%" }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("INPUT").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                InputModePicker(mode: $app.inputMode)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("METRONOME").font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
                Toggle("Click", isOn: $metronome).toggleStyle(.switch).font(Theme.font(13))
            }
        }
        .fixedSize()
    }

    private func playActions(_ s: Song) -> some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(Array(s.sections.enumerated()), id: \.offset) { i, sec in
                    Button("\(sec.name)\(sec.repeats > 1 ? " (×\(sec.repeats))" : "")") {
                        app.play(s, mode: mode == .sheet ? .perform : mode, tempo: tempo, metronome: metronome, loopSection: i)
                    }
                }
            } label: {
                Label("Loop a Section", systemImage: "repeat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Practise one section on repeat. Every clean pass speeds it up by 5%.")
            Button { app.play(s, mode: mode, tempo: tempo, metronome: metronome) } label: {
                Label("Play \(Int(Double(s.bpm) * tempo)) BPM", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .keyboardShortcut(.return, modifiers: [])
            .fixedSize()
        }
    }

    private func modeButton(_ m: PlayMode) -> some View {
        Button { mode = m } label: {
            HStack(spacing: 12) {
                Image(systemName: m.icon).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(mode == m ? Theme.accent : Theme.textDim)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                        if m == progress.skill.recommendedMode {
                            Text("For you").font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent.opacity(0.15)))
                        }
                    }
                    Text(m.subtitle).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(mode == m ? Theme.accent.opacity(0.12) : Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(mode == m ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1.25))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.title). \(m.subtitle)")
        .accessibilityAddTraits(mode == m ? .isSelected : [])
    }

    private func keyCard(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Key & capo", subtitle: soundingKey(s) ?? "Change the key or where you put the capo.")
            HStack(spacing: 14) {
                stepper(title: "TRANSPOSE", value: transpose == 0 ? "Original" : (transpose > 0 ? "+\(transpose)" : "\(transpose)"),
                        minus: { transpose = max(-6, transpose - 1) }, plus: { transpose = min(6, transpose + 1) })
                stepper(title: "CAPO", value: capo == 0 ? "None" : "Fret \(capo)",
                        minus: { capo = max(0, capo - 1) }, plus: { capo = min(9, capo + 1) })
            }
            Text(capo > 0 ? "Put a capo on fret \(capo) and play the shapes shown." : "No capo — play the shapes shown.")
                .font(Theme.font(12)).foregroundStyle(Theme.textDim)
            if transpose != 0 || capo != base.capo {
                Button("Reset to original") { transpose = 0; capo = base.capo }
                    .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 20, radius: 20)
    }

    private func stepper(title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(10, .heavy)).tracking(1.2).foregroundStyle(Theme.textFaint)
            HStack(spacing: 8) {
                Button(action: minus) { Image(systemName: "minus") }.buttonStyle(IconButtonStyle(size: 30)).accessibilityLabel("\(title.capitalized) down")
                Text(value).font(Theme.font(15, .bold)).foregroundStyle(Theme.text).frame(minWidth: 64)
                Button(action: plus) { Image(systemName: "plus") }.buttonStyle(IconButtonStyle(size: 30)).accessibilityLabel("\(title.capitalized) up")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(value)
    }

    private func chordsCard(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: s.uniqueChords.isEmpty ? "Notes in this riff" : "Chords in this song",
                          subtitle: s.uniqueChords.isEmpty ? "Single notes — pick one string at a time." : "Click a chord name for fingerings, or a diagram to hear it.") {
                HStack(spacing: 8) {
                    HearChordsButton(player: hear, song: s, tempo: tempo)
                    if base.isCustom && SongMedia.hasPreview(base.id) {
                        Button { original.toggle(SongMedia.previewURL(base.id)) } label: {
                            Label(original.playing ? "Stop" : "Original", systemImage: original.playing ? "stop.fill" : "music.note")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Hear the 30-second preview of the real recording")
                    }
                    if !s.uniqueChords.isEmpty {
                        Button { app.practice(chords: s.uniqueChords) } label: { Label("Drill these", systemImage: "target") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(s.uniqueChords, id: \.self) { c in chordTile(c) }
                    ForEach(s.uniqueNotes, id: \.self) { n in
                        VStack(spacing: 8) {
                            Text(n).font(Theme.font(16, .bold)).foregroundStyle(Theme.text)
                            if let m = Theory.midi(noteName: n) { NoteTabView(midi: m, width: 150) }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2))
                    }
                }
            }
        }
        .card(padding: 20, radius: 20)
    }

    private func chordTile(_ c: String) -> some View {
        VStack(spacing: 8) {
            ChordChip(name: c, size: 15)
            Button {
                if let sh = ChordLibrary.displayShape(for: c) { GuitarSynth.shared.strum(sh) }
            } label: { ChordDiagram(name: c, width: 92) }
                .buttonStyle(.plain)
                .accessibilityLabel("Hear \(c)")
            masteryDots(progress.mastery(c))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2))
    }

    private func masteryDots(_ m: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(i < m ? Theme.success : Theme.track).frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Mastery \(m) of 5")
    }

    private func strumCard(_ s: Song) -> some View {
        let p = s.strumPattern
        let others = s.sections.filter { $0.strum != nil && $0.strum != s.strum }
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Strumming pattern", subtitle: "\(p.name) · \(p.subdivisionName) · played \(s.feelName.lowercased())")
            StrumPatternView(pattern: p, slotWidth: min(40, 330 / CGFloat(max(1, p.strokes.count))))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(p.tip).font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            ForEach(others, id: \.id) { sec in
                HStack {
                    Text("\(sec.name):").font(Theme.font(12, .semibold)).foregroundStyle(Theme.text)
                    Text(StrumPattern.match(sec.strum!, beatsPerBar: s.beatsPerBar).name).font(Theme.font(12)).foregroundStyle(Theme.textDim)
                    Text(sec.strum!).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textFaint)
                }
            }
            HStack {
                Button {
                    if let sh = ChordLibrary.displayShape(for: s.uniqueChords.first ?? "G") { demo(p, sh, bpm: s.bpm) }
                } label: { Label("Hear it", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(SecondaryButtonStyle())
                Button {
                    app.strumPreset = p.pattern
                    app.strumChordPreset = s.uniqueChords.first
                    app.selection = .strum
                } label: { Label("Practice strum", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .card(padding: 20, radius: 20)
    }

    private func demo(_ p: StrumPattern, _ shape: ChordShape, bpm: Int) {
        let slotDur = 60.0 / Double(bpm) / Double(p.slotsPerBeat)
        for (i, st) in p.strokes.enumerated() where st.isStrum {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * slotDur) { GuitarSynth.shared.strum(shape, stroke: st) }
        }
    }

    /// The hardest chord changes in the song, with a tip for each.
    private func trickyChanges(_ s: Song) -> [(String, String, String)] {
        var seen = Set<String>()
        var pairs: [(String, String, Int)] = []
        let ev = s.events.filter { !$0.isNote }
        for i in 1..<max(1, ev.count) where ev[i].chord != ev[i - 1].chord {
            let key = ev[i - 1].chord + ">" + ev[i].chord
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let cost = ChordLibrary.level(of: ev[i - 1].chord) + ChordLibrary.level(of: ev[i].chord) - progress.mastery(ev[i].chord) / 2
            pairs.append((ev[i - 1].chord, ev[i].chord, cost))
        }
        return pairs.sorted { $0.2 > $1.2 }.prefix(4).compactMap { p in
            ChordLibrary.transitionTip(from: p.0, to: p.1).map { (p.0, p.1, $0) }
        }
    }

    @ViewBuilder private func tricksCard(_ s: Song) -> some View {
        let tricks = trickyChanges(s)
        if !tricks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Tricky changes", subtitle: "How to move between the hardest chord pairs in this song.")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { ForEach(tricks.indices, id: \.self) { i in trickTile(tricks[i]) } }
                    VStack(spacing: 12) { ForEach(tricks.indices, id: \.self) { i in trickTile(tricks[i]) } }
                }
            }
            .card(padding: 20, radius: 20)
        }
    }

    private func trickTile(_ t: (String, String, String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ChordChip(name: t.0, size: 13)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textFaint)
                ChordChip(name: t.1, size: 13)
                Spacer(minLength: 8)
                Button { app.changesPreset = (t.0, t.1); app.selection = .changes } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help("Drill this change in 1-Minute Changes")
                    .accessibilityLabel("Drill \(t.0) to \(t.1)")
            }
            Text(t.2).font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface2))
    }

    private func historyCard(_ r: SongRecord) -> some View {
        let pts = Array(r.history.suffix(30).enumerated())
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your progress on this song", subtitle: "Accuracy for your last \(pts.count) plays")
            Chart {
                ForEach(pts, id: \.offset) { i, a in
                    LineMark(x: .value("Play", i + 1), y: .value("Accuracy", a.accuracy * 100))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Play", i + 1), y: .value("Accuracy", a.accuracy * 100))
                        .foregroundStyle(a.mode == PlayMode.practice.rawValue ? Theme.info : Theme.accent)
                        .symbolSize(40)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: 1...max(2, pts.count))
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }.foregroundStyle(Theme.textFaint) } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.textFaint) } }
            .frame(height: 160)
            .accessibilityLabel("Accuracy history chart")
            HStack(spacing: 14) {
                Label("Play Along", systemImage: "circle.fill").foregroundStyle(Theme.accent)
                Label("Wait Mode", systemImage: "circle.fill").foregroundStyle(Theme.info)
            }
            .font(Theme.font(11, .medium))
        }
        .card(padding: 20, radius: 20)
    }

    private func structureCard(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Song structure", subtitle: "Every chord is clickable. Press ▶ to hear a section, or Loop to drill it.") {
                HearChordsButton(player: hear, song: s, tempo: tempo, label: "Hear Whole Song")
            }
            ForEach(Array(s.sections.enumerated()), id: \.offset) { i, sec in
                sectionRow(s, i, sec)
            }
        }
        .card(padding: 20, radius: 20)
    }

    private func sectionRow(_ s: Song, _ i: Int, _ sec: SongSection) -> some View {
        let toks = sec.tokens(beatsPerBar: s.beatsPerBar)
        let full = Double(s.beatsPerBar)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sec.name).font(Theme.font(14, .bold)).foregroundStyle(Theme.text)
                if sec.repeats > 1 { Text("× \(sec.repeats)").font(Theme.font(12, .semibold)).foregroundStyle(Theme.accent) }
                if let st = sec.strum { Text(st).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textFaint) }
                HStack(spacing: 10) {
                    Button {
                        let start = ProgressionPlayer.positions(s).firstIndex { $0.section == i } ?? 0
                        hear.play(s, tempo: tempo, from: start)
                    } label: {
                        Label("Hear", systemImage: "play.fill").font(Theme.font(11, .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("Hear this section's chords from here on")
                    Button { app.play(s, mode: mode == .sheet ? .perform : mode, tempo: tempo, metronome: metronome, loopSection: i) } label: {
                        Label("Loop", systemImage: "repeat").font(Theme.font(11, .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 120, alignment: .leading)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Array(toks.enumerated()), id: \.offset) { ti, t in
                    let live = hear.position.map { $0.section == i && $0.token == ti } ?? false
                    HStack(spacing: 3) {
                        if t.chord.hasPrefix("~") {
                            Text(String(t.chord.dropFirst())).font(Theme.font(14, .bold)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(live ? Theme.accent.opacity(0.4) : Theme.surface2))
                        } else {
                            ChordChip(name: t.chord, size: 14, highlighted: live)
                        }
                        if t.beats != full {
                            Text("\(formatBeats(t.beats))♩").font(Theme.font(10, .semibold)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Song editor (visual chord builder)

struct EditChord: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var beats: Double
}

struct EditSection: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var repeats = 1
    var strum: String? = nil
    var chords: [EditChord] = []
}

struct SongEditorView: View {
    @EnvironmentObject var progress: ProgressStore
    @Environment(\.dismiss) var dismiss
    var existing: Song?
    /// Inside another sheet: report back instead of saving and dismissing.
    var embedded = false
    var onDone: ((Song?) -> Void)? = nil

    @State private var title = ""
    @State private var artist = ""
    @State private var genre = "Pop"
    @State private var bpm = 90
    @State private var beats = 4
    @State private var capo = 0
    @State private var strumID = "campfire"
    @State private var feel = ""
    @State private var parts: [EditSection] = [EditSection(name: "Verse")]
    @State private var textMode = false
    @State private var text = ""
    @State private var taps: [Date] = []
    @StateObject private var player = ProgressionPlayer()
    @State private var loaded = false

    /// One section per line: `Name xN [STRUM]: chords…` (used by "Type it instead").
    static func parseSections(_ text: String) -> [SongSection] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { return nil }
            var name = "Part"
            var chords = l
            if let colon = l.firstIndex(of: ":") {
                let head = String(l[l.startIndex..<colon])
                if ChordSymbol.parse(head) == nil && !head.hasPrefix("~") {
                    name = head
                    chords = String(l[l.index(after: colon)...])
                }
            }
            var strum: String? = nil
            if let open = name.firstIndex(of: "["), let close = name.firstIndex(of: "]"), open < close {
                let p = String(name[name.index(after: open)..<close]).uppercased().replacingOccurrences(of: "X", with: "x")
                if !p.isEmpty && p.allSatisfy({ "DU-x".contains($0) }) { strum = p }
                name.removeSubrange(open...close)
                name = name.trimmingCharacters(in: .whitespaces)
            }
            var repeats = 1
            let words = name.split(separator: " ")
            if let last = words.last, last.lowercased().hasPrefix("x"), let r = Int(last.dropFirst()) {
                repeats = r
                name = words.dropLast().joined(separator: " ")
            }
            return SongSection(name: name.isEmpty ? "Part" : name, chords: chords.trimmingCharacters(in: .whitespaces), repeats: max(1, repeats), strum: strum)
        }
    }

    private static func toText(_ parts: [EditSection], beats: Int) -> String {
        parts.map { p in
            var head = p.name
            if p.repeats > 1 { head += " x\(p.repeats)" }
            if let st = p.strum { head += " [\(st)]" }
            return "\(head): " + p.chords.map { token($0, beats: beats) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func token(_ c: EditChord, beats: Int) -> String {
        c.beats == Double(beats) ? c.name : "\(c.name):\(formatBeats(c.beats))"
    }

    private static func fromSections(_ secs: [SongSection], beats: Int) -> [EditSection] {
        secs.map { s in
            EditSection(name: s.name, repeats: s.repeats, strum: s.strum,
                        chords: s.tokens(beatsPerBar: beats).map { EditChord(name: $0.chord, beats: $0.beats) })
        }
    }

    private var sections: [SongSection] {
        if textMode { return Self.parseSections(text) }
        return parts.filter { !$0.chords.isEmpty }.map { p in
            SongSection(name: p.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Part" : p.name,
                        chords: p.chords.map { Self.token($0, beats: beats) }.joined(separator: " "),
                        repeats: p.repeats, strum: p.strum)
        }
    }

    private var unknown: [String] {
        var out: [String] = []
        for sec in sections {
            for t in sec.tokens(beatsPerBar: beats) where !out.contains(t.chord) {
                let ok = t.chord.hasPrefix("~") ? Theory.midi(noteName: String(t.chord.dropFirst())) != nil : ChordSymbol.parse(t.chord) != nil
                if !ok { out.append(t.chord) }
            }
        }
        return out
    }
    @State private var customStrum: String?
    private var pattern: String {
        if strumID == "detected", let c = customStrum { return c }
        return StrumPattern.library.first { $0.id == strumID }?.pattern ?? (beats == 3 ? "D-DUDU" : "D-DU-UDU")
    }
    private var usedChords: [String] {
        var seen: [String] = []
        for p in parts { for c in p.chords where !seen.contains(c.name) && !c.name.hasPrefix("~") { seen.append(c.name) } }
        return seen
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !sections.isEmpty && unknown.isEmpty }
    private var preview: Song {
        Song(id: existing?.id ?? "preview", title: title, artist: artist, genre: genre, bpm: bpm, beatsPerBar: beats, capo: capo, strum: pattern, sections: sections,
             feel: feel.isEmpty ? nil : feel, melody: existing?.melody)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack {
                    Text(existing == nil ? "New Song" : "Edit Song").font(Theme.font(22, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    details
                    sectionsArea
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 700)
        .background(Theme.surface)
        .onAppear(perform: load)
        .onDisappear { stopPlay() }
        .onChange(of: beats) { old, nb in
            if StrumPattern.library.first(where: { $0.id == strumID })?.beatsPerBar != nb {
                strumID = StrumPattern.library.first { $0.beatsPerBar == nb }?.id ?? strumID
            }
            // whole-bar chords stay whole bars
            for i in parts.indices { for j in parts[i].chords.indices where parts[i].chords[j].beats == Double(old) { parts[i].chords[j].beats = Double(nb) } }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let e = existing else { return }
        title = e.title; artist = e.artist == "Me" ? "" : e.artist; genre = e.genre; bpm = e.bpm; beats = e.beatsPerBar; capo = e.capo
        strumID = StrumPattern.library.first { $0.pattern == e.strum }?.id ?? (e.beatsPerBar == 3 ? "waltz" : "campfire")
        customStrum = StrumPattern.library.contains { $0.pattern == e.strum } ? nil : e.strum
        if customStrum != nil { strumID = "detected" }
        feel = e.feel ?? ""
        parts = Self.fromSections(e.sections, beats: e.beatsPerBar)
        if parts.isEmpty { parts = [EditSection(name: "Verse")] }
    }

    // MARK: details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                field("Song title") { TextField("e.g. Wonderwall", text: $title).textFieldStyle(.roundedBorder) }
                field("Artist") { TextField("Optional", text: $artist).textFieldStyle(.roundedBorder) }
            }
            HStack(alignment: .bottom, spacing: 18) {
                field("Tempo") {
                    HStack(spacing: 8) {
                        Stepper("\(bpm) BPM", value: $bpm, in: 40...220, step: 1).font(Theme.font(13, .semibold)).monospacedDigit()
                        Button { tap() } label: { Label("Tap", systemImage: "hand.tap.fill") }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Tap along to the song 4 or more times to set the tempo")
                    }
                }
                field("Beats per bar") {
                    Picker("", selection: $beats) { Text("4").tag(4); Text("3").tag(3) }.labelsHidden().pickerStyle(.segmented).frame(width: 90)
                }
                field("Capo") { Stepper(capo == 0 ? "None" : "Fret \(capo)", value: $capo, in: 0...9).font(Theme.font(13, .semibold)) }
                field("Genre") { Picker("", selection: $genre) { ForEach(Genre.all, id: \.self) { Text($0) } }.labelsHidden().frame(width: 120) }
            }
            HStack(alignment: .bottom, spacing: 18) {
                field("Strumming pattern") {
                    Picker("", selection: $strumID) {
                        if let c = customStrum { Text("From the recording   \(c)").tag("detected") }
                        ForEach(StrumPattern.library.filter { $0.beatsPerBar == beats }) { p in Text("\(p.name)   \(p.pattern)").tag(p.id) }
                    }
                    .labelsHidden().frame(maxWidth: 340)
                }
                field("Style") {
                    Picker("", selection: $feel) {
                        Text("Automatic").tag("")
                        ForEach(Song.feelNames, id: \.0) { f in Text(f.1).tag(f.0) }
                    }
                    .labelsHidden().frame(width: 190)
                    .help("How “Hear it” plays the chords")
                }
            }
        }
    }

    private func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now)
        GuitarSynth.shared.click(accent: taps.count % beats == 1)
        guard taps.count >= 3 else { return }
        let recent = Array(taps.suffix(8))
        let gaps = zip(recent.dropFirst(), recent).map { $0.timeIntervalSince($1) }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        if avg > 0 { bpm = max(40, min(220, Int((60 / avg).rounded()))) }
    }

    // MARK: sections

    private var sectionsArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chords").font(Theme.font(16, .bold)).foregroundStyle(Theme.text)
                    Text(textMode ? "One section per line. G:2 = 2 beats · x2 repeats · [DUDU] sets a strum · ~E3 is a single note."
                                  : "Each box is one bar. Click a chord to change it, or + to add one.")
                        .font(Theme.font(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Toggle("Type it instead", isOn: Binding(get: { textMode }, set: { on in
                    if on { text = Self.toText(parts, beats: beats) } else { parts = Self.fromSections(Self.parseSections(text), beats: beats); if parts.isEmpty { parts = [EditSection(name: "Verse")] } }
                    textMode = on
                }))
                .toggleStyle(.switch).font(Theme.font(12))
            }
            if textMode {
                TextEditor(text: $text)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
            } else {
                ForEach($parts) { $p in
                    SectionEditorCard(section: $p, beatsPerBar: beats, used: usedChords, activeChord: activeChordID,
                                      isFirst: parts.first?.id == p.id, isLast: parts.last?.id == p.id,
                                      onMove: { dir in move(p.id, dir) },
                                      onDuplicate: { duplicate(p.id) },
                                      onDelete: { parts.removeAll { $0.id == p.id }; if parts.isEmpty { parts = [EditSection(name: "Verse")] } })
                }
                Menu {
                    ForEach(["Verse", "Chorus", "Pre-Chorus", "Bridge", "Intro", "Outro", "Solo"], id: \.self) { n in
                        Button(n) { addSection(n) }
                    }
                } label: {
                    Label("Add Section", systemImage: "plus.rectangle.on.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.top, 2)
            }
            if !unknown.isEmpty {
                Label("Not recognised: \(unknown.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(12, .medium)).foregroundStyle(Theme.danger)
            }
        }
    }

    /// The chord tile that's sounding while "Hear it" plays.
    private var activeChordID: UUID? {
        guard let pos = player.position else { return nil }
        let filled = parts.filter { !$0.chords.isEmpty }
        guard filled.indices.contains(pos.section), filled[pos.section].chords.indices.contains(pos.token) else { return nil }
        return filled[pos.section].chords[pos.token].id
    }

    private func addSection(_ name: String) {
        let count = parts.filter { $0.name.hasPrefix(name) }.count
        // a repeated section name usually means the same chords (second verse, etc.)
        if let same = parts.last(where: { $0.name == name }) {
            var copy = same; copy.id = UUID(); copy.chords = same.chords.map { EditChord(name: $0.name, beats: $0.beats) }
            parts.append(copy)
        } else {
            parts.append(EditSection(name: count > 0 ? "\(name) \(count + 1)" : name))
        }
    }

    private func duplicate(_ id: UUID) {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return }
        var c = parts[i]; c.id = UUID(); c.chords = c.chords.map { EditChord(name: $0.name, beats: $0.beats) }
        parts.insert(c, at: i + 1)
    }

    private func move(_ id: UUID, _ dir: Int) {
        guard let i = parts.firstIndex(where: { $0.id == id }), parts.indices.contains(i + dir) else { return }
        parts.swapAt(i, i + dir)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !sections.isEmpty {
                DifficultyBadge(level: preview.difficulty)
                Text("· \(preview.durationText)").font(Theme.font(12)).foregroundStyle(Theme.textDim)
                HearChordsButton(player: player, song: preview, label: "Hear it")
            }
            Spacer()
            Button("Cancel") { stopPlay(); if let onDone { onDone(nil) } else { dismiss() } }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(embedded ? nil : .cancelAction)
            Button(embedded ? "Add to My Songs" : "Save Song") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
                .help(canSave ? "" : (title.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the song a title" : "Add some chords"))
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func stopPlay() { player.stop() }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
            c()
        }
    }

    private func save() {
        stopPlay()
        let id = existing?.id ?? "custom-\(UUID().uuidString.prefix(8))"
        let song = Song(id: id, title: title.trimmingCharacters(in: .whitespaces),
                        artist: artist.trimmingCharacters(in: .whitespaces).isEmpty ? "Me" : artist.trimmingCharacters(in: .whitespaces),
                        genre: genre, bpm: bpm, beatsPerBar: beats, capo: capo, strum: pattern,
                        sections: sections, isCustom: true, note: existing?.note, feel: feel.isEmpty ? nil : feel,
                        melody: existing?.melody)
        if let onDone { onDone(song) } else { progress.addCustomSong(song); dismiss() }
    }
}

/// One section: name, repeats, strum, and its bars as clickable chord tiles.
struct SectionEditorCard: View {
    @Binding var section: EditSection
    var beatsPerBar: Int
    var used: [String]
    var activeChord: UUID? = nil
    var isFirst: Bool
    var isLast: Bool
    var onMove: (Int) -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    @State private var adding = false
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Section name", text: $section.name)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15, .bold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: 200)
                Spacer()
                HStack(spacing: 6) {
                    Text("Play").font(Theme.font(12)).foregroundStyle(Theme.textDim)
                    Button { section.repeats = max(1, section.repeats - 1) } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle(size: 24)).accessibilityLabel("Fewer repeats")
                    Text("×\(section.repeats)").font(Theme.font(13, .bold)).foregroundStyle(Theme.text).frame(minWidth: 26).monospacedDigit()
                    Button { section.repeats = min(16, section.repeats + 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle(size: 24)).accessibilityLabel("More repeats")
                }
                Menu {
                    Button("Use the song's pattern") { section.strum = nil }
                    Divider()
                    ForEach(StrumPattern.library.filter { $0.beatsPerBar == beatsPerBar }) { p in
                        Button("\(p.name)  \(p.pattern)") { section.strum = p.pattern }
                    }
                } label: {
                    Label(section.strum.map { StrumPattern.match($0, beatsPerBar: beatsPerBar).name } ?? "Song's strum", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(Theme.font(12))
                Menu {
                    Button("Duplicate", action: onDuplicate)
                    Button("Move Up") { onMove(-1) }.disabled(isFirst)
                    Button("Move Down") { onMove(1) }.disabled(isLast)
                    Divider()
                    Button("Delete Section", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Section options")
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach($section.chords) { $c in
                    chordTile(c)
                        .popover(isPresented: Binding(get: { editingID == c.id }, set: { if !$0 { editingID = nil } }), arrowEdge: .bottom) {
                            ChordPickerView(current: c.name, beats: $c.beats, beatsPerBar: beatsPerBar, used: used,
                                            onPick: { name in c.name = name },
                                            onMove: { dir in moveChord(c.id, dir) },
                                            onDelete: { editingID = nil; section.chords.removeAll { $0.id == c.id } },
                                            onDone: { editingID = nil })
                        }
                }
                Button { adding = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                        Text(section.chords.isEmpty ? "Add chord" : "Add").font(Theme.font(10, .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(width: section.chords.isEmpty ? 90 : 62, height: 58)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a chord to \(section.name)")
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    ChordPickerView(current: nil, beats: .constant(Double(beatsPerBar)), beatsPerBar: beatsPerBar, used: used,
                                    onPick: { name in section.chords.append(EditChord(name: name, beats: Double(beatsPerBar))) },
                                    onMove: nil, onDelete: nil, onDone: { adding = false })
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func chordTile(_ c: EditChord) -> some View {
        let full = Double(beatsPerBar)
        let known = c.name.hasPrefix("~") ? Theory.midi(noteName: String(c.name.dropFirst())) != nil : ChordSymbol.parse(c.name) != nil
        return Button { editingID = c.id } label: {
            VStack(spacing: 3) {
                Text(c.name.hasPrefix("~") ? String(c.name.dropFirst()) : c.name)
                    .font(Theme.font(17, .heavy)).lineLimit(1).fixedSize()
                    .foregroundStyle(known ? Theme.text : Theme.danger)
                Text(c.beats == full ? "1 bar" : (c.beats == full * 2 ? "2 bars" : (c.beats == full / 2 ? "½ bar" : "\(formatBeats(c.beats)) beats")))
                    .font(Theme.font(10, .medium)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: c.beats < full ? 54 : 70, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(activeChord == c.id ? Theme.accent.opacity(0.35) : (editingID == c.id ? Theme.accent.opacity(0.18) : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(editingID == c.id || activeChord == c.id ? Theme.accent : Theme.strokeStrong, lineWidth: activeChord == c.id ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.name), \(formatBeats(c.beats)) beats. Edit")
    }

    private func moveChord(_ id: UUID, _ dir: Int) {
        guard let i = section.chords.firstIndex(where: { $0.id == id }), section.chords.indices.contains(i + dir) else { return }
        section.chords.swapAt(i, i + dir)
    }
}

/// Pick a chord by tapping: ones already in the song, common chords, or any root + type.
struct ChordPickerView: View {
    var current: String?
    @Binding var beats: Double
    var beatsPerBar: Int
    var used: [String]
    var onPick: (String) -> Void
    var onMove: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    var onDone: () -> Void

    @State private var typed = ""
    @State private var root = 7
    @State private var flat = false

    static let common = ["G", "C", "D", "Em", "Am", "E", "A", "Dm", "F", "Bm", "B7", "E7", "A7", "D7", "G7", "Cadd9", "Dsus4", "Asus2"]
    static let qualities: [(String, String)] = [("", "major"), ("m", "minor"), ("7", "7"), ("maj7", "maj7"), ("m7", "m7"), ("sus2", "sus2"), ("sus4", "sus4"), ("add9", "add9"), ("5", "power"), ("dim", "dim")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if current != nil {
                HStack(spacing: 8) {
                    Text("Length").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textDim)
                    Segmented(options: lengths, selection: $beats) { b in
                        b == Double(beatsPerBar) ? "1 bar" : (b == Double(beatsPerBar) * 2 ? "2 bars" : (b == Double(beatsPerBar) / 2 ? "½ bar" : "\(formatBeats(b)) beats"))
                    }
                    Spacer()
                    if let onMove {
                        Button { onMove(-1) } label: { Image(systemName: "arrow.left") }.buttonStyle(IconButtonStyle(size: 26)).accessibilityLabel("Move earlier")
                        Button { onMove(1) } label: { Image(systemName: "arrow.right") }.buttonStyle(IconButtonStyle(size: 26)).accessibilityLabel("Move later")
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(IconButtonStyle(size: 26)).accessibilityLabel("Remove chord")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Type any chord, e.g. F#m7", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTyped() }
                Button(current == nil ? "Add" : "Use") { addTyped() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(ChordSymbol.parse(typed.trimmingCharacters(in: .whitespaces)) == nil)
            }
            if !used.isEmpty {
                group("In this song") { grid(used) }
            }
            group("Common chords") { grid(Self.common) }
            group("Any chord") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<12, id: \.self) { pc in
                            Button { root = pc } label: {
                                Text(Theory.name(pc, flat: Theory.flatKeys.contains(pc) && pc != 6 && pc != 1))
                                    .font(Theme.font(11, .bold)).frame(width: 30, height: 26)
                                    .foregroundStyle(root == pc ? Theme.onAccent : Theme.text)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(root == pc ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface2)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    let rootName = Theory.name(root, flat: Theory.flatKeys.contains(root) && root != 6 && root != 1)
                    grid(Self.qualities.map { rootName + $0.0 })
                }
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(Theme.surface)
        .preferredColorScheme(Theme.colorScheme)
    }

    private var lengths: [Double] {
        let b = Double(beatsPerBar)
        return beatsPerBar == 4 ? [1, 2, 4, 8] : [1, 3, 6]
            .map { $0 }
            .filter { $0 <= b * 2 }
    }

    private func addTyped() {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard let sym = ChordSymbol.parse(t) else { return }
        pick(sym.displayName)
        typed = ""
    }

    private func pick(_ name: String) {
        onPick(name)
        GuitarSynth.shared.strum(ChordLibrary.displayShape(for: name) ?? ChordLibrary.shapes[0], ring: 1.2)
        if current != nil { onDone() }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.font(9, .heavy)).tracking(1.1).foregroundStyle(Theme.textFaint)
            c()
        }
    }

    private func grid(_ names: [String]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(names, id: \.self) { n in
                Button { pick(n) } label: {
                    Text(n).font(Theme.font(13, .bold)).lineLimit(1).fixedSize()
                        .foregroundStyle(n == current ? Theme.onAccent : Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(n == current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface2)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .help(ChordLibrary.shape(for: n) == nil ? "No diagram for this one yet" : "")
            }
        }
    }
}
