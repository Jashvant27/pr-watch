import AppKit

// Usage: swift Scripts/make_icon.swift <AppIcon.appiconset dir> [preview.png]
// Draws the PR Watch icon with CoreGraphics (no bitmap source): the macOS rounded square with a
// soft dark-to-indigo gradient and GitHub's pull-request glyph (two dots joined by a line, and a
// branch arrow curving back into them) in white. Every macOS icon size plus Contents.json.
let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: make_icon.swift <AppIcon.appiconset dir> [preview.png]") }
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
}

/// Draws in a 1024 × 1024 top-down coordinate space (y grows downwards).
func drawIcon(in ctx: CGContext, size: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: size / 1024, y: -size / 1024)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // Background: the macOS icon shape (824 pt on the 1024 canvas, 185 pt corners).
    let inset: CGFloat = 100
    let shape = rounded(inset, inset, 824, 824, 185)
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [rgb(0x1A1D2E), rgb(0x2B2F6B), rgb(0x5B55E6)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: shape, angle: -60)
    // A faint sheen across the top.
    NSGradient(starting: rgb(0xFFFFFF, 0.14), ending: rgb(0xFFFFFF, 0))!.draw(in: shape, angle: -90)
    ctx.restoreGState()

    // The glyph, stroked in white with a soft shadow.
    let stroke: CGFloat = 60
    let radius: CGFloat = 66
    let leftX: CGFloat = 356, rightX: CGFloat = 668
    let topY: CGFloat = 318, bottomY: CGFloat = 706
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x0B0D20, 0.45).cgColor)
    NSColor.white.setStroke()

    for path in [circle(leftX, topY, radius), circle(leftX, bottomY, radius), circle(rightX, bottomY, radius)] {
        path.lineWidth = stroke
        path.stroke()
    }

    let trunk = NSBezierPath()
    trunk.move(to: NSPoint(x: leftX, y: topY + radius + stroke / 2))
    trunk.line(to: NSPoint(x: leftX, y: bottomY - radius - stroke / 2))
    trunk.lineWidth = stroke
    trunk.lineCapStyle = .round
    trunk.stroke()

    // The branch: up from the right dot, a rounded corner, then left into an arrowhead.
    let cornerY: CGFloat = topY
    let cornerR: CGFloat = 120
    let branch = NSBezierPath()
    branch.move(to: NSPoint(x: rightX, y: bottomY - radius - stroke / 2))
    branch.line(to: NSPoint(x: rightX, y: cornerY + cornerR))
    branch.curve(to: NSPoint(x: rightX - cornerR, y: cornerY),
                 controlPoint1: NSPoint(x: rightX, y: cornerY + cornerR * 0.45),
                 controlPoint2: NSPoint(x: rightX - cornerR * 0.45, y: cornerY))
    let tipX = leftX + radius + stroke / 2 + 30
    branch.line(to: NSPoint(x: tipX, y: cornerY))
    branch.lineWidth = stroke
    branch.lineCapStyle = .round
    branch.lineJoinStyle = .round
    branch.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: tipX + 74, y: cornerY - 74))
    head.line(to: NSPoint(x: tipX, y: cornerY))
    head.line(to: NSPoint(x: tipX + 74, y: cornerY + 74))
    head.lineWidth = stroke
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
    ctx.restoreGState()

    ctx.restoreGState()
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.cgContext.setAllowsAntialiasing(true)
    gc.cgContext.setShouldAntialias(true)
    drawIcon(in: gc.cgContext, size: CGFloat(size))
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let slots: [(String, Int)] = [("16x16", 1), ("16x16", 2), ("32x32", 1), ("32x32", 2), ("128x128", 1), ("128x128", 2),
                              ("256x256", 1), ("256x256", 2), ("512x512", 1), ("512x512", 2)]
var images: [[String: String]] = []
for (name, scale) in slots {
    let base = Int(name.split(separator: "x")[0])!
    let file = "icon_\(name)@\(scale)x.png"
    try render(base * scale).write(to: outDir.appendingPathComponent(file))
    images.append(["filename": file, "idiom": "mac", "scale": "\(scale)x", "size": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
if args.count >= 3 { try render(512).write(to: URL(fileURLWithPath: args[2])) }
print("wrote \(images.count) icons to \(outDir.path)")
