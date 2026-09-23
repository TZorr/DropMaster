//
//  Matcher.swift
//  DropMaster
//
//  Target + reference in, matched target out. The order of the stages is
//  the design, spelled out here in one function rather than spread over a
//  chain of objects:
//
//  1. Mid/Side. Tone is matched separately for the centre and the sides -
//     what carries stereo width across: a reference whose sides are
//     brighter and louder than the target's gets a Side filter that makes
//     them so, while the Mid vocal is treated on its own terms.
//
//  2. Loudness profile of both (MatchAnalysis): which blocks are loud, and
//     their RMS. The ratio of the two Mid RMS values is the first gain
//     estimate.
//
//  3. Tone (MatchEQ): spectra over the loud blocks, a smoothed correction
//     per Mid and Side with the broadband gain taken out, and a
//     linear-phase FIR for each.
//
//  4. Level. The RMS of the loud blocks brings the target near the
//     reference; the exact level is then whatever makes the *limited*
//     result measure the loudness asked for - the reference's own LUFS, or
//     the limiter panel's target (`finish`).
//
//     The RMS pass is measured again after the EQ (the filters change it),
//     on a copy clipped at the ceiling, three times - what the limiter
//     takes off the peaks is loudness the target will not have. Without
//     that, a dense target comes out quieter than the reference by exactly
//     the amount its peaks were shaved.
//
//     Limit: a reference *clipped* to its loudness cannot be reached
//     without clipping, and DropMaster does not clip - the harness
//     measured about 3 dB short against pink noise clipped by 12 dB.
//     Measuring through the real limiter and pushing harder was tried: it
//     limited 6 dB more and came out quieter still, since the release
//     pumps the level down between the peaks.
//
//  5. Back to L/R, and the limiter, ceiling at the reference's own peak
//     (never above -0.1 dBFS). A reference mastered to -1 dBFS for a
//     streaming service yields a result that leaves the same room.
//
//  Stages 1-4 are `prepare`, stage 5 is `finish`, kept separate on purpose:
//  the limiter panel changes only stage 5, a fraction of a second, and
//  must not wait for the EQ to be worked out again.
//
//  Everything runs on the caller's thread and checks for cancellation
//  between stages, so a new file dropped mid-match can stop the old run.
//
import Foundation
import Accelerate

nonisolated enum MatchStage: String, Sendable {
    case analysing = "Analysing"
    case tone = "Matching tone"
    case level = "Matching loudness"
    case limiting = "Limiting"
}

/// What the match did - for the curve view and the figures beside it.
nonisolated struct MatchReport: Sendable, Equatable {
    /// Correction per bin, DC to Nyquist, `MatchEQ.binHz` apart.
    var midCurveDB: [Double]
    var sideCurveDB: [Double]
    var gainDB: Double
    var ceilingDB: Double
    var limiterReductionDB: Double
    /// With a LUFS target: the target, what the result measured, and
    /// whether that is within 0.1 LU of it.
    var targetLUFS: Double? = nil
    var resultLUFS: Double? = nil
    var targetReached = true
}

nonisolated enum MatchError: Error, LocalizedError {
    case identical
    case tooShort(String)
    case tooLong(String)

    var errorDescription: String? {
        switch self {
        case .identical: "Target and reference are the same audio - there is nothing to match."
        case .tooShort(let role): "The \(role) is too short - it needs at least \(Int(Matcher.minimumSeconds)) seconds."
        case .tooLong(let role): "The \(role) is too long - at most \(Int(Matcher.maximumSeconds / 60)) minutes."
        }
    }
}

nonisolated enum Matcher {
    static let minimumSeconds = 3.0
    static let maximumSeconds = 20.0 * 60
    /// Never closer to full scale than this, whatever the reference does:
    /// converters and codecs downstream reconstruct peaks slightly higher
    /// than the samples.
    static let maximumCeilingDB = -0.1
    static let levelIterations = 3

    /// Throws if `audio` cannot take part in a match, naming it by `role`.
    static func validate(_ audio: StereoAudio, role: String) throws {
        if audio.duration < minimumSeconds { throw MatchError.tooShort(role) }
        if audio.duration > maximumSeconds { throw MatchError.tooLong(role) }
    }

    /// The whole match with default limiter settings: `prepare`, then
    /// `finish`.
    static func match(target: StereoAudio, reference: StereoAudio, allowIdentical: Bool = false,
                      settings: LimiterSettings = LimiterSettings(),
                      progress: (MatchStage) -> Void = { _ in }) throws -> (StereoAudio, MatchReport) {
        let preparation = try prepare(target: target, reference: reference, allowIdentical: allowIdentical,
                                      progress: progress)
        progress(.limiting)
        return try finish(preparation, settings: settings)
    }

    /// Stages 1 to 4: everything up to the limiter. The slow part, done once
    /// per pair of files; its result is kept so the limiter can be run again
    /// with other settings in a fraction of the time.
    static func prepare(target: StereoAudio, reference: StereoAudio, allowIdentical: Bool = false,
                        progress: (MatchStage) -> Void = { _ in }) throws -> MatchPreparation {
        try validate(target, role: "target")
        try validate(reference, role: "reference")
        if !allowIdentical && target.isIdentical(to: reference) { throw MatchError.identical }

        // 1-2. Mid/Side and loudness.
        progress(.analysing)
        let (targetMid, targetSide) = MatchAnalysis.midSide(target)
        var referenceMS: (mid: [Float], side: [Float])? = MatchAnalysis.midSide(reference)
        let targetProfile = MatchAnalysis.profile(targetMid, count: targetMid.count)
        let referenceProfile = MatchAnalysis.profile(referenceMS!.mid, count: referenceMS!.mid.count)
        let referenceRMS = referenceProfile.loudRMS
        let firstGain = referenceRMS / max(targetProfile.loudRMS, 1e-9)
        let ceiling = min(Double(reference.peak), pow(10, maximumCeilingDB / 20))
        try Task.checkCancellation()

        // 3. Tone.
        progress(.tone)
        let spectra: [[Double]] = [
            MatchAnalysis.powerSpectrum(targetMid, profile: targetProfile),
            MatchAnalysis.powerSpectrum(referenceMS!.mid, profile: referenceProfile),
            MatchAnalysis.powerSpectrum(targetSide, profile: targetProfile),
            MatchAnalysis.powerSpectrum(referenceMS!.side, profile: referenceProfile),
        ]
        referenceMS = nil
        let offsetDB = 20 * log10(max(firstGain, 1e-9))
        let midCurve = MatchEQ.correction(target: spectra[0], reference: spectra[1], offsetDB: offsetDB)
        let sideCurve = MatchEQ.correction(target: spectra[2], reference: spectra[3], offsetDB: offsetDB)
        try Task.checkCancellation()

        let count = target.frameCount
        let unlimited = try filtered(mid: targetMid, side: targetSide, midCurveDB: midCurve, sideCurveDB: sideCurve)
        let mid = unlimited.left, side = unlimited.right

        // 4. Level.
        progress(.level)
        let clip = Float(ceiling)
        var gain = referenceRMS / max(MatchAnalysis.loudRMS(mid, profile: targetProfile, gain: 1, clip: .infinity), 1e-9)
        for _ in 0..<levelIterations {
            let measured = MatchAnalysis.loudRMS(mid, profile: targetProfile, gain: Float(gain), clip: clip)
            gain *= referenceRMS / max(measured, 1e-9)
        }
        try Task.checkCancellation()

        // Back to L/R, with the gain applied: the input of the limiter.
        var g = Float(gain)
        var scratch = [Float](repeating: 0, count: count)
        vDSP_vsub(side, 1, mid, 1, &scratch, 1, vDSP_Length(count))        // M - S = R
        vDSP_vadd(mid, 1, side, 1, unlimited.left, 1, vDSP_Length(count))   // M + S = L
        vDSP_vsmul(unlimited.left, 1, &g, unlimited.left, 1, vDSP_Length(count))
        vDSP_vsmul(scratch, 1, &g, unlimited.right, 1, vDSP_Length(count))

        return MatchPreparation(unlimited: unlimited, gainDB: 20 * log10(max(gain, 1e-9)),
                                autoCeilingDB: 20 * log10(max(ceiling, 1e-9)),
                                midCurveDB: midCurve, sideCurveDB: sideCurve,
                                defaultTargetLUFS: Loudness.integrated(Loudness.hops(reference)))
    }

    /// Stages 1-4 with a saved curve instead of a reference: the tone
    /// comes from the preset, the level from the target search in
    /// `finish` (the preset's own LUFS, or the panel's). There is no
    /// reference to measure here, so the gain starts at 0 dB.
    static func prepare(target: StereoAudio, preset: MatchPreset,
                        progress: (MatchStage) -> Void = { _ in }) throws -> MatchPreparation {
        try validate(target, role: "target")
        progress(.analysing)
        let (targetMid, targetSide) = MatchAnalysis.midSide(target)
        try Task.checkCancellation()

        progress(.tone)
        let midCurve = preset.midCurveDB
        let sideCurve = preset.sideCurveDB
        let unlimited = try filtered(mid: targetMid, side: targetSide, midCurveDB: midCurve, sideCurveDB: sideCurve)
        let count = target.frameCount

        // Mid/Side back to L/R, at unity: the level stage is the target
        // search, which measures what comes out of the limiter.
        var scratch = [Float](repeating: 0, count: count)
        vDSP_vsub(unlimited.right, 1, unlimited.left, 1, &scratch, 1, vDSP_Length(count))
        vDSP_vadd(unlimited.left, 1, unlimited.right, 1, unlimited.left, 1, vDSP_Length(count))
        unlimited.right.update(from: scratch, count: count)
        try Task.checkCancellation()

        return MatchPreparation(unlimited: unlimited, gainDB: 0,
                                autoCeilingDB: preset.autoCeilingDB,
                                midCurveDB: midCurve, sideCurveDB: sideCurve,
                                defaultTargetLUFS: preset.reference?.integrated)
    }

    /// Mid and Side through their FIRs, on two cores. The result holds the
    /// filtered Mid in `left` and Side in `right` - callers turn that into
    /// L/R themselves, because each needs a different gain applied first.
    private static func filtered(mid: [Float], side: [Float],
                                 midCurveDB: [Double], sideCurveDB: [Double]) throws -> StereoAudio {
        let count = mid.count
        let output = StereoAudio(frameCount: count)
        nonisolated(unsafe) let jobs: [(fir: [Float], input: [Float], output: UnsafeMutablePointer<Float>)] = [
            (MatchEQ.fir(midCurveDB), mid, output.left),
            (MatchEQ.fir(sideCurveDB), side, output.right),
        ]
        // The lock is only for the unlikely case of both failing together.
        let lock = NSLock()
        nonisolated(unsafe) var failure: Error?
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            do {
                try jobs[i].input.withUnsafeBufferPointer { input in
                    try FIRConvolver(fir: jobs[i].fir).apply(input.baseAddress!, count: count, output: jobs[i].output)
                }
            } catch {
                lock.withLock { failure = error }
            }
        }
        if let failure { throw failure }
        return output
    }

    /// Stage 5: the level, then the limiter - or, with the limiter off, a
    /// plain turn-down until the peaks fit under the ceiling. Never clips
    /// either way.
    ///
    /// The level is the reference's plus the panel's offset, or - with a
    /// LUFS target - whatever gain makes the *limited* result measure the
    /// target. That gain cannot be worked out in advance: below the ceiling
    /// a dB is a dB, above it the limiter takes part of every dB back, and
    /// on dense material it has been measured to lose loudness when pushed
    /// (see Limiter). So it is searched: run the stage, measure, correct by
    /// the slope seen so far, at most `targetRounds` times. When pushing
    /// harder stops making it louder, the target is out of reach; the
    /// loudest round is kept and the report says so.
    static func finish(_ preparation: MatchPreparation, settings: LimiterSettings) throws -> (StereoAudio, MatchReport) {
        guard let target = settings.targetLUFS ?? preparation.defaultTargetLUFS else {
            // Only when the reference measured no loudness at all (silence):
            // the level then stands where the RMS match left it.
            let run = try limitStage(preparation, settings: settings, offsetDB: 0)
            return (run.audio, report(preparation, run, target: nil, measured: nil))
        }

        var offset = min(maximumTargetGainDB, max(minimumTargetGainDB, target - (preparation.unlimitedLUFS ?? target)))
        var best: (run: StageRun, lufs: Double)?
        var previous: (offset: Double, lufs: Double)?
        for _ in 0..<targetRounds {
            let run = try limitStage(preparation, settings: settings, offsetDB: offset)
            let lufs = Loudness.integrated(Loudness.hops(run.audio)) ?? -99
            if best == nil || abs(lufs - target) < abs(best!.lufs - target) { best = (run, lufs) }
            let error = target - lufs
            if abs(error) <= targetTolerance { break }
            var slope = 1.0
            if let previous, abs(offset - previous.offset) > 1e-6 {
                slope = (lufs - previous.lufs) / (offset - previous.offset)
                // More gain, no more loudness: the limiter (or the ceiling,
                // with the limiter off) has the last word.
                if error > 0 && offset > previous.offset && lufs - previous.lufs < 0.02 { break }
            }
            slope = min(1, max(0.2, slope))
            let next = min(maximumTargetGainDB, max(minimumTargetGainDB, offset + error / slope))
            if abs(next - offset) < 1e-4 { break }
            previous = (offset, lufs)
            offset = next
        }
        let found = best!
        return (found.run.audio, report(preparation, found.run, target: target, measured: found.lufs))
    }

    static let targetRounds = 6
    /// Close enough: a tenth of the smallest step anyone reads on a meter.
    static let targetTolerance = 0.05
    static let minimumTargetGainDB = -30.0
    static let maximumTargetGainDB = 12.0

    private struct StageRun {
        let audio: StereoAudio
        let gainDB: Double
        let ceilingDB: Double
        let reductionDB: Double
    }

    /// One run of the level and limiter stage, `offsetDB` above the
    /// reference-matched level.
    private static func limitStage(_ preparation: MatchPreparation, settings: LimiterSettings,
                                   offsetDB: Double) throws -> StageRun {
        let source = preparation.unlimited
        let count = source.frameCount
        let ceilingDB = settings.autoCeiling
            ? preparation.autoCeilingDB
            : min(settings.ceilingDB, maximumCeilingDB)
        let ceiling = Float(pow(10, ceilingDB / 20))
        var gainDB = preparation.gainDB + offsetDB

        let result = StereoAudio(frameCount: count)
        var offset = Float(pow(10, offsetDB / 20))
        vDSP_vsmul(source.left, 1, &offset, result.left, 1, vDSP_Length(count))
        vDSP_vsmul(source.right, 1, &offset, result.right, 1, vDSP_Length(count))
        try Task.checkCancellation()

        var reductionDB = 0.0
        if settings.enabled {
            let limiter = Limiter(ceiling: ceiling,
                                  releaseSeconds: settings.autoRelease ? nil : settings.releaseMilliseconds / 1000)
            try limiter.processAll(left: result.left, right: result.right, count: count)
            result.gainReduction = limiter.reduction
            reductionDB = limiter.maxReductionDB
        } else {
            let peak = result.peak
            if peak > ceiling {
                var down = ceiling / peak
                vDSP_vsmul(result.left, 1, &down, result.left, 1, vDSP_Length(count))
                vDSP_vsmul(result.right, 1, &down, result.right, 1, vDSP_Length(count))
                gainDB += 20 * log10(Double(down))
            }
        }
        return StageRun(audio: result, gainDB: gainDB, ceilingDB: ceilingDB, reductionDB: reductionDB)
    }

    private static func report(_ preparation: MatchPreparation, _ run: StageRun,
                               target: Double?, measured: Double?) -> MatchReport {
        MatchReport(midCurveDB: preparation.midCurveDB, sideCurveDB: preparation.sideCurveDB,
                    gainDB: run.gainDB, ceilingDB: run.ceilingDB, limiterReductionDB: run.reductionDB,
                    targetLUFS: target, resultLUFS: measured,
                    targetReached: target.map { t in measured.map { abs($0 - t) <= 0.1 } ?? false } ?? true)
    }
}

/// Everything the limiter stage needs, kept between runs of it.
nonisolated final class MatchPreparation: @unchecked Sendable {
    /// The matched audio before the limiter: EQ'd, levelled, back in L/R.
    /// Peaks may be well above full scale - it is Float.
    let unlimited: StereoAudio
    let gainDB: Double
    /// The reference's peak, capped at `Matcher.maximumCeilingDB`.
    let autoCeilingDB: Double
    let midCurveDB: [Double]
    let sideCurveDB: [Double]
    /// Integrated loudness of `unlimited`: where a LUFS-target search
    /// starts.
    let unlimitedLUFS: Double?
    /// What "Match reference" aims at: the reference's own integrated
    /// loudness (or, with a preset, the one it carries). The limiter
    /// panel's target overrides it.
    let defaultTargetLUFS: Double?

    init(unlimited: StereoAudio, gainDB: Double, autoCeilingDB: Double, midCurveDB: [Double], sideCurveDB: [Double],
         defaultTargetLUFS: Double? = nil) {
        unlimitedLUFS = Loudness.integrated(Loudness.hops(unlimited))
        self.defaultTargetLUFS = defaultTargetLUFS
        self.unlimited = unlimited
        self.gainDB = gainDB
        self.autoCeilingDB = autoCeilingDB
        self.midCurveDB = midCurveDB
        self.sideCurveDB = sideCurveDB
    }
}

/// The limiter panel. Stored per Mac, as JSON in UserDefaults.
nonisolated struct LimiterSettings: Codable, Sendable, Equatable {
    static let ceilingRange = -3.0...Matcher.maximumCeilingDB
    static let releaseRange = 10.0...1000.0
    /// The release slider's stops: a stepped slider, like Loudness and
    /// Ceiling, at values an engineer would dial in, roughly evenly spaced
    /// on a log scale.
    static let releaseSteps: [Double] = [10, 15, 20, 30, 40, 50, 70, 100, 150, 200, 300, 400, 500, 700, 1000]

    var enabled = true
    var autoCeiling = true
    var ceilingDB = -1.0
    var autoRelease = true
    var releaseMilliseconds = 200.0
    /// An integrated-loudness target in LUFS instead of the reference's
    /// level (see LoudnessTarget); nil matches the reference. Optional, so
    /// settings stored before it existed still decode - as do settings
    /// with the `targetName` key it once had (unknown keys are ignored).
    var targetLUFS: Double?
}
