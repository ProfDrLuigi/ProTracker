import SwiftUI
import AppKit

private enum Theme {
    static let background = Color(red:0.055,green:0.065,blue:0.078)
    static let panel = Color(red:0.085,green:0.096,blue:0.112)
    static let raised = Color(red:0.12,green:0.135,blue:0.15)
    static let line = Color.white.opacity(0.08)
    static let orange = Color(red:1,green:0.62,blue:0.32)
    static let mint = Color(red:0.43,green:0.88,blue:0.81)
    static let muted = Color(red:0.48,green:0.52,blue:0.56)
}

struct TrackerButton: View {
    var title: String
    var icon: String?
    var active = false
    var accent = false
    var action: () -> Void
    init(_ title: String, icon: String? = nil, active: Bool = false, accent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.active = active; self.accent = accent; self.action = action
    }
    var body: some View {
        Button(action:action) {
            HStack(spacing:6) {
                if let icon { Image(systemName:icon).font(.system(size:11,weight:.semibold)) }
                Text(title).font(.system(size:11,weight:.semibold))
            }
            .padding(.horizontal,11).frame(height:29)
            .foregroundColor(accent || active ? Theme.background : Color.white.opacity(0.8))
            .background(accent ? Theme.orange : (active ? Theme.mint : Theme.raised))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius:4).stroke(Theme.line,lineWidth:1))
        }.buttonStyle(PlainButtonStyle())
    }
}

struct ContentView: View {
    @ObservedObject var store: TrackerStore = .shared
    var body: some View {
        VStack(spacing:0) {
            topBar
            Rectangle().fill(Theme.line).frame(height:1)
            HStack(spacing:0) {
                library.frame(width:232)
                Rectangle().fill(Theme.line).frame(width:1)
                VStack(spacing:0) {
                    transport
                    scopes
                    patternToolbar
                    PatternEditor(store:store).frame(minHeight:250)
                    editorFooter
                    sampleEditor
                }
            }
            statusBar
        }
        .background(Theme.background).foregroundColor(.white)
        .frame(minWidth:1050,minHeight:780)
        .preferredColorScheme(.dark)
        .background(WindowGuard(store:store))
        .sheet(isPresented:$store.showsHelp) { HelpView() }
        .onOpenURL { store.open($0,confirming:true) }
    }
    private var topBar: some View {
        HStack(spacing:14) {
            ZStack {
                RoundedRectangle(cornerRadius:8).fill(Theme.orange).frame(width:42,height:42)
                Text("pt").font(.system(size:27,weight:.black,design:.monospaced)).italic().foregroundColor(Theme.background)
            }
            VStack(alignment:.leading,spacing:3) {
                HStack(alignment:.firstTextBaseline,spacing:7) {
                    Text("PROTRACKER").font(.system(size:17,weight:.heavy,design:.monospaced)).tracking(1.8)
                    Text("/ SWIFT").font(.system(size:10,weight:.medium,design:.monospaced)).foregroundColor(Theme.orange)
                }
                Text("AMIGA SOUL.  NATIVE MAC.").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1.6).foregroundColor(Theme.muted)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:3) {
                Text(store.module.title.isEmpty ? "Untitled" : store.module.title).font(.system(size:12,weight:.semibold))
                Text(store.isDirty ? "UNGESICHERTE ÄNDERUNGEN" : "4 CHANNELS · 31 SAMPLES · MOD").font(.system(size:8,design:.monospaced)).tracking(1).foregroundColor(store.isDirty ? Theme.orange : Theme.muted)
            }
            Rectangle().fill(Theme.line).frame(width:1,height:28)
            TrackerButton("Öffnen",icon:"folder",action:store.open)
            TrackerButton("Sichern",icon:"square.and.arrow.down",action:{ store.save() })
            TrackerButton(store.exporting ? "Rendert …" : "WAV",icon:"waveform",accent:true,action:store.exportWAV).disabled(store.exporting)
            Button(action:{ store.showsHelp = true }) { Image(systemName:"questionmark.circle").foregroundColor(Theme.muted) }.buttonStyle(PlainButtonStyle()).help("Tastatur & Effekte")
        }.padding(.horizontal,20).frame(height:78).background(Theme.panel)
    }
    private func heading(_ text: String, trailing: String = "") -> some View {
        HStack {
            Text(text).font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1.4)
            Spacer()
            Text(trailing).font(.system(size:9,design:.monospaced)).foregroundColor(Theme.muted)
        }.foregroundColor(Theme.muted)
    }
    private var library: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:9) {
                heading("MODULE")
                TextField("Songname",text:Binding(get:{ store.module.title },set:{ value in store.change("Songname") { $0.title = String(value.prefix(32)) } }))
                    .textFieldStyle(PlainTextFieldStyle()).font(.system(size:13,weight:.semibold)).padding(9).background(Theme.background).cornerRadius(4)
                HStack(spacing:8) {
                    TrackerButton("Neu",icon:"plus",action:store.newModule)
                    TrackerButton("Demo",icon:"music.note",action:store.loadDemo)
                    Spacer()
                }
            }.padding(16)
            Rectangle().fill(Theme.line).frame(height:1)
            VStack(alignment:.leading,spacing:10) {
                heading("POSITIONEN",trailing:"\(store.module.orders.count) / 128")
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:5) {
                        ForEach(store.module.orders.indices,id:\.self) { index in
                            Button(action:{ store.selectOrder(index) }) {
                                VStack(spacing:5) {
                                    Text(String(format:"%02X",index)).font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted)
                                    Text(String(format:"%02X",store.module.orders[index])).font(.system(size:16,weight:.semibold,design:.monospaced))
                                }.frame(width:36,height:47).foregroundColor(index == store.selectedOrder ? Theme.orange : .white.opacity(0.65))
                                .background(index == store.selectedOrder ? Theme.orange.opacity(0.12) : Theme.background).cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius:4).stroke(index == store.selectedOrder ? Theme.orange.opacity(0.5) : Theme.line,lineWidth:1))
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                HStack(spacing:5) {
                    Text("PAT").font(.system(size:9,design:.monospaced)).foregroundColor(Theme.muted)
                    numeric(value:store.patternIndex,range:0...127,set:store.setOrderPattern)
                    Spacer()
                    smallButton("plus",help:"Position duplizieren",action:store.addOrder).disabled(store.module.orders.count >= 128)
                    smallButton("minus",help:"Position entfernen",action:store.removeOrder).disabled(store.module.orders.count == 1)
                }
            }.padding(16)
            Rectangle().fill(Theme.line).frame(height:1)
            heading("SAMPLES",trailing:"\(store.module.samples.filter { !$0.pcm.isEmpty }.count) / 31").padding(.horizontal,16).frame(height:38)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(0..<31,id:\.self) { index in
                            let sample = store.module.samples[index]
                            Button(action:{ store.selectedSample = index }) {
                                HStack(spacing:9) {
                                    Text(String(format:"%02X",index+1)).font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundColor(index == store.selectedSample ? Theme.orange : Theme.muted)
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(sample.name.isEmpty ? "Empty sample" : sample.name).font(.system(size:10,weight:.medium)).lineLimit(1).foregroundColor(sample.pcm.isEmpty ? Theme.muted.opacity(0.6) : .white.opacity(0.85))
                                        if !sample.pcm.isEmpty { Text("\(sample.pcm.count) bytes\(sample.loops ? "  ↻ LOOP" : "")").font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted) }
                                    }
                                    Spacer(minLength:0)
                                    if index == store.selectedSample { Rectangle().fill(Theme.orange).frame(width:2,height:16) }
                                }.padding(.horizontal,12).frame(height:38).background(index == store.selectedSample ? Theme.raised : Color.clear).cornerRadius(4)
                            }.buttonStyle(PlainButtonStyle()).id(index)
                        }
                    }.padding(.horizontal,8)
                }.onChange(of:store.selectedSample) { value in proxy.scrollTo(value) }
            }
            HStack {
                Text(String(format:"%.1f KB",Double(store.module.sampleBytes)/1024)).font(.system(size:9,design:.monospaced)).foregroundColor(Theme.muted)
                Spacer()
                Text("8-BIT / MONO").font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted)
            }.padding(16)
        }.background(Theme.panel)
    }
    private func numeric(value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing:0) {
            Button("−") { set(max(range.lowerBound,value-1)) }.buttonStyle(PlainButtonStyle()).frame(width:18)
            Text(String(format:"%02X",value)).font(.system(size:12,weight:.semibold,design:.monospaced)).foregroundColor(Theme.orange).frame(minWidth:24)
            Button("+") { set(min(range.upperBound,value+1)) }.buttonStyle(PlainButtonStyle()).frame(width:18)
        }.frame(height:25).background(Theme.background).cornerRadius(3)
    }
    private func smallButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:icon).font(.system(size:10)).frame(width:23,height:24).background(Theme.raised).cornerRadius(3) }.buttonStyle(PlainButtonStyle()).help(help)
    }
    private func metric(_ label: String, _ value: String, color: Color = Theme.mint) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(label).font(.system(size:8,weight:.medium,design:.monospaced)).tracking(1).foregroundColor(Theme.muted)
            Text(value).font(.system(size:23,weight:.medium,design:.monospaced)).foregroundColor(color)
        }.frame(minWidth:57,alignment:.leading)
    }
    private var transport: some View {
        HStack(spacing:16) {
            metric("POSITION",String(format:"%02X",store.playing ? store.playbackOrder : store.selectedOrder))
            metric("PATTERN",String(format:"%02X",store.patternIndex))
            metric("ROW",String(format:"%02X",store.selectedRow),color:Theme.orange)
            Rectangle().fill(Theme.line).frame(width:1,height:34)
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:5) {
                    Text("BPM").font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted).frame(width:31,alignment:.leading)
                    Stepper(value:Binding(get:{ store.module.initialBPM },set:{ v in store.change("BPM") { $0.initialBPM = v } }),in:32...255) {
                        Text("\(store.currentBPM)").font(.system(size:12,weight:.semibold,design:.monospaced)).frame(width:29)
                    }.frame(width:92)
                }
                HStack(spacing:5) {
                    Text("SPEED").font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted).frame(width:31,alignment:.leading)
                    Stepper(value:Binding(get:{ store.module.initialSpeed },set:{ v in store.change("Speed") { $0.initialSpeed = v } }),in:1...31) {
                        Text(String(format:"%02d",store.currentSpeed)).font(.system(size:12,weight:.semibold,design:.monospaced)).frame(width:29)
                    }.frame(width:92)
                }
            }
            Spacer(minLength:0)
            VStack(alignment:.trailing,spacing:7) {
                HStack(spacing:6) {
                    TrackerButton("Song",icon:"play.fill",active:store.playing,accent:!store.playing,action:{ store.play() }).help("Song ab Position abspielen")
                    TrackerButton("Pattern",icon:"repeat",action:{ store.play(pattern:true) })
                    TrackerButton("Stop",icon:"stop.fill",action:store.stop)
                }
                HStack(spacing:10) {
                    Circle().fill(store.playing ? Theme.mint : Theme.muted).frame(width:5,height:5)
                    Text(store.playing ? "PLAYING" : "STOPPED").font(.system(size:8,design:.monospaced)).tracking(1).foregroundColor(Theme.muted)
                    Text(store.timeLabel).font(.system(size:12,design:.monospaced)).foregroundColor(.white.opacity(0.7))
                }
            }
        }.padding(.horizontal,18).frame(height:83).background(Theme.panel)
    }
    private var scopes: some View {
        HStack(spacing:8) {
            ForEach(0..<4,id:\.self) { ch in
                VStack(alignment:.leading,spacing:5) {
                    HStack {
                        Text("CH \(String(format:"%02d",ch+1))").font(.system(size:8,weight:.bold,design:.monospaced)).foregroundColor(store.muted[ch] ? Theme.orange : Theme.muted)
                        Spacer()
                        Button(store.muted[ch] ? "MUTE" : "●") { store.muted[ch].toggle() }.buttonStyle(PlainButtonStyle()).font(.system(size:8,design:.monospaced)).foregroundColor(store.muted[ch] ? Theme.orange : Theme.mint).help("Kanal stummschalten")
                    }
                    SignalView(points:store.scopes[ch],color:store.muted[ch] ? .darkGray : NSColor(calibratedRed:0.43,green:0.88,blue:0.81,alpha:1)).frame(height:39)
                    GeometryReader { geo in
                        ZStack(alignment:.leading) {
                            Rectangle().fill(Theme.raised)
                            Rectangle().fill(Theme.mint.opacity(store.muted[ch] ? 0.2 : 0.7)).frame(width:geo.size.width*CGFloat(min(1,store.levels[ch])))
                        }
                    }.frame(height:2)
                }
            }
        }.padding(.horizontal,18).padding(.vertical,10).background(Theme.background)
    }
    private var patternToolbar: some View {
        HStack(spacing:8) {
            Text("PATTERN \(String(format:"%02X",store.patternIndex))").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1)
            Text("64 ROWS").font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted)
            Spacer()
            TrackerButton("Kopie",icon:"doc.on.doc",action:store.copyPattern)
            TrackerButton("Einsetzen",action:store.pastePattern)
            TrackerButton("Duplizieren",action:store.duplicatePattern).disabled(store.module.patterns.count >= 128 || store.module.orders.count >= 128)
            TrackerButton("Edit",icon:"pencil",active:store.editMode,action:{ store.editMode.toggle() }).help("Return · Noten und Hexwerte eingeben")
        }.padding(.horizontal,14).frame(height:43).background(Theme.raised.opacity(0.45))
    }
    private var editorFooter: some View {
        HStack(spacing:12) {
            Text(store.editMode ? "● EDIT" : "○ AUDITION").foregroundColor(store.editMode ? Theme.orange : Theme.muted)
            Text("OCT")
            Picker("Oktave",selection:$store.octave) { ForEach(1...3,id:\.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width:55)
            Text("STEP")
            Picker("Schritt",selection:$store.editStep) { ForEach([0,1,2,4,8,16],id:\.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width:58)
            Spacer()
            Toggle("Follow",isOn:$store.follow).toggleStyle(CheckboxToggleStyle()).font(.system(size:10))
            Text("Y/Z–M / Q–U · NOTES").foregroundColor(Theme.muted)
        }.font(.system(size:9,weight:.medium,design:.monospaced)).foregroundColor(Theme.muted).padding(.horizontal,15).frame(height:35).background(Theme.panel)
    }
    private var sampleEditor: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:8) {
                Text("SAMPLE \(String(format:"%02X",store.selectedSample+1))").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundColor(Theme.orange)
                TextField("Samplename",text:Binding(get:{ store.sample.name },set:{ name in store.sampleChange("Samplename") { $0.name = String(name.prefix(22)) } }))
                    .textFieldStyle(PlainTextFieldStyle()).font(.system(size:11)).frame(maxWidth:200)
                Spacer()
                TrackerButton("Import",icon:"square.and.arrow.down",action:store.importSample)
                TrackerButton("WAV",icon:"square.and.arrow.up",action:store.exportSample).disabled(store.sample.pcm.isEmpty)
                TrackerButton("Vorhören",icon:"speaker.wave.2",action:{ store.preview() }).disabled(store.sample.pcm.isEmpty)
            }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    SignalView(points:store.sample.pcm.map { Float($0)/128 },color:NSColor(calibratedRed:1,green:0.62,blue:0.32,alpha:1),filled:true,
                        loopRange:store.sample.loops ? Double(store.sample.loopStart)/Double(store.sample.pcm.count)..<Double(store.sample.loopStart+store.sample.loopLength)/Double(store.sample.pcm.count) : nil)
                        .frame(height:67).overlay(Rectangle().stroke(Theme.line,lineWidth:1))
                    HStack {
                        Text(store.sample.pcm.isEmpty ? "KEIN SAMPLE · WAV / AIFF / 8SVX IMPORTIEREN" : "\(store.sample.pcm.count) BYTES · 8-BIT MONO · C-3 / 16.574 kHz")
                        Spacer()
                        if store.sample.loops { Text("↻ \(store.sample.loopStart) — \(store.sample.loopStart+store.sample.loopLength)").foregroundColor(Theme.orange) }
                    }.font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted)
                }
                VStack(alignment:.leading,spacing:7) {
                    sampleNumber("VOL",value:store.sample.volume,range:0...64) { value in store.sampleChange("Sample-Lautstärke") { $0.volume = value } }
                    sampleNumber("FINE",value:store.sample.finetune,range: -8...7) { value in store.sampleChange("Finetune") { $0.finetune = value } }
                    Toggle("Loop",isOn:Binding(get:{ store.sample.loops },set:{ enabled in store.sampleChange("Sample-Loop") { s in s.loopStart = 0; s.loopLength = enabled ? s.pcm.count : 0 } })).toggleStyle(CheckboxToggleStyle()).font(.system(size:10)).disabled(store.sample.pcm.count < 4)
                }.frame(width:118)
                VStack(alignment:.leading,spacing:7) {
                    sampleNumber("START",value:store.sample.loopStart,range:0...max(0,store.sample.pcm.count-4),step:2) { value in store.sampleChange("Loop-Start") { $0.loopStart = value } }
                    sampleNumber("LENGTH",value:store.sample.loopLength,range:0...max(0,store.sample.pcm.count-store.sample.loopStart),step:2) { value in store.sampleChange("Loop-Länge") { $0.loopLength = value } }
                    HStack(spacing:5) {
                        smallButton("arrow.left.and.right",help:"Sample umkehren",action:store.reverseSample)
                        smallButton("waveform.path",help:"Sample normalisieren",action:store.normalizeSample)
                        smallButton("decrease.indent",help:"Sample ausblenden",action:store.fadeSample)
                    }.disabled(store.sample.pcm.isEmpty)
                }.frame(width:141)
            }
        }.padding(.horizontal,16).padding(.vertical,12).background(Theme.panel)
    }
    private func sampleNumber(_ label: String, value: Int, range: ClosedRange<Int>, step: Int = 1, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing:5) {
            Text(label).font(.system(size:8,design:.monospaced)).foregroundColor(Theme.muted).frame(width:label.count > 4 ? 38 : 29,alignment:.leading)
            TextField("",value:Binding(get:{ value },set:{ set(min(range.upperBound,max(range.lowerBound,$0))) }),formatter:NumberFormatter())
                .textFieldStyle(PlainTextFieldStyle()).font(.system(size:10,design:.monospaced)).multilineTextAlignment(.trailing).padding(3).background(Theme.background).frame(minWidth:32)
            Stepper("",value:Binding(get:{ value },set:set),in:range,step:step).labelsHidden().frame(width:18)
        }
    }
    private var statusBar: some View {
        HStack(spacing:10) {
            Circle().fill(store.exporting ? Theme.orange : Theme.mint).frame(width:5,height:5)
            Text(store.status).lineLimit(1)
            Spacer()
            Toggle("A500",isOn:$store.amigaFilter).toggleStyle(CheckboxToggleStyle()).help("Annäherung an den analogen 4,42-kHz-Tiefpass")
            Text("STEREO").foregroundColor(Theme.muted)
            Slider(value:$store.stereo,in:0...1).frame(width:65)
            Image(systemName:"speaker.wave.2").foregroundColor(Theme.muted)
            Slider(value:$store.masterVolume,in:0...1).frame(width:80)
            Text("\(Int(store.masterVolume*100))%").frame(width:28,alignment:.trailing)
        }.font(.system(size:9,design:.monospaced)).foregroundColor(Theme.muted).padding(.horizontal,16).frame(height:31).background(Theme.raised)
    }
}

struct HelpView: View {
    @Environment(\.presentationMode) var presentation
    var body: some View {
        VStack(alignment:.leading,spacing:17) {
            HStack { Text("Protracker / Swift").font(.title2).bold(); Spacer(); Button("Fertig") { presentation.wrappedValue.dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Native Neuimplementierung auf Basis der statisch analysierten ProTracker-3.61-Binary. Die Originalprogramme und die reproduzierbare Disassemblierung liegen im Projekt unter Reference und ReverseEngineering.").font(.system(size:12)).foregroundColor(.secondary)
            Divider()
            Text("Tastatur im Pattern-Editor").font(.headline)
            Text("Klicke in das Pattern, um den Tastaturfokus zu setzen.\nLeertaste: Song / Stop · Esc: Stop · Return: Edit an/aus\nPfeiltasten: Zeile / Feld · Tab: nächster Kanal · Shift-Tab: zurück\nPage Up/Down: 16 Zeilen · Home/End: Anfang/Ende\nY/Z S X D C V G B H N J M: chromatische Noten\nQ 2 W 3 E R 5 T 6 Y 7 U: nächsthöhere Oktave\nA–F / 0–9: Hexwerte im Sample- oder Effektfeld\nEntf: Feld löschen · Shift-Entf: ganze Zelle\n⌘Z: Undo · ⇧⌘Z: Redo · ⌘C / ⌘V: Pattern kopieren / einsetzen").font(.system(size:11,design:.monospaced)).lineSpacing(4)
            Text("Effekte").font(.headline)
            Text("0 Arpeggio · 1/2 Slides · 3 Portamento · 4 Vibrato\n5/6 + Volume Slide · 7 Tremolo · 9 Sample Offset\nA Volume Slide · B Position Jump · C Volume\nD Pattern Break (dezimal/BCD) · E erweiterte Effekte\nF01–F1F Speed · F20–FFF BPM (CIA) · F00 Stop\nE0 Filter · E1/E2 Fine Slide · E3 Glissando · E4/E7 Wellenform\nE5 Finetune · E6 Loop · E8 Karplus-Strong · E9 Retrigger\nEA/EB Fine Volume · EC Cut · ED Delay · EE Pattern Delay · EF Invert Loop").font(.system(size:10,design:.monospaced)).lineSpacing(3)
            Text("Dateien & Klang").font(.headline)
            Text("MOD: 4 Kanäle, 31 Samples, bis zu 128 Patterns. MODL bewahrt Starttempo, VBlank/CIA und Filterstatus. Samples werden als 8-Bit-Mono mit C-3-Grundton importiert (max. 131.070 Bytes). WAV rendert eine Songrunde, höchstens 10 Minuten. Die analogen Filter sind angenähert; der Mixer ist keine taktgenaue Paula-Emulation. Die vollständige Amiga-Oberfläche, XPK und Hardware-Sampling sind nicht portiert.").font(.system(size:11)).foregroundColor(.secondary)
        }.padding(26).frame(width:640).background(Theme.panel).preferredColorScheme(.dark)
    }
}

struct WindowGuard: NSViewRepresentable {
    let store: TrackerStore
    func makeCoordinator() -> Coordinator { Coordinator(store:store) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { window.delegate = context.coordinator; window.title = "Protracker — Swift"; window.minSize = NSSize(width:1050,height:808)
                let available = window.screen?.visibleFrame.size ?? NSSize(width:1440,height:1000)
                window.setContentSize(NSSize(width:min(1220,available.width-60),height:min(900,available.height-80)))
                func focusGrid(in view: NSView) -> Bool {
                    if let grid = view as? PatternGridView { window.makeFirstResponder(grid); return true }
                    return view.subviews.contains(where: { focusGrid(in:$0) })
                }
                DispatchQueue.main.async { if let root = window.contentView { _ = focusGrid(in:root) } } } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.window?.isDocumentEdited = store.isDirty }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let store: TrackerStore
        init(store: TrackerStore) { self.store = store }
        func windowShouldClose(_ sender: NSWindow) -> Bool { if store.confirmDiscard() { store.stop(); return true }; return false }
    }
}
