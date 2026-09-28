#!/usr/bin/env swift
//
// Renders the 1024×1024 image for the tip jar's in-app purchases. Run from the repo root:
//
//     swift Tools/GenerateTipImage.swift
//
// Same backdrop and corner brackets as the app icon, so it's recognisably the same app, but with
// a heart where the rewind arrow goes: App Review asks that purchase images not simply repeat the
// icon. Opaque, because App Store Connect rejects images with an alpha channel.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

guard let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("couldn't create context") }

// MARK: - Background (matches the icon)

let backdrop = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.13, green: 0.16, blue: 0.21, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// MARK: - Corner brackets (matches the icon)

let yellow = CGColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let inset = 132.0, arm = 196.0
context.setStrokeColor(yellow)
context.setLineWidth(54)
context.setLineCap(.round)
context.setLineJoin(.round)
let left = inset, right = size - inset, bottom = inset, top = size - inset
for corner in [
    [CGPoint(x: left, y: top - arm), CGPoint(x: left, y: top), CGPoint(x: left + arm, y: top)],
    [CGPoint(x: right - arm, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: top - arm)],
    [CGPoint(x: right, y: bottom + arm), CGPoint(x: right, y: bottom), CGPoint(x: right - arm, y: bottom)],
    [CGPoint(x: left + arm, y: bottom), CGPoint(x: left, y: bottom), CGPoint(x: left, y: bottom + arm)],
] {
    context.beginPath()
    context.move(to: corner[0])
    for point in corner.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}

// MARK: - Heart

// A square turned 45° with a circle on each of its two upper edges — the classic construction,
// which gets the lobes exactly tangent to the sides. Sized to sit inside the brackets with the
// same breathing room as the icon's arrow. CoreGraphics' origin is bottom-left.
let side = 290.0
let diag = side / 2.squareRoot()                    // half the diamond's width
let heartHeight = 1.5 * diag + side / 2           // tip to the top of the lobes
let tip = CGPoint(x: size / 2, y: (size - heartHeight) / 2 + 12)

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.beginPath()
context.move(to: tip)
context.addLine(to: CGPoint(x: tip.x + diag, y: tip.y + diag))
context.addLine(to: CGPoint(x: tip.x, y: tip.y + 2 * diag))
context.addLine(to: CGPoint(x: tip.x - diag, y: tip.y + diag))
context.closePath()
context.fillPath()
for dx in [-diag / 2, diag / 2] {
    let centre = CGPoint(x: tip.x + dx, y: tip.y + 1.5 * diag)
    context.fillEllipse(in: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
}

// MARK: - Write

guard let image = context.makeImage() else { fatalError("couldn't render") }
let outputURL = URL(fileURLWithPath: "AppStore/tip-1024.png")
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("couldn't create destination") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write") }
print("wrote \(outputURL.path)")
