import Foundation

func runHardwareChecks(_ expect: (Bool,String) -> Void) throws {
    let timerData = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"ReverseEngineering/timer-vectors.json"))) as! [String:Any]
    for vector in timerData["cases"] as! [[String:Any]] {
        let standard: AmigaStandard = vector["pal"] as! Bool ? .pal : .ntsc
        let bpm = vector["cia"] as! Bool ? vector["bpm"] as! Int : 125
        expect(Int(standard.timerLatch(bpm:bpm)) == vector["latch"] as! Int,"CIA latch matches actual PT3.61 programmer")
        let writes = vector["writes"] as! [[String:Int]], b = vector["timerB"] as! Bool
        expect(writes.map { $0["offset"]! } == (b ? [0xf00,0xf00,0x600,0x700] : [0xe00,0xe00,0x400,0x500]),"Original CIA force-load precedes new latch bytes")
        expect(writes[0]["value"] == 1 && writes[1]["value"] == 0x11,"Original CIA programmer leaves one-shot and strobes load/start")
    }
    var timer = CIAIntervalTimer(); timer.writeLow(3); timer.writeHigh(0); timer.writeControl(0x11); timer.writeICR(0x81)
    expect(timer.advance(eClocks:3) == 0 && timer.counter == 0,"CIA counts zero before underflow")
    timer.writeLow(7); timer.writeHigh(0)
    expect(timer.counter == 0 && timer.latch == 7,"Running CIA latch write preserves current countdown")
    expect(timer.advance(eClocks:1) == 1 && timer.counter == 7 && timer.irq,"CIA underflow reloads new latch and raises ICR")
    expect(timer.readICR() == 0x81 && !timer.irq,"Reading CIA ICR acknowledges pending interrupt")
    expect(timer.advance(eClocks:8_000_000) == 1_000_000 && timer.counter == 7,"CIA long-run period has no fractional drift")
    timer.writeControl(0x19); expect(timer.advance(eClocks:100) == 1 && !timer.running,"CIA one-shot stops after one underflow")
    timer.writeHigh(0); expect(timer.running,"One-shot high-byte write restarts stopped timer")
    var zero = CIAIntervalTimer(); zero.writeLow(0); zero.writeHigh(0); zero.writeControl(0x11)
    expect(zero.advance(eClocks:10) == 10,"CIA zero latch underflows on each E-clock")
    for standard in [AmigaStandard.pal,.ntsc] {
        for rate in [32000,44100,48000,96000,176400,192000] {
            var clock = AmigaSampleClock(standard:standard,rate:rate)
            for _ in 0..<100_003 { _ = clock.next() }
            expect(clock.cycle == 100_003*standard.clock/UInt64(rate) && clock.phase == 100_003*standard.clock%UInt64(rate),"Integer CCK conversion is exact at every supported rate")
        }
    }
    func chip(period: UInt16 = 124, length: UInt16 = 2, standard: AmigaStandard = .pal) -> PaulaChip {
        let chip = PaulaChip(standard:standard); chip.traceEnabled = true
        chip.readWord = { $0 == 0x100 ? 0x0a14 : 0x1e28 }
        chip.writeLocation(0,0x100); chip.write(0xa4,length); chip.write(0xa6,period); chip.write(0xa8,64); chip.write(0x96,0x8201)
        return chip
    }
    let original = chip(); original.advance(to:1000)
    let samples = original.trace.filter { $0.kind == .sample && $0.channel == 0 }
    expect(samples.prefix(6).map(\.cycle) == [241,365,489,613,737,861],"Paula byte edges follow DMA priming and integer period")
    expect(samples.prefix(6).map(\.value) == [640,1280,1920,2560,640,1280],"Paula word order and length reload match HRM state machine")
    expect(original.trace.filter { $0.kind == .dma }.prefix(5).map(\.cycle) == [13,240,467,694,921],"Agnus fetches once per PAL line in AUD0 slot")
    expect(original.trace.filter { $0.kind == .interrupt }.prefix(2).map(\.cycle) == [15,490],"Initial DMA and last-word interrupt positions")
    let sliced = chip()
    for cycle: UInt64 in [0,1,12,13,14,226,227,239,240,364,467,488,999,1000] { sliced.advance(to:cycle) }
    expect(sliced.trace == original.trace,"Event-driven Paula matches arbitrarily split advances exactly")
    let ntsc = chip(standard:.ntsc); ntsc.advance(to:1000)
    expect(ntsc.trace.filter { $0.kind == .dma }.prefix(5).map(\.cycle) == [13,240,468,695,923],"NTSC alternates 227/228 CCK lines")
    let slots = chip(); slots.writeLocation(1,0x100); slots.write(0xb4,2); slots.write(0xb6,124); slots.write(0x96,0x8002); slots.advance(to:500)
    expect(slots.trace.filter { $0.kind == .dma && $0.channel == 1 }.prefix(3).map(\.cycle) == [15,242,469],"AUD1 has a distinct reserved DMA slot")
    let changed = chip(); changed.advance(to:300); changed.write(0xa6,60)
    expect(changed.channels[0].sampleCycle == 365,"AUDxPER write leaves the in-flight period intact")
    changed.advance(to:365); expect(changed.channels[0].sampleCycle == 425,"New AUDxPER is latched at the byte boundary")
    let emptyLength = chip(length:0); emptyLength.advance(to:241)
    expect(emptyLength.channels[0].remaining == 65535,"AUDxLEN zero means 65536 words")
    let zeroPeriod = chip(period:0); zeroPeriod.advance(to:241)
    expect(zeroPeriod.channels[0].sampleCycle == 241+65536,"AUDxPER zero means a 65536-CCK period")
    let pointer = chip(); pointer.writeLocation(0,0xffffff); expect(pointer.channels[0].location == 0x1ffffe,"Physical Chip-RAM pointer is word-aligned and masked")
    let fast = chip(period:2); fast.advance(to:500)
    expect(fast.channels[0].underruns > 0 && fast.channels[0].fetchedWords == 3,"Too-short periods repeat buffered data instead of inventing DMA bandwidth")
    let loop = chip(length:2); loop.advance(to:14); loop.writeLocation(0,0x200); loop.write(0xa4,1); loop.advance(to:700)
    expect(loop.trace.filter { $0.kind == .dma }.prefix(4).map(\.address) == [0,0x100,0x102,0x200],"AUDxLC/LEN changes affect reload, not the current DMA block")
    var memory: UInt16 = 0x1e28
    let latch = chip(); latch.readWord = { $0 == 0x100 ? 0x0a14 : memory }; latch.advance(to:468); memory = 0x7f80; latch.advance(to:489)
    expect(latch.channels[0].buffer == 0x1e28,"Memory changes do not alter words already latched by Paula")
    let manual = PaulaChip(); manual.traceEnabled = true; manual.write(0xa6,4); manual.write(0xa8,0x7f); manual.write(0x9a,0xc080); manual.write(0xaa,0x1020)
    expect(manual.channels[0].sample == 16 && manual.channels[0].volume == 64 && !manual.irq,"CPU AUDxDAT starts high byte and audio interrupt; volume bit 6 forces 64")
    manual.advance(to:1); expect(manual.irq,"Audio interrupt is delayed by exactly one CCK")
    manual.advance(to:4); expect(manual.channels[0].sample == 32,"Manual playback emits low byte one period later")
    manual.advance(to:8); expect(manual.channels[0].state == .idle,"Unacknowledged manual interrupt ends the word")
    manual.write(0x9c,0x80); expect(!manual.irq,"INTREQ SET/CLR acknowledges audio interrupt")
    let attached = chip(); attached.write(0x9e,0x8001); attached.advance(to:500)
    expect(attached.channels[1].volume == 40 && attached.channels[0].output == 0,"Volume attachment updates next channel and suppresses modulator output")
    let attachedPeriod = chip(); attachedPeriod.write(0x9e,0x8010); attachedPeriod.advance(to:365)
    expect(attachedPeriod.channels[1].period == 0x0a14 && attachedPeriod.channels[0].output == 0,"Period attachment uses the full audio word")
    let both = chip(period:428); both.write(0x9e,0x8011); both.advance(to:669)
    expect(both.channels[1].period == 0x1e28,"Combined attachment uses the prefetched holding word, not an old output word")
    let periodIRQ = chip(); periodIRQ.write(0x9e,0x8010); periodIRQ.advance(to:1000)
    expect(periodIRQ.trace.contains { $0.kind == .interrupt && $0.cycle == 614 },"Period attachment raises the loop interrupt on the correct byte transition")
    func manualWord() -> PaulaChip { let c = PaulaChip(); c.write(0xa6,4); c.write(0xa8,64); c.write(0xaa,0x1020); return c }
    let earlyAck = manualWord(); earlyAck.advance(to:6); earlyAck.write(0x9c,0x80); earlyAck.write(0xaa,0x3040); earlyAck.advance(to:8)
    expect(earlyAck.channels[0].state == .high && earlyAck.channels[0].sample == 48,"Manual audio continues when IRQ is cleared before the penultimate CCK")
    let lateAck = manualWord(); lateAck.advance(to:7); lateAck.write(0x9c,0x80); lateAck.advance(to:8)
    expect(lateAck.channels[0].state == .idle,"Manual IRQ stop decision is latched one CCK before the word ends")
    try JSONEncoder().encode(original.trace).write(to:URL(fileURLWithPath:".build/checks/paula-register-trace.json"),options:.atomic)
    let pwm = PaulaChip(); pwm.write(0xa6,1000); pwm.write(0xa8,32); pwm.write(0xaa,0x6464)
    expect(pwm.channels[0].output == 100*64,"PWM starts with full DAC voltage")
    pwm.advance(to:31); expect(pwm.channels[0].output == 100*64,"PWM half-volume high phase lasts 32 CCK")
    pwm.advance(to:32); expect(pwm.channels[0].output == 0,"PWM half-volume low phase begins at counter 32")
    pwm.advance(to:64); expect(pwm.channels[0].output == 100*64,"PWM repeats on a 64-CCK counter")
    pwm.advance(to:80); pwm.write(0xa8,8); expect(pwm.channels[0].output == 0,"Volume changes use the current PWM phase")
    let blep = BandLimitedDAC(clock:3_546_895,rate:44100,outputRate:44100); blep.change(channel:0,value:8192,cycle:1)
    var response: [Float] = []; for _ in 0..<70 { response.append(blep.next()[0]) }
    expect(abs(response.last!-1) < 0.0001 && abs(response[0]) < 0.001,"Band-limited DAC has causal onset and unity DC gain")
    let cancel = BandLimitedDAC(clock:3_546_895,rate:44100,outputRate:44100); cancel.change(channel:0,value:8192,cycle:10); cancel.change(channel:0,value:0,cycle:10)
    expect((0..<70).allSatisfy { _ in cancel.next()[0] == 0 },"Opposite DAC changes in the same CCK cancel exactly")
    let demo = DemoModule.make(), whole = TrackerReplay(module:demo), chunked = TrackerReplay(module:demo)
    whole.smoothResampling = true; chunked.smoothResampling = true; whole.start(); chunked.start()
    let audio = whole.renderBlock(12000)
    var left: [Float] = [], right: [Float] = []
    for size in [1,17,511,4096,3,7372] { let part = chunked.renderBlock(size); left += part.0; right += part.1 }
    expect(audio.0 == left && audio.1 == right,"Hardware replay is bit-identical across host buffer sizes")
    expect(whole.hardware?.paula.channels.contains(where: { $0.fetchedWords > 0 }) == true,"Default live/export renderer actually uses Paula DMA")
    var oneShotModule = TrackerModule(); oneShotModule.samples[0] = TrackerSample(pcm:[100,-100,80,-80])
    let preview = TrackerReplay(module:oneShotModule); preview.preview(sample:0,period:428,channel:0)
    let previewAudio = preview.renderBlock(44100)
    expect(!preview.voices[0].active && abs(previewAudio.0.last!) < 0.000001,"One-shot preview reaches the silent DMA loop and releases the native voice")
    expect(preview.renderBlock(512).0.allSatisfy { $0 == 0 },"Finished preview returns to the idle fast path")
    let start = Date(); let benchmark = TrackerReplay(module:demo); benchmark.smoothResampling = true; benchmark.start(); _ = benchmark.renderBlock(44100)
    print(String(format:"Hardware renderer: one second at 4x in %.3f seconds",Date().timeIntervalSince(start)))
}
