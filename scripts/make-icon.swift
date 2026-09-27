// Renders the app icon into an .iconset folder: `swift scripts/make-icon.swift <out.iconset>`.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024

    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: color(0x2C2C30), ending: color(0x0E0E10))!.draw(in: tile, angle: -90)

    // Battery body and cap.
    let width = 560 * s, height = 310 * s
    let body = NSRect(x: 512 * s - width / 2 - 20 * s, y: 512 * s - height / 2, width: width, height: height)
    let shell = NSBezierPath(roundedRect: body, xRadius: 78 * s, yRadius: 78 * s)
    color(0xFFFFFF, 0.2).setFill()
    shell.fill()
    NSBezierPath(roundedRect: NSRect(x: body.maxX + 16 * s, y: 512 * s - 58 * s, width: 38 * s, height: 116 * s),
                 xRadius: 18 * s, yRadius: 18 * s).fill()

    // Two charge bars: Claude orange on top, OpenAI green below.
    let inner = body.insetBy(dx: 30 * s, dy: 30 * s)
    let gap = 22 * s
    let barHeight = (inner.height - gap) / 2
    let bars: [(CGFloat, NSColor, CGFloat)] = [
        (inner.minY + barHeight + gap, color(0xD97757), 0.74),
        (inner.minY, color(0x34C759), 0.48),
    ]
    for (y, fill, fraction) in bars {
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: y, width: inner.width * fraction, height: barHeight),
                     xRadius: 34 * s, yRadius: 34 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}
