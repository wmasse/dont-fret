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
| Studio: takes store, audio/video recorder, live mixer with effects, offline mixdown, video export | `Sources/App/StudioEngine.swift` |
| Studio pages: record panel, takes, editor with trim/layers/sound/export | `Sources/App/StudioView.swift` |
| Play Along / Wait Mode / Auto-Scroll sheet, section loops with auto speed-up | `Sources/App/Game.swift` |
| Chord Trainer (spaced review), 1-Minute Changes, Strum Trainer | `Sources/App/Practice.swift` |
| Song library, song page (key & capo, tricky changes, history), song editor | `Sources/App/SongsView.swift` |
| Melody from a recording: pitch tracking, notes on the song's beats, fret positions, the melody strip | `Sources/App/Melody.swift`, `MelodyView.swift` |
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

### Melody

Every analysis also picks out the song's tune, usually the lead vocal (`MelodyExtractor` in `Sources/App/Melody.swift`):

1. A 46 ms spectrum every 10 ms. For stereo audio (previews, audio files and the whole-song listen all keep a side channel), each bin is weighted by how centred it is in the stereo picture, `(|M|² − |S|²) / (|M|² + |S|²)`, because lead vocals are usually mixed in the middle.
2. Harmonic-sum pitch salience over G2–D6 in fifth-of-a-semitone steps, favouring a singer's range and pitches whose own fundamental is present.
3. A Viterbi path through the salience with a voiced/unvoiced state: moving pitch costs in proportion to the size of the move, so it follows one voice.
4. Notes: the singer's own tuning offset is measured from the pitch track, then a note-level Viterbi assigns each stretch of singing to a semitone (staying on a note is free, changing costs, notes in the key are slightly preferred), so vibrato and a singer sitting between two pitches don't flicker. Short glides are folded into the note they slide to, dips in strength split repeated notes, weak notes whose pitch doesn't move at all are dropped (singers wobble; strummed accompaniment doesn't), a note moves down an octave when the octave below explains the sound almost as well, and a lone note an octave away from both neighbours is moved back next to them.
5. `Transcription.songZeroBeat` says which beat of the recording is song beat 0 (the first bar, the bar a repeating loop was rotated to, or minus the chart offset for a matched chord chart), so `MelodyExtractor.place` can snap notes onto the song's own beat grid (16ths). A short preview's melody repeats with its chords.

The melody is stored on the song (`Song.melody`, relative to the capo like single-note tokens) and follows transposing and capo changes. `ProgressionPlayer` plays it on a second instance of the guitar (`GuitarSynth.melody`) so the tune doesn't cut off the chord's strings; `MelodyExtractor.picks` chooses where to fret each note (a small Viterbi over string/fret choices), hammer-ons and pull-offs for notes that carry straight on along a string, and vibrato on long notes. The song page shows it as a scrolling strip with string and fret labels that follows playback.

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
- In-game verification accepts 100% of correctly played chords; a wrong chord is accepted 3% of the time.
- Single notes (riffs): 100% accepted with pitch tracking, 0% wrong notes accepted.
- Muted-string hints catch 100% of detectable muted strings with no false alarms.
- Generated voicings, transposing, ChordPro round trip and catalog chords are all checked.

- Automatic chords from a full band mix (10 synthesized songs with guitar, bass, drums and melody): tempo, key and time signature 100%, bars 92%, whole progression 100%.
- Melody from a full band mix (8 synthesized 40 s songs with a sung-style lead over wide strummed guitars, bass and drums; `build/selftest --melody`): pitch right about 90% of the time the voice sings, notes about 70% F-measure (right pitch, onset within 100 ms), about 67% placed on the right beat. A quiet voice under loud guitars is the hard case (40–60%).
- Melody on real recordings (`build/selftest --melody-bench`, add `--verbose` for every note): 13 store previews of public-domain tunes we know note for note (*Silent Night*, *Amazing Grace*, *Jingle Bells*, *Joy to the World*, *Deck the Halls*, *When the Saints*, *Twinkle Twinkle*, *Happy Birthday*, *We Wish You a Merry Christmas*) sung by Bing Crosby, Kelly Clarkson, Elvis, Judy Collins, Michael Bublé, Sinatra, Nat King Cole, Louis Armstrong, Mariah Carey and children's recordings. The extracted melody is aligned to the written tune in any key and tempo, and each difference is classified. Currently 68% of the written notes come out right (octave slips 6%, a semitone off 5%, a tone off 6%, other wrong 8%, missed 7%); 28% of the heard notes aren't in the written tune, mostly backing vocals, horn and band fills, and singers' ornaments. Swing and gospel arrangements where the band answers the singer (Sinatra, Elvis) are the hard cases (30–50%). Previews download once into `build/bench` (needs the network).

These numbers come from synthesized sound. A real guitar in a real room will differ, so run **Settings → Microphone & timing → Calibrate** first.
