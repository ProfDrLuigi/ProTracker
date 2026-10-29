import Foundation

enum DemoModule {
    static func make() -> TrackerModule {
        var module = TrackerModule()
        module.title = L("Neon Harbor")
        module.comment = "Original demo for the native Swift Protracker. All samples synthesized locally."
        func wave(_ name: String, _ length: Int, volume: Int = 48, loop: Bool = false, generate: (Int) -> Double) -> TrackerSample {
            var sample = TrackerSample(name: name, pcm: (0..<length).map { Int8(max(-127,min(127,Int(generate($0)*110)))) }, volume: volume, loopLength: loop ? length : 0)
            sample.validate(); return sample
        }
        module.samples[0] = wave("01 · Harbor bass",64,volume:44,loop:true) { n in
            let p = Double(n)/64
            return (p < 0.35 ? 0.65 : -0.35) + sin(p * .pi * 2)*0.25
        }
        module.samples[1] = wave("02 · Glass signal",128,volume:38,loop:true) { n in
            let p = Double(n)/128 * .pi * 2
            return sin(p)*0.6 + sin(p*2)*0.2 + sin(p*3)*0.13
        }
        module.samples[2] = wave("03 · Analog kick",6200,volume:64) { n in
            let t = Double(n)/SampleAudio.rootRate
            return sin(2 * .pi * (48*t + 8*(1-exp(-t*35)))) * exp(-t*13)
        }
        var noise: UInt32 = 0x361
        func random() -> Double { noise = noise &* 1664525 &+ 1013904223; return Double(noise >> 8)/Double(0xffffff)*2-1 }
        module.samples[3] = wave("04 · Dust snare",3700,volume:52) { n in
            let t = Double(n)/SampleAudio.rootRate
            return (random()*0.7 + sin(t*2 * .pi*170)*0.3)*exp(-t*23)
        }
        module.samples[4] = wave("05 · Closed hat",1100,volume:30) { n in random()*exp(-Double(n)/210) }
        module.samples[5] = wave("06 · Open hat",4600,volume:26) { n in random()*exp(-Double(n)/1000) }
        module.patterns = Array(repeating: TrackerPattern(), count: 3)
        module.orders = [0,1,0,2]
        for p in 0..<3 {
            let root = [0,5,8][p]
            for r in stride(from:0,to:64,by:4) {
                module.patterns[p][r,0] = TrackerCell(period:Notes.period(root + (r%16 == 12 ? 12 : 0)),sample:1,effect:0,parameter:0)
                module.patterns[p][r,3] = TrackerCell(period:Notes.period(24),sample:r%16 == 12 ? 6 : 5,effect:12,parameter:r%8 == 0 ? 28 : 18)
            }
            for r in stride(from:0,to:64,by:8) {
                module.patterns[p][r,2] = TrackerCell(period:Notes.period(24),sample:r%16 == 8 ? 4 : 3)
            }
            let melody = [12,19,15,22,19,15,24,22,12,19,15,22,27,24,22,19]
            for (i,note) in melody.enumerated() {
                let row = i*4+2
                module.patterns[p][row,1] = TrackerCell(period:Notes.period(min(35,note+root)),sample:2,effect:12,parameter:30)
                module.patterns[p][row+1,1] = TrackerCell(effect:10,parameter:3)
            }
        }
        return module
    }
}
