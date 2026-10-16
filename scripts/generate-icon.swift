import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func drawIcon(size: Int) throws {
    let canvas = NSImage(size: NSSize(width: 1024, height: 1024))
    canvas.lockFocus()
    let base = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.07, green: 0.22, blue: 0.29, alpha: 1).setFill()
    base.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.40, alpha: 1),
               ending: NSColor(calibratedRed: 0.035, green: 0.15, blue: 0.23, alpha: 1))!
        .draw(in: base, angle: -90)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    base.lineWidth = 2; base.stroke()
    let heights: [CGFloat] = [90, 160, 260, 390, 490, 360, 260, 390, 310, 180, 100]
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.31, green: 0.88, blue: 0.80, alpha: 1),
                              ending: NSColor(calibratedRed: 0.83, green: 1, blue: 0.92, alpha: 1))!
    for (index, height) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 226 + CGFloat(index) * 53, y: 512 - height / 2,
                                                   width: 38, height: height), xRadius: 19, yRadius: 19)
        gradient.draw(in: bar, angle: 90)
    }
    canvas.unlockFocus()
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let labels: [Int: [String]] = [16: ["icon_16x16"], 32: ["icon_16x16@2x", "icon_32x32"],
                                   64: ["icon_32x32@2x"], 128: ["icon_128x128"],
                                   256: ["icon_128x128@2x", "icon_256x256"],
                                   512: ["icon_256x256@2x", "icon_512x512"], 1024: ["icon_512x512@2x"]]
    for name in labels[size] ?? [] { try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png")) }
}
for size in [16, 32, 64, 128, 256, 512, 1024] { try drawIcon(size: size) }
