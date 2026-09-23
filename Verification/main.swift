//
//  Verification/main.swift
//  DropMaster
//
//  Self-checks for the engine: does the match do what it claims, on
//  signals where the right answer is known in advance? There is no
//  comparison with Matchering here, deliberately - DropMaster is its own
//  design, and "the same as another program" is not what it promises.
//
//  What it promises, and what is checked:
//  - the FFT and the FIR are scaled right (a flat curve is a unit impulse),
//  - matching a track to itself changes nothing,
//  - a tonal difference is corrected, band by band,
//  - a level difference is corrected, and the ceiling holds,
//  - every export format and quality reads back: lossless ones sample for
//    sample within their dither, lossy ones at the right length and size,
//  - the decoder turns mono into stereo, resamples, and refuses garbage,
//  - the A/B player switches without a jump and fades instead of clicking
//    (its render block, driven by hand - no audio device, no sound),
//  - the loudness figures read what EBU R128 / Tech 3341-3342 say they
//    should on their test signals, and the true peak finds the overshoot,
//  - the limiter panel's settings do what they say, and the defaults give
//    exactly what the match gave before the panel existed,
//  - a preset carries the curve accurately enough at 1/12 octave, writes
//    and reads back, and matches a new target through it.
//

import Foundation
import AVFoundation
import Accelerate

var failures = 0

func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "  ok  " : "  FAIL") \(message)")
    if !condition { failures += 1 }
}

func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

// MARK: - Signals

/// Deterministic white noise in ±1.
struct Noise {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

/// Pink noise (Paul Kellet's filter), stereo with some width, peaking
/// around `peak`.
func pinkStereo(seconds: Double, seed: UInt64, peak: Float = 0.5) -> StereoAudio {
    let n = Int(seconds * StereoAudio.sampleRate)
    var noise = Noise(state: seed)
    func pink() -> [Float] {
        var b = [Float](repeating: 0, count: 7)
        return (0..<n).map { _ in
            let w = noise.next()
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.0168980
            let out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            return out
        }
    }
    let a = pink(), s = pink()
    var left = zip(a, s).map { $0 + 0.3 * $1 }
    var right = zip(a, s).map { $0 - 0.3 * $1 }
    let top = max(left.map(abs).max()!, right.map(abs).max()!)
    left = left.map { $0 * peak / top }
    right = right.map { $0 * peak / top }
    return StereoAudio(left: left, right: right)
}

/// RBJ high shelf, applied to both channels.
func highShelf(_ audio: StereoAudio, hz: Double, gainDB: Double) -> StereoAudio {
    let a = pow(10, gainDB / 40)
    let w0 = 2 * Double.pi * hz / StereoAudio.sampleRate
    let alpha = sin(w0) / 2 * sqrt(2)
    let c = cos(w0), sa = 2 * sqrt(a) * alpha
    let b0 = a * ((a + 1) + (a - 1) * c + sa)
    let b1 = -2 * a * ((a - 1) + (a + 1) * c)
    let b2 = a * ((a + 1) + (a - 1) * c - sa)
    let a0 = (a + 1) - (a - 1) * c + sa
    let a1 = 2 * ((a - 1) - (a + 1) * c)
    let a2 = (a + 1) - (a - 1) * c - sa
    func run(_ x: UnsafePointer<Float>) -> [Float] {
        var y = [Float](repeating: 0, count: audio.frameCount)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<audio.frameCount {
            let x0 = Double(x[i])
            let y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            y[i] = Float(y0)
        }
        return y
    }
    return StereoAudio(left: run(audio.left), right: run(audio.right))
}

func scaled(_ audio: StereoAudio, _ gain: Float) -> StereoAudio {
    StereoAudio(left: (0..<audio.frameCount).map { audio.left[$0] * gain },
                right: (0..<audio.frameCount).map { audio.right[$0] * gain })
}

/// Third-octave band levels (dB) of the Mid of `audio`, 63 Hz to 12.5 kHz.
func bands(_ audio: StereoAudio) -> [Double] {
    let (mid, _) = MatchAnalysis.midSide(audio)
    let all = MatchAnalysis.profile(mid, count: mid.count)
    let whole = LoudnessProfile(blockSize: all.blockSize, blockPower: all.blockPower,
                                loudBlocks: Array(all.blockPower.indices), loudRMS: 0)
    let spectrum = MatchAnalysis.powerSpectrum(mid, profile: whole)
    let centres = (0..<24).map { 63 * pow(2, Double($0) / 3) }
    return centres.map { f in
        let lo = Int((f / pow(2, 1.0 / 6) / MatchEQ.binHz).rounded())
        let hi = Int((f * pow(2, 1.0 / 6) / MatchEQ.binHz).rounded())
        return 10 * log10((lo...max(lo, hi)).reduce(0) { $0 + spectrum[$1] })
    }
}

func loudRMS(_ audio: StereoAudio) -> Double {
    let (mid, _) = MatchAnalysis.midSide(audio)
    return MatchAnalysis.profile(mid, count: mid.count).loudRMS
}

func maxDifference(_ a: StereoAudio, _ b: StereoAudio) -> Float {
    var worst: Float = 0
    for i in 0..<min(a.frameCount, b.frameCount) {
        worst = max(worst, abs(a.left[i] - b.left[i]), abs(a.right[i] - b.right[i]))
    }
    return worst
}

// MARK: - FFT and FIR

print("FFT / FIR")
do {
    let fft = RealFFT(size: 64)
    var noise = Noise(state: 7)
    let input = (0..<64).map { _ in noise.next() }
    var real = [Float](repeating: 0, count: 32), imag = [Float](repeating: 0, count: 32)
    var back = [Float](repeating: 0, count: 64)
    fft.forward(input, real: &real, imag: &imag)
    fft.inverse(real: &real, imag: &imag, output: &back)
    let error = zip(input, back).map { abs($0 - $1) }.max()!
    check(error < 1e-5, "inverse(forward(x)) == x (max error \(error))")

    let flat = MatchEQ.fir([Double](repeating: 0, count: MatchEQ.firLength / 2 + 1))
    let centre = flat[MatchEQ.firLength / 2]
    let rest = flat.enumerated().filter { $0.offset != MatchEQ.firLength / 2 }.map { abs($0.element) }.max()!
    check(abs(centre - 1) < 1e-4 && rest < 1e-4, "flat curve -> unit impulse at the centre (\(centre), rest \(rest))")

    // A delayed impulse through the convolver comes out undelayed.
    var impulse = [Float](repeating: 0, count: 20_000)
    impulse[12_345] = 1
    var out = [Float](repeating: 0, count: 20_000)
    try FIRConvolver(fir: flat).apply(impulse, count: impulse.count, output: &out)
    let peakAt = out.indices.max { abs(out[$0]) < abs(out[$1]) }!
    check(peakAt == 12_345 && abs(out[peakAt] - 1) < 1e-3, "convolver removes the FIR delay (peak at \(peakAt), \(out[peakAt]))")
} catch {
    check(false, "FFT / FIR threw \(error)")
}

// MARK: - Matching

print("Matching")
do {
    let source = pinkStereo(seconds: 30, seed: 1)

    // Identity.
    let (same, sameReport) = try Matcher.match(target: source, reference: source, allowIdentical: true)
    let difference = maxDifference(same, source)
    check(abs(sameReport.gainDB) < 0.1, "self-match: gain \(String(format: "%+.3f", sameReport.gainDB)) dB")
    check(sameReport.midCurveDB.allSatisfy { abs($0) < 0.05 }, "self-match: flat Mid curve")
    check(difference < 0.01, "self-match: output ≈ input, sample-aligned (max diff \(difference))")
    do {
        _ = try Matcher.match(target: source, reference: source)
        check(false, "identical target and reference are refused")
    } catch MatchError.identical {
        check(true, "identical target and reference are refused")
    }

    // Tone.
    let bright = highShelf(source, hz: 2000, gainDB: 6)
    let other = pinkStereo(seconds: 30, seed: 2)
    let (toned, toneReport) = try Matcher.match(target: other, reference: bright)
    let want = bands(bright), got = bands(toned)
    let deltas = zip(got, want).map { $0 - $1 }
    let mean = deltas.reduce(0, +) / Double(deltas.count)
    let spread = deltas.map { abs($0 - mean) }.max()!
    check(spread < 1.0, "tone: third-octave bands follow the reference within ±\(String(format: "%.2f", spread)) dB")
    check(abs(mean) < 1.0, "tone: overall band level within \(String(format: "%+.2f", mean)) dB")
    let at10k = toneReport.midCurveDB[Int(10_000 / MatchEQ.binHz)]
    let at100 = toneReport.midCurveDB[Int(100 / MatchEQ.binHz)]
    check(abs((at10k - at100) - 6) < 1, "tone: curve rises \(String(format: "%.2f", at10k - at100)) dB from 100 Hz to 10 kHz (shelf +6)")

    // Level.
    let quiet = scaled(other, 0.25)
    let (levelled, levelReport) = try Matcher.match(target: quiet, reference: source)
    let error = db(loudRMS(levelled)) - db(loudRMS(source))
    check(abs(error) < 0.5, "level: loud-block RMS within \(String(format: "%+.2f", error)) dB of the reference")
    check(Double(levelled.peak) <= pow(10, levelReport.ceilingDB / 20) + 1e-6,
          "level: peak \(String(format: "%.2f", db(Double(levelled.peak)))) dBFS ≤ ceiling \(String(format: "%.2f", levelReport.ceilingDB))")

    // A loud master: the reference was pushed 8 dB into a limiter, the
    // way loud records are made. The match has to get there the same way.
    let hot = scaled(source, 2.5)
    try Limiter(ceiling: pow(10, -0.1 / 20)).processAll(left: hot.left, right: hot.right, count: hot.frameCount)
    let (loud, loudReport) = try Matcher.match(target: other, reference: hot)
    check(loudReport.ceilingDB <= Matcher.maximumCeilingDB + 1e-9, "loud master: ceiling capped at \(String(format: "%.2f", loudReport.ceilingDB)) dBFS")
    check(Double(loud.peak) <= pow(10, loudReport.ceilingDB / 20) + 1e-6, "loud master: peak \(String(format: "%.3f", db(Double(loud.peak)))) dBFS ≤ ceiling")
    check(loudReport.limiterReductionDB < -1, "loud master: the limiter worked (\(String(format: "%.1f", loudReport.limiterReductionDB)) dB)")
    let hotError = db(loudRMS(loud)) - db(loudRMS(hot))
    check(abs(hotError) < 1.0, "loud master: loudness within \(String(format: "%+.2f", hotError)) dB of the reference")

    // A clipped reference: a documented limit, reported, not asserted.
    let clipped = StereoAudio(left: (0..<source.frameCount).map { max(-1, min(1, source.left[$0] * 4)) },
                              right: (0..<source.frameCount).map { max(-1, min(1, source.right[$0] * 4)) })
    let (versusClipped, _) = try Matcher.match(target: other, reference: clipped)
    print("        info: vs. a reference clipped by 12 dB the result is \(String(format: "%+.2f", db(loudRMS(versusClipped)) - db(loudRMS(clipped)))) dB (no clipping by design)")

    // Timing, on something the length of a song.
    let long = pinkStereo(seconds: 300, seed: 3)
    let longRef = pinkStereo(seconds: 240, seed: 4)
    let start = Date()
    _ = try Matcher.match(target: long, reference: longRef)
    print("        5-minute match took \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
} catch {
    check(false, "matching threw \(error)")
}

// MARK: - Export

print("Export")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dropmaster_verify", isDirectory: true)
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// 10 s of music-like material: a chord over pink noise, with some width.
let exportSource: StereoAudio = {
    let pink = pinkStereo(seconds: 10, seed: 9, peak: 0.3)
    for i in 0..<pink.frameCount {
        let t = Double(i) / 44_100
        let chord = Float(0.15 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)))
        pink.left[i] += chord
        pink.right[i] += chord * 0.8
    }
    return pink
}()

/// Reads a whole file back as Float32 at its own rate.
func readBack(_ url: URL) throws -> (file: AVAudioFormat, left: [Float], right: [Float]) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    var left: [Float] = [], right: [Float] = []
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
    while true {
        do { try file.read(into: buffer) } catch { break }
        if buffer.frameLength == 0 { break }
        let n = Int(buffer.frameLength), c = buffer.floatChannelData!
        left += UnsafeBufferPointer(start: c[0], count: n)
        right += UnsafeBufferPointer(start: c[Int(file.processingFormat.channelCount) > 1 ? 1 : 0], count: n)
    }
    return (file.fileFormat, left, right)
}

var sizes: [String: Int] = [:]
for format in OutputFormat.allCases {
    for quality in format.qualityOptions {
        let name = "\(format.menuTitle) \(quality.label)"
        let url = folder.appendingPathComponent("\(format.rawValue)-\(quality.label.replacingOccurrences(of: " ", with: "_")).\(format.fileExtension)")
        do {
            try Exporter.export(exportSource, format: format, quality: quality, to: url)
            sizes[name] = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let (fileFormat, left, right) = try readBack(url)
            let frames = left.count
            var basic = fileFormat.sampleRate == 44_100 && fileFormat.channelCount == 2
            var detail = "\(frames) frames"
            if let bits = quality.pcmBits {
                // Lossless: sample for sample, within the dither of the chosen depth.
                var worst: Float = 0
                for i in 0..<min(frames, exportSource.frameCount) {
                    worst = max(worst, abs(left[i] - exportSource.left[i]), abs(right[i] - exportSource.right[i]))
                }
                basic = basic && frames == exportSource.frameCount
                if quality.isFloatPCM {
                    basic = basic && worst < 1e-6
                    detail += ", float error \(worst)"
                } else {
                    // ALAC and FLAC say their depth in the source-data flags.
                    if format == .m4aALAC || format == .flac {
                        let flags = fileFormat.streamDescription.pointee.mFormatFlags
                        let expected = bits >= 24 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_16BitSourceData
                        basic = basic && flags == expected
                        detail += ", stored as \(flags == kAppleLosslessFormatFlag_24BitSourceData ? 24 : flags == kAppleLosslessFormatFlag_16BitSourceData ? 16 : 0)-bit"
                    }
                    let lsb = 1 / Float(1 << (bits - 1)), lsb24 = 1 / Float(1 << 23)
                    // Within 2.5 LSB of the chosen depth - and, for 16 bits,
                    // clearly more than 24-bit error: it really was quantised.
                    basic = basic && worst <= 2.5 * lsb && (bits == 24 || worst > 2.5 * lsb24)
                    detail += String(format: ", error %.2f LSB", worst / lsb)
                }
            } else {
                // Lossy: the length within codec priming and padding.
                basic = basic && abs(frames - exportSource.frameCount) <= 4096
            }
            check(basic, "\(name): \(detail), \(sizes[name]! / 1024) KB")
        } catch {
            check(false, "\(name) threw \(error)")
        }
    }
}
let aacRatio = Double(sizes["M4A / AAC 128 kbps"] ?? 0) / Double(max(sizes["M4A / AAC 256 kbps"] ?? 1, 1))
let mp3Ratio = Double(sizes["MP3 192 kbps CBR"] ?? 0) / Double(max(sizes["MP3 320 kbps CBR"] ?? 1, 1))
check(aacRatio > 0.4 && aacRatio < 0.65, "AAC 128 vs 256 kbps: size ratio \(String(format: "%.2f", aacRatio))")
check(mp3Ratio > 0.5 && mp3Ratio < 0.7, "MP3 192 vs 320 kbps: size ratio \(String(format: "%.2f", mp3Ratio))")
do {
    let url = folder.appendingPathComponent("no-such-folder/out.flac")
    try Exporter.export(exportSource, format: .flac, quality: OutputFormat.flac.defaultQuality, to: url)
    check(false, "an unwritable destination is an error")
} catch {
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("no-such-folder/out.flac").path),
          "an unwritable destination is an error, and leaves nothing (\(error.localizedDescription))")
}

// MARK: - Decoder

print("Decoder")
/// In a function of its own: AVAudioFile finishes the header when released.
func writeMono48k(_ url: URL, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let n = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buffer.frameLength = n
    for i in 0..<Int(n) { buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * Double.pi * 500 * Double(i) / 48_000)) }
    try file.write(from: buffer)
}
do {
    let url = folder.appendingPathComponent("mono48k.caf")
    try writeMono48k(url, seconds: 4)
    let (audio, info) = try Decoder.decode(url)
    let expected = 4 * 44_100
    var same = true
    for i in 0..<audio.frameCount where audio.left[i] != audio.right[i] { same = false; break }
    check(info.sampleRate == 48_000 && info.channels == 1, "mono 48 kHz: source info \(info.sampleRate) Hz, \(info.channels) ch")
    check(abs(audio.frameCount - expected) <= 64, "mono 48 kHz -> \(audio.frameCount) frames at 44.1 kHz (expected ≈ \(expected))")
    check(same && abs(audio.peak - 0.3) < 0.01, "mono -> both channels at full level (peak \(audio.peak))")
} catch {
    check(false, "decoding mono 48 kHz threw \(error)")
}
do {
    let url = folder.appendingPathComponent("garbage.wav")
    try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(to: url)
    _ = try Decoder.decode(url)
    check(false, "a garbage file is refused")
} catch {
    check(true, "a garbage file is refused (\(error.localizedDescription))")
}

// MARK: - A/B player

print("A/B player")
do {
    let n = 44_100
    let original = StereoAudio(left: [Float](repeating: 0.5, count: n), right: [Float](repeating: 0.5, count: n))
    let matched = StereoAudio(left: [Float](repeating: -0.25, count: n), right: [Float](repeating: -0.25, count: n))
    let core = ABCore()
    core.original.store(UnsafeRawPointer(Unmanaged.passUnretained(original).toOpaque()), ordering: .releasing)
    core.matched.store(UnsafeRawPointer(Unmanaged.passUnretained(matched).toOpaque()), ordering: .releasing)
    let render = core.makeRenderBlock()
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l)
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: r)
    var silence = ObjCBool(false)
    var stamp = AudioTimeStamp()
    func pull() -> [Float] {
        _ = render(&silence, &stamp, AVAudioFrameCount(frames), list.unsafeMutablePointer)
        return Array(UnsafeBufferPointer(start: l, count: frames))
    }
    func steps(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }

    let idle = pull()
    check(idle.allSatisfy { $0 == 0 } && core.position.load(ordering: .acquiring) == 0, "paused: silent, playhead still")

    core.wantsToPlay.store(true, ordering: .releasing)
    let fadeIn = pull(), steady = pull()
    check(fadeIn.first! < 0.01 && steps(fadeIn) < 0.01, "play: fades in (first \(fadeIn.first!), largest step \(steps(fadeIn)))")
    check(steady.allSatisfy { abs($0 - 0.5) < 1e-6 }, "play: then the original, unchanged")
    check(core.position.load(ordering: .acquiring) == 2 * frames, "play: playhead advances by what was rendered")

    core.source.store(PreviewSource.matched.rawValue, ordering: .releasing)
    let switching = pull(), switched = pull()
    check(steps(switching) < 0.01 && switching.first! > 0.49, "switch: crossfades (largest step \(steps(switching)))")
    check(switched.allSatisfy { abs($0 + 0.25) < 1e-6 }, "switch: then the matched version")
    check(core.position.load(ordering: .acquiring) == 4 * frames, "switch: same playhead, no jump")

    core.wantsToPlay.store(false, ordering: .releasing)
    let fadeOut = pull()
    let stoppedAt = core.position.load(ordering: .acquiring)
    let after = pull()
    check(steps(fadeOut) < 0.01 && abs(fadeOut.last!) < 1e-6, "pause: fades out (largest step \(steps(fadeOut)))")
    check(after.allSatisfy { $0 == 0 } && core.position.load(ordering: .acquiring) == stoppedAt
          && !core.running.load(ordering: .acquiring), "pause: then silent, playhead stays at \(stoppedAt)")

    core.position.store(n - 100, ordering: .releasing)
    core.wantsToPlay.store(true, ordering: .releasing)
    _ = pull()
    check(!core.wantsToPlay.load(ordering: .acquiring), "end of song: the player stops itself")
    l.deallocate(); r.deallocate(); free(list.unsafeMutablePointer)
}

// MARK: - Reference preview

print("Reference preview")
do {
    let n = 44_100
    let original = StereoAudio(left: [Float](repeating: 0.5, count: n), right: [Float](repeating: 0.5, count: n))
    // A ramp, so the frame that plays can be told from its value; shorter
    // than the target, so the wrap shows.
    let refCount = 10_000
    let ramp = (0..<refCount).map { Float($0) / Float(refCount) }
    let reference = StereoAudio(left: ramp, right: ramp)
    let core = ABCore()
    core.original.store(UnsafeRawPointer(Unmanaged.passUnretained(original).toOpaque()), ordering: .releasing)
    core.reference.store(UnsafeRawPointer(Unmanaged.passUnretained(reference).toOpaque()), ordering: .releasing)
    let render = core.makeRenderBlock()
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l)
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: r)
    var silence = ObjCBool(false)
    var stamp = AudioTimeStamp()
    func pull() -> [Float] {
        _ = render(&silence, &stamp, AVAudioFrameCount(frames), list.unsafeMutablePointer)
        return Array(UnsafeBufferPointer(start: l, count: frames))
    }
    core.position.store(25_000, ordering: .releasing)
    core.wantsToPlay.store(true, ordering: .releasing)
    _ = pull(); _ = pull()
    core.source.store(PreviewSource.reference.rawValue, ordering: .releasing)
    let switching = pull()
    let steps = zip(switching, switching.dropFirst()).map { abs($1 - $0) }.max()!
    let start = core.position.load(ordering: .acquiring)
    let settled = pull()
    let expected = (0..<frames).map { ramp[(start + $0) % refCount] }
    let worst = zip(settled, expected).map { abs($0 - $1) }.max()!
    check(steps < 0.01, "switch to reference: crossfades (largest step \(steps))")
    check(worst < 1e-6, "reference plays at the playhead's time, wrapped round (frame \(start % refCount) of \(refCount))")
    core.reference.store(nil, ordering: .releasing)
    _ = pull()
    let fallback = pull()
    check(fallback.allSatisfy { abs($0 - 0.5) < 1e-6 }, "reference gone: falls back to the original")
    l.deallocate(); r.deallocate(); free(list.unsafeMutablePointer)
}

// MARK: - Loudness

print("Loudness")
func sine(hz: Double, dbfs: Double, seconds: Double, phase: Double = 0) -> [Float] {
    let a = pow(10, dbfs / 20)
    return (0..<Int(seconds * StereoAudio.sampleRate)).map {
        Float(a * sin(2 * Double.pi * hz * Double($0) / StereoAudio.sampleRate + phase))
    }
}
do {
    // BS.1770 prints its filter for 48 kHz; the derivation must give it back.
    let (shelf, highPass) = KWeighting.coefficients(sampleRate: 48_000)
    let printed = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                   -1.99004745483398, 0.99007225036621]
    let derived = [shelf.b0, shelf.b1, shelf.b2, shelf.a1, shelf.a2, highPass.a1, highPass.a2]
    let worst = zip(printed, derived).map { abs($0 - $1) }.max()!
    check(worst < 1e-8, "K-weighting at 48 kHz = BS.1770's coefficients (max diff \(worst))")

    // EBU Tech 3341: 1 kHz, -23 dBFS on both channels reads -23 LUFS.
    let tone = sine(hz: 1000, dbfs: -23, seconds: 20)
    let stats = LoudnessStats.measure(StereoAudio(left: tone, right: tone))
    check(abs((stats.integrated ?? 0) + 23) < 0.1, "−23 dBFS 1 kHz stereo: integrated \(String(format: "%.2f", stats.integrated ?? 0)) LUFS")
    check(abs((stats.shortTermMax ?? 0) + 23) < 0.1, "−23 dBFS 1 kHz stereo: short-term max \(String(format: "%.2f", stats.shortTermMax ?? 0)) LUFS")
    check((stats.range ?? 99) < 0.1, "steady tone: loudness range \(String(format: "%.2f", stats.range ?? 99)) LU")

    // EBU Tech 3342: -20 and -30 LUFS in turn gives a range of 10 LU.
    var stepped: [Float] = []
    for _ in 0..<3 {
        stepped += sine(hz: 1000, dbfs: -20, seconds: 20)
        stepped += sine(hz: 1000, dbfs: -30, seconds: 20)
    }
    let range = LoudnessStats.measure(StereoAudio(left: stepped, right: stepped)).range ?? 0
    check(abs(range - 10) < 1, "−20 / −30 LUFS alternating: loudness range \(String(format: "%.2f", range)) LU")

    // True peak: fs/4 sampled 45° off the crest - samples at -3 dBFS, wave at 0.
    let quarter = sine(hz: StereoAudio.sampleRate / 4, dbfs: 0, seconds: 1, phase: Double.pi / 4)
    let tp = LoudnessStats.measure(StereoAudio(left: quarter, right: quarter))
    let samplePeak = 20 * log10(Double(quarter.map(abs).max()!))
    check(abs(samplePeak + 3.01) < 0.05 && abs(tp.truePeakDB) < 0.3,
          "fs/4 at 45°: sample peak \(String(format: "%.2f", samplePeak)) dBFS, true peak \(String(format: "%.2f", tp.truePeakDB)) dBTP")
    let plain = sine(hz: 997, dbfs: -6, seconds: 1)
    let tpPlain = LoudnessStats.measure(StereoAudio(left: plain, right: plain)).truePeakDB
    check(abs(tpPlain + 6) < 0.05, "a slow sine: true peak = sample peak (\(String(format: "%.3f", tpPlain)) dBTP)")

    // The live meter, driven by hand on the same tone as above.
    let audio = StereoAudio(left: tone, right: tone)
    let core = ABCore()
    core.original.store(UnsafeRawPointer(Unmanaged.passUnretained(audio).toOpaque()), ordering: .releasing)
    core.wantsToPlay.store(true, ordering: .releasing)
    let render = core.makeRenderBlock()
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: l)
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: r)
    var silence = ObjCBool(false)
    var stamp = AudioTimeStamp()
    for _ in 0..<(5 * 44_100 / frames) { _ = render(&silence, &stamp, AVAudioFrameCount(frames), list.unsafeMutablePointer) }
    let shortTerm = Double(bitPattern: core.meterShortTerm.load(ordering: .relaxed))
    let momentary = Double(bitPattern: core.meterMomentary.load(ordering: .relaxed))
    let peak = 20 * log10(Double(Float(bitPattern: core.meterLeft.load(ordering: .relaxed))))
    check(abs(shortTerm + 23) < 0.2 && abs(momentary + 23) < 0.2,
          "live meter on the −23 tone: LUFS S \(String(format: "%.2f", shortTerm)), M \(String(format: "%.2f", momentary))")
    check(abs(peak + 23) < 0.1, "live meter peak \(String(format: "%.2f", peak)) dBFS")
    l.deallocate(); r.deallocate(); free(list.unsafeMutablePointer)
}

// MARK: - Limiter controls

print("Limiter controls")
do {
    let reference = scaled(pinkStereo(seconds: 30, seed: 1), 2.5)
    try Limiter(ceiling: pow(10, -0.3 / 20)).processAll(left: reference.left, right: reference.right, count: reference.frameCount)
    let target = pinkStereo(seconds: 30, seed: 2)
    let preparation = try Matcher.prepare(target: target, reference: reference)
    func lufs(_ audio: StereoAudio) -> Double { LoudnessStats.measure(audio).integrated ?? -99 }
    func peakDB(_ audio: StereoAudio) -> Double { 20 * log10(Double(audio.peak)) }

    let (plain, plainReport) = try Matcher.match(target: target, reference: reference)
    let (defaults, defaultsReport) = try Matcher.finish(preparation, settings: LimiterSettings())
    check(plain.isIdentical(to: defaults) && plainReport == defaultsReport, "default settings: identical to match()")
    check(!defaults.gainReduction.isEmpty
          && abs(20 * log10(Double(defaults.gainReduction.min()!)) - defaultsReport.limiterReductionDB) < 0.01,
          "gain-reduction record: \(defaults.gainReduction.count) chunks, deepest = the limiter's \(String(format: "%.2f", defaultsReport.limiterReductionDB)) dB")

    // Default settings mean "as loud as the reference" - and that is now
    // its integrated loudness, not the RMS of its loud blocks.
    check(abs(lufs(defaults) - (LoudnessStats.measure(reference).integrated ?? 0)) < 0.1,
          "match reference: \(String(format: "%.2f", lufs(defaults))) LUFS against the reference's \(String(format: "%.2f", LoudnessStats.measure(reference).integrated ?? 0))")

    var hotter = LimiterSettings(); hotter.targetLUFS = LoudnessTarget.clamped(lufs(defaults) + 3)
    let (pushed, pushedReport) = try Matcher.finish(preparation, settings: hotter)
    let gained = lufs(pushed) - lufs(defaults)
    check(gained > 0.5 && pushedReport.limiterReductionDB < defaultsReport.limiterReductionDB,
          "3 LU louder asked for: \(String(format: "%+.2f", gained)) LU, the limiter works harder (\(String(format: "%.1f", pushedReport.limiterReductionDB)) dB)")
    check(peakDB(pushed) <= pushedReport.ceilingDB + 1e-4, "3 LU louder: the ceiling holds")

    var lower = LimiterSettings(); lower.autoCeiling = false; lower.ceilingDB = -1
    let (capped, cappedReport) = try Matcher.finish(preparation, settings: lower)
    check(cappedReport.ceilingDB == -1 && peakDB(capped) <= -1 + 1e-4, "manual ceiling −1.0: peak \(String(format: "%.3f", peakDB(capped))) dBFS")

    var off = LimiterSettings(); off.enabled = false
    let (unlimited, offReport) = try Matcher.finish(preparation, settings: off)
    check(offReport.limiterReductionDB == 0 && unlimited.gainReduction.isEmpty && peakDB(unlimited) <= offReport.ceilingDB + 1e-4,
          "limiter off: no reduction, turned down to fit (gain \(String(format: "%+.1f", offReport.gainDB)) dB vs \(String(format: "%+.1f", defaultsReport.gainDB)))")
    check(lufs(unlimited) < lufs(defaults) - 1, "limiter off: quieter than limited (\(String(format: "%.1f", lufs(unlimited))) vs \(String(format: "%.1f", lufs(defaults))) LUFS)")

    var fast = LimiterSettings(); fast.autoRelease = false; fast.releaseMilliseconds = 50
    let (quick, _) = try Matcher.finish(preparation, settings: fast)
    check(!quick.isIdentical(to: defaults) && peakDB(quick) <= defaultsReport.ceilingDB + 1e-4,
          "fixed 50 ms release: differs from auto, ceiling holds (\(String(format: "%.1f", lufs(quick))) vs \(String(format: "%.1f", lufs(defaults))) LUFS)")

    let start = Date()
    _ = try Matcher.finish(preparation, settings: hotter)
    let finishTime = Date().timeIntervalSince(start)
    let long = try Matcher.prepare(target: pinkStereo(seconds: 300, seed: 5), reference: reference)
    let longStart = Date()
    let (longResult, _) = try Matcher.finish(long, settings: hotter)
    let longFinish = Date().timeIntervalSince(longStart)
    let statsStart = Date()
    _ = LoudnessStats.measure(longResult)
    print("        finish: 30 s in \(String(format: "%.3f", finishTime)) s, 5 min in \(String(format: "%.3f", longFinish)) s; loudness stats of 5 min in \(String(format: "%.2f", Date().timeIntervalSince(statsStart))) s")
} catch {
    check(false, "limiter controls threw \(error)")
}

// MARK: - LUFS target

print("LUFS target")
check(LoudnessTarget.stepped(from: -14, by: 0.5) == -13.5 && LoudnessTarget.stepped(from: -14, by: -0.5) == -14.5
      && LoudnessTarget.stepped(from: -14, by: 0.1) == -13.9 && LoudnessTarget.stepped(from: -7.03, by: 0.5) == -7
      && LoudnessTarget.stepped(from: -7.03, by: -0.5) == -7.5 && LoudnessTarget.stepped(from: -13.9, by: 0.5) == -13.5
      && LoudnessTarget.stepped(from: -6, by: 0.5) == -6 && LoudnessTarget.stepped(from: -24, by: -0.5) == -24
      && LoudnessTarget.stepped(from: -30, by: 0.5) == -24,
      "stepping: ±0.5 and 0.1 on their grids, off-grid values go to the grid in the step's direction, clamped to −24…−6")
check(LoudnessTarget.title(-16) == "Apple Music" && LoudnessTarget.title(-14) == "YouTube"
      && LoudnessTarget.title(-14.5) == "Custom" && LoudnessTarget.title(nil) == "Reference",
      "box title follows the value")
check(Set(LoudnessTarget.platforms.map(\.lufs)).count == LoudnessTarget.platforms.count, "no two platforms share a level")
do {
    let withName = #"{"autoRelease":true,"releaseMilliseconds":200,"autoCeiling":true,"loudnessOffsetDB":0,"ceilingDB":-1,"enabled":true,"targetLUFS":-14,"targetName":"Spotify"}"#
    let decoded = try JSONDecoder().decode(LimiterSettings.self, from: Data(withName.utf8))
    check(decoded.targetLUFS == -14, "settings saved with the old targetName key still load")
} catch {
    check(false, "settings with targetName threw \(error)")
}
do {
    // Settings from before targets - and before the loudness offset was
    // dropped - still decode; the keys that went are ignored.
    let old = #"{"autoRelease":true,"releaseMilliseconds":200,"autoCeiling":true,"loudnessOffsetDB":3,"ceilingDB":-1,"enabled":false}"#
    let decoded = try JSONDecoder().decode(LimiterSettings.self, from: Data(old.utf8))
    check(decoded.targetLUFS == nil && !decoded.enabled, "settings stored before targets existed still load")
} catch {
    check(false, "old settings threw \(error)")
}
do {
    let reference = scaled(pinkStereo(seconds: 30, seed: 1), 2.5)
    try Limiter(ceiling: pow(10, -0.3 / 20)).processAll(left: reference.left, right: reference.right, count: reference.frameCount)
    let preparation = try Matcher.prepare(target: pinkStereo(seconds: 30, seed: 2), reference: reference)
    let (_, plainReport) = try Matcher.finish(preparation, settings: LimiterSettings())
    func run(_ lufs: Double, limiter: Bool = true) throws -> (StereoAudio, MatchReport, Double, TimeInterval) {
        var settings = LimiterSettings()
        settings.targetLUFS = lufs
        settings.enabled = limiter
        let start = Date()
        let (audio, report) = try Matcher.finish(preparation, settings: settings)
        let time = Date().timeIntervalSince(start)
        return (audio, report, LoudnessStats.measure(audio).integrated ?? -99, time)
    }
    for target in [-14.0, -16, -18, -8] {
        let (audio, report, measured, time) = try run(target)
        check(report.targetReached && abs(measured - target) <= 0.1 && 20 * log10(Double(audio.peak)) <= report.ceilingDB + 1e-4,
              "target \(Int(target)): measures \(String(format: "%.2f", measured)) LUFS, GR \(String(format: "%.1f", report.limiterReductionDB)) dB, \(String(format: "%.2f", time)) s")
    }
    let (_, eight, _, _) = try run(-8)
    check(eight.limiterReductionDB < plainReport.limiterReductionDB, "target −8 (louder than the reference): the limiter works harder")
    let (loudest, far, farMeasured, farTime) = try run(-3)
    check(!far.targetReached && farMeasured < -3.5 && 20 * log10(Double(loudest.peak)) <= far.ceilingDB + 1e-4,
          "target −3: not reachable, best \(String(format: "%.2f", farMeasured)) LUFS, ceiling holds, \(String(format: "%.2f", farTime)) s")
    let (_, offQuiet, offMeasured, _) = try run(-18, limiter: false)
    check(offQuiet.targetReached && abs(offMeasured + 18) <= 0.1 && offQuiet.limiterReductionDB == 0,
          "limiter off, target −18: \(String(format: "%.2f", offMeasured)) LUFS")
    let (offLoudAudio, offLoud, offLoudMeasured, _) = try run(-6, limiter: false)
    check(!offLoud.targetReached && 20 * log10(Double(offLoudAudio.peak)) <= offLoud.ceilingDB + 1e-4,
          "limiter off, target −6: not reachable (\(String(format: "%.2f", offLoudMeasured)) LUFS), ceiling holds")
    let (_, plain) = try Matcher.finish(preparation, settings: LimiterSettings())
    check(plain.targetLUFS.map { abs($0 - (LoudnessStats.measure(reference).integrated ?? 0)) < 1e-9 } == true
          && plain.targetReached,
          "no target of its own: the report names the reference's loudness as the target")
} catch {
    check(false, "LUFS target threw \(error)")
}

// MARK: - Presets

print("Presets")
do {
    let reference = scaled(pinkStereo(seconds: 30, seed: 1), 2.5)
    try Limiter(ceiling: pow(10, -0.3 / 20)).processAll(left: reference.left, right: reference.right, count: reference.frameCount)
    let target = pinkStereo(seconds: 30, seed: 2)
    let preparation = try Matcher.prepare(target: target, reference: reference)
    let (matched, report) = try Matcher.finish(preparation, settings: LimiterSettings())
    let referenceStats = LoudnessStats.measure(reference)

    // 1/12 octave: how close is the rebuilt curve to the computed one?
    var worst = 0.0
    for curve in [report.midCurveDB, report.sideCurveDB] {
        let back = MatchPreset.rebuild(MatchPreset.sample(curve))
        for k in Int(20 / MatchEQ.binHz)...Int(20_000 / MatchEQ.binHz) {
            worst = max(worst, abs(back[k] - curve[k]))
        }
    }
    check(worst <= 0.1, "1/\(Int(MatchPreset.pointsPerOctave))-octave curve: rebuilt within \(String(format: "%.3f", worst)) dB from 20 Hz to 20 kHz")

    var settings = LimiterSettings(); settings.targetLUFS = -14
    let preset = MatchPreset(name: "Loud Master", referenceName: "Reference.wav", report: report,
                             reference: referenceStats, limiter: settings,
                             autoCeilingDB: report.ceilingDB)
    let url = folder.appendingPathComponent("test.\(MatchPreset.fileExtension)")
    try preset.write(to: url)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let reloaded = try MatchPreset.read(from: url)
    check(reloaded == preset && reloaded.mid.count == MatchPreset.frequencies().count,
          "written and read back unchanged: \(reloaded.mid.count) points per curve, \(size) bytes on disk")
    check(size < 8192, "a preset file stays small (\(size) bytes)")

    // A preset from before the resolution was written into the file: 12
    // points per octave, no key for it.
    var old = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
    old.removeValue(forKey: "pointsPerOctave")
    old["mid"] = MatchPreset.sample(report.midCurveDB, perOctave: 12)
    old["side"] = MatchPreset.sample(report.sideCurveDB, perOctave: 12)
    let oldURL = folder.appendingPathComponent("old.\(MatchPreset.fileExtension)")
    try JSONSerialization.data(withJSONObject: old).write(to: oldURL)
    let loadedOld = try MatchPreset.read(from: oldURL)
    var oldWorst = 0.0
    for k in Int(20 / MatchEQ.binHz)...Int(20_000 / MatchEQ.binHz) {
        oldWorst = max(oldWorst, abs(loadedOld.midCurveDB[k] - report.midCurveDB[k]))
    }
    check(loadedOld.resolution == 12 && loadedOld.mid.count == 121 && oldWorst <= 0.2,
          "a preset saved at 1/12 octave still loads and rebuilds (\(loadedOld.mid.count) points, \(String(format: "%.2f", oldWorst)) dB)")

    // A preset applied to another target: the tone it produces, and the
    // loudness it aims at.
    let other = pinkStereo(seconds: 30, seed: 3)
    let viaPreset = try Matcher.prepare(target: other, preset: reloaded)
    let (throughPreset, presetReport) = try Matcher.finish(viaPreset, settings: LimiterSettings())
    let measured = LoudnessStats.measure(throughPreset)
    check(presetReport.targetLUFS == referenceStats.integrated && presetReport.targetReached,
          "without a target of its own it aims at the preset's reference: \(String(format: "%.2f", measured.integrated ?? 0)) LUFS")
    check(abs(presetReport.ceilingDB - report.ceilingDB) < 1e-9
          && 20 * log10(Double(throughPreset.peak)) <= presetReport.ceilingDB + 1e-4,
          "the preset carries the ceiling: \(String(format: "%.2f", presetReport.ceilingDB)) dBFS, peak below it")
    var own = LimiterSettings(); own.targetLUFS = -16
    let (atSixteen, sixteenReport) = try Matcher.finish(viaPreset, settings: own)
    let sixteen = LoudnessStats.measure(atSixteen).integrated ?? 0
    check(sixteenReport.targetReached && abs(sixteen + 16) < 0.1, "the panel's own target wins: \(String(format: "%.2f", sixteen)) LUFS")

    // The curve really is the reference's: matching `other` to the same
    // reference directly gives the same third-octave balance.
    let (direct, _) = try Matcher.match(target: other, reference: reference)
    let a = bands(direct), b = bands(throughPreset)
    let deltas = zip(b, a).map { $0 - $1 }
    let mean = deltas.reduce(0, +) / Double(deltas.count)
    let spread = deltas.map { abs($0 - mean) }.max()!
    check(spread < 0.6, "through the preset vs. straight from the reference: bands within ±\(String(format: "%.2f", spread)) dB")

    let damaged = folder.appendingPathComponent("damaged.\(MatchPreset.fileExtension)")
    try Data("{\"version\":1}".utf8).write(to: damaged)
    do {
        _ = try MatchPreset.read(from: damaged)
        check(false, "a damaged preset is refused")
    } catch {
        check(true, "a damaged preset is refused")
    }
} catch {
    check(false, "presets threw \(error)")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
