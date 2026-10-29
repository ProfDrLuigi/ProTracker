import AppKit
import Foundation
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
NSColor(calibratedRed:0.07,green:0.08,blue:0.095,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:215,yRadius:215).fill()
NSColor(calibratedRed:1,green:0.62,blue:0.32,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:128,y:178,width:768,height:714),xRadius:140,yRadius:140).fill()
let font = NSFont.monospacedSystemFont(ofSize:570,weight:.black)
("pt" as NSString).draw(at:NSPoint(x:162,y:230),withAttributes:[.font:font,.foregroundColor:NSColor(calibratedWhite:0.07,alpha:1)])
for i in 0..<4 {
    NSColor(calibratedRed:0.43,green:0.88,blue:0.81,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:256+i*135,y:105,width:105,height:22),xRadius:9,yRadius:9).fill()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Protracker/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
