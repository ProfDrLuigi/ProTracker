# ProTracker for macOS

Bring the Amiga tracker experience to your Mac. Open classic songs, shape your own sounds, and write music with four channels and 31 samples. No Amiga or emulator required.

## What you can do

- Create and arrange patterns, with notes, effects, block editing, and undo/redo.
- Select, draw, trim, loop, reverse, filter, fade, mix, and resample sounds.
- Add echo, adjust volume, or turn a sample into a chord.
- Organize sounds into searchable preset banks and favorites.
- Record samples from your microphone or audio interface.
- Play a MIDI keyboard and record notes with quantization, a metronome, and count-in.
- Open classic modules and export your finished songs as WAV.

## Getting started

1. Download the app from [Releases](https://github.com/ProfDrLuigi/ProTracker/releases).
2. Move **Protracker.app** to your **Applications** folder.
3. Open the app. The demo song **Neon Harbor** is ready to play — press **Space**.

## Make your first song

1. Click **New** and select an empty sample slot on the left.
2. Use **Import** to load a sound, or open **Tools → Recording** to record one.
3. Click a note column in the pattern editor and press **Return** to enable Edit mode. Play notes using the letter keys; **Q–U** play the next octave. **OCT** selects the octave, and **STEP** sets the spacing between notes.
4. Arrange patterns using **Positions (song order)**. Click **Save** to keep editing later, or **WAV** at the top to export audio.

With Edit mode off, you can preview sounds without changing notes.

The app supports **English and German** and follows your macOS language by default. You can choose a language in **Tools → Setup → Language**. Some macOS controls adopt the new language after restarting the app.

## Your workspace

Click **Tools** to open:

- **Sampler:** drag to select a range, zoom in, draw the waveform, or apply sound effects. Edits use the selected range, or the whole sample if nothing is selected.
- **Edit operations:** copy, cut, paste, reverse, transpose, expand, and arrange blocks or tracks.
- **Presets · PLST / PED:** add sounds from files, folders, or modules; organize banks, edit names, and save or share your collection.
- **Recording:** record a sample or capture notes while the song plays. Microphone recording starts only when you press Start and allow access in macOS.
- **Setup:** customize colors, shortcuts, folders, MIDI, playback, and recording options. Preferences are saved automatically.

## Essential shortcuts

Click inside the pattern editor before entering notes.

| Key | Action |
| --- | --- |
| Space | Start or stop the song |
| Return | Toggle Edit mode |
| Esc | Stop playback |
| Arrow keys | Move between rows and fields |
| Tab / Shift + Tab | Next / previous channel |
| ⌘O / ⌘S | Open / save |
| ⌘Z / ⇧⌘Z | Undo / redo |
| Control+B | Mark a block |
| Control+C / X / P | Copy / cut / paste a block |
| F3 / F4 / F5 | Cut / copy / paste a sample |

F-keys may require **Fn** on your Mac. Setup also offers a classic keyboard mode. Click the **question mark** for more help.

## Save and share

Use **MOD** for classic tracker songs, **MODL** for additional playback settings, or **PACK** for the original ProTracker packed format. **SONG** saves the arrangement without audio samples; export those separately if you want to share it. **WAV** creates an audio file you can listen to anywhere.

Sample import supports WAV, AIFF, raw audio, and 8SVX. Sample export supports WAV, 8SVX, and raw audio, with loops preserved in WAV and 8SVX. Classic four-channel modules, older 15-sample songs, PP20, and XPK-SQSH are supported. XM, S3M, and IT are not supported.

WAV export renders one pass through the song. The default limit is ten minutes and can be changed in Setup.

## Project status

An independent native recreation based on Amiga ProTracker 3.61. It includes macOS equivalents of the main editing and sample-management tools. Playback is not guaranteed to sound identical to a real Amiga, and some original formats and hardware-specific functions remain unsupported.
