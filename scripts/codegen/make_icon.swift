// Renders DroidDeck's app icon at every macOS size. Usage: swift make_icon.swift <appiconset-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824/1024 content square with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    ctx.addPath(squircle); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Phone silhouette.
    let phoneW = s * 0.34, phoneH = s * 0.58
    let phone = CGRect(x: (s - phoneW) / 2, y: (s - phoneH) / 2, width: phoneW, height: phoneH)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
    ctx.setLineWidth(max(1, s * 0.022))
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil))
    ctx.strokePath()
    // Screen glow in DroidDeck green.
    let screen = phone.insetBy(dx: s * 0.035, dy: s * 0.05)
    ctx.setFillColor(NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.52, alpha: 0.9).cgColor)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
    ctx.fillPath()
    // Deck: three stacked lines under the phone.
    ctx.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 0.35).cgColor)
    for i in 0..<2 {
        let w = phoneW * (1.25 + CGFloat(i) * 0.3)
        let r = CGRect(x: (s - w) / 2, y: phone.minY - s * (0.045 + CGFloat(i) * 0.04), width: w, height: s * 0.018)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.009, cornerHeight: s * 0.009, transform: nil))
        ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: out.appending(path: name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "Contents.json"))
