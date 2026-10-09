// Draws the app icon: a π whose top bar grows reindeer antlers, cream on Reindeer black with a teal aurora glow.
// Writes the 1024×1024 app icon, the in-app logo, and the teal accent color into PiMobile/Assets.xcassets.
//
//   swift App/Design/make-logo.swift
import AppKit

let size = 1024.0
let cream = NSColor(srgbRed: 0.95, green: 0.91, blue: 0.82, alpha: 1)
let teal = NSColor(srgbRed: 0.18, green: 0.83, blue: 0.72, alpha: 1)
let black = NSColor(srgbRed: 0.04, green: 0.06, blue: 0.07, alpha: 1)

func draw(in context: CGContext) {
    context.setFillColor(black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // Aurora: a soft teal glow behind the antlers.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [teal.withAlphaComponent(0.45).cgColor, teal.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 760), endRadius: 520, options: [])

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Antlers, mirrored around the center, rising from the ends of π's bar.
    context.setStrokeColor(teal.cgColor)
    context.setLineWidth(32)
    for side in [-1.0, 1.0] {
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 512 + side * x, y: y) }
        let beam = CGMutablePath()
        beam.move(to: point(200, 640))
        beam.addCurve(to: point(300, 905), control1: point(205, 735), control2: point(330, 800))
        context.addPath(beam)
        // Tines.
        for (start, control, end) in [((216, 715), (170, 735), (122, 800)), ((255, 785), (225, 840), (215, 910)),
                                      ((292, 842), (340, 870), (392, 925))] {
            let tine = CGMutablePath()
            tine.move(to: point(Double(start.0), Double(start.1)))
            tine.addQuadCurve(to: point(Double(end.0), Double(end.1)), control: point(Double(control.0), Double(control.1)))
            context.addPath(tine)
        }
    }
    context.strokePath()

    // π: a bar and two legs, the right one curling at the foot.
    context.setStrokeColor(cream.cgColor)
    context.setLineWidth(80)
    let bar = CGMutablePath()
    bar.move(to: CGPoint(x: 300, y: 600))
    bar.addCurve(to: CGPoint(x: 730, y: 612), control1: CGPoint(x: 440, y: 625), control2: CGPoint(x: 600, y: 600))
    context.addPath(bar)
    let left = CGMutablePath()
    left.move(to: CGPoint(x: 415, y: 600))
    left.addCurve(to: CGPoint(x: 330, y: 215), control1: CGPoint(x: 410, y: 430), control2: CGPoint(x: 385, y: 290))
    context.addPath(left)
    let right = CGMutablePath()
    right.move(to: CGPoint(x: 615, y: 600))
    right.addCurve(to: CGPoint(x: 735, y: 230), control1: CGPoint(x: 605, y: 380), control2: CGPoint(x: 610, y: 215))
    context.addPath(right)
    context.strokePath()
}

func png() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "PiMobile/Assets.xcassets")
let files = FileManager.default

func write(_ json: String, to path: String) throws {
    try files.createDirectory(at: assets.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: assets.appending(path: path))
}

try write(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#, to: "Contents.json")
try write(#"""
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, to: "AppIcon.appiconset/Contents.json")
try png().write(to: assets.appending(path: "AppIcon.appiconset/icon-1024.png"))
try write(#"""
{
  "images" : [ { "filename" : "logo.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, to: "Logo.imageset/Contents.json")
try png().write(to: assets.appending(path: "Logo.imageset/logo.png"))
// Teal accent: darker on light backgrounds for contrast, the logo's teal on dark ones.
try write(#"""
{
  "colors" : [
    { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "0.000", "green" : "0.520", "blue" : "0.470" } },
      "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "0.180", "green" : "0.830", "blue" : "0.720" } },
      "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, to: "AccentColor.colorset/Contents.json")
print("wrote \(assets.path)")
