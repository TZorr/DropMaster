//
//  Encoding.swift
//  DropMaster
//
//  What every writer looks like from the exporter's side, and how it fails.
//
//  The protocol that lets one loop feed both CoreAudioEncoder and
//  MP3Encoder, and the error they throw. The pipeline around them is not
//  needed here - DropMaster's exporter (Exporter.swift) reads from memory,
//  not from a decoder.
//

import Foundation
import AVFoundation

nonisolated protocol AudioEncoder {
    /// Append one chunk: Float32, non-interleaved, in the format the encoder
    /// was created with.
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Flush and close. After this the output file is complete on disk.
    func finish() throws
    /// Release resources without any promise about the file. Safe to call
    /// after `finish()`, and called on the error path.
    func cancel()
}

nonisolated enum ConversionError: LocalizedError {
    case bufferAllocationFailed
    case encoderSetupFailed(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:      return "Out of memory."
        case .encoderSetupFailed(let why): return why
        case .encodeFailed(let why):       return why
        }
    }
}
