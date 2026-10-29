import Foundation

/// Native Swift depackers. SQSH follows libxmp's MIT implementation by
/// Claudio Matsuoka / Bert Jahn; PP20 follows Stuart Caie's public-domain algorithm.
/// Attribution and permission notice: SourcesLegal/Depackers.txt.
enum PackedModules {
    static let limit = 10_000_000
    static func unpack(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return data }
        let id = String(bytes:bytes.prefix(4),encoding:.ascii)
        if id == "PACK" || id == "PAKK" { return Data(try protracker(bytes)) }
        if id == "PP20" { return Data(try powerPacker(bytes)) }
        if id == "XPKF" { return Data(try xpk(bytes)) }
        if id == "PX20" { throw ModuleError.invalid("Verschlüsselte PowerPacker-Dateien benötigen ein Passwort und werden nicht unterstützt.") }
        return data
    }
    struct Bits {
        var bytes: [UInt8]
        var offset = 0
        var reverse = false
        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= 32, offset+count <= bytes.count*8 else { throw ModuleError.invalid("Abgeschnittener komprimierter Bitstrom.") }
            var value = 0
            for _ in 0..<count {
                let index = reverse ? bytes.count-1-offset/8 : offset/8
                let bit = reverse ? offset%8 : 7-offset%8
                value = (value<<1) | Int((bytes[index]>>bit)&1); offset += 1
            }
            return value
        }
        mutating func signed(_ count: Int) throws -> Int {
            let value = try read(count)
            return value & (1<<(count-1)) != 0 ? value-(1<<count) : value
        }
    }
    /// PT3.61 $23B8A–$23C28: backward decoding with a sentinel in each 32-bit word.
    static func protracker(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 16 else { throw ModuleError.invalid("Abgeschnittenes PACK-Modul.") }
        let packed = IFF.be32(b,4), size = IFF.be32(b,8)
        guard packed > 0 && packed%4 == 0 && packed <= b.count-12 && size > 0 && size <= limit && size+b.count-12-packed <= limit else { throw ModuleError.invalid("Ungültige PACK-Längen.") }
        var pointer = 12+packed-4, buffer = UInt32(IFF.be32(b,pointer))
        func bit() throws -> Int {
            var result = Int(buffer&1); buffer >>= 1
            if buffer == 0 {
                pointer -= 4
                guard pointer >= 12 else { throw ModuleError.invalid("Abgeschnittener PACK-Bitstrom.") }
                let word = UInt32(IFF.be32(b,pointer)); result = Int(word&1); buffer = (word>>1)|0x80000000
            }
            return result
        }
        func read(_ count: Int) throws -> Int { var value = 0; for _ in 0..<count { value = (value<<1) | (try bit()) }; return value }
        var output = [UInt8](repeating:0,count:size), out = size
        while out > 0 {
            var literals = false, count: Int, offsetBits = 8
            if try bit() == 0 {
                if try bit() == 0 { literals = true; count = try read(3)+1 }
                else { count = 2 }
            } else {
                let code = try read(2)
                switch code {
                case 0,1: count = code+3; offsetBits = code+9
                case 2: count = try read(8)+1
                default: literals = true; count = try read(8)+9
                }
            }
            guard count <= out else { throw ModuleError.invalid("PACK-Ausgabeüberlauf.") }
            if literals {
                for _ in 0..<count { let value = try read(8); out -= 1; output[out] = UInt8(value) }
            } else {
                let offset = try read(offsetBits)
                guard offset > 0 && out-1+offset < size else { throw ModuleError.invalid("Ungültiger PACK-Rückverweis.") }
                for _ in 0..<count { out -= 1; output[out] = output[out+offset] }
            }
        }
        return output+Array(b[(12+packed)...])
    }
    /// Same wire format as the original packer; greedy future matches are decoded backwards.
    static func packProtracker(_ data: Data, largePatterns: Bool = false) throws -> Data {
        let input = [UInt8](data)
        guard !input.isEmpty && input.count <= limit else { throw ModuleError.invalid("Ungültige PACK-Eingabe.") }
        var output: [UInt8] = [], buffer: UInt32 = 1, pending = 0, position = 0
        func emit(_ value: Int, count: Int) {
            for bit in 0..<count {
                let carry = buffer & 0x80000000 != 0
                buffer = (buffer<<1) | UInt32((value>>bit)&1)
                if carry { output += IFF.big32(Int(buffer)); buffer = 1 }
            }
        }
        func flush() {
            guard pending > 0 else { return }
            if pending < 9 { emit(pending-1,count:5) }
            else { emit((pending-9)|0x700,count:11) }
            pending = 0
        }
        while position < input.count {
            var best = 1, distance = 0
            let maxDistance = min(127,input.count-position-2)
            if maxDistance > 0 {
                for offset in 1...maxDistance where input[position] == input[position+offset] {
                    let maximum = min(256,input.count-position-offset)
                    var count = 1
                    while count < maximum && input[position+count] == input[position+offset+count] { count += 1 }
                    if count > best { best = count; distance = offset }
                    if best == 256 { break }
                }
            }
            if best >= 2 {
                flush()
                if best == 2 { emit(distance,count:8); emit(1,count:2) }
                else if best <= 4 { emit(distance,count:best == 3 ? 9 : 10); emit(best == 3 ? 4 : 5,count:3) }
                else { emit(distance,count:8); emit(best-1,count:8); emit(6,count:3) }
                position += best
            } else {
                emit(Int(input[position]),count:8); position += 1; pending += 1
                if pending == 264 { flush() }
            }
        }
        flush(); output += IFF.big32(Int(buffer))
        return Data(Array((largePatterns ? "PAKK" : "PACK").utf8)+IFF.big32(output.count)+IFF.big32(input.count)+output)
    }

    static func powerPacker(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 16, b.count%4 == 0, b[4..<8].allSatisfy({ (9...15).contains($0) }), b.last! <= 32 else { throw ModuleError.invalid("Ungültiger PP20-Header.") }
        let p = b.count-4, length = Int(b[p])<<16 | Int(b[p+1])<<8 | Int(b[p+2])
        guard length > 0 && length <= limit else { throw ModuleError.invalid("Ungültige PP20-Ausgabelänge.") }
        var bits = Bits(bytes:Array(b[8..<p]),reverse:true); _ = try bits.read(Int(b[p+3]))
        var result = [UInt8](repeating:0,count:length), out = length
        func write(_ value: UInt8) throws {
            guard out > 0 else { throw ModuleError.invalid("PP20-Ausgabeüberlauf.") }
            out -= 1; result[out] = value
        }
        while out > 0 {
            if try bits.read(1) == 0 {
                var count = 1, more: Int
                repeat { more = try bits.read(2); count += more; guard count <= out else { throw ModuleError.invalid("PP20-Literallänge ungültig.") } } while more == 3
                for _ in 0..<count { try write(UInt8(try bits.read(8))) }
                if out == 0 { break }
            }
            let code = try bits.read(2)
            var width = Int(b[4+code]), count = code+2
            if code == 3 { if try bits.read(1) == 0 { width = 7 } }
            let offset = try bits.read(width)
            if code == 3 {
                var more: Int
                repeat { more = try bits.read(3); count += more; guard count <= out else { throw ModuleError.invalid("PP20-Matchlänge ungültig.") } } while more == 7
            }
            guard count <= out, out+offset < length else { throw ModuleError.invalid("Ungültiger PP20-Rückverweis.") }
            for _ in 0..<count { let value = result[out+offset]; try write(value) }
        }
        return result
    }
    static func xpk(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 36, IFF.be32(b,4)+8 <= b.count else { throw ModuleError.invalid("Abgeschnittener XPK-Header.") }
        let codec = MODCodec.ascii(b,8,4), size = IFF.be32(b,12), end = IFF.be32(b,4)+8
        guard size > 0 && size <= limit else { throw ModuleError.invalid("Ungültige XPK-Ausgabelänge.") }
        guard codec == "SQSH" || codec == "NONE" else { throw ModuleError.invalid("XPK-Codec \(codec) ist nicht verfügbar. Unterstützt: SQSH und NONE.") }
        var p = 36, output: [UInt8] = []; output.reserveCapacity(size)
        while output.count < size {
            guard p+8 <= end else { throw ModuleError.invalid("Abgeschnittener XPK-Block.") }
            let type = b[p], checksum = MODCodec.be16(b,p+2), packed = MODCodec.be16(b,p+4), unpacked = MODCodec.be16(b,p+6)
            guard packed > 0 && unpacked > 0 && p+8+packed <= end, output.count+unpacked <= size else { throw ModuleError.invalid("Ungültige XPK-Blocklänge.") }
            let chunk = Array(b[p+8..<p+8+packed])
            var sum: UInt32 = 0
            for i in stride(from:0,to:packed,by:4) {
                var word: UInt32 = 0
                for j in 0..<4 { word = (word<<8) | (i+j<packed ? UInt32(chunk[i+j]) : 0) }
                sum ^= word
            }
            guard Int((sum^(sum>>16))&65535) == checksum else { throw ModuleError.invalid("XPK-Prüfsumme stimmt nicht.") }
            if type == 0 {
                guard packed == unpacked else { throw ModuleError.invalid("Ungültiger unkomprimierter XPK-Block.") }
                output += chunk; p += 8+packed
            } else if type == 1 && codec == "SQSH" {
                try sqsh(chunk,appendTo:&output,count:unpacked); p += 8+((packed+3) & ~3)
            } else { throw ModuleError.invalid("Unbekannter XPK-Blocktyp.") }
        }
        return output
    }
    private static func sqsh(_ bytes: [UInt8], appendTo output: inout [UInt8], count: Int) throws {
        guard bytes.count >= 3 else { throw ModuleError.invalid("Leerer SQSH-Block.") }
        let end = output.count+count
        var bits = Bits(bytes:Array(bytes.dropFirst(3))), data = Int(bytes[2]), d1 = 0, d2 = 0, oldCount = 0
        let table = [2,3,4,5,6,7,8,0,3,2,4,5,6,7,8,0,4,3,5,2,6,7,8,0,5,4,6,2,3,7,8,0,6,5,7,2,3,4,8,0,7,6,8,2,3,4,5,0,8,7,6,2,3,4,5,0]
        output.append(UInt8(truncatingIfNeeded:data))
        func copy() throws {
            let length: Int
            if try bits.read(1) == 0 { length = try bits.read(1)+2 }
            else if try bits.read(1) == 0 { length = try bits.read(1)+4 }
            else if try bits.read(1) == 0 { length = try bits.read(1)+6 }
            else if try bits.read(1) == 0 { length = try bits.read(3)+8 }
            else { length = try bits.read(5)+16 }
            let width: Int, base: Int
            if try bits.read(1) == 0 {
                if try bits.read(1) == 0 { width = 8; base = 0 } else { width = 14; base = 0x1100 }
            } else { width = 12; base = 0x100 }
            if length >= 3 { d1 = max(0,d1-(length == 3 ? 1 : 2)) }
            let offset = try bits.read(width), start = output.count-base-offset-1
            guard start >= 0, output.count+length <= end else { throw ModuleError.invalid("Ungültiger SQSH-Rückverweis.") }
            for i in 0..<length { output.append(output[start+i]) }
            data = Int(output.last!)
        }
        while output.count < end {
            let first = try bits.read(1)
            var width = 8, extra = 0
            if d1 < 8 {
                if first != 0 { try copy(); d2 -= d2>>3; continue }
            } else if first != 0 {
                if oldCount == 8 { if d2 >= 20 { extra = 1; d2 += 8 } }
                else { width = oldCount; extra = 4; d2 += 8 }
            } else {
                if try bits.read(1) == 0 { try copy(); d2 -= d2>>3; continue }
                let code: Int
                if try bits.read(1) == 0 { code = 2 }
                else if try bits.read(1) != 0 { bits.offset -= 1; code = try bits.read(3) }
                else { code = 3 }
                let index = 8*oldCount+code-17
                guard table.indices.contains(index) else { throw ModuleError.invalid("Ungültige SQSH-Codetabelle.") }
                width = table[index]
                if width != 8 { extra = 4; d2 += 8 }
                else if d2 >= 20 { extra = 1; d2 += 8 }
            }
            guard (1...8).contains(width), output.count+extra+1 <= end else { throw ModuleError.invalid("SQSH-Ausgabeüberlauf.") }
            for _ in 0...extra { data -= try bits.signed(width); output.append(UInt8(truncatingIfNeeded:data)) }
            d1 = min(31,d1+1); oldCount = width; d2 -= d2>>3
        }
    }
}
