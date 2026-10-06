#!/usr/bin/env swift
// Pad a square app icon into Apple's macOS icon canvas.
// The artwork is scaled to `contentSize` and centered on a transparent canvas,
// so the squircle occupies Apple's recommended ~80.5% of the 1024px canvas.
//
// Usage: pad-icon.swift <input.png> <output.png> [canvasSize] [contentSize]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: pad-icon.swift <in.png> <out.png> [canvas] [content]\n".data(using: .utf8)!)
    exit(1)
}

let inPath = args[1]
let outPath = args[2]
let canvas = args.count > 3 ? (Int(args[3]) ?? 1024) : 1024
let content = args.count > 4 ? (Int(args[4]) ?? 824) : 824

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("error: cannot read \(inPath)\n".data(using: .utf8)!)
    exit(1)
}

guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }
guard let ctx = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("error: cannot create bitmap context\n".data(using: .utf8)!)
    exit(1)
}

// Transparent canvas: leave the buffer zeroed.
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
ctx.interpolationQuality = .high

// Fit the artwork into the content box without distorting it.
let side = CGFloat(content)
let scale = min(side / CGFloat(image.width), side / CGFloat(image.height))
let drawW = CGFloat(image.width) * scale
let drawH = CGFloat(image.height) * scale
let originX = (CGFloat(canvas) - drawW) / 2.0
let originY = (CGFloat(canvas) - drawH) / 2.0

ctx.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    FileHandle.standardError.write("error: cannot write \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("error: cannot finalize \(outPath)\n".data(using: .utf8)!)
    exit(1)
}

print("padded \(inPath) -> \(outPath)  canvas=\(canvas) content=\(content)")
