//
//  Exporter.swift
//  DropMaster
//
//  The matched result, written in any of eight formats.
//
//  The result lives in memory as Float32, so there is no decoder here: the
//  exporter cuts it into chunks, adds dither where the target quantises to
//  integers, and hands the chunks to one of two writers: CoreAudioEncoder
//  (ExtAudioFile: WAV, AIFF, CAF, AAC, ALAC, FLAC) and MP3Encoder
//  (libmp3lame, compiled into the app).
//
//  Dither is TPDF, one LSB peak each way, for every integer target - 16 and
//  24-bit PCM, ALAC and FLAC. A converter typically adds it only when the
//  source is wider than the target; here the source is always Float32, so
//  it always is. Without it, rounding a master to 16 bits leaves distortion
//  that follows the music down into every fade-out. The generator is
//  deterministic, so the same result exports to the same bytes (it is the
//  one DropMaster's own WAV writer used before this file replaced it).
//  Float and lossy targets get none: they do not quantise on this axis.
//
//  A file that fails half-way is removed, not left behind looking complete.
//

import Foundation
@preconcurrency import AVFoundation

nonisolated enum Exporter {
    static let chunkFrames: AVAudioFrameCount = 32_768

    static func export(_ audio: StereoAudio, format: OutputFormat, quality: QualityOption, to url: URL) throws {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: StereoAudio.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: chunkFrames),
              let channels = buffer.floatChannelData else {
            throw ConversionError.bufferAllocationFailed
        }
        let encoder: AudioEncoder = format.usesLAME
            ? try MP3Encoder(destination: url, quality: quality, sourceFormat: pcm)
            : try CoreAudioEncoder(destination: url, format: format, quality: quality, sourceFormat: pcm)
        var dither = Dither(bits: quality.integerBitDepth)
        do {
            var start = 0
            while start < audio.frameCount {
                try Task.checkCancellation()
                let n = min(Int(chunkFrames), audio.frameCount - start)
                channels[0].update(from: audio.left + start, count: n)
                channels[1].update(from: audio.right + start, count: n)
                dither.apply(channels[0], count: n)
                dither.apply(channels[1], count: n)
                buffer.frameLength = AVAudioFrameCount(n)
                try encoder.write(buffer)
                start += n
            }
            try encoder.finish()
        } catch {
            encoder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Triangular dither of ±1 LSB at `bits`, from a deterministic generator.
/// Does nothing when `bits` is nil.
nonisolated struct Dither {
    private let lsb: Float
    private var state: UInt32 = 0x9E37_79B9

    init(bits: Int?) {
        lsb = bits.map { 1 / Float(1 << ($0 - 1)) } ?? 0
    }

    mutating func apply(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard lsb > 0 else { return }
        for i in 0..<count {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let a = Float(state) / 4_294_967_296
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let b = Float(state) / 4_294_967_296
            samples[i] += (a - b) * lsb
        }
    }
}
