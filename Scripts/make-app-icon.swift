// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon, in the two forms the platforms take it.
//
//     swift Scripts/make-app-icon.swift
//
// Tula/AppIcon.icon is an Icon Composer bundle, for macOS and iOS: icon.json
// plus one SVG per layer. Xcode's asset compiler turns it into every size
// those platforms need and applies the system shape and the glass, dark,
// clear and tinted treatments, so the artwork is full bleed and carries no
// mask, rim, shadow or gloss of its own.
//
// Tula/Assets.xcassets/AppIcon.solidimagestack is the same drawing for
// visionOS, which takes nothing from an Icon Composer bundle: three 1024 px
// PNGs that the system crops to a circle and floats one above the other.
// Both go by the name AppIcon, and each platform's build picks out its own.
//
// The picture is an idealized balance scale, perfectly level, weighing a
// sphere against a pyramid. From back to front: the navy ground, the pedestal
// (Base), the pole, beam, strings and pans (Balance), and the two weights
// (Sphere and Pyramid).
//
// Both outputs are committed, so this only needs running when the design
// changes. To look at the Icon Composer bundle without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         "$PWD/Tula/AppIcon.icon" --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// The renditions are Default, Dark, TintedLight, TintedDark, ClearLight and
// ClearDark; the platforms macOS and iOS.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Colours

// The ground, top to bottom. Left to itself the system swaps the ground for
// its own charcoal in the dark appearance; the second pair keeps it navy.
let ground = [0x2B3358, 0x161B2E]
let groundDark = [0x1B2140, 0x090B16]

let gold = "#FFC81E"
let goldDark = "#E09E00"

/// A weight's lit and shaded colours.
typealias Tones = (lit: String, shaded: String)
let blue: Tones = ("#2E7BFF", "#1D5AD1")
let coral: Tones = ("#FF5147", "#C8231C")
// The tinted and clear appearances keep only a layer's lightness, and the
// blue and the red are dark enough to sink into the ground there. In those
// appearances the weights are drawn in these greys, lighter than the gold.
let paleSphere: Tones = ("#F0F0F0", "#B4B4B4")
let palePyramid: Tones = ("#F0F0F0", "#9C9C9C")

// MARK: Geometry, on the 1024 x 1024 canvas with y downward

let center = 512.0
let beamY = 194.0  // centre line of the beam, and the pivot
let armX = [220.0, 804.0]  // where the two pans hang
let stringSpread = 150.0  // half the width of a pan's pair of strings
let panY = 624.0  // rim of the pans
let panRadii = (x: 172.0, y: 52.0)

let sphere = (x: armX[0], y: 568.0, radius: 106.0)
// The sphere's shaded underside is the part of it inside this ellipse.
let shade = (x: armX[0], y: 687.0, radiusX: 140.0, radiusY: 95.0)

let pyramid = (x: armX[1], apexY: 428.0, baseY: 648.0, halfBase: 130.0)

// The numbers above lay the scale out from pan tip (x = 48) to pan tip, as the
// flat icon had it. Every layer is drawn at a fraction of that size, about the
// drawing's centre: in the square icon so the pans stand clear of the system's
// glass rim, and smaller still in the round one, where the circle visionOS
// crops to would otherwise cut close to the ends of the beam.
let squareFit = 0.9
let roundFit = 0.76
let drawing = (x: center, y: 547.0)  // centre of the drawing's bounds

// MARK: SVG

/// A coordinate, without a trailing ".0".
func n(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func svg(_ body: [String]) -> String {
    let lines = body.map { "  \($0)\n" }.joined()
    return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
        \(lines)</svg>

        """
}

/// A drawing at `fit` times the size the geometry gives it, with its centre
/// at the centre of the canvas.
func placed(_ body: [String], fit: Double) -> [String] {
    let shift = (x: 512 - fit * drawing.x, y: 512 - fit * drawing.y)
    return [#"<g transform="translate(\#(n(shift.x)) \#(n(shift.y))) scale(\#(n(fit)))">"#]
        + body.map { "  \($0)" } + ["</g>"]
}

func base() -> [String] {
    [#"<rect x="282" y="876" width="460" height="64" rx="32" fill="\#(goldDark)"/>"#]
}

func balance() -> [String] {
    var body = [
        #"<g fill="\#(gold)">"#,
        // Pole, standing on the pedestal.
        #"  <rect x="\#(n(center - 22))" y="\#(n(beamY - 24))" width="44" height="744" rx="22"/>"#,
        // Beam and pivot cap.
        #"  <rect x="\#(n(center - 338))" y="\#(n(beamY - 24))" width="676" height="48" rx="24"/>"#,
        #"  <circle cx="\#(n(center))" cy="\#(n(beamY))" r="40"/>"#,
    ]
    for x in armX {
        // Pan: the lower half of an ellipse, under a thin flat rim.
        let (left, right) = (x - panRadii.x, x + panRadii.x)
        body.append(
            #"  <path d="M\#(n(left)) \#(n(panY)) H\#(n(right)) V\#(n(panY + 2)) "#
                + #"A\#(n(panRadii.x)) \#(n(panRadii.y)) 0 0 1 \#(n(left)) \#(n(panY + 2)) Z"/>"#)
    }
    body.append("</g>")
    for x in armX {
        // The pair of strings a pan hangs from.
        body.append(
            #"<path d="M\#(n(x - stringSpread)) \#(n(panY - 2)) L\#(n(x)) \#(n(beamY + 8)) "#
                + #"L\#(n(x + stringSpread)) \#(n(panY - 2))" fill="none" stroke="\#(gold)" "#
                + #"stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>"#)
    }
    body.append(#"<circle cx="\#(n(center))" cy="\#(n(beamY))" r="14" fill="\#(goldDark)"/>"#)
    return body
}

func sphereLayer(_ tones: Tones) -> [String] {
    // Where the shade ellipse crosses the sphere's outline: with u, v measured
    // from the sphere's centre, u² = r² − v² on the circle, and substituting
    // into the ellipse gives a quadratic in v.
    let (r, a, b) = (sphere.radius, shade.radiusX, shade.radiusY)
    let d = shade.y - sphere.y
    let qa = 1 / (b * b) - 1 / (a * a)
    let qb = -2 * d / (b * b)
    let qc = (r * r) / (a * a) + (d * d) / (b * b) - 1
    let v = (-qb - (qb * qb - 4 * qa * qc).squareRoot()) / (2 * qa)
    let u = (r * r - v * v).squareRoot()
    let (left, right, y) = (sphere.x - u, sphere.x + u, sphere.y + v)
    return [
        #"<circle cx="\#(n(sphere.x))" cy="\#(n(sphere.y))" r="\#(n(r))" fill="\#(tones.lit)"/>"#,
        // Over the top along the ellipse, back underneath along the sphere.
        #"<path d="M\#(n(left)) \#(n(y)) A\#(n(a)) \#(n(b)) 0 0 1 \#(n(right)) \#(n(y)) "#
            + #"A\#(n(r)) \#(n(r)) 0 0 1 \#(n(left)) \#(n(y)) Z" fill="\#(tones.shaded)"/>"#,
    ]
}

func pyramidLayer(_ tones: Tones) -> [String] {
    let p = pyramid
    let apex = "\(n(p.x)),\(n(p.apexY))"
    return [
        // The whole face in the lit colour, then the shaded half over it, so
        // no seam shows down the middle.
        #"<polygon points="\#(apex) \#(n(p.x - p.halfBase)),\#(n(p.baseY)) "#
            + #"\#(n(p.x + p.halfBase)),\#(n(p.baseY))" fill="\#(tones.lit)"/>"#,
        #"<polygon points="\#(apex) \#(n(p.x)),\#(n(p.baseY)) "#
            + #"\#(n(p.x + p.halfBase)),\#(n(p.baseY))" fill="\#(tones.shaded)"/>"#,
    ]
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Pretty-printed with sorted keys is the form Xcode and Icon Composer save.
func write(json object: Any, to file: URL) throws {
    var data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: file)
}

// MARK: The Icon Composer bundle, for macOS and iOS

func gradient(_ colors: [Int]) -> [String: Any] {
    let stops = colors.map { hex -> String in
        let parts = [hex >> 16, hex >> 8, hex].map {
            String(format: "%.5f", Double($0 & 0xFF) / 255)
        }
        return "extended-srgb:\(parts.joined(separator: ",")),1.00000"
    }
    return ["linear-gradient": stops]
}

/// A layer, with the drawing that stands in for it in the tinted and clear
/// appearances if it has one.
typealias Layer = (name: String, body: [String], pale: [String]?)

/// Groups from front to back, the order icon.json lists them. Every piece is
/// a solid object, so every group is glass with the system's neutral shadow.
let groups: [[Layer]] = [
    [
        ("Sphere", sphereLayer(blue), sphereLayer(paleSphere)),
        ("Pyramid", pyramidLayer(coral), pyramidLayer(palePyramid)),
    ],
    [("Balance", balance(), nil)],
    [("Base", base(), nil)],
]

let bundle = root.appendingPathComponent("Tula/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: assets)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func write(_ body: [String], as name: String) throws -> String {
    try svg(placed(body, fit: squareFit))
        .write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
    return name
}

// A specialization with no appearance is the default; "tinted" also covers
// the clear appearances.
var document: [String: Any] = [
    "fill-specializations": [
        ["value": gradient(ground)],
        ["appearance": "dark", "value": gradient(groundDark)],
    ],
    "supported-platforms": ["squares": "shared"],
]
document["groups"] = try groups.map { layers -> [String: Any] in
    [
        "layers": try layers.map { layer -> [String: Any] in
            let image = try write(layer.body, as: layer.name + ".svg")
            guard let pale = layer.pale else { return ["image-name": image, "name": layer.name] }
            let paleImage = try write(pale, as: layer.name + "-Tinted.svg")
            return [
                "image-name-specializations": [
                    ["value": image],
                    ["appearance": "tinted", "value": paleImage],
                ],
                "name": layer.name,
            ]
        },
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ]
}
try write(json: document, to: bundle.appendingPathComponent("icon.json"))
print("wrote Tula/AppIcon.icon")

// MARK: The solid image stack, for visionOS

func groundLayer() -> [String] {
    let stops = ground.map { String(format: "#%06X", $0) }
    return [
        "<defs>",
        #"  <linearGradient id="ground" x1="0" y1="0" x2="0" y2="1">"#,
        #"    <stop offset="0" stop-color="\#(stops[0])"/>"#,
        #"    <stop offset="1" stop-color="\#(stops[1])"/>"#,
        "  </linearGradient>",
        "</defs>",
        #"<rect width="1024" height="1024" fill="url(#ground)"/>"#,
    ]
}

/// Layers from front to back, the order the stack lists them. The asset
/// compiler takes PNGs here, not SVGs, and the back layer has to be opaque.
let stackLayers: [(name: String, drawing: [String], opaque: Bool)] = [
    ("Front", placed(sphereLayer(blue) + pyramidLayer(coral), fit: roundFit), false),
    ("Middle", placed(base() + balance(), fit: roundFit), false),
    ("Back", groundLayer(), true),
]

/// Draws an SVG at 1024 x 1024 pixels and encodes it as an sRGB PNG.
func png(_ source: String, opaque: Bool) -> Data? {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let image = NSImage(data: Data(source.utf8)),
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: alpha.rawValue)
    else { return nil }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.current = nil

    let data = NSMutableData()
    guard let drawn = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, drawn, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

let catalog = root.appendingPathComponent("Tula/Assets.xcassets")
let stack = catalog.appendingPathComponent("AppIcon.solidimagestack")
let info: [String: Any] = ["author": "xcode", "version": 1]
try? FileManager.default.removeItem(at: stack)
for layer in stackLayers {
    let folder = stack.appendingPathComponent(layer.name + ".solidimagestacklayer")
    let imageSet = folder.appendingPathComponent("Content.imageset")
    let file = layer.name + ".png"
    try FileManager.default.createDirectory(at: imageSet, withIntermediateDirectories: true)
    guard let image = png(svg(layer.drawing), opaque: layer.opaque) else {
        fatalError("could not draw the \(layer.name) layer")
    }
    try image.write(to: imageSet.appendingPathComponent(file))
    try write(
        json: ["images": [["filename": file, "idiom": "vision", "scale": "2x"]], "info": info],
        to: imageSet.appendingPathComponent("Contents.json"))
    try write(json: ["info": info], to: folder.appendingPathComponent("Contents.json"))
}
try write(
    json: [
        "info": info,
        "layers": stackLayers.map { ["filename": $0.name + ".solidimagestacklayer"] },
    ],
    to: stack.appendingPathComponent("Contents.json"))
try write(json: ["info": info], to: catalog.appendingPathComponent("Contents.json"))
print("wrote Tula/Assets.xcassets/AppIcon.solidimagestack")
