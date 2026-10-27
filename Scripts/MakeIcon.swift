import AppKit

let directory = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = CGFloat(pixels) * 0.07
        NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: CGFloat(pixels) * 0.2, yRadius: CGFloat(pixels) * 0.2).fill()
        NSColor(calibratedRed: 0.94, green: 0.62, blue: 0.47, alpha: 1).setStroke()
        let p = CGFloat(pixels)
        let arrows = NSBezierPath()
        arrows.lineWidth = p * 0.065
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.move(to: NSPoint(x: p * 0.29, y: p * 0.63))
        arrows.line(to: NSPoint(x: p * 0.71, y: p * 0.63))
        arrows.move(to: NSPoint(x: p * 0.61, y: p * 0.73))
        arrows.line(to: NSPoint(x: p * 0.71, y: p * 0.63))
        arrows.line(to: NSPoint(x: p * 0.61, y: p * 0.53))
        arrows.move(to: NSPoint(x: p * 0.71, y: p * 0.37))
        arrows.line(to: NSPoint(x: p * 0.29, y: p * 0.37))
        arrows.move(to: NSPoint(x: p * 0.39, y: p * 0.47))
        arrows.line(to: NSPoint(x: p * 0.29, y: p * 0.37))
        arrows.line(to: NSPoint(x: p * 0.39, y: p * 0.27))
        arrows.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

// Package PNG representations directly without depending on iconutil.
func bigEndian(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
let entries = [("icp4", "16x16"), ("icp5", "32x32"), ("icp6", "32x32@2x"), ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x")]
var body = Data()
for (type, name) in entries {
    let png = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(name).png"))
    body.append(Data(type.utf8)); body.append(bigEndian(png.count + 8)); body.append(png)
}
var family = Data("icns".utf8)
family.append(bigEndian(body.count + 8)); family.append(body)
try family.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
