//
//  Tools/make_icon.swift
//  DropMaster
//
//  Draws the app icon and writes every size the asset catalog asks for.
//  Code rather than a drawing file, so the icon can be changed by editing
//  numbers and rerunning, without a graphics program.
//
//  The picture: a dark tile with one waveform cut in two by a thin line -
//  dim and uneven on the left (the track as dropped), bright and even on
//  the right (the track matched). Before | after, which is what the app
//  does. It replaced a first design with a drop falling onto two
//  overlapping waveforms; of three drop-free sketches - this one, two
//  frequency curves, bars under a target line - this one was chosen.
//
//  Usage: swift Tools/make_icon.swift
//

import AppKit

let folder = URL(fileURLWithPath: "DropMaster/Assets.xcassets/AppIcon.appiconset")

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // The macOS tile: 824 of 1024 with a margin, corner radius ~185.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.saveGState()
    c.addPath(path); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.13, green: 0.14, blue: 0.20, alpha: 1),
                                       CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    func bars(count: Int, from: Double, to: Double, amplitude: (Double) -> Double, color: CGColor) {
        let mid = 512 * s
        c.setStrokeColor(color)
        c.setLineWidth(26 * s)
        c.setLineCap(.round)
        for i in 0..<count {
            let u = Double(i) / Double(count - 1)
            let t = from + (to - from) * u
            let x = tile.minX + 110 * s + CGFloat(t) * (tile.width - 220 * s)
            let h = CGFloat(amplitude(t)) * 250 * s
            c.move(to: CGPoint(x: x, y: mid - h))
            c.addLine(to: CGPoint(x: x, y: mid + h))
        }
        c.strokePath()
    }
    // Before: uneven, dim.
    bars(count: 11, from: 0, to: 0.46,
         amplitude: { 0.12 + 0.62 * abs(sin($0 * 17.3 + 0.4)) * (0.5 + 0.5 * abs(cos($0 * 6.1))) },
         color: CGColor(red: 0.55, green: 0.58, blue: 0.68, alpha: 0.45))
    // After: full and even, bright.
    bars(count: 11, from: 0.54, to: 1,
         amplitude: { 0.72 + 0.12 * abs(sin($0 * 17.3 + 0.4)) },
         color: CGColor(red: 0.30, green: 0.78, blue: 1.0, alpha: 1))
    // The line between them.
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
    c.setLineWidth(6 * s)
    c.move(to: CGPoint(x: tile.midX, y: tile.minY + 130 * s))
    c.addLine(to: CGPoint(x: tile.midX, y: tile.maxY - 130 * s))
    c.strokePath()
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = draw(CGFloat(points * scale))
        let url = folder.appendingPathComponent("icon_\(points)x\(points)@\(scale)x.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
print("icons written to \(folder.path)")
