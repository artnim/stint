// Renders Stint's icons from code so they can be regenerated at any size.
//
//   swift stint_icon.swift app <size> <out.png>              full-bleed app icon (the system applies the shape)
//   swift stint_icon.swift menubar <size> <out.png>          monochrome template for the menu bar
//
// The motif: a clock ring with one highlighted arc from 12 to 4 o'clock, "a stint" of time.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
func usage() -> Never { fputs("usage: stint_icon.swift app <size> <out> | menubar <size> <out>\n", stderr); exit(2) }
guard args.count >= 4 else { usage() }
let mode = args[1]

/// `opaque`: no alpha channel at all (App Store Connect rejects an app icon that has one, even fully opaque).
func context(_ size: Int, opaque: Bool = false) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: alpha.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

func write(_ ctx: CGContext, to path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let top = CGFloat.pi / 2
let arcEnd = top - 2 * .pi / 3            // 12 -> 4 o'clock, 120°

/// Ring, ticks (under everything), the stint arc, and the hand. `w` is the canvas width.
func drawClock(_ ctx: CGContext, w: CGFloat, ring: CGColor, tick: CGColor?, arc: CGColor?, hand: CGColor?,
               radius: CGFloat, ringWidth: CGFloat, arcWidth: CGFloat) {
    let center = CGPoint(x: w / 2, y: w / 2)
    if let tick {
        ctx.setStrokeColor(tick)
        ctx.setLineWidth(w * 0.03)
        ctx.setLineCap(.round)
        for i in 0..<4 {
            let a = top - CGFloat(i) * .pi / 2
            let inner = radius * 0.64, outer = radius * 0.78     // fully inside the ring
            ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
        }
        ctx.strokePath()
    }
    ctx.setStrokeColor(ring)
    ctx.setLineWidth(ringWidth)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    if let arc {
        ctx.setStrokeColor(arc)
        ctx.setLineWidth(arcWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: top, endAngle: arcEnd, clockwise: true)
        ctx.strokePath()
    }
    if let hand {
        ctx.setStrokeColor(hand)
        ctx.setFillColor(hand)
        ctx.setLineWidth(w * 0.045)
        ctx.setLineCap(.round)
        ctx.move(to: center)
        ctx.addLine(to: CGPoint(x: center.x + cos(arcEnd) * radius * 0.68, y: center.y + sin(arcEnd) * radius * 0.68))
        ctx.strokePath()
        let hub = w * 0.04
        ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
    }
}

switch mode {
case "app":
    guard args.count == 4, let size = Int(args[2]) else { usage() }
    let ctx = context(size, opaque: true)
    let w = CGFloat(size)
    // full-bleed: the system applies the icon shape, so no inset and no rounded corners
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [CGColor(red: 0.16, green: 0.19, blue: 0.42, alpha: 1),
                  CGColor(red: 0.08, green: 0.10, blue: 0.26, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: w), end: CGPoint(x: w, y: 0), options: [])
    drawClock(ctx, w: w,
              ring: CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
              tick: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9),
              arc: CGColor(red: 1.0, green: 0.72, blue: 0.20, alpha: 1),
              hand: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
              radius: w * 0.27, ringWidth: w * 0.055, arcWidth: w * 0.075)
    write(ctx, to: args[3])

case "menubar":
    guard args.count == 4, let size = Int(args[2]) else { usage() }
    let ctx = context(size)
    let w = CGFloat(size)
    // template image: black with alpha, macOS tints it; the ring is muted, the stint arc solid.
    // Same motif whether idle or running: the elapsed time next to it shows the state.
    drawClock(ctx, w: w,
              ring: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4),
              tick: nil,
              arc: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
              hand: nil,
              radius: w * 0.36, ringWidth: w * 0.11, arcWidth: w * 0.15)
    write(ctx, to: args[3])

default:
    usage()
}
