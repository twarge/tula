import AppKit
import CoreGraphics

// Tula app icon: an idealized balance scale, perfectly level, weighing a
// sphere against a pyramid. Drawn in a 1024pt coordinate space (origin
// bottom-left), scaled for every output size.

let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let bgTop = rgb(0x2B3358)
let bgBottom = rgb(0x161B2E)
let gold = rgb(0xFFC81E)
let goldDark = rgb(0xE09E00)
let cream = rgb(0x2E7BFF)
let creamShade = rgb(0x1D5AD1)
let coral = rgb(0xFF5147)
let coralDark = rgb(0xC8231C)

func drawScale(_ ctx: CGContext) {
    // Background
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(
        colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        grad, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // Pedestal base
    ctx.setFillColor(goldDark)
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: 512 - 230, y: 84, width: 460, height: 64),
            cornerWidth: 32, cornerHeight: 32, transform: nil))
    ctx.fillPath()

    // Pole
    ctx.setFillColor(gold)
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: 512 - 22, y: 110, width: 44, height: 744),
            cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.fillPath()

    // Beam
    ctx.addPath(
        CGPath(
            roundedRect: CGRect(x: 512 - 338, y: 806, width: 676, height: 48),
            cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.fillPath()

    // Pivot cap
    ctx.fillEllipse(in: CGRect(x: 512 - 40, y: 790, width: 80, height: 80))
    ctx.setFillColor(goldDark)
    ctx.fillEllipse(in: CGRect(x: 512 - 14, y: 816, width: 28, height: 28))

    // Both arms: strings + hanging pan
    for cx: CGFloat in [220, 804] {
        ctx.setStrokeColor(gold)
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx, y: 822))
        ctx.addLine(to: CGPoint(x: cx - 150, y: 402))
        ctx.move(to: CGPoint(x: cx, y: 822))
        ctx.addLine(to: CGPoint(x: cx + 150, y: 402))
        ctx.strokePath()

        // Deep dish: bottom half of an ellipse
        ctx.saveGState()
        ctx.clip(to: CGRect(x: cx - 178, y: 336, width: 356, height: 64))
        ctx.setFillColor(gold)
        ctx.fillEllipse(in: CGRect(x: cx - 172, y: 346, width: 344, height: 104))
        ctx.restoreGState()
    }

    // Left object: sphere resting in the dish
    let sphere = CGRect(x: 220 - 106, y: 350, width: 212, height: 212)
    ctx.setFillColor(cream)
    ctx.fillEllipse(in: sphere)
    ctx.saveGState()
    ctx.addEllipse(in: sphere)
    ctx.clip()
    // soft bottom shading + small highlight
    ctx.setFillColor(creamShade)
    ctx.fillEllipse(in: CGRect(x: 220 - 140, y: 350 - 108, width: 280, height: 190))
    ctx.setFillColor(rgb(0xFFFFFF, 0.5))
    ctx.fillEllipse(in: CGRect(x: 220 - 52, y: 350 + 134, width: 50, height: 38))
    ctx.restoreGState()

    // Right object: two-tone pyramid standing on the dish
    let apex = CGPoint(x: 804, y: 596)
    let baseY: CGFloat = 376
    let half: CGFloat = 130
    ctx.setFillColor(coral)
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: 804 - half, y: baseY))
    ctx.addLine(to: CGPoint(x: 804, y: baseY))
    ctx.closePath()
    ctx.fillPath()
    ctx.setFillColor(coralDark)
    ctx.beginPath()
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: 804, y: baseY))
    ctx.addLine(to: CGPoint(x: 804 + half, y: baseY))
    ctx.closePath()
    ctx.fillPath()
}

func render(pixels: Int, macRounded: Bool, to path: String) {
    let s = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if macRounded {
        // macOS icon shape: content squircle inset on a transparent canvas.
        let inset = s * 100 / 1024
        let content = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = content.width * 185 / 824
        ctx.addPath(
            CGPath(
                roundedRect: content, cornerWidth: radius, cornerHeight: radius,
                transform: nil))
        ctx.clip()
        ctx.translateBy(x: inset, y: inset)
        let k = content.width / S
        ctx.scaleBy(x: k, y: k)
    } else {
        let k = s / S
        ctx.scaleBy(x: k, y: k)
    }
    drawScale(ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(pixels: 1024, macRounded: false, to: "\(outDir)/ios-1024.png")
for (name, px) in [
    ("mac-16", 16), ("mac-16@2x", 32), ("mac-32", 32), ("mac-32@2x", 64),
    ("mac-128", 128), ("mac-128@2x", 256), ("mac-256", 256), ("mac-256@2x", 512),
    ("mac-512", 512), ("mac-512@2x", 1024),
] {
    render(pixels: px, macRounded: true, to: "\(outDir)/\(name).png")
}
