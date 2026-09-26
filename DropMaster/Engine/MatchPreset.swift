//
//  MatchPreset.swift
//  DropMaster
//
//  Two kinds of file share the extension `.dmpreset`, told apart by their
//  `version`:
//
//  - Version 1, `MatchPreset`: one match, saved - the tone correction of a
//    reference against the target of the day, its loudness, and the
//    limiter settings. Written until 2026-09-26; still opened, into the
//    active slot, and kept inside sets as it is.
//  - Version 2, `PresetSet`: all five reference slots, each as a
//    ReferenceProfile (see there) - what the reference *is*, not what it
//    did to one target - plus the active slot and the limiter settings. It
//    needs no target to be saved, and matches the next target the way the
//    references themselves would.
//
//  The user saves these; nothing ships with the app. Ten anonymous presets
//  did for half an hour on 2026-09-20 and came straight back out: a canned
//  reference nobody can place is more irritating than helpful, and picking
//  one's own record is the whole idea. JSON, pretty-printed, because a
//  preset one can read and edit in a text editor is worth more than the
//  kilobytes it costs.
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
    /// The version of a single-curve file. Sets are PresetSet.version.
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
    /// A ReferenceProfile's spectra use 0.01 (see there).
    static func sample(_ curve: [Double], perOctave: Double = pointsPerOctave, step: Double = 0.1) -> [Double] {
        // × 10 then ÷ 10, not ÷ 0.1 then × 0.1: the latter writes
        // 0.30000000000000004 into the file.
        let scale = (1 / step).rounded()
        return frequencies(perOctave: perOctave).map { hz in
            let x = hz / MatchEQ.binHz
            let i = min(curve.count - 2, max(0, Int(x)))
            let fraction = min(1, max(0, x - Double(i)))
            let value = curve[i] * (1 - fraction) + curve[i + 1] * fraction
            return (value * scale).rounded() / scale
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
        guard case .curve(let preset) = try PresetFile.read(from: url) else {
            throw PresetError.damaged(url.lastPathComponent)
        }
        return preset
    }

    /// Whether the curves have as many points as their resolution needs.
    var isComplete: Bool {
        let expected = Self.frequencies(perOctave: resolution).count
        return mid.count == expected && side.count == expected
    }
}

/// One slot of a set: a measured reference, or a version-1 curve that was
/// open in that slot. Never both.
nonisolated struct PresetSlot: Codable, Sendable, Equatable {
    var profile: ReferenceProfile?
    var curve: MatchPreset?

    var name: String { profile?.name ?? curve?.name ?? "" }
}

/// All five reference slots, saved: version 2 of the file.
nonisolated struct PresetSet: Codable, Sendable, Equatable {
    static let currentVersion = 2

    var version = PresetSet.currentVersion
    var name: String
    /// Whole seconds, as in MatchPreset.
    var created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
    /// 0-based; the slot the set was saved with active.
    var activeSlot: Int
    var limiter: LimiterSettings
    /// One entry per slot, null where the slot was empty.
    var slots: [PresetSlot?]

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url)
    }
}

/// What a `.dmpreset` turned out to hold.
nonisolated enum PresetFile: Sendable, Equatable {
    case curve(MatchPreset)
    case set(PresetSet)

    private struct Header: Decodable { var version: Int? }

    static func read(from url: URL) throws -> PresetFile {
        let name = url.lastPathComponent
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { throw PresetError.damaged(name) }
        let version = header.version ?? 1
        guard version <= PresetSet.currentVersion else { throw PresetError.tooNew(name) }
        do {
            if version <= MatchPreset.currentVersion {
                let preset = try decoder.decode(MatchPreset.self, from: data)
                guard preset.isComplete else { throw PresetError.damaged(name) }
                return .curve(preset)
            }
            let set = try decoder.decode(PresetSet.self, from: data)
            let entries = set.slots.compactMap { $0 }
            guard !entries.isEmpty,
                  entries.allSatisfy({ ($0.profile?.isComplete ?? true) && ($0.curve?.isComplete ?? true)
                                       && ($0.profile == nil) != ($0.curve == nil) })
            else { throw PresetError.damaged(name) }
            return .set(set)
        } catch let error as PresetError {
            throw error
        } catch {
            throw PresetError.damaged(name)
        }
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
