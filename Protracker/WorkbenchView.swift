import AppKit
import SwiftUI

enum AppPalette {
    static func color(_ hex: String) -> NSColor {
        let value = Int(hex,radix:16) ?? 0
        return NSColor(calibratedRed:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,alpha:1)
    }
    static func hex(_ color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return String(format:"%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))
    }
}

enum WorkbenchTab: String, CaseIterable, Identifiable {
    case sample = "Sampler", pattern = "Edit operations", presets = "Presets · PLST / PED", recording = "Recording", settings = "Setup"
    var id: String { rawValue }
}
@MainActor
final class WorkbenchWindow: NSObject, NSWindowDelegate {
    static let shared = WorkbenchWindow()
    private var window: NSWindow?
    private weak var store: TrackerStore?
    func show(store: TrackerStore) {
        self.store = store
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:780),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = L("Protracker · Workbench"); window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width:1000,height:720)
        window.contentView = NSHostingView(rootView:WorkbenchView(store:store)); window.center()
        self.window = window; window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { store?.recorder.stop(); window = nil }
}

struct WorkbenchView: View {
    @ObservedObject var store: TrackerStore
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(L("PROTRACKER / WORKBENCH")).font(.system(size:15,weight:.bold,design:.monospaced)).tracking(1)
                Spacer()
                Text(store.status.resolved).font(.system(size:10)).foregroundColor(.secondary).lineLimit(1)
            }
            Picker(L("Workspace"),selection:$store.workbenchTab) { ForEach(WorkbenchTab.allCases) { Text(LK($0.rawValue)).tag($0) } }.pickerStyle(SegmentedPickerStyle())
            switch store.workbenchTab {
            case .sample: SampleWorkbench(store:store)
            case .pattern: PatternWorkbench(store:store)
            case .presets: PresetWorkbench(store:store)
            case .recording: RecordingWorkbench(store:store,recorder:store.recorder)
            case .settings: SettingsWorkbench(store:store,midi:store.midi)
            }
            Spacer(minLength:0)
        }.id(store.language).environment(\.locale,store.language.locale).padding(20).background(Color(red:0.07,green:0.08,blue:0.095)).preferredColorScheme(.dark).frame(minWidth:960,minHeight:680)
    }
}

struct SampleWorkbench: View {
    @ObservedObject var store: TrackerStore
    var body: some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                Picker(L("Sample"),selection:$store.selectedSample) {
                    ForEach(0..<31,id:\.self) { Text(String(format:"%02X",$0+1)+" · "+store.module.samples[$0].name).tag($0) }
                }.frame(width:290)
                Spacer()
                Button(L("Import"),action:store.importSample)
                Button(L("Export WAV / 8SVX / raw"),action:store.exportSample).disabled(store.sample.pcm.isEmpty)
                Button(L("▶ Preview")) { store.preview() }.disabled(store.sample.pcm.isEmpty)
                Button(L("■ Stop"),action:store.stop)
            }
            InteractiveWaveform(store:store).frame(minHeight:190,maxHeight:280).overlay(Rectangle().stroke(Color.white.opacity(0.15),lineWidth:1))
            HStack {
                Text(L("\(store.sample.pcm.count) bytes · drag to select · double-click: select all")).font(.system(size:10,design:.monospaced)).foregroundColor(.secondary)
                Spacer()
                Toggle(L("Draw"),isOn:$store.sampleDrawMode).toggleStyle(CheckboxToggleStyle())
                Button(L("Zoom range")) { if !store.sampleRange.isEmpty { store.sampleZoomStart = store.sampleRange.lowerBound; store.sampleZoomEnd = store.sampleRange.upperBound } }
                Button(L("Show all")) { store.sampleZoomStart = 0; store.sampleZoomEnd = 0 }
            }
            HStack(spacing:14) {
                integerField("From",value:$store.sampleSelectionStart,range:0...store.sample.pcm.count)
                integerField("To",value:$store.sampleSelectionEnd,range:0...store.sample.pcm.count)
                Text(L("\(store.sampleRange.count) selected")).font(.system(size:11,design:.monospaced)).frame(width:115)
                Button(L("All"),action:store.selectAllSamples)
                Button(L("Loop from range"),action:store.setLoopFromSelection)
                Spacer()
                Button(L("Undo")) { store.undoManager.undo() }.disabled(!store.undoManager.canUndo)
                Button(L("Redo")) { store.undoManager.redo() }.disabled(!store.undoManager.canRedo)
            }
            HStack {
                Button(L("Cut")) { store.copySample(cut:true) }
                Button(L("Copy")) { store.copySample() }
                Button(L("Paste"),action:store.pasteSample).disabled(store.sampleClipboard.isEmpty)
                Button(L("Delete"),action:store.deleteSampleRange)
                Button(L("Crop"),action:store.cropSample)
                Button(L("Swap buffer"),action:store.swapSampleBuffer)
                Divider().frame(height:20)
                Button(L("Reverse")) { store.sampleOperation(.reverse) }
                Button(L("Normalize")) { store.sampleOperation(.normalize) }
                Button(L("Silence")) { store.sampleOperation(.silence) }
                Button(L("Invert")) { store.sampleOperation(.invert) }
                Button(L("DC offset")) { store.sampleOperation(.removeDC) }
            }.disabled(store.sample.pcm.isEmpty)
            HStack {
                Text(L("Ramp"))
                TextField(L("From"),value:$store.rampFrom,formatter:NumberFormatter()).frame(width:35)
                Text(L("→"))
                TextField(L("To"),value:$store.rampTo,formatter:NumberFormatter()).frame(width:35)
                Button(L("Ramp")) { store.sampleOperation(.ramp) }
                Button(L("Fade in")) { store.sampleOperation(.fadeIn) }
                Button(L("Fade out")) { store.sampleOperation(.fadeOut) }
                Text(L("Gain"))
                Slider(value:$store.sampleGain,in:0...4).frame(width:95)
                Text(String(format:"%.0f%%",store.sampleGain*100)).frame(width:42)
                Button(L("Apply")) { store.sampleOperation(.gain) }
                Button(L("Low-pass")) { store.sampleOperation(.lowPass) }
                Button(L("High-pass")) { store.sampleOperation(.highPass) }
                Spacer()
            }.disabled(store.sample.pcm.isEmpty)
            HStack {
                Text(L("Echo / crossfade"))
                Slider(value:$store.echoDelay,in:0.001...0.5).frame(width:100)
                Text(String(format:"%d ms",Int(store.echoDelay*1000))).frame(width:50)
                Slider(value:$store.echoFeedback,in:0...0.95).frame(width:80)
                Button(L("Echo")) { store.sampleOperation(.echo) }
                Button(L("Crossfade loop")) { store.sampleOperation(.crossfade) }
                Spacer()
                Button(L("Pitch +12")) { store.resampleSample(2) }
                Button(L("Pitch −12")) { store.resampleSample(0.5) }
                Button(L("+1")) { store.resampleSample(pow(2,1.0/12)) }
                Button(L("−1")) { store.resampleSample(pow(2,-1.0/12)) }
            }.disabled(store.sample.pcm.isEmpty)
            HStack {
                Picker(L("Mix source"),selection:$store.mixSource) { ForEach(0..<31,id:\.self) { Text(String(format:"%02X",$0+1)).tag($0) } }.frame(width:115)
                Toggle(L("Half volume"),isOn:$store.halfMix).toggleStyle(CheckboxToggleStyle())
                Button(L("Mix at cursor"),action:store.mixSample)
                Divider().frame(height:20)
                Picker(L("Chord"),selection:$store.chordType) { ForEach(Array(["Major","Minor","Sus4","Major 7","Minor 7","Major 6","Minor 6"].enumerated()),id:\.offset) { Text(LK($0.element)).tag($0.offset) } }.frame(width:155).onChange(of:store.chordType) { index in
                    let values = [[0,4,7,-1],[0,3,7,-1],[0,5,7,-1],[0,4,7,11],[0,3,7,10],[0,4,7,9],[0,3,7,9]]
                    store.chordNotes = values[index]
                }
                Button(L("Render chord"),action:store.createChord)
                Spacer()
                Button(L("Add to presets"),action:store.addPreset)
            }.disabled(store.sample.pcm.isEmpty)
            HStack {
                ForEach(0..<4,id:\.self) { index in
                    Picker(L("Chord \(index+1)"),selection:$store.chordNotes[index]) { Text(L("Off")).tag(-1); ForEach(0..<36,id:\.self) { Text(Notes.name(Notes.period($0))).tag($0) } }.labelsHidden().frame(width:65)
                }
                Picker(L("New waveform"),selection:$store.waveShape) { ForEach(["Sine","Square","Saw","Triangle","Noise"],id:\.self) { Text(LK($0)).tag($0) } }.frame(width:180)
                Button(L("Generate"),action:store.generateWave)
                Button(L("Clear")) { store.sampleChange("Sample leeren") { $0 = TrackerSample() } }
                Spacer()
                Text(L("All edits apply to the selection, or the whole sample if nothing is selected.")).font(.system(size:10)).foregroundColor(.secondary)
            }
        }.font(.system(size:11))
    }
    private func integerField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack { Text(LK(title)); TextField(LK(title),value:Binding(get:{ value.wrappedValue },set:{ value.wrappedValue = min(range.upperBound,max(range.lowerBound,$0)) }),formatter:NumberFormatter()).frame(width:68) }
    }
}

struct InteractiveWaveform: NSViewRepresentable {
    @ObservedObject var store: TrackerStore
    func makeNSView(context: Context) -> EditableWaveView { EditableWaveView(store:store) }
    func updateNSView(_ view: EditableWaveView, context: Context) { view.setAccessibilityLabel(L("Sample waveform. Drag to select; enable Draw to edit samples.")); view.needsDisplay = true }
}
@MainActor
final class EditableWaveView: NSView {
    let store: TrackerStore
    private var anchor = 0
    private var lastDraw: (Int,Int8)?
    init(store: TrackerStore) { self.store = store; super.init(frame:.zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(L("Sample waveform. Drag to select; enable Draw to edit samples.")) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    var visible: Range<Int> {
        let count = store.sample.pcm.count
        if store.sampleZoomEnd > store.sampleZoomStart {
            let start = min(count,store.sampleZoomStart), end = min(count,store.sampleZoomEnd)
            if end > start { return start..<end }
        }
        return 0..<count
    }
    private func samplePosition(_ event: NSEvent) -> (Int,Int8) {
        let p = convert(event.locationInWindow,from:nil), r = visible
        let index = min(r.upperBound,max(r.lowerBound,r.lowerBound+Int(p.x/max(1,bounds.width)*Double(r.count))))
        return (index,SampleEditing.clamp((p.y/max(1,bounds.height)*2-1)*127))
    }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite:0.035,alpha:1).setFill(); bounds.fill()
        let r = visible, center = bounds.midY
        NSColor.white.withAlphaComponent(0.1).setStroke(); let grid = NSBezierPath()
        grid.move(to:NSPoint(x:0,y:center)); grid.line(to:NSPoint(x:bounds.width,y:center)); grid.stroke()
        guard !r.isEmpty else { return }
        let selected = store.sampleRange.clamped(to:r)
        if !selected.isEmpty {
            NSColor.systemOrange.withAlphaComponent(0.15).setFill()
            NSRect(x:Double(selected.lowerBound-r.lowerBound)/Double(r.count)*bounds.width,y:0,width:Double(selected.count)/Double(r.count)*bounds.width,height:bounds.height).fill()
        }
        let path = NSBezierPath(), pcm = store.sample.pcm, pixels = max(1,Int(bounds.width))
        for x in 0..<pixels {
            let start = r.lowerBound+x*r.count/pixels, end = min(r.upperBound,max(start+1,r.lowerBound+(x+1)*r.count/pixels))
            var lo = 127, hi = -128
            for i in start..<end { let v = Int(store.sampleDrawing[i] ?? pcm[i]); lo = min(lo,v); hi = max(hi,v) }
            let bottom: CGFloat = center+CGFloat(lo)/128*center*0.9
            let top: CGFloat = center+CGFloat(hi)/128*center*0.9+0.8
            path.move(to:NSPoint(x:CGFloat(x),y:bottom)); path.line(to:NSPoint(x:CGFloat(x),y:top))
        }
        NSColor.systemOrange.setStroke(); path.lineWidth = 1; path.stroke()
        if store.sample.loops {
            NSColor.systemTeal.setStroke(); let loop = NSBezierPath()
            for point in [store.sample.loopStart,store.sample.loopStart+store.sample.loopLength] where r.contains(point) {
                let x = Double(point-r.lowerBound)/Double(r.count)*bounds.width
                loop.move(to:NSPoint(x:x,y:0)); loop.line(to:NSPoint(x:x,y:bounds.height))
            }
            loop.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { store.selectAllSamples(); needsDisplay = true; return }
        let (index,value) = samplePosition(event); anchor = index
        if store.sampleDrawMode { lastDraw = (index,value); store.drawSample(at:index,value:value) }
        else { store.setSampleSelection(index..<index) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let (index,value) = samplePosition(event)
        if store.sampleDrawMode {
            if let (previous,old) = lastDraw {
                for n in min(previous,index)...max(previous,index) {
                    let t = previous == index ? 1 : Double(n-previous)/Double(index-previous)
                    store.drawSample(at:n,value:SampleEditing.clamp(Double(old)+(Double(value)-Double(old))*t))
                }
            }
            lastDraw = (index,value)
        } else { store.setSampleSelection(min(anchor,index)..<max(anchor,index)) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if store.sampleDrawMode { store.commitSampleDrawing(); lastDraw = nil }; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers {
            switch key { case "a": store.selectAllSamples(); case "c": store.copySample(); case "x": store.copySample(cut:true); case "v": store.pasteSample(); case "z": event.modifierFlags.contains(.shift) ? store.undoManager.redo() : store.undoManager.undo(); default: super.keyDown(with:event) }
        } else if event.keyCode == 51 { store.deleteSampleRange() }
        else if event.keyCode == 49 { store.preview() }
        else if event.keyCode == 53 { store.stop() }
        else { super.keyDown(with:event) }
    }
    @objc func copy(_ sender: Any?) { store.copySample() }
    @objc func cut(_ sender: Any?) { store.copySample(cut:true) }
    @objc func paste(_ sender: Any?) { store.pasteSample() }
    override func scrollWheel(with event: NSEvent) {
        let r = visible
        guard r.count < store.sample.pcm.count else { return }
        let offset = Int(event.scrollingDeltaX+event.scrollingDeltaY)*max(1,r.count/200)
        let start = min(store.sample.pcm.count-r.count,max(0,r.lowerBound+offset))
        store.sampleZoomStart = start; store.sampleZoomEnd = start+r.count
    }
}

struct PatternWorkbench: View {
    @ObservedObject var store: TrackerStore
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text(L("Block / track editing")).font(.title2)
            HStack {
                Stepper(L("First row: \(store.blockStart)"),value:$store.blockStart,in:0...63)
                Stepper(L("Last row: \(store.blockEnd)"),value:$store.blockEnd,in:0...63)
                Toggle(L("All channels"),isOn:$store.blockAllChannels)
            }
            Text(L("Channel \(store.selectedChannel+1) · pattern \(store.patternIndex) · \(store.blockRows.count) rows selected")).foregroundColor(.secondary)
            HStack {
                Button(L("Mark at cursor"),action:store.markBlock)
                Button(L("Cut")) { store.copyBlock(cut:true) }; Button(L("Copy")) { store.copyBlock() }
                Button(L("Paste")) { store.pasteBlock() }; Button(L("Insert paste")) { store.pasteBlock(insert:true) }
                Button(L("Mix paste")) { store.pasteBlock(mix:true) }; Button(L("Reverse"),action:store.reverseBlock)
            }
            HStack {
                Button(L("−12")) { store.transposeBlock(-12) }; Button(L("−1")) { store.transposeBlock(-1) }
                Button(L("+1")) { store.transposeBlock(1) }; Button(L("+12")) { store.transposeBlock(12) }
                Button(L("Insert row")) { store.shiftRows(insert:true,all:store.blockAllChannels) }
                Button(L("Delete row")) { store.shiftRows(insert:false,all:store.blockAllChannels) }
                Button(L("Delete block"),action:store.deleteBlock)
            }
            HStack {
                Button(L("Copy track")) { store.copyBlock(track:true) }; Button(L("Copy effects")) { store.copyBlock(track:true,effects:true) }
                Button(L("Paste effects")) { store.pasteBlock(effects:true) }
                Button(L("Expand 2×")) { store.stretchTrack(expand:true) }; Button(L("Contract ½")) { store.stretchTrack(expand:false) }
                Button(L("Swap adjacent tracks"),action:store.swapTracks)
            }
            Divider()
            HStack {
                Button(L("Load pattern / track"),action:store.loadPatternFile)
                Button(L("Save pattern")) { store.savePatternFile() }; Button(L("Save track")) { store.savePatternFile(track:true) }
                Button(L("Export all samples"),action:store.exportAllSamples)
                Button(L("Print song"),action:store.printSong)
            }
            HStack {
                Text(L("Sample \(store.selectedSample+1) →"))
                Picker(L("Destination"),selection:$store.mixSource) { ForEach(0..<31,id:\.self) { Text(L("\($0+1)")).tag($0) } }.frame(width:130)
                Button(L("Exchange samples")) { store.exchangeSamples() }
                Button(L("Move sample")) { store.exchangeSamples(move:true) }
                Button(L("Replace note instrument")) { store.exchangeSamples(move:true,notesOnly:true) }
                Button(L("Delete instrument notes"),action:store.removeInstrumentNotes)
            }
            Divider()
            HStack {
                Button(store.liveRecording ? L("■ Stop note recording") : L("● Record notes"),action:store.toggleLiveRecording)
                Toggle(L("Pattern only"),isOn:$store.recordPatternOnly)
                Stepper(L("Quantize: \(store.preferences.quantize)"),value:$store.preferences.quantize,in:0...16)
                Toggle(L("Multi-keyboard"),isOn:$store.preferences.multiKeyboard)
            }
            Text(L("Control+B marks a block. Control+C/X/P copies, cuts and pastes. F3–F5 operate on samples; Shift+F3–F5 on tracks; Option+F3–F5 on patterns. Note recording uses the pattern keyboard while playback runs.")).font(.system(size:12)).foregroundColor(.secondary)
            Spacer()
            HStack { Button(L("Undo")) { store.undoManager.undo() }; Button(L("Redo")) { store.undoManager.redo() } }
        }.font(.system(size:12))
    }
}

struct PresetWorkbench: View {
    @ObservedObject var store: TrackerStore
    @State private var search = ""
    @State private var bank = "All banks"
    @State private var favorites = false
    @State private var selected: UUID?
    var filtered: [PresetEntry] {
        store.presets.filter { (bank == "All banks" || $0.bank == bank) && (!favorites || $0.favorite) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bank.localizedCaseInsensitiveContains(search)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                TextField(L("Search presets"),text:$search)
                Picker(L("Bank"),selection:$bank) { Text(L("All banks")).tag("All banks"); ForEach(Array(Set(store.presets.map(\.bank))).sorted(),id:\.self) { Text($0).tag($0) } }.frame(width:220)
                Toggle(L("Favorites"),isOn:$favorites).toggleStyle(CheckboxToggleStyle())
            }
            HStack {
                Button(L("Add files / module")) { store.importPresets() }
                Button(L("Add folder")) { store.importPresets(folder:true) }
                Button(L("Add current sample"),action:store.addPreset)
                Spacer()
                Button(L("Import list"),action:store.openPresetList)
                Button(L("Export list"),action:store.savePresetList)
                Button(L("Print"),action:store.printPresets)
            }.disabled(store.libraryImporting)
            if store.libraryImporting { Text(L("Importing samples…")).foregroundColor(.orange) }
            List(selection:$selected) {
                ForEach(filtered) { entry in
                    HStack {
                        Text(entry.favorite ? "★" : "☆").foregroundColor(.orange).frame(width:18)
                        Text(entry.name).frame(maxWidth:.infinity,alignment:.leading)
                        Text(entry.bank).foregroundColor(.secondary).frame(width:160,alignment:.leading)
                        Text(L("\(entry.sample.pcm.count) bytes")).font(.system(.caption,design:.monospaced)).frame(width:100,alignment:.trailing)
                    }.tag(entry.id).padding(.vertical,3)
                    .onTapGesture(count:2) { store.loadPreset(entry.id) }
                }
            }.frame(minHeight:260)
            if let id = selected, let entry = store.presets.first(where:{ $0.id == id }) {
                HStack {
                    TextField(L("Name"),text:Binding(get:{ store.presets.first(where:{ $0.id == id })?.name ?? "" },set:{ store.renamePreset(id,name:$0) }))
                    TextField(L("Bank"),text:Binding(get:{ store.presets.first(where:{ $0.id == id })?.bank ?? "" },set:{ store.renamePreset(id,bank:$0) })).frame(width:180)
                    Button(entry.favorite ? L("Unfavorite") : L("Favorite")) { store.togglePresetFavorite(id) }
                    Button(L("▶ Preview")) { store.loadPreset(id,preview:true) }
                    Button(L("Load into sample \(store.selectedSample+1)")) { store.loadPreset(id) }
                    Button(L("Remove")) { store.removePreset(id); selected = nil }
                }
            }
            HStack {
                Text(L("\(filtered.count) shown / \(store.presets.count) presets · saved automatically")).font(.system(size:11)).foregroundColor(.secondary)
                Spacer()
                if bank != "All banks" { Button(L("Remove bank")) { store.removePresetBank(bank); bank = "All banks" } }
            }
        }
    }
}

struct RecordingWorkbench: View {
    @ObservedObject var store: TrackerStore
    @ObservedObject var recorder: SampleRecorder
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            Text(L("Record a sample")).font(.title)
            Text(L("The microphone or audio interface selected as your Mac’s default input is used. Nothing is recorded until you press Start.")).foregroundColor(.secondary)
            HStack(spacing:25) {
                Text(String(format:"%04.1f s",recorder.seconds)).font(.system(size:48,design:.monospaced))
                GeometryReader { geo in Rectangle().fill(Color.green).frame(width:geo.size.width*CGFloat(min(1,recorder.level))) }.frame(height:12).background(Color.black)
            }.frame(height:70)
            Text(recorder.message.resolved).foregroundColor(recorder.recording ? .orange : .secondary)
            HStack {
                Button(L("● Start recording"),action:recorder.start).disabled(recorder.recording || recorder.starting || recorder.deviceBusy)
                Button(L("■ Stop"),action:recorder.stop).disabled(!recorder.recording && !recorder.starting)
                Button(L("Use take in sample \(store.selectedSample+1)")) {
                    do { let sample = try recorder.take(); store.sampleChange("Aufnahme übernehmen") { $0 = sample }; store.selectAllSamples(); store.workbenchTab = .sample }
                    catch { store.report(error) }
                }.disabled(!recorder.hasTake || recorder.recording)
            }
            Text(L("Each take is limited to \(String(format:"%.1f",recorder.limit)) seconds to fit an Amiga sample. The Sampler provides trimming, drawing, loops, filters, fades, echo and resampling.")).font(.system(size:12)).foregroundColor(.secondary)
            Divider()
            Text(L("Record notes into the pattern")).font(.headline)
            HStack {
                Button(store.liveRecording ? L("Stop note recording") : L("Start note recording"),action:store.toggleLiveRecording)
                Toggle(L("Pattern only"),isOn:$store.recordPatternOnly)
                Stepper(L("Count-in: \(store.preferences.countInBeats) beats"),value:$store.preferences.countInBeats,in:0...8)
                Stepper(L("Quantize: \(store.preferences.quantize) rows"),value:$store.preferences.quantize,in:0...16)
            }
            Text(L("After starting note recording, return to the main pattern window and play notes on the keyboard. The cursor follows playback.")).font(.system(size:12)).foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct SettingsWorkbench: View {
    @ObservedObject var store: TrackerStore
    @ObservedObject var midi: MIDIKeyboard
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Picker(L("Language"),selection:$store.language) { ForEach(AppLanguage.allCases) { Text($0.title).tag($0) } }.frame(width:270)
                    Text(L("Some macOS controls use the new language after restarting the app.")).font(.system(size:10)).foregroundColor(.secondary)
                }

                Text(L("Palette & folders")).font(.headline)
                HStack {
                    ColorPicker(L("Accent"),selection:Binding(get:{ Color(AppPalette.color(store.preferences.accentColor)) },set:{ store.preferences.accentColor = AppPalette.hex($0) }),supportsOpacity:false)
                    ColorPicker(L("Scopes"),selection:Binding(get:{ Color(AppPalette.color(store.preferences.scopeColor)) },set:{ store.preferences.scopeColor = AppPalette.hex($0) }),supportsOpacity:false)
                    ColorPicker(L("Pattern background"),selection:Binding(get:{ Color(AppPalette.color(store.preferences.backgroundColor)) },set:{ store.preferences.backgroundColor = AppPalette.hex($0) }),supportsOpacity:false)
                }
                HStack {
                    Button(L("Module folder…")) { store.chooseDefaultFolder(sample:false) }
                    Text(store.preferredFolder(sample:false)?.lastPathComponent ?? L("System default")).foregroundColor(.secondary)
                    Button(L("Sample folder…")) { store.chooseDefaultFolder(sample:true) }
                    Text(store.preferredFolder(sample:true)?.lastPathComponent ?? L("System default")).foregroundColor(.secondary)
                }
                Divider()
                Text(L("Keyboard & display")).font(.headline)
                HStack { Toggle(L("Classic Space / Return keys"),isOn:$store.preferences.classicKeys); Toggle(L("Decimal rows"),isOn:$store.preferences.decimalRows); Toggle(L("Show zeroes"),isOn:$store.preferences.showZeroes); Toggle(L("Flat note names"),isOn:$store.preferences.flats) }
                HStack { Toggle(L("Multi-keyboard"),isOn:$store.preferences.multiKeyboard); ForEach(0..<4,id:\.self) { ch in Toggle(L("CH \(ch+1)"),isOn:$store.preferences.enabledChannels[ch]) } }
                HStack {
                    Toggle(L("Split keyboard"),isOn:$store.preferences.splitKeyboard)
                    Stepper(L("Upper sample: \(store.preferences.splitSample+1)"),value:$store.preferences.splitSample,in:0...30)
                    Stepper(L("Upper octave: \(store.preferences.splitOctave)"),value:$store.preferences.splitOctave,in:1...3)
                }
                Divider()
                HStack { Toggle(L("MIDI keyboard"),isOn:$store.preferences.midiEnabled); Text(midi.status.resolved).foregroundColor(.secondary); Spacer() }
                Text(L("MIDI notes C2–B4 map to the three tracker octaves; note velocity is recorded as volume.")).font(.system(size:11)).foregroundColor(.secondary)
                Text(L("Playback & recording")).font(.headline)
                HStack { Toggle(L("PAL clock"),isOn:$store.preferences.palClock); Toggle(L("4× resampling"),isOn:$store.preferences.interpolation); Toggle(L("A500 filter"),isOn:$store.amigaFilter); Toggle(L("Metronome"),isOn:$store.preferences.metronome) }
                HStack { Stepper(L("Metronome: every \(store.preferences.metronomeRows) rows"),value:$store.preferences.metronomeRows,in:1...16); Stepper(L("Count-in: \(store.preferences.countInBeats) beats"),value:$store.preferences.countInBeats,in:0...8) }
                HStack { Stepper(L("Default BPM: \(store.preferences.defaultBPM)"),value:$store.preferences.defaultBPM,in:32...255); Stepper(L("Default speed: \(store.preferences.defaultSpeed)"),value:$store.preferences.defaultSpeed,in:1...31); Stepper(L("WAV limit: \(store.preferences.exportMinutes) min"),value:$store.preferences.exportMinutes,in:1...120) }
                Toggle(L("Keep current sample bank when opening a song"),isOn:$store.preferences.keepSampleBank)
                Toggle(L("CIA timing for this song"),isOn:Binding(get:{ store.module.ciaTiming },set:{ v in store.change("Timing") { $0.ciaTiming = v } }))
                Toggle(L("LED filter at song start"),isOn:Binding(get:{ store.module.filterEnabled },set:{ v in store.change("Startfilter") { $0.filterEnabled = v } }))
                Text(L("Song comment (saved in MODL)")).font(.headline)
                TextEditor(text:Binding(get:{ store.module.comment },set:{ v in store.change("Kommentar") { $0.comment = v } })).frame(height:95)
                Divider()
                HStack {
                    Button(L("Import configuration"),action:store.importSettings)
                    Button(L("Export configuration"),action:store.exportSettings)
                    Button(L("Restore defaults")) { store.preferences = TrackerPreferences(); store.masterVolume = 0.8; store.stereo = 0.8; store.amigaFilter = true }
                    Spacer()
                    Text(L("Preferences are saved automatically.")).foregroundColor(.secondary)
                }
                Text(L("Classic shortcuts follow the original help file where possible. macOS keeps Command shortcuts for opening, saving and undo. F-keys may require Fn. Amiga-specific disk, screen and printer controls are replaced by macOS dialogs.")).font(.system(size:12)).foregroundColor(.secondary)
            }.padding(6)
        }.toggleStyle(CheckboxToggleStyle()).font(.system(size:12))
    }
}
