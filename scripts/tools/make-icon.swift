// Рисует значок приложения (остров с двумя точками статуса и строками списка) и собирает scripts/AppIcon.icns.
// Использование: swiftc -O scripts/tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon scripts/AppIcon.icns
import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Плитка по шаблону macOS: 824 пт внутри 1024, радиус около 185.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.27, green: 0.31, blue: 0.47, alpha: 1),
                                                           CGColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 800, y: 100), options: [])
    ctx.restoreGState()

    // «Остров»: чёрная капсула у верхнего края плитки.
    let island = CGRect(x: 232, y: 640, width: 560, height: 170)
    let islandPath = CGPath(roundedRect: island, cornerWidth: 85, cornerHeight: 85, transform: nil)
    ctx.addPath(islandPath); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.addPath(islandPath); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); ctx.setLineWidth(4); ctx.strokePath()
    // Две точки статуса по краям.
    for (x, color) in [(CGFloat(335), CGColor(red: 0.35, green: 0.65, blue: 1, alpha: 1)), (CGFloat(689), CGColor(red: 0.27, green: 0.78, blue: 0.47, alpha: 1))] {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: x - 30, y: island.midY - 30, width: 60, height: 60))
    }

    // Строки раскрытого списка под островом.
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
    for (i, width) in [CGFloat(470), CGFloat(390), CGFloat(300)].enumerated() {
        let y = 540 - CGFloat(i) * 90
        let row = CGRect(x: 512 - width / 2, y: y, width: width, height: 44)
        ctx.addPath(CGPath(roundedRect: row, cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
    }
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let dir = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: dir)
print(p.terminationStatus == 0 ? "значок: \(out)" : "iconutil не справился")
