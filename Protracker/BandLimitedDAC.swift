import Foundation

/// Causal, windowed-sinc step reconstruction. Device edges retain their integer CCK
/// timestamps; fractional host positions affect reconstruction, never chip scheduling.
/// Independently generated Blackman-windowed kernel (no imported BLEP tables).
final class BandLimitedDAC {
    private let clock: UInt64
    private let rate: UInt64
    private let taps: Int
    private let response: [Float]
    private let resolution = 256
    private var contributions = Array(repeating:Array(repeating:Float(0),count:256),count:4)
    private var tails = Array(repeating:Array(repeating:Float(0),count:256),count:4)
    private var base = Array(repeating:Float(0),count:4)
    private var last = Array(repeating:0,count:4)
    private(set) var index: UInt64 = 1
    private var settledAfter: UInt64 = 1
    var hasSignal: Bool { index < settledAfter || last.contains(where:{ $0 != 0 }) }
    init(clock: UInt64, rate: Int, outputRate: Double) {
        self.clock = clock; self.rate = UInt64(rate)
        taps = min(128,max(32,Int((Double(rate)/outputRate).rounded())*32))
        let count = taps*resolution, cutoff = min(0.45,20000/Double(rate))
        var integral = [Double](repeating:0,count:count+1)
        var previous = 0.0
        for n in 0...count {
            let t = Double(n)/Double(resolution), x = t-Double(taps)/2
            let sinc = abs(x) < 1e-12 ? 2*cutoff : sin(2*Double.pi*cutoff*x)/(Double.pi*x)
            let window = 0.42-0.5*cos(2*Double.pi*t/Double(taps))+0.08*cos(4*Double.pi*t/Double(taps))
            let value = sinc*window
            if n > 0 { integral[n] = integral[n-1]+(value+previous)/(2*Double(resolution)) }
            previous = value
        }
        response = integral.map { Float($0/integral[count]) }
    }
    private func step(_ position: Double) -> Float {
        if position <= 0 { return 0 }; if position >= Double(taps) { return 1 }
        let point = position*Double(resolution), n = Int(point), f = Float(point-Double(n))
        return response[n]+(response[n+1]-response[n])*f
    }
    func change(channel: Int, value: Int, cycle: UInt64) {
        let delta = Float(value-last[channel])/8192; last[channel] = value
        guard delta != 0 else { return }
        let product = cycle*rate, whole = product/clock, remainder = product%clock
        let first = whole+(remainder == 0 ? 0 : 1)
        let fraction = Double(remainder)/Double(clock)
        let start = max(first,index), end = first+UInt64(taps)
        settledAfter = max(settledAfter,end+1)
        if start < end {
            contributions[channel].withUnsafeMutableBufferPointer { buffer in
                for output in start..<end {
                    let age = Double(output-whole)-fraction
                    buffer[Int(output&255)] += delta*step(age)
                }
            }
        }
        tails[channel][Int(max(index,end)&255)] += delta
    }
    func next() -> SIMD4<Float> {
        let slot = Int(index&255)
        var values = SIMD4<Float>.zero
        for n in 0..<4 {
            base[n] += tails[n][slot]; tails[n][slot] = 0
            values[n] = base[n]+contributions[n][slot]; contributions[n][slot] = 0
        }
        index += 1; return values
    }
    func clear() {
        settledAfter = index
        for n in 0..<4 { base[n] = 0; last[n] = 0; contributions[n] = Array(repeating:0,count:256); tails[n] = Array(repeating:0,count:256) }
    }
}
