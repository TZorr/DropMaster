//
//  PreviewBar.swift
//  DropMaster
//
//  Original · Pause · Matched · Reference, and where in the song the
//  playhead is. Reference sits last, apart from the target's two versions:
//  it is the other record, heard at the same time in seconds (see
//  ABPlayer).
//
//  The switcher shows what is actually happening, not what was last
//  clicked: when the song plays to its end the player stops itself, and the
//  switcher has to say Pause without anyone clicking it. So its state is
//  derived from the player - `playing ? source : pause` - and re-read
//  thirty times a second inside the TimelineView, together with the
//  position. Reading those inside the timeline's own closure (rather than
//  in a child view handed the player) is what makes them update: a child
//  given only a reference has no changed input and is never redrawn.
//

import SwiftUI

enum PreviewMode: Hashable {
    case original, pause, matched, reference
}

struct PreviewBar: View {
    let player: ABPlayer
    let canMatch: Bool
    let canReference: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let duration = player.duration
            let position = min(player.positionSeconds, duration)
            let mode = Self.mode(playing: player.isPlaying, source: player.source)
            HStack(spacing: 14) {
                Picker("Preview", selection: Binding(get: { mode }, set: { select($0) })) {
                    Text("Original").tag(PreviewMode.original)
                    Image(systemName: "pause.fill").tag(PreviewMode.pause)
                        .accessibilityLabel("Pause")
                    Text("Matched").tag(PreviewMode.matched)
                        .selectionDisabled(!canMatch)
                    Text("Reference").tag(PreviewMode.reference)
                        .selectionDisabled(!canReference)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                .disabled(duration == 0)

                Text(TimeFormat.string(position))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Slider(value: Binding(get: { position }, set: { player.seek(toSeconds: $0) }),
                       in: 0...max(duration, 0.001))
                    .disabled(duration == 0)
                    .accessibilityLabel("Position")
                Text(TimeFormat.string(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
    }

    private static func mode(playing: Bool, source: PreviewSource) -> PreviewMode {
        guard playing else { return .pause }
        switch source {
        case .original: return .original
        case .matched: return .matched
        case .reference: return .reference
        }
    }

    private func select(_ mode: PreviewMode) {
        switch mode {
        case .original: player.play(.original)
        case .matched: player.play(.matched)
        case .reference: player.play(.reference)
        case .pause: player.pause()
        }
    }
}
