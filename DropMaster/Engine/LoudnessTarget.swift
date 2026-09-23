//
//  LoudnessTarget.swift
//  DropMaster
//
//  An integrated-loudness target instead of "as loud as the reference":
//  the streaming platforms' reference levels, or any value set with - / +.
//
//  The platforms do not want a master *at* their level so much as they turn
//  anything louder down to it. Mastering to the level avoids giving away
//  dynamics for loudness nobody will hear - and, for a platform that also
//  turns quiet tracks up, avoids its limiter. Spotify was on the list and
//  came off: at -14 LUFS it is YouTube's level, and one value per entry
//  lets the name follow the value (see `title`).
//
//  Other values are set with - / + rather than typed: every value that can
//  be reached is valid, so there is nothing to parse and nothing to refuse
//  (a text field was tried first; it needed both, and a blinking cursor in
//  a panel of meters). The range is what masters are actually delivered
//  at: -24 for the quietest (broadcast is -23, Qobuz -18) to -6 for the
//  loudest - the limiter has not reached more than about -8 on dense
//  material anyway. Half an LU per step, a tenth with Option.
//

import Foundation

nonisolated enum LoudnessTarget {
    struct Platform: Identifiable, Hashable, Sendable {
        let name: String
        let lufs: Double
        var id: String { name }
    }

    static let platforms: [Platform] = [
        Platform(name: "YouTube", lufs: -14),
        Platform(name: "Deezer", lufs: -15),
        Platform(name: "Apple Music", lufs: -16),
        Platform(name: "Qobuz", lufs: -18),
    ]

    static let range = -24.0 ... -6.0
    static let step = 0.5
    static let fineStep = 0.1

    /// `value` moved by `delta` on the grid of `delta`'s size, clamped to
    /// `range`. A value off the grid (a reference's -7.03) first goes to the
    /// grid line in the direction of the step, so + never goes down.
    static func stepped(from value: Double, by delta: Double) -> Double {
        let grid = abs(delta) < step ? fineStep : step
        let units = value / grid
        let next: Double
        if abs(units - units.rounded()) < 1e-6 {
            next = (units.rounded() + (delta > 0 ? 1 : -1)) * grid
        } else {
            next = (delta > 0 ? units.rounded(.up) : units.rounded(.down)) * grid
        }
        return clamped((next * 10).rounded() / 10)
    }

    static func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// What the target box shows: the platform whose level this is,
    /// "Custom" for any other value, "Reference" for none. Its menu says
    /// "Match reference"; the face is shorter because box and stepper
    /// share one row of the panel, and "Match reference" pushed it from
    /// 341 to 373 points wide.
    static func title(_ lufs: Double?) -> String {
        guard let lufs else { return "Reference" }
        return platforms.first { abs($0.lufs - lufs) < 0.001 }?.name ?? "Custom"
    }
}
