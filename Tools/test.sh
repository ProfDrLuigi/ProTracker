#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
xcrun swiftc -O Protracker/AmigaTables.swift Protracker/TrackerModule.swift Protracker/TrackerReplay.swift Protracker/AudioDriver.swift Protracker/DemoModule.swift Tests/main.swift -o .build/checks/replay-tests
.build/checks/replay-tests
