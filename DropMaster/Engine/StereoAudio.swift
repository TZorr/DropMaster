//
//  StereoAudio.swift
//  DropMaster
//
//  The one shape audio has inside DropMaster: two channels of Float32 at
//  44.1 kHz, held in memory, left and right in separate buffers.
//
//  Separate buffers rather than interleaved frames because every stage works
//  per channel - Mid/Side is a sum and a difference of two whole channels,
//  the EQ convolves each on its own, the player hands AVAudioEngine one
//  buffer per channel. Interleaving would mean a stride on every one of
//  those, and a copy wherever vDSP wants a contiguous run.
//
//  One fixed rate, because the matching compares spectra bin for bin. A
//  target at 48 kHz and a reference at 44.1 kHz would put the same bin at
//  different frequencies; converting both on the way in is simpler than
//  carrying two frequency axes through the analysis.
//

import Foundation
import Accelerate

/// Stereo Float32 audio at `StereoAudio.sampleRate`.
///
/// A class, because it owns its buffers and must free them exactly once, and
/// because the audio thread holds it by an unmanaged pointer. It is written
/// only by whoever creates it and never after it is shared, which is what
/// makes the `@unchecked Sendable` true.
nonisolated final class StereoAudio: @unchecked Sendable {
    static let sampleRate = 44_100.0

    let frameCount: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    var duration: Double { Double(frameCount) / Self.sampleRate }

    /// For a limited result: the limiter's smallest gain in every
    /// `Limiter.reductionChunk` frames (see Limiter), for the live meter.
    /// Empty for anything else. Set by the creator, like the samples.
    var gainReduction: [Float] = []

    /// Zeroed buffers of `frameCount` frames, for the creator to fill.
    init(frameCount: Int) {
        self.frameCount = frameCount
        // One spare frame, so a zero-length buffer is still a valid pointer.
        left = .allocate(capacity: max(frameCount, 1))
        right = .allocate(capacity: max(frameCount, 1))
        left.initialize(repeating: 0, count: max(frameCount, 1))
        right.initialize(repeating: 0, count: max(frameCount, 1))
    }

    convenience init(left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        self.init(frameCount: left.count)
        left.withUnsafeBufferPointer { self.left.update(from: $0.baseAddress!, count: $0.count) }
        right.withUnsafeBufferPointer { self.right.update(from: $0.baseAddress!, count: $0.count) }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// The largest absolute sample on either channel.
    var peak: Float {
        var l: Float = 0, r: Float = 0
        vDSP_maxmgv(left, 1, &l, vDSP_Length(frameCount))
        vDSP_maxmgv(right, 1, &r, vDSP_Length(frameCount))
        return max(l, r)
    }

    /// Sample-for-sample equality - what "the target is the reference" means.
    func isIdentical(to other: StereoAudio) -> Bool {
        frameCount == other.frameCount
            && memcmp(left, other.left, frameCount * MemoryLayout<Float>.size) == 0
            && memcmp(right, other.right, frameCount * MemoryLayout<Float>.size) == 0
    }
}
