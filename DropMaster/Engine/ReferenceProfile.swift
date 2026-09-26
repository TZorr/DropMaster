//
//  ReferenceProfile.swift
//  DropMaster
//
//  Everything a match takes from its reference, and nothing it takes from
//  the target: the smoothed Mid and Side spectra of the loud blocks, the
//  Mid RMS of those blocks, the sample peak and the loudness figures.
//  Measured once when a reference is loaded, it answers for the audio from
//  then on - Matcher.prepare(target:profile:) is the one path, whether the
//  reference was just decoded or read from a preset file. The audio stays
//  only for listening to it.
//
//  That it can be kept apart from the target at all rests on one property
//  of MatchEQ: the smoothing is a weighted mean with the same weights for
//  every spectrum, so smoothing each spectrum and subtracting is the
//  smoothed difference. A saved profile therefore matches any later target
//  the way its reference would have, unlike the v1 preset, whose curve had
//  the target of the day divided into it.
//
//  In memory the spectra have a value per FFT bin. In a file they are
//  sampled like a preset's curve - 24 points per octave, 20 Hz to 20 kHz -
//  but to 0.01 dB rather than 0.1: these are absolute levels, and the
//  correction is the difference of two of them.
//

import Foundation

nonisolated struct ReferenceProfile: Codable, Sendable, Equatable {
    /// The reference's file name, for the drop zone and the slot's tooltip.
    var name: String
    /// Points per octave of `mid` and `side`, or nil for one value per bin.
    var pointsPerOctave: Double?
    /// MatchEQ.smoothedDB of the loud blocks' power spectra.
    var mid: [Double]
    var side: [Double]
    /// RMS of the Mid over the loud blocks - the level the target meets
    /// before the LUFS search.
    var loudRMS: Double
    /// Sample peak, linear: what the auto ceiling follows.
    var peak: Double
    var stats: LoudnessStats

    /// The spectra per bin, rebuilt from the file's points if need be.
    var midDB: [Double] { pointsPerOctave.map { MatchPreset.rebuild(mid, perOctave: $0) } ?? mid }
    var sideDB: [Double] { pointsPerOctave.map { MatchPreset.rebuild(side, perOctave: $0) } ?? side }

    /// Measures `audio`, already validated as a reference. `stats` are its
    /// loudness figures, measured by the caller, which has them anyway.
    static func measure(_ audio: StereoAudio, name: String, stats: LoudnessStats) -> ReferenceProfile {
        let (mid, side) = MatchAnalysis.midSide(audio)
        let profile = MatchAnalysis.profile(mid, count: mid.count)
        return ReferenceProfile(name: name, pointsPerOctave: nil,
                                mid: MatchEQ.smoothedDB(MatchAnalysis.powerSpectrum(mid, profile: profile)),
                                side: MatchEQ.smoothedDB(MatchAnalysis.powerSpectrum(side, profile: profile)),
                                loudRMS: profile.loudRMS, peak: Double(audio.peak), stats: stats)
    }

    /// The form a file keeps: sampled, unless it already is - a profile
    /// read from a file and saved again is written unchanged, not rounded
    /// twice.
    var stored: ReferenceProfile {
        guard pointsPerOctave == nil else { return self }
        var copy = self
        copy.pointsPerOctave = MatchPreset.pointsPerOctave
        copy.mid = MatchPreset.sample(mid, step: 0.01)
        copy.side = MatchPreset.sample(side, step: 0.01)
        return copy
    }

    /// Whether the spectra have as many values as their resolution needs.
    var isComplete: Bool {
        let expected = pointsPerOctave.map { MatchPreset.frequencies(perOctave: $0).count }
            ?? MatchEQ.firLength / 2 + 1
        return mid.count == expected && side.count == expected
    }
}
