#!/usr/bin/env swift
//
// Renders the app icon. Run from the repo root:
//
//     swift Tools/GenerateIcon.swift
//
// Kept as code rather than a checked-in binary so the icon can be adjusted, re-rendered, and
// reviewed in a diff like anything else.
//
// Design: the yellow corner brackets are lifted straight from the capture screen's safe-frame
// overlay, so the icon and the app speak the same visual language. The counterclockwise arrow
// inside them is the whole product in one mark — you press the button and it reaches *backwards*
// to grab what already happened.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let center = CGPoint(x: size / 2, y: size / 2)

guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("couldn't create context") }

// MARK: - Background

// A cool near-black rather than pure black: pure black icons look like a hole on a dark home
// screen, and the slight blue keeps it from reading as "broken".
let backdrop = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 0.13, green: 0.16, blue: 0.21, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// MARK: - Corner brackets

let yellow = CGColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let inset = 132.0
let arm = 196.0
let bracketWidth = 54.0

context.setStrokeColor(yellow)
context.setLineWidth(bracketWidth)
context.setLineCap(.round)
context.setLineJoin(.round)

let left = inset, right = size - inset, bottom = inset, top = size - inset
let corners: [[CGPoint]] = [
    [CGPoint(x: left, y: top - arm), CGPoint(x: left, y: top), CGPoint(x: left + arm, y: top)],
    [CGPoint(x: right - arm, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: top - arm)],
    [CGPoint(x: right, y: bottom + arm), CGPoint(x: right, y: bottom), CGPoint(x: right - arm, y: bottom)],
    [CGPoint(x: left + arm, y: bottom), CGPoint(x: left, y: bottom), CGPoint(x: left, y: bottom + arm)],
]
for corner in corners {
    context.beginPath()
    context.move(to: corner[0])
    for point in corner.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}

// MARK: - Rewind arc

let radius = 196.0
let arcWidth = 62.0
let startAngle = -0.30 * Double.pi
// The stroke stops short of where the arrowhead sits, so the head reads as the continuation of
// the arc rather than a triangle stuck onto the end of it.
let endAngle = 1.10 * Double.pi
let headAngle = 1.125 * Double.pi

context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(arcWidth)
context.setLineCap(.round)
context.beginPath()
context.addArc(
    center: center,
    radius: radius,
    startAngle: startAngle,
    endAngle: endAngle,
    clockwise: false
)
context.strokePath()

// Arrowhead at the leading (counterclockwise) end of the arc.
let head = CGPoint(
    x: center.x + radius * cos(headAngle),
    y: center.y + radius * sin(headAngle)
)
// Travelling counterclockwise, the tangent at angle θ is (-sin θ, cos θ).
let tangent = CGPoint(x: -sin(headAngle), y: cos(headAngle))
let radial = CGPoint(x: cos(headAngle), y: sin(headAngle))
let tipLength = 112.0
let halfBase = 76.0

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.beginPath()
context.move(to: CGPoint(
    x: head.x + tangent.x * tipLength,
    y: head.y + tangent.y * tipLength
))
context.addLine(to: CGPoint(
    x: head.x + radial.x * halfBase,
    y: head.y + radial.y * halfBase
))
context.addLine(to: CGPoint(
    x: head.x - radial.x * halfBase,
    y: head.y - radial.y * halfBase
))
context.closePath()
context.fillPath()

// MARK: - Write

guard let image = context.makeImage() else { fatalError("couldn't render") }

let outputDirectory = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let outputURL = outputDirectory.appendingPathComponent("icon-1024.png")

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("couldn't create destination") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write") }

print("wrote \(outputURL.path)")
