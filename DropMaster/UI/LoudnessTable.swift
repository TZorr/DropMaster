//
//  LoudnessTable.swift
//  DropMaster
//
//  Target, reference and result side by side, in the figures a mastering
//  engineer - or a streaming service - reads: integrated loudness, the
//  loudest 3 seconds, loudness range, and true peak.
//
//  The matched row carries its distance to the reference - or to the LUFS
//  target, when one is set - because that is the question the table
//  answers: did the match get there? A dash means
//  there is nothing to measure yet; an ellipsis that it is being measured.
//

import SwiftUI

struct LoudnessTable: View {
    struct Row {
        var name: String
        var present: Bool
        var stats: LoudnessStats?
        var emphasised = false
    }

    let rows: [Row]
    /// What the matched row is compared with: the LUFS target, or the
    /// reference's integrated loudness when matching the reference.
    let comparison: Double?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("")
                header("Integrated", "Integrated loudness of the whole track (EBU R128, gated)")
                header("Short-term max", "The loudest 3 seconds")
                header("Range", "Loudness range, LRA (EBU Tech 3342)")
                header("True peak", "Highest peak between the samples, 4× oversampled (dBTP)")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                GridRow {
                    Text(row.name)
                        .fontWeight(row.emphasised ? .semibold : .regular)
                        .foregroundStyle(row.emphasised ? Color.accentColor : Color.primary)
                    integrated(row)
                    value(row, row.stats?.shortTermMax, "LUFS")
                    value(row, row.stats?.range, "LU")
                    truePeak(row)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func header(_ title: String, _ help: String) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(help)
    }

    private func placeholder(_ row: Row) -> Text {
        Text(row.present ? "…" : "–").foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func value(_ row: Row, _ number: Double?, _ unit: String) -> some View {
        if row.stats != nil, let number {
            Text(String(format: "%.1f ", number)) + Text(unit).foregroundStyle(.secondary)
        } else if row.stats != nil {
            Text("–").foregroundStyle(.secondary)
        } else {
            placeholder(row)
        }
    }

    @ViewBuilder
    private func integrated(_ row: Row) -> some View {
        if row.emphasised, let own = row.stats?.integrated, let target = comparison {
            Text(String(format: "%.1f ", own)) + Text("LUFS").foregroundStyle(.secondary)
                + Text(Self.difference(own - target)).foregroundStyle(.secondary)
        } else {
            value(row, row.stats?.integrated, "LUFS")
        }
    }

    @ViewBuilder
    private func truePeak(_ row: Row) -> some View {
        if let stats = row.stats {
            // Above 0 dBTP a converter or a lossy encoder will clip.
            let over = stats.truePeakDB > 0
            (Text(stats.truePeakDB.isFinite ? String(format: "%.1f ", stats.truePeakDB) : "−∞ ")
                + Text("dBTP").foregroundStyle(.secondary))
                .foregroundStyle(over ? Color.orange : Color.primary)
                .help(over ? "Above 0 dBTP: expect clipping in lossy encoding or a D/A converter. Lower the ceiling." : "")
        } else {
            placeholder(row)
        }
    }

    /// "(+0.3)", and "(±0.0)" rather than a "(-0.0)" left by rounding.
    static func difference(_ value: Double) -> String {
        abs(value) < 0.05 ? "  (±0.0)" : String(format: "  (%+.1f)", value)
    }
}
