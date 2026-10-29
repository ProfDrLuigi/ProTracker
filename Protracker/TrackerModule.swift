import Foundation

struct TrackerCell: Equatable, Codable {
    var period = 0
    var sample = 0
    var effect = 0
    var parameter = 0
    var noteName: String { Notes.name(period) }
    var effectName: String { String(format: "%X%02X", effect, parameter) }
    var isEmpty: Bool { period == 0 && sample == 0 && effect == 0 && parameter == 0 }
}

struct TrackerPattern: Equatable, Codable {
    var cells = Array(repeating: TrackerCell(), count: 256)
    subscript(_ row: Int, _ channel: Int) -> TrackerCell {
        get { cells[row * 4 + channel] }
        set { cells[row * 4 + channel] = newValue }
    }
}

struct TrackerSample: Equatable, Codable {
    var name = ""
    var pcm: [Int8] = []
    var volume = 64
    var finetune = 0
    var loopStart = 0
    var loopLength = 0
    var loops: Bool { loopLength > 2 && loopStart + loopLength <= pcm.count }
    mutating func validate() {
        pcm = Array(pcm.prefix(131070))
        if pcm.count % 2 != 0 { pcm.append(0) }
        volume = min(64, max(0, volume)); finetune = min(7, max(-8, finetune))
        loopStart = min(max(0, loopStart / 2 * 2), max(0, pcm.count - 2))
        loopLength = min(max(0, loopLength / 2 * 2), pcm.count - loopStart)
        if loopLength <= 2 { loopLength = 0 }
    }
}

struct TrackerModule: Equatable, Codable {
    var title = "Untitled module"
    var samples = Array(repeating: TrackerSample(), count: 31)
    var patterns = [TrackerPattern()]
    var orders = [0]
    var initialBPM = 125
    var initialSpeed = 6
    var ciaTiming = true
    var filterEnabled = false
    var comment = ""
    var sampleBytes: Int { samples.reduce(0) { $0 + $1.pcm.count } }
    mutating func ensurePattern(_ index: Int) {
        while patterns.count <= min(127, index) { patterns.append(TrackerPattern()) }
    }
}

enum Notes {
    static let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
    static func index(_ period: Int) -> Int {
        AmigaTables.periods[0].indices.min { abs(AmigaTables.periods[0][$0] - period) < abs(AmigaTables.periods[0][$1] - period) } ?? 0
    }
    static func name(_ period: Int) -> String {
        guard period > 0 else { return "---" }
        let note = index(period)
        return names[note % 12] + String(note / 12 + 1)
    }
    static func period(_ index: Int, finetune: Int = 0) -> Int {
        AmigaTables.periods[finetune & 15][max(0, min(35, index))]
    }
}

enum ModuleError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// Decodes the 31-sample MOD layout and PT3.61's FORM/MODL/PTDT wrapper.
/// The original loader is identified at $1ED28–$1EFEA (synthetic 68000 addresses).
enum MODCodec {
    static func decode(_ data: Data) throws -> TrackerModule {
        let bytes = [UInt8](data)
        if bytes.count >= 12, ascii(bytes, 0, 4) == "FORM", ascii(bytes, 8, 4) == "MODL" {
            var mod: TrackerModule?
            var info: [UInt8]?
            var comment = ""
            for chunk in try IFF.chunks(bytes) {
                switch chunk.id {
                case "PTDT": mod = try decode(Data(chunk.data))
                case "INFO": info = chunk.data
                case "CMNT": comment = ascii(chunk.data, 0, chunk.data.count)
                default: break
                }
            }
            guard var result = mod else { throw ModuleError.invalid("MODL enthält keinen PTDT-Modulblock.") }
            if let info, info.count >= 44 {
                result.title = ascii(info, 0, 32)
                result.initialBPM = max(32, min(255, be16(info, 40)))
                let flags = be16(info, 42)
                result.ciaTiming = flags & 1 != 0
                result.filterEnabled = flags & 2 != 0
            }
            result.comment = comment
            return result
        }
        guard bytes.count >= 1084 else { throw ModuleError.invalid("Datei ist zu kurz für ein ProTracker-Modul.") }
        let signature = ascii(bytes, 1080, 4)
        guard ["M.K.", "M!K!", "4CHN", "FLT4"].contains(signature) else {
            throw ModuleError.invalid("Unterstützt werden 4-Kanal-MOD (M.K./M!K!/4CHN/FLT4) und ProTracker MODL. Kennung: \(signature)")
        }
        let count = Int(bytes[950])
        guard (1...128).contains(count) else { throw ModuleError.invalid("Ungültige Songlänge.") }
        let orderTable = bytes[952..<1080].map(Int.init)
        guard orderTable.allSatisfy({ $0 < 128 }) else { throw ModuleError.invalid("Ungültige Patternnummer.") }
        let patternCount = (orderTable.max() ?? 0) + 1
        let patternEnd = 1084 + patternCount * 1024
        guard bytes.count >= patternEnd else { throw ModuleError.invalid("Abgeschnittene Patterndaten.") }
        var module = TrackerModule()
        module.title = ascii(bytes, 0, 20)
        module.orders = Array(orderTable.prefix(count))
        module.patterns = Array(repeating: TrackerPattern(), count: patternCount)
        for pattern in 0..<patternCount {
            for cell in 0..<256 {
                let p = 1084 + pattern * 1024 + cell * 4
                let sample = Int(bytes[p] & 0xf0) | Int(bytes[p+2] >> 4)
                guard sample <= 31 else { throw ModuleError.invalid("Ungültiger Sampleindex im Pattern.") }
                module.patterns[pattern].cells[cell] = TrackerCell(
                    period: Int(bytes[p] & 15) * 256 + Int(bytes[p+1]), sample: sample,
                    effect: Int(bytes[p+2] & 15), parameter: Int(bytes[p+3]))
            }
        }
        var cursor = patternEnd
        for n in 0..<31 {
            let p = 20 + n * 30
            let length = be16(bytes, p+22) * 2
            guard cursor + length <= bytes.count else { throw ModuleError.invalid("Abgeschnittene Audiodaten in Sample \(n+1).") }
            let fine = Int(bytes[p+24] & 15)
            var sample = TrackerSample(name: ascii(bytes, p, 22),
                pcm: bytes[cursor..<cursor+length].map { Int8(bitPattern: $0) },
                volume: min(64, Int(bytes[p+25])), finetune: fine >= 8 ? fine - 16 : fine,
                loopStart: be16(bytes, p+26) * 2, loopLength: be16(bytes, p+28) * 2)
            sample.validate(); module.samples[n] = sample
            cursor += length
        }
        return module
    }

    static func encode(_ module: TrackerModule, iff: Bool = false) throws -> Data {
        var module = module
        guard module.samples.count == 31, (1...128).contains(module.orders.count),
              module.orders.allSatisfy({ module.patterns.indices.contains($0) && $0 < 128 }),
              (1...128).contains(module.patterns.count), module.patterns.allSatisfy({ $0.cells.count == 256 }) else {
            throw ModuleError.invalid("Ungültige Modulstruktur.")
        }
        // Raw MOD has no tempo header. Materialize non-default initial settings in row zero.
        var commands: [Int] = []
        if module.initialSpeed != 6 { commands.append(module.initialSpeed) }
        if !iff && module.initialBPM != 125 && module.ciaTiming { commands.append(module.initialBPM) }
        let firstPattern = module.orders[0]
        for value in commands {
            if module.patterns[firstPattern].cells.prefix(4).contains(where: { $0.effect == 15 && (($0.parameter >= 32) == (value >= 32)) }) { continue }
            guard let channel = (0..<4).first(where: { module.patterns[firstPattern][0,$0].effect == 0 && module.patterns[firstPattern][0,$0].parameter == 0 }) else {
                throw ModuleError.invalid("Für das Starttempo ist in Zeile 00 kein Effektfeld frei. Bitte Fxx im Pattern setzen.")
            }
            module.patterns[firstPattern][0,channel].effect = 15
            module.patterns[firstPattern][0,channel].parameter = value
        }
        if !iff && !module.ciaTiming { throw ModuleError.invalid("VBlank-Timing bitte im MODL-Format speichern.") }
        var bytes = [UInt8](repeating: 0, count: 1084)
        writeText(module.title, to: &bytes, at: 0, count: 20)
        for n in 0..<31 {
            module.samples[n].validate()
            let sample = module.samples[n], p = 20 + n * 30
            writeText(sample.name, to: &bytes, at: p, count: 22)
            put16(sample.pcm.count / 2, in: &bytes, at: p+22)
            bytes[p+24] = UInt8(sample.finetune & 15); bytes[p+25] = UInt8(sample.volume)
            put16(sample.loopStart / 2, in: &bytes, at: p+26)
            put16(max(1, sample.loopLength / 2), in: &bytes, at: p+28)
        }
        bytes[950] = UInt8(module.orders.count); bytes[951] = 127
        for (n, pattern) in module.orders.enumerated() { bytes[952+n] = UInt8(pattern) }
        // Preserve unreferenced edited patterns through the unused order table tail.
        if module.orders.count < 128 { bytes[1079] = UInt8(module.patterns.count - 1) }
        writeText(module.patterns.count > 64 ? "M!K!" : "M.K.", to: &bytes, at: 1080, count: 4)
        for pattern in module.patterns {
            for cell in pattern.cells {
                guard (0...4095).contains(cell.period), (0...31).contains(cell.sample),
                      (0...15).contains(cell.effect), (0...255).contains(cell.parameter) else {
                    throw ModuleError.invalid("Pattern enthält ungültige Werte.")
                }
                bytes += [UInt8((cell.sample & 0xf0) | (cell.period >> 8)), UInt8(cell.period & 255),
                          UInt8((cell.sample & 15) << 4 | cell.effect), UInt8(cell.parameter)]
            }
        }
        for sample in module.samples { bytes += sample.pcm.map { UInt8(bitPattern: $0) } }
        if !iff { return Data(bytes) }
        var info = [UInt8](repeating: 0, count: 64)
        writeText(module.title, to: &info, at: 0, count: 32)
        put16(31, in: &info, at: 32); put16(module.orders.count, in: &info, at: 34)
        put16(module.patterns.count, in: &info, at: 36); put16(64, in: &info, at: 38)
        put16(module.initialBPM, in: &info, at: 40)
        put16((module.ciaTiming ? 1 : 0) | (module.filterEnabled ? 2 : 0) | 128, in: &info, at: 42)
        return IFF.form("MODL", chunks: [("VERS", [0,0,0,1]+Array("PT3.61".utf8)),
            ("INFO", info), ("CMNT", Array(module.comment.utf8)), ("PTDT", bytes)])
    }

    static func be16(_ bytes: [UInt8], _ p: Int) -> Int { Int(bytes[p]) << 8 | Int(bytes[p+1]) }
    static func ascii(_ bytes: [UInt8], _ p: Int, _ count: Int) -> String {
        String(bytes: bytes[p..<p+count].prefix(while: { $0 != 0 }), encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func put16(_ value: Int, in bytes: inout [UInt8], at p: Int) {
        bytes[p] = UInt8((value >> 8) & 255); bytes[p+1] = UInt8(value & 255)
    }
    static func writeText(_ text: String, to bytes: inout [UInt8], at p: Int, count: Int) {
        let encoded = Array(text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(count)
        for (i, b) in encoded.enumerated() { bytes[p+i] = b }
    }
}

enum IFF {
    struct Chunk { var id: String; var data: [UInt8] }
    static func chunks(_ bytes: [UInt8]) throws -> [Chunk] {
        guard bytes.count >= 12 else { throw ModuleError.invalid("Abgeschnittenes IFF-Format.") }
        let end = 8 + be32(bytes, 4)
        guard end <= bytes.count, end >= 12 else { throw ModuleError.invalid("Ungültige IFF-Länge.") }
        var p = 12, result: [Chunk] = []
        while p + 8 <= end {
            let count = be32(bytes, p+4)
            guard count <= end - p - 8 else { throw ModuleError.invalid("Abgeschnittener IFF-Block.") }
            result.append(Chunk(id: MODCodec.ascii(bytes, p, 4), data: Array(bytes[p+8..<p+8+count])))
            p += 8 + count + (count & 1)
        }
        return result
    }
    static func be32(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) << 24 | Int(b[p+1]) << 16 | Int(b[p+2]) << 8 | Int(b[p+3]) }
    static func big32(_ v: Int) -> [UInt8] { [UInt8((v >> 24)&255),UInt8((v >> 16)&255),UInt8((v >> 8)&255),UInt8(v&255)] }
    static func form(_ kind: String, chunks: [(String, [UInt8])]) -> Data {
        var body = Array(kind.utf8)
        for (id, bytes) in chunks {
            body += Array(id.utf8) + big32(bytes.count) + bytes
            if bytes.count & 1 != 0 { body.append(0) }
        }
        return Data(Array("FORM".utf8) + big32(body.count) + body)
    }
}
