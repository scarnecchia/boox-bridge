#!/usr/bin/env swift
//
// make-icon.swift — render the app icon at every macOS size.
//
// Draws the Boox Bridge mark: a handwritten notebook page with a USB-C
// plug at its corner, on a rounded-rect tile with a soft gradient. Pure
// CoreGraphics, no assets, no dependencies — runs under plain `swift`.
// The Makefile runs `iconutil -c icns build/AppIcon.iconset` on the PNGs
// this writes.

import AppKit

let iconsetDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: iconsetDir, withIntermediateDirectories: true)

// (filename, pixel dimension) — the set iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func draw(into ctx: CGContext, size s: CGFloat) {
    // Background tile — rounded rect with a soft vertical gradient.
    let inset = s * 0.06
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = s * 0.22
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.30, green: 0.46, blue: 0.95, alpha: 1),
            CGColor(red: 0.16, green: 0.28, blue: 0.78, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    drawGlyph(into: ctx, tile: tile)
}

func drawGlyph(into ctx: CGContext, tile: CGRect) {
    // A white notebook page, slightly rotated, with handwritten-style lines.
    let pageW = tile.width * 0.54
    let pageH = pageW * 1.24
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: tile.midY)
    ctx.rotate(by: -0.06)
    let page = CGRect(x: -pageW / 2, y: -pageH / 2, width: pageW, height: pageH)
    let radius = pageW * 0.08
    // Soft page shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: -pageH * 0.03), blur: pageW * 0.10,
                  color: CGColor(red: 0, green: 0, blue: 0.15, alpha: 0.35))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Handwriting lines: an accent heading plus muted strokes, drawn in the
    // page's (rotated) coordinate space so they sit on the page naturally.
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: tile.midY)
    ctx.rotate(by: -0.06)
    let accent = CGColor(red: 0.20, green: 0.34, blue: 0.85, alpha: 1)
    let muted = CGColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 1)
    let padX = pageW * 0.14
    let lineH = pageH * 0.035
    let lineGap = pageH * 0.075
    var y = pageH / 2 - pageH * 0.14
    let lineSpecs: [(CGColor, CGFloat)] = [
        (accent, 0.70), (muted, 0.58), (muted, 0.48), (muted, 0.62),
    ]
    for (color, widthFraction) in lineSpecs {
        let bar = CGRect(
            x: -pageW / 2 + padX, y: y - lineH,
            width: (pageW - 2 * padX) * widthFraction, height: lineH)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.fillPath()
        y -= lineGap
    }
    ctx.restoreGState()

    // USB-C plug bottom-right: rounded capsule body + tongue, in white on
    // a small accent chip so it reads at 16px.
    let plugW = tile.width * 0.34
    let plugH = plugW * 0.42
    let plugRect = CGRect(
        x: tile.maxX - plugW * 0.78, y: tile.minY + tile.height * 0.10,
        width: plugW, height: plugH)
    ctx.setFillColor(accent)
    ctx.addPath(CGPath(roundedRect: plugRect, cornerWidth: plugH * 0.45, cornerHeight: plugH * 0.45, transform: nil))
    ctx.fillPath()
    // Tongue slot.
    let slot = CGRect(
        x: plugRect.midX - plugW * 0.16, y: plugRect.midY - plugH * 0.16,
        width: plugW * 0.32, height: plugH * 0.32)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.addPath(CGPath(roundedRect: slot, cornerWidth: slot.height / 2, cornerHeight: slot.height / 2, transform: nil))
    ctx.fillPath()
}

for (name, px) in variants {
    let dim = CGFloat(px)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, size: dim)
    guard let image = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

print("✓ wrote \(variants.count) icons to \(iconsetDir)")
