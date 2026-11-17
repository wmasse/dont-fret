import SwiftUI
import AppKit

#if !SELFTEST
@main
#endif
struct DontFretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppState()
    @State private var progress = ProgressStore()
    @State private var audio = AudioEngine.shared

    var body: some Scene {
        WindowGroup("Don’t Fret") {
            RootView()
                .environment(app)
                .environment(progress)
                .environment(audio)
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme(Theme.colorScheme)
                .tint(Theme.accent)
                .id(progress.data.profile.themeID)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        GuitarSynth.warmUp()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home, songs, library, studio, riffs, chords, strum, trainer, changes, tuner, progress, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .songs: return "Songs"
        case .library: return "My Songs"
        case .riffs: return "Riffs & Solos"
        case .studio: return "Studio"
        case .chords: return "Chord Library"
        case .strum: return "Strum Trainer"
        case .trainer: return "Chord Trainer"
        case .changes: return "1-Minute Changes"
        case .tuner: return "Tuner & Detector"
        case .progress: return "Progress"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .songs: return "music.note.list"
        case .library: return "heart.fill"
        case .riffs: return "bolt.horizontal.fill"
        case .studio: return "record.circle"
        case .chords: return "square.grid.3x3.fill"
        case .strum: return "arrow.up.arrow.down"
        case .trainer: return "target"
        case .changes: return "arrow.left.arrow.right"
        case .tuner: return "tuningfork"
        case .progress: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

enum PlayMode: String, CaseIterable, Identifiable, Codable {
    case perform, practice, sheet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .perform: return "Play Along"
        case .practice: return "Wait Mode"
        case .sheet: return "Auto-Scroll Sheet"
        }
    }
    var subtitle: String {
        switch self {
        case .perform: return "Hit every change in time. Scored."
        case .practice: return "Song pauses until you play the right chord."
        case .sheet: return "Chord sheet that scrolls with the beat."
        }
    }
    var icon: String {
        switch self {
        case .perform: return "gamecontroller.fill"
        case .practice: return "hourglass"
        case .sheet: return "scroll.fill"
        }
    }
}

enum InputMode: String, CaseIterable, Identifiable, Codable {
    case mic, manual
    var id: String { rawValue }
    var title: String { self == .mic ? "Microphone" : "Tap (Space)" }
    var icon: String { self == .mic ? "mic.fill" : "keyboard" }
}

struct GameConfig: Identifiable, Equatable {
    let id = UUID()
    var song: Song
    var mode: PlayMode
    var tempo: Double
    var input: InputMode
    var metronome: Bool
    var loopSection: Int? = nil
}

@Observable
final class AppState {
    var selection: SidebarItem = .home
    var activeGame: GameConfig?
    var trainerPreset: [String]? = nil
    var strumPreset: String? = nil
    var strumChordPreset: String? = nil
    var changesPreset: (String, String)? = nil
    var songPath: [Song] = []
    var libraryPath: [Song] = []
    var inputMode: InputMode = .mic
    // onboarding draft
    var obStep = 0
    var obName = ""
    var obSkill: SkillLevel = .beginner
    var obGenres: Set<String> = []

    func play(_ song: Song, mode: PlayMode, tempo: Double = 1.0, metronome: Bool = true, loopSection: Int? = nil) {
        withAnimation(.easeOut(duration: 0.25)) {
            activeGame = GameConfig(song: song, mode: mode, tempo: tempo, input: inputMode, metronome: metronome, loopSection: loopSection)
        }
    }

    func openSong(_ song: Song) {
        // a song opened from My Songs stays in My Songs
        if selection == .library { libraryPath = [song]; return }
        selection = .songs
        songPath = [song]
    }

    func practice(chords: [String]) {
        trainerPreset = chords
        selection = .trainer
    }
}
