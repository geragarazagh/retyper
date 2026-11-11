// SourceKey's icon: one key cap with both of its letters, G and П, as Russian Apple keyboards print them. The app rests on
// that fact: every key carries two letters, and SourceKey reads the other one. G/П is the first key of «ghbdtn» → «привет».
// An Icon Composer icon (macOS 26+ switches it with the theme): this draws only the picture, light.png and dark.png,
// 1024 px, transparent; the plate is the system's own fill (./build writes icon.json and runs actool).
// Grid of the family (STT, HoldQ): drawn on the old 824 px plate (100..924) scaled to the canvas; the cap is 576 square
// like their marks, its line 48; letters SF 230 medium. Ink #1C1C1E on light (STT's), white on dark.
// Usage: icon <dir> writes <dir>/light.png and <dir>/dark.png.

import AppKit

func letter(_ s: String, _ color: CGColor, center: CGPoint, in c: CGContext) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 230, weight: .medium), .foregroundColor: NSColor(cgColor: color)!]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a))
    c.textPosition = .zero   // image bounds are measured from the current text position, which a draw moves
    let b = CTLineGetImageBounds(line, c)
    c.textPosition = CGPoint(x: center.x - b.midX, y: center.y - b.midY)
    CTLineDraw(line, c)
}

func draw(_ light: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let c = ctx.cgContext
    c.scaleBy(x: 1024 / 824, y: 1024 / 824); c.translateBy(x: -100, y: -100)
    let ink = light ? CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) : CGColor(gray: 1, alpha: 1)
    c.setStrokeColor(ink); c.setLineWidth(48)
    c.addPath(CGPath(roundedRect: CGRect(x: 248, y: 248, width: 528, height: 528), cornerWidth: 104, cornerHeight: 104, transform: nil))
    c.strokePath()
    letter("G", ink, center: CGPoint(x: 400, y: 628), in: c)
    letter("П", ink, center: CGPoint(x: 624, y: 396), in: c)
    NSGraphicsContext.current = nil
    return rep
}

let out = CommandLine.arguments[1]
for (name, light) in [("light", true), ("dark", false)] {
    try! draw(light).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
