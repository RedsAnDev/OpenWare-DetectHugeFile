// Genera AppIcon.icns: swift Tools/make_icon.swift <out.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = NSTemporaryDirectory() + "dhf.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let r = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: r, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1)])!.draw(in: bg, angle: -60)
    // grafico a torta "spazio occupato"
    let c = NSPoint(x: s / 2, y: s / 2), rad = s * 0.27
    NSColor.white.withAlphaComponent(0.35).setFill()
    let full = NSBezierPath(); full.move(to: c); full.appendArc(withCenter: c, radius: rad, startAngle: 0, endAngle: 360); full.fill()
    NSColor.white.setFill()
    let slice = NSBezierPath(); slice.move(to: c); slice.appendArc(withCenter: c, radius: rad, startAngle: 90, endAngle: -150, clockwise: true); slice.close(); slice.fill()
    NSColor(calibratedRed: 1, green: 0.55, blue: 0.2, alpha: 1).setFill()
    let hot = NSBezierPath(); hot.move(to: NSPoint(x: c.x + s * 0.03, y: c.y + s * 0.03))
    hot.appendArc(withCenter: NSPoint(x: c.x + s * 0.03, y: c.y + s * 0.03), radius: rad, startAngle: 10, endAngle: 85); hot.close(); hot.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try! render(base * scale).write(to: URL(fileURLWithPath: tmp + "/" + name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp, "-o", out]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Creata \(out)" : "iconutil fallito")
