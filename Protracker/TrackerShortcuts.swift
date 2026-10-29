import AppKit

@MainActor
extension TrackerStore {
    func handleTrackerShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags, key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = flags.contains(.shift), option = flags.contains(.option), control = flags.contains(.control)
        // F1–F10 follow the original manual; macOS may require holding Fn.
        let functionKeys: [UInt16:Int] = [122:1,120:2,99:3,118:4,96:5,97:6,98:7,100:8,101:9,109:10]
        if let f = functionKeys[event.keyCode] {
            if f <= 2 { octave = f; return true }
            if f <= 5 {
                if option {
                    if f == 5 { pastePattern() } else { copyPattern(); if f == 3 { clearPattern() } }
                } else if shift || control {
                    if f == 5 { pasteBlock(effects:control) } else { copyBlock(cut:f == 3,track:true,effects:control) }
                } else {
                    if f == 5 { pasteSample() } else { copySample(cut:f == 3) }
                }
                return true
            }
            let slot = f-6
            if shift { storedRows[slot] = selectedRow }
            else if option || control { selectedRow = storedRows[slot]; if control { liveRecording = true; editMode = true }; play(pattern:true,fromCursor:true) }
            else { selectedRow = storedRows[slot] }
            return true
        }
        let digits: [UInt16:Int] = [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9,29:0]
        if event.keyCode == 114 { if option { openWorkbench(.presets) } else { showsHelp = true }; return true }
        if control {
            if let digit = Int(key), (0...9).contains(digit) { editStep = digit; return true }
            switch key {
            case "a": muted[selectedChannel].toggle()
            case "b": markBlock()
            case "c": copyBlock()
            case "d": deleteBlock()
            case "e": stretchTrack(expand:true)
            case "f": amigaFilter.toggle()
            case "g": change("Alle Samples verstärken") { for i in 0..<31 { SampleEditing.apply(.gain,to:&$0.samples[i]) } }
            case "h": transposeBlock(1)
            case "i": pasteBlock(insert:true)
            case "j": pasteBlock(mix:true)
            case "k":
                let p = patternIndex,r = selectedRow,ch = selectedChannel
                change("Spur ab Cursor löschen") { for row in r..<64 { $0.patterns[p][row,ch] = TrackerCell() } }
            case "l": transposeBlock(-1)
            case "m": preferences.multiKeyboard.toggle()
            case "n": selectedRow = blockStart
            case "o": stretchTrack(expand:false)
            case "p": pasteBlock()
            case "q": muted = [false,false,false,false]
            case "r": storedRows = [0,16,32,48,63]
            case "s": preferences.splitKeyboard.toggle()
            case "t": swapTracks()
            case "u": undoManager.undo()
            case "v": change("Alle Samples filtern") { for i in 0..<31 { SampleEditing.apply(.lowPass,to:&$0.samples[i]) } }
            case "w":
                let p = patternIndex,rows = blockRows,ch = selectedChannel,source = pattern
                change("Block polyphonisieren") { song in for r in rows { let target = (ch+r-rows.lowerBound)%4; song.patterns[p][r,target] = source[r,ch]; if target != ch { song.patterns[p][r,ch] = TrackerCell() } } }
            case "x": copyBlock(cut:true)
            case "y": reverseBlock()
            case "z": pasteBlock(effects:true)
            default:
                if event.keyCode == 36 { shiftRows(insert:true,effects:true) }
                else if event.keyCode == 51 { shiftRows(insert:false,effects:true) }
                else if event.keyCode == 123 { selectedSample = min(30,selectedSample+1) }
                else if event.keyCode == 124 { selectedSample = max(0,selectedSample-1) }
                else { return false }
            }
            return true
        }
        if option {
            if event.keyCode == 36 { shiftRows(insert:true,all:true); return true }
            if event.keyCode == 51 { shiftRows(insert:false,all:true); return true }
            if event.keyCode == 123 { setOrderPattern(patternIndex-1); return true }
            if event.keyCode == 124 { setOrderPattern(patternIndex+1); return true }
            if let digit = Int(key), (0...9).contains(digit) {
                let macro = effectMacros[digit],p = patternIndex,r = selectedRow,ch = selectedChannel
                change("Effekt-Makro") { $0.patterns[p][r,ch].effect = macro.effect; $0.patterns[p][r,ch].parameter = macro.parameter }; return true
            }
            switch key {
            case "a": openWorkbench(.recording)
            case "b": sampleOperation(.gain)
            case "d": open()
            case "e": openWorkbench(.pattern)
            case "f": sampleOperation(.lowPass)
            case "m": preferences.metronome.toggle()
            case "r": openWorkbench(.sample)
            case "s": openWorkbench(.sample)
            case "t": preview()
            case "y": exportAllSamples()
            case "z": muted[0].toggle()
            case "x": muted[1].toggle()
            case "c": muted[2].toggle()
            case "v": muted[3].toggle()
            case "-": openWorkbench(.settings)
            default: return false
            }
            return true
        }
        if shift && event.keyCode == 36 { shiftRows(insert:true); return true }
        if shift && event.keyCode == 51 { if selectedRow > 0 { selectedRow -= 1 }; shiftRows(insert:false); return true }
        if shift && event.keyCode == 124 { selectOrder(selectedOrder+1); return true }
        if shift && event.keyCode == 123 { selectOrder(selectedOrder-1); return true }
        if shift, let digit = digits[event.keyCode] { effectMacros[digit] = pattern[selectedRow,selectedChannel]; return true }
        if preferences.classicKeys && event.keyCode == 49 { stop(); editMode.toggle(); return true }
        if preferences.classicKeys && event.keyCode == 36 { move(row:1); return true }
        return false
    }
}
