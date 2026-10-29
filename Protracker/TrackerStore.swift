import AppKit
import Combine
import SwiftUI

@MainActor
final class TrackerStore: ObservableObject {
    static let shared = TrackerStore()
    @Published var module: TrackerModule
    @Published var selectedOrder = 0
    @Published var selectedRow = 0
    @Published var selectedChannel = 0
    @Published var selectedField = 0
    @Published var selectedSample = 0 { didSet { sampleSelectionStart = 0; sampleSelectionEnd = 0; sampleZoomStart = 0; sampleZoomEnd = 0 } }
    @Published var editMode = false
    @Published var octave = 2
    @Published var editStep = 1
    @Published var follow = true
    @Published var playing = false
    @Published var audioStarting = false
    var audioRequestID: UUID?
    var previewGeneration = UUID()
    @Published var playbackRow = 0
    @Published var playbackOrder = 0
    @Published var currentBPM = 125
    @Published var currentSpeed = 6
    @Published var elapsed = 0.0
    @Published var levels = Array(repeating: Float(0), count: 4)
    @Published var scopes = Array(repeating: Array(repeating: Float(0), count: 128), count: 4)
    @Published var muted = Array(repeating: false, count: 4) { didSet { configureAudio() } }
    @Published var masterVolume: Double = 0.8 { didSet { configureAudio() } }
    @Published var stereo: Double = 0.8 { didSet { configureAudio() } }
    @Published var amigaFilter = true { didSet { configureAudio() } }
    @Published var status: AppText = "Demo bereit · Leertaste startet · Return aktiviert Edit"
    @Published var isDirty = false
    @Published var exporting = false
    @Published var showsHelp = false
    @Published var fileURL: URL?
    @Published var preferences = TrackerPreferences.load() { didSet { preferences.save(); configureAudio() } }
    @Published var language = L10n.language { didSet { L10n.setLanguage(language) } }
    @Published var workbenchTab = WorkbenchTab.sample
    @Published var sampleSelectionStart = 0
    @Published var sampleSelectionEnd = 0
    @Published var sampleZoomStart = 0
    @Published var sampleZoomEnd = 0
    @Published var sampleDrawMode = false
    @Published var sampleGain = 1.5
    @Published var rampFrom = 0.0
    @Published var rampTo = 1.0
    @Published var chordNotes = [0,4,7,-1]
    @Published var echoDelay = 0.1
    @Published var echoFeedback = 0.4
    @Published var waveShape = "Sine"
    @Published var chordType = 0
    @Published var mixSource = 1
    @Published var halfMix = true
    @Published var blockAnchor: Int?
    @Published var blockStart = 0
    @Published var blockEnd = 0
    @Published var blockAllChannels = false
    @Published var liveRecording = false
    @Published var recordPatternOnly = false
    @Published var countIn = false
    @Published var presets: [PresetEntry] = [] { didSet { persistLibrary() } }
    @Published var libraryImporting = false
    let recorder = SampleRecorder()
    let midi = MIDIKeyboard()
    var midiNoteChannels: [Int:Int] = [:]
    var midiLastPlayed: [Int:Int] = [:]
    var playbackTick = 0
    var sampleClipboard: [Int8] = []
    var sampleDrawing: [Int:Int8] = [:]
    var blockClipboard: PatternBlock?
    var storedRows = [0,16,32,48,63]
    var effectMacros = Array(repeating:TrackerCell(),count:10)
    var librarySaveTask: DispatchWorkItem?
    let librarySaveQueue = DispatchQueue(label:"Protracker.library",qos:.utility)
    var exportSessionID = UUID().uuidString.prefix(8).description
    let undoManager = UndoManager()
    let audio = AudioDriver()
    private var savedModule: TrackerModule
    private var ticker: AnyCancellable?
    private var clipboard: TrackerPattern?
    var patternIndex: Int { module.orders[min(selectedOrder,module.orders.count-1)] }
    var pattern: TrackerPattern { module.patterns[patternIndex] }
    var sample: TrackerSample { module.samples[selectedSample] }
    var timeLabel: String { String(format:"%02d:%02d",Int(elapsed)/60,Int(elapsed)%60) }

    init() {
        let demo = DemoModule.make()
        module = demo; savedModule = demo
        audio.update(demo)
        let defaults = UserDefaults.standard
        if defaults.object(forKey:"tracker.volume") != nil { masterVolume = defaults.double(forKey:"tracker.volume") }
        if defaults.object(forKey:"tracker.stereo") != nil { stereo = defaults.double(forKey:"tracker.stereo") }
        if defaults.object(forKey:"tracker.a500") != nil { amigaFilter = defaults.bool(forKey:"tracker.a500") }
        midi.onNote = { [weak self] event in self?.inputMIDINote(event) }
        loadLibrary(); configureAudio()
        ticker = Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.pollAudio() }
    }
    func change(_ name: String, _ body: (inout TrackerModule) -> Void) {
        var next = module; body(&next)
        guard next != module else { return }
        apply(next, name: name)
    }
    private func apply(_ next: TrackerModule, name: String) {
        let old = module
        undoManager.registerUndo(withTarget:self) { target in target.apply(old,name:name) }
        undoManager.setActionName(LK(name))
        module = next; isDirty = module != savedModule
        selectedOrder = min(selectedOrder,module.orders.count-1)
        audio.update(module)
    }
    func sampleChange(_ name: String, _ body: (inout TrackerSample) -> Void) {
        let index = selectedSample
        change(name) { body(&$0.samples[index]); $0.samples[index].validate() }
    }
    func configureAudio() {
        midi.setEnabled(preferences.midiEnabled)
        audio.configure(volume:Float(masterVolume),stereo:Float(stereo),filter:amigaFilter,muted:muted,preferences:preferences)
        UserDefaults.standard.set(masterVolume,forKey:"tracker.volume")
        UserDefaults.standard.set(stereo,forKey:"tracker.stereo")
        UserDefaults.standard.set(amigaFilter,forKey:"tracker.a500")
    }
    private func pollAudio() {
        let snap = audio.snapshot()
        if playing != snap.playing { playing = snap.playing }
        if levels != snap.levels { levels = snap.levels }
        if scopes != snap.scopes { scopes = snap.scopes }
        if countIn != snap.countIn { countIn = snap.countIn }
        playbackTick = snap.tick
        if !snap.playing && liveRecording && !audioStarting { liveRecording = false }
        if elapsed != snap.seconds { elapsed = snap.seconds }
        if playbackOrder != snap.order { playbackOrder = snap.order }
        if playbackRow != snap.row { playbackRow = snap.row }
        let bpm = snap.playing ? snap.bpm : module.initialBPM, speed = snap.playing ? snap.speed : module.initialSpeed
        if currentBPM != bpm { currentBPM = bpm }
        if currentSpeed != speed { currentSpeed = speed }
        if snap.playing && follow {
            let order = min(snap.order,module.orders.count-1)
            if selectedOrder != order { selectedOrder = order }
            if selectedRow != snap.row { selectedRow = snap.row }
        }
    }
    func play(pattern: Bool = false, fromCursor: Bool = false) {
        let id = UUID(); audioRequestID = id; audioStarting = true
        status = "Audio wird gestartet …"
        configureAudio()
        audio.playAsync(module:module,order:selectedOrder,row:fromCursor ? selectedRow : 0,pattern:pattern,countIn:liveRecording ? preferences.countInBeats : 0) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.audioRequestID == id else { return }
                self.audioStarting = false
                switch result {
                case .success: self.playing = true; self.status = pattern ? "Pattern-Wiedergabe" : "Song-Wiedergabe"
                case .failure(let error): self.status = .verbatim(error.localizedDescription); self.liveRecording = false
                }
            }
        }
    }
    func togglePlay() { if playing || audioStarting { stop() } else { play() } }
    func stop() { previewGeneration = UUID(); audioRequestID = nil; audioStarting = false; audio.stop(); playing = false; liveRecording = false; status = "Gestoppt" }
    func preview(period: Int? = nil) { previewModule(module,sample:selectedSample,period:period ?? Notes.period((octave-1)*12),channel:selectedChannel) }
    func previewModule(_ song: TrackerModule, sample: Int, period: Int, channel: Int, volume: Int? = nil) {
        let generation = previewGeneration
        audio.previewAsync(module:song,sample:sample,period:period,channel:channel,volume:volume) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                if case .failure(let error) = result { self.status = .verbatim(error.localizedDescription) }
            }
        }
    }
    func selectOrder(_ index: Int) { selectedOrder = min(max(0,index),module.orders.count-1); selectedRow = 0 }
    func setOrderPattern(_ value: Int) {
        let order = selectedOrder, value = min(127,max(0,value))
        change("Pattern zuweisen") { $0.ensurePattern(value); $0.orders[order] = value }
    }
    func addOrder() {
        guard module.orders.count < 128 else { return }
        let next = selectedOrder+1, value = patternIndex
        change("Position hinzufügen") { $0.orders.insert(value, at: next) }; selectedOrder = next
    }
    func removeOrder() {
        guard module.orders.count > 1 else { return }
        let index = selectedOrder
        change("Position entfernen") { $0.orders.remove(at:index) }
    }
    func duplicatePattern() {
        guard module.patterns.count < 128, module.orders.count < 128 else { return }
        let source = pattern, index = module.patterns.count, order = selectedOrder+1
        change("Pattern duplizieren") { $0.patterns.append(source); $0.orders.insert(index,at:order) }
        selectedOrder = order
    }
    func copyPattern() {
        clipboard = pattern
        if let data = try? JSONEncoder().encode(pattern) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data,forType:NSPasteboard.PasteboardType("com.protracker.pattern"))
        }
        status = "Pattern \(String(format:"%02X",patternIndex)) kopiert"
    }
    func pastePattern() {
        let data = NSPasteboard.general.data(forType:NSPasteboard.PasteboardType("com.protracker.pattern"))
        let copied = data.flatMap { try? JSONDecoder().decode(TrackerPattern.self,from:$0) } ?? clipboard
        guard let copied, copied.cells.count == 256,
              copied.cells.allSatisfy({ (0...4095).contains($0.period) && (0...31).contains($0.sample) && (0...15).contains($0.effect) && (0...255).contains($0.parameter) }) else { return }
        let p = patternIndex
        change("Pattern einsetzen") { $0.patterns[p] = copied }
    }
    func clearPattern() { let p = patternIndex; change("Pattern löschen") { $0.patterns[p] = TrackerPattern() } }
    func transpose(_ offset: Int) {
        let p = patternIndex, ch = selectedChannel
        change("Spur transponieren") { song in
            for row in 0..<64 where song.patterns[p][row,ch].period > 0 {
                song.patterns[p][row,ch].period = Notes.period(Notes.index(song.patterns[p][row,ch].period)+offset)
            }
        }
    }
    func move(row: Int = 0, field: Int = 0, channel: Int = 0) {
        selectedRow = (selectedRow+row+64)%64
        var position = selectedChannel*6+selectedField+field+channel*6
        position = (position+24)%24
        selectedChannel = position/6; selectedField = position%6
    }
    func input(_ event: NSEvent) -> Bool {
        if handleTrackerShortcut(event) { return true }
        if event.modifierFlags.contains(.command) { return false }
        switch event.keyCode {
        case 49: togglePlay(); return true
        case 36,76: editMode.toggle(); status = editMode ? "Edit aktiv · Noten per Y/Z–M / Q–U eingeben" : "Vorhören · Return aktiviert Edit"; return true
        case 53: stop(); return true
        case 123: move(field:-1); return true
        case 124: move(field:1); return true
        case 125: move(row:event.modifierFlags.contains(.shift) ? 16 : 1); return true
        case 126: move(row:event.modifierFlags.contains(.shift) ? -16 : -1); return true
        case 48: move(channel:event.modifierFlags.contains(.shift) ? -1 : 1); return true
        case 115: selectedRow = 0; return true
        case 119: selectedRow = 63; return true
        case 116: move(row:-16); return true
        case 121: move(row:16); return true
        case 51,117:
            guard editMode else { return true }
            let p = patternIndex,r = selectedRow,ch = selectedChannel,field = selectedField
            change("Zelle löschen") { song in
                if event.modifierFlags.contains(.shift) { song.patterns[p][r,ch] = TrackerCell() }
                else if field == 0 { song.patterns[p][r,ch].period = 0; song.patterns[p][r,ch].sample = 0 }
                else if field <= 2 { song.patterns[p][r,ch].sample = 0 }
                else { song.patterns[p][r,ch].effect = 0; song.patterns[p][r,ch].parameter = 0 }
            }
            move(row:editStep); return true
        default: break
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }
        if selectedField > 0 && editMode, let hex = Int(key,radix:16) {
            let p = patternIndex,r = selectedRow,ch = selectedChannel,field = selectedField
            change("Effekt eingeben") { song in
                var cell = song.patterns[p][r,ch]
                switch field {
                case 1: cell.sample = min(31,(hex & 1)*16+(cell.sample & 15))
                case 2: cell.sample = min(31,(cell.sample & 16)+hex)
                case 3: cell.effect = hex
                case 4: cell.parameter = hex*16+(cell.parameter & 15)
                case 5: cell.parameter = (cell.parameter & 240)+hex
                default: break
                }
                song.patterns[p][r,ch] = cell
            }
            if selectedField == 2 { selectedField = 1; move(row:editStep) }
            else if selectedField == 5 { selectedField = 3; move(row:editStep) }
            else { selectedField += 1 }
            return true
        }
        // Physical piano layout stays stable on QWERTY and German QWERTZ.
        let keyboard: [UInt16:Int] = [6:0,1:1,7:2,2:3,8:4,9:5,5:6,11:7,4:8,45:9,38:10,46:11,43:12,37:13,47:14,41:15,44:16,
            12:12,19:13,13:14,20:15,14:16,15:17,23:18,17:19,22:20,16:21,26:22,32:23,34:24,25:25,31:26,29:27,35:28,33:29,24:30,30:31]
        guard let semitone = keyboard[event.keyCode] else { return false }
        let note = (octave-1)*12+semitone
        guard note < 36 || (preferences.splitKeyboard && semitone >= 12) else { return true }
        let upper = semitone >= 12
        let actualSample = preferences.splitKeyboard && upper ? preferences.splitSample : selectedSample
        let actualNote = preferences.splitKeyboard && upper ? min(35,(preferences.splitOctave-1)*12+semitone-12) : note
        enterPlayedNote(period:Notes.period(actualNote),sample:actualSample)
        return true
    }

    func newModule() { guard confirmDiscard() else { return }; var song = TrackerModule(); song.initialBPM = preferences.defaultBPM; song.initialSpeed = preferences.defaultSpeed; replace(song,url:nil); status = "Neues Modul · Sample importieren oder Demo laden" }
    func loadDemo() { guard confirmDiscard() else { return }; replace(DemoModule.make(),url:nil); status = "Neon Harbor · Original-Demo mit sechs synthetischen Samples" }
    private func replace(_ song: TrackerModule, url: URL?) {
        stop(); module = song; savedModule = song; fileURL = url
        selectedOrder = 0; selectedRow = 0; selectedChannel = 0; selectedField = 0; selectedSample = 0
        isDirty = false; undoManager.removeAllActions(); audio.update(song)
    }
    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.title = L("ProTracker-Modul öffnen"); panel.directoryURL = preferredFolder(sample:false)
        panel.allowedFileTypes = ["mod","modl","ptm","stk","pp","xpk","pack","song"]; panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
    func open(_ url: URL, confirming: Bool = false) {
        if confirming && !confirmDiscard() { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys:[.fileSizeKey])
            guard (info.fileSize ?? 0) <= 10_000_000 else { throw ModuleError.invalid("Die Datei ist für ein 4-Kanal-MOD zu groß.") }
            var song = try MODCodec.decode(Data(contentsOf:url),allowMissingSamples:url.pathExtension.lowercased() == "song")
            if preferences.keepSampleBank { song.samples = module.samples }
            replace(song,url:url); status = url.pathExtension.lowercased() == "song" ? "Songstruktur geladen · fehlende Samples über Import oder Presets ergänzen" : "Geladen: \(url.lastPathComponent)"
        } catch { report(error) }
    }
    @discardableResult func save(as saveAs: Bool = false) -> Bool {
        var destination = fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.title = L("Modul speichern · .mod oder .modl")
            panel.allowedFileTypes = ["mod","modl","pack","song"]; panel.allowsOtherFileTypes = false
            panel.directoryURL = fileURL?.deletingLastPathComponent() ?? preferredFolder(sample:false)
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "\(module.title.isEmpty ? "Untitled" : module.title).mod"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let url = destination else { return false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try MODCodec.encode(module,iff:url.pathExtension.lowercased() == "modl",packed:url.pathExtension.lowercased() == "pack",includeSamples:url.pathExtension.lowercased() != "song")
            try data.write(to:url,options:.atomic)
            savedModule = module; isDirty = false; fileURL = url
            status = "Gespeichert: \(url.lastPathComponent)"; return true
        } catch { report(error); return false }
    }
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Änderungen an „\(module.title)“ sichern?")
        alert.informativeText = L("Ungesicherte Änderungen gehen beim Schließen oder Laden verloren.")
        alert.addButton(withTitle:L("Sichern")); alert.addButton(withTitle:L("Abbrechen")); alert.addButton(withTitle:L("Verwerfen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func importSample() {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.title = L("Sample importieren · WAV, AIFF, 8SVX"); panel.directoryURL = preferredFolder(sample:true)
        panel.allowedFileTypes = ["wav","aif","aiff","8svx","iff","caf","raw","smp"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let (sample,truncated) = try SampleAudio.load(url)
            sampleChange("Sample importieren") { $0 = sample }
            status = truncated ? "Sample auf 131.070 Bytes gekürzt · 8-Bit mono / C-3" : "Sample importiert · 8-Bit mono / C-3"
        } catch { report(error) }
    }
    func exportSample() {
        guard !sample.pcm.isEmpty else { return }
        let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.allowedFileTypes = ["wav","8svx","raw"]; panel.nameFieldStringValue = "sample-\(selectedSample+1).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch url.pathExtension.lowercased() { case "8svx": data = SampleAudio.svx(sample:sample); case "raw": data = Data(sample.pcm.map { UInt8(bitPattern:$0) }); default: data = SampleAudio.wav(sample:sample) }
            try data.write(to:url,options:.atomic); status = "Sample exportiert"
        } catch { report(error) }
    }
    func exportWAV() {
        guard !exporting else { return }
        let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.allowedFileTypes = ["wav"]; panel.nameFieldStringValue = "\(module.title).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let song = module, volume = Float(masterVolume), width = Float(stereo), filter = amigaFilter, mute = muted, prefs = preferences
        exporting = true; status = "Rendere WAV · eine Songrunde, maximal \(prefs.exportMinutes) Minuten …"
        let access = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try WAVWriter.export(module:song,to:url,volume:volume,stereo:width,filter:filter,muted:mute,preferences:prefs) }
            if access { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.exporting = false
                switch result {
                case .success(let limited): self.status = limited ? "WAV exportiert · \(prefs.exportMinutes)-Minuten-Grenze erreicht" : "WAV exportiert: \(url.lastPathComponent)"
                case .failure(let error): self.report(error)
                }
            }
        }
    }
    func normalizeSample() {
        sampleChange("Sample normalisieren") { sample in
            let peak = sample.pcm.map { abs(Int($0)) }.max() ?? 0
            if peak > 0 { sample.pcm = sample.pcm.map { Int8(max(-128,min(127,Int($0)*127/peak))) } }
        }
    }
    func reverseSample() {
        sampleChange("Sample umkehren") { sample in
            sample.pcm.reverse()
            if sample.loops { sample.loopStart = sample.pcm.count-sample.loopStart-sample.loopLength }
        }
    }
    func fadeSample() {
        sampleChange("Sample ausblenden") { sample in
            let length = sample.pcm.count
            guard length > 1 else { return }
            for n in 0..<length { sample.pcm[n] = Int8(Int(sample.pcm[n])*(length-1-n)/(length-1)) }
        }
    }
    func report(_ error: Error) {
        status = .verbatim(error.localizedDescription)
        let alert = NSAlert(error:error); alert.runModal()
    }
}
