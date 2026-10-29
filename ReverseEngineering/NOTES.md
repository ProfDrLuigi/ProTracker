# ProTracker 3.61 → native Swift

## Grundlage und Nachweis

Ausgangspunkt ist das vom Benutzer bereitgestellte `Protracker3.61.lha`, nicht der
Quellcode eines anderen Tracker-Clones. Das Archiv wurde unverändert aufbewahrt
und nach `Reference/ProTracker361` entpackt. Es enthält den fertigen Editor in zwei
CPU-Varianten, Dokumentation und eine ältere 2.1A-Replayroutine in Assembler;
der vollständige 3.61-Editorquelltext ist nicht enthalten.

| Programm | CPU laut eingebettetem `$VER` | Größe | SHA-256 |
|---|---|---:|---|
| `MAIN/ProTracker_000` | 68000 | 286316 | `87789199f121137451b6c49af1af76389b3b1e85d4c78474c3b3d1bdbe80596e` |
| `MAIN/ProTracker` | 68030 | 283740 | `8bfef482a904fcb54afb58d190e5502a56a8355b8a354ae43d3128063d25caca` |

Beide Dateien wurden tatsächlich zerlegt und disassembliert. `Tools/disassemble_amiga.py`
liest HUNK_HEADER, CODE, DATA, BSS und RELOC32, legt die Segmente an synthetische
Ladeadressen und wendet die Relokationen an. Capstone dekodiert die Instruktionen
mit dem passenden CPU-Modus. In `68000/` und `68030/` liegen jeweils:

- `hunk-0.s`: vollständiger linearer Disassembly-Durchlauf mit Maschinenbytes.
- `analysis.json`: Segmentgrößen, Dateioffsets, Relokationen und Zeichenkettenreferenzen.
- `strings.tsv`: Zeichenketten, ursprüngliche Dateioffsets und direkte Referenzen.

**Adresskonvention:** Die folgenden Adressen beziehen sich auf die relokierte
68000-Variante mit Hunk 0 bei `$10000`, nicht auf Offsets innerhalb der LHA-Datei.
Für Hunk 0 gilt: Dateioffset = Ladeadresse − `$10000` + `$30`.
Der lineare Durchlauf interpretiert auch eingebettete Daten als Instruktionen.
Er ist keine vollständige Kontrollflussrekonstruktion. Die unten benannten Bereiche
wurden anhand zusammenhängender Kontrollflüsse, Registerzugriffe und Aufrufer untersucht.

## Rekonstruierte Bereiche

Die Bezeichnungen sind hier vergebene Funktionsnamen, keine wiedergewonnenen Originalsymbole.

| Bereich | Befund direkt aus der Binary | Swift-Zuordnung |
|---|---|---|
| `$10000–$101F0` | Prozess-/Workbench-Start, Exec-Basis aus `$4`, Bibliotheksaufrufe, Hauptschleife | `ProtrackerApp`, native macOS-Lifecycle |
| `$11464–$11722` | CIA-A/B-Anforderung und Timerprogrammierung, BPM-Division | `AmigaTiming`, `AmigaReplayHardware`; originale ganzzahlige Timer-Latches |
| `$1289C–$128D4` | vier Paula-Registerblöcke mit `$10` Abstand; Lautstärke `(volume × master + 32) >> 6` | Mixer und Masterlautstärke |
| `$1ED28–$1EFEA` | `MODL`, `VERS`, `INFO`, `CMNT`, `PTDT`; INFO-Übernahme in Wiedergabevariablen | `MODCodec`, `IFF` |
| `$29B9C–$29BEE` | Tickzähler, Vergleich mit Speed, vier Stimmen; Zustandsblöcke von `$58` Bytes | `processTick`, `Voice` |
| `$29C48–$29CA6` | Positionstabelle bei Modul+952, Pattern bei +1084, Patternnummer ×1024, vier Zellen ×4 Bytes | `TrackerPattern`, `readRow` |
| `$29CFA–$29E62` | Sampleindex aus zwei Nibbles, 30-Byte-Sampleheader, Finetune, Lautstärke, Loops, verzögerte Note | `TrackerCell`, `TrackerSample`, Note-Trigger |
| `$29FF6–$2A116` | Zeilenoffset +16, Patternende bei 1024, Positionsfortschritt, Delay und Pattern-Loops | `advanceRow` und Delay-Zustand |
| `$2A118–$2A19A` | Effekt-Dispatcher für Folgeticks und getrennte Paula-Ausgabe | `runEffects` |
| `$2A19C–$2A200` | Arpeggio modulo 3 und Finetune-Tabelle; jeder dritte Tick benutzt die unveränderte Basisperiode | Arpeggio |
| `$2A202–$2A2A4` | Slides/Fine-Slides; 16-Bit-Zustand, 12-Bit-Vergleich, Grenzen 113/856 | `slide` |
| `$2A2A6–$2A39C` | Portamento-Ziel, negatives Finetune, Speed-Gedächtnis und Glissando | `readRow`, `portamento` |
| `$2A39E–$2A502` | Vibrato/Tremolo mit Nibble-Gedächtnis, Sinus/Rampe/Rechteck, 8-Bit-Phase | `vibrato`, `tremolo`, `wave` |
| `$2A504–$2A632` | Sample-Offset, Volume Slide, B/C/D/F, BCD-Zeilenumrechnung, F00 Stop | Haupt-Effekte |
| `$2A696–$2A95C` | E-Dispatcher; E5 ist Finetune, E6 Loop, E8 Sample-Glättung, E9 Retrigger, EC/ED/EE/EF | erweiterte Effekte |
| `$2A7CC–$2A804` | E8 mittelt benachbarte signed Samplewerte im Loop, letzter Wert gegen den bereits veränderten ersten | `karplusStrong` |
| `$2A95E–$2A9AE` | Funk-/Invert-Loop-Akkumulator; Byte-Invertierung nach Schwellwert 128 | `invertLoop` |
| `$2B5AA` | 16 Funk-Geschwindigkeiten | `AmigaTables.funk` |
| `$2B5BA` | 32 Sinus-Halbwellenwerte | `AmigaTables.sine` |
| `$2C172` | 16 Finetunes ×37 Wörter, je 36 Noten plus Nullabschluss | `AmigaTables.periods` |

Die drei numerischen Tabellen werden mit SHA-256-Prüfung von
`Tools/extract_tables.py` direkt aus der Original-Binary extrahiert.
Die mitgelieferten Textbeschreibungen wurden zum Abgleich verwendet. Ein konkreter
Unterschied: Das Effektblatt bezeichnet E8 als unbenutzt, die 3.61-Binary enthält
jedoch tatsächlich die oben beschriebene Sample-Glättung.

## Dynamischer Abgleich ausgewählter Originalroutinen

`Tools/original_replay_vectors.py` lädt die Originalsegmente in Unicorn mit
M68000-CPU, wendet dieselben Relokationen an und initialisiert einen isolierten
Stimmenzustand bei `$62D84` sowie Paula-Registerspeicher bei `$DFF0A0`.
Aufgerufen werden der Original-Dispatcher `$2A118` bzw. für Tick 0 `$2A634`
mit dem ursprünglichen Volume-Ausgabepfad `$29BF0`.
Eine künstliche Rücksprungadresse und ein Instruktionslimit begrenzen jeden Fall.
Es wird kein AmigaOS und kein kompletter Song in einer Amiga-Umgebung ausgeführt.

`replay-vectors.json` enthält **206 Ergebnisse tatsächlicher Ausführungen der
Original-Maschineninstruktionen**. Verglichen werden Zustandsperiode, ausgegebene
Periode, Lautstärke, ausgegebene Lautstärke, Portamento-Ziel und Modulationsphasen.
Abgedeckt sind Slides einschließlich Überlauf, Volume Slides, Cxx-Clamping,
Arpeggios/Finetunes, Portamento, Vibrato/Tremolo einschließlich Rampen/Rechtecken,
sowie ausgewählte Tick-0-E-Effekte. Zusätzlich werden E8-Sample-Glättung auf
mehreren Ticks und EF-Invert-Loop direkt an den veränderten Samplebytes verglichen.

Aus diesen Vergleichen wurden Fehler der ersten Swift-Implementierung korrigiert:
Nibble-Gedächtnis beim laufenden Modulationseffekt, Portamento-Speed,
Arpeggio-Basis auf jedem dritten Tick und das nicht intuitive 16-Bit-Slide-Wrapping.
Die erwarteten Daten werden nicht von einer zweiten Swift-Implementierung erzeugt.

Zusätzliche native Prüfungen decken unter anderem 100-Pattern-MOD-Roundtrips,
MODL-Metadaten, ungültige/abgeschnittene Dateien, 250 deterministische Fuzz-Eingaben,
Zeilen-/Tempogrenzen, E6/EE/F00, PCM-Loops, WAV-Länge/Header und Sampleimport ab.

## Umfang und bekannte Unterschiede

Der native Funktionsumfang wurde nach dem ersten Kern deutlich erweitert. Den
aktuellen Abgleich mit Original-Help und Binary einschließlich offener Grenzen
beschreibt [FEATURES.md](FEATURES.md).

Hinzugekommen sind der Bereichs-Sampler mit Zeichnen und DSP-Werkzeugen,
Block-/Spur-/Effektbearbeitung, Chord maker, native PLST/PED-Verwaltung,
Audio- und MIDI-Aufnahme, Konfiguration/Palette/Ordner, Druck/PDF, ältere und
samplelose Songs sowie PP20/XPK-SQSH und PACK/PAKK.

PACK/PAKK wurde unmittelbar aus `$23B8A–$23C28` rekonstruiert. Die Datei beginnt
mit Kennung, Packed-Length und Unpacked-Length (je 32 Bit big endian). Der
rückwärts lesende Decoder benutzt Sentinel-Bits in 32-Bit-Wörtern und Literal-/
Matchcodes. `Tools/verify_pack_original.py` führt die tatsächliche Originalroutine
in Unicorn aus und bestätigt einen Swift-Export von 19948 Bytes bytegenau.

Der vollständige Editor ist weiterhin keine automatische Decompilierung. Native
DSP- und UI-Funktionen sind Nachimplementierungen; vollständige Paula-/Bus-Zyklen,
alle XPK-Codecs und alte PLST-/Konfigurationsdateien sind nicht gleichgesetzt.
Die Originalprogramme werden nicht in das App-Bundle übernommen.

## Ergebnis der Verifikation

Der Xcode-Debug-Build ist erfolgreich. `Tools/test.sh` prüft den erweiterten Kern;
der abschließende Stand wird in der Übergabe genannt. Die 206 ursprünglichen
Effektvergleichsfälle bleiben enthalten. Für SQSH wurden 16886 Bytes einer realen
Datei gegen den etablierten C-Decoder verglichen. Wellenformauswahl, Reverse/Undo,
Preset-Persistenz und Entfernen/Undo/Redo sowie Wiedergabe/Stop wurden interaktiv
geprüft. Physische Aufnahme, MIDI-Hardware und Druck wurden nicht ausgelöst.

Ein im Test beobachteter CoreAudio-Treiberaufruf blockierte den Hauptthread beim
Audiostart. Wiedergabe und Aufnahme initialisieren Geräte deshalb im Hintergrund;
Startabbruch/Timeout lassen den Editor bedienbar. Ein verspätet fertiger
Wiedergabestart darf keine Noten mehr auslösen. Der Renderer hat einen schnellen
Ruhepfad, und UI-Polling publiziert nur tatsächliche Änderungen.

## Reproduzieren

Im Projektordner:

```sh
python3 -m venv .tools-venv
.tools-venv/bin/python -m pip install -r Tools/requirements.txt
.tools-venv/bin/python Tools/disassemble_amiga.py Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker_000 ReverseEngineering/68000
.tools-venv/bin/python Tools/disassemble_amiga.py Reference/ProTracker361/Install-Protracker/ProTracker/MAIN/ProTracker ReverseEngineering/68030 --cpu 68030
python3 Tools/extract_tables.py
.tools-venv/bin/python Tools/original_replay_vectors.py
Tools/test.sh
xcodebuild -project Protracker.xcodeproj -scheme Protracker -configuration Debug -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
open .build/Build/Products/Debug/Protracker.app
```

Die Swift-App benötigt keine Python-Pakete oder externen Audio-Bibliotheken.
Capstone und Unicorn dienen ausschließlich der reproduzierbaren Analyse.
Die originale Dokumentation/Freeware-Hinweise der jeweiligen Amiga-Autoren liegen
unverändert im entpackten Archiv. Es wurde kein pt2-clone-Quellcode übernommen.

## Hardware-Audiokern

Live-Wiedergabe und WAV-Export nutzen jetzt standardmäßig `PaulaChip` und den
CIA-Timer auf einer gemeinsamen ganzzahligen CCK-Zeitbasis. Hinzugekommen sind
DMA-Slots, Wortpuffer, Pointer-Reloads, verzögerte Interrupts, PWM-Lautstärke und
bandbegrenzte DAC-Rekonstruktion. 120 zusätzliche Original-Binary-Ausführungen
prüfen den CIA-Programmierpfad. Den genauen Umfang, Referenzen und die noch offenen
Grenzen einer vollständigen Taktgleichheit dokumentiert [HARDWARE.md](HARDWARE.md).
