# Cycle-based audio devices

The default live and WAV renderer now uses integer Amiga color clocks (CCK).
This replaces floating sample positions and idealized `2.5 / BPM` tick durations.
It is a substantial audio-hardware implementation, **not a verified cycle-exact
emulation of the entire original ProTracker executable or an entire Amiga**.

## Implemented

- Nominal PAL 3,546,895 Hz / NTSC 3,579,545 Hz, with one CIA E-clock per five CCK.
- 8520 interval-timer latch, counter, zero count, continuous/one-shot operation,
  force-load, high/low writes, interrupt mask and read-to-acknowledge ICR subset.
- PT3.61 tempo dividends from the actual binary: `$1B0F87` / `$1B4F4D`.
  The original code force-loads the old timer latch before writing the new value.
  The resulting one-interval tempo-change latency is preserved. With CIA tempo
  disabled, this particular original programmer still uses its fixed 125-BPM
  timer; it does not select the native Mac's refresh rate or an ideal 60 Hz tick.
- Four Paula state machines (idle, DMA priming, waiting, upper/lower byte).
- AUDxLC/LEN/PER/VOL/DAT and audio bits of DMACON, INTENA, INTREQ and ADKCON.
- Reserved audio DMA fetch slots `$0D/$0F/$11/$13`, latched requests/restarts,
  discarded priming word, separate holding/output buffers, word counters,
  pointer reloads, and repeated words when DMA bandwidth is insufficient.
- One-CCK DMA state-processing delay and one-CCK audio interrupt delay.
- PAL 227-CCK lines; NTSC alternating 227/228-CCK lines.
- Period changes take effect on the next byte boundary; an in-flight countdown
  isn't recalculated. Zero period/length represent 65536 clocks/words.
- Full 64-CCK PWM volume counter, including its phase and the maximum-volume bit.
- Manual AUDxDAT playback and period/volume attachment to the next channel.
- Timestamped device events and optional bounded traces for diagnostic tests.
- Integer rational conversion to host samples at 32/44.1/48/96/176.4/192 kHz,
  independent of host buffer partitioning.
- Independently generated, causal Blackman-windowed sinc step reconstruction.
  Floating point is used for reconstruction/analog filters, not device deadlines.
  The 4x option retains four internal output samples per host frame.

`AmigaTiming.swift`, `PaulaChip.swift` and `BandLimitedDAC.swift` are independent
Swift implementations. `AmigaReplayHardware.swift` connects them to the native
tracker. The former mixer is retained internally for development comparisons;
`hardwareTiming` defaults to true and the application does not disable it.

## Evidence and reproducibility

`Tools/original_timer_vectors.py` executes the supplied 68000 binary's actual
`$116D4..$11722` timer programmer with Unicorn. The 120 saved cases span PAL/NTSC,
Timer A/B, CIA on/off and several tempos. Tests compare latch values and the
observed order of register writes. Unicorn supplies **no CIA or CPU-cycle oracle**;
these vectors establish what the original code programs, not hardware timing.

`Tests/HardwareChecks.swift` adds device-level checks derived from the hardware
specification: DMA slots, sample-byte edges, counter reloads, interrupts,
manual playback, PWM duty and phase, attachment, zero values, buffered data,
underruns, and split-advance equivalence. A full native replay render is compared
bit-for-bit across different host buffer sizes. The original 206 effect-vector
comparisons remain in the suite. `Tools/test.sh` runs all of these checks.

A release-optimized local benchmark renders one second of the demo with 4x
reconstruction in approximately 0.14 seconds; this is a performance observation
on the development Mac, not a timing deadline guarantee on every Mac.

## Accuracy boundaries still open

- The Swift tracker emits register batches at tick boundaries. It does not execute
  68000 instructions, account for the original interrupt-prologue latency, or
  reproduce instruction/bus contention against Copper, bitplanes, blitter and OS.
  The native note-restart adapter explicitly resets a channel; it does not yet
  reproduce the original CPU's complete DMA-off/interrupt/restart choreography.
- The device model and race ordering have not been compared exhaustively against
  a physical Paula/8520 trace. In particular, sub-CCK bus phases, all simultaneous
  register/DMA races, delayed 8520 control pipelines and every attach/manual-audio
  edge case require further external conformance work.
- Native playback uses virtual sample banks, so editor modules aren't constrained
  to physical Chip-RAM capacity. The low-level Paula model separately defaults
  to a word-aligned 2 MB pointer mask.
- Fixed non-interlaced beam timing is modeled. Programmable ECS/AGA beam timings,
  interlaced fields, genlock, video, disk and serial hardware are outside this core.
- The analog A500/LED/high-pass filters remain approximations. Actual resistor,
  capacitor and DAC nonlinearity variations aren't modeled by the digital tests.
- The sinc filter has a finite kernel and reconstruction latency. Its output is
  a band-limited representation of the modeled DAC, not a recording of real hardware.

The Xcode Debug target enables Swift optimization as well: the unoptimized PWM/
sinc path was measured at about 4.5 times real time and could not meet audio
callback deadlines. Optimized debug builds trade some source-stepping fidelity
for a usable real-time audio engine.

These boundaries must remain explicit: passing the unit tests is not proof of
complete cycle equality with every Amiga or every ProTracker song.

## Primary references

- Commodore, *Amiga Hardware Reference Manual*, third edition, chapter 2
  (horizontal timing), chapter 5 pp. 137-166 (audio registers/state diagram),
  chapter 6 pp. 194-195 (DMA allocation), appendix F pp. 341-343 (8520 timers):
  [original manual scan](https://www.ikod.se/wp-content/uploads/2020/08/Amiga_Hardware_Reference_Manual_3rd_Edition.pdf).
- Commodore's audio-state-machine text:
  [ADCD HTML reproduction](https://amigadev.elowar.com/read/ADCD_2.1/Hardware_Manual_guide/node00F2.html).
- Independent cross-check of one-CCK delays, priming/reload semantics and PWM:
  [WinUAE audio.cpp](https://github.com/tonioni/WinUAE/blob/master/audio.cpp) and
  [custom.cpp](https://github.com/tonioni/WinUAE/blob/master/custom.cpp).
  These were read as reference material; no WinUAE source, tables, library or
  runtime dependency is included in the application.

The manual scan and downloaded comparison sources remain under ignored
`.build/reference/hardware/`; they are not bundled with the app or committed.
