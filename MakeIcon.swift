import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 512)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464),
                                xRadius: 106, yRadius: 106)
        let base = NSColor(srgbRed: 0.10, green: 0.25, blue: 0.21, alpha: 1)
        let deep = NSColor(srgbRed: 0.04, green: 0.11, blue: 0.10, alpha: 1)
        NSGradient(starting: base, ending: deep)?.draw(in: tile, angle: -55)
        NSColor(srgbRed: 0.49, green: 0.88, blue: 0.72, alpha: 1).setStroke()
        let points = [NSPoint(x: 125, y: 167), NSPoint(x: 256, y: 337), NSPoint(x: 387, y: 237)]
        let route = NSBezierPath()
        route.move(to: points[0])
        route.line(to: points[1])
        route.line(to: points[2])
        route.lineWidth = 19
        route.lineCapStyle = .round
        route.stroke()
        for point in points {
            let node = NSBezierPath(ovalIn: NSRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64))
            deep.setFill()
            node.fill()
            node.lineWidth = 18
            node.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
