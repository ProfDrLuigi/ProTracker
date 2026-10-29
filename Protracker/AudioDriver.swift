import AVFoundation
import Foundation

struct PlaybackSnapshot {
    var playing: Bool
    var order: Int
    var row: Int
    var bpm: Int
    var speed: Int
    var seconds: Double
    var levels: [Float]
    var scopes: [[Float]]
    var countIn: Bool
    var tick: Int
}

/// Audio state is shared only through this lock. UI polling never runs on the render callback.
final class AudioDriver: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var source: AVAudioSourceNode?
    private var replay = TrackerReplay(module: TrackerModule())
    private var configured = false

    func prepare() throws {
        guard !configured else { if !engine.isRunning { try engine.start() }; return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frames, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            guard let self else {
                left.initialize(repeating: 0, count: Int(frames)); right.initialize(repeating: 0, count: Int(frames)); return noErr
            }
            self.lock.lock()
            self.replay.render(frames: Int(frames), left: left, right: right)
            self.lock.unlock()
            return noErr
        }
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node; configured = true
        try engine.start()
    }
    func update(_ module: TrackerModule) {
        lock.lock()
        if module.initialBPM != replay.module.initialBPM { replay.bpm = module.initialBPM }
        if module.initialSpeed != replay.module.initialSpeed { replay.speed = module.initialSpeed }
        replay.module = module
        lock.unlock()
    }
    private let operationQueue = DispatchQueue(label:"Protracker.audio-start",qos:.userInitiated)
    private let requestLock = NSLock()
    private var requests: [UUID:AudioStartRequest] = [:]
    private func startAsync(_ body: @escaping @Sendable () -> Void, completion: @escaping @Sendable (Result<Void,Error>) -> Void) {
        requestLock.lock()
        guard requests.count < 32 else {
            requestLock.unlock()
            DispatchQueue.main.async { completion(.failure(ModuleError.invalid("Das Audiogerät wird noch initialisiert. Bitte dessen Verfügbarkeit in macOS prüfen."))) }; return
        }
        let id = UUID(), request = AudioStartRequest(completion:completion)
        requests[id] = request; requestLock.unlock()
        DispatchQueue.global().asyncAfter(deadline:.now()+5) {
            request.finish(.failure(ModuleError.invalid("Das Audiogerät antwortet nicht. Bitte die Audioausgabe in den macOS-Systemeinstellungen prüfen. Der Editor und WAV-Export bleiben verfügbar.")))
        }
        operationQueue.async {
            defer { self.requestLock.lock(); self.requests.removeValue(forKey:id); self.requestLock.unlock() }
            do { try self.prepare(); request.perform(body) }
            catch { request.finish(.failure(error)) }
        }
    }
    func playAsync(module: TrackerModule, order: Int, row: Int, pattern: Bool, countIn: Int = 0,
                   completion: @escaping @Sendable (Result<Void,Error>) -> Void) {
        startAsync({
            self.lock.lock(); defer { self.lock.unlock() }
            self.replay.module = module; self.replay.start(order:order,row:row,patternOnly:pattern)
            self.replay.countInRemaining = countIn*module.initialSpeed*4
        },completion:completion)
    }
    func stop() {
        requestLock.lock(); let pending = Array(requests.values); requestLock.unlock()
        for request in pending { request.finish(.failure(ModuleError.invalid("Audiostart abgebrochen."))) }
        lock.lock(); replay.stop(); lock.unlock()
    }
    func releasePreview(channel: Int) { lock.lock(); if !replay.playing && (0..<4).contains(channel) { replay.voices[channel].active = false }; lock.unlock() }
    func previewAsync(module: TrackerModule, sample: Int, period: Int, channel: Int, volume: Int? = nil,
                      completion: @escaping @Sendable (Result<Void,Error>) -> Void) {
        startAsync({
            self.lock.lock(); defer { self.lock.unlock() }
            self.replay.module = module; self.replay.preview(sample:sample,period:period,channel:channel)
            if let volume { self.replay.voices[channel].volume = min(64,max(0,volume)); self.replay.voices[channel].outputVolume = self.replay.voices[channel].volume }
        },completion:completion)
    }
    func configure(volume: Float, stereo: Float, filter: Bool, muted: [Bool], preferences: TrackerPreferences = TrackerPreferences()) {
        lock.lock(); defer { lock.unlock() }
        replay.masterVolume = volume; replay.stereoWidth = stereo; replay.amigaFilter = filter; replay.muted = muted
        replay.smoothResampling = preferences.interpolation; replay.palClock = preferences.palClock
        replay.metronome = preferences.metronome; replay.metronomeRows = preferences.metronomeRows
    }
    func snapshot() -> PlaybackSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PlaybackSnapshot(playing: replay.playing, order: replay.order, row: replay.row, bpm: replay.bpm,
            speed: replay.speed, seconds: Double(replay.frameCount)/replay.sampleRate, levels: replay.levels, scopes: replay.scopes,countIn:replay.countInRemaining > 0,tick:replay.tick)
    }
}

/// Completion is delivered once, and a timed-out request can never trigger notes later.
final class AudioStartRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    private let completion: @Sendable (Result<Void,Error>) -> Void
    private let queue: DispatchQueue
    init(queue: DispatchQueue = .main, completion: @escaping @Sendable (Result<Void,Error>) -> Void) { self.completion = completion; self.queue = queue }
    func finish(_ result: Result<Void,Error>) {
        lock.lock(); guard pending else { lock.unlock(); return }; pending = false; lock.unlock()
        queue.async { self.completion(result) }
    }
    func perform(_ body: () -> Void) {
        lock.lock(); guard pending else { lock.unlock(); return }
        body(); pending = false; lock.unlock()
        queue.async { self.completion(.success(())) }
    }
}

enum SampleAudio {
    static let rootRate = 3546894.6 / 214 // C-3, matching the recovered period table.
    static func load(_ url: URL) throws -> (TrackerSample, Bool) {
        if ["8svx", "iff"].contains(url.pathExtension.lowercased()) {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else { throw ModuleError.invalid("8SVX-Datei ist zu groß.") }
            let bytes = [UInt8](try Data(contentsOf: url))
            guard bytes.count >= 12, MODCodec.ascii(bytes,8,4) == "8SVX" else { throw ModuleError.invalid("Keine IFF-8SVX-Datei.") }
            let chunks = try IFF.chunks(bytes)
            guard let body = chunks.first(where: { $0.id == "BODY" }) else { throw ModuleError.invalid("8SVX enthält keine Audiodaten.") }
            var pcm = body.data.map { Int8(bitPattern:$0) }, volume = 64, start = 0, length = 0
            if let vhdr = chunks.first(where:{ $0.id == "VHDR" })?.data, vhdr.count >= 20 {
                start = IFF.be32(vhdr,0); length = IFF.be32(vhdr,4)
                volume = min(64,IFF.be32(vhdr,16)/1024)
                if vhdr[15] == 1 {
                    guard body.data.count >= 2 else { throw ModuleError.invalid("Abgeschnittenes Fibonacci-8SVX.") }
                    let table = [-34,-21,-13,-8,-5,-3,-2,-1,0,1,2,3,5,8,13,21]
                    var current = Int(Int8(bitPattern:body.data[1])); pcm = []
                    for byte in body.data.dropFirst(2).prefix(65535) {
                        for nibble in [Int(byte>>4),Int(byte&15)] { current += table[nibble]; pcm.append(Int8(truncatingIfNeeded:current)) }
                    }
                } else if vhdr[15] != 0 { throw ModuleError.invalid("Unbekannte 8SVX-Kompression.") }
            }
            let name = chunks.first(where:{ $0.id == "NAME" }).map { MODCodec.ascii($0.data,0,$0.data.count) } ?? url.deletingPathExtension().lastPathComponent
            var sample = TrackerSample(name:name,pcm:Array(pcm.prefix(131070)),volume:volume,loopStart:start,loopLength:length)
            sample.validate(); return (sample,pcm.count > 131070)
        }
        if ["raw","smp"].contains(url.pathExtension.lowercased()) {
            let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
            let data = try file.read(upToCount:131072) ?? Data()
            var sample = TrackerSample(name:url.deletingPathExtension().lastPathComponent,pcm:data.prefix(131070).map { Int8(bitPattern:$0) })
            sample.validate(); return (sample,data.count > 131070)
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let needed = min(file.length, AVAudioFramePosition(ceil(131071 / rootRate * format.sampleRate)))
        guard needed > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(needed)) else { throw ModuleError.invalid("Leere Audiodatei.") }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { throw ModuleError.invalid("Audiodatei lässt sich nicht als PCM lesen.") }
        let length = min(131070, Int(Double(buffer.frameLength) * rootRate / format.sampleRate))
        var pcm = [Int8](); pcm.reserveCapacity(length)
        for n in 0..<length {
            let pos = Double(n) * format.sampleRate / rootRate
            let a = min(Int(buffer.frameLength)-1,Int(pos)), b = min(Int(buffer.frameLength)-1,a+1)
            var value: Float = 0
            for ch in 0..<Int(format.channelCount) {
                value += channels[ch][a] + (channels[ch][b]-channels[ch][a]) * Float(pos-Double(a))
            }
            value /= Float(format.channelCount)
            pcm.append(SampleEditing.clamp(Double(value)*127))
        }
        var sample = TrackerSample(name: url.deletingPathExtension().lastPathComponent, pcm: pcm)
        if url.pathExtension.lowercased() == "wav", let data = try? Data(contentsOf:url,options:.mappedIfSafe) {
            let b = [UInt8](data.prefix(16_000_000)); var p = 12
            while p+8 <= b.count {
                let size = Int(b[p+4]) | Int(b[p+5])<<8 | Int(b[p+6])<<16 | Int(b[p+7])<<24
                guard size >= 0, size <= b.count-p-8 else { break }
                if String(bytes:b[p..<p+4],encoding:.ascii) == "smpl", size >= 60 {
                    func little(_ a: Int) -> Int { Int(b[a]) | Int(b[a+1])<<8 | Int(b[a+2])<<16 | Int(b[a+3])<<24 }
                    if little(p+36) > 0 {
                        let a = little(p+52), z = little(p+56)+1
                        if z > a { sample.loopStart = Int(Double(a)*rootRate/format.sampleRate); sample.loopLength = Int(Double(z-a)*rootRate/format.sampleRate) }
                    }
                    break
                }
                p += 8+size+(size&1)
            }
        }
        sample.validate()
        return (sample, Double(file.length)/format.sampleRate * rootRate > 131070)
    }
    static func wav(sample: TrackerSample) -> Data {
        let pcm = sample.pcm.map { UInt8(Int($0)+128) }
        var data = WAVWriter.header(bytes: pcm.count, rate: Int(rootRate.rounded()), channels: 1, bits: 8) + Data(pcm)
        if sample.loops {
            let values = [0,0,Int(1_000_000_000/rootRate),60,0,0,0,1,0,0,0,sample.loopStart,sample.loopStart+sample.loopLength-1,0,0]
            data += Data(Array("smpl".utf8)+WAVWriter.le32(60)+values.flatMap { WAVWriter.le32($0) })
            data.replaceSubrange(4..<8,with:WAVWriter.le32(data.count-8))
        }
        return data
    }
    static func svx(sample: TrackerSample) -> Data {
        let start = sample.loops ? sample.loopStart : sample.pcm.count, loop = sample.loops ? sample.loopLength : 0
        let header = IFF.big32(start)+IFF.big32(loop)+IFF.big32(0)+[UInt8(Int(rootRate)>>8),UInt8(Int(rootRate)&255),1,0]+IFF.big32(sample.volume*1024)
        return IFF.form("8SVX",chunks:[("VHDR",header),("NAME",Array(sample.name.utf8)),("BODY",sample.pcm.map { UInt8(bitPattern:$0) })])
    }
}

enum WAVWriter {
    static func le16(_ n: Int) -> [UInt8] { [UInt8(n&255),UInt8((n>>8)&255)] }
    static func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> ($0*8))&255) } }
    static func header(bytes: Int, rate: Int = 44100, channels: Int = 2, bits: Int = 16) -> Data {
        Data(Array("RIFF".utf8)+le32(bytes+36)+Array("WAVEfmt ".utf8)+le32(16)+le16(1)+le16(channels)+le32(rate)+le32(rate*channels*bits/8)+le16(channels*bits/8)+le16(bits)+Array("data".utf8)+le32(bytes))
    }
    /// One song traversal, including E6 loops. Bxx backwards ends the traversal.
    /// A bounded export avoids unbounded files for deliberately looping modules.
    static func export(module: TrackerModule, to url: URL, volume: Float, stereo: Float, filter: Bool, muted: [Bool], preferences: TrackerPreferences = TrackerPreferences()) throws -> Bool {
        guard preferences.valid else { throw ModuleError.invalid("Ungültige Export-Einstellungen.") }
        let core = TrackerReplay(module: module)
        core.masterVolume = volume; core.stereoWidth = stereo; core.amigaFilter = filter; core.muted = muted
        core.smoothResampling = preferences.interpolation; core.palClock = preferences.palClock
        core.loopSong = false; core.start()
        let staging = url.deletingLastPathComponent().appendingPathComponent(".protracker-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: header(bytes: 0)) else { throw ModuleError.invalid("WAV-Datei konnte nicht angelegt werden.") }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.seek(toOffset: 44)
        var total = 0
        while core.playing && total < 44100 * 60 * preferences.exportMinutes {
            let before = core.frameCount
            let (left,right) = core.renderBlock(min(2048,44100*60*preferences.exportMinutes-total))
            let length = core.frameCount-before
            var bytes = [UInt8](); bytes.reserveCapacity(length*4)
            for frame in 0..<length {
                for value in [left[frame],right[frame]] {
                    let sample = Int16(max(-32768,min(32767,Int(value*32767))))
                    bytes += le16(Int(UInt16(bitPattern: sample)))
                }
            }
            try handle.write(contentsOf: Data(bytes)); total += length
        }
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header(bytes: total*4))
        try handle.synchronize(); try handle.close()
        // NSData's atomic writer replaces the destination only after the render succeeded.
        try Data(contentsOf: staging, options: .mappedIfSafe).write(to: url, options: .atomic)
        return core.playing
    }
}
