import Foundation

/// Nominal clocks and non-interlaced beam timing from the Commodore HRM.
/// All device deadlines are integer color clocks (CCK). One CIA E-clock = five CCK.
enum AmigaStandard: Equatable {
    case pal, ntsc
    var clock: UInt64 { self == .pal ? 3_546_895 : 3_579_545 }
    var tempoDividend: Int { self == .pal ? 0x1b0f87 : 0x1b4f4d } // PT3.61 $114E6/$114EE
    var fieldCycles: UInt64 { self == .pal ? 227*312 : (227+228)*131 }
    func lineLength(_ line: UInt64) -> UInt64 { self == .ntsc && line&1 != 0 ? 228 : 227 }
    func timerLatch(bpm: Int) -> UInt16 { UInt16(tempoDividend/max(32,min(255,bpm))) }
}

/// The 8520 interval-timer register subset used by the original replay.
/// Latch writes while running don't alter the counter; force-load does.
/// Counter underflow is after latch+1 E-clocks, including the zero count.
struct CIAIntervalTimer {
    private(set) var latch: UInt16 = 0xffff
    private(set) var counter: UInt16 = 0xffff
    private(set) var control: UInt8 = 0
    private(set) var interruptPending = false
    private(set) var interruptMask = false
    private(set) var underflows: UInt64 = 0
    var running: Bool { control&1 != 0 }
    var oneShot: Bool { control&8 != 0 }
    var irq: Bool { interruptPending && interruptMask }
    mutating func writeLow(_ value: UInt8) { latch = latch&0xff00 | UInt16(value) }
    mutating func writeHigh(_ value: UInt8) {
        latch = latch&0x00ff | UInt16(value)<<8
        if !running { counter = latch }
        if oneShot { counter = latch; control |= 1 }
    }
    mutating func writeControl(_ value: UInt8) {
        control = value&0xef
        if value&0x10 != 0 { counter = latch }
    }
    mutating func writeICR(_ value: UInt8) { if value&1 != 0 { interruptMask = value&0x80 != 0 } }
    mutating func readICR() -> UInt8 {
        let value: UInt8 = (interruptPending ? 1 : 0) | (irq ? 0x80 : 0)
        interruptPending = false; return value
    }
    @discardableResult mutating func advance(eClocks: UInt64) -> UInt64 {
        guard running && control&0x20 == 0 else { return 0 }
        var remaining = eClocks, fired: UInt64 = 0
        let first = UInt64(counter)+1
        if remaining < first { counter -= UInt16(remaining); return 0 }
        remaining -= first; fired = 1; counter = latch
        if oneShot { control &= 0xfe }
        else {
            let period = UInt64(latch)+1
            fired += remaining/period; counter -= UInt16(remaining%period)
        }
        interruptPending = true; underflows += fired; return fired
    }
}

/// Rational host-sample/CCK conversion: changing buffer sizes cannot move chip events.
struct AmigaSampleClock {
    let clock: UInt64
    let rate: UInt64
    private(set) var cycle: UInt64 = 0
    private(set) var phase: UInt64 = 0
    private(set) var samples: UInt64 = 0
    init(standard: AmigaStandard, rate: Int) { clock = standard.clock; self.rate = UInt64(max(1,rate)) }
    mutating func next() -> UInt64 {
        phase += clock; cycle += phase/rate; phase %= rate; samples += 1; return cycle
    }
}
