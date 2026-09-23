//
//  DropMasterApp.swift
//  DropMaster
//
//  Reference mastering by drag and drop: a target, a reference, and a
//  matched target that sounds like the reference in loudness, tone and
//  stereo width.
//
//  The idea - match a track's RMS, spectrum and width to a reference, then
//  limit it - is the one Matchering made popular. The implementation is our
//  own and different in its details (block-wise loudness, Gaussian
//  fractional-octave smoothing, a look-ahead limiter); no code or text was
//  taken from Matchering, which is GPL. See README.md.
//
//  One window, one pair of files. The commands below mirror the window's
//  controls, so everything can be done from the keyboard too; Space is the
//  play/pause key because it is in every other audio app.
//

import SwiftUI

@main
struct DropMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DropMaster", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 900, height: 760)
        .commands {
            // One group, not two: a `CommandGroup(after: .newItem)` beside a
            // `CommandGroup(replacing: .newItem)` never appeared in the File
            // menu - the replacement takes the anchor the other one hangs
            // from with it.
            CommandGroup(replacing: .newItem) {
                Button("Choose Target…") { model.choose(.target) }
                    .keyboardShortcut("o")
                Button("Choose Reference…") { model.choose(.reference) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Open Preset…") { model.openPreset() }
                    .keyboardShortcut("p")
                Button("Save Preset…") { model.savePreset() }
                    .keyboardShortcut("s")
                    .disabled(!model.canExport)
                Button("Close Preset") { model.closePreset() }
                    .disabled(model.preset == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export \(model.exportFormat.menuTitle) · \(model.exportQuality.label)…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
            }
            CommandMenu("Preview") {
                Button("Play / Pause") { model.player.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.target.audio == nil)
                Divider()
                Button("Original") { model.player.play(.original) }
                    .keyboardShortcut("1")
                    .disabled(model.target.audio == nil)
                Button("Matched") { model.player.play(.matched) }
                    .keyboardShortcut("2")
                    .disabled(model.result == nil)
                Button("Reference") { model.player.play(.reference) }
                    .keyboardShortcut("3")
                    .disabled(model.target.audio == nil || model.reference.audio == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
