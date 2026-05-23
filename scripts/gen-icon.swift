#!/usr/bin/env swift

// Generates chord.app's AppIcon.appiconset from a single 1024px
// programmatic master. Run from the repo root:
//
//     swift scripts/gen-icon.swift
//
// Produces:
//   assets/icon/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png
//   assets/icon/AppIcon.appiconset/Contents.json
//   assets/icon/chord.iconset/icon_*.png  (intermediate for iconutil)
//   assets/icon/chord.icns
//
// Design: rounded-square gradient (deep indigo → accent cyan) with
// three connected dots in a triangle — a chord diagram in shorthand,
// the three "notes" representing keyboard + modifier + mouse fused
// into one binding.

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let outDir = "assets/icon"
let appiconset = "\(outDir)/AppIcon.appiconset"
let iconset = "\(outDir)/chord.iconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: appiconset, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func makeIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square clip (Apple-style ~22.37% corner radius).
    let r = size * 0.2237
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(roundedRect: rect, cornerWidth: r,
                      cornerHeight: r, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Gradient background.
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors: CFArray = [
        // deep indigo (top-left)
        CGColor(srgbRed: 0.12, green: 0.13, blue: 0.28, alpha: 1.0),
        // accent cyan (bottom-right)
        CGColor(srgbRed: 0.17, green: 0.52, blue: 0.84, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors,
                          locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

    // Three "notes" — a triangular chord diagram.
    // Coordinates are unit-square (0…1) then scaled to size.
    let nodes: [(CGFloat, CGFloat)] = [
        (0.30, 0.72),   // top-left
        (0.70, 0.72),   // top-right
        (0.50, 0.30),   // bottom-centre
    ]
    let pts = nodes.map {
        CGPoint(x: $0.0 * size, y: $0.1 * size)
    }

    // Connecting strokes between every pair (the chord).
    ctx.setLineCap(.round)
    ctx.setLineWidth(size * 0.045)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88))
    for i in 0..<pts.count {
        for j in (i+1)..<pts.count {
            ctx.move(to: pts[i])
            ctx.addLine(to: pts[j])
        }
    }
    ctx.strokePath()

    // Filled dots on top of the strokes.
    let dotR = size * 0.105
    ctx.setFillColor(.white)
    for p in pts {
        let r = CGRect(x: p.x - dotR, y: p.y - dotR,
                       width: dotR * 2, height: dotR * 2)
        ctx.fillEllipse(in: r)
    }

    // Tiny inner accent dot — picks up the gradient cyan at the
    // pixel scale and stops the disks reading as featureless white.
    let inner = dotR * 0.32
    ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.52,
                             blue: 0.84, alpha: 1.0))
    for p in pts {
        let r = CGRect(x: p.x - inner, y: p.y - inner,
                       width: inner * 2, height: inner * 2)
        ctx.fillEllipse(in: r)
    }

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to encode \(path)\n", stderr); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
}

// Master 1024 first; sips downscales for everything else (sharper
// at small sizes than redrawing the geometry).
let master = makeIcon(size: 1024)
savePNG(master, path: "\(iconset)/icon_512x512@2x.png")

let sizes: [(CGFloat, String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
]
for (px, name) in sizes {
    let img = makeIcon(size: px)
    savePNG(img, path: "\(iconset)/\(name)")
}

// Mirror the iconset to the appiconset directory (Xcode asset
// catalog format) and write Contents.json.
let appiconJSON: [String: Any] = [
    "images": [
        ["size": "16x16",   "idiom": "mac", "filename": "icon_16x16.png",     "scale": "1x"],
        ["size": "16x16",   "idiom": "mac", "filename": "icon_16x16@2x.png",  "scale": "2x"],
        ["size": "32x32",   "idiom": "mac", "filename": "icon_32x32.png",     "scale": "1x"],
        ["size": "32x32",   "idiom": "mac", "filename": "icon_32x32@2x.png",  "scale": "2x"],
        ["size": "128x128", "idiom": "mac", "filename": "icon_128x128.png",   "scale": "1x"],
        ["size": "128x128", "idiom": "mac", "filename": "icon_128x128@2x.png","scale": "2x"],
        ["size": "256x256", "idiom": "mac", "filename": "icon_256x256.png",   "scale": "1x"],
        ["size": "256x256", "idiom": "mac", "filename": "icon_256x256@2x.png","scale": "2x"],
        ["size": "512x512", "idiom": "mac", "filename": "icon_512x512.png",   "scale": "1x"],
        ["size": "512x512", "idiom": "mac", "filename": "icon_512x512@2x.png","scale": "2x"],
    ],
    "info": ["version": 1, "author": "chord"],
]
let json = try JSONSerialization.data(
    withJSONObject: appiconJSON, options: [.prettyPrinted])
try json.write(to: URL(fileURLWithPath: "\(appiconset)/Contents.json"))

for f in (try? fm.contentsOfDirectory(atPath: iconset)) ?? [] {
    let src = "\(iconset)/\(f)"
    let dst = "\(appiconset)/\(f)"
    try? fm.removeItem(atPath: dst)
    try fm.copyItem(atPath: src, toPath: dst)
}

print("wrote \(appiconset)/")
print("run `iconutil -c icns \(iconset) -o \(outDir)/chord.icns` to bake .icns")
