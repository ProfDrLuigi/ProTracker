import Foundation

/// Four independent audio state machines plus the reserved Agnus audio DMA slots.
/// Register writes and output edges are stamped in integer CCK, independently of the Mac rate.
/// This is an audio-device model, not a 68000/whole-machine emulator. See HARDWARE.md.
final class PaulaChip {
    enum State: Int { case idle = 0, starting = 1, high = 2, low = 3, waiting = 5 }
    struct Channel {
        var location: UInt32 = 0
        var length: UInt16 = 0
        var period: UInt16 = 0
        var volume = 0
        var pointer: UInt32 = 0
        var remaining = 0
        var data: UInt16 = 0
        var buffer: UInt16 = 0
        var dataAddress: UInt32 = 0
        var bufferAddress: UInt32 = 0
        var state = State.idle
        var sample: Int8 = 0
        var output = 0
        var request = false
        var restartRequested = false
        var transferRestart = false
        var pendingInterrupt = false
        var fetchCycle = UInt64.max
        var sampleCycle = UInt64.max
        var manualCheckCycle = UInt64.max
        var manualStop = false
        var fetchedWords: UInt64 = 0
        var underruns: UInt64 = 0
        var freshData = false
        var deliveryCycle = UInt64.max
        var transferWord: UInt16 = 0
        var transferAddress: UInt32 = 0
        var interruptCycle = UInt64.max
        var pwmOrigin: UInt64 = 0
        var pwmCycle = UInt64.max
    }
    struct Event: Equatable, Codable {
        enum Kind: String, Codable { case write, dma, sample, interrupt, state }
        var cycle: UInt64
        var kind: Kind
        var channel: Int
        var value: Int
        var address: UInt32 = 0
    }
    let standard: AmigaStandard
    let pointerMask: UInt32
    private(set) var cycle: UInt64 = 0
    private(set) var channels = Array(repeating:Channel(),count:4)
    private(set) var dmaControl: UInt16 = 0
    private(set) var interruptRequest: UInt16 = 0
    private(set) var interruptEnable: UInt16 = 0
    private(set) var attachment: UInt16 = 0
    private var nextLine: UInt64 = 0
    private var line: UInt64 = 0
    var traceEnabled = false
    private(set) var trace: [Event] = []
    var readWord: (UInt32) -> UInt16 = { _ in 0 }
    var onOutput: ((Int,Int,UInt64) -> Void)?
    var onInterrupt: ((Int,UInt64) -> Void)?
    init(standard: AmigaStandard = .pal, pointerMask: UInt32 = 0x1ffffe) { self.standard = standard; self.pointerMask = pointerMask }
    var irq: Bool { interruptEnable&0x4000 != 0 && interruptEnable&interruptRequest&0x0780 != 0 }
    func clearTrace() { trace.removeAll(keepingCapacity:true) }
    private func record(_ kind: Event.Kind, _ channel: Int, _ value: Int, address: UInt32 = 0) {
        if traceEnabled && trace.count < 65536 { trace.append(Event(cycle:cycle,kind:kind,channel:channel,value:value,address:address)) }
    }
    private func dmaEnabled(_ n: Int) -> Bool { dmaControl&0x0200 != 0 && dmaControl&(1<<n) != 0 }
    private func attachVolume(_ n: Int) -> Bool { attachment&(1<<n) != 0 }
    private func attachPeriod(_ n: Int) -> Bool { attachment&(0x10<<n) != 0 }
    private func normalRequests(_ n: Int) -> Bool { !attachPeriod(n) || attachVolume(n) }
    private func period(_ n: Int) -> UInt64 { channels[n].period == 0 ? 65536 : UInt64(channels[n].period) }
    private func setOutput(_ n: Int) {
        // Paula's six-bit volume counter gates the DAC, rather than multiplying
        // the sample by a floating amplitude. Its PWM phase persists across bytes.
        let phase = Int((cycle-channels[n].pwmOrigin)&63), volume = channels[n].volume
        let audible = volume == 64 || phase < volume
        let value = (attachVolume(n) || attachPeriod(n) || !audible) ? 0 : Int(channels[n].sample)*64
        if volume > 0 && volume < 64 && channels[n].sample != 0 && !attachVolume(n) && !attachPeriod(n) {
            let wait = phase < volume ? volume-phase : 64-phase
            channels[n].pwmCycle = cycle+UInt64(wait)
        } else { channels[n].pwmCycle = .max }
        if channels[n].output != value {
            channels[n].output = value; record(.sample,n,value); onOutput?(n,value,cycle)
        }
    }
    private func setSample(_ n: Int, high: Bool) {
        channels[n].sample = Int8(bitPattern:UInt8(truncatingIfNeeded:high ? channels[n].buffer>>8 : channels[n].buffer))
        setOutput(n)
    }
    private func interrupt(_ n: Int) {
        // The request reaches INTREQ on the following CCK.
        channels[n].interruptCycle = min(channels[n].interruptCycle,cycle+1)
    }
    private func setState(_ n: Int, _ state: State) { channels[n].state = state; record(.state,n,state.rawValue) }
    /// W offsets are relative to $DFF000. SET/CLR applies to DMACON, INTENA, INTREQ, ADKCON.
    func write(_ offset: Int, _ value: UInt16) {
        record(.write,(offset >= 0xa0 && offset < 0xe0) ? (offset-0xa0)/16 : -1,Int(value),address:UInt32(offset))
        func setClear(_ old: UInt16) -> UInt16 { value&0x8000 != 0 ? old | (value&0x7fff) : old & ~value }
        switch offset {
        case 0x96:
            let old = (0..<4).map { dmaEnabled($0) }; dmaControl = setClear(dmaControl)&0x07ff
            for n in 0..<4 {
                if !old[n] && dmaEnabled(n) && channels[n].state == .idle {
                    channels[n].remaining = channels[n].length == 0 ? 65536 : Int(channels[n].length)
                    channels[n].request = true; channels[n].restartRequested = true; setState(n,.starting)
                } else if old[n] && !dmaEnabled(n) {
                    channels[n].request = false
                    if channels[n].state == .low && channels[n].sampleCycle != .max {
                        channels[n].manualCheckCycle = max(cycle,channels[n].sampleCycle-1)
                    }
                    if channels[n].state == .starting || channels[n].state == .waiting { setState(n,.idle) }
                }
            }
        case 0x9a: interruptEnable = setClear(interruptEnable)&0x7fff
        case 0x9c: interruptRequest = setClear(interruptRequest)&0x7fff
        case 0x9e:
            attachment = setClear(attachment)&0x7fff
            for n in 0..<4 { setOutput(n) }
        default:
            guard offset >= 0xa0 && offset < 0xe0 else { return }
            let n = (offset-0xa0)/16
            switch offset&15 {
            case 0: channels[n].location = ((channels[n].location&0xffff) | UInt32(value)<<16)&pointerMask
            case 2: channels[n].location = ((channels[n].location&0xffff0000) | UInt32(value))&pointerMask
            case 4: channels[n].length = value
            case 6: channels[n].period = value // Doesn't reload the current countdown.
            case 8: channels[n].volume = value&0x40 != 0 ? 64 : Int(value&63); setOutput(n)
            case 10:
                channels[n].data = value; channels[n].dataAddress = 0; channels[n].freshData = true
                if channels[n].state == .idle && !dmaEnabled(n) && interruptRequest&UInt16(0x80<<n) == 0 {
                    channels[n].buffer = value; channels[n].freshData = false
                    setState(n,.high); channels[n].sampleCycle = cycle+period(n); setSample(n,high:true); interrupt(n)
                }
            default: break
            }
        }
    }
    func writeLocation(_ n: Int, _ address: UInt32) { write(0xa0+n*16,UInt16(truncatingIfNeeded:address>>16)); write(0xa2+n*16,UInt16(truncatingIfNeeded:address)) }
    /// Native-player restart adapter. Raw hardware tests use only write()/advance().
    /// The Swift player doesn't execute the original 68000 interrupt prologue.
    func restart(_ n: Int) {
        write(0x96,UInt16(1<<n)); write(0x9c,UInt16(0x80<<n))
        channels[n] = Channel(); onOutput?(n,0,cycle)
    }
    func silence(_ n: Int) {
        write(0x96,UInt16(1<<n)); channels[n].sampleCycle = .max; channels[n].fetchCycle = .max
        channels[n].request = false; channels[n].deliveryCycle = .max; channels[n].interruptCycle = .max; channels[n].manualCheckCycle = .max
        setState(n,.idle); channels[n].sample = 0; setOutput(n)
    }
    private func lineStart() {
        for n in 0..<4 {
            if dmaEnabled(n) && channels[n].request {
                channels[n].fetchCycle = cycle+13+UInt64(n*2)
                channels[n].transferRestart = channels[n].restartRequested
                channels[n].request = false; channels[n].restartRequested = false
            }
        }
        nextLine += standard.lineLength(line); line += 1
    }
    private func fetch(_ n: Int) {
        channels[n].fetchCycle = .max
        let address = channels[n].pointer&pointerMask, data = readWord(address)
        channels[n].fetchedWords += 1; record(.dma,n,Int(data),address:address)
        channels[n].transferWord = data; channels[n].transferAddress = address
        channels[n].pointer = channels[n].transferRestart ? channels[n].location : (address+2)&pointerMask
        channels[n].data = data; channels[n].dataAddress = address; channels[n].freshData = true
        if (channels[n].state == .high || channels[n].state == .low) && channels[n].remaining == 1 { channels[n].pendingInterrupt = true }
        channels[n].deliveryCycle = cycle+1
    }
    private func receive(_ n: Int) {
        channels[n].deliveryCycle = .max
        guard dmaEnabled(n) && channels[n].state != .idle else { return }
        let address = channels[n].dataAddress, data = channels[n].data
        if channels[n].state == .starting {
            // Priming transfer is discarded; Agnus restarts at AUDxLC for real data.
            channels[n].request = true; channels[n].restartRequested = channels[n].remaining == 1
            if channels[n].remaining != 1 { channels[n].remaining -= 1 }
            setState(n,.waiting); interrupt(n); return
        }
        if channels[n].state != .waiting {
            if channels[n].remaining == 1 { channels[n].remaining = channels[n].length == 0 ? 65536 : Int(channels[n].length) }
            else { channels[n].remaining = (channels[n].remaining-1)&0xffff }
        }
        if channels[n].state == .waiting {
            channels[n].buffer = data; channels[n].bufferAddress = address; channels[n].freshData = false; setState(n,.high)
            channels[n].pwmOrigin = cycle
            if attachVolume(n) { attach(n,volume:true) }
            channels[n].sampleCycle = cycle+period(n); setSample(n,high:true)
            if normalRequests(n) { channels[n].request = true; channels[n].restartRequested = channels[n].remaining == 1 }
            if channels[n].pendingInterrupt { channels[n].pendingInterrupt = false; interrupt(n) }
        }
    }
    private func attach(_ n: Int, volume: Bool) {
        guard n < 3 else { return }
        write(0xa0+(n+1)*16+(volume ? 8 : 6),channels[n].data)
    }
    private func sampleEdge(_ n: Int) {
        switch channels[n].state {
        case .high:
            setState(n,.low)
            if attachPeriod(n) {
                attach(n,volume:false)
                channels[n].buffer = channels[n].data; channels[n].bufferAddress = channels[n].dataAddress
                channels[n].freshData = false; channels[n].request = dmaEnabled(n); channels[n].restartRequested = channels[n].remaining == 1
                if channels[n].pendingInterrupt || !dmaEnabled(n) { channels[n].pendingInterrupt = false; interrupt(n) }
            }
            if !dmaEnabled(n) {
                channels[n].manualStop = interruptRequest&UInt16(0x80<<n) != 0
                if period(n) > 1 { channels[n].manualCheckCycle = cycle+period(n)-1 }
            }
            setSample(n,high:false)
        case .low:
            if !dmaEnabled(n) && channels[n].manualStop {
                setState(n,.idle); channels[n].sampleCycle = .max; return
            }
            if !channels[n].freshData && dmaEnabled(n) { channels[n].underruns += 1 }
            channels[n].buffer = channels[n].data; channels[n].bufferAddress = channels[n].dataAddress; channels[n].freshData = false
            setState(n,.high)
            if attachVolume(n) { attach(n,volume:true) }
            setSample(n,high:true)
            if dmaEnabled(n) {
                if normalRequests(n) { channels[n].request = true; channels[n].restartRequested = channels[n].remaining == 1 }
                if channels[n].pendingInterrupt && normalRequests(n) { channels[n].pendingInterrupt = false; interrupt(n) }
            } else { interrupt(n) }
        default: channels[n].sampleCycle = .max; return
        }
        channels[n].sampleCycle = cycle+period(n)
    }
    /// Event driven, but all events occur on the same integer CCK grid as a cycle loop.
    /// DMA data arrives before a period expiration at the same CCK.
    func advance(to target: UInt64) {
        precondition(target >= cycle)
        while true {
            var next = nextLine
            for n in 0..<4 {
                next = min(next,channels[n].fetchCycle,channels[n].deliveryCycle,channels[n].sampleCycle,channels[n].manualCheckCycle,channels[n].interruptCycle,channels[n].pwmCycle)
            }
            if next > target { break }
            cycle = next
            if nextLine == cycle { lineStart() }
            for n in 0..<4 where channels[n].fetchCycle == cycle { fetch(n) }
            for n in 0..<4 where channels[n].deliveryCycle == cycle { receive(n) }
            for n in 0..<4 where channels[n].manualCheckCycle == cycle {
                channels[n].manualCheckCycle = .max; channels[n].manualStop = interruptRequest&UInt16(0x80<<n) != 0
            }
            for n in 0..<4 where channels[n].sampleCycle == cycle { sampleEdge(n) }
            for n in 0..<4 where channels[n].pwmCycle == cycle { setOutput(n) }
            for n in 0..<4 where channels[n].interruptCycle == cycle {
                channels[n].interruptCycle = .max
                interruptRequest |= UInt16(0x80<<n); record(.interrupt,n,1); onInterrupt?(n,cycle)
            }
        }
        cycle = target
    }
}
