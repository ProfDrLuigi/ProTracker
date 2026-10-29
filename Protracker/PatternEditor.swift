import AppKit
import SwiftUI

struct PatternEditor: NSViewRepresentable {
    @ObservedObject var store: TrackerStore
    func makeNSView(context: Context) -> PatternGridView { PatternGridView(store:store) }
    func updateNSView(_ view: PatternGridView, context: Context) { view.store = store; view.needsDisplay = true }
}

@MainActor
final class PatternGridView: NSView {
    var store: TrackerStore
    private let header: CGFloat = 32
    private let rowHeight: CGFloat = 23
    private let gutter: CGFloat = 48
    private let offsets: [CGFloat] = [14,65,76,109,120,131]
    private var startRow = 0
    private var scrollRemainder: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(store: TrackerStore) {
        self.store = store; super.init(frame:.zero)
        setAccessibilityElement(true); setAccessibilityRole(.textArea)
        setAccessibilityLabel("Pattern-Editor. Return: Edit. Leertaste: Wiedergabe. Pfeiltasten: Navigation. Tab: Kanal.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(calibratedRed:0.055,green:0.065,blue:0.078,alpha:1)
        background.setFill(); bounds.fill()
        let width = (bounds.width-gutter)/4
        let count = max(1,Int((bounds.height-header)/rowHeight))
        startRow = max(0,min(64-count,store.selectedRow-count/2))
        let font = NSFont.monospacedSystemFont(ofSize:16,weight:.medium)
        let small = NSFont.monospacedSystemFont(ofSize:10,weight:.semibold)
        let cyan = NSColor(calibratedRed:0.43,green:0.88,blue:0.81,alpha:1)
        let orange = NSColor(calibratedRed:1,green:0.62,blue:0.32,alpha:1)
        func text(_ s: String, x: CGFloat, y: CGFloat, color: NSColor, font: NSFont) {
            (s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:font,.foregroundColor:color])
        }
        NSColor.white.withAlphaComponent(0.035).setFill(); NSRect(x:0,y:0,width:bounds.width,height:header).fill()
        text("ROW",x:10,y:10,color:.secondaryLabelColor,font:small)
        for ch in 0..<4 {
            let x = gutter+CGFloat(ch)*width
            text(String(format:"%02d",ch+1),x:x+14,y:9,color:store.muted[ch] ? .systemRed : cyan,font:small)
            text((ch == 0 || ch == 3) ? "PAULA / L" : "PAULA / R",x:x+43,y:9,color:.secondaryLabelColor,font:small)
            text(store.muted[ch] ? "MUTE" : "ON",x:x+width-36,y:9,color:store.muted[ch] ? .systemRed : .secondaryLabelColor,font:small)
            NSColor.white.withAlphaComponent(0.07).setFill(); NSRect(x:x,y:0,width:1,height:bounds.height).fill()
        }
        for visible in 0..<count {
            let row = startRow+visible
            guard row < 64 else { break }
            let y = header+CGFloat(visible)*rowHeight
            if row % 4 == 0 { NSColor.white.withAlphaComponent(0.025).setFill(); NSRect(x:0,y:y,width:bounds.width,height:rowHeight).fill() }
            if row == store.playbackRow && store.playing && store.selectedOrder == store.playbackOrder {
                cyan.withAlphaComponent(0.12).setFill(); NSRect(x:0,y:y,width:bounds.width,height:rowHeight).fill()
                cyan.setFill(); NSRect(x:0,y:y,width:3,height:rowHeight).fill()
            }
            if row == store.selectedRow {
                NSColor.white.withAlphaComponent(0.065).setFill(); NSRect(x:0,y:y,width:bounds.width,height:rowHeight).fill()
                let fieldX = gutter+CGFloat(store.selectedChannel)*width+offsets[store.selectedField]-2
                let fieldWidth: CGFloat = store.selectedField == 0 ? 34 : 12
                let highlight = store.editMode ? orange : cyan
                highlight.withAlphaComponent(window?.firstResponder === self ? 0.28 : 0.12).setFill()
                NSRect(x:fieldX,y:y+1,width:fieldWidth,height:rowHeight-2).fill()
                highlight.setFill(); NSRect(x:fieldX,y:y+rowHeight-2,width:fieldWidth,height:1).fill()
            }
            text(String(format:"%02X",row),x:12,y:y+3,color:row == store.selectedRow ? orange : (row % 4 == 0 ? .lightGray : .darkGray),font:font)
            for ch in 0..<4 {
                let cell = store.pattern[row,ch]
                let x = gutter+CGFloat(ch)*width
                let alpha: CGFloat = store.muted[ch] ? 0.32 : 1
                text(cell.noteName,x:x+offsets[0],y:y+3,color:(cell.period == 0 ? NSColor.darkGray : cyan).withAlphaComponent(alpha),font:font)
                text(cell.sample == 0 ? ".." : String(format:"%02X",cell.sample),x:x+offsets[1],y:y+3,color:(cell.sample == 0 ? NSColor.darkGray : NSColor(calibratedWhite:0.78,alpha:1)).withAlphaComponent(alpha),font:font)
                text(cell.effect == 0 && cell.parameter == 0 ? "..." : cell.effectName,x:x+offsets[3],y:y+3,color:(cell.effect == 0 && cell.parameter == 0 ? NSColor.darkGray : orange).withAlphaComponent(alpha),font:font)
            }
        }
        setAccessibilityValue("Pattern \(store.patternIndex), Zeile \(store.selectedRow), Kanal \(store.selectedChannel+1), \(store.pattern[store.selectedRow,store.selectedChannel].noteName)")
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow,from:nil)
        let width = (bounds.width-gutter)/4
        let ch = min(3,max(0,Int((point.x-gutter)/width)))
        if point.y < header { store.muted[ch].toggle(); return }
        if store.playing { store.follow = false }
        store.selectedRow = min(63,max(0,startRow+Int((point.y-header)/rowHeight)))
        store.selectedChannel = ch
        let x = point.x-gutter-CGFloat(ch)*width
        store.selectedField = offsets.indices.min(by:{ abs(offsets[$0]-x) < abs(offsets[$1]-x) }) ?? 0
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) { if !store.input(event) { super.keyDown(with:event) }; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        if store.playing { store.follow = false }
        scrollRemainder += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        let delta = Int(scrollRemainder/threshold)
        if delta != 0 { store.selectedRow = min(63,max(0,store.selectedRow-delta)); scrollRemainder -= CGFloat(delta)*threshold; needsDisplay = true }
    }
    @objc func copy(_ sender: Any?) { store.copyPattern() }
    @objc func paste(_ sender: Any?) { store.pastePattern() }
    override func insertText(_ insertString: Any) { }
}

struct SignalView: NSViewRepresentable {
    var points: [Float]
    var color: NSColor = NSColor(calibratedRed:0.43,green:0.88,blue:0.81,alpha:1)
    var filled = false
    var loopRange: Range<Double>?
    func makeNSView(context: Context) -> SignalNSView { SignalNSView() }
    func updateNSView(_ view: SignalNSView, context: Context) {
        view.points = points; view.signalColor = color; view.filled = filled; view.loopRange = loopRange; view.needsDisplay = true
    }
}
final class SignalNSView: NSView {
    var points: [Float] = []
    var signalColor = NSColor.systemTeal
    var filled = false
    var loopRange: Range<Double>?
    override func draw(_ rect: NSRect) {
        NSColor(calibratedWhite:0.035,alpha:1).setFill(); bounds.fill()
        let mid = bounds.midY
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath(); grid.move(to:NSPoint(x:0,y:mid)); grid.line(to:NSPoint(x:bounds.width,y:mid))
        for n in 1..<8 { let x = CGFloat(n)*bounds.width/8; grid.move(to:NSPoint(x:x,y:0)); grid.line(to:NSPoint(x:x,y:bounds.height)) }
        grid.lineWidth = 0.5; grid.stroke()
        if let loopRange {
            signalColor.withAlphaComponent(0.09).setFill()
            NSRect(x:loopRange.lowerBound*bounds.width,y:0,width:(loopRange.upperBound-loopRange.lowerBound)*bounds.width,height:bounds.height).fill()
        }
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        let pixelCount = max(1,Int(bounds.width))
        if filled {
            for x in 0..<pixelCount {
                let start = x*points.count/pixelCount, end = max(start+1,(x+1)*points.count/pixelCount)
                let slice = points[min(start,points.count-1)..<min(end,points.count)]
                let lo = slice.min() ?? 0, hi = slice.max() ?? 0
                path.move(to:NSPoint(x:CGFloat(x),y:mid+CGFloat(lo)*mid*0.88))
                path.line(to:NSPoint(x:CGFloat(x),y:mid+CGFloat(hi)*mid*0.88+0.6))
            }
        } else {
            for (n,value) in points.enumerated() {
                let point = NSPoint(x:CGFloat(n)*bounds.width/CGFloat(points.count-1),y:mid+CGFloat(value)*mid*0.85)
                if n == 0 { path.move(to:point) } else { path.line(to:point) }
            }
        }
        signalColor.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
