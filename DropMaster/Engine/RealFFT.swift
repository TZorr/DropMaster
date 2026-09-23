//
//  RealFFT.swift
//  DropMaster
//
//  A real-input FFT on vDSP, in both directions, with the scaling decided
//  once and in one place.
//
//  vDSP's real FFT stores N real samples as N/2 complex numbers and returns
//  a "packed" spectrum: bins 1 ..< N/2 as usual, while DC and Nyquist - both
//  purely real - share slot 0, DC in the real part and Nyquist in the
//  imaginary part. Its forward result is also twice the textbook DFT.
//  Everything here keeps that packed form, because both users of this file
//  either read magnitudes (where a constant factor cancels in a ratio) or
//  multiply two spectra (where slot 0 needs its own two multiplications and
//  nothing else changes). Unpacking into N/2 + 1 bins would only be undone
//  again before the inverse.
//
//  `inverse` is scaled so that inverse(forward(x)) == x. The harness checks
//  that round trip; every other scale factor in DropMaster is derived from
//  it rather than remembered.
//

import Foundation
import Accelerate

nonisolated final class RealFFT {
    let size: Int
    var half: Int { size / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `size` real samples -> packed spectrum in `real` / `imag`
    /// (`half` values each).
    func forward(_ input: UnsafePointer<Float>, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        input.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
            var split = DSPSplitComplex(realp: real, imagp: imag)
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        }
    }

    /// Packed spectrum -> `size` real samples. Overwrites `real` / `imag`.
    func inverse(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>,
                 output: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        output.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(half))
        }
        var scale = 1 / Float(2 * size)
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(size))
    }

    /// `a *= b` for two packed spectra: complex products for bins 1 ..< half,
    /// and slot 0 as two real products, DC with DC and Nyquist with Nyquist.
    static func multiplyPacked(_ aReal: UnsafeMutablePointer<Float>, _ aImag: UnsafeMutablePointer<Float>,
                               by bReal: UnsafePointer<Float>, _ bImag: UnsafePointer<Float>, half: Int) {
        let dc = aReal[0] * bReal[0]
        let nyquist = aImag[0] * bImag[0]
        var a = DSPSplitComplex(realp: aReal, imagp: aImag)
        var b = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: bReal), imagp: UnsafeMutablePointer(mutating: bImag))
        vDSP_zvmul(&a, 1, &b, 1, &a, 1, vDSP_Length(half), 1)
        aReal[0] = dc
        aImag[0] = nyquist
    }
}
