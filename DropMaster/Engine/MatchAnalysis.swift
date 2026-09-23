//
//  MatchAnalysis.swift
//  DropMaster
//
//  What a track "is", for the purpose of matching it: how loud it is where
//  it is loud, and what its spectrum looks like there.
//
//  "Where it is loud" is the point. A song's quiet intro, its breakdown and
//  its fade-out say nothing about how it was mastered, and they pull an
//  average-over-everything down in proportion to how long they last. Two
//  masters with identical choruses would then measure differently just
//  because one has a longer intro - and matching that difference would make
//  the chorus of the target louder than the chorus of the reference. So the
//  track is cut into blocks of a few seconds, and only the blocks at or
//  above the track's own average power count - for level and for tone.
//
//  Three seconds is long enough that one block holds a bar or two of music
//  (a kick drum does not make its block "loud" on its own) and short enough
//  that a 30-second breakdown is several blocks, not a fraction of one.
//
//  Spectra are averaged as power over Hann-windowed frames with half
//  overlap: the Hann window keeps a loud bass note from leaking into every
//  bin above it, which with a rectangular window would read as "the target
//  lacks treble" and be answered with a treble boost it does not need.
//

import Foundation
import Accelerate

/// Where a signal's loud blocks are, and how loud they are.
nonisolated struct LoudnessProfile: Sendable {
    let blockSize: Int
    /// Mean-square per block, all blocks.
    let blockPower: [Double]
    /// Indices of the blocks at or above the mean block power.
    let loudBlocks: [Int]
    /// RMS over the loud blocks together.
    let loudRMS: Double
}

nonisolated enum MatchAnalysis {
    static let blockSeconds = 3.0
    static let fftSize = 4096

    /// Blocks of `blockSeconds`; a trailing partial block is left out, so
    /// every block weighs the same. A signal shorter than two blocks is one
    /// block.
    static func profile(_ signal: UnsafePointer<Float>, count: Int) -> LoudnessProfile {
        let nominal = Int(blockSeconds * StereoAudio.sampleRate)
        let blockSize = count < 2 * nominal ? count : nominal
        let blocks = max(1, count / max(blockSize, 1))
        var power = [Double](repeating: 0, count: blocks)
        for b in 0..<blocks {
            var meanSquare: Float = 0
            vDSP_measqv(signal + b * blockSize, 1, &meanSquare, vDSP_Length(blockSize))
            power[b] = Double(meanSquare)
        }
        let mean = power.reduce(0, +) / Double(blocks)
        // `>=` so that a perfectly steady signal (every block equal) keeps
        // all its blocks rather than, by rounding, none of them.
        var loud = power.indices.filter { power[$0] >= mean * (1 - 1e-9) }
        if loud.isEmpty { loud = Array(power.indices) }
        let loudPower = loud.reduce(0) { $0 + power[$1] } / Double(loud.count)
        return LoudnessProfile(blockSize: blockSize, blockPower: power, loudBlocks: loud,
                               loudRMS: sqrt(loudPower))
    }

    /// RMS over `profile`'s loud blocks of `signal × gain`, clipped at
    /// ±`clip` first. The clip is what makes the level match honest: a
    /// sample the limiter will pull down to the ceiling should not count at
    /// the height it has before the limiter.
    static func loudRMS(_ signal: UnsafePointer<Float>, profile: LoudnessProfile,
                        gain: Float, clip: Float) -> Double {
        let n = profile.blockSize
        var scratch = [Float](repeating: 0, count: n)
        var total = 0.0
        var g = gain, low = -clip, high = clip
        scratch.withUnsafeMutableBufferPointer { buffer in
            let s = buffer.baseAddress!
            for b in profile.loudBlocks {
                vDSP_vsmul(signal + b * n, 1, &g, s, 1, vDSP_Length(n))
                vDSP_vclip(s, 1, &low, &high, s, 1, vDSP_Length(n))
                var meanSquare: Float = 0
                vDSP_measqv(s, 1, &meanSquare, vDSP_Length(n))
                total += Double(meanSquare)
            }
        }
        return sqrt(total / Double(profile.loudBlocks.count))
    }

    /// Mean power spectrum over the loud blocks: `fftSize / 2 + 1` bins,
    /// DC to Nyquist. Unscaled - only ratios of two of these are meaningful.
    static func powerSpectrum(_ signal: UnsafePointer<Float>, profile: LoudnessProfile) -> [Double] {
        let n = fftSize
        let hop = n / 2
        let fft = RealFFT(size: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitude = [Float](repeating: 0, count: n / 2)
        var sum = [Double](repeating: 0, count: n / 2 + 1)
        var frames = 0

        for b in profile.loudBlocks {
            let blockStart = b * profile.blockSize
            var offset = 0
            while offset + n <= profile.blockSize {
                vDSP_vmul(signal + blockStart + offset, 1, window, 1, &frame, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { r in
                    imag.withUnsafeMutableBufferPointer { i in
                        fft.forward(frame, real: r.baseAddress!, imag: i.baseAddress!)
                        // Slot 0 first, before the squared magnitudes
                        // treat it as one complex number.
                        sum[0] += Double(r[0] * r[0])
                        sum[n / 2] += Double(i[0] * i[0])
                        r[0] = 0; i[0] = 0
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_zvmags(&split, 1, &magnitude, 1, vDSP_Length(n / 2))
                    }
                }
                for k in 1..<(n / 2) { sum[k] += Double(magnitude[k]) }
                frames += 1
                offset += hop
            }
        }
        let scale = 1 / Double(max(frames, 1))
        return sum.map { $0 * scale }
    }

    /// L/R -> Mid/Side as (L+R)/2 and (L-R)/2, so that M+S and M-S give L
    /// and R back without a factor.
    static func midSide(_ audio: StereoAudio) -> (mid: [Float], side: [Float]) {
        let n = audio.frameCount
        var mid = [Float](repeating: 0, count: n)
        var side = [Float](repeating: 0, count: n)
        var half: Float = 0.5
        vDSP_vadd(audio.left, 1, audio.right, 1, &mid, 1, vDSP_Length(n))
        vDSP_vsmul(mid, 1, &half, &mid, 1, vDSP_Length(n))
        vDSP_vsub(audio.right, 1, audio.left, 1, &side, 1, vDSP_Length(n))  // left - right
        vDSP_vsmul(side, 1, &half, &side, 1, vDSP_Length(n))
        return (mid, side)
    }
}
