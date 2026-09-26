//
//  DropZone.swift
//  DropMaster
//
//  One slot: a dashed target to drop a file on, or to click for a file
//  dialog. Once filled it shows what was loaded - name, length, and the
//  file's own rate and channel count, because "why does my 96 kHz master
//  sound different" is answered by seeing that it was resampled.
//
//  The whole zone is the drop target and the click target, not a small
//  button inside it: a drop that lands a few pixels off a button is a drop
//  the app silently ignores.
//
//  The reference zone doubles as the preset's seat: with a preset loaded
//  there is no reference file, and what the zone shows is the preset's
//  name, the reference it was made from and that reference's loudness.
//  It shows the active one of the five reference slots, and says which in
//  its title.
//

import SwiftUI

struct DropZone: View {
    let role: SlotRole
    let slot: Slot
    /// Only the reference zone: a preset standing in for a file.
    var preset: MatchPreset? = nil
    /// Only the reference zone: which of the slots it shows, 1-based.
    var slotNumber: Int? = nil
    let onDrop: (URL) -> Void
    let onChoose: () -> Void

    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.2,
                                                 dash: slot.url == nil && preset == nil ? [6, 4] : []))
            content
                .padding(14)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onDrop(url)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role.title) drop zone")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 8) {
            Text(slotNumber.map { "\(role.title.uppercased()) · \($0)" } ?? role.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            if let preset {
                presetContent(preset)
            } else {
                fileContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presetContent(_ preset: MatchPreset) -> some View {
        Group {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(preset.name)
                .font(.headline)
            Text(Self.presetDetails(preset))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private var fileContent: some View {
        switch slot.state {
        case .empty:
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(role.subtitle)
                .font(.headline)
            Text("Drop an audio file here or click to choose")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .decoding:
            ProgressView()
                .controlSize(.small)
            fileName
            Text("Decoding…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready(let audio, let info):
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
            fileName
            Text(Self.details(audio, info))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.orange)
            fileName
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    private var fileName: some View {
        Text(slot.url?.lastPathComponent ?? "")
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// A built-in preset has no reference name to show (see
    /// MatchPreset.load) - it is meant to be judged by ear.
    static func presetDetails(_ preset: MatchPreset) -> String {
        let loudness = preset.reference?.integrated.map { String(format: "%.1f LUFS", $0) } ?? "–"
        let source = preset.referenceName.isEmpty ? "" : "\(preset.referenceName) · "
        return "Preset · \(source)\(loudness)"
    }

    static func details(_ audio: StereoAudio, _ info: SourceInfo) -> String {
        let rate = info.sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f kHz", info.sampleRate / 1000)
            : String(format: "%.1f kHz", info.sampleRate / 1000)
        let channels = switch info.channels {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(info.channels) ch"
        }
        return "\(TimeFormat.string(audio.duration)) · \(rate) · \(channels)"
    }
}

enum TimeFormat {
    static func string(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
