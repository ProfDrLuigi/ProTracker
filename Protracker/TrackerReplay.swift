import Foundation

/// Native translation of the PT3.61 replay state machine, not a 68k emulator.
/// Reverse-engineered entry points are documented in ReverseEngineering/NOTES.md.
final class TrackerReplay {
    struct Voice {
        var triggerSerial = 0
        var instrument = -1
        var activeSample = -1
        var position = 0.0
        var pendingLoopSample = -1
        var firstPass = true
        var period = 0
        var outputPeriod = 0
        var volume = 0
        var outputVolume = 0
        var finetune = 0
        var target = 0
        var portaSpeed = 0
        var vibrato = 0
        var vibratoPhase = 0
        var vibratoWave = 0
        var tremolo = 0
        var tremoloPhase = 0
        var tremoloWave = 0
        var offset = 0
        var glissando = false
        var loopRow = 0
        var loopCounter = 0
        var funkSpeed = 0
        var funkAccumulator = 0
        var funkPosition = 0
        var cell = TrackerCell()
        var active = false
    }
    var module: TrackerModule
    let sampleRate: Double
    var voices = Array(repeating: Voice(), count: 4)
    var muted = Array(repeating: false, count: 4)
    var order = 0
    var row = 0
    var tick = 0
    var bpm = 125
    var speed = 6
    var playing = false
    var patternOnly = false
    var loopSong = true
    var completedCycles = 0
    var masterVolume: Float = 0.8
    var stereoWidth: Float = 0.8
    var amigaFilter = true
    var ledFilter = false
    var frameCount = 0
    var hardwareTiming = true
    private(set) var hardware: AmigaReplayHardware?
    var smoothResampling = false
    var palClock = true
    var countInRemaining = 0
    var metronome = false
    var metronomeRows = 4
    private var click = 0.0
    private var clickPhase = 0.0
    var levels = Array(repeating: Float(0), count: 4)
    var scopes = Array(repeating: Array(repeating: Float(0), count: 128), count: 4)
    private var scopePosition = 0
    private var untilTick = 0.0
    private var rowPending = false
    private var delayRemaining = 0
    private var repeatingRow = false
    private var jumpOrder: Int?
    private var breakRow: Int?
    private var patternLoopRow: Int?
    private var low = [Float(0), Float(0)]
    private var led = [Float(0), Float(0)]
    private var led2 = [Float(0), Float(0)]
    private var high = [Float(0), Float(0)]
    private var last = [Float(0), Float(0)]

    init(module: TrackerModule, sampleRate: Double = 44100) {
        self.module = module; self.sampleRate = sampleRate
        bpm = module.initialBPM; speed = module.initialSpeed
        ledFilter = module.filterEnabled
    }
    func start(order: Int = 0, row: Int = 0, patternOnly: Bool = false) {
        self.order = min(max(0, order), module.orders.count-1)
        self.row = min(63, max(0, row)); self.patternOnly = patternOnly
        hardware = nil
        voices = Array(repeating: Voice(), count: 4)
        bpm = module.initialBPM; speed = module.initialSpeed
        countInRemaining = 0; click = 0; clickPhase = 0
        tick = 0; untilTick = 0; rowPending = false; repeatingRow = false
        delayRemaining = 0; completedCycles = 0; frameCount = 0
        jumpOrder = nil; breakRow = nil; patternLoopRow = nil
        ledFilter = module.filterEnabled
        low = [0,0]; led = [0,0]; led2 = [0,0]; high = [0,0]; last = [0,0]
        playing = true
    }
    func stop() {
        playing = false; countInRemaining = 0; click = 0
        hardware?.stop()
        low = [0,0]; led = [0,0]; led2 = [0,0]; high = [0,0]; last = [0,0]
        for n in 0..<4 { voices[n].active = false; levels[n] = 0; scopes[n] = Array(repeating: 0, count: 128) }
    }
    func preview(sample: Int, period: Int, channel: Int) {
        guard module.samples.indices.contains(sample), (0..<4).contains(channel) else { return }
        voices[channel].instrument = sample
        voices[channel].finetune = module.samples[sample].finetune
        voices[channel].volume = module.samples[sample].volume
        trigger(channel, period: Notes.period(Notes.index(period), finetune: voices[channel].finetune))
        voices[channel].outputVolume = voices[channel].volume
    }
    private func translatedPeriod(_ raw: Int, finetune: Int) -> Int {
        guard let index = AmigaTables.periods[0].firstIndex(where: { $0 <= raw }) else { return 0 }
        return AmigaTables.periods[finetune & 15][index]
    }
    private func trigger(_ channel: Int, period: Int, offset: Int = 0) {
        voices[channel].triggerSerial += 1
        voices[channel].activeSample = voices[channel].instrument
        voices[channel].pendingLoopSample = voices[channel].instrument; voices[channel].firstPass = true
        voices[channel].position = Double(offset)
        voices[channel].period = period; voices[channel].outputPeriod = period
        voices[channel].active = voices[channel].activeSample >= 0 && period > 0
        if voices[channel].vibratoWave & 4 == 0 { voices[channel].vibratoPhase = 0 }
        if voices[channel].tremoloWave & 4 == 0 { voices[channel].tremoloPhase = 0 }
    }

    func processTick() {
        guard playing else { return }
        if countInRemaining > 0 {
            if countInRemaining % (max(1,speed)*4) == 0 { click = 1; clickPhase = 0 }
            countInRemaining -= 1; return
        }
        if tick == 0 {
            if rowPending { advanceRow(); rowPending = false }
            guard playing else { return }
            if !repeatingRow { readRow() }
            else { for n in 0..<4 { runEffects(n, tickZero: false) } }
        } else {
            for n in 0..<4 { runEffects(n, tickZero: false) }
        }
        guard playing else { return }
        tick += 1
        if tick >= max(1, speed) {
            tick = 0
            if delayRemaining > 0 { delayRemaining -= 1; repeatingRow = true }
            else { repeatingRow = false; rowPending = true }
        }
    }
    private func advanceRow() {
        let previousOrder = order
        if let loop = patternLoopRow { row = loop }
        else if jumpOrder != nil || breakRow != nil {
            order = patternOnly ? order : (jumpOrder ?? order + 1)
            row = breakRow ?? 0
            if !patternOnly && order <= previousOrder { finishCycle() }
        } else {
            row += 1
            if row >= 64 { row = 0; if !patternOnly { order += 1 } else { finishCycle() } }
        }
        if order >= module.orders.count { order = 0; finishCycle() }
        if order != previousOrder { for n in 0..<4 { voices[n].loopRow = 0; voices[n].loopCounter = 0 } }
        jumpOrder = nil; breakRow = nil; patternLoopRow = nil
    }
    private func finishCycle() { completedCycles += 1; if !loopSong { stop() } }
    private func readRow() {
        let pattern = module.orders[order]
        if metronome && row % max(1,metronomeRows) == 0 { click = 1; clickPhase = 0 }
        for n in 0..<4 {
            let cell = module.patterns[pattern][row,n]
            voices[n].cell = cell
            if cell.sample > 0 {
                let index = cell.sample-1
                voices[n].instrument = index
                voices[n].pendingLoopSample = index
                voices[n].volume = module.samples[index].volume
                voices[n].finetune = module.samples[index].finetune
            }
            // E5 finetune is evaluated before translating the note ($29DB4).
            if cell.effect == 14 && cell.parameter >> 4 == 5 {
                voices[n].finetune = cell.parameter & 15
            }
            if cell.effect == 9 && cell.parameter > 0 { voices[n].offset = cell.parameter * 256 }
            let delayed = cell.effect == 14 && cell.parameter >> 4 == 13 && cell.parameter & 15 > 0
            if cell.period > 0 && !delayed {
                let period = translatedPeriod(cell.period, finetune: voices[n].finetune)
                if cell.effect == 3 || cell.effect == 5 {
                    let table = AmigaTables.periods[voices[n].finetune & 15]
                    var index = table.firstIndex(where: { $0 <= cell.period }) ?? 35
                    if voices[n].finetune & 8 != 0 && index > 0 { index -= 1 }
                    voices[n].target = table[index] == voices[n].period ? 0 : table[index]
                }
                else { trigger(n, period: period, offset: cell.effect == 9 ? voices[n].offset : 0) }
            }
            runEffects(n, tickZero: true)
            if !playing { return }
        }
    }
    private func runEffects(_ n: Int, tickZero: Bool) {
        let cell = voices[n].cell, value = cell.parameter, x = value >> 4, y = value & 15
        voices[n].outputPeriod = voices[n].period
        voices[n].outputVolume = voices[n].volume
        if !tickZero { invertLoop(n) }
        if tickZero {
            switch cell.effect {
                        case 11: jumpOrder = value; breakRow = 0
            case 12: voices[n].volume = min(64, value)
            case 13: breakRow = x * 10 + y; if breakRow! > 63 { breakRow = 0 }
            case 15:
                if value == 0 { stop() }
                else if value < 32 || !module.ciaTiming { speed = value }
                else { bpm = value }
            case 14: extendedEffect(n,value)
            default: break
            }
            voices[n].outputPeriod = voices[n].period & 4095; voices[n].outputVolume = voices[n].volume
            return
        }
        switch cell.effect {
        case 0 where value > 0:
            if tick % 3 == 0 { break }
            let add = tick % 3 == 1 ? x : y
            let table = AmigaTables.periods[voices[n].finetune & 15]
            let index = table.firstIndex(where: { $0 <= voices[n].period }) ?? 35
            voices[n].outputPeriod = table[min(35, index+add)]
        case 1: slide(n, amount: -value, up: true)
        case 2: slide(n, amount: value)
        case 3: if value > 0 { voices[n].portaSpeed = value }; portamento(n)
        case 4: voices[n].vibrato = mergeNibbles(voices[n].vibrato,value); vibrato(n)
        case 5: portamento(n); volumeSlide(n, value)
        case 6: vibrato(n); volumeSlide(n, value)
        case 7: voices[n].tremolo = mergeNibbles(voices[n].tremolo,value); tremolo(n)
        case 10: volumeSlide(n, value)
        case 14: extendedEffect(n,value)
        default: break
        }
        if ![0,3,4,5,6].contains(cell.effect) || (cell.effect == 0 && value == 0) { voices[n].outputPeriod = voices[n].period & 4095 }
        if cell.effect != 7 { voices[n].outputVolume = voices[n].volume }
    }
    private func extendedEffect(_ n: Int, _ value: Int) {
        let command = value >> 4, y = value & 15
        switch command {
        case 0: ledFilter = y & 1 == 0
        case 1: if tick == 0 { slide(n, amount: -y, up: true) }
        case 2: if tick == 0 { slide(n, amount: y) }
        case 3: voices[n].glissando = y != 0
        case 4: voices[n].vibratoWave = y
        case 5: voices[n].finetune = y
        case 6:
            guard tick == 0 else { return }
            if y == 0 { voices[n].loopRow = row }
            else if voices[n].loopCounter == 0 { voices[n].loopCounter = y; patternLoopRow = voices[n].loopRow }
            else { voices[n].loopCounter -= 1; if voices[n].loopCounter > 0 { patternLoopRow = voices[n].loopRow } }
        case 7: voices[n].tremoloWave = y
        case 8: karplusStrong(n)
        case 9:
            if y > 0 && tick % y == 0 && (tick > 0 || voices[n].cell.period == 0) { retrigger(n) }
        case 10: if tick == 0 { voices[n].volume = min(64, voices[n].volume+y) }
        case 11: if tick == 0 { voices[n].volume = max(0, voices[n].volume-y) }
        case 12: if tick == y { voices[n].volume = 0 }
        case 13:
            let cell = voices[n].cell
            if tick == y && cell.period > 0 { trigger(n, period: translatedPeriod(cell.period, finetune: voices[n].finetune)) }
        case 14: if tick == 0 && !repeatingRow { delayRemaining = y }
        case 15: if tick == 0 { voices[n].funkSpeed = y; invertLoop(n) }
        default: break
        }
    }
    private func slide(_ n: Int, amount: Int, up: Bool = false) {
        var raw = (voices[n].period+amount) & 65535
        if up && raw & 4095 < 113 { raw = (raw & 0xf000) | 113 }
        if !up && raw & 4095 > 856 { raw = (raw & 0xf000) | 856 }
        voices[n].period = raw
    }
    private func mergeNibbles(_ old: Int, _ value: Int) -> Int {
        (value & 240 == 0 ? old & 240 : value & 240) | (value & 15 == 0 ? old & 15 : value & 15)
    }
    private func retrigger(_ n: Int) {
        voices[n].triggerSerial += 1
        voices[n].position = 0
        voices[n].activeSample = voices[n].instrument
        voices[n].pendingLoopSample = voices[n].instrument; voices[n].firstPass = true
        voices[n].active = voices[n].activeSample >= 0 && voices[n].period > 0
    }
    private func volumeSlide(_ n: Int, _ v: Int) { voices[n].volume = min(64,max(0,voices[n].volume + (v >> 4 > 0 ? v >> 4 : -(v & 15)))) }
    private func portamento(_ n: Int) {
        let target = voices[n].target
        if target > 0 {
            if voices[n].period < target { voices[n].period = min(target, voices[n].period+voices[n].portaSpeed) }
            else { voices[n].period = max(target, voices[n].period-voices[n].portaSpeed) }
            if voices[n].period == target { voices[n].target = 0 }
        }
        voices[n].outputPeriod = voices[n].period
        if voices[n].glissando {
            let table = AmigaTables.periods[voices[n].finetune & 15]
            voices[n].outputPeriod = table.first(where: { $0 <= voices[n].period }) ?? table[35]
        }
    }
    private func wave(_ phase: Int, _ shape: Int, signPhase: Int? = nil) -> Int {
        let index = (phase >> 2) & 31
        let magnitude: Int
        switch shape & 3 {
        case 0: magnitude = AmigaTables.sine[index]
        case 1: magnitude = (signPhase ?? phase) & 128 != 0 ? 255-index*8 : index*8
        default: magnitude = 255
        }
        return phase & 128 == 0 ? magnitude : -magnitude
    }
    private func vibrato(_ n: Int) {
        let v = voices[n]
        voices[n].outputPeriod = v.period + wave(v.vibratoPhase,v.vibratoWave) * (v.vibrato & 15) / 128
        voices[n].vibratoPhase = (v.vibratoPhase + (v.vibrato >> 4)*4) & 255
    }
    private func tremolo(_ n: Int) {
        let v = voices[n]
        // The original ramp waveform uses vibrato's sign bit ($2A49E).
        let delta = wave(v.tremoloPhase,v.tremoloWave,signPhase:v.vibratoPhase) * (v.tremolo & 15) / 64
        voices[n].outputVolume = min(64,max(0,v.volume+delta))
        voices[n].tremoloPhase = (v.tremoloPhase + (v.tremolo >> 4)*4) & 255
    }
    private func invertLoop(_ n: Int) {
        let index = voices[n].instrument
        guard index >= 0, module.samples[index].loops, voices[n].funkSpeed > 0 else { return }
        voices[n].funkAccumulator += AmigaTables.funk[voices[n].funkSpeed]
        if voices[n].funkAccumulator >= 128 {
            voices[n].funkAccumulator = 0
            let start = module.samples[index].loopStart, length = module.samples[index].loopLength
            voices[n].funkPosition = (voices[n].funkPosition + 1) % length
            let pos = start + voices[n].funkPosition
            module.samples[index].pcm[pos] = ~module.samples[index].pcm[pos]
        }
    }
    private func karplusStrong(_ n: Int) {
        let index = voices[n].instrument
        guard index >= 0, module.samples[index].loops else { return }
        let start = module.samples[index].loopStart, end = start + module.samples[index].loopLength
        for p in start..<end {
            let next = p+1 == end ? start : p+1
            module.samples[index].pcm[p] = Int8((Int(module.samples[index].pcm[p])+Int(module.samples[index].pcm[next])) >> 1)
        }
    }

    /// Four-times oversampling follows sample-and-hold transitions before the analog filters.
    /// This avoids treating interpolation as Paula hardware behavior.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        if hardwareTiming { renderHardware(frames:frames,left:left,right:right); return }
        if !playing && !voices.contains(where:{ $0.active }) && click < 0.000001 &&
            low.allSatisfy({ abs($0)<0.000001 }) && led.allSatisfy({ abs($0)<0.000001 }) &&
            led2.allSatisfy({ abs($0)<0.000001 }) && high.allSatisfy({ abs($0)<0.000001 }) {
            left.update(repeating:0,count:frames); right.update(repeating:0,count:frames)
            if levels.contains(where:{ $0 != 0 }) { levels = Array(repeating:0,count:4) }
            if scopes.contains(where:{ $0.contains(where:{ $0 != 0 }) }) { scopes = Array(repeating:Array(repeating:0,count:128),count:4) }
            return
        }
        let factor = smoothResampling ? 4 : 1, rate = sampleRate*Double(factor)
        let a500 = Float(1-exp(-2 * Double.pi * 4420/rate))
        let ledCoefficient = Float(1-exp(-2 * Double.pi * 3275/rate)), hp = Float(exp(-2 * Double.pi * 5/rate))
        let levelDecay = pow(Float(0.9995),1/Float(factor)), clickDecay = exp(-180/rate)
        let clock = palClock ? 3546894.6 : 3579545.0
        for frame in 0..<frames {
            var sumL: Float = 0, sumR: Float = 0, wasPlaying = false
            for sub in 0..<factor {
                if playing && untilTick <= 0 { processTick(); untilTick += module.ciaTiming ? sampleRate*2.5/Double(bpm) : sampleRate/(palClock ? 50 : 60) }
                if playing { untilTick -= 1/Double(factor); wasPlaying = true }
                var l: Float = 0, r: Float = 0
                for n in 0..<4 {
                    var value: Float = 0
                    if voices[n].active && voices[n].activeSample >= 0 {
                        var index = voices[n].activeSample, sample = module.samples[index]
                        let firstEnd = sample.loops && sample.loopStart > 0 ? sample.loopStart+sample.loopLength : sample.pcm.count
                        let end = voices[n].firstPass ? firstEnd : (sample.loops ? sample.loopStart+sample.loopLength : sample.pcm.count)
                        if Int(voices[n].position) >= end {
                            let pending = voices[n].pendingLoopSample >= 0 ? voices[n].pendingLoopSample : index
                            let next = module.samples[pending]
                            if next.loops {
                                voices[n].position = Double(next.loopStart)+(voices[n].position-Double(end)).truncatingRemainder(dividingBy:Double(next.loopLength))
                                voices[n].activeSample = pending; voices[n].firstPass = false; index = pending; sample = next
                            } else { voices[n].active = false }
                        }
                        let pos = Int(voices[n].position)
                        if voices[n].active && sample.pcm.indices.contains(pos) {
                            value = Float(sample.pcm[pos])/128*Float(voices[n].outputVolume)/64
                            voices[n].position += clock/Double(max(1,voices[n].outputPeriod))/rate
                        }
                    }
                    if muted[n] { value = 0 }
                    levels[n] = max(abs(value),levels[n]*levelDecay)
                    if sub == 0 && frameCount % 6 == 0 { scopes[n][scopePosition] = value }
                    let pan: Float = n == 0 || n == 3 ? -stereoWidth : stereoWidth
                    l += value*(1-pan)*0.25; r += value*(1+pan)*0.25
                }
                if click > 0.0001 {
                    let value = Float(sin(clickPhase)*click*0.15); l += value; r += value
                    clickPhase += 2 * Double.pi*1200/rate; click *= clickDecay
                }
                sumL += filter(l,channel:0,a500:a500,ledCoefficient:ledCoefficient,hp:hp)
                sumR += filter(r,channel:1,a500:a500,ledCoefficient:ledCoefficient,hp:hp)
            }
            if wasPlaying { frameCount += 1 }
            if frameCount % 6 == 0 { scopePosition = (scopePosition+1)%128 }
            left[frame] = sumL/Float(factor); right[frame] = sumR/Float(factor)
        }
    }
    private func renderHardware(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let factor = smoothResampling ? 4 : 1, rate = sampleRate*Double(factor)
        hardware?.synchronize()
        if !playing && !voices.contains(where:{ $0.active }) && !(hardware?.hasSignal ?? false) &&
            low.allSatisfy({ abs($0)<0.000001 }) && led.allSatisfy({ abs($0)<0.000001 }) &&
            led2.allSatisfy({ abs($0)<0.000001 }) && high.allSatisfy({ abs($0)<0.000001 }) {
            left.update(repeating:0,count:frames); right.update(repeating:0,count:frames)
            if levels.contains(where:{ $0 != 0 }) { levels = Array(repeating:0,count:4) }
            if scopes.contains(where:{ $0.contains(where:{ $0 != 0 }) }) { scopes = Array(repeating:Array(repeating:0,count:128),count:4) }
            return
        }
        if hardware == nil || hardware?.standard != (palClock ? .pal : .ntsc) || hardware?.rate != Int(rate) {
            hardware = AmigaReplayHardware(replay:self,rate:Int(rate))
        }
        guard let hardware else { return }
        hardware.synchronize()
        let a500 = Float(1-exp(-2 * Double.pi * 4420/rate))
        let ledCoefficient = Float(1-exp(-2 * Double.pi * 3275/rate)), hp = Float(exp(-2 * Double.pi * 5/rate))
        let levelDecay = pow(Float(0.9995),1/Float(factor)), clickDecay = exp(-180/rate)
        for frame in 0..<frames {
            var sumL: Float = 0, sumR: Float = 0, wasPlaying = false
            for sub in 0..<factor {
                let running = playing
                let values = hardware.next()
                wasPlaying = wasPlaying || running || playing
                var l: Float = 0, r: Float = 0
                for n in 0..<4 {
                    let value = muted[n] ? 0 : values[n]
                    levels[n] = max(abs(value),levels[n]*levelDecay)
                    if sub == 0 && frameCount%6 == 0 { scopes[n][scopePosition] = value }
                    let pan: Float = n == 0 || n == 3 ? -stereoWidth : stereoWidth
                    l += value*(1-pan)*0.25; r += value*(1+pan)*0.25
                }
                if click > 0.0001 {
                    let value = Float(sin(clickPhase)*click*0.15); l += value; r += value
                    clickPhase += 2 * Double.pi*1200/rate; click *= clickDecay
                }
                sumL += filter(l,channel:0,a500:a500,ledCoefficient:ledCoefficient,hp:hp)
                sumR += filter(r,channel:1,a500:a500,ledCoefficient:ledCoefficient,hp:hp)
            }
            if wasPlaying { frameCount += 1 }
            if frameCount%6 == 0 { scopePosition = (scopePosition+1)%128 }
            left[frame] = sumL/Float(factor); right[frame] = sumR/Float(factor)
        }
    }
    @inline(__always) private func filter(_ input: Float, channel n: Int, a500: Float, ledCoefficient: Float, hp: Float) -> Float {
        var value = input
        low[n] += a500 * (value-low[n])
        if amigaFilter { value = low[n] }
        led[n] += ledCoefficient * (value-led[n]); led2[n] += ledCoefficient * (led[n]-led2[n])
        if ledFilter { value = led2[n] }
        high[n] = hp * (high[n] + value-last[n]); last[n] = value
        return max(-1,min(1,high[n]*masterVolume))
    }
    func renderBlock(_ count: Int) -> ([Float], [Float]) {
        guard count > 0 else { return ([],[]) }
        var left = Array(repeating: Float(0), count: count), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in render(frames: count, left: l.baseAddress!, right: r.baseAddress!) }
        }
        return (left,right)
    }
}
