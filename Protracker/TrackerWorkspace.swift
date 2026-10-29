import AppKit
import SwiftUI

@MainActor
extension TrackerStore {
    var sampleRange: Range<Int> {
        let start = min(sample.pcm.count,max(0,sampleSelectionStart)), end = min(sample.pcm.count,max(0,sampleSelectionEnd))
        return min(start,end)..<max(start,end)
    }
    var operationRange: Range<Int> { sampleRange.isEmpty ? 0..<sample.pcm.count : sampleRange }
    func selectAllSamples() { sampleSelectionStart = 0; sampleSelectionEnd = sample.pcm.count }
    func setSampleSelection(_ range: Range<Int>) { sampleSelectionStart = range.lowerBound; sampleSelectionEnd = range.upperBound }
    func sampleOperation(_ op: SampleEditing.Operation) {
        let r = operationRange, gain = sampleGain, delay = max(1,Int(echoDelay*SampleAudio.rootRate)), feedback = echoFeedback
        sampleChange(op.rawValue) { SampleEditing.apply(op,to:&$0,range:r,gain:gain,delay:delay,feedback:feedback,rampFrom:rampFrom,rampTo:rampTo) }
    }
    func copySample(cut: Bool = false) {
        let r = operationRange
        sampleClipboard = Array(sample.pcm[r])
        if cut { deleteSampleRange() }
        status = "\(sampleClipboard.count) Sample-Bytes kopiert"
    }
    func pasteSample() {
        guard !sampleClipboard.isEmpty else { return }
        var next = sample
        do {
            let r = sampleRange
            try SampleEditing.replace(r,in:&next,with:sampleClipboard)
            sampleChange("Sample einsetzen") { $0 = next }
            setSampleSelection(r.lowerBound..<min(next.pcm.count,r.lowerBound+sampleClipboard.count))
        } catch { report(error) }
    }
    func swapSampleBuffer() {
        guard !sampleClipboard.isEmpty else { return }
        let old = Array(sample.pcm[operationRange]), clipboard = sampleClipboard
        var next = sample
        do { try SampleEditing.replace(operationRange,in:&next,with:clipboard); sampleChange("Sample-Puffer tauschen") { $0 = next }; sampleClipboard = old; selectAllSamples() }
        catch { report(error) }
    }
    func deleteSampleRange() {
        let r = operationRange; var next = sample
        do { try SampleEditing.replace(r,in:&next,with:[]); sampleChange("Sample-Bereich löschen") { $0 = next }; setSampleSelection(min(r.lowerBound,next.pcm.count)..<min(r.lowerBound,next.pcm.count)) }
        catch { report(error) }
    }
    func cropSample() { let r = operationRange; sampleChange("Sample zuschneiden") { SampleEditing.crop(r,in:&$0) }; selectAllSamples(); sampleZoomStart = 0; sampleZoomEnd = 0 }
    func setLoopFromSelection() {
        let r = operationRange
        sampleChange("Loop aus Bereich") { $0.loopStart = r.lowerBound; $0.loopLength = r.count }
    }
    func resampleSample(_ ratio: Double) {
        var next = sample
        do { try SampleEditing.resample(operationRange,in:&next,ratio:ratio); sampleChange("Resample") { $0 = next }; selectAllSamples() }
        catch { report(error) }
    }
    func mixSample() {
        let source = module.samples[mixSource], offset = operationRange.lowerBound
        var next = sample
        do { try SampleEditing.mix(source,into:&next,at:offset,half:halfMix); sampleChange("Samples mischen") { $0 = next } }
        catch { report(error) }
    }
    func createChord() {
        let presets = [[0,4,7],[0,3,7],[0,5,7],[0,4,7,11],[0,3,7,10],[0,4,7,9],[0,3,7,9]]
        let selected = chordNotes.filter { $0 >= 0 }
        let root = selected.first ?? 0
        let result = SampleEditing.chord(sample,intervals:selected.isEmpty ? presets[min(chordType,presets.count-1)] : selected.map { $0-root })
        sampleChange("Akkord erzeugen") { $0 = result }; selectAllSamples()
    }
    func generateWave() { sampleChange("Wellenform erzeugen") { $0 = SampleEditing.waveform(waveShape) }; selectAllSamples() }
    func drawSample(at index: Int, value: Int8) {
        guard sample.pcm.indices.contains(index) else { return }
        // The waveform view collects a stroke, then commits one undoable edit on mouse-up.
        sampleDrawing[index] = value
    }
    func commitSampleDrawing() {
        let drawing = sampleDrawing; sampleDrawing.removeAll()
        sampleChange("Sample zeichnen") { s in for (index,value) in drawing where s.pcm.indices.contains(index) { s.pcm[index] = value } }
    }
    func openWorkbench(_ tab: WorkbenchTab) { workbenchTab = tab; WorkbenchWindow.shared.show(store:self) }

    func markBlock() {
        if let anchor = blockAnchor {
            blockStart = min(anchor,selectedRow); blockEnd = max(anchor,selectedRow); blockAnchor = nil
        } else { blockAnchor = selectedRow; blockStart = selectedRow; blockEnd = selectedRow }
    }
    var blockRows: ClosedRange<Int> { if let anchor = blockAnchor { return min(anchor,selectedRow)...max(anchor,selectedRow) }; return min(blockStart,blockEnd)...max(blockStart,blockEnd) }
    var blockChannels: ClosedRange<Int> { blockAllChannels ? 0...3 : selectedChannel...selectedChannel }
    func copyBlock(cut: Bool = false, track: Bool = false, effects: Bool = false) {
        let rows = track ? 0...63 : blockRows, channels = blockChannels
        var block = PatternEditing.copy(pattern,rows:rows,channels:channels)
        if effects { block.cells = block.cells.map { TrackerCell(effect:$0.effect,parameter:$0.parameter) } }
        blockClipboard = block
        if let data = try? JSONEncoder().encode(block) { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:.init("com.protracker.block")) }
        if cut {
            let p = patternIndex
            change("Block ausschneiden") { song in for row in rows { for ch in channels {
                if effects { song.patterns[p][row,ch].effect = 0; song.patterns[p][row,ch].parameter = 0 }
                else { song.patterns[p][row,ch] = TrackerCell() }
            } } }
        }
        status = "Block: \(block.rows) Zeilen × \(block.channels) Spuren"
    }
    func pasteBlock(mix: Bool = false, insert: Bool = false, effects: Bool = false) {
        let data = NSPasteboard.general.data(forType:.init("com.protracker.block"))
        guard let block = data.flatMap({ try? JSONDecoder().decode(PatternBlock.self,from:$0) }) ?? blockClipboard, block.isValid else { return }
        let p = patternIndex, row = selectedRow, ch = selectedChannel
        change("Block einsetzen") { song in
            if insert { PatternEditing.shift(&song.patterns[p],row:row,count:block.rows,channels:ch...min(3,ch+block.channels-1),insert:true,effectsOnly:effects) }
            PatternEditing.paste(block,into:&song.patterns[p],row:row,channel:ch,mix:mix,effectsOnly:effects)
        }
    }
    func shiftRows(insert: Bool, all: Bool = false, effects: Bool = false, count: Int = 1) {
        let p = patternIndex, row = selectedRow, channels = all ? 0...3 : selectedChannel...selectedChannel
        change(insert ? "Zeilen einfügen" : "Zeilen entfernen") { PatternEditing.shift(&$0.patterns[p],row:row,count:count,channels:channels,insert:insert,effectsOnly:effects) }
    }
    func deleteBlock() {
        let p = patternIndex,rows = blockRows,channels = blockChannels
        change("Block löschen") { PatternEditing.shift(&$0.patterns[p],row:rows.lowerBound,count:rows.count,channels:channels,insert:false) }
    }
    func removeInstrumentNotes() {
        let p = patternIndex,channels = blockChannels,sample = selectedSample+1
        change("Instrumentnoten entfernen") { song in for row in 0..<64 { for ch in channels where song.patterns[p][row,ch].sample == sample { song.patterns[p][row,ch].period = 0; song.patterns[p][row,ch].sample = 0 } } }
    }
    func reverseBlock() {
        let p = patternIndex, rows = blockRows, channels = blockChannels, source = pattern
        change("Block umkehren") { song in for row in rows { for ch in channels { song.patterns[p][row,ch] = source[rows.upperBound-(row-rows.lowerBound),ch] } } }
    }
    func transposeBlock(_ amount: Int, selectedInstrumentOnly: Bool = false, wholePattern: Bool = false) {
        let p = patternIndex, rows = wholePattern ? 0...63 : blockRows, channels = wholePattern ? 0...3 : blockChannels, sample = selectedSample+1
        change("Transponieren") { song in for row in rows { for ch in channels {
            let cell = song.patterns[p][row,ch]
            if cell.period > 0 && (!selectedInstrumentOnly || cell.sample == sample) { song.patterns[p][row,ch].period = Notes.period(Notes.index(cell.period)+amount) }
        } } }
    }
    func stretchTrack(expand: Bool) { let p = patternIndex,ch = selectedChannel; change(expand ? "Spur expandieren" : "Spur komprimieren") { PatternEditing.stretch(&$0.patterns[p],channel:ch,expand:expand) } }
    func swapTracks() {
        let p = patternIndex,ch = selectedChannel,to = (selectedChannel+1)%4
        change("Spuren tauschen") { song in for r in 0..<64 { let a = song.patterns[p][r,ch]; song.patterns[p][r,ch] = song.patterns[p][r,to]; song.patterns[p][r,to] = a } }
    }
    func exchangeSamples(move: Bool = false, notesOnly: Bool = false) {
        let from = selectedSample,to = mixSource
        guard from != to else { return }
        change("Samples tauschen/verschieben") { song in
            if !notesOnly {
                let a = song.samples[from]; song.samples[from] = move ? TrackerSample() : song.samples[to]; song.samples[to] = a
            }
            for p in song.patterns.indices { for i in 0..<256 {
                if song.patterns[p].cells[i].sample == from+1 { song.patterns[p].cells[i].sample = to+1 }
                else if !move && song.patterns[p].cells[i].sample == to+1 { song.patterns[p].cells[i].sample = from+1 }
            } }
        }
    }
    func savePatternFile(track: Bool = false) {
        let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.allowedFileTypes = [track ? "pttrack" : "ptpattern"]; panel.nameFieldStringValue = track ? "Track.pttrack" : "Pattern.ptpattern"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let block = PatternEditing.copy(pattern,rows:0...63,channels:track ? selectedChannel...selectedChannel : 0...3)
        do { try JSONEncoder().encode(block).write(to:url,options:.atomic) } catch { report(error) }
    }
    func loadPatternFile() {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.allowedFileTypes = ["pttrack","ptpattern"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) < 100_000 else { throw ModuleError.invalid("Pattern-Datei ist zu groß.") }
            let block = try JSONDecoder().decode(PatternBlock.self,from:Data(contentsOf:url))
            guard block.isValid else { throw ModuleError.invalid("Ungültiges Pattern.") }
            let p = patternIndex,ch = block.channels == 4 ? 0 : selectedChannel
            change("Pattern laden") { PatternEditing.paste(block,into:&$0.patterns[p],row:0,channel:ch) }
        } catch { report(error) }
    }
    func inputMIDINote(_ event: MIDINoteEvent) {
        let id = event.channel*128+event.note
        if !event.on {
            if let channel = midiNoteChannels.removeValue(forKey:id), midiLastPlayed[channel] == id { midiLastPlayed.removeValue(forKey:channel); audio.releasePreview(channel:channel) }
            return
        }
        guard (36..<72).contains(event.note) else { return }
        midiNoteChannels[id] = selectedChannel; midiLastPlayed[selectedChannel] = id
        enterPlayedNote(period:Notes.period(event.note-36),sample:selectedSample,velocity:max(1,event.velocity*64/127),forceRecord:true)
    }
    func enterPlayedNote(period: Int, sample: Int, velocity: Int? = nil, forceRecord: Bool = false) {
        previewModule(module,sample:sample,period:period,channel:selectedChannel,volume:velocity)
        if editMode && (selectedField == 0 || forceRecord) && !countIn {
            var order = liveRecording && playing ? min(playbackOrder,module.orders.count-1) : selectedOrder
            let q = preferences.quantize
            var row = selectedRow
            if liveRecording && playing {
                let fraction = Double(max(0,playbackTick-1))/Double(max(1,currentSpeed))
                row = q == 0 ? playbackRow : Int(((Double(playbackRow)+fraction)/Double(q)).rounded())*q
                if row >= 64 { row -= 64; if !recordPatternOnly { order = (order+1)%module.orders.count } }
            }
            let p = module.orders[order],ch = selectedChannel,r = min(63,max(0,row))
            change("Note eingeben") { song in
                song.patterns[p][r,ch].period = period; song.patterns[p][r,ch].sample = sample+1
                if let velocity, song.patterns[p][r,ch].effect == 0 && song.patterns[p][r,ch].parameter == 0 { song.patterns[p][r,ch].effect = 12; song.patterns[p][r,ch].parameter = velocity }
            }
            if !liveRecording { move(row:editStep) }
        }
        if preferences.multiKeyboard {
            for offset in 1...4 where preferences.enabledChannels[(selectedChannel+offset)%4] { selectedChannel = (selectedChannel+offset)%4; break }
        }
    }
    func toggleLiveRecording() {
        if liveRecording { liveRecording = false; stop() }
        else {
            liveRecording = true; editMode = true; follow = true
            play(pattern:recordPatternOnly)
            status = "Notenaufnahme · Quantize \(preferences.quantize) · Leertaste stoppt"
        }
    }
    func chooseDefaultFolder(sample: Bool) {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.title = sample ? L("Sample-Ordner") : L("Modul-Ordner")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            if sample { preferences.sampleFolderBookmark = data } else { preferences.moduleFolderBookmark = data }
        } catch { report(error) }
    }
    func preferredFolder(sample: Bool) -> URL? {
        guard let data = sample ? preferences.sampleFolderBookmark : preferences.moduleFolderBookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.allowedFileTypes = ["ptconfig"]; panel.nameFieldStringValue = "Protracker.ptconfig"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(preferences).write(to:url,options:.atomic) } catch { report(error) }
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.allowedFileTypes = ["ptconfig"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try JSONDecoder().decode(TrackerPreferences.self,from:Data(contentsOf:url))
            guard value.valid else { throw ModuleError.invalid("Ungültige Konfiguration.") }
            preferences = value
        } catch { report(error) }
    }
    func printSong() {
        var text = module.title+"\n"+L("Positions:")+" "+module.orders.map { String(format:"%02X",$0) }.joined(separator:" ")+"\n\n"
        for p in Set(module.orders).sorted() {
            text += "PATTERN \(String(format:"%02X",p))\n"
            for row in 0..<64 { text += String(format:"%02X",row)+"  "+(0..<4).map { ch in let c = module.patterns[p][row,ch]; return c.noteName+String(format:" %02X ",c.sample)+c.effectName }.joined(separator:"    ")+"\n" }
            text += "\n"
        }
        printText(text,title:module.title)
    }
    func printPresets() { printText(presets.map { "\($0.bank)  \($0.name)  \($0.sample.pcm.count) bytes" }.joined(separator:"\n"),title:L("Preset list")) }
    private func printText(_ text: String,title: String) {
        let view = NSTextView(frame:NSRect(x:0,y:0,width:520,height:100))
        view.font = NSFont.monospacedSystemFont(ofSize:9,weight:.regular); view.string = text
        view.isVerticallyResizable = true; view.textContainer?.containerSize = NSSize(width:520,height:CGFloat.greatestFiniteMagnitude)
        if let container = view.textContainer, let layout = view.layoutManager { layout.ensureLayout(for:container); view.setFrameSize(NSSize(width:520,height:layout.usedRect(for:container).height+40)) }
        let operation = NSPrintOperation(view:view); operation.jobTitle = title; operation.run()
    }
    func exportAllSamples() {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = L("Samples exportieren")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do { for (i,s) in module.samples.enumerated() where !s.pcm.isEmpty {
            // A fresh folder avoids overwriting a user's previous exports.
            let folder = dir.appendingPathComponent("Protracker-Samples-\(exportSessionID)",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try SampleAudio.wav(sample:s).write(to:folder.appendingPathComponent(String(format:"%02d",i+1)+".wav"),options:.atomic)
        }; exportSessionID = UUID().uuidString.prefix(8).description; status = "Alle Samples exportiert" } catch { report(error) }
    }
}
