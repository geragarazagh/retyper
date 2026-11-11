// Retyper's icon: the G/П key cap of a Russian Apple keyboard, laid in place of an icon. The app rests on that fact:
// every key carries two letters, and Retyper reads the other one. G/П is the first key of «ghbdtn» → «привет».
// One version for both appearances: keys are dark on Apple's laptops, so the cap stays dark in the light theme too.
// Legends as Apple draws them (its render of the Russian Magic Keyboard with black keys): SF Pro Regular, colour #E0DEDD,
// the cap shaded from #141416 at the top to #2D2D2F at the bottom. Their arrangement as on a MacBook key: G large in the
// centre, П at 0.74 of its height in the lower right, with equal right and bottom margins.
// An Icon Composer icon: this draws the whole cap, 1024 px, opaque; ./build writes icon.json and runs actool.
// Usage: icon <dir> writes <dir>/key.png.

import AppKit

func letter(_ s: String, height: CGFloat, place: (CGRect) -> CGPoint, in c: CGContext) {
    func line(_ size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0xE0 / 255, green: 0xDE / 255, blue: 0xDD / 255, alpha: 1)]))
    }
    c.textPosition = .zero   // image bounds are measured from the current text position, which a draw moves
    let l = line(100 * height / CTLineGetImageBounds(line(100), c).height)
    c.textPosition = .zero
    c.textPosition = place(CTLineGetImageBounds(l, c))
    CTLineDraw(l, c)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let c = ctx.cgContext
let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
    CGColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1),
    CGColor(srgbRed: 0x2D / 255, green: 0x2D / 255, blue: 0x2F / 255, alpha: 1)] as CFArray, locations: [0, 1])!
c.drawLinearGradient(shade, start: CGPoint(x: 0, y: 1024), end: .zero, options: [])
// Heights 0.25 and 0.185 of the cap and the margin 0.105: measured on a photo of the key, the margin being the nearest
// equal right and bottom margin to where П stands there.
let margin: CGFloat = 0.105 * 1024
letter("G", height: 0.25 * 1024, place: { CGPoint(x: 512 - $0.midX, y: 512 - $0.midY) }, in: c)
letter("П", height: 0.185 * 1024, place: { CGPoint(x: 1024 - margin - $0.maxX, y: margin - $0.minY) }, in: c)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/key.png"))
