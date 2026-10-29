# Funktionsabgleich mit ProTracker 3.61

Grundlage: `Reference/ProTracker361/Install-Protracker/ProTracker/DATA/pt.help`,
die mitgelieferten Guides und die statische/dynamische Binary-Analyse.
Dieser Abgleich beschreibt konkrete Funktionen und ersetzt keine Behauptung einer
vollständigen 1:1-Portierung aller Amiga-Hardware- und Konfigurationsdetails.

| Originalbereich | Native Umsetzung | Nachweis |
|---|---|---|
| Pattern/Positionen | Vier Spuren, 64 Zeilen, 31 Samples, 128 Positionen/Patterns, Song/Pattern/ab Cursor | Build und interaktiver Lauf |
| Block/Spur/Effekte | Auswahl per Maus/Ctrl+B, Cut/Copy/Paste/Insert/Join, Reverse, Transpose, Expand/Contract, Spurtausch, Effekte separat, Polyphonisierung | Modelltests, native UI |
| Pattern-/Spurdateien | Laden/Speichern als ptpattern/pttrack | Validierte native Austauschformate |
| Sampler-Bereiche | Drag-Auswahl, numerische Grenzen, Zoom, Scroll, Zeichnen, Cut/Copy/Paste/Delete/Crop, Puffertausch | Modelltests + Auswahl/Reverse/Undo interaktiv |
| Sample-Effekte | Normalize, Ramp, Fade up/down, Gain, Silence, Invert, DC, Low/High-pass, Echo, Loop-Crossfade | Bereichs-/Clipping-/Längenprüfungen |
| Mix/Resample | Quellsample, Zielposition, Half/Clip, ±Halbton/Oktave | Loop- und Längentests |
| Chord maker | Dur/Moll/Sus4/7/6-Presets plus vier frei wählbare Töne | Modelltest, native UI |
| Waveform/Loop | Sinus/Rechteck/Sägezahn/Dreieck/Rauschen, Loop aus Bereich, Volume/Finetune | Modelltests |
| PLST/PED | Bis zu 2500 Presets/64 MB, Dateien/Ordner/Modulsamples, Suche, Banken, Namen, Favoriten, Banklöschung, Undo/Redo, Listenimport/-export, automatische Speicherung | Neustart + Entfernen/Undo/Redo interaktiv |
| Hardware-Sampler | Aufnahme über macOS-Standardeingang, Pegel, Zeitlimit, Übernahme in Sample-Platz | Implementiert; echte Mikrofonaufnahme benötigt Freigabe und ist nicht automatisiert aufgenommen worden |
| MIDI | CoreMIDI-Eingänge, Gerätewechsel, Running Status, Velocity, Note-off | Parsertests; kein externes MIDI-Gerät im End-to-End-Test |
| Notenaufnahme | Song/Pattern, Quantize, Count-in, Multi-/Split-Keyboard, nativer Metronom-Klick | Timing-/Parsertests und UI; Click ersetzt den reservierten Original-Samplekanal |
| Sprache | Deutsch/Englisch, automatische macOS-Sprachwahl, Umschalter im Setup; Oberfläche, Menüs, Hilfe, Status, Fehler und Bedienungshilfen | Ressourcen-/Platzhaltertests und interaktiver Sprachwechsel |
| Setup | Farben, Notennamen, Zahlen/Nullen, klassische Tasten, Multi/Split, MIDI, Standardordner, PAL/NTSC, Filter, 4× Resampling, Defaulttempo, Exportlimit, Konfiguration laden/sichern/reset | Validierung/Roundtrip + UI |
| Shortcuts | Original-F1–F10-Slots und Modifikatoren, Blockbefehle, Shift/Option/Ctrl-Return/Backspace, Effektmakros, rechte Modifier im Classic-Modus | Implementiert aus dem Original-Help; systemreservierte macOS-Tasten bleiben systemabhängig |
| Drucken | Song und Preset-Liste über macOS-Druckdialog/PDF | Native Implementierung; kein physischer Druckauftrag erzeugt |
| MOD/MODL | 31-Sample-MOD, M.K./M!K!/4CHN/FLT4, MODL/PTDT/INFO/CMNT, UTF-8-Kommentar | Roundtrips, malformed/fuzz |
| Alte Songs | Klassisches 15-Sample-Layout und explizite samplelose SONG-Dateien; optional aktuelle Samplebank behalten | Layout-/Loop-/Song-only-Tests |
| PACK/PAKK | Originales ProTracker-Packing laden und schreiben | Swift-Grenzfälle + originaler 68000-Decoder reproduziert 19948 Bytes des Swift-Exports exakt |
| PowerPacker/XPK | PP20, XPK-SQSH und unkomprimierte XPK-Blöcke | Literal/Match/Checksum-Tests; reale SQSH-Datei bytegenau gegen C-Referenz |
| Sampleformate | WAV/AIFF/CAF, raw/smp, 8SVX einschließlich Fibonacci; WAV/8SVX/raw-Export, Loop-Metadaten | WAV/8SVX/Fibonacci-/Loop-Tests |
| Wiedergabe | Standard-/E-Effekte, Loop-Reload bei Instrumentwechsel, 4× Oversampling, PAL/NTSC, angenäherte analoge Filter | 206 Original-Effektvektoren + Timing/Loop/Ende/Audio-Tests |
| Hardware-Audiokern | Ganzzahlige PAL/NTSC- und CIA-Zeitbasis, Paula-Register/DMA/Puffer/PWM, verzögerte Interrupts, sinc-DAC-Rekonstruktion | 120 originale Timer-Vektoren plus Hardware-/Puffergrößenprüfungen; Grenzen siehe HARDWARE.md |
| Audio-Lifecycle | Start im Hintergrund, 5-Sekunden-Timeout, Stop/Abbruch, keine verspäteten Noten nach Timeout | Regressionstest; realer Wiedergabestart/Stop nach Treiberhänger geprüft |

## Bewusste Plattformanpassungen und offene Kompatibilität

- PLST/PED und Konfiguration erfüllen die entsprechenden Aufgaben mit nativen
  Dateien. Die alten Amiga-PLST-/PT.config-Binärdateien werden nicht importiert.
- Pattern-/Track-Austausch nutzt native Dateien; nicht jede historische
  Editor-Dateivariante ist rekonstruiert.
- Nicht jeder XPK-Untercodec ist SQSH: andere Codecs und verschlüsseltes PX20
  werden mit einer konkreten Fehlermeldung abgelehnt. XPK-/PP20-Export ist nicht
  implementiert; PACK/PAKK steht als natives komprimiertes Exportformat bereit.
- Sample-Effekte und Resampling sind native DSP-Implementierungen. Sie sind nicht
  für jeden Arbeitsschritt bytegenau mit dem Amiga-Editor verglichen.
- Der Hardware-Audiokern modelliert Paula-DMA, ganzzahlige CIA-Latches, PWM und
  bandbegrenzte DAC-Flanken. Originale 68000-Instruktionslatenzen, vollständige
  Buskonkurrenz und analoge Hardware sind noch nicht vollständig nachgebildet.
  Eine nachgewiesene 1:1-Taktgleichheit aller Songs besteht weiterhin nicht;
  Details und Nachweise stehen in [HARDWARE.md](HARDWARE.md).
- DF0:-Operationen, Diskformatieren, Workbench-Icons, Amiga-CLI, Copper- und
  Bildschirmhardware werden durch macOS-Fenster, Farbauswahl, Datei- und
  Druckdialoge ersetzt. Amiga-Selbstläufer/Executable-Module werden nicht erzeugt.
- Die Aufnahme nutzt das in macOS gewählte Standardeingabegerät; maximal rund
  7,9 Sekunden passen in ein 131070-Byte-Sample. macOS kann dafür eine
  Mikrofonfreigabe verlangen.

## Prüfung

`Tools/test.sh` prüft den nativen Kern. Die erweiterten Tests enthalten zusätzlich
Sample-/Blockoperationen, Presets, MIDI-Parser, Packed-Formate, Unicode-/Songdateien,
Oversampling und Abbruch des Audiostarts. Der reale SQSH-C-Vergleich wird ausgeführt,
wenn die lokalen Referenzdateien unter `.build/reference/` vorhanden sind.
Sie werden nicht in die App kopiert.

Original-PACK-Abgleich (Entwicklungswerkzeug, benötigt Unicorn):

```sh
.tools-venv/bin/python Tools/verify_pack_original.py '.build/checks/Neon Harbor.pack' '.build/checks/Neon Harbor.mod'
```

Drittanbieter-Hinweise für die Swift-Adaptionen der SQSH-/PP20-Algorithmen befinden
sich in `SourcesLegal/Depackers.txt` und werden als `ThirdPartyNotices.txt` in die App
aufgenommen. Die Musikdatei aus dem SQSH-Referenztest bleibt außerhalb des Repositorys.
