import AppKit
// usage: make-icon <out.png> <variant: light|dark|tinted>
let out = CommandLine.arguments[1], variant = CommandLine.arguments[2]
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}

struct Palette { let bg: [CGColor]; let glow: CGColor; let frame: [CGColor]; let shadow: CGColor; let lock: [CGColor] }
let p: Palette = switch variant {
case "dark":
    Palette(bg: [c(0x06140F), c(0x000000)], glow: c(0x10B981, 0.22),
            frame: [c(0xA7F3D0), c(0x6EE7B7)], shadow: c(0x000000, 0.6), lock: [c(0x34D399), c(0x10B981)])
case "tinted":
    Palette(bg: [c(0x000000), c(0x000000)], glow: c(0xFFFFFF, 0),
            frame: [c(0xFFFFFF), c(0xD4D4D4)], shadow: c(0x000000, 0), lock: [c(0x9A9A9A), c(0x8A8A8A)])
default:
    Palette(bg: [c(0x065F46), c(0x0B1F1A)], glow: c(0x34D399, 0.40),
            frame: [c(0xFFFFFF), c(0xD1FAE5)], shadow: c(0x02130D, 0.55), lock: [c(0x6EE7B7), c(0x10B981)])
}

func background() {
    ctx.drawLinearGradient(gradient(p.bg), start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func fill(_ path: CGPath, _ colors: [CGColor], top: CGFloat, bottom: CGFloat, shadow: Bool = false) {
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 56, color: p.shadow)
        ctx.addPath(path); ctx.setFillColor(colors[0]); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

background()
ctx.drawRadialGradient(gradient([p.glow, c(0x34D399, 0)]), startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 480, options: [])

// Monitor: frame, stand and base in one silhouette; the screen is cut out so the background shows.
let monitor = [
    CGPath(roundedRect: CGRect(x: 176, y: 318, width: 672, height: 470), cornerWidth: 64, cornerHeight: 64, transform: nil),
    CGPath(rect: CGRect(x: 466, y: 236, width: 92, height: 100), transform: nil),
    CGPath(roundedRect: CGRect(x: 336, y: 206, width: 352, height: 52), cornerWidth: 26, cornerHeight: 26, transform: nil),
].reduce(CGMutablePath() as CGPath) { $0.union($1) }
fill(monitor, p.frame, top: 788, bottom: 206, shadow: true)

let screen = CGPath(roundedRect: CGRect(x: 220, y: 362, width: 584, height: 382), cornerWidth: 28, cornerHeight: 28, transform: nil)
ctx.saveGState()
ctx.addPath(screen); ctx.clip()
background()
ctx.drawRadialGradient(gradient([p.glow, c(0x34D399, 0)]), startCenter: CGPoint(x: 512, y: 553), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 553), endRadius: 300, options: [])
ctx.restoreGState()

// Padlock on the screen: shackle arc, body, keyhole cut out.
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: 452, y: 548))
shackle.addLine(to: CGPoint(x: 452, y: 612))
shackle.addArc(center: CGPoint(x: 512, y: 612), radius: 60, startAngle: .pi, endAngle: 0, clockwise: true)
shackle.addLine(to: CGPoint(x: 572, y: 548))
let lockBody = CGPath(roundedRect: CGRect(x: 412, y: 418, width: 200, height: 156), cornerWidth: 30, cornerHeight: 30, transform: nil)
let lock = shackle.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10).union(lockBody)
fill(lock, p.lock, top: 690, bottom: 418)

let keyhole = CGPath(ellipseIn: CGRect(x: 491, y: 494, width: 42, height: 42), transform: nil)
    .union(CGPath(roundedRect: CGRect(x: 500, y: 450, width: 24, height: 60), cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.saveGState()
ctx.addPath(keyhole); ctx.clip()
background()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
