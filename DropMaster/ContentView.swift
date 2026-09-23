//
//  ContentView.swift
//  DropMaster
//
//  One window, top to bottom in the order it is used: drop the two files,
//  see what the match did, listen, export.
//

import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ForEach(SlotRole.allCases) { role in
                    DropZone(role: role, slot: model.slot(role),
                             preset: role == .reference ? model.preset : nil,
                             onDrop: { model.load($0, into: role) },
                             onChoose: { model.choose(role) })
                }
            }
            .frame(height: 150)

            // The one part that grows with the window: a taller curve is
            // easier to read; taller drop zones are just emptier.
            HStack(alignment: .top, spacing: 14) {
                matchPanel
                LiveMeter(player: model.player)
                    .frame(width: 200)
                    .padding(.top, 26)
            }
            .frame(minHeight: 170, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 14) {
                LoudnessTable(rows: [
                    .init(name: "Target", present: model.target.audio != nil, stats: model.stats[.target]),
                    .init(name: "Reference", present: model.reference.audio != nil || model.preset != nil,
                          stats: model.referenceStats),
                    .init(name: "Matched", present: model.result != nil, stats: model.matchedStats, emphasised: true),
                ], comparison: model.limiter.targetLUFS ?? model.referenceStats?.integrated)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                LimiterPanel(model: model)
                    .frame(width: 356)
            }
            .fixedSize(horizontal: false, vertical: true)

            PreviewBar(player: model.player, canMatch: model.result != nil, canReference: model.reference.audio != nil)

            Divider()

            HStack(spacing: 10) {
                if let message = model.exportMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                ExportBoxes(model: model)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 700)
    }

    @ViewBuilder
    private var matchPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                switch model.match {
                case .idle:
                    Text(model.canMatch ? "Waiting…"
                         : "Drop a target and a reference - matching starts on its own. A saved preset can stand in for the reference.")
                        .foregroundStyle(.secondary)
                case .running(let stage):
                    ProgressView().controlSize(.small)
                    Text("\(stage.rawValue)…")
                        .foregroundStyle(.secondary)
                case .done(let report):
                    Label("Matched", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    figure("Gain", String(format: "%+.1f dB", report.gainDB))
                    figure("Ceiling", String(format: "%.1f dBFS", report.ceilingDB))
                    figure("Limiter", String(format: "%.1f dB", report.limiterReductionDB))
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                legend
            }
            .font(.callout)
            .frame(height: 20)

            CurveView(mid: report?.midCurveDB, side: report?.sideCurveDB, binHz: MatchEQ.binHz)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        }
    }

    private var report: MatchReport? {
        if case .done(let report) = model.match { return report }
        return nil
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Capsule().fill(Color.accentColor).frame(width: 14, height: 3)
                Text("Mid")
            }
            HStack(spacing: 4) {
                Capsule().fill(Color.secondary).frame(width: 14, height: 2)
                Text("Side")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func figure(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
