//
//  QualityOption.swift
//  DropMaster
//
//  One entry in the Quality popup.
//
//  A single type covers two unrelated kinds of "quality" because the popup
//  they share is one control: for PCM and the lossless codecs the axis is bit
//  depth, for the lossy codecs it is bitrate, and MP3 adds a variable-bitrate
//  mode that is neither. Rather than three parallel enums and a switch in the
//  view, the difference is pushed into `Kind` and the view just renders
//  `label`.
//
//  The factory methods (`.bitDepth`, `.cbr`, `.mp3CBR`, `.mp3VBR`) exist so
//  `OutputFormat.qualityOptions` reads as a table. `label` is derived once
//  here so the popup and the file list's "Status / Bitrate" column cannot
//  drift apart.
//

import Foundation

nonisolated struct QualityOption: Identifiable, Hashable, Sendable {

    enum Kind: Hashable, Sendable {
        /// Linear PCM / ALAC / FLAC target sample format.
        case bitDepth(bits: Int, isFloat: Bool)
        /// Constant bitrate in kbit/s — AAC, or MP3 in CBR mode.
        case constantBitrate(kbps: Int)
        /// LAME variable-bitrate quality level: 0 is largest/best, 9 smallest.
        case variableBitrate(v: Int)
    }

    let kind: Kind
    let label: String
    let isDefault: Bool

    var id: String { label }

    // MARK: Builders

    static func bitDepth(_ bits: Int, isFloat: Bool, isDefault: Bool = false) -> QualityOption {
        QualityOption(
            kind: .bitDepth(bits: bits, isFloat: isFloat),
            label: isFloat ? "\(bits)-bit float" : "\(bits)-bit",
            isDefault: isDefault
        )
    }

    static func cbr(_ kbps: Int, isDefault: Bool = false) -> QualityOption {
        QualityOption(kind: .constantBitrate(kbps: kbps), label: "\(kbps) kbps", isDefault: isDefault)
    }

    static func mp3CBR(_ kbps: Int, isDefault: Bool = false) -> QualityOption {
        QualityOption(kind: .constantBitrate(kbps: kbps), label: "\(kbps) kbps CBR", isDefault: isDefault)
    }

    static func mp3VBR(_ v: Int, label: String, isDefault: Bool = false) -> QualityOption {
        QualityOption(kind: .variableBitrate(v: v), label: label, isDefault: isDefault)
    }

    // MARK: Queries the encoders ask

    /// Target integer bit depth, or nil for float / lossy targets. Drives the
    /// dither decision in `PCMProcessing`.
    var integerBitDepth: Int? {
        if case .bitDepth(let bits, let isFloat) = kind, !isFloat { return bits }
        return nil
    }

    var isFloatPCM: Bool {
        if case .bitDepth(_, let isFloat) = kind { return isFloat }
        return false
    }

    var pcmBits: Int? {
        if case .bitDepth(let bits, _) = kind { return bits }
        return nil
    }

    var bitrateKbps: Int? {
        if case .constantBitrate(let kbps) = kind { return kbps }
        return nil
    }

    var vbrLevel: Int? {
        if case .variableBitrate(let v) = kind { return v }
        return nil
    }
}
