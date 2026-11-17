import SwiftUI

struct RootView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !progress.data.profile.onboarded {
                OnboardingView()
                    .transition(.opacity)
            } else {
                NavigationSplitView {
                    SidebarView()
                        .task { AlbumArt.shared.prefetchAll() }
                        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
                } detail: {
                    DetailView()
                        .background(Theme.bg.ignoresSafeArea())
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar(app.activeGame != nil ? .hidden : .automatic, for: .windowToolbar)

                if let g = app.activeGame {
                    GameContainer(config: g)
                        .id(g.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(10)
                }
            }
        }
        .overlay(alignment: .top) { ToastStack().padding(.top, 18) }
        .animation(.easeInOut(duration: 0.3), value: progress.data.profile.onboarded)
    }
}

struct ToastStack: View {
    @Environment(ProgressStore.self) var progress
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            ForEach(progress.toasts) { t in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.accentGradient)
                        Image(systemName: t.icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(Theme.font(14, .bold)).foregroundStyle(Theme.text)
                        Text(t.subtitle).font(Theme.font(12)).foregroundStyle(Theme.textDim)
                    }
                }
                .padding(.vertical, 10).padding(.leading, 10).padding(.trailing, 18)
                .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.25), radius: 14, y: 6))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.75))
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress.toasts)
        .allowsHitTesting(false)
    }
}

struct Logo: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: 10) {
            // The app icon itself; its artwork fills about 80% of the image, so draw it larger and pull the margins in.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.24, height: size * 1.24)
                .padding(-size * 0.12)
            Text("Don’t Fret")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(Theme.text)
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) var app
    @Environment(ProgressStore.self) var progress

    private var selection: Binding<SidebarItem?> {
        Binding(get: { app.selection }, set: { if let v = $0 { app.selection = v; if v == .songs { app.songPath = [] }; if v == .library { app.libraryPath = [] } } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Play") { row(.home); row(.songs); row(.library); row(.studio) }
            Section("Learn") { row(.riffs); row(.chords); row(.strum); row(.trainer); row(.changes) }
            Section("Tools") { row(.tuner); row(.progress); row(.settings) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack { Logo(size: 26); Spacer() }
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) { levelCard.padding(12) }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title).font(Theme.font(13.5, app.selection == item ? .semibold : .regular))
        } icon: {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(app.selection == item ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.textDim))
                .frame(width: 20)
        }
        .tag(item)
        .padding(.vertical, 3)
    }

    private var levelCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RingView(progress: progress.levelProgress, lineWidth: 4)
                Text("\(progress.level)").font(Theme.font(14, .heavy)).foregroundStyle(Theme.text)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.data.profile.name.isEmpty ? "Guitarist" : progress.data.profile.name)
                    .font(Theme.font(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: progress.skill.icon).font(.system(size: 9))
                    Text("\(progress.skill.title) · Lv \(progress.level)")
                }
                .font(Theme.font(11, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            if progress.streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.accent)
                    Text("\(progress.streak)").font(Theme.font(12, .bold)).foregroundStyle(Theme.text)
                }
            }
        }
        .card(padding: 12, radius: 14, fill: Theme.surface)
    }
}

struct DetailView: View {
    @Environment(AppState.self) var app
    var body: some View {
        Group {
            switch app.selection {
            case .home: HomeView()
            case .songs:
                NavigationStack(path: Bindable(app).songPath) {
                    SongLibraryView()
                        .navigationDestination(for: Song.self) { SongDetailView(song: $0) }
                }
            case .library: MySongsPage()
            case .riffs: RiffLibraryView()
            case .studio: StudioView()
            case .chords: ChordLibraryView()
            case .strum: StrumTrainerView()
            case .trainer: ChordTrainerView()
            case .changes: ChangesView()
            case .tuner: TunerView()
            case .progress: StatsView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standard scrolling page container.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content() }
                .padding(.horizontal, 36)
                .padding(.top, 40)
                .padding(.bottom, 48)
                .frame(maxWidth: 1280, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(ProgressStore.self) var progress
    @Environment(AppState.self) var app
    @State private var themeID = Theme.palette.id
    // Draft lives in AppState so it survives the full re-render a theme change triggers.
    private var step: Int { get { app.obStep } nonmutating set { app.obStep = newValue } }
    private var name: Binding<String> { Bindable(app).obName }
    private var skill: SkillLevel { get { app.obSkill } nonmutating set { app.obSkill = newValue } }
    private var genres: Set<String> { get { app.obGenres } nonmutating set { app.obGenres = newValue } }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // ambient glow
            Circle().fill(Theme.accent.opacity(0.18)).frame(width: 620).blur(radius: 140).offset(x: -320, y: -260)
            Circle().fill(Theme.accent2.opacity(0.14)).frame(width: 560).blur(radius: 140).offset(x: 360, y: 280)

            VStack(spacing: 0) {
                HStack {
                    Logo(size: 30)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule().fill(i <= step ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.track))
                                .frame(width: i == step ? 26 : 10, height: 6)
                        }
                    }
                    .animation(.spring(response: 0.35), value: step)
                }
                .padding(.horizontal, 44).padding(.top, 40)

                Spacer(minLength: 20)
                Group {
                    switch step {
                    case 0: welcome
                    case 1: skillStep
                    case 2: genreStep
                    default: themeStep
                    }
                }
                .frame(maxWidth: 860)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
                Spacer(minLength: 20)

                HStack {
                    if step > 0 {
                        Button("Back") { withAnimation(.spring(response: 0.4)) { step -= 1 } }
                            .buttonStyle(SecondaryButtonStyle(large: true))
                    }
                    Spacer()
                    Button(step == 3 ? "Start Playing" : "Continue") {
                        if step == 3 { finish() } else { withAnimation(.spring(response: 0.4)) { step += 1 } }
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 44).padding(.bottom, 40)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Learn guitar the fun way.")
                .font(Theme.font(52, .heavy)).foregroundStyle(Theme.text)
            Text("Don’t Fret listens to your guitar through your Mac's microphone, checks every chord you play, and turns songs into a game — so practice turns into muscle memory.")
                .font(Theme.font(18)).foregroundStyle(Theme.textDim).frame(maxWidth: 640, alignment: .leading)
            HStack(spacing: 14) {
                feature("waveform", "Hears your chords", "Real-time chord recognition")
                feature("gamecontroller.fill", "Song games", "Scores, streaks & stars")
                feature("arrow.up.arrow.down", "Strum trainer", "Rhythm with live feedback")
                feature("tuningfork", "Built-in tuner", "Uses your Mac's mic")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What should we call you?").font(Theme.font(14, .semibold)).foregroundStyle(Theme.textDim)
                TextField("Your name", text: name)
                    .textFieldStyle(.plain)
                    .font(Theme.font(18, .medium))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.strokeStrong))
                    .frame(maxWidth: 360)
            }
        }
    }

    private func feature(_ icon: String, _ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(t).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
            Text(s).font(Theme.font(12)).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16, radius: 16)
    }

    private var skillStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How well do you play?").font(Theme.font(40, .heavy)).foregroundStyle(Theme.text)
            Text("We'll tailor songs, tempo, chord detection and your learning path. You can change this any time.")
                .font(Theme.font(16)).foregroundStyle(Theme.textDim)
            VStack(spacing: 10) {
                ForEach(SkillLevel.allCases) { s in
                    SkillRow(skill: s, selected: skill == s) { skill = s }
                }
            }
        }
    }

    private var genreStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("What do you like to play?").font(Theme.font(40, .heavy)).foregroundStyle(Theme.text)
            Text("Pick a few — we'll put these songs first in your recommendations.")
                .font(Theme.font(16)).foregroundStyle(Theme.textDim)
            FlowLayout(spacing: 10, lineSpacing: 10) {
                ForEach(Genre.all.filter { $0 != "Custom" && $0 != "Exercise" }, id: \.self) { g in
                    Button {
                        if genres.contains(g) { genres.remove(g) } else { genres.insert(g) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: Genre.icon(g))
                            Text(g)
                        }
                        .font(Theme.font(16, .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .foregroundStyle(genres.contains(g) ? Theme.onAccent : Theme.text)
                        .background(Capsule().fill(genres.contains(g) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface)))
                        .overlay(Capsule().strokeBorder(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var themeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Pick your look.").font(Theme.font(40, .heavy)).foregroundStyle(Theme.text)
            Text("Themes change the whole app. Find more in Settings.")
                .font(Theme.font(16)).foregroundStyle(Theme.textDim)
            ThemeGrid(selected: $themeID) { id in
                var d = progress.data
                d.profile.themeID = id
                progress.data = d
            }
        }
    }

    private func finish() {
        var d = progress.data
        d.profile.name = app.obName.trimmingCharacters(in: .whitespaces)
        d.profile.skill = skill
        d.profile.genres = Array(genres)
        d.profile.themeID = themeID
        d.profile.onboarded = true
        progress.data = d
    }
}

struct SkillRow: View {
    var skill: SkillLevel
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface2))
                    Image(systemName: skill.icon).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? .white : Theme.textDim)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.title).font(Theme.font(17, .bold)).foregroundStyle(Theme.text)
                    Text(skill.blurb).font(Theme.font(13)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                DifficultyBadge(level: skill.songRange.upperBound, compact: true)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Theme.accent : Theme.textFaint)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThemeGrid: View {
    @Binding var selected: String
    var onPick: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            ForEach(Palette.all) { p in
                Button {
                    selected = p.id
                    onPick(p.id)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            Color(hex: p.bg)
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Color(hex: p.bg2)).frame(width: 34)
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.surface)).frame(height: 18)
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.surface2))
                                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.surface2))
                                    }
                                    Capsule().fill(LinearGradient(colors: [Color(hex: p.accent), Color(hex: p.accent2)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: 70, height: 14)
                                }
                            }
                            .padding(10)
                        }
                        .frame(height: 100)
                        HStack {
                            Text(p.name).font(Theme.font(14, .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            if selected == p.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }
                        .padding(12)
                        .background(Theme.surface)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected == p.id ? Theme.accent : Theme.stroke, lineWidth: selected == p.id ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(ProgressStore.self) var progress
    @State private var themeID = Theme.palette.id
    @State private var confirmReset = false

    private func update(_ f: (inout Profile) -> Void) {
        var d = progress.data
        f(&d.profile)
        progress.data = d
    }

    var body: some View {
        Page {
            PageHeader(title: "Settings", subtitle: "Make Don’t Fret fit the way you play.") { EmptyView() }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Your level", subtitle: "Changes recommendations, default tempo, detection strictness and your learning path.")
                VStack(spacing: 10) {
                    ForEach(SkillLevel.allCases) { s in
                        SkillRow(skill: s, selected: progress.skill == s) { update { $0.skill = s } }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Theme")
                ThemeGrid(selected: $themeID) { id in update { $0.themeID = id } }
            }

            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Playing")
                settingRow("Name", "Shown on your home screen.") {
                    TextField("Your name", text: Binding(get: { progress.data.profile.name }, set: { v in update { $0.name = v } }))
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Divider().overlay(Theme.stroke)
                settingRow("Chord detection", progress.strictness.detail) {
                    Segmented(options: ["auto"] + Strictness.allCases.map(\.rawValue),
                              selection: Binding(get: { progress.data.profile.strictness?.rawValue ?? "auto" },
                                                 set: { v in update { $0.strictness = Strictness(rawValue: v) } }),
                              label: { $0 == "auto" ? "Auto" : $0.capitalized })
                }
                Divider().overlay(Theme.stroke)
                settingRow("Daily goal", "Minutes of practice per day.") {
                    Stepper(value: Binding(get: { progress.dailyGoal }, set: { v in update { $0.dailyGoal = v } }), in: 5...120, step: 5) {
                        Text("\(progress.dailyGoal) min").font(Theme.font(14, .semibold)).monospacedDigit()
                    }
                }
                Divider().overlay(Theme.stroke)
                settingRow("Left-handed", "Mirror every chord diagram.") {
                    Toggle("", isOn: Binding(get: { progress.data.profile.leftHanded }, set: { v in update { $0.leftHanded = v } }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            .card(padding: 22)

            MicSettingsCard()
            BackupCard()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start over").font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                    Text("Erase XP, scores, chord mastery and your custom songs.").font(Theme.font(13)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button("Reset Progress…") { confirmReset = true }.buttonStyle(SecondaryButtonStyle())
            }
            .card(padding: 22)
            .alert("Reset all progress?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) {
                    let p = progress.data.profile
                    var fresh = ProgressData()
                    fresh.profile = p
                    progress.data = fresh
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This can't be undone.") }
        }
    }

    private func settingRow<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            control()
        }
    }
}
