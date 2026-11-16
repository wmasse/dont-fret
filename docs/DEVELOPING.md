# Developing Don't Fret

Everything here builds with only the Xcode Command Line Tools (macOS 14+). No Xcode project, no dependencies.

## Build & run

```bash
./build.sh
open "build/Don't Fret.app"
```

To make a downloadable release (universal Apple Silicon + Intel app in a DMG):

```bash
scripts/release.sh 1.1
```

## What's inside

| Area | File |
|---|---|
| App shell, sidebar, onboarding, settings, themes | `Sources/App/DontFretApp.swift`, `RootView.swift`, `Theme.swift` |
| Chord theory, 90+ chord shapes, easy/alt voicings, voicing generator, transposing | `Sources/App/Music.swift` |
| 80+ songs/lessons (chords and single-note riffs), strum patterns, per-section strums | `Sources/App/Songs.swift` |
| ChordPro / plain-text import and export | `Sources/App/ChordPro.swift` |
| Mic chord & note detection, muted-string hints, YIN tuner, strum onsets & direction, input devices | `Sources/App/Audio.swift` |
| Guitar sound: physical string model, acoustic body, electric clean/drive amp, bends/slides/hammer-ons/vibrato | `Sources/App/Synth.swift` |
| Riffs & Solos: 18 riffs, solos, melodies and exercises with TAB, techniques, playback and mic practice | `Sources/App/Riffs.swift` |
| Play Along / Wait Mode / Auto-Scroll sheet, section loops with auto speed-up | `Sources/App/Game.swift` |
| Chord Trainer (spaced review), 1-Minute Changes, Strum Trainer | `Sources/App/Practice.swift` |
| Song library, song page (key & capo, tricky changes, history), song editor | `Sources/App/SongsView.swift` |
| Mic calibration, timing calibration, backup & restore | `Sources/App/Calibration.swift` |
| Tuner, progress, achievements | `Sources/App/TunerView.swift` |
| Progress, XP, skill levels, learning paths, achievements, daily challenge | `Sources/App/Store.swift` |

Progress is saved to `~/Library/Application Support/DontFret/progress.json`. **Settings → Back Up** writes the same data to any file — save it in iCloud Drive to move it between Macs.

Built-in songs use simplified, beginner-friendly progressions and aren't synced to recordings. Use **Edit a Copy** on any song to fix chords for your own version, or import a ChordPro chart.

## Songs and chord charts

**Songs → Add Any Song** (⌘N): search for any song by title or artist. The app finds it in Apple's public music catalog (no account needed), downloads the 30-second preview and album art, and works out the chords automatically:

1. Onset detection and a dynamic-programming beat tracker find the tempo and beats.
2. Beat-by-beat bass and treble pitch profiles go through a chord recognizer that knows the song's key and prefers chord changes on the downbeat.
3. It finds the repeating progression and suggests the capo position that gives the easiest shapes.

You can listen to the preview with the chords lighting up, fix chords in the visual editor, or paste a chord chart from any website instead. Every song page has **Hear the Chords** to play the chords in order at the song's tempo, in its playing style: strummed with the song's pattern, fingerpicked, bass-note-and-strum, palm-muted power chords or reggae chops. For searched songs the strum pattern is detected from the recording.

`Sources/App/Transcriber.swift` (analysis), `SongFinder.swift` (catalog search, media), `AddSongView.swift` (the flow), `ProgressionPlayer.swift` (playback).

You can also build a song chord by chord, import ChordPro `.cho` / plain-text charts, or add a line to `SongCatalog.songs` in `Songs.swift`:

```swift
s("Title", "Artist", "Rock", bpm: 100, strum: "D-DU-UDU", [("Verse", "G D Em C", 2), ("Chorus", "C G D:2 D:2", 1)]),
```

Each chord fills one bar unless you write `Chord:beats` (half beats allowed, e.g. `G:1.5`). Write `~E3` for a single note, and in the editor `Chorus x2 [DUDUDUDU]: C G` sets a section's repeats and strum. Difficulty is rated automatically.

## Riffs & Solos

Each riff is written in a compact TAB shorthand in `RiffLibrary` (`Sources/App/Riffs.swift`):

```
E0+A2:1 E0m E0m E3 | G7h G5p B8b:1 e12~:2 r:1 D7/
```

A token is the string (`E A D G B e`), the fret, an optional technique (`h` hammer-on, `p` pull-off, `/` slide in, `b` bend a whole step, `~` vibrato, `m` palm mute), then an optional `:beats` and `*repeat`. `+` plays notes together, `r` is a rest, `|` is only there to make it readable. **Practice with Mic** turns the riff into a song whose notes carry their TAB position (`~G4@B8`).

## Detection self-test

```bash
swiftc -D SELFTEST -parse-as-library -swift-version 5 -O Sources/App/*.swift Tests/*.swift -o build/selftest && build/selftest
```

The test synthesizes every chord shape and single note and runs them through the recognizer. Current results:
- 97% of beginner chords and 87% of all chords are named correctly from scratch.
- In-game verification accepts 100% of correctly played chords; a wrong chord is accepted 3% of the time.
- Single notes (riffs): 100% accepted with pitch tracking, 0% wrong notes accepted.
- Muted-string hints catch 100% of detectable muted strings with no false alarms.
- Generated voicings, transposing, ChordPro round trip and catalog chords are all checked.

- Automatic chords from a full band mix (10 synthesized songs with guitar, bass, drums and melody): tempo, key and time signature 100%, bars 92%, whole progression 100%.

These numbers come from synthesized sound. A real guitar in a real room will differ, so run **Settings → Microphone & timing → Calibrate** first.
