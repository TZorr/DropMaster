//
//  OutputFormat.swift
//  DropMaster
//
//  The eight rows of the Format popup, and everything the engine needs to
//  know once one is chosen.
//
//  The list is deliberately "container / codec" pairs rather than bare codec
//  names, because the same codec in two containers is two different files to
//  the person converting: "M4A / AAC" and "AAC / ADTS" are both AAC, but one
//  is a QuickTime file you drop into a video project and the other is a raw
//  stream a hardware player expects. Collapsing them would hide the choice
//  that matters.
//
//  There is exactly one branch in here that the rest of the app cares about:
//  `usesLAME`. MP3 is the only format Core Audio cannot write, so it is the
//  only one that takes the libmp3lame path; the other seven all go through
//  one ExtAudioFile writer. Everything else on this type is presentation.
//
//  The eight formats a matched track can export to, so DropMaster exports
//  exactly what it converts to.
//

import Foundation
import AudioToolbox

nonisolated enum OutputFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case wav
    case aiff
    case caf
    case m4aAAC
    case m4aALAC
    case aacADTS
    case flac
    case mp3

    var id: String { rawValue }

    /// Label as it appears in the popup. Matches the mock's wording.
    var menuTitle: String {
        switch self {
        case .wav:     return "WAV / PCM"
        case .aiff:    return "AIFF / PCM"
        case .caf:     return "CAF"
        case .m4aAAC:  return "M4A / AAC"
        case .m4aALAC: return "M4A / ALAC"
        case .aacADTS: return "AAC / ADTS"
        case .flac:    return "FLAC"
        case .mp3:     return "MP3"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav:              return "wav"
        case .aiff:             return "aiff"
        case .caf:              return "caf"
        case .m4aAAC, .m4aALAC: return "m4a"
        case .aacADTS:          return "aac"
        case .flac:             return "flac"
        case .mp3:              return "mp3"
        }
    }

    /// The fork the pipeline switches on. True only for MP3 — see the file
    /// header. Kept as a computed property rather than a stored flag so a new
    /// case cannot be added without the compiler asking which side it is on.
    var usesLAME: Bool { self == .mp3 }

    /// How the ExtAudioFile writer should shape its output. Undefined for
    /// `.mp3`, which never reaches that writer.
    enum Container {
        case pcm(AudioFileTypeID)          // linear PCM in some wrapper
        case appleLossless                  // ALAC in an M4A
        case flac                           // FLAC in its own container
        case aac(AudioFileTypeID)          // AAC in M4A or raw ADTS
    }

    var container: Container {
        switch self {
        case .wav:     return .pcm(kAudioFileWAVEType)
        case .aiff:    return .pcm(kAudioFileAIFFType)   // AIFC is substituted for float, see CoreAudioEncoder
        case .caf:     return .pcm(kAudioFileCAFType)
        case .m4aAAC:  return .aac(kAudioFileM4AType)
        case .m4aALAC: return .appleLossless
        case .aacADTS: return .aac(kAudioFileAAC_ADTSType)
        case .flac:    return .flac
        case .mp3:     return .aac(kAudioFileM4AType)     // unreachable; keeps the switch total
        }
    }

    // MARK: Quality menu

    /// The Quality popup is rebuilt from this whenever the format changes.
    /// Lossy formats list bitrates; PCM and the lossless formats list bit
    /// depths. The first entry flagged `isDefault` is the one selected on
    /// switch — for MP3 that is "320 kbps CBR", matching the mock.
    var qualityOptions: [QualityOption] {
        switch self {
        case .wav, .aiff, .caf:
            return [
                .bitDepth(16, isFloat: false),
                .bitDepth(24, isFloat: false, isDefault: true),
                .bitDepth(32, isFloat: true),
            ]
        case .m4aALAC, .flac:
            return [
                .bitDepth(16, isFloat: false, isDefault: true),
                .bitDepth(24, isFloat: false),
            ]
        case .m4aAAC, .aacADTS:
            return [
                .cbr(256, isDefault: true),
                .cbr(192),
                .cbr(128),
            ]
        case .mp3:
            return [
                .mp3CBR(320, isDefault: true),
                .mp3CBR(256),
                .mp3CBR(192),
                .mp3VBR(0, label: "VBR V0"),
                .mp3VBR(2, label: "VBR V2"),
            ]
        }
    }

    var defaultQuality: QualityOption {
        qualityOptions.first(where: \.isDefault) ?? qualityOptions[0]
    }
}
