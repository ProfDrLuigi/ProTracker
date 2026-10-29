#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
python3 Tools/check_localizations.py
mkdir -p .build/checks
xcrun swiftc -O Protracker/Localization.swift Protracker/MIDIKeyboard.swift Protracker/PackedModules.swift Protracker/SampleEditing.swift Protracker/TrackerPreferences.swift Protracker/AmigaTables.swift Protracker/TrackerModule.swift Protracker/AmigaTiming.swift Protracker/PaulaChip.swift Protracker/BandLimitedDAC.swift Protracker/AmigaReplayHardware.swift Protracker/TrackerReplay.swift Protracker/AudioDriver.swift Protracker/DemoModule.swift Tests/HardwareChecks.swift Tests/main.swift -o .build/checks/replay-tests
.build/checks/replay-tests
