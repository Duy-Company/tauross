import AppKit

// A vector-drawn app icon; no downloaded images or build dependencies.
let destination = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let outer = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 216, yRadius: 216)
NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.95, alpha: 1).setFill()
outer.fill()
NSColor(calibratedRed: 0.35, green: 0.43, blue: 0.23, alpha: 1).setStroke()
let brackets = NSBezierPath()
brackets.lineWidth = 31
brackets.lineCapStyle = .round
brackets.lineJoinStyle = .round
for (x, y, sx, sy) in [(254.0, 770.0, 1.0, -1.0), (770, 770, -1, -1), (254, 254, 1, 1), (770, 254, -1, 1)] {
    brackets.move(to: NSPoint(x: x + sx * 84, y: y))
    brackets.line(to: NSPoint(x: x, y: y))
    brackets.line(to: NSPoint(x: x, y: y + sy * 84))
}
brackets.stroke()
let phone = NSBezierPath(roundedRect: NSRect(x: 407, y: 317, width: 210, height: 390), xRadius: 38, yRadius: 38)
phone.lineWidth = 22
phone.stroke()
let detail = NSBezierPath()
detail.lineWidth = 17; detail.lineCapStyle = .round
detail.move(to: NSPoint(x: 483, y: 668)); detail.line(to: NSPoint(x: 541, y: 668))
detail.move(to: NSPoint(x: 483, y: 354)); detail.line(to: NSPoint(x: 541, y: 354)); detail.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: destination))
