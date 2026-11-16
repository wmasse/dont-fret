import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var progress: ProgressStore

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        let n = progress.data.profile.name
        return n.isEmpty ? part : "\(part), \(n)"
    }

    private var chordOfDay: ChordShape {
        let pool = ChordLibrary.shapes.filter { $0.level <= min(3, progress.skill.rank + 1) }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return pool[day % max(1, pool.count)]
    }

    var body: some View {
        let recs = progress.recommendedSongs(limit: 10)
        Page {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).font(Theme.font(32, .bold)).foregroundStyle(Theme.text)
                    Text("Tailored for a \(progress.skill.title.lowercased()) player · Level \(progress.level)")
                        .font(Theme.font(15)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button { app.selection = .settings } label: {
                    Label("Change level", systemImage: progress.skill.icon)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    if let next = recs.first { heroCard(next).frame(minWidth: 520) }
                    goalCard.frame(width: 300)
                }
                VStack(spacing: 18) {
                    if let next = recs.first { heroCard(next) }
                    goalCard
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    dailyCard
                    if !progress.dueChords.isEmpty { reviewCard.frame(width: 300) }
                }
                VStack(spacing: 18) {
                    dailyCard
                    if !progress.dueChords.isEmpty { reviewCard }
                }
            }

            pathSection

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Quick practice", subtitle: "Short drills that build muscle memory fast.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    quickTile("Chord Trainer", "Flash chords, play them fast", "target", Theme.accent) { app.selection = .trainer }
                    quickTile("Strum Trainer", "Lock in rhythm patterns", "arrow.up.arrow.down", Theme.info) { app.selection = .strum }
                    quickTile("1-Minute Changes", "Switch between two chords", "arrow.left.arrow.right", Theme.success) { app.selection = .changes }
                    quickTile("Tune Up", "Mic-based tuner", "tuningfork", Theme.violet) { app.selection = .tuner }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Recommended for you", subtitle: "Picked for your level\(progress.data.profile.genres.isEmpty ? "" : " and favourite genres").") {
                    Button("See all") { app.selection = .songs }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.font(13, .semibold))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recs) { s in
                            Button { app.openSong(s) } label: { SongCard(song: s).frame(width: 178) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            chordOfDayCard
        }
    }

    private func heroCard(_ song: Song) -> some View {
        HStack(spacing: 24) {
            ArtworkView(seed: song.id, title: song.title, genre: song.genre, size: 170)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 10) {
                Text("Up next").font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.accent)
                Text(song.title).font(Theme.font(28, .bold)).foregroundStyle(Theme.text).lineLimit(2)
                Text(song.artist).font(Theme.font(15)).foregroundStyle(Theme.textDim)
                HStack(spacing: 8) {
                    DifficultyBadge(level: song.difficulty)
                    Pill(icon: "metronome.fill", text: "\(song.bpm) BPM")
                }
                HStack(spacing: 6) {
                    ForEach(song.uniqueChords.prefix(6), id: \.self) { ChordChip(name: $0, size: 13) }
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    Button {
                        app.play(song, mode: progress.skill.recommendedMode, tempo: progress.skill.defaultTempo)
                    } label: {
                        Label(progress.skill.recommendedMode == .practice ? "Start in Wait Mode" : "Play Now", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    Button("Details") { app.openSong(song) }.buttonStyle(SecondaryButtonStyle(large: true))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var dailyCard: some View {
        let c = progress.dailyChallenge
        let done = progress.dailyDoneToday
        return HStack(spacing: 18) {
            IconTile(icon: done ? "checkmark" : c.icon, tint: done ? Theme.success : Theme.accent, size: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(done ? "Daily challenge · done" : "Daily challenge · +50 XP").font(Theme.font(12.5, .semibold))
                    .foregroundStyle(done ? Theme.success : Theme.accent)
                Text(c.title).font(Theme.font(18, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(done ? "Nice work. A new challenge arrives tomorrow." : c.detail).font(Theme.font(13)).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 8)
            if !done {
                Button { startDaily(c) } label: { Label("Go", systemImage: "arrow.right") }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(done ? Theme.success.opacity(0.5) : Theme.stroke))
        .accessibilityElement(children: .combine)
    }

    private func startDaily(_ c: DailyChallenge) {
        switch c.kind {
        case .song(let id, _): if let s = progress.song(id: id) { app.openSong(s) }
        case .changes(let a, let b, _): app.changesPreset = (a, b); app.selection = .changes
        case .strum(let id, _):
            app.strumPreset = StrumPattern.library.first { $0.id == id }?.pattern
            app.selection = .strum
        case .review: app.selection = .trainer
        }
    }

    private var reviewCard: some View {
        let due = progress.dueChords
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(due.count) chord\(due.count == 1 ? "" : "s") due", systemImage: "clock.arrow.circlepath")
                    .font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            Text("Spaced review keeps chords in your fingers. A quick pass takes a minute.")
                .font(Theme.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(due.prefix(5), id: \.self) { ChordChip(name: $0, size: 12) }
                if due.count > 5 { Text("+\(due.count - 5)").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textFaint) }
            }
            Button { app.practice(chords: Array(due.prefix(12))) } label: { Label("Review now", systemImage: "target") }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var goalCard: some View {
        let goal = Double(progress.dailyGoal)
        let today = progress.todayMinutes
        return VStack(spacing: 16) {
            HStack {
                Text("Today").font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(progress.streak > 0 ? Theme.accent : Theme.textFaint)
                    Text("\(progress.streak) day streak").font(Theme.font(12, .semibold)).foregroundStyle(Theme.textDim)
                }
            }
            ZStack {
                RingView(progress: today / goal, lineWidth: 12)
                VStack(spacing: 0) {
                    Text("\(Int(today))").font(Theme.font(34, .heavy)).foregroundStyle(Theme.text).monospacedDigit()
                    Text("of \(Int(goal)) min").font(Theme.font(12, .medium)).foregroundStyle(Theme.textDim)
                }
            }
            .frame(width: 130, height: 130)
            Text(today >= goal ? "Goal smashed. Keep the streak alive tomorrow!" : "Practice \(max(1, Int((goal - today).rounded(.up)))) more minutes to hit your goal.")
                .font(Theme.font(12)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var pathSection: some View {
        let steps = progress.skill.path
        let done = steps.filter { progress.isComplete($0) }.count
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Your \(progress.skill.title) path", subtitle: "\(done) of \(steps.count) milestones complete") {
                ProgressView(value: Double(done), total: Double(steps.count)).frame(width: 160).tint(Theme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        let complete = progress.isComplete(step)
                        Button { go(step) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    ZStack {
                                        Circle().fill(complete ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.surface3))
                                        if complete { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white) }
                                        else { Text("\(i + 1)").font(Theme.font(12, .bold)).foregroundStyle(Theme.textDim) }
                                    }
                                    .frame(width: 28, height: 28)
                                    Spacer()
                                    Image(systemName: step.icon).foregroundStyle(Theme.textFaint)
                                }
                                Text(step.title).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                                Text(step.detail).font(Theme.font(12)).foregroundStyle(Theme.textDim).lineLimit(3)
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .frame(width: 200, height: 150, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(complete ? Theme.success.opacity(0.4) : Theme.stroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func go(_ step: PathStep) {
        switch step.kind {
        case .chords(let c): app.practice(chords: c)
        case .song(let t): if let s = progress.song(titled: t) { app.openSong(s) }
        case .strum(let id): app.strumPreset = id; app.selection = .strum
        case .tune: app.selection = .tuner
        }
    }

    private func quickTile(_ title: String, _ sub: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                IconTile(icon: icon, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                    Text(sub).font(Theme.font(12)).foregroundStyle(Theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 18, radius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chordOfDayCard: some View {
        let c = chordOfDay
        return HStack(spacing: 28) {
            ChordDiagramView(shape: c, width: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("Chord of the day").font(Theme.font(12.5, .semibold)).foregroundStyle(Theme.accent)
                Text(c.name).font(Theme.font(40, .heavy)).foregroundStyle(Theme.text)
                Text(c.symbol?.longName.capitalized ?? "").font(Theme.font(14)).foregroundStyle(Theme.textDim)
                Text(c.tips).font(Theme.font(13)).foregroundStyle(Theme.textDim).frame(maxWidth: 460, alignment: .leading)
                HStack(spacing: 10) {
                    Button { GuitarSynth.shared.strum(c) } label: { Label("Hear it", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                    Button { app.practice(chords: [c.name]) } label: { Label("Practice it", systemImage: "target") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .card(padding: 24, radius: 22)
    }
}
