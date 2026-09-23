//
//  Limiter.swift
//  DropMaster
//
//  The last stage: after level matching, the loud passages of the target
//  sit where the reference's do - and the reference got there with a
//  limiter of its own, so the target's peaks now reach above full scale.
//  This brings them back under a ceiling without clipping a single sample.
//
//  A look-ahead brickwall limiter with the make-up gain taken out: here the
//  level stage has already decided the loudness, and the limiter's only
//  job is the ceiling.
//
//  How it can promise the ceiling: it looks ahead. The audio is delayed by
//  `latency` frames (3 ms); the gain for each delayed sample is decided
//  knowing every sample up to 3 ms later. Per sample, the gain a peak
//  *requires* is ceiling / peak. The limiter takes, for each moment, the
//  smallest requirement in the look-ahead window (a sliding minimum), and
//  then averages that over the same window length. The minimum alone would
//  drop the gain in one step - a click; averaging turns the step into a
//  3 ms ramp. And because every value averaged is a minimum over a window
//  that contains the sample about to leave, the average can never be above
//  what that sample requires. The ceiling holds by construction, not by a
//  clamp that happens to catch whatever got through.
//
//  Release is programme-dependent by default: quick after a lone peak, so
//  a single transient does not dent the bar after it; slow through a dense
//  passage, so a loud chorus does not pump. Which one is decided by how
//  much reduction the last few hundred milliseconds needed. A fixed release
//  can be set instead (the limiter panel's Release slider).
//
//  It also keeps a coarse record of its own work - the deepest gain per
//  1024 output frames - which the live meter reads at the playhead to show
//  gain reduction while the matched version plays.
//

import Foundation

nonisolated final class Limiter {
    /// Look-ahead, and therefore delay, in frames.
    let latency: Int

    private let ceiling: Float
    private let fastRelease: Float
    private let slowRelease: Float
    private let depthFollow: Float
    /// A fixed release coefficient, or nil for the programme-dependent one.
    private let fixedRelease: Float?

    // Delay line, one per channel.
    private var delayLeft: [Float]
    private var delayRight: [Float]
    private var delayIndex = 0

    // Sliding minimum of the required gain: a monotonic queue in a ring.
    private var queueValues: [Float]
    private var queueFrames: [Int]
    private var queueHead = 0
    private var queueCount = 0

    // Running average of the sliding minimum over the same window.
    private var boxValues: [Float]
    private var boxSum: Double
    private var boxIndex = 0

    private var gain: Float = 1
    private var depth: Float = 0
    private var frame = 0
    private var primed = 0

    /// Deepest gain reduction so far, in dB (≤ 0).
    private(set) var maxReductionDB: Double = 0

    /// Frames per entry of `reduction`.
    static let reductionChunk = 1024
    /// The smallest gain (linear, ≤ 1) of every `reductionChunk` output
    /// frames, in output order; the last entry may cover fewer frames.
    private(set) var reduction: [Float] = []
    private var chunkGain: Float = 1
    private var chunkFrames = 0

    /// `releaseSeconds` nil: programme-dependent release.
    // Auto release: 60 ms after a lone peak, up to 600 ms under sustained
    // reduction, reached at about 1 dB of it (depth × 4 = 1). A faster
    // 25 / 120 ms (depth × 1.5) was tried: it made a loudness push actually
    // louder (+3 dB gave +1.6 LUFS instead of +1.3 on dense pink noise; a
    // kick-heavy track no longer got quieter) and was reverted the same
    // day - the result could come out too loud. Slower release keeps the
    // limiter from adding density.
    private static let autoFastSeconds = 0.060
    private static let autoSlowSeconds = 0.600
    private let depthScale: Float = 4

    init(ceiling: Float, releaseSeconds: Double? = nil, sampleRate: Double = StereoAudio.sampleRate) {
        latency = max(1, Int((0.003 * sampleRate).rounded()))
        self.ceiling = ceiling
        func coefficient(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * sampleRate))) }
        fastRelease = coefficient(Self.autoFastSeconds)
        slowRelease = coefficient(Self.autoSlowSeconds)
        depthFollow = coefficient(0.300)
        fixedRelease = releaseSeconds.map { coefficient(max(0.001, $0)) }

        let window = latency + 1
        delayLeft = [Float](repeating: 0, count: latency)
        delayRight = [Float](repeating: 0, count: latency)
        queueValues = [Float](repeating: 1, count: window + 1)
        queueFrames = [Int](repeating: 0, count: window + 1)
        boxValues = [Float](repeating: 1, count: window)
        boxSum = Double(window)
    }

    /// Limits a whole stereo signal in place. The look-ahead delay is taken
    /// back out, so sample `i` of the result is sample `i` of the input.
    func processAll(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) throws {
        // Output runs `latency` frames behind input, so it can be written
        // over the input it has already read.
        var written = 0
        let chunk = 65_536
        var start = 0
        while start < count {
            try Task.checkCancellation()
            let n = min(chunk, count - start)
            written += process(left: left + start, right: right + start, count: n,
                               outLeft: left + written, outRight: right + written)
            start += n
        }
        let silence = [Float](repeating: 0, count: latency)
        var tailLeft = [Float](repeating: 0, count: latency)
        var tailRight = [Float](repeating: 0, count: latency)
        let tail = process(left: silence, right: silence, count: latency, outLeft: &tailLeft, outRight: &tailRight)
        let keep = min(tail, count - written)
        (left + written).update(from: tailLeft, count: keep)
        (right + written).update(from: tailRight, count: keep)
        if chunkFrames > 0 {
            reduction.append(chunkGain)
            chunkFrames = 0
            chunkGain = 1
        }
    }

    /// Processes `count` input frames and writes the frames that come out -
    /// `count` of them once the look-ahead is primed, fewer at the start.
    /// Returns how many were written.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int,
                 outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) -> Int {
        var produced = 0
        let window = latency + 1
        let capacity = queueValues.count
        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            let peak = max(abs(l), abs(r))
            let required: Float = peak > ceiling ? ceiling / peak : 1

            // Sliding minimum over the last `window` requirements.
            while queueCount > 0 {
                let back = (queueHead + queueCount - 1) % capacity
                if queueValues[back] >= required { queueCount -= 1 } else { break }
            }
            let slot = (queueHead + queueCount) % capacity
            queueValues[slot] = required
            queueFrames[slot] = frame
            queueCount += 1
            while queueFrames[queueHead] <= frame - window {
                queueHead = (queueHead + 1) % capacity
                queueCount -= 1
            }
            let minimum = queueValues[queueHead]

            boxSum += Double(minimum) - Double(boxValues[boxIndex])
            boxValues[boxIndex] = minimum
            boxIndex = (boxIndex + 1) % window
            let smoothed = Float(boxSum / Double(window))

            if smoothed < gain {
                gain = smoothed
            } else {
                let release = fixedRelease ?? (fastRelease + (slowRelease - fastRelease) * min(1, depth * depthScale))
                gain += (smoothed - gain) * release
            }
            depth += ((1 - smoothed) - depth) * depthFollow

            let delayedL = delayLeft[delayIndex]
            let delayedR = delayRight[delayIndex]
            delayLeft[delayIndex] = l
            delayRight[delayIndex] = r
            delayIndex = (delayIndex + 1) % latency
            frame += 1
            if primed < latency {
                primed += 1
                continue
            }
            if gain < 1 {
                maxReductionDB = min(maxReductionDB, 20 * log10(Double(gain)))
            }
            chunkGain = min(chunkGain, gain)
            chunkFrames += 1
            if chunkFrames == Self.reductionChunk {
                reduction.append(chunkGain)
                chunkFrames = 0
                chunkGain = 1
            }
            // The clamp only catches float rounding of ceiling / peak × peak;
            // the gain already guarantees the ceiling.
            outLeft[produced] = min(max(delayedL * gain, -ceiling), ceiling)
            outRight[produced] = min(max(delayedR * gain, -ceiling), ceiling)
            produced += 1
        }
        return produced
    }
}
