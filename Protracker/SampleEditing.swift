import Foundation

/// Destructive operations use half-open, byte-based ranges; loops follow edits.
enum SampleEditing {
    enum Operation: String, CaseIterable {
        case reverse = "Reverse", normalize = "Normalize", silence = "Silence", invert = "Invert"
        case fadeIn = "Fade in", fadeOut = "Fade out", ramp = "Ramp", gain = "Volume", removeDC = "Remove DC"
        case lowPass = "Low-pass", highPass = "High-pass", echo = "Echo", crossfade = "Crossfade"
    }
    static func range(_ requested: Range<Int>?, count: Int) -> Range<Int> {
        guard let requested else { return 0..<count }
        let start = min(count,max(0,requested.lowerBound)), end = min(count,max(0,requested.upperBound))
        return min(start,end)..<max(start,end)
    }
    static func clamp(_ value: Double) -> Int8 {
        if value.isNaN { return 0 }
        if value >= 127 { return 127 }; if value <= -128 { return -128 }
        return Int8(Int(value.rounded()))
    }
    static func apply(_ op: Operation, to sample: inout TrackerSample, range requested: Range<Int>? = nil,
                      gain: Double = 1.5, delay: Int = 1657, feedback: Double = 0.4, rampFrom: Double = 0, rampTo: Double = 1) {
        let r = range(requested,count:sample.pcm.count)
        guard !r.isEmpty else { return }
        let original = Array(sample.pcm[r])
        let peak = original.map { abs(Int($0)) }.max() ?? 0
        let mean = original.reduce(0.0) { $0+Double($1) }/Double(original.count)
        var previous = Double(original[0]), previousInput = previous
        for i in original.indices {
            let value = Double(original[i]), t = Double(i)/Double(max(1,original.count-1))
            let output: Double
            switch op {
            case .reverse: output = Double(original[original.count-1-i])
            case .normalize: output = peak > 0 ? value*127/Double(peak) : 0
            case .silence: output = 0
            case .invert: output = -value
            case .fadeIn: output = value*t
            case .fadeOut: output = value*(1-t)
            case .ramp: output = value*(rampFrom+(rampTo-rampFrom)*t)
            case .gain: output = value*gain
            case .removeDC: output = value-mean
            case .lowPass: previous += 0.25*(value-previous); output = previous
            case .highPass:
                previous = 0.75*(previous+value-previousInput); previousInput = value; output = previous
            case .echo:
                let back = i-max(1,delay)
                output = value+(back >= 0 ? Double(sample.pcm[r.lowerBound+back])*min(0.95,max(0,feedback)) : 0)
            case .crossfade:
                let edge = max(1,min(original.count/2,delay))
                if i >= original.count-edge {
                    let n = i-(original.count-edge), mix = Double(n+1)/Double(edge)
                    output = value*(1-mix)+Double(original[n])*mix
                } else { output = value }
            }
            sample.pcm[r.lowerBound+i] = clamp(output)
        }
        if op == .reverse && sample.loops && r.contains(sample.loopStart) && sample.loopStart+sample.loopLength <= r.upperBound {
            sample.loopStart = r.lowerBound+r.upperBound-sample.loopStart-sample.loopLength
        }
        sample.validate()
    }
    static func replace(_ requested: Range<Int>, in sample: inout TrackerSample, with pcm: [Int8]) throws {
        let r = range(requested,count:sample.pcm.count)
        guard sample.pcm.count-r.count+pcm.count <= 131070 else { throw ModuleError.invalid("Sample wäre länger als 131.070 Bytes.") }
        let delta = pcm.count-r.count
        let oldStart = sample.loopStart, oldEnd = oldStart+sample.loopLength
        func map(_ point: Int) -> Int {
            if point <= r.lowerBound { return point }
            if point >= r.upperBound { return point+delta }
            return r.lowerBound+min(pcm.count,point-r.lowerBound)
        }
        sample.pcm.replaceSubrange(r,with:pcm)
        if sample.loopLength > 2 { sample.loopStart = map(oldStart); sample.loopLength = max(0,map(oldEnd)-sample.loopStart) }
        sample.validate()
    }
    static func crop(_ requested: Range<Int>, in sample: inout TrackerSample) {
        let r = range(requested,count:sample.pcm.count)
        let start = max(r.lowerBound,sample.loopStart), end = min(r.upperBound,sample.loopStart+sample.loopLength)
        sample.pcm = Array(sample.pcm[r]); sample.loopStart = max(0,start-r.lowerBound)
        sample.loopLength = max(0,end-start); sample.validate()
    }
    static func resample(_ requested: Range<Int>, in sample: inout TrackerSample, ratio: Double) throws {
        guard ratio.isFinite && ratio >= 0.125 && ratio <= 8 else { throw ModuleError.invalid("Resampling-Faktor muss zwischen 0,125 und 8 liegen.") }
        let r = range(requested,count:sample.pcm.count), source = Array(sample.pcm[range(requested,count:sample.pcm.count)])
        guard !source.isEmpty else { return }
        let count = max(2,Int(Double(source.count)/ratio)/2*2)
        guard sample.pcm.count-r.count+count <= 131070 else { throw ModuleError.invalid("Resampling überschreitet die Samplegrenze.") }
        let pcm: [Int8] = (0..<count).map { i in
            let pos = min(Double(source.count-1),Double(i)*ratio), a = Int(pos), b = min(source.count-1,a+1)
            return clamp(Double(source[a])+(Double(source[b])-Double(source[a]))*(pos-Double(a)))
        }
        let loopStart = sample.loopStart, loopEnd = sample.loopStart+sample.loopLength
        try replace(r,in:&sample,with:pcm)
        if loopStart >= r.lowerBound && loopEnd <= r.upperBound {
            sample.loopStart = r.lowerBound+Int(Double(loopStart-r.lowerBound)/ratio)
            sample.loopLength = Int(Double(loopEnd-loopStart)/ratio); sample.validate()
        }
    }
    static func mix(_ source: TrackerSample, into destination: inout TrackerSample, at offset: Int, half: Bool = true) throws {
        let offset = max(0,offset), needed = offset+source.pcm.count
        guard needed <= 131070 else { throw ModuleError.invalid("Mix überschreitet die Samplegrenze.") }
        if destination.pcm.count < needed { destination.pcm += Array(repeating:0,count:needed-destination.pcm.count) }
        for i in source.pcm.indices { destination.pcm[offset+i] = clamp((Double(destination.pcm[offset+i])+Double(source.pcm[i]))*(half ? 0.5 : 1)) }
        destination.validate()
    }
    static func chord(_ source: TrackerSample, intervals: [Int]) -> TrackerSample {
        guard !source.pcm.isEmpty, !intervals.isEmpty else { return source }
        let ratios = intervals.prefix(4).map { pow(2,Double($0)/12) }
        let count = min(131070,Int(Double(source.pcm.count)/(ratios.min() ?? 1)))
        var result = source; result.name = String((source.name+" chord").prefix(22)); result.loopLength = 0; result.loopStart = 0
        result.pcm = (0..<count).map { n in
            var sum = 0.0
            for ratio in ratios {
                let p = Double(n)*ratio
                if p < Double(source.pcm.count) { sum += Double(source.pcm[min(source.pcm.count-1,Int(p))]) }
            }
            return clamp(sum/Double(ratios.count))
        }
        result.validate(); return result
    }
    static func waveform(_ shape: String, length: Int = 128) -> TrackerSample {
        let count = max(4,min(131070,length/2*2))
        var seed: UInt32 = 361
        let pcm: [Int8] = (0..<count).map { i in
            let t = Double(i)/Double(count), value: Double
            switch shape {
            case "Square": value = t < 0.5 ? 100 : -100
            case "Saw": value = t*240-120
            case "Triangle": value = (1-4*abs(t-0.5))*120
            case "Noise": seed = seed &* 1664525 &+ 1013904223; value = Double(seed>>24)-128
            default: value = sin(t*2 * .pi)*120
            }
            return clamp(value)
        }
        return TrackerSample(name:shape,pcm:pcm,loopLength:count)
    }
}

struct PatternBlock: Codable, Equatable {
    var rows: Int
    var channels: Int
    var cells: [TrackerCell]
    var isValid: Bool {
        (1...64).contains(rows) && (1...4).contains(channels) && cells.count == rows*channels &&
        cells.allSatisfy { (0...4095).contains($0.period) && (0...31).contains($0.sample) && (0...15).contains($0.effect) && (0...255).contains($0.parameter) }
    }
}
enum PatternEditing {
    static func copy(_ pattern: TrackerPattern, rows: ClosedRange<Int>, channels: ClosedRange<Int>) -> PatternBlock {
        PatternBlock(rows:rows.count,channels:channels.count,cells:rows.flatMap { row in channels.map { pattern[row,$0] } })
    }
    static func paste(_ block: PatternBlock, into pattern: inout TrackerPattern, row: Int, channel: Int, mix: Bool = false, effectsOnly: Bool = false) {
        guard block.isValid else { return }
        for r in 0..<min(block.rows,64-row) {
            for ch in 0..<min(block.channels,4-channel) {
                let value = block.cells[r*block.channels+ch]
                if effectsOnly { pattern[row+r,channel+ch].effect = value.effect; pattern[row+r,channel+ch].parameter = value.parameter }
                else if !mix { pattern[row+r,channel+ch] = value }
                else {
                    if value.period > 0 { pattern[row+r,channel+ch].period = value.period }
                    if value.sample > 0 { pattern[row+r,channel+ch].sample = value.sample }
                    if value.effect != 0 || value.parameter != 0 { pattern[row+r,channel+ch].effect = value.effect; pattern[row+r,channel+ch].parameter = value.parameter }
                }
            }
        }
    }
    static func shift(_ pattern: inout TrackerPattern, row: Int, count: Int, channels: ClosedRange<Int>, insert: Bool, effectsOnly: Bool = false) {
        let source = pattern, count = min(64,max(1,count))
        for ch in channels {
            for r in row..<64 {
                let origin = insert ? r-count : r+count
                let value = origin >= row && origin < 64 ? source[origin,ch] : TrackerCell()
                if effectsOnly { pattern[r,ch].effect = value.effect; pattern[r,ch].parameter = value.parameter }
                else { pattern[r,ch] = value }
            }
        }
    }
    static func stretch(_ pattern: inout TrackerPattern, channel: Int, expand: Bool) {
        let source = pattern
        for row in 0..<64 {
            pattern[row,channel] = expand ? (row % 2 == 0 ? source[row/2,channel] : TrackerCell()) : (row < 32 ? source[row*2,channel] : TrackerCell())
        }
    }
}
