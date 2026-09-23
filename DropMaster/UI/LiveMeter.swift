//
//  LiveMeter.swift
//  DropMaster
//
//  What is playing, as it plays: peak per channel, the limiter's gain
//  reduction while Matched is heard, and momentary and short-term loudness.
//
//  Upright bars, as on a console: the column beside the curve is tall and
//  narrow, and a meter that uses the height resolves the top 6 dB - where
//  a master lives - far better than a short horizontal bar could.
//
//  Two clocks: the bars at 30 frames a second, because a peak meter that
//  jumps four times a second hides the peaks it is for; the numbers four
//  times a second, because a number that changes thirty times a second
//  cannot be read.
//
//  Both TimelineViews read the player in their own closure and hand plain
//  values to the views that draw them - a child given only the player
//  would never be redrawn (its input never changes), and the meters would
//  stand still while the music plays.
//

import SwiftUI

struct LiveMeter: View {
    let player: ABPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OUTPUT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            HStack(alignment: .top, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    MeterBars(levels: player.readMeters())
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let levels = player.readMeters()
                    VStack(alignment: .leading, spacing: 12) {
                        LoudnessReadout(value: levels.momentary.map { String(format: "%.1f", $0) }, label: "LUFS M",
                                        help: "Momentary loudness of what is playing: the last 400 ms, K-weighted.")
                        LoudnessReadout(value: levels.shortTerm.map { String(format: "%.1f", $0) }, label: "LUFS S",
                                        help: "Short-term loudness of what is playing: the last 3 seconds, K-weighted.")
                        let peak = max(levels.left, levels.right)
                        LoudnessReadout(value: peak > 1e-5 ? String(format: "%.1f", 20 * log10(Double(peak))) : nil,
                                        label: "dBFS peak", help: "Peak level of what is playing")
                        LoudnessReadout(value: levels.reductionDB < -0.05 ? String(format: "%.1f", levels.reductionDB) : nil,
                                        label: "dB GR", help: "Gain reduction of the limiter at the playhead, while Matched plays")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

/// L, R and GR as upright bars on a dB scale. Plain values only.
///
/// The peak scale is not linear in dB: 0 to -12 dB takes the upper half,
/// -12 to -48 the lower. A master spends its life in the top few dB, and
/// on a linear scale they were an eighth of the bar. Gain reduction has its
/// own scale, 0 to -12 dB from the top, marked on its right.
struct MeterBars: View {
    let levels: LiveLevels

    private static let peakTicks: [Double] = [0, -3, -6, -12, -24, -48]
    private static let reductionTicks: [Double] = [0, -3, -6, -9, -12]
    private static let reductionRangeDB = 12.0
    private static let labelRow = 16.0

    /// 0 at the bottom, 1 at the top.
    nonisolated static func position(_ db: Double) -> Double {
        if db >= -12 { return 0.5 + 0.5 * max(0, 12 + min(db, 0)) / 12 }
        return 0.5 * max(0, db + 48) / 36
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            scale(Self.peakTicks, position: Self.position, alignment: .trailing)
            channel("L", fraction: Self.position(db(levels.left)), color: color(levels.left), fromTop: false)
            channel("R", fraction: Self.position(db(levels.right)), color: color(levels.right), fromTop: false)
            channel("GR", fraction: min(max(-Double(levels.reductionDB) / Self.reductionRangeDB, 0), 1),
                    color: .orange, fromTop: true)
                .padding(.leading, 6)
                .help("Gain reduction of the limiter at the playhead, 0 to −12 dB from the top, while Matched plays")
            scale(Self.reductionTicks, position: { 1 + $0 / Self.reductionRangeDB }, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func db(_ value: Float) -> Double { 20 * log10(max(Double(value), 1e-6)) }

    private func color(_ value: Float) -> Color {
        let level = db(value)
        return level > -1 ? .red : level > -6 ? .yellow : .green
    }

    private func channel(_ name: String, fraction: Double, color: Color, fromTop: Bool) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: fromTop ? .top : .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2).fill(color.gradient)
                        .frame(height: geometry.size.height * fraction)
                }
            }
            .frame(width: 9)
            Text(name).font(.caption2).foregroundStyle(.secondary)
                .frame(height: Self.labelRow)
                .fixedSize()
        }
    }

    /// Tick labels on the same geometry as the bars beside them.
    private func scale(_ ticks: [Double], position: @escaping (Double) -> Double,
                       alignment: Alignment) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ForEach(ticks, id: \.self) { tick in
                    Text(tick == 0 ? "0" : "\(Int(tick))")
                        .font(.system(size: 8))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: geometry.size.width, alignment: alignment)
                        .position(x: geometry.size.width / 2,
                                  y: geometry.size.height * (1 - position(tick)))
                }
            }
            .frame(width: 18)
            Color.clear.frame(height: Self.labelRow)
        }
    }
}

/// One figure with its label, the way a transport bar shows "LUFS S".
struct LoudnessReadout: View {
    let value: String?
    let label: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? "–")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .help(help)
    }
}
