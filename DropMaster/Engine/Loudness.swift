//
//  Loudness.swift
//  DropMaster
//
//  Loudness in LUFS after ITU-R BS.1770-4 / EBU R128, and loudness range
//  after EBU Tech 3342: the numbers a mastering engineer reads first, and
//  the ones a streaming service turns a record down by.
//
//  DropMaster matches its own measure - RMS of the Mid in the loud blocks -
//  because that is what the EQ and the limiter act on. LUFS is how the
//  result is *judged*, by people and by platforms, so it is shown beside
//  it: if the matched track reads the reference's LUFS, the match did what
//  it promised in the currency that counts.
//
//  K-weighting, the 100 ms hops, the gating and the short-term meter.
//  K-weighting is two biquads per channel - a high shelf for the head, a
//  high-pass for the
//  ear's poor bass - derived from the filters' analog parameters, because
//  the coefficients BS.1770 prints are for 48 kHz only and wrong at 44.1.
//  The harness checks that the derivation gives the printed values back.
//

import Foundation

/// One biquad in Double, transposed direct form II.
nonisolated struct LoudnessBiquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func clear() {
        z1 = 0
        z2 = 0
    }
}

/// The K-weighting filter for a stereo signal.
nonisolated struct KWeighting: Sendable {
    private var shelfL, shelfR, highPassL, highPassR: LoudnessBiquad

    init(sampleRate: Double = StereoAudio.sampleRate) {
        let (shelf, highPass) = Self.coefficients(sampleRate: sampleRate)
        shelfL = shelf; shelfR = shelf
        highPassL = highPass; highPassR = highPass
    }

    static func coefficients(sampleRate: Double) -> (shelf: LoudnessBiquad, highPass: LoudnessBiquad) {
        // Stage 1: a high shelf, +4 dB above about 1.7 kHz.
        let gain = 3.999843853973347, q1 = 0.7071752369554196, f1 = 1681.974450955533
        let k1 = tan(Double.pi * f1 / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let d1 = 1 + k1 / q1 + k1 * k1
        let shelf = LoudnessBiquad(b0: (vh + vb * k1 / q1 + k1 * k1) / d1,
                                   b1: 2 * (k1 * k1 - vh) / d1,
                                   b2: (vh - vb * k1 / q1 + k1 * k1) / d1,
                                   a1: 2 * (k1 * k1 - 1) / d1,
                                   a2: (1 - k1 / q1 + k1 * k1) / d1)
        // Stage 2: the RLB high-pass at about 38 Hz. Its numerator stays
        // 1, -2, 1, as the standard prints it: the -0.691 in the loudness
        // formula is calibrated with exactly that.
        let q2 = 0.5003270373238773, f2 = 38.13547087602444
        let k2 = tan(Double.pi * f2 / sampleRate)
        let d2 = 1 + k2 / q2 + k2 * k2
        let highPass = LoudnessBiquad(b0: 1, b1: -2, b2: 1,
                                      a1: 2 * (k2 * k2 - 1) / d2,
                                      a2: (1 - k2 / q2 + k2 * k2) / d2)
        return (shelf, highPass)
    }

    /// K-weighted power of one stereo frame: both channels squared and
    /// summed, each with the weight 1.0 BS.1770 gives left and right.
    @inline(__always)
    mutating func power(_ left: Double, _ right: Double) -> Double {
        let l = highPassL.process(shelfL.process(left))
        let r = highPassR.process(shelfR.process(right))
        return l * l + r * r
    }

    mutating func clear() {
        shelfL.clear(); shelfR.clear()
        highPassL.clear(); highPassR.clear()
    }
}

nonisolated enum Loudness {
    /// 100 ms at 44.1 kHz.
    static let hopFrames = 4410
    /// Momentary: 400 ms. Short-term: 3 s.
    static let momentaryHops = 4
    static let shortTermHops = 30
    /// The absolute gate, -70 LUFS, as a power.
    static let silentPower = pow(10, (-70 + 0.691) / 10)

    static func lufs(power: Double) -> Double {
        -0.691 + 10 * log10(power)
    }

    /// Mean K-weighted power of every 100 ms of `audio`. A tail shorter than
    /// a hop is left out.
    static func hops(_ audio: StereoAudio) -> [Double] {
        var filter = KWeighting()
        let count = audio.frameCount / hopFrames
        var hops = [Double](repeating: 0, count: count)
        let left = audio.left, right = audio.right
        for hop in 0..<count {
            var sum = 0.0
            let first = hop * hopFrames
            for frame in first..<(first + hopFrames) {
                sum += filter.power(Double(left[frame]), Double(right[frame]))
            }
            hops[hop] = sum / Double(hopFrames)
        }
        return hops
    }

    /// Mean power of every window of `length` hops, stepping one hop.
    static func windows(_ hops: [Double], length: Int) -> [Double] {
        guard hops.count >= length else { return [] }
        var sum = hops[0..<length].reduce(0, +)
        var result = [sum / Double(length)]
        result.reserveCapacity(hops.count - length + 1)
        for i in length..<hops.count {
            sum += hops[i] - hops[i - length]
            result.append(max(0, sum) / Double(length))
        }
        return result
    }

    /// Integrated loudness: 400 ms blocks, the absolute gate at -70 LUFS,
    /// then the relative gate 10 LU under what passed the first.
    static func integrated(_ hops: [Double]) -> Double? {
        let blocks = windows(hops, length: momentaryHops)
        let audible = blocks.filter { $0 > silentPower }
        guard !audible.isEmpty else { return nil }
        let relative = audible.reduce(0, +) / Double(audible.count) * 0.1
        let kept = audible.filter { $0 > relative }
        guard !kept.isEmpty else { return nil }
        return lufs(power: kept.reduce(0, +) / Double(kept.count))
    }

    /// The loudest 3 s of the track.
    static func shortTermMax(_ hops: [Double]) -> Double? {
        guard let loudest = windows(hops, length: shortTermHops).max(), loudest > silentPower else { return nil }
        return lufs(power: loudest)
    }

    /// Loudness range, EBU Tech 3342: the short-term values (3 s, every
    /// 100 ms) above -70 LUFS and above 20 LU under their own mean; the
    /// spread between their 10th and 95th percentile. The percentiles keep
    /// a single loud hit or a long fade from deciding the range.
    static func range(_ hops: [Double]) -> Double? {
        let audible = windows(hops, length: shortTermHops).filter { $0 > silentPower }
        guard !audible.isEmpty else { return nil }
        let relative = audible.reduce(0, +) / Double(audible.count) * 0.01
        let kept = audible.filter { $0 > relative }.map { lufs(power: $0) }.sorted()
        guard kept.count > 1 else { return kept.isEmpty ? nil : 0 }
        func percentile(_ p: Double) -> Double {
            kept[min(kept.count - 1, max(0, Int((p * Double(kept.count - 1)).rounded())))]
        }
        return percentile(0.95) - percentile(0.10)
    }
}

/// The figures of the loudness table, for one piece of audio.
nonisolated struct LoudnessStats: Codable, Sendable, Equatable {
    var integrated: Double?
    var shortTermMax: Double?
    var range: Double?
    var truePeakDB: Double

    static func measure(_ audio: StereoAudio) -> LoudnessStats {
        // True peak is the slow half; run it beside the K-weighting.
        nonisolated(unsafe) var truePeak = -Double.infinity
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            truePeak = TruePeak.measure(audio)
        }
        let hops = Loudness.hops(audio)
        group.wait()
        return LoudnessStats(integrated: Loudness.integrated(hops),
                             shortTermMax: Loudness.shortTermMax(hops),
                             range: Loudness.range(hops),
                             truePeakDB: truePeak)
    }
}

/// Momentary and short-term loudness measured as the output plays. It
/// never allocates after init: it runs on the audio thread.
nonisolated final class LiveLoudness {
    private var filter = KWeighting()
    private let ring = UnsafeMutablePointer<Double>.allocate(capacity: Loudness.shortTermHops)
    private var next = 0
    private var filled = 0
    private var hopSum = 0.0
    private var hopFrames = 0
    /// Mean powers; 0 until the first hop is complete.
    private(set) var shortTermPower = 0.0
    private(set) var momentaryPower = 0.0

    init() {
        ring.initialize(repeating: 0, count: Loudness.shortTermHops)
    }

    deinit {
        ring.deallocate()
    }

    /// Until 3 s have played, the mean is over what has: a meter that
    /// started at a third of the level would read as a fade-in.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        let window = Loudness.shortTermHops
        for i in 0..<count {
            hopSum += filter.power(Double(left[i]), Double(right[i]))
            hopFrames += 1
            guard hopFrames == Loudness.hopFrames else { continue }
            ring[next] = hopSum / Double(hopFrames)
            next = (next + 1) % window
            filled = min(filled + 1, window)
            hopSum = 0
            hopFrames = 0
            var total = 0.0
            for j in 0..<filled { total += ring[j] }
            shortTermPower = total / Double(filled)
            let recent = min(filled, Loudness.momentaryHops)
            var momentary = 0.0
            for j in 1...recent { momentary += ring[(next - j + window) % window] }
            momentaryPower = momentary / Double(recent)
        }
    }

    func reset() {
        filter.clear()
        ring.update(repeating: 0, count: Loudness.shortTermHops)
        next = 0
        filled = 0
        hopSum = 0
        hopFrames = 0
        shortTermPower = 0
        momentaryPower = 0
    }
}
