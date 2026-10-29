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
    func play(module: TrackerModule, order: Int, row: Int, pattern: Bool) throws {
        try prepare()
        lock.lock(); defer { lock.unlock() }
        replay.module = module; replay.start(order: order, row: row, patternOnly: pattern)
    }
    func stop() { lock.lock(); replay.stop(); lock.unlock() }
    func preview(module: TrackerModule, sample: Int, period: Int, channel: Int) throws {
        try prepare(); lock.lock(); defer { lock.unlock() }
        replay.module = module; replay.preview(sample: sample, period: period, channel: channel)
    }
    func configure(volume: Float, stereo: Float, filter: Bool, muted: [Bool]) {
        lock.lock(); defer { lock.unlock() }
        replay.masterVolume = volume; replay.stereoWidth = stereo; replay.amigaFilter = filter; replay.muted = muted
    }
    func snapshot() -> PlaybackSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PlaybackSnapshot(playing: replay.playing, order: replay.order, row: replay.row, bpm: replay.bpm,
            speed: replay.speed, seconds: Double(replay.frameCount)/replay.sampleRate, levels: replay.levels, scopes: replay.scopes)
    }
}

enum SampleAudio {
    static let rootRate = 3546894.6 / 214 // C-3, matching the recovered period table.
    static func load(_ url: URL) throws -> (TrackerSample, Bool) {
        if ["8svx", "iff"].contains(url.pathExtension.lowercased()) {
            let bytes = [UInt8](try Data(contentsOf: url))
            guard bytes.count >= 12, MODCodec.ascii(bytes,8,4) == "8SVX" else { throw ModuleError.invalid("Keine IFF-8SVX-Datei.") }
            let chunks = try IFF.chunks(bytes)
            guard let body = chunks.first(where: { $0.id == "BODY" }) else { throw ModuleError.invalid("8SVX enthält keine Audiodaten.") }
            var sample = TrackerSample(name: url.deletingPathExtension().lastPathComponent, pcm: body.data.prefix(131070).map { Int8(bitPattern: $0) })
            if let vhdr = chunks.first(where: { $0.id == "VHDR" })?.data, vhdr.count >= 20 {
                guard vhdr[15] == 0 else { throw ModuleError.invalid("Komprimierte 8SVX-Samples werden nicht unterstützt.") }
                sample.loopStart = IFF.be32(vhdr,0); sample.loopLength = IFF.be32(vhdr,4)
            }
            sample.validate(); return (sample, body.data.count > 131070)
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
            pcm.append(Int8(max(-128,min(127,Int((value*127).rounded())))))
        }
        var sample = TrackerSample(name: url.deletingPathExtension().lastPathComponent, pcm: pcm)
        sample.validate()
        return (sample, Double(file.length)/format.sampleRate * rootRate > 131070)
    }
    static func wav(sample: TrackerSample) -> Data {
        let pcm = sample.pcm.map { UInt8(Int($0)+128) }
        return WAVWriter.header(bytes: pcm.count, rate: Int(rootRate.rounded()), channels: 1, bits: 8) + Data(pcm)
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
    static func export(module: TrackerModule, to url: URL, volume: Float, stereo: Float, filter: Bool, muted: [Bool]) throws -> Bool {
        let core = TrackerReplay(module: module)
        core.masterVolume = volume; core.stereoWidth = stereo; core.amigaFilter = filter; core.muted = muted
        core.loopSong = false; core.start()
        let staging = url.deletingLastPathComponent().appendingPathComponent(".protracker-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: header(bytes: 0)) else { throw ModuleError.invalid("WAV-Datei konnte nicht angelegt werden.") }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.seek(toOffset: 44)
        var total = 0
        while core.playing && total < 44100 * 60 * 10 {
            let before = core.frameCount
            let (left,right) = core.renderBlock(2048)
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
