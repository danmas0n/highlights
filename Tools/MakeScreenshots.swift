// Builds the captioned App Store screenshots from raw device captures.
//
//     swift Tools/MakeScreenshots.swift
//
// Reads AppStore/screenshots/*.png, writes AppStore/screenshots/final/NN-name.png at
// 2868×1320 — the 6.9" iPhone landscape size, which App Store Connect scales down for every
// smaller phone. Landscape throughout: the app is used sideways on a tripod, and a consistent
// orientation keeps the gallery tidy.

import AppKit
import CoreGraphics
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("AppStore/screenshots")
let out = root.appendingPathComponent("final")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let canvas = CGSize(width: 2868, height: 1320)
let yellow = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)

struct Shot {
    let file: String            // prefix of the source file name
    let crop: CGRect?           // unit-space crop; nil = trim black pillarbox bars automatically
}

struct Slide {
    let name: String
    let headline: String
    let subhead: String
    let shots: [Shot]
}

let slides: [Slide] = [
    Slide(name: "01-tap",
          headline: "Tap when it happens.\nIt's already saved.",
          subhead: "The last 25 seconds are always kept. Tap the screen and they become a clip — no filming the whole game.",
          shots: [Shot(file: "In game screenshot 2026-09-22 at 5.05", crop: nil)]),
    Slide(name: "02-any-sport",
          headline: "Any sport with\na sideline.",
          subhead: "Real telephoto zoom for the far end of the field, and a game clock that keeps track of periods.",
          shots: [Shot(file: "In game screenshot 2026-09-22 at 4.48", crop: nil)]),
    Slide(name: "03-edit",
          headline: "Trim it and frame\nit at home.",
          subhead: "Every moment sorted by game. Recorded in 4K, so a 2× crop is still full HD.",
          shots: [
            Shot(file: "Screenshot 2026-09-27 at 11.12.48", crop: CGRect(x: 0, y: 0.065, width: 1, height: 0.60)),
            Shot(file: "Screenshot 2026-09-27 at 11.13.22", crop: CGRect(x: 0, y: 0.065, width: 1, height: 0.905)),
          ]),
    Slide(name: "04-full-screen",
          headline: "Turn sideways\nto look closer.",
          subhead: "See exactly what you're saving before it goes to Photos — ready for the grandparents, or a college coach.",
          shots: [Shot(file: "Screenshot 2026-09-27 at 11.13.47", crop: nil)]),
    Slide(name: "05-private",
          headline: "Made by a sports\nparent. Free.",
          subhead: "No account, no ads, no tracking. Nothing leaves your phone, and the microphone is one tap from off.",
          shots: [Shot(file: "About Screen Screenshot", crop: CGRect(x: 0, y: 0.065, width: 1, height: 0.725))]),
]

// MARK: - Image helpers

func load(_ prefix: String) -> CGImage {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    guard let name = files.first(where: { $0.hasPrefix(prefix) }),
          let image = NSImage(contentsOf: root.appendingPathComponent(name)),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("missing screenshot: \(prefix)") }
    return cg
}

/// Finds the camera picture inside a landscape capture by trimming columns that are mostly black.
/// "Mostly", because the privacy indicator dot sits in the left bar.
func pillarboxCrop(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = ctx.data else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    func isContent(_ x: Int) -> Bool {
        var lit = 0
        for y in stride(from: 0, to: h, by: 4) {
            let i = (y * w + x) * 4
            if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 45 { lit += 1 }
        }
        return lit > (h / 4) / 3
    }
    var left = 0; while left < w / 3, !isContent(left) { left += 1 }
    var right = w - 1; while right > w * 2 / 3, !isContent(right) { right -= 1 }
    return CGRect(x: Double(left) / Double(w), y: 0, width: Double(right - left + 1) / Double(w), height: 1)
}

func cropped(_ image: CGImage, _ unit: CGRect) -> CGImage {
    let r = CGRect(x: unit.minX * Double(image.width), y: unit.minY * Double(image.height),
                   width: unit.width * Double(image.width), height: unit.height * Double(image.height))
        .integral
    return image.cropping(to: r)!
}

// MARK: - Render

for slide in slides {
    // Opaque on purpose: App Store Connect rejects screenshots with an alpha channel.
    let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    // Background: near-black with a faint warm glow behind the caption.
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(srgbRed: 0.10, green: 0.10, blue: 0.09, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.03, green: 0.035, blue: 0.045, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 400, y: canvas.height * 0.6), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: canvas.height * 0.6), endRadius: 1900,
                           options: .drawsAfterEndLocation)

    // Screenshots, right-aligned and vertically centred.
    let images = slide.shots.map { shot -> CGImage in
        let image = load(shot.file)
        return cropped(image, shot.crop ?? pillarboxCrop(image))
    }
    let maxHeight: CGFloat = 1140
    // Leave the caption room to breathe: a full-height 16:9 frame would squeeze it to a sliver.
    let maxGroupWidth: CGFloat = 1800
    let gap: CGFloat = 56
    let rightMargin: CGFloat = 100
    // One scale for the whole group, so two phones side by side show UI at the same size even
    // when one is cropped shorter than the other.
    let sourceWidth = images.reduce(0) { $0 + CGFloat($1.width) }
    let sourceHeight = images.map { CGFloat($0.height) }.max() ?? 1
    let scale = min(maxHeight / sourceHeight,
                    (maxGroupWidth - gap * CGFloat(images.count - 1)) / sourceWidth)
    let sizes = images.map { CGSize(width: CGFloat($0.width) * scale, height: CGFloat($0.height) * scale) }
    let totalWidth = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(images.count - 1)
    let groupTop = (canvas.height + sourceHeight * scale) / 2   // AppKit origin is bottom-left
    // Caption on the left at a readable measure; the screenshots centre in whatever is left.
    let left: CGFloat = 130
    let columnWidth = min(canvas.width - rightMargin - totalWidth - left - 110, 1050)
    let free = canvas.width - rightMargin - (left + columnWidth + 110)
    var x = canvas.width - rightMargin - free + (free - totalWidth) / 2
    for (image, size) in zip(images, sizes) {
        // Top-aligned, so shorter crops hang from the same line as taller ones.
        let drawRect = CGRect(x: x, y: groupTop - size.height, width: size.width, height: size.height)
        let path = CGPath(roundedRect: drawRect, cornerWidth: 40, cornerHeight: 40, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 60, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(3); ctx.strokePath()
        ctx.restoreGState()
        x += size.width + gap
    }

    // Caption column.
    let headlineFont = NSFont.systemFont(ofSize: 104, weight: .heavy)
    let para = NSMutableParagraphStyle(); para.lineSpacing = 6
    let headline = NSAttributedString(string: slide.headline, attributes: [
        .font: headlineFont, .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: -1.5,
    ])
    let subPara = NSMutableParagraphStyle(); subPara.lineSpacing = 12
    let subhead = NSAttributedString(string: slide.subhead, attributes: [
        .font: NSFont.systemFont(ofSize: 50, weight: .medium),
        .foregroundColor: NSColor(white: 0.68, alpha: 1), .paragraphStyle: subPara,
    ])
    let bound = CGSize(width: columnWidth, height: 2000)
    let hSize = headline.boundingRect(with: bound, options: [.usesLineFragmentOrigin]).size
    let sSize = subhead.boundingRect(with: bound, options: [.usesLineFragmentOrigin]).size
    let barHeight: CGFloat = 12, barGap: CGFloat = 56, textGap: CGFloat = 48
    let blockHeight = barHeight + barGap + hSize.height + textGap + sSize.height
    var top = (canvas.height + blockHeight) / 2   // AppKit origin is bottom-left

    ctx.setFillColor(yellow.cgColor)
    ctx.fill(CGRect(x: left, y: top - barHeight, width: 140, height: barHeight))
    top -= barHeight + barGap
    headline.draw(with: CGRect(x: left, y: top - hSize.height, width: columnWidth, height: hSize.height),
                  options: [.usesLineFragmentOrigin])
    top -= hSize.height + textGap
    subhead.draw(with: CGRect(x: left, y: top - sSize.height, width: columnWidth, height: sSize.height),
                 options: [.usesLineFragmentOrigin])

    NSGraphicsContext.current = nil
    let url = out.appendingPathComponent("\(slide.name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent)  caption column \(Int(columnWidth))px")
}
