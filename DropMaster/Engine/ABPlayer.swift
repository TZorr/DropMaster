//
//  ABPlayer.swift
//  DropMaster
//
//  Original · Pause · Matched · Reference: one playhead, two versions of
//  the same song, and the record they are being matched to.
//
//  The point of the preview is the comparison, and a comparison only works
//  if the switch is instant and lands on the same moment. So both versions
//  play from one position counter - the matched audio is sample-aligned
//  with the original (MatchEQ removes its filter delay) - and switching
//  only changes which one is heard. Not a second player started at the
//  same time: two players drift, and a restart on every switch would make
//  the listener hear the switch instead of the difference.
//
//  The switch itself is a 10 ms crossfade, and play/pause a 5 ms fade:
//  cutting a waveform mid-cycle clicks, and a click on every switch would
//  sound like one of the two versions has a problem.
//
//  There is deliberately no loudness compensation. Matching the loudness
//  of a reference is half of what DropMaster does; levelling the two
//  versions for the comparison would hide it.
//
//  The reference is a different song, so "the same moment" means the same
//  time: it plays from the playhead's position in seconds. The playhead
//  and its slider belong to the target; where the target is longer than
//  the reference, the reference wraps round to its start instead of
//  falling silent - a comparison needs something to compare with.
//
//  The pattern - an AVAudioSourceNode whose render block reads atomics and
//  an unmanaged pointer - is the same one an earlier preview player used.
//
//  The live meter measures what is heard: the output of the crossfade,
//  after the play/pause fade. Peak per channel with a 20 dB/s fall,
//  momentary and short-term loudness (see LiveLoudness), and while Matched
//  plays the limiter's gain reduction at the playhead, looked up in the
//  record the limiter kept. The render block publishes them as atomics;
//  the UI reads them thirty times a second.
//

import Foundation
import Observation
@preconcurrency import AVFoundation
import Synchronization
import Accelerate

nonisolated enum PreviewSource: Int, Sendable {
    case original = 0
    case matched = 1
    case reference = 2
}

/// Everything the render block touches.
nonisolated final class ABCore: @unchecked Sendable {
    let original = Atomic<UnsafeRawPointer?>(nil)
    let matched = Atomic<UnsafeRawPointer?>(nil)
    let reference = Atomic<UnsafeRawPointer?>(nil)
    let source = Atomic<Int>(PreviewSource.original.rawValue)
    let position = Atomic<Int>(0)
    /// What the user asked for. The audio keeps running for the few
    /// milliseconds of the fade-out after this goes false.
    let wantsToPlay = Atomic<Bool>(false)
    /// True while anything is audible, fade-out included.
    let running = Atomic<Bool>(false)

    // Meters, as bit patterns: peaks (Float, linear), loudness (Double,
    // LUFS, NaN for none), reduction (Float, dB ≤ 0).
    let meterLeft = Atomic<UInt32>(0)
    let meterRight = Atomic<UInt32>(0)
    let meterMomentary = Atomic<UInt64>(Double.nan.bitPattern)
    let meterShortTerm = Atomic<UInt64>(Double.nan.bitPattern)
    let meterReduction = Atomic<UInt32>(Float(0).bitPattern)
    /// Set by the UI thread; the render block clears the loudness state.
    let resetMeters = Atomic<Bool>(false)

    // Audio thread only. One gain per source, each gliding to 1 or 0 over
    // 10 ms: a switch is a crossfade between whichever two are involved.
    private var gainOriginal: Float = 1
    private var gainMatched: Float = 0
    private var gainReference: Float = 0
    private var level: Float = 0
    private let live = LiveLoudness()
    private var peakLeft: Float = 0
    private var peakRight: Float = 0
    /// 20 dB per second, per frame, as a natural-log rate.
    private let fallPerFrame = 20.0 / 20 * log(10.0) / StereoAudio.sampleRate

    private let blendStep = Float(1 / (0.010 * StereoAudio.sampleRate))
    private let levelStep = Float(1 / (0.005 * StereoAudio.sampleRate))

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let outLeft = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let outRight = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)
            outLeft.update(repeating: 0, count: count)
            outRight.update(repeating: 0, count: count)

            if resetMeters.exchange(false, ordering: .acquiringAndReleasing) {
                live.reset()
            }
            let wants = wantsToPlay.load(ordering: .acquiring)
            guard let rawOriginal = original.load(ordering: .acquiring), wants || level > 0 else {
                level = 0
                running.store(false, ordering: .releasing)
                publishMeters(left: outLeft, right: outRight, count: 0, frames: count, reductionDB: 0, audible: false)
                isSilence.pointee = true
                return noErr
            }
            let rawMatched = matched.load(ordering: .acquiring)
            let rawReference = reference.load(ordering: .acquiring)
            // A source that is not there falls back to the original.
            var chosen = source.load(ordering: .relaxed)
            if (chosen == 1 && rawMatched == nil) || (chosen == 2 && rawReference == nil) { chosen = 0 }
            let targetOriginal: Float = chosen == 0 ? 1 : 0
            let targetMatched: Float = chosen == 1 ? 1 : 0
            let targetReference: Float = chosen == 2 ? 1 : 0
            let levelTarget: Float = wants ? 1 : 0
            let start = position.load(ordering: .acquiring)

            @inline(__always) func glide(_ value: inout Float, to target: Float) {
                if value < target { value = min(target, value + blendStep) }
                else if value > target { value = max(target, value - blendStep) }
            }

            let a = Unmanaged<StereoAudio>.fromOpaque(rawOriginal)
            var reachedEnd = false
            var advanced = 0
            var reductionDB: Float = 0
            if let rawMatched, gainMatched > 0 || targetMatched > 0 {
                Unmanaged<StereoAudio>.fromOpaque(rawMatched)._withUnsafeGuaranteedRef { matched in
                    let chunk = start / Limiter.reductionChunk
                    if chunk < matched.gainReduction.count {
                        reductionDB = 20 * log10(max(matched.gainReduction[chunk], 1e-6))
                    }
                }
            }
            a._withUnsafeGuaranteedRef { original in
                let last = original.frameCount
                for i in 0..<count {
                    let f = start + i
                    guard f < last else { reachedEnd = true; break }
                    glide(&gainOriginal, to: targetOriginal)
                    glide(&gainMatched, to: targetMatched)
                    glide(&gainReference, to: targetReference)
                    if level < levelTarget { level = min(levelTarget, level + levelStep) }
                    else if level > levelTarget { level = max(levelTarget, level - levelStep) }

                    var l: Float = 0, r: Float = 0
                    if gainOriginal > 0 {
                        l += original.left[f] * gainOriginal
                        r += original.right[f] * gainOriginal
                    }
                    if gainMatched > 0, let rawMatched {
                        Unmanaged<StereoAudio>.fromOpaque(rawMatched)._withUnsafeGuaranteedRef { matched in
                            if f < matched.frameCount {
                                l += matched.left[f] * gainMatched
                                r += matched.right[f] * gainMatched
                            }
                        }
                    }
                    if gainReference > 0, let rawReference {
                        Unmanaged<StereoAudio>.fromOpaque(rawReference)._withUnsafeGuaranteedRef { reference in
                            if reference.frameCount > 0 {
                                let g = f % reference.frameCount
                                l += reference.left[g] * gainReference
                                r += reference.right[g] * gainReference
                            }
                        }
                    }
                    outLeft[i] = l * level
                    outRight[i] = r * level
                    advanced += 1
                    if level == 0 && !wants { break }
                }
            }
            position.store(start + advanced, ordering: .releasing)
            if reachedEnd {
                wantsToPlay.store(false, ordering: .releasing)
                level = 0
            }
            let audible = level > 0 || (wants && !reachedEnd)
            running.store(audible, ordering: .releasing)
            publishMeters(left: outLeft, right: outRight, count: advanced, frames: count,
                          reductionDB: reductionDB * gainMatched, audible: audible)
            return noErr
        }
    }

    /// Audio thread. `count` rendered frames to measure, `frames` the
    /// length of the block (for the peaks' fall).
    private func publishMeters(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, frames: Int,
                               reductionDB: Float, audible: Bool) {
        let fall = Float(exp(-fallPerFrame * Double(frames)))
        var blockLeft: Float = 0, blockRight: Float = 0
        if count > 0 {
            vDSP_maxmgv(left, 1, &blockLeft, vDSP_Length(count))
            vDSP_maxmgv(right, 1, &blockRight, vDSP_Length(count))
            live.process(left: left, right: right, count: count)
        }
        peakLeft = max(blockLeft, peakLeft * fall)
        peakRight = max(blockRight, peakRight * fall)
        meterLeft.store(peakLeft.bitPattern, ordering: .relaxed)
        meterRight.store(peakRight.bitPattern, ordering: .relaxed)
        func lufs(_ power: Double) -> Double {
            audible && power > Loudness.silentPower ? Loudness.lufs(power: power) : .nan
        }
        meterMomentary.store(lufs(live.momentaryPower).bitPattern, ordering: .relaxed)
        meterShortTerm.store(lufs(live.shortTermPower).bitPattern, ordering: .relaxed)
        meterReduction.store((audible ? reductionDB : 0).bitPattern, ordering: .relaxed)
    }
}

/// One reading of the live meter.
nonisolated struct LiveLevels: Equatable, Sendable {
    var left: Float
    var right: Float
    var momentary: Double?
    var shortTerm: Double?
    var reductionDB: Float
}

@Observable
final class ABPlayer {
    private let engine = AVAudioEngine()
    private let core = ABCore()
    /// The audio currently handed to the render block, and the audio before
    /// it: the callback may still be finishing a block of the previous one
    /// when a new one is set, so that one is released one change later.
    @ObservationIgnored private var heldOriginal: [StereoAudio] = []
    @ObservationIgnored private var heldMatched: [StereoAudio] = []
    @ObservationIgnored private var heldReference: [StereoAudio] = []
    @ObservationIgnored private var started = false

    /// The version playing, or the one that will play on resume.
    private(set) var source: PreviewSource = .original
    private(set) var duration: Double = 0

    var isPlaying: Bool { core.wantsToPlay.load(ordering: .acquiring) }
    var hasMatched: Bool { core.matched.load(ordering: .acquiring) != nil }
    var hasReference: Bool { core.reference.load(ordering: .acquiring) != nil }

    var positionSeconds: Double {
        Double(core.position.load(ordering: .acquiring)) / StereoAudio.sampleRate
    }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: StereoAudio.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// A new target: stops, rewinds, and forgets any matched version.
    func setOriginal(_ audio: StereoAudio?) {
        core.wantsToPlay.store(false, ordering: .releasing)
        setMatched(nil)
        core.original.store(Self.pointer(audio), ordering: .releasing)
        heldOriginal = Array(heldOriginal.suffix(1)) + (audio.map { [$0] } ?? [])
        core.position.store(0, ordering: .releasing)
        duration = audio?.duration ?? 0
        if audio == nil { source = .original }
    }

    /// The matched version of the current target (same length), or nil.
    func setMatched(_ audio: StereoAudio?) {
        core.matched.store(Self.pointer(audio), ordering: .releasing)
        heldMatched = Array(heldMatched.suffix(1)) + (audio.map { [$0] } ?? [])
        if audio == nil && source == .matched {
            source = .original
            core.source.store(PreviewSource.original.rawValue, ordering: .releasing)
        }
    }

    /// The reference, heard at the playhead's time (see the file header).
    func setReference(_ audio: StereoAudio?) {
        core.reference.store(Self.pointer(audio), ordering: .releasing)
        heldReference = Array(heldReference.suffix(1)) + (audio.map { [$0] } ?? [])
        if audio == nil && source == .reference {
            source = .original
            core.source.store(PreviewSource.original.rawValue, ordering: .releasing)
        }
    }

    func play(_ source: PreviewSource) {
        guard core.original.load(ordering: .acquiring) != nil else { return }
        if source == .matched && !hasMatched { return }
        if source == .reference && !hasReference { return }
        self.source = source
        core.source.store(source.rawValue, ordering: .releasing)
        if !started {
            started = (try? engine.start()) != nil
        }
        if Int(positionSeconds * StereoAudio.sampleRate) >= Int(duration * StereoAudio.sampleRate) - 1 {
            core.position.store(0, ordering: .releasing)
        }
        // A fresh measurement on start, not on a switch: the loudness of
        // what is heard carries on across the three.
        if !isPlaying { core.resetMeters.store(true, ordering: .releasing) }
        core.wantsToPlay.store(true, ordering: .releasing)
    }

    func pause() {
        core.wantsToPlay.store(false, ordering: .releasing)
    }

    func togglePlay() {
        if isPlaying { pause() } else { play(source) }
    }

    func seek(toSeconds seconds: Double) {
        let frame = Int(max(0, min(seconds, duration)) * StereoAudio.sampleRate)
        core.position.store(frame, ordering: .releasing)
        core.resetMeters.store(true, ordering: .releasing)
    }

    func readMeters() -> LiveLevels {
        func optional(_ bits: UInt64) -> Double? {
            let value = Double(bitPattern: bits)
            return value.isFinite ? value : nil
        }
        return LiveLevels(left: Float(bitPattern: core.meterLeft.load(ordering: .relaxed)),
                          right: Float(bitPattern: core.meterRight.load(ordering: .relaxed)),
                          momentary: optional(core.meterMomentary.load(ordering: .relaxed)),
                          shortTerm: optional(core.meterShortTerm.load(ordering: .relaxed)),
                          reductionDB: Float(bitPattern: core.meterReduction.load(ordering: .relaxed)))
    }

    private static func pointer(_ audio: StereoAudio?) -> UnsafeRawPointer? {
        audio.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
    }
}
