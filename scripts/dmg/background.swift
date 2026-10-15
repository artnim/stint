// Renders the DMG window background: a soft arrow from the app (left) to Applications (right)
// and a one-line hint. Coordinates match scripts/dmg/settings.py (600 × 400 window, icons at
// x 160 and 440, y 190 from the top).
//
//   swift background.swift <scale> <out.png>      scale 1 → 600×400, scale 2 → 1200×800
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[1]) else {
    fputs("usage: background.swift <scale> <out.png>\n", stderr); exit(2)
}
let w = 600.0, h = 400.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)          // points; the pixel size carries the Retina scale

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// background: a quiet vertical gradient
NSGradient(starting: NSColor(white: 0.985, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// arrow between the two icon slots (AppKit's origin is bottom-left; icons sit 190 pt from the top)
let y = h - 190
let amber = NSColor(red: 0.95, green: 0.62, blue: 0.13, alpha: 0.9)
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 245, y: y))
shaft.line(to: NSPoint(x: 345, y: y))
shaft.lineWidth = 6
shaft.lineCapStyle = .round
amber.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 362, y: y))
head.line(to: NSPoint(x: 338, y: y + 14))
head.line(to: NSPoint(x: 338, y: y - 14))
head.close()
amber.setFill()
head.fill()

// hint under the icons
let hint = "Drag Stint to Applications" as NSString
let style = NSMutableParagraphStyle(); style.alignment = .center
hint.draw(in: NSRect(x: 0, y: 95, width: w, height: 24), withAttributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(white: 0.35, alpha: 1),
    .paragraphStyle: style,
])

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
