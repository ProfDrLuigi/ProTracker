# ProTracker for macOS

Bring the Amiga tracker experience to your Mac. Open classic songs, edit samples, and write your own music. ProTracker runs directly on macOS — no Amiga or emulator required.

## What you can do

- Create music with **four channels and 31 samples**.
- Open, edit, and save **MOD and MODL files**.
- Enter notes and effects in 64-row patterns, then arrange them into a song.
- Import **WAV, AIFF, and 8SVX samples**, create loops, reverse sounds, or normalize their volume.
- Mute individual channels and adjust volume, stereo width, and the A500 sound filter.
- Export songs as **WAV** and undo or redo your edits.

## Getting started

1. Download ProTracker for macOS from the [Releases page](https://github.com/ProfDrLuigi/ProTracker/releases).
2. Move **Protracker.app** to your **Applications** folder.
3. Open the app.

The demo song **Neon Harbor** is loaded when you first launch the app. Press **Space** to listen.

## Make your first song

The app currently uses German labels. The steps below include their English meanings.

1. Click **Neu (New)**.
2. Select an empty sample slot on the left and load a sound using **Import**.
3. Click a note column in the pattern editor and press **Return** to turn on Edit mode.
4. Play notes with your keyboard. The lower letter row and nearby keys work like a small piano; **Q–U** play the next octave. **OCT** selects the octave, and **STEP** sets how many rows to advance after entering a note.
5. Listen to your pattern and use **Positionen (song order)** on the left to arrange your patterns into a song.
6. Click **Sichern (Save)** to save your module, or **WAV** at the top to export the song as audio.

With Edit mode off, you can preview sounds without changing any notes.

## Essential shortcuts

Click inside the pattern editor before entering notes.

| Key | Action |
| --- | --- |
| Space | Start or stop the song |
| Return | Toggle Edit mode |
| Esc | Stop playback |
| Arrow keys | Move between rows and fields |
| Tab / Shift + Tab | Next / previous channel |
| Delete | Clear the selected field |
| ⌘O | Open a module |
| ⌘S | Save a module |
| ⌘Z / ⇧⌘Z | Undo / redo |

Click the **question mark in the top-right corner** for more shortcuts and an effects reference.

## Save and share

Use **MOD** to keep editing your song or open it in other trackers. **MODL** preserves additional playback settings. Use **WAV** to create an audio file you can listen to and share.

WAV export renders one pass through the song, up to ten minutes. Classic four-channel modules are supported; XM, S3M, and IT files cannot be opened yet.
Use **MOD** for classic tracker songs, **MODL** for additional playback settings, or **PACK** for the original ProTracker packed format. **SONG** saves the arrangement without audio samples; export those separately if you want to share it. **WAV** creates an audio file you can listen to anywhere.

Sample import supports WAV, AIFF, raw audio, and 8SVX. Sample export supports WAV, 8SVX, and raw audio, with loops preserved in WAV and 8SVX. Classic four-channel modules, older 15-sample songs, PP20, and XPK-SQSH are supported. XM, S3M, and IT are not supported.

WAV export renders one pass through the song. The default limit is ten minutes and can be changed in Setup.

## Project status

ProTracker for macOS is an independent recreation based on Amiga ProTracker 3.61. Some original features are still missing, and certain modules may sound different from playback on a real Amiga.
