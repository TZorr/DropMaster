//
//  MatchPreset.swift
//  DropMaster
//
//  A match, saved: the tone correction of a reference, its loudness, and
//  the limiter settings that went with it - so the same reference can be
//  applied to the next song without loading it again. The user saves
//  these; nothing ships with the app. Ten anonymous presets did for half
//  an hour on 2026-09-20 and came straight back out: a canned reference
//  nobody can place is more irritating than helpful, and picking one's own
//  record is the whole idea. One file per preset,
//  JSON, about 4.8 kB as written - pretty-printed, because a preset one
//  can read and edit in a text editor is worth more than the kilobyte it
//  costs.
//
//  The curve is stored 24 points per octave from 20 Hz to 20 kHz - 240
//  numbers per channel instead of the 2049 bins it is computed on, for a
//  shape that is smoothed to about a sixth of an octave anyway. Storing
//  every bin would be 32 kB of Float64 for the same curve.
//
//  It was 12 points per octave first, chosen on a synthetic curve where
//  that was within 0.07 dB. Real music proved it optimistic: a match with
//  a narrow +7 dB peak at 528 Hz had 1/12 octave flatten its tip by
//  0.85 dB. At 1/24 the same peak
//  costs 0.36 dB, the whole curve 0.045 dB rms, and the file grows from
//  2.8 to about 4.8 kB - which is nothing. The resolution is written into the
//  file, so presets saved at 1/12 still load and rebuild as they were.
//
//  What a preset does *not* carry is the level of the new song. Loudness
//  is measured per track: applying a preset matches the reference's
//  integrated LUFS (kept here), or whatever target the limiter panel is
//  set to. A saved curve says "sound like this", not "be this loud
//  regardless".
//

import Foundation

nonisolated struct MatchPreset: Codable, Sendable, Equatable {
    static let fileExtension = "dmpreset"
    /// What new presets use. Older files carry their own; see `resolution`.
    static let pointsPerOctave = 24.0
    static let lowHz = 20.0
    static let highHz = 20_000.0
    /// Written into every file, read back to refuse a future format.
    static let currentVersion = 1

    var version = MatchPreset.currentVersion
    /// Points per octave of `mid` and `side`. Absent in the first presets,
    /// which were all 12.
    var pointsPerOctave: Double?
    var name: String
    /// The file the reference came from, for the drop zone's subtitle.
    var referenceName: String
    /// Whole seconds: ISO 8601 writes no fraction, so a preset that kept
    /// one would not equal itself after a round trip.
    var created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
    /// Correction in dB at `frequencies`, Mid and Side.
    var mid: [Double]
    var side: [Double]
    /// The ceiling the reference's own peak asked for, so "Auto" means the
    /// same thing as it did when the preset was saved.
    var autoCeilingDB: Double
    /// The reference's loudness figures: its integrated LUFS is what
    /// "Match reference" aims at without the reference, and the rest fills
    /// the loudness table's Reference row.
    var reference: LoudnessStats?
    var limiter: LimiterSettings

    /// This preset's resolution: its own, or the 12 the first ones had.
    var resolution: Double { pointsPerOctave ?? 12 }

    /// The frequencies the points sit on: 20 Hz, then `perOctave` steps per
    /// octave up to 20 kHz.
    static func frequencies(perOctave: Double = pointsPerOctave) -> [Double] {
        let count = Int((log2(highHz / lowHz) * perOctave).rounded()) + 1
        return (0..<count).map { lowHz * pow(2, Double($0) / perOctave) }
    }

    var frequencies: [Double] { Self.frequencies(perOctave: resolution) }

    init(name: String, referenceName: String, report: MatchReport, reference: LoudnessStats?,
         limiter: LimiterSettings, autoCeilingDB: Double) {
        self.name = name
        self.referenceName = referenceName
        pointsPerOctave = Self.pointsPerOctave
        mid = Self.sample(report.midCurveDB)
        side = Self.sample(report.sideCurveDB)
        self.autoCeilingDB = autoCeilingDB
        self.reference = reference
        self.limiter = limiter
    }

    /// The curve at the stored frequencies, rounded to 0.1 dB - finer than
    /// anyone can hear on a broad curve, and it keeps the file readable.
    static func sample(_ curve: [Double], perOctave: Double = pointsPerOctave) -> [Double] {
        frequencies(perOctave: perOctave).map { hz in
            let x = hz / MatchEQ.binHz
            let i = min(curve.count - 2, max(0, Int(x)))
            let fraction = min(1, max(0, x - Double(i)))
            let value = curve[i] * (1 - fraction) + curve[i + 1] * fraction
            return (value * 10).rounded() / 10
        }
    }

    /// Back to one value per FFT bin, straight lines between the points on
    /// a log-frequency axis, edges held - the same shape MatchEQ.correction
    /// produces, which holds its own edges below 20 Hz and above 20 kHz.
    static func rebuild(_ points: [Double], perOctave: Double = pointsPerOctave) -> [Double] {
        let hz = frequencies(perOctave: perOctave)
        precondition(points.count == hz.count)
        let bins = MatchEQ.firLength / 2 + 1
        var curve = [Double](repeating: 0, count: bins)
        var index = 0
        for k in 0..<bins {
            let f = Double(k) * MatchEQ.binHz
            if f <= hz[0] { curve[k] = points[0]; continue }
            if f >= hz[hz.count - 1] { curve[k] = points[points.count - 1]; continue }
            while index < hz.count - 2 && hz[index + 1] < f { index += 1 }
            let u = (log2(f) - log2(hz[index])) / (log2(hz[index + 1]) - log2(hz[index]))
            curve[k] = points[index] * (1 - u) + points[index + 1] * u
        }
        return curve
    }

    var midCurveDB: [Double] { Self.rebuild(mid, perOctave: resolution) }
    var sideCurveDB: [Double] { Self.rebuild(side, perOctave: resolution) }

    // MARK: - Files

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url)
    }

    static func read(from url: URL) throws -> MatchPreset {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let preset = try decoder.decode(MatchPreset.self, from: Data(contentsOf: url))
        guard preset.version <= currentVersion else { throw PresetError.tooNew(url.lastPathComponent) }
        let expected = frequencies(perOctave: preset.resolution).count
        guard preset.mid.count == expected, preset.side.count == expected else {
            throw PresetError.damaged(url.lastPathComponent)
        }
        return preset
    }
}

nonisolated enum PresetError: Error, LocalizedError {
    case tooNew(String)
    case damaged(String)

    var errorDescription: String? {
        switch self {
        case .tooNew(let name): "\(name) was saved by a newer version of DropMaster."
        case .damaged(let name): "\(name) is not a DropMaster preset, or it is damaged."
        }
    }
}
