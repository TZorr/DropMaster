//
//  MatchEQ.swift
//  DropMaster
//
//  The tonal half of matching: a correction curve from two spectra, and a
//  linear-phase filter that applies it.
//
//  The raw curve - reference power over target power, bin by bin - is far
//  too detailed to use. It follows every note and every drum hit that one
//  song has and the other does not, and an EQ that copied it would imprint
//  the reference's melody onto the target as a comb of narrow boosts. What
//  should transfer is the *balance*: more air, less low-mid, a warmer top.
//  So the curve is smoothed with a window whose width grows with frequency
//  (about a sixth of an octave wide), the way hearing groups frequencies:
//  at 100 Hz that is a few hertz, at 10 kHz it is over a kilohertz.
//  Smoothing happens in dB, so a single deep notch in the target averages
//  in as one bin of a big number, not as a boost that dominates its whole
//  neighbourhood.
//
//  Below 20 Hz and above 20 kHz the curve holds its edge value instead of
//  following spectra that are mostly noise and filter slopes there. And the
//  finished curve is clamped to ±15 dB: a reference with content the target
//  simply does not have cannot be matched by gain, only made hissy trying.
//
//  The filter is linear phase - a symmetric FIR - so transients keep their
//  shape and Mid and Side, filtered differently, stay time-aligned with each
//  other. Its delay (half its length) is removed when it is applied, so the
//  matched audio lines up sample for sample with the original and the A/B
//  switch compares the same moment of the song.
//

import Foundation
import Accelerate

nonisolated enum MatchEQ {
    static let firLength = MatchAnalysis.fftSize
    static let clampDB = 15.0
    static let lowEdgeHz = 20.0
    static let highEdgeHz = 20_000.0

    static var binHz: Double { StereoAudio.sampleRate / Double(firLength) }

    /// One spectrum in dB, smoothed: the half of the correction that
    /// belongs to one track. The smoothing is a weighted mean with the same
    /// weights for every spectrum, so smoothing two spectra and subtracting
    /// gives exactly the smoothed difference - which is what lets a
    /// reference be measured once, kept (ReferenceProfile) and matched
    /// against any target later.
    ///
    /// The floor sits far below anything audible, relative to the
    /// spectrum's own maximum, so a digitally silent bin is a large
    /// negative number, not -inf.
    static func smoothedDB(_ spectrum: [Double]) -> [Double] {
        let bins = spectrum.count
        let floor = (spectrum.max() ?? 0) * 1e-12 + 1e-30
        let raw = spectrum.map { 10 * log10($0 + floor) }

        let width = binHz
        let firstBin = Int((lowEdgeHz / width).rounded(.up))
        let lastBin = min(bins - 1, Int((highEdgeHz / width).rounded(.down)))
        var smoothed = [Double](repeating: 0, count: bins)
        for k in firstBin...lastBin {
            let f = Double(k) * width
            // σ of a Gaussian: 1/12 octave (≈ 0.058 f) makes a window about
            // a sixth of an octave wide at half height. Never narrower than
            // one and a half bins, where octaves are narrower than bins.
            let sigmaBins = max(1.5, 0.058 * f / width)
            let reach = Int((3 * sigmaBins).rounded(.up))
            var sum = 0.0, weights = 0.0
            for j in max(1, k - reach)...min(bins - 1, k + reach) {
                let d = Double(j - k) / sigmaBins
                let w = exp(-0.5 * d * d)
                sum += w * raw[j]
                weights += w
            }
            smoothed[k] = sum / weights
        }
        for k in 0..<firstBin { smoothed[k] = smoothed[firstBin] }
        for k in (lastBin + 1)..<bins { smoothed[k] = smoothed[lastBin] }
        return smoothed
    }

    /// Correction in dB per bin (`firLength / 2 + 1` bins), from two
    /// `smoothedDB` spectra, clamped. `offsetDB` is taken off before the
    /// clamp: the broadband level difference is the level stage's job, and
    /// leaving it in would let a quiet target spend the clamp's range on
    /// level instead of tone.
    static func correction(targetDB: [Double], referenceDB: [Double], offsetDB: Double) -> [Double] {
        precondition(referenceDB.count == targetDB.count)
        return zip(referenceDB, targetDB).map { reference, target in
            min(clampDB, max(-clampDB, reference - target - offsetDB))
        }
    }

    /// A `firLength`-tap linear-phase FIR whose response is `curveDB`,
    /// centred at `firLength / 2`.
    ///
    /// Zero-phase design: the curve is a purely real spectrum, its inverse
    /// transform a symmetric impulse around sample 0, which is rotated to
    /// the middle and faded out with a Hann window so the response between
    /// the bins is smooth instead of rippling.
    static func fir(_ curveDB: [Double]) -> [Float] {
        let n = firLength
        precondition(curveDB.count == n / 2 + 1)
        let fft = RealFFT(size: n)
        // `inverse` undoes `forward`, whose output is twice the DFT - so
        // the gains go in doubled.
        var real = (0..<(n / 2)).map { Float(2 * pow(10, curveDB[$0] / 20)) }
        var imag = [Float](repeating: 0, count: n / 2)
        imag[0] = Float(2 * pow(10, curveDB[n / 2] / 20))
        var impulse = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                fft.inverse(real: r.baseAddress!, imag: i.baseAddress!, output: &impulse)
            }
        }
        var window = [Float](repeating: 0, count: n)
        // The periodic Hann: its peak is exactly at n/2, where the rotated
        // impulse has its centre.
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var fir = [Float](repeating: 0, count: n)
        for i in 0..<n {
            fir[i] = impulse[(i + n / 2) % n] * window[i]
        }
        return fir
    }
}

/// Convolves a whole signal with one FIR, by FFT overlap-add, and removes
/// the FIR's delay.
///
/// Direct convolution would be 4096 multiplies per sample - several seconds
/// per channel for a long song. By FFT it is a few hundred.
nonisolated final class FIRConvolver {
    let delay: Int
    private let firLength: Int
    private let block: Int
    private let fft: RealFFT
    private var filterReal: [Float]
    private var filterImag: [Float]

    init(fir: [Float]) {
        firLength = fir.count
        delay = fir.count / 2
        block = fir.count
        // Block + filter - 1 must fit without wrapping round.
        fft = RealFFT(size: 2 * fir.count)
        let half = fft.half
        var padded = fir + [Float](repeating: 0, count: fft.size - fir.count)
        filterReal = [Float](repeating: 0, count: half)
        filterImag = [Float](repeating: 0, count: half)
        filterReal.withUnsafeMutableBufferPointer { r in
            filterImag.withUnsafeMutableBufferPointer { i in
                fft.forward(&padded, real: r.baseAddress!, imag: i.baseAddress!)
            }
        }
        // Two forward transforms multiplied carry 2 × 2 = 4 times the DFT
        // product; `inverse` expects 2 times. Halve the filter once here.
        var half2: Float = 0.5
        vDSP_vsmul(filterReal, 1, &half2, &filterReal, 1, vDSP_Length(half))
        vDSP_vsmul(filterImag, 1, &half2, &filterImag, 1, vDSP_Length(half))
    }

    /// `output[i]` = the filtered signal at `i`, delay removed. `output`
    /// must hold `count` samples and must not alias `input`.
    func apply(_ input: UnsafePointer<Float>, count: Int, output: UnsafeMutablePointer<Float>) throws {
        output.update(repeating: 0, count: count)
        let size = fft.size, half = fft.half
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var result = [Float](repeating: 0, count: size)
        var start = 0
        while start < count {
            if start % (block * 256) == 0 { try Task.checkCancellation() }
            let n = min(block, count - start)
            frame.withUnsafeMutableBufferPointer { f in
                f.baseAddress!.update(from: input + start, count: n)
                (f.baseAddress! + n).update(repeating: 0, count: size - n)
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    fft.forward(frame, real: r.baseAddress!, imag: i.baseAddress!)
                    RealFFT.multiplyPacked(r.baseAddress!, i.baseAddress!, by: filterReal, filterImag, half: half)
                    fft.inverse(real: r.baseAddress!, imag: i.baseAddress!, output: &result)
                }
            }
            // result[j] belongs at start + j in the delayed signal, so at
            // start + j - delay in the aligned one.
            let first = max(0, delay - start)
            let last = min(n + firLength - 1, count + delay - start)
            if first < last {
                let at = start + first - delay
                result.withUnsafeBufferPointer { r in
                    vDSP_vadd(output + at, 1, r.baseAddress! + first, 1, output + at, 1, vDSP_Length(last - first))
                }
            }
            start += block
        }
    }
}
