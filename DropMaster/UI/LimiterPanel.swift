//
//  LimiterPanel.swift
//  DropMaster
//
//  The limiter's controls. Everything here re-runs only the limiter stage
//  on the prepared match, so it answers within a fraction of a second and
//  playback carries on.
//
//  Loudness is an offset from the match, not an absolute LUFS target: 0 dB
//  is "as loud as the reference", which is the point of the app, and the
//  offset reads as "a bit hotter than the reference" rather than as a
//  number to look up. The LUFS it produces is shown right beside it -
//  measured, not predicted, because a limiter takes back part of every dB
//  pushed into it (the harness measured +3 dB giving +1.3 LUFS on a loud
//  master).
//
//  Release is a stepped slider over 15 stops from 10 ms to 1 s, spaced
//  about evenly on a log scale: the difference between 20 and 40 ms is as
//  audible as the one between 200 and 400. Stepped, like Loudness and
//  Ceiling, so all three sliders look and behave alike.
//
//  Target is the only level control: an integrated LUFS, or the
//  reference's own. A ±6 dB "Loudness" slider sat beside it until
//  2026-09-20 - two ways to say the same thing, and the slider's dB were
//  not the LUFS they produced anyway.
//
//  Target replaces "as loud as the reference" with an integrated LUFS: a
//  box of streaming platforms, and - / + for any value from -24 to -6 in
//  half-LU steps (a tenth with Option). No text field: it needed parsing
//  and refusing, and showed a
//  blinking cursor among the meters. The box is a pull-down Menu around an
//  inline Picker, not a bare Picker, so it opens below itself. With a target the offset slider disappears - the level is
//  whatever makes the limited result measure the target (Matcher.finish) -
//  and the result line says when a target is out of reach. Pressing − or +
//  while "Reference" is chosen starts from the reference's own loudness
//  and turns the box to "Custom".
//

import SwiftUI
import AppKit

struct LimiterPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("LIMITER")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Toggle("Limiter", isOn: $model.limiter.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Off: no limiting - the result is turned down until its peaks fit under the ceiling")
                if model.refining {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button("Reset") { model.limiter = LimiterSettings() }
                    .controlSize(.small)
                    .disabled(model.limiter == LimiterSettings())
                    .help("Back to the reference's own loudness, automatic ceiling and release, limiter on")
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Target")
                    HStack(spacing: 8) {
                        targetBox
                        Spacer(minLength: 4)
                        TargetStepper(model: model)
                    }
                    .gridCellColumns(3)
                }
                GridRow {
                    Text("")
                    // Three columns, not two: "-6.0 not reachable · max
                    // -7.0 LUFS" is wider than slider and value together,
                    // and pushed the whole panel past its width.
                    Text(resultingLoudness)
                        .font(.caption)
                        .foregroundStyle(targetMissed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .gridCellColumns(3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    Text("Ceiling")
                    Toggle("Auto", isOn: $model.limiter.autoCeiling)
                        .controlSize(.small)
                        .help("Auto: the reference's own peak, never above −0.1 dBFS")
                    Slider(value: $model.limiter.ceilingDB, in: LimiterSettings.ceilingRange, step: 0.1)
                        .controlSize(.small)
                        .disabled(model.limiter.autoCeiling)
                    Text(ceilingText)
                        .frame(width: 76, alignment: .trailing)
                }
                GridRow {
                    Text("Release")
                    Toggle("Auto", isOn: $model.limiter.autoRelease)
                        .controlSize(.small)
                        .help("Auto: 60 ms after a lone peak, up to 600 ms through dense passages")
                        .disabled(!model.limiter.enabled)
                    Slider(value: releasePosition, in: 0...Double(LimiterSettings.releaseSteps.count - 1), step: 1)
                        .controlSize(.small)
                        .disabled(model.limiter.autoRelease || !model.limiter.enabled)
                    Text(model.limiter.autoRelease ? "Auto" : String(format: "%.0f ms", model.limiter.releaseMilliseconds))
                        .frame(width: 76, alignment: .trailing)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private var targetBox: some View {
        Menu {
            Picker("Target", selection: $model.limiter.targetLUFS) {
                Text("Match reference").tag(Double?.none)
                Divider()
                ForEach(LoudnessTarget.platforms) { platform in
                    Text("\(platform.name)  \(String(format: "%.0f", platform.lufs)) LUFS").tag(Double?.some(platform.lufs))
                }
                // A stepped value is listed too, so the checkmark has a row.
                if let value = model.limiter.targetLUFS, LoudnessTarget.title(value) == "Custom" {
                    Text("Custom  \(String(format: "%.1f", value)) LUFS").tag(Double?.some(value))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(LoudnessTarget.title(model.limiter.targetLUFS))
        }
        .controlSize(.small)
        .help("Integrated loudness of the result: the reference track's own, a streaming platform's, or any value set with − / + on the right. Platforms turn louder masters down and ask for a true peak ≤ −1 dBTP - a Ceiling of −1.0 suits them.")
    }

    private var targetMissed: Bool {
        if case .done(let report) = model.match { return !report.targetReached }
        return false
    }

    private var resultingLoudness: String {
        guard case .done(let report) = model.match else { return " " }
        let lufs = model.matchedStats?.integrated.map { String(format: "%.1f LUFS", $0) } ?? "…"
        let reduction = model.limiter.enabled ? String(format: " · GR max %.1f dB", report.limiterReductionDB) : ""
        if let target = report.targetLUFS, !report.targetReached {
            let reached = report.resultLUFS.map { String(format: "%.1f LUFS", $0) } ?? lufs
            return String(format: "%.1f not reachable · max %@", target, reached)
        }
        return "Result \(lufs)\(reduction)"
    }

    private var ceilingText: String {
        if model.limiter.autoCeiling, case .done(let report) = model.match {
            return String(format: "%.1f dBFS", report.ceilingDB)
        }
        return model.limiter.autoCeiling ? "Auto" : String(format: "%.1f dBFS", model.limiter.ceilingDB)
    }

    /// The slider's stop for the stored release: the nearest one, so a
    /// value set before the slider had stops still shows sensibly.
    private var releasePosition: Binding<Double> {
        let steps = LimiterSettings.releaseSteps
        return Binding(
            get: {
                let ms = model.limiter.releaseMilliseconds
                let nearest = steps.indices.min { abs(log(steps[$0] / ms)) < abs(log(steps[$1] / ms)) } ?? 0
                return Double(nearest)
            },
            set: { model.limiter.releaseMilliseconds = steps[min(steps.count - 1, max(0, Int($0.rounded())))] })
    }
}

/// − value +: the target in half-LU steps, a tenth with Option held; the
/// buttons repeat while held. With "Match reference" it shows the
/// reference's own loudness, greyed, and the first step starts from there.
struct TargetStepper: View {
    @Bindable var model: AppModel

    private var shown: Double? { model.limiter.targetLUFS ?? model.stats[.reference]?.integrated }

    var body: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { icon("minus") }
                .disabled(atLimit(.lowerBound))
                .help("0.5 LU quieter (⌥: 0.1)")
                .accessibilityLabel("Target quieter")
            // Fixed width in monospaced digits: the + stays put from -9.5
            // to -10.0.
            Text(shown.map { String(format: "%.1f", $0) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(model.limiter.targetLUFS == nil ? Color.secondary : Color.primary)
                .frame(width: 42, alignment: .trailing)
            Text("LUFS").font(.caption).foregroundStyle(.secondary)
            Button { step(1) } label: { icon("plus") }
                .disabled(atLimit(.upperBound))
                .help("0.5 LU louder (⌥: 0.1)")
                .accessibilityLabel("Target louder")
        }
        .buttonRepeatBehavior(.enabled)
        .controlSize(.small)
        // Its own width, always: squeezed, "LUFS" became "LU…".
        .fixedSize()
    }

    private enum Limit { case lowerBound, upperBound }

    private func atLimit(_ limit: Limit) -> Bool {
        guard let value = model.limiter.targetLUFS else { return shown == nil }
        return limit == .lowerBound
            ? value <= LoudnessTarget.range.lowerBound + 1e-9
            : value >= LoudnessTarget.range.upperBound - 1e-9
    }

    private func step(_ direction: Double) {
        guard let from = shown else { return }
        let fine = NSEvent.modifierFlags.contains(.option)
        let size = fine ? LoudnessTarget.fineStep : LoudnessTarget.step
        model.limiter.targetLUFS = LoudnessTarget.stepped(from: from, by: direction * size)
    }

    /// Minus is a flat glyph: a button sized by it comes out lower than the
    /// plus beside it. Both get the same box.
    private func icon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 10, height: 10)
    }
}
