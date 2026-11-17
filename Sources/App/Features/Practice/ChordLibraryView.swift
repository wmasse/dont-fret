import SwiftUI

struct ChordLibraryView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
    @State private var query = ""
    @State private var category: ChordCategory? = nil
    @State private var level: Int? = nil
    @State private var selected: ChordShape?

    private var results: [ChordShape] {
        ChordLibrary.shapes.filter { s in
            let sym = s.symbol
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let matchesQ = q.isEmpty || s.name.lowercased().hasPrefix(q) || (sym?.longName.lowercased().contains(q) ?? false)
            return matchesQ && (category == nil || sym?.quality.category == category) && (level == nil || s.level == level)
        }
    }

    var body: some View {
        let res = results
        Page {
            PageHeader(title: "Chord Library", subtitle: "\(ChordLibrary.shapes.count) shapes from first chords to jazz voicings. Each one is rated for difficulty.") {
                Button { app.practice(chords: res.map(\.name)) } label: { Label("Drill \(res.count) chords", systemImage: "target") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(res.isEmpty)
            }
            VStack(alignment: .leading, spacing: 12) {
                SearchField(text: $query, prompt: "Search chords — e.g. Am, F#m7, sus, diminished…")
                HStack(spacing: 8) {
                    Chip(title: "All types", selected: category == nil) { category = nil }
                    ForEach(ChordCategory.allCases) { c in
                        Chip(title: c.rawValue, selected: category == c) { category = category == c ? nil : c }
                    }
                }
                HStack(spacing: 8) {
                    Chip(title: "Any difficulty", selected: level == nil) { level = nil }
                    Chip(title: "Beginner", icon: "leaf.fill", selected: level == 1, tint: Theme.success) { level = level == 1 ? nil : 1 }
                    Chip(title: "Intermediate", icon: "guitars.fill", selected: level == 2, tint: Theme.info) { level = level == 2 ? nil : 2 }
                    Chip(title: "Advanced", icon: "flame.fill", selected: level == 3, tint: Theme.accent2) { level = level == 3 ? nil : 3 }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 14) {
                ForEach(res) { s in
                    Button { selected = s } label: { ChordCard(shape: s, mastery: progress.mastery(s.name)) }
                        .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $selected) { s in
            ChordDetailSheet(shape: s)
                .environment(app)
                .environment(progress)
        }
    }
}

struct ChordCard: View {
    var shape: ChordShape
    var mastery: Int
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(shape.name).font(Theme.font(20, .heavy)).foregroundStyle(Theme.text)
                Spacer()
                Circle().fill(Theme.levelColor(shape.level * 2 - 1)).frame(width: 8, height: 8).help(shape.levelName)
            }
            ChordDiagramView(shape: shape, width: 104)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(i < mastery ? Theme.success : Theme.track).frame(height: 4)
                }
            }
            Text(shape.symbol?.quality.longName.capitalized ?? "")
                .font(Theme.font(11, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? Theme.surface2 : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .scaleEffect(hover && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shape.name), \(shape.symbol?.quality.longName ?? ""). \(shape.levelName). Mastery \(mastery) of 5")
        .accessibilityAddTraits(.isButton)
    }
}

struct ChordDetailSheet: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress
    @Environment(\.dismiss) var dismiss
    var shape: ChordShape

    var body: some View {
        let sym = shape.symbol
        let songs = progress.allSongs.filter { $0.uniqueChords.contains { ChordLibrary.shape(for: $0)?.name == shape.name } }
        let cstat = progress.data.chords[shape.name]
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 14) {
                ChordDiagramView(shape: shape, width: 200)
                Button { GuitarSynth.shared.strum(shape) } label: { Label("Hear it", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shape.name).font(Theme.font(44, .heavy)).foregroundStyle(Theme.text)
                    Text(shape.levelName).font(Theme.font(12, .bold))
                        .foregroundStyle(Theme.levelColor(shape.level * 2 - 1))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.levelColor(shape.level * 2 - 1).opacity(0.15)))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
                }
                Text(sym?.longName.capitalized ?? "").font(Theme.font(16)).foregroundStyle(Theme.textDim)
                if let sym {
                    HStack(spacing: 8) {
                        ForEach(Array(zip(sym.noteNames, sym.quality.intervalNames)), id: \.0) { n, iv in
                            VStack(spacing: 2) {
                                Text(n).font(Theme.font(17, .bold)).foregroundStyle(Theme.text)
                                Text(iv).font(Theme.font(11, .semibold)).foregroundStyle(Theme.accent)
                            }
                            .frame(width: 48, height: 50)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
                        }
                    }
                }
                Text(shape.tips).font(Theme.font(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 20) {
                    stat(label: "Mastery", value: "\(cstat?.mastery ?? 0)/5")
                    stat(label: "Attempts", value: "\(cstat?.attempts ?? 0)")
                    stat(label: "Best time", value: cstat?.bestTime.map { String(format: "%.1fs", $0) } ?? "—")
                }
                Button { dismiss(); app.practice(chords: [shape.name]) } label: { Label("Practice in Chord Trainer", systemImage: "target") }
                    .buttonStyle(PrimaryButtonStyle())
                if !songs.isEmpty {
                    Divider().overlay(Theme.stroke)
                    Text("Songs that use \(shape.name)").font(Theme.font(13, .semibold)).foregroundStyle(Theme.text)
                    FlowLayout(spacing: 8) {
                        ForEach(songs.prefix(10)) { s in
                            Button { dismiss(); app.openSong(s) } label: {
                                Text(s.title).font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.surface2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 720)
        .background(Theme.surface)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.font(18, .bold)).foregroundStyle(Theme.text)
            Text(label).font(Theme.font(11, .medium)).foregroundStyle(Theme.textFaint)
        }
    }
}
