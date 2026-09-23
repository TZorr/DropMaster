//
//  CurveView.swift
//  DropMaster
//
//  What the match did to the tone, drawn: the Mid and Side corrections
//  from 20 Hz to 20 kHz on a log axis, ±15 dB.
//
//  Not decoration. A match can only be trusted if its reasons can be seen:
//  a curve that climbs 12 dB above 10 kHz says the reference is much
//  brighter - or that it is a lossy file whose top was never there in the
//  target - and that is worth knowing before exporting the result.
//
//  The curves are passed in as values, not read from the model inside the
//  Canvas: a view that only holds a model reference is not redrawn when the
//  data behind it changes.
//

import SwiftUI

struct CurveView: View {
    let mid: [Double]?
    let side: [Double]?
    let binHz: Double

    private static let lowHz = 20.0
    private static let highHz = 20_000.0
    private static let rangeDB = 15.0

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 30, y: 6, width: size.width - 36, height: size.height - 22)
            func x(_ hz: Double) -> CGFloat {
                plot.minX + plot.width * CGFloat(log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz))
            }
            func y(_ db: Double) -> CGFloat {
                plot.midY - plot.height / 2 * CGFloat(max(-Self.rangeDB, min(Self.rangeDB, db)) / Self.rangeDB)
            }
            let grid = GraphicsContext.Shading.color(.secondary.opacity(0.25))
            let label = Color.secondary

            for db in [-12.0, -6, 0, 6, 12] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(db)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(line, with: db == 0 ? .color(.secondary.opacity(0.5)) : grid, lineWidth: db == 0 ? 1 : 0.5)
                context.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 9)).foregroundStyle(label),
                             at: CGPoint(x: plot.minX - 4, y: y(db)), anchor: .trailing)
            }
            for (hz, name) in [(50.0, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"),
                               (2000, "2k"), (5000, "5k"), (10000, "10k")] {
                var line = Path()
                line.move(to: CGPoint(x: x(hz), y: plot.minY))
                line.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
                context.stroke(line, with: grid, lineWidth: 0.5)
                context.draw(Text(name).font(.system(size: 9)).foregroundStyle(label),
                             at: CGPoint(x: x(hz), y: plot.maxY + 3), anchor: .top)
            }

            func curve(_ values: [Double]) -> Path {
                var path = Path()
                var started = false
                for k in 1..<values.count {
                    let hz = Double(k) * binHz
                    guard hz >= Self.lowHz, hz <= Self.highHz else { continue }
                    let point = CGPoint(x: x(hz), y: y(values[k]))
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                }
                return path
            }
            if let side {
                context.stroke(curve(side), with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            if let mid {
                context.stroke(curve(mid), with: .color(.accentColor), lineWidth: 2)
            }
        }
        .accessibilityLabel("Tone correction curves")
    }
}
