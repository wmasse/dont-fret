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

The app icon is drawn by `scripts/make_icon.swift`. To change it, edit that script, then rebuild `Resources/AppIcon.icns` and `docs/icon.png`:

```bash
mkdir -p /tmp/AppIcon.iconset && swift scripts/make_icon.swift /tmp/icon.png
for s in 16 32 128 256 512; do sips -z $s $s /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}.png; sips -z $((s*2)) $((s*2)) /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${s}x${s}@2x.png; done
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns && sips -z 512 512 /tmp/icon.png --out docs/icon.png
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
| Studio: takes store, audio/video recorder, live mixer with effects, offline mixdown, video export | `Sources/App/StudioEngine.swift` |
| Studio pages: record panel, takes, editor with trim/layers/sound/export | `Sources/App/StudioView.swift` |
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

You can listen to the preview with the chords lighting up, fix chords in the visual editor, or paste a chord chart from any website instead. Every song page has **Hear the Chords** to play the chords in order at the song's tempo, in its playing style: strummed with the song's pattern, fingerpicked, bass-note-and-strum, palm-muted power chords or reggae chops. For searched songs the strum pattern is detected from the recording. When the whole song was heard, each part's pattern is detected from its own bars, so a verse and chorus that are strummed differently each keep their pattern (`Tests/TranscribeTest.swift`, `partStrumChecks`).

Everything about a searched song comes from Apple's catalog and from listening on the Mac. The app does not read chords, tabs or lyrics from other websites.

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

## Studio

- **Storage:** takes live in `~/Library/Application Support/DontFret/Studio/`. `takes.json` holds every `Take`: its recording, an audio file the mixer can read (for video, the sound is extracted to `<id>-sound.m4a`), its `TakeEdit` and its overdub layers. `StudioStore(folder:)` can point anywhere, which tests use.
- **Recording:** `StudioRecorder` uses `AVCaptureSession` with `AVCaptureAudioFileOutput` (AAC `.m4a`) or `AVCaptureMovieFileOutput` (`.mov`). The camera needs `NSCameraUsageDescription`, which `build.sh` writes.
- **Mixing:** `StudioGraph` routes the take and its layers through a mixer, then a 2-band EQ, an Apple dynamics processor ("even out the volume") and reverb. `StudioPlayback` runs it live and keeps a video `AVPlayer` in sync with `setRate(_:time:atHostTime:)`. `StudioRenderer.render` runs the same graph offline, then applies fades and levels the peak to −1 dB. `exportVideo` combines the trimmed picture (with opacity fades) and the mixed sound into an `.mp4`.
- **Layer alignment:** a layer's `start` is the take time of its first sample, worked out from the gap between the recorder starting and playback starting. Users can drag a layer to fine-tune it.
- **Cuts (clipping):** edits are non-destructive. `TakeEdit.cuts` lists removed ranges in take time and applies to every track. `Take.kept` is the trim window minus the cuts, `length` is their total, and `outputTime(_:)` / `takeTime(_:)` convert between the edited timeline and the original recording. `Take.cut` merges overlapping cuts and `keepOnly` cuts everything outside a range. Playback schedules only `kept` (the video plays a composition of the kept ranges), and both renderers do the same, with 6 ms ramps at each join to avoid clicks.
- **Layers:** an `Overdub` also has `pan`, `muted` and `inPoint` / `outPoint` (a trim inside the layer file; `used` is the part that plays, in take time). `StudioPlayback.solo` is a set of track ids (`"main"` or a layer id); when it isn't empty, only those play. Recording over a selection starts playback 2 s early in raw mode (ignoring cuts) and crops the new layer to the selection.
- **Auto-align:** `StudioMedia.align` compares onset envelopes (5 ms hop) of the layer and the main take and searches ±0.15 s for the best match. It moves the layer only when the peak is clearly above the rest (z-score > 2), otherwise it reports no match.
- **Undo:** `TakeEditorView` keeps a history of `Take` values; slider drags made in quick succession count as one step.

## Detection self-test

```bash
swiftc -D SELFTEST -parse-as-library -swift-version 5 -O Sources/App/*.swift Tests/*.swift -o build/selftest && build/selftest
```

The test synthesizes every chord shape and single note and runs them through the recognizer. Current results:
- 97% of beginner chords and 87% of all chords are named correctly from scratch.
- In-game verification (Normal) accepts about 98% of correctly played chords, and every common open chord. A wrong chord is accepted about 1% of the time, room noise or random notes about 1%, just two strings of the chord about 10%, and a chord with one string on the wrong fret about 40% (often that still sounds like the chord).
- To pass, the sound has to match the chord's template, no other chord can fit better, every tone except the fifth has to be heard, and little sound can sit on notes outside the chord. It also has to hold for 2, 3 or 4 frames (Relaxed, Normal or Strict). The thresholds live on `Strictness` in `Store.swift`, and `Tests/StrictnessTest.swift` reports all three levels.
- Single notes (riffs): 100% accepted with pitch tracking, 0% wrong notes accepted.
- Muted-string hints catch 100% of detectable muted strings with no false alarms.
- Generated voicings, transposing, ChordPro round trip and catalog chords are all checked.

- Automatic chords from a full band mix (10 synthesized songs with guitar, bass, drums and melody): tempo, key and time signature 100%, bars 92%, whole progression 100%.

These numbers come from synthesized sound. A real guitar in a real room will differ, so run **Settings → Microphone & timing → Calibrate** first.
