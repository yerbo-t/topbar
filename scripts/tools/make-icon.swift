// Рисует значок topbar по рисунку владельца и собирает scripts/AppIcon.icon (формат Icon Composer: светлый и тёмный вид).
// Буквы «pBar» превращаются в контуры шрифтом SF Rounded, поэтому значок не зависит от шрифтов на чужом Mac.
// Использование: swiftc -O scripts/tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon scripts/AppIcon.icon
import AppKit
import CoreText

struct Palette {
    let background: String   // "srgb:r,g,b,1" для icon.json
    let plate: String        // плашка и ножка (hex)
    let ink: String          // буквы и кружок на плашке (hex)
    let dot: String          // серая точка внутри кружка
}
let light = Palette(background: "srgb:0.96078,0.96078,0.96863,1.00000", plate: "#0A0A0C", ink: "#F6F6F7", dot: "#8A8D97")
let dark = Palette(background: "srgb:0.04314,0.04314,0.05098,1.00000", plate: "#F6F6F7", ink: "#0A0A0C", dot: "#8A8D97")

/// Контуры слов шрифтом SF Rounded Heavy: путь SVG, ширина и высота (базовая линия внутри рамки).
func textPath(_ string: String, size: CGFloat) -> (d: String, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    let font = (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
    var chars = Array(string.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    var advances = [CGSize](repeating: .zero, count: chars.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
    var d = ""
    var x: CGFloat = 0
    for (index, glyph) in glyphs.enumerated() {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            var move = CGAffineTransform(translationX: x, y: 0)
            if let moved = path.copy(using: &move) {
                moved.applyWithBlock { element in
                    let e = element.pointee
                    func f(_ p: CGPoint) -> String { String(format: "%.1f %.1f", p.x, -p.y) }
                    switch e.type {
                    case .moveToPoint: d += "M\(f(e.points[0]))"
                    case .addLineToPoint: d += "L\(f(e.points[0]))"
                    case .addQuadCurveToPoint: d += "Q\(f(e.points[0])) \(f(e.points[1]))"
                    case .addCurveToPoint: d += "C\(f(e.points[0])) \(f(e.points[1])) \(f(e.points[2]))"
                    case .closeSubpath: d += "Z"
                    @unknown default: break
                    }
                }
            }
        }
        x += advances[index].width
    }
    return (d, x, CTFontGetAscent(font), CTFontGetDescent(font))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon"
let assets = out + "/Assets"
try? FileManager.default.removeItem(atPath: out)
try! FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)

// Раскладка на холсте 1024×1024 (значок целиком, форму скругления накладывает система).
let text = textPath("pBar", size: 200)
let capHeight: CGFloat = 112
let scale = capHeight / (NSFont.systemFont(ofSize: 200, weight: .heavy).capHeight)
let textWidth = text.width * scale
let textLeft: CGFloat = 340
let baseline: CGFloat = 164

func plateSVG(_ p: Palette) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <path d="M112 0H912V162Q912 262 812 262H212Q112 262 112 162Z" fill="\(p.plate)"/>
      <circle cx="252" cy="120" r="52" fill="\(p.ink)"/>
      <circle cx="252" cy="120" r="19" fill="\(p.dot)"/>
      <path transform="translate(\(textLeft) \(baseline)) scale(\(String(format: "%.4f", scale)))" d="\(text.d)" fill="\(p.ink)"/>
    </svg>
    """
}
func stemSVG(_ p: Palette) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <rect x="372" y="386" width="280" height="478" rx="78" fill="\(p.plate)"/>
    </svg>
    """
}
try! plateSVG(light).write(toFile: assets + "/plate-light.svg", atomically: true, encoding: .utf8)
try! plateSVG(dark).write(toFile: assets + "/plate-dark.svg", atomically: true, encoding: .utf8)
try! stemSVG(light).write(toFile: assets + "/stem-light.svg", atomically: true, encoding: .utf8)
try! stemSVG(dark).write(toFile: assets + "/stem-dark.svg", atomically: true, encoding: .utf8)
print("ширина текста \(Int(textWidth)) пт, справа остаётся \(Int(912 - textLeft - textWidth)) пт")

let json = """
{
  "fill" : { "solid" : "\(light.background)" },
  "fill-specializations" : [
    { "appearance" : "dark", "value" : { "solid" : "\(dark.background)" } }
  ],
  "groups" : [
    {
      "layers" : [
        { "glass" : false, "hidden-specializations" : [ { "appearance" : "dark", "value" : true } ], "image-name" : "stem-light.svg", "name" : "stem-light" },
        { "glass" : false, "hidden-specializations" : [ { "appearance" : "dark", "value" : true } ], "image-name" : "plate-light.svg", "name" : "plate-light" },
        { "glass" : false, "hidden-specializations" : [ { "appearance" : "light", "value" : true } ], "image-name" : "stem-dark.svg", "name" : "stem-dark" },
        { "glass" : false, "hidden-specializations" : [ { "appearance" : "light", "value" : true } ], "image-name" : "plate-dark.svg", "name" : "plate-dark" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""
try! json.write(toFile: out + "/icon.json", atomically: true, encoding: .utf8)
print("значок: \(out)")
