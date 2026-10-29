import Foundation
import AVFoundation

var passed = 0, failed = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
}
func rejects(_ data: Data, _ message: String) { do { _ = try MODCodec.decode(data); expect(false,message) } catch { expect(true,message) } }

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
// An exact 125 BPM / speed 6 row lasts 5292 output frames at 44.1kHz.
let core = TrackerReplay(module:decoded); core.start()
_ = core.renderBlock(5292); expect(core.row == 0,"row remains active for full tick interval")
_ = core.renderBlock(1); expect(core.row == 1,"sample-accurate row boundary")
expect(core.voices[0].position >= 2 && core.voices[0].position < 6.5,"sample stays inside loop")
let output = core.renderBlock(2000)
expect(output.0.allSatisfy { $0.isFinite && abs($0) <= 1 },"bounded finite audio")
expect(output.0.contains { abs($0) > 0.001 },"non-silent PCM output")
var tempoSong = TrackerModule(); tempoSong.patterns[0][0,0] = TrackerCell(effect:15,parameter:150)
let tempo = TrackerReplay(module:tempoSong); tempo.start(); _ = tempo.renderBlock(4410); _ = tempo.renderBlock(1)
expect(tempo.bpm == 150 && tempo.row == 1,"F96 tempo affects tick duration")
var delaySong = TrackerModule(); delaySong.patterns[0][0,0] = TrackerCell(effect:14,parameter:0xe2)
let delay = TrackerReplay(module:delaySong); delay.start(); _ = delay.renderBlock(5292*3); _ = delay.renderBlock(1)
expect(delay.row == 1,"EE2 repeats exactly two extra rows")
var loopSong = TrackerModule(); loopSong.patterns[0][0,0] = TrackerCell(effect:14,parameter:0x60); loopSong.patterns[0][1,0] = TrackerCell(effect:14,parameter:0x62)
let loop = TrackerReplay(module:loopSong); loop.start(); _ = loop.renderBlock(5292*6); _ = loop.renderBlock(1)
expect(loop.row == 2,"E62 repeats loop twice then advances")
let once = TrackerReplay(module:TrackerModule()); once.loopSong = false; once.start(); _ = once.renderBlock(5292*64+1)
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
expect(wav.length == 5292*4,"WAV stops at F00 after exactly four rows")
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
print("\(passed) checks passed, \(failed) failed; \(cases.count) original-binary vectors")
if failed > 0 { exit(1) }
