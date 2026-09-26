//
//  ReferenceSlots.swift
//  DropMaster
//
//  Five small buttons under the reference zone, one per reference slot.
//  The zone above always shows the active one; a click here chooses
//  another, and the match runs again against it.
//
//  Each button is a drop target of its own: a file dropped on 3 goes into
//  slot 3 and makes it active, so five references can be loaded without
//  first clicking through the slots. Right-click chooses a file or empties
//  the slot.
//
//  What a button looks like says what its slot holds - accent for the
//  active one, a light fill for a loaded file or preset, an outline for an
//  empty slot - so the row reads at a glance which numbers are worth
//  pressing. The name is in the tooltip.
//

import SwiftUI

struct ReferenceSlots: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<AppModel.referenceSlotCount, id: \.self) { index in
                SlotButton(number: index + 1,
                           slot: model.references[index],
                           preset: model.presets[index],
                           active: index == model.activeReference,
                           onSelect: { model.selectReference(index) },
                           onDrop: { model.loadReference($0, slot: index) },
                           onChoose: { model.chooseReference(slot: index) },
                           onClear: { model.clearReference(index) })
            }
        }
    }
}

private struct SlotButton: View {
    let number: Int
    let slot: Slot
    let preset: MatchPreset?
    let active: Bool
    let onSelect: () -> Void
    let onDrop: (URL) -> Void
    let onChoose: () -> Void
    let onClear: () -> Void

    @State private var targeted = false

    private var filled: Bool { preset != nil || slot.url != nil }

    private var name: String? {
        preset?.name ?? slot.url?.lastPathComponent
    }

    private var failed: Bool {
        if case .failed = slot.state { return true }
        return false
    }

    private var decoding: Bool {
        if case .decoding = slot.state { return true }
        return false
    }

    var body: some View {
        face
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                onDrop(url)
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button("Choose Reference \(number)…", action: onChoose)
                Button("Clear Slot \(number)", action: onClear)
                    .disabled(!filled)
            }
            .help(tooltip)
            .accessibilityElement()
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(name ?? "Empty")
            .accessibilityAddTraits(traits)
            .accessibilityAction(.default, onSelect)
    }

    private var face: some View {
        Text(String(number))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(foreground)
            .frame(width: 22, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke, lineWidth: targeted ? 1.5 : 1))
            .opacity(decoding ? 0.55 : 1)
    }

    private var accessibilityName: String { "Reference slot \(number)" }

    private var tooltip: String {
        guard let name else { return "Reference \(number): empty - drop a reference here" }
        return "Reference \(number): \(name)"
    }

    private var fill: Color {
        if active { return .accentColor }
        if targeted { return Color.accentColor.opacity(0.12) }
        return filled ? Color.primary.opacity(0.08) : .clear
    }

    /// An outline only where there is no fill to show the button.
    private var stroke: Color {
        if targeted { return .accentColor }
        return filled || active ? .clear : Color.secondary.opacity(0.5)
    }

    private var traits: AccessibilityTraits {
        active ? [.isButton, .isSelected] : .isButton
    }

    private var foreground: Color {
        if active { return .white }
        if failed { return .orange }
        return filled ? .primary : .secondary
    }
}
