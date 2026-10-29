import Foundation

/// Adapter between the native tracker and the cycle-based audio devices.
/// The chip models can also be driven directly by timestamped register traces.
/// Native tracker register batches have no emulated 68000 instruction latency.
final class AmigaReplayHardware {
    private weak var replay: TrackerReplay?
    let standard: AmigaStandard
    let rate: Int
    let paula: PaulaChip
    private(set) var timer = CIAIntervalTimer()
    private(set) var sampleClock: AmigaSampleClock
    private(set) var nextTick: UInt64 = 0
    private var timerCycle: UInt64 = 0
    private var programmedBPM: Int
    private var serials = [Int](repeating:-1,count:4)
    private var loopPending = [Bool](repeating:false,count:4)
    private var periods = [Int](repeating:-1,count:4)
    private var volumes = [Int](repeating:-1,count:4)
    private let dac: BandLimitedDAC
    var hasSignal: Bool { dac.hasSignal }
    init(replay: TrackerReplay, rate: Int) {
        self.replay = replay; self.rate = rate; standard = replay.palClock ? .pal : .ntsc
        programmedBPM = replay.module.ciaTiming ? replay.bpm : 125
        sampleClock = AmigaSampleClock(standard:standard,rate:rate)
        // Virtual sample banks avoid a Chip-RAM size limit in the native editor.
        // Physical pointer masking is exercised separately with PaulaChip's 2 MB default.
        paula = PaulaChip(standard:standard,pointerMask:0x7ffffe)
        dac = BandLimitedDAC(clock:standard.clock,rate:rate,outputRate:replay.sampleRate)
        let latch = standard.timerLatch(bpm:programmedBPM)
        timer.writeLow(UInt8(truncatingIfNeeded:latch)); timer.writeHigh(UInt8(latch>>8)); timer.writeControl(0x11); timer.writeICR(0x81)
        paula.write(0x9a,0xc780)
        paula.readWord = { [weak replay] address in
            guard let replay else { return 0 }
            let slot = Int(address>>17)-1, position = Int(address&0x1ffff)
            guard replay.module.samples.indices.contains(slot) else { return 0 }
            let pcm = replay.module.samples[slot].pcm
            let high: UInt16 = position < pcm.count ? UInt16(UInt8(bitPattern:pcm[position])) : 0
            let low: UInt16 = position+1 < pcm.count ? UInt16(UInt8(bitPattern:pcm[position+1])) : 0
            return high<<8 | low
        }
        paula.onOutput = { [weak self] channel,value,cycle in self?.dac.change(channel:channel,value:value,cycle:cycle) }
        paula.onInterrupt = { [weak self] channel,_ in
            guard let self, self.paula.irq else { return }
            if self.loopPending[channel] { self.loopPending[channel] = false; self.writeLoop(channel) }
            self.paula.write(0x9c,UInt16(0x80<<channel))
        }
    }
    private func address(_ instrument: Int, _ offset: Int = 0) -> UInt32 { UInt32((instrument+1)*0x20000+offset)&0x7ffffe }
    private func writeLoop(_ n: Int) {
        guard let replay else { return }
        let v = replay.voices[n], index = v.pendingLoopSample >= 0 ? v.pendingLoopSample : v.instrument
        guard replay.module.samples.indices.contains(index) else { return }
        let sample = replay.module.samples[index]
        paula.writeLocation(n,sample.loops ? address(index,sample.loopStart) : 0)
        paula.write(0xa4+n*16,UInt16(sample.loops ? sample.loopLength/2 : 1))
    }
    func synchronize() {
        guard let replay else { return }
        for n in 0..<4 {
            let v = replay.voices[n]
            guard v.active && replay.module.samples.indices.contains(v.instrument) && !replay.module.samples[v.instrument].pcm.isEmpty else {
                if paula.channels[n].state != .idle || paula.channels[n].output != 0 { paula.silence(n) }
                serials[n] = -1; continue
            }
            if serials[n] != v.triggerSerial {
                serials[n] = v.triggerSerial; paula.restart(n); periods[n] = -1; volumes[n] = -1
                let instrument = v.activeSample >= 0 ? v.activeSample : v.instrument
                let sample = replay.module.samples[instrument], offset = min(sample.pcm.count,max(0,Int(v.position))) & ~1
                let end = sample.loops && sample.loopStart > 0 ? sample.loopStart+sample.loopLength : sample.pcm.count
                let length = max(2,end-offset)
                paula.writeLocation(n,offset < end ? address(instrument,offset) : 0)
                paula.write(0xa4+n*16,UInt16(length/2))
                loopPending[n] = true
                paula.write(0xa6+n*16,UInt16(truncatingIfNeeded:v.outputPeriod)); periods[n] = v.outputPeriod
                paula.write(0xa8+n*16,UInt16(min(64,max(0,v.outputVolume)))); volumes[n] = v.outputVolume
                paula.write(0x96,0x8200 | UInt16(1<<n))
            } else {
                if !loopPending[n] { writeLoop(n) }
                if periods[n] != v.outputPeriod { paula.write(0xa6+n*16,UInt16(truncatingIfNeeded:v.outputPeriod)); periods[n] = v.outputPeriod }
                if volumes[n] != v.outputVolume { paula.write(0xa8+n*16,UInt16(min(64,max(0,v.outputVolume)))); volumes[n] = v.outputVolume }
            }
        }
    }
    private func programTempo(_ bpm: Int) {
        guard bpm != programmedBPM else { return }
        // Match the actual PT3.61 write order at $116F4/$1170C:
        // force-load the OLD latch first, then write the NEW low/high bytes.
        timer.writeControl(0x11)
        let latch = standard.timerLatch(bpm:bpm)
        timer.writeLow(UInt8(truncatingIfNeeded:latch)); timer.writeHigh(UInt8(latch>>8)); programmedBPM = bpm
    }
    func next() -> SIMD4<Float> {
        guard let replay else { return .zero }
        let target = sampleClock.next()
        while replay.playing && nextTick <= target {
            if nextTick > paula.cycle { paula.advance(to:nextTick) }
            _ = timer.advance(eClocks:nextTick/5-timerCycle/5); timerCycle = nextTick
            _ = timer.readICR()
            replay.processTick(); synchronize()
            programTempo(replay.module.ciaTiming ? replay.bpm : 125)
            nextTick = (nextTick/5+UInt64(timer.counter)+1)*5
        }
        paula.advance(to:target)
        for n in 0..<4 where replay.voices[n].active {
            let c = paula.channels[n]
            if c.state == .high || c.state == .low {
                let instrument = Int(c.bufferAddress>>17)-1
                if replay.module.samples.indices.contains(instrument) {
                    replay.voices[n].activeSample = instrument
                    replay.voices[n].position = Double(Int(c.bufferAddress&0x1ffff)+(c.state == .low ? 1 : 0))
                } else if c.bufferAddress == 0 && !loopPending[n] {
                    // The native preview is complete once the zero-word loop is audible.
                    replay.voices[n].active = false; paula.silence(n)
                }
            }
        }
        return dac.next()
    }
    func stop() {
        for n in 0..<4 { paula.silence(n) }
        dac.clear(); serials = [-1,-1,-1,-1]
    }
}
