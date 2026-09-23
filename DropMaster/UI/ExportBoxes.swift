//
//  ExportBoxes.swift
//  DropMaster
//
//  The export, as two boxes at the bottom right: format and quality, the
//  same eight formats an earlier converter offered, in the shape of a
//  transition split button.
//
//  The format box is a split button: its face does the thing ("Export
//  WAV / PCM"), its arrow picks another format. The thing done most often
//  is one click, and changing the format does not also export by surprise.
//
//  The quality box is a pull-down Menu around an inline Picker. Not a bare
//  Picker: that is an NSPopUpButton, which
//  opens with the selected item laid over the button - with the last of
//  five MP3 qualities selected, the list unfolded upwards, off the bottom
//  of the window's content. A pull-down always opens below; the inline
//  Picker keeps the checkmark.
//

import SwiftUI

struct ExportBoxes: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.menuTitle).tag(format)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Export \(model.exportFormat.menuTitle)", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.export()
            }
            .fixedSize()
            .help(formatHelp)

            Menu {
                Picker("Quality", selection: $model.exportQuality) {
                    ForEach(model.exportFormat.qualityOptions) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(model.exportQuality.label)
            }
            .fixedSize()
            .help("Quality of the export: bit depth for PCM and lossless formats, bitrate for AAC and MP3")
        }
        .disabled(!model.canExport)
    }

    private var formatHelp: String {
        let lossy = [OutputFormat.m4aAAC, .aacADTS, .mp3].contains(model.exportFormat)
        return "Export the matched track as \(model.exportFormat.menuTitle), 44.1 kHz stereo (⌘E); the arrow picks another format"
            + (lossy ? ". Lossy codecs rebuild peaks higher than the samples: a Ceiling of −1.0 dBFS in the limiter panel leaves them room." : "")
    }
}
