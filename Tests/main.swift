import Foundation
import AVFoundation

var passed = 0, failed = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
}
func rejects(_ data: Data, _ message: String) { do { _ = try MODCodec.decode(data); expect(false,message) } catch { expect(true,message) } }

// Localization uses resource bundles and keeps user content out of translation keys.
let localizationRoot = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Protracker")
func localized(_ message: AppText, _ language: AppLanguage) -> String { L10n.resolve(message,language:language,resources:localizationRoot) }
expect(localized("Sichern",.english) == "Save","English UI translation")
expect(localized("Sichern",.german) == "Sichern","German UI translation")
expect(localized("Record a sample",.german) == "Sample aufnehmen","German workbench translation")
let fileName = "Sichern {1} 100% 🥁.mod"
expect(localized("Gespeichert: \(fileName)",.english) == "Saved: \(fileName)","Interpolated filenames stay verbatim")
expect(localized(.verbatim("Sichern"),.english) == "Sichern","User content is never translated")
expect(localized("Block: \(12) Zeilen × \(4) Spuren",.english) == "Block: 12 rows × 4 tracks","Multiple localized values")
expect(localized("No such translation",.english) == "No such translation","Missing keys have a readable fallback")
expect(L10n.code(for:.system,preferredLanguages:["de-CH","en-US"]) == "de","German system language variants")
expect(L10n.code(for:.system,preferredLanguages:["en-GB","de"]) == "en","English system language variants")
expect(L10n.code(for:.system,preferredLanguages:["ja"]) == "en","Unsupported system language falls back to English")
if case .invalid(let reason) = ModuleError.invalid("Ungültige Songlänge.") {
    expect(localized(reason,.english) == "Invalid song length.","Module error uses the same English resources")
}
for language in ["en","de"] {
    let data = try Data(contentsOf:localizationRoot.appendingPathComponent(language+".lproj/InfoPlist.strings"))
    let dictionary = try PropertyListSerialization.propertyList(from:data,format:nil) as! [String:String]
    expect(dictionary["NSMicrophoneUsageDescription"]?.isEmpty == false,"Localized microphone permission description")
}

// Reference vectors run selected original machine-code paths, not a second Swift implementation.
let oracle = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"ReverseEngineering/replay-vectors.json"))) as! [String:Any]
let cases = oracle["cases"] as! [[String:Any]]
for test in cases {
    let input = test["input"] as! [String:Int], expected = test["expected"] as! [String:Int]
    let effect = input["effect"]!, parameter = input["parameter"]!, tick = input["tick"] ?? 1
    var module = TrackerModule()
    module.patterns[0][0,0] = TrackerCell(effect:effect,parameter:parameter)
    if input["sampleFixture"] == 1 {
        module.samples[0] = TrackerSample(pcm:[10,30,-80,60,-40,100,-10,20],loopLength:8)
    }
    let core = TrackerReplay(module:module)
    core.start(); core.tick = tick
    if input["sampleFixture"] == 1 { core.voices[0].instrument = 0 }
    core.voices[0].cell = module.patterns[0][0,0]
    core.voices[0].period = input["period"] ?? 428
    core.voices[0].volume = input["volume"] ?? 32
    core.voices[0].finetune = input["finetune"] ?? 0
    core.voices[0].target = input["target"] ?? 0
    core.voices[0].portaSpeed = input["portaSpeed"] ?? 0
    core.voices[0].vibrato = input["vibrato"] ?? 0
    core.voices[0].vibratoPhase = input["phase"] ?? 0
    core.voices[0].vibratoWave = (input["wave"] ?? 0) & 15
    core.voices[0].tremoloWave = (input["wave"] ?? 0) >> 4
    core.voices[0].tremolo = input["tremolo"] ?? 0
    core.voices[0].tremoloPhase = input["tremoloPhase"] ?? 0
    core.processTick()
    let voice = core.voices[0]
    var actual = ["period":voice.period,"volume":voice.volume,"outputPeriod":voice.outputPeriod,
                  "outputVolume":voice.outputVolume,"target":voice.target,"phase":voice.vibratoPhase,"tremoloPhase":voice.tremoloPhase]
    if input["sampleFixture"] == 1 {
        for (i,value) in core.module.samples[0].pcm.enumerated() { actual["pcm\(i)"] = Int(value) }
    }
    for (key,value) in expected { expect(actual[key] == value,"\(test["name"]!): \(key) expected \(value), got \(actual[key] ?? -999)") }
}

var song = TrackerModule()
song.title = "Round trip"
song.samples[0] = TrackerSample(name:"Loop",pcm:[0,10,80,-127,-64,40,20,0],volume:37,finetune:-3,loopStart:2,loopLength:4)
song.patterns = Array(repeating:TrackerPattern(),count:100)
song.patterns[99][63,3] = TrackerCell(period:113,sample:31,effect:15,parameter:125)
song.patterns[0][0,0] = TrackerCell(period:428,sample:1)
song.orders = [0,99,0]
let bytes = try MODCodec.encode(song)
let decoded = try MODCodec.decode(bytes)
expect(decoded == song,"100-pattern MOD round trip with signed PCM, finetune, loops, sample 31")
expect(String(data:bytes[1080..<1084],encoding:.ascii) == "M!K!","100-pattern signature")
var iffSong = song
iffSong.title = String("32-character MODL title: Protrack".prefix(32))
iffSong.initialBPM = 145; iffSong.ciaTiming = false; iffSong.filterEnabled = true; iffSong.comment = "Native Swift"
let iffBytes = try MODCodec.encode(iffSong,iff:true)
let decodedIFF = try MODCodec.decode(iffBytes)
expect(decodedIFF == iffSong,"MODL round trip metadata and embedded PTDT")
rejects(Data(),"reject empty")
rejects(bytes.prefix(1083),"reject truncated header")
rejects(bytes.dropLast(),"reject truncated sample data")
var bad = bytes; bad[950] = 0; rejects(bad,"reject zero song length")
bad = bytes; bad[952] = 255; rejects(bad,"reject invalid order")
bad = bytes; bad[1080] = 88; rejects(bad,"reject unknown channels")
bad = iffBytes; bad[4] = 127; rejects(bad,"reject oversized IFF")
for length in stride(from:0,to:bytes.count,by:997) { rejects(bytes.prefix(length),"truncated MOD at \(length)") }
// Deterministic malformed inputs exercise bounded decoding without allocating arbitrary sizes.
var random: UInt32 = 361
for _ in 0..<250 {
    var data = Data(repeating:0,count:1400)
    for i in data.indices { random = random &* 1664525 &+ 1013904223; data[i] = UInt8(truncatingIfNeeded:random >> 16) }
    rejects(data,"malformed fuzz input")
}
// CIA timing is quantized to the original latch and five-CCK E-clock.
func hardwareFrames(ticks: Int, bpm: Int = 125, standard: AmigaStandard = .pal, rate: Int = 44100) -> Int {
    let cycles = UInt64(ticks)*(UInt64(standard.timerLatch(bpm:bpm))+1)*5
    return Int((cycles*UInt64(rate)+standard.clock-1)/standard.clock)
}
let core = TrackerReplay(module:decoded); core.start()
_ = core.renderBlock(5292); expect(core.row == 0,"row remains active for full tick interval")
_ = core.renderBlock(1); expect(core.row == 1,"sample-accurate row boundary")
expect(core.voices[0].position >= 2 && core.voices[0].position < 6.5,"sample stays inside loop")
let output = core.renderBlock(2000)
expect(output.0.allSatisfy { $0.isFinite && abs($0) <= 1 },"bounded finite audio")
expect(output.0.contains { abs($0) > 0.001 },"non-silent PCM output")
var tempoSong = TrackerModule(); tempoSong.patterns[0][0,0] = TrackerCell(effect:15,parameter:150)
let tempo = TrackerReplay(module:tempoSong); tempo.start()
let tempoCycles = (UInt64(AmigaStandard.pal.timerLatch(bpm:125))+1)*5 + 5*(UInt64(AmigaStandard.pal.timerLatch(bpm:150))+1)*5
_ = tempo.renderBlock(Int((tempoCycles*44100+AmigaStandard.pal.clock-1)/AmigaStandard.pal.clock))
expect(tempo.bpm == 150 && tempo.row == 1,"F96 updates tempo after the CIA force-load of the previous latch")
var delaySong = TrackerModule(); delaySong.patterns[0][0,0] = TrackerCell(effect:14,parameter:0xe2)
let delay = TrackerReplay(module:delaySong); delay.start(); _ = delay.renderBlock(5292*3); _ = delay.renderBlock(1)
expect(delay.row == 1,"EE2 repeats exactly two extra rows")
var loopSong = TrackerModule(); loopSong.patterns[0][0,0] = TrackerCell(effect:14,parameter:0x60); loopSong.patterns[0][1,0] = TrackerCell(effect:14,parameter:0x62)
let loop = TrackerReplay(module:loopSong); loop.start(); _ = loop.renderBlock(5292*6); _ = loop.renderBlock(1)
expect(loop.row == 2,"E62 repeats loop twice then advances")
let once = TrackerReplay(module:TrackerModule()); once.loopSong = false; once.start(); _ = once.renderBlock(hardwareFrames(ticks:64*6))
expect(!once.playing && once.completedCycles == 1,"offline traversal stops at song end")
var stopSong = TrackerModule(); stopSong.patterns[0][0,0] = TrackerCell(effect:15,parameter:0)
let stop = TrackerReplay(module:stopSong); stop.start(); _ = stop.renderBlock(1)
expect(!stop.playing,"F00 stops playback")
// Exercise the same exporter and importer used by the application.
let directory = URL(fileURLWithPath:".build/checks",isDirectory:true)
var shortSong = TrackerModule()
shortSong.samples[0] = song.samples[0]
shortSong.patterns[0][0,0] = TrackerCell(period:428,sample:1)
shortSong.patterns[0][4,0] = TrackerCell(effect:15,parameter:0)
shortSong.patterns[0][4,1] = TrackerCell(period:428,sample:1)
let wavURL = directory.appendingPathComponent("render-check.wav")
let limited = try WAVWriter.export(module:shortSong,to:wavURL,volume:0.8,stereo:0.8,filter:true,muted:[false,false,false,false])
let wav = try AVAudioFile(forReading:wavURL)
expect(!limited,"finite WAV export")
expect(wav.processingFormat.sampleRate == 44100 && wav.processingFormat.channelCount == 2,"WAV is 44.1kHz stereo")
expect(wav.length == hardwareFrames(ticks:4*6),"WAV stops at F00 after exactly four rows")
let renderedBytes = try Data(contentsOf:wavURL)
expect(renderedBytes.count == 44+Int(wav.length)*4,"WAV header matches PCM length")
let sampleURL = directory.appendingPathComponent("sample-check.wav")
try SampleAudio.wav(sample:song.samples[0]).write(to:sampleURL)
let (imported,truncated) = try SampleAudio.load(sampleURL)
expect(!truncated && !imported.pcm.isEmpty && imported.pcm.count % 2 == 0,"WAV sample import produces even signed PCM")
let demo = DemoModule.make()
let demoData = try MODCodec.encode(demo)
let decodedDemo = try MODCodec.decode(demoData)
var expectedDemo = demo; expectedDemo.comment = ""
expect(decodedDemo == expectedDemo,"synthesized demo MOD round trip (MOD has no comment chunk)")
try demoData.write(to:directory.appendingPathComponent("Neon Harbor.mod"))
let stopped = TrackerReplay(module:shortSong); stopped.start(); let stopAudio = stopped.renderBlock(5292*4+1024)
expect(!stopped.voices[1].active,"F00 prevents later channels from retriggering")
expect(abs(stopAudio.0.last ?? 1) < 0.01,"F00 leaves no sounding voice")
// Expanded sample editor: bounded edits, loop relocation, clipping and resampling.
var editSample = TrackerSample(name:"Editor",pcm:[10,20,30,40,50,60,70,80],loopStart:2,loopLength:4)
SampleEditing.apply(.reverse,to:&editSample,range:2..<6)
expect(editSample.pcm == [10,20,60,50,40,30,70,80],"reverse only selected region")
try SampleEditing.replace(0..<2,in:&editSample,with:[])
expect(editSample.loopStart == 0 && editSample.loopLength == 4,"cut moves loop with remaining audio")
try SampleEditing.replace(2..<2,in:&editSample,with:[1,2])
expect(editSample.loopLength == 6 && editSample.pcm.count == 8,"insertion inside loop extends it")
SampleEditing.crop(2..<6,in:&editSample)
expect(editSample.pcm.count == 4 && editSample.loopStart == 0 && editSample.loopLength == 4,"crop intersects loop")
var faded = TrackerSample(pcm:[100,100,100,100])
SampleEditing.apply(.fadeIn,to:&faded); expect(faded.pcm.first == 0 && faded.pcm.last == 100,"fade in endpoints")
SampleEditing.apply(.fadeOut,to:&faded); expect(faded.pcm.last == 0,"fade out endpoint")
var dc = TrackerSample(pcm:[40,40,40,40]); SampleEditing.apply(.removeDC,to:&dc)
expect(dc.pcm == [0,0,0,0],"DC removal")
var normalized = TrackerSample(pcm:[-128,64,0,32]); SampleEditing.apply(.normalize,to:&normalized)
expect(normalized.pcm[0] == -127 && normalized.pcm[1] == 64,"normalize handles Int8 minimum safely")
var clipped = TrackerSample(pcm:[100,-100,50,-50]); SampleEditing.apply(.gain,to:&clipped,gain:4)
expect(clipped.pcm == [127,-128,127,-128],"gain clips safely")
for operation in SampleEditing.Operation.allCases {
    var sample = TrackerSample(pcm:[-128,127,-40,40,0,10,-20,80],loopLength:8)
    SampleEditing.apply(operation,to:&sample,range:1..<7)
    expect(sample.pcm.count == 8 && sample.pcm.first == -128 && sample.pcm.last == 80,"range operation \(operation)")
}
var resampled = TrackerSample(pcm:Array(repeating:80,count:16),loopStart:4,loopLength:8)
try SampleEditing.resample(0..<16,in:&resampled,ratio:2)
expect(resampled.pcm.count == 8 && resampled.loopStart == 2 && resampled.loopLength == 4,"resampling scales loop")
let beforeOversize = resampled
 do { try SampleEditing.replace(0..<0,in:&resampled,with:Array(repeating:0,count:131070)); expect(false,"oversized paste rejected") } catch { expect(resampled == beforeOversize,"oversized paste is atomic") }
var mixed = TrackerSample(pcm:[100,-100,100,-100]); try SampleEditing.mix(mixed,into:&mixed,at:0)
expect(mixed.pcm == [100,-100,100,-100],"half-volume self mix")
let chord = SampleEditing.chord(SampleEditing.waveform("Sine"),intervals:[0,4,7])
expect(chord.pcm.count == 128 && !chord.pcm.isEmpty,"chord render")
for wave in ["Sine","Square","Saw","Triangle","Noise"] { let value = SampleEditing.waveform(wave); expect(value.loops && value.pcm.count == 128,"generated \(wave)") }
// Track/block edits retain effects and don't cross channel or pattern boundaries.
var patternEdit = TrackerPattern()
for r in 0..<8 { patternEdit[r,1] = TrackerCell(period:Notes.period(r),sample:2,effect:12,parameter:r) }
let block = PatternEditing.copy(patternEdit,rows:2...5,channels:1...1)
expect(block.isValid && block.rows == 4,"block capture")
PatternEditing.paste(block,into:&patternEdit,row:62,channel:3)
expect(patternEdit[63,3] == block.cells[1],"paste clipped at pattern boundary")
let snapshot = patternEdit
PatternEditing.shift(&patternEdit,row:2,count:2,channels:1...1,insert:true)
expect(patternEdit[2,1].isEmpty && patternEdit[4,1] == snapshot[2,1] && patternEdit[62,3] == snapshot[62,3],"insert shifts one track")
PatternEditing.shift(&patternEdit,row:2,count:2,channels:1...1,insert:false)
expect(patternEdit[2,1] == snapshot[2,1],"delete reverses insertion within retained area")
PatternEditing.stretch(&patternEdit,channel:1,expand:true); PatternEditing.stretch(&patternEdit,channel:1,expand:false)
expect(patternEdit[2,1] == snapshot[2,1],"expand/contract retained events")
let libraryEntry = PresetEntry(name:"Drum",bank:"Bank",sample:song.samples[0])
let library = try PresetDocument.decode(JSONEncoder().encode(PresetDocument(entries:[libraryEntry])))
expect(library.entries == [libraryEntry],"preset library round trip with PCM and loops")
let prefs = TrackerPreferences(); expect(prefs.valid,"default preferences valid")
expect(try! JSONDecoder().decode(TrackerPreferences.self,from:JSONEncoder().encode(prefs)) == prefs,"settings round trip")
// MIDI parser handles running status across packets, real-time bytes and note-off velocity zero.
var midiDecoder = MIDINoteDecoder()
expect(midiDecoder.decode([0x90,60]).isEmpty,"split MIDI packet waits")
let midiEvents = midiDecoder.decode([100,0xf8,64,0,0x80,60,0])
expect(midiEvents == [MIDINoteEvent(note:60,velocity:100,channel:0,on:true),MIDINoteEvent(note:64,velocity:0,channel:0,on:false),MIDINoteEvent(note:60,velocity:0,channel:0,on:false)],"MIDI running status and real-time interleave")
expect(midiDecoder.decode([0xf0,1,2,0xf8,3,0xf7,0x91,62,80]).last?.channel == 1,"MIDI sysex skipped")
// Sample interchange preserves loops in WAV and IFF-8SVX.
expect(imported.loopStart == song.samples[0].loopStart && imported.loopLength == song.samples[0].loopLength,"WAV smpl loop round trip")
let svxURL = directory.appendingPathComponent("sample-check.8svx")
try SampleAudio.svx(sample:song.samples[0]).write(to:svxURL)
let svx = try SampleAudio.load(svxURL).0
expect(svx.pcm == song.samples[0].pcm && svx.volume == 37 && svx.loopLength == 4,"8SVX sample round trip")
var vhdr = [UInt8](repeating:0,count:20); vhdr[3] = 4; vhdr[14] = 1; vhdr[15] = 1
let fibonacci = IFF.form("8SVX",chunks:[("VHDR",vhdr),("BODY",[0,0,0x89,0x7f])])
try fibonacci.write(to:svxURL)
expect(try! SampleAudio.load(svxURL).0.pcm == [0,1,0,21],"Fibonacci compressed 8SVX")
// A real SQSH fixture is compared byte-for-byte with libxmp's original C decoder when available.
let packedURL = URL(fileURLWithPath:".build/reference/PRU2.PDX-Perihelion")
let referenceURL = URL(fileURLWithPath:".build/reference/perihelion.unpacked")
if FileManager.default.fileExists(atPath:packedURL.path) && FileManager.default.fileExists(atPath:referenceURL.path) {
    let expected = try Data(contentsOf:referenceURL)
    let actual = try PackedModules.unpack(Data(contentsOf:packedURL))
    expect(actual == expected,"real SQSH differential test against libxmp C implementation")
}
func msbBits(_ value: Int, _ count: Int) -> [Int] { (0..<count).reversed().map { (value>>$0)&1 } }
func packBits(_ bits: [Int], backwards: Bool = false) -> [UInt8] {
    var bytes = [UInt8](repeating:0,count:(bits.count+7)/8)
    for (i,bit) in bits.enumerated() { bytes[i/8] |= UInt8(bit) << (backwards ? i%8 : 7-i%8) }
    return backwards ? Array(bytes.reversed()) : bytes
}
func ppLiteral(_ bytes: [UInt8]) -> Data {
    var bits = [0], left = bytes.count-1
    while left >= 3 { bits += msbBits(3,2); left -= 3 }
    bits += msbBits(left,2)
    for byte in bytes.reversed() { bits += msbBits(Int(byte),8) }
    var payload = packBits(bits,backwards:true)
    while payload.count%4 != 0 { payload.insert(0,at:0) }
    return Data(Array("PP20".utf8)+[9,9,9,9]+payload+[UInt8((bytes.count>>16)&255),UInt8((bytes.count>>8)&255),UInt8(bytes.count&255),0])
}
let ppModule = ppLiteral([UInt8](demoData))
expect(try! PackedModules.unpack(ppModule) == demoData,"PP20 literal decoder")
expect(try! MODCodec.decode(ppModule) == expectedDemo,"PP20 module loading")
var matchBits = [0,0,0]+msbBits(65,8)+[1,1,0]+msbBits(0,7)+msbBits(0,3)
var matchBytes = packBits(matchBits,backwards:true); while matchBytes.count%4 != 0 { matchBytes.insert(0,at:0) }
expect(try! PackedModules.unpack(Data(Array("PP20".utf8)+[9,9,9,9]+matchBytes+[0,0,6,0])) == Data(repeating:65,count:6),"PP20 overlapping backward match")
func xpk(_ payload: [UInt8], expanded: Int, type: UInt8) -> Data {
    var sum: UInt32 = 0
    for i in stride(from:0,to:payload.count,by:4) { var word: UInt32 = 0; for j in 0..<4 { word = word<<8 | (i+j<payload.count ? UInt32(payload[i+j]) : 0) }; sum ^= word }
    let checksum = Int((sum^(sum>>16))&65535)
    var header = [UInt8](repeating:0,count:36)
    MODCodec.writeText("XPKFSQSH",to:&header,at:0,count:4); MODCodec.writeText("SQSH",to:&header,at:8,count:4)
    header.replaceSubrange(12..<16,with:IFF.big32(expanded))
    var chunk = [type,UInt8(0),UInt8(checksum>>8),UInt8(checksum&255),UInt8(payload.count>>8),UInt8(payload.count&255),UInt8(expanded>>8),UInt8(expanded&255)]
    chunk[1] = chunk.reduce(0, ^); chunk += payload
    if type == 1 { while chunk.count%4 != 0 { chunk.append(0) } }
    header.replaceSubrange(4..<8,with:IFF.big32(header.count+chunk.count-8))
    return Data(header+chunk)
}
let tinySQSH = xpk([0,6,65]+packBits([1,1,0,1,0,0]+msbBits(0,8)),expanded:6,type:1)
expect(try! PackedModules.unpack(tinySQSH) == Data(repeating:65,count:6),"SQSH overlapping LZ copy")
let verbatim = xpk(Array("native tracker".utf8),expanded:14,type:0)
expect(try! PackedModules.unpack(verbatim) == Data("native tracker".utf8),"XPK verbatim block")
var brokenXPK = verbatim; brokenXPK[38] ^= 1
 do { _ = try PackedModules.unpack(brokenXPK); expect(false,"bad XPK checksum rejected") } catch { expect(true,"bad XPK checksum rejected") }
for n in 0..<tinySQSH.count { do { _ = try PackedModules.unpack(tinySQSH.prefix(n)); if n >= 4 { expect(false,"truncated XPK at \(n)") } } catch { expect(true,"truncated XPK at \(n)") } }
// Instrument-only changes switch the hardware-style loop reload on the next wrap.
var switchSong = TrackerModule(); switchSong.samples[0] = TrackerSample(pcm:[10,20,30,40],loopLength:4); switchSong.samples[1] = TrackerSample(pcm:[-10,-20,-30,-40],loopLength:4)
let switcher = TrackerReplay(module:switchSong); switcher.preview(sample:0,period:428,channel:0)
switcher.voices[0].instrument = 1; switcher.voices[0].pendingLoopSample = 1
_ = switcher.renderBlock(100)
expect(switcher.voices[0].activeSample == 1,"instrument without note updates next loop")
let smoother = TrackerReplay(module:decoded); smoother.smoothResampling = true; smoother.start()
let smooth = smoother.renderBlock(4000)
expect(smooth.0.allSatisfy({ $0.isFinite && abs($0)<=1 }),"4x render bounded")
let countin = TrackerReplay(module:decoded); countin.start(); countin.countInRemaining = 24
_ = countin.renderBlock(5292*4)
expect(countin.row == 0 && !countin.voices[0].active,"count-in leaves pattern untouched")
_ = countin.renderBlock(1); expect(countin.voices[0].active,"pattern begins after count-in")
// New interchange and merge regressions.
var oldSong = TrackerModule(); oldSong.samples[0] = TrackerSample(pcm:[10,20,30,40,50,60,70,80],volume:32,loopStart:2,loopLength:4)
oldSong.patterns[0][0,0] = TrackerCell(period:428,sample:1)
let oldMOD = [UInt8](try MODCodec.encode(oldSong))
var stk = Array(oldMOD[0..<470])+[UInt8(1),UInt8(125)]+Array(repeating:UInt8(0),count:128)+Array(oldMOD[1084...])
MODCodec.put16(2,in:&stk,at:46)
let decodedSTK = try MODCodec.decode(Data(stk))
expect(decodedSTK.patterns[0][0,0].period == 428 && decodedSTK.samples[0].loopStart == 2,"15-sample Soundtracker layout")
var unicode = oldSong; unicode.comment = "Grüße · 音楽"
let unicodeRoundtrip = try MODCodec.decode(MODCodec.encode(unicode,iff:true))
expect(unicodeRoundtrip.comment == unicode.comment,"UTF-8 MODL comments")
var nested = try MODCodec.encode(oldSong)
for _ in 0..<10 { nested = IFF.form("MODL",chunks:[("PTDT",[UInt8](nested))]) }
rejects(nested,"excessive nested containers rejected")
var mergePattern = TrackerPattern(); mergePattern[0,0] = TrackerCell(period:428,sample:2)
PatternEditing.paste(PatternBlock(rows:1,channels:1,cells:[TrackerCell(effect:10,parameter:3)]),into:&mergePattern,row:0,channel:0,mix:true)
expect(mergePattern[0,0].period == 428 && mergePattern[0,0].sample == 2 && mergePattern[0,0].effect == 10,"join-paste preserves notes while adding effects")
let emptyRender = TrackerReplay(module:oldSong).renderBlock(0)
expect(emptyRender.0.isEmpty && emptyRender.1.isEmpty,"zero-frame render")
let idleRender = TrackerReplay(module:oldSong).renderBlock(512)
expect(idleRender.0.allSatisfy({ $0 == 0 }),"idle renderer is silent")
var invalidPalette = TrackerPreferences(); invalidPalette.accentColor = "INVALID"
expect(!invalidPalette.valid,"invalid palette rejected")
// The audio-start guard completes once and cannot play notes after a timeout or cancellation.
final class TestAudioResult: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
let callbackQueue = DispatchQueue(label:"audio-start-check"), completionSignal = DispatchSemaphore(value:0)
let completionCount = TestAudioResult()
let cancelledRequest = AudioStartRequest(queue:callbackQueue) { _ in completionCount.increment(); completionSignal.signal() }
cancelledRequest.finish(.failure(ModuleError.invalid("timeout")))
var lateNotePlayed = false
cancelledRequest.perform { lateNotePlayed = true }
cancelledRequest.finish(.success(()))
expect(completionSignal.wait(timeout:.now()+1) == .success,"audio timeout completion delivered")
callbackQueue.sync { }
expect(!lateNotePlayed && completionCount.count == 1,"timed-out start never plays and completes once")
// Original PT3.61 PACK/PAKK with word-boundary literals and overlapping matches.
for length in [1,2,3,4,8,9,31,32,33,263,264,265,511,1024] {
    let raw = Data((0..<length).map { UInt8(truncatingIfNeeded:$0*73) })
    let packed = try PackedModules.packProtracker(raw)
    expect(try! PackedModules.unpack(packed) == raw,"PACK literal/match boundaries \(length)")
}
for length in [2,3,4,5,127,255,256,257,1024] {
    let raw = Data(repeating:65,count:length)
    expect(try! PackedModules.unpack(PackedModules.packProtracker(raw)) == raw,"PACK overlapping repeated data \(length)")
}
let packedDemo = try MODCodec.encode(demo,packed:true)
expect(try! MODCodec.decode(packedDemo) == expectedDemo,"PACK module round trip")
try packedDemo.write(to:directory.appendingPathComponent("Neon Harbor.pack"))
let largePacked = try MODCodec.encode(song,packed:true)
expect(String(data:largePacked.prefix(4),encoding:.ascii) == "PAKK","PAKK large-pattern signature")
expect(try! MODCodec.decode(largePacked) == song,"PAKK 100-pattern round trip")
let songOnly = try MODCodec.encode(song,includeSamples:false)
rejects(songOnly,"sampleless song is not silently accepted as a truncated module")
let restoredSong = try MODCodec.decode(songOnly,allowMissingSamples:true)
expect(restoredSong.patterns == song.patterns && restoredSong.samples[0].pcm == Array(repeating:0,count:song.samples[0].pcm.count),"explicit sampleless-song load keeps definitions and uses silent placeholders")
let iffSongOnly = try MODCodec.encode(song,iff:true,includeSamples:false)
expect(try! MODCodec.decode(iffSongOnly).patterns == song.patterns,"MODL song-only INFO flag")
expect(SampleEditing.clamp(.nan) == 0 && SampleEditing.clamp(.infinity) == 127 && SampleEditing.clamp(-.infinity) == -128,"non-finite DSP input handled safely")
var floatWAV = WAVWriter.header(bytes:16,rate:16574,channels:1,bits:32)
floatWAV[20] = 3
for value: UInt32 in [0x7fc00000,0x7f800000,0xff800000,0x3f000000] { floatWAV += Data(WAVWriter.le32(Int(value))) }
let floatURL = directory.appendingPathComponent("float-input.wav"); try floatWAV.write(to:floatURL)
let sanitized = try SampleAudio.load(floatURL).0
expect(sanitized.pcm.count == 4,"float WAV NaN/Inf cannot crash sample import")
try runHardwareChecks { condition,message in expect(condition,message) }
print("\(passed) checks passed, \(failed) failed; \(cases.count) original-binary vectors")
if failed > 0 { exit(1) }
