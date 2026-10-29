import Foundation

struct TrackerPreferences: Codable, Equatable {
    var accentColor = "FF9E52"
    var scopeColor = "6EE0CF"
    var backgroundColor = "0E1114"
    var moduleFolderBookmark: Data?
    var sampleFolderBookmark: Data?
    var keepSampleBank = false
    var midiEnabled = false
    var classicKeys = false
    var decimalRows = false
    var showZeroes = false
    var flats = false
    var multiKeyboard = false
    var enabledChannels = [true,true,true,true]
    var splitKeyboard = false
    var splitSample = 1
    var splitOctave = 1
    var quantize = 1
    var metronome = false
    var metronomeRows = 4
    var countInBeats = 0
    var defaultBPM = 125
    var defaultSpeed = 6
    var interpolation = true
    var palClock = true
    var exportMinutes = 10
    static let key = "tracker.preferences.v1"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey:key), let value = try? JSONDecoder().decode(Self.self,from:data), value.valid else { return Self() }
        return value
    }
    var valid: Bool {
        [accentColor,scopeColor,backgroundColor].allSatisfy({ $0.count == 6 && Int($0,radix:16) != nil }) &&
        enabledChannels.count == 4 && (0...30).contains(splitSample) && (1...3).contains(splitOctave) &&
        (0...16).contains(quantize) && (1...16).contains(metronomeRows) && (0...8).contains(countInBeats) &&
        (32...255).contains(defaultBPM) && (1...31).contains(defaultSpeed) && (1...120).contains(exportMinutes)
    }
    func save() { if valid, let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data,forKey:Self.key) } }
}

private struct PresetMetadata: Codable {
    var name: String
    var volume: Int
    var finetune: Int
    var loopStart: Int
    var loopLength: Int
    init(_ sample: TrackerSample) { name = sample.name; volume = sample.volume; finetune = sample.finetune; loopStart = sample.loopStart; loopLength = sample.loopLength }
    var sample: TrackerSample { TrackerSample(name:name,volume:volume,finetune:finetune,loopStart:loopStart,loopLength:loopLength) }
}
struct PresetEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bank: String
    var favorite = false
    var source = ""
    var sample: TrackerSample
    enum CodingKeys: String, CodingKey { case id,name,bank,favorite,source,metadata,pcm }
    init(name: String, bank: String, source: String = "", sample: TrackerSample) {
        self.name = name; self.bank = bank; self.source = source; self.sample = sample
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(UUID.self,forKey:.id); name = try c.decode(String.self,forKey:.name)
        bank = try c.decode(String.self,forKey:.bank); favorite = try c.decode(Bool.self,forKey:.favorite)
        source = try c.decode(String.self,forKey:.source)
        guard name.utf8.count <= 320 && bank.utf8.count <= 320 && source.utf8.count <= 4096 else { throw ModuleError.invalid("Ungültige Preset-Bezeichnung.") }
        sample = try c.decode(PresetMetadata.self,forKey:.metadata).sample
        let pcm = try c.decode(Data.self,forKey:.pcm)
        guard pcm.count <= 131070 else { throw ModuleError.invalid("Preset-Sample ist zu groß.") }
        sample.pcm = pcm.map { Int8(bitPattern:$0) }; sample.validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        let metadata = PresetMetadata(sample)
        try c.encode(id,forKey:.id); try c.encode(name,forKey:.name); try c.encode(bank,forKey:.bank)
        try c.encode(favorite,forKey:.favorite); try c.encode(source,forKey:.source)
        try c.encode(metadata,forKey:.metadata); try c.encode(Data(sample.pcm.map { UInt8(bitPattern:$0) }),forKey:.pcm)
    }
}
struct PresetDocument: Codable {
    var version = 1
    var entries: [PresetEntry]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 100_000_000 else { throw ModuleError.invalid("Preset-Liste ist zu groß.") }
        let result = try JSONDecoder().decode(Self.self,from:data)
        guard result.version == 1, result.entries.count <= 2500,
              Set(result.entries.map(\.id)).count == result.entries.count,
              result.entries.reduce(0, { $0+$1.sample.pcm.count }) <= 64_000_000 else { throw ModuleError.invalid("Ungültige Preset-Liste (max. 2500 Einträge / 64 MB).") }
        return result
    }
}
