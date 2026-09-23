//
//  TruePeak.swift
//  DropMaster
//
//  The peak of the waveform between the samples, in dBTP.
//
//  A sample peak says how high the samples go. A DAC - or an MP3 or AAC
//  decoder - reconstructs the continuous wave through them, and that wave
//  can overshoot: a sine at a quarter of the sample rate, sampled 45° off
//  its crest, has samples at -3 dBFS and a wave that reaches 0. A limited
//  master is full of such places, so its true peak can sit a dB or more
//  above its ceiling. The table shows it because that is where encoders
//  start to clip.
//
//  Measured as BS.1770 describes it: oversample four times, take the
//  largest magnitude. The interpolation filter is our own windowed sinc,
//  48 taps (12 per phase), not the standard's table - close enough to read
//  to a tenth of a dB, which the harness checks on the quarter-rate sine.
//
//  Each phase is a correlation of the signal with 12 taps, done with
//  `vDSP_conv` over large chunks: 36 multiply-adds per sample in vector
//  code, a fraction of a second for a long song.
//

import Foundation
import Accelerate

nonisolated enum TruePeak {
    static let factor = 4
    static let tapsPerPhase = 12

    /// The four interpolating phases, each scaled to unity gain at DC. The
    /// samples themselves are checked separately.
    static let phases: [[Float]] = {
        let length = factor * tapsPerPhase
        let centre = Double(length - 1) / 2
        let prototype = (0..<length).map { n -> Double in
            let t = (Double(n) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            // Blackman window: the sidelobes of a short sinc are what
            // would make the peak wrong, not its passband.
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4 * Double.pi * Double(n) / Double(length - 1))
            return sinc * w
        }
        // With a centre of 23.5 the four phases fall a quarter of a sample
        // apart at 1/8, 3/8, 5/8 and 7/8 - none on a sample - so all four
        // are interpolating.
        return (0..<factor).map { p in
            let taps = (0..<tapsPerPhase).map { prototype[p + factor * $0] }
            let sum = taps.reduce(0, +)
            return taps.map { Float($0 / sum) }
        }
    }()

    /// The true peak of `audio` in dBTP (-infinity for digital silence).
    static func measure(_ audio: StereoAudio) -> Double {
        var peak: Float = 0
        for channel in [audio.left, audio.right] {
            peak = max(peak, channelPeak(channel, count: audio.frameCount))
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    private static func channelPeak(_ x: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(count))
        let taps = tapsPerPhase
        guard count > taps else { return peak }
        let chunk = 1 << 18
        var output = [Float](repeating: 0, count: chunk)
        var start = 0
        while start + taps <= count {
            let n = min(chunk, count - start - taps + 1)
            for phase in phases {
                phase.withUnsafeBufferPointer { f in
                    vDSP_conv(x + start, 1, f.baseAddress!, 1, &output, 1, vDSP_Length(n), vDSP_Length(taps))
                }
                var m: Float = 0
                vDSP_maxmgv(output, 1, &m, vDSP_Length(n))
                peak = max(peak, m)
            }
            start += n
        }
        return peak
    }
}
