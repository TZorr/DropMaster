//
//  Decoder.swift
//  DropMaster
//
//  Any file macOS can play, in: WAV, AIFF, CAF, FLAC, ALAC, AAC/M4A, MP3.
//  Out: StereoAudio at 44.1 kHz. No ffmpeg, no decoder of our own - Core
//  Audio reads all of these, and it is already on every Mac.
//
//  Two ways in. The first is AVAudioFile plus AVAudioConverter, with the
//  converter set to its mastering-quality resampler: that is the path
//  nearly every file takes. The second is AVAssetReader, for the handful
//  of MP3s the first refuses on the very first read (half a percent of a
//  real library, measured) that the asset pipeline decodes without
//  complaint. Refusing a record the user can play in the Music app would
//  be a poor first impression for an app whose whole interface is "drop a
//  file here".
//
//  Mono comes in on both sides at full level, not -3 dB each: a mono target
//  matched to a stereo reference should be judged at the level it plays at.
//  More than two channels are folded down by the converter.
//

import Foundation
// The converter's input block runs synchronously inside `convert`, on this
// thread; AVFAudio's buffers simply predate Sendable annotations.
@preconcurrency import AVFoundation

/// What the file was before it became StereoAudio - for the drop zone.
nonisolated struct SourceInfo: Sendable, Equatable {
    var sampleRate: Double
    var channels: Int
}

nonisolated enum DecodeError: Error, LocalizedError {
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .undecodable(let name): "\(name) is not an audio file DropMaster can read."
        }
    }
}

nonisolated enum Decoder {

    static func decode(_ url: URL) throws -> (StereoAudio, SourceInfo) {
        do {
            return try convert(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try readWithAssetReader(url)
        }
    }

    // MARK: - AVAudioFile + AVAudioConverter

    /// In a function of its own: an AVAudioFile finishes its work when it is
    /// released, and Swift releases at the end of a scope, not at last use.
    private static func convert(_ url: URL) throws -> (StereoAudio, SourceInfo) {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            // Explicit processing format: the default is deinterleaved float
            // too, but saying so means a change of default can never make
            // `read(into:)` fail with a bare -50.
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw DecodeError.undecodable(name)
        }
        let inFormat = file.processingFormat
        guard inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: StereoAudio.sampleRate,
                                            channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DecodeError.undecodable(name)
        }
        if inFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        } else if inFormat.channelCount > 2 {
            converter.downmix = true
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunk: AVAudioFrameCount = 32_768
        let ratio = StereoAudio.sampleRate / inFormat.sampleRate
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096) else {
            throw DecodeError.undecodable(name)
        }

        // `length` is only a hint: a file whose writer never finished its
        // header reports 0 and still decodes. Reserve by it, never stop by it.
        let expected = Int(Double(max(file.length, 0)) * ratio) + 8192
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)

        var framesRead: AVAudioFramePosition = 0
        var finished = false
        while true {
            try Task.checkCancellation()
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // `read` throws at the end of the file rather than returning
                // zero frames, so the throw is the normal way out.
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                framesRead += AVAudioFramePosition(inBuffer.frameLength)
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw DecodeError.undecodable(name) }
            let count = Int(outBuffer.frameLength)
            if count > 0, let channels = outBuffer.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
                right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: count))
            }
            if status == .endOfStream || (finished && count == 0) { break }
        }
        // A throw on the very first read is an unreadable file, not an empty
        // one that happens to end at once.
        guard framesRead > 0, !left.isEmpty else { throw DecodeError.undecodable(name) }
        let info = SourceInfo(sampleRate: inFormat.sampleRate, channels: Int(inFormat.channelCount))
        return (StereoAudio(left: left, right: right), info)
    }

    // MARK: - AVAssetReader

    /// The way round for files ExtAudioFile refuses. Asynchronous APIs, run
    /// to completion here: the caller is already off the main thread.
    private static func readWithAssetReader(_ url: URL) throws -> (StereoAudio, SourceInfo) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Result<(StereoAudio, SourceInfo), Error>
            .failure(DecodeError.undecodable(url.lastPathComponent))
        Task.detached {
            do {
                outcome = .success(try await read(url))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    private static func read(_ url: URL) async throws -> (StereoAudio, SourceInfo) {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            throw DecodeError.undecodable(name)
        }
        var info = SourceInfo(sampleRate: StereoAudio.sampleRate, channels: 2)
        if let description = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            info = SourceInfo(sampleRate: basic.mSampleRate, channels: Int(basic.mChannelsPerFrame))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: StereoAudio.sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw DecodeError.undecodable(name) }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.undecodable(name) }

        var left: [Float] = [], right: [Float] = []
        var interleaved: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / (2 * MemoryLayout<Float>.size)
            guard frames > 0 else { continue }
            if interleaved.count < frames * 2 { interleaved = [Float](repeating: 0, count: frames * 2) }
            let copied = interleaved.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2 * MemoryLayout<Float>.size,
                                           destination: bytes.baseAddress!)
            }
            guard copied == noErr else { throw DecodeError.undecodable(name) }
            for i in 0..<frames {
                left.append(interleaved[2 * i])
                right.append(interleaved[2 * i + 1])
            }
        }
        // Only a complete read counts: a partial one would match a truncated
        // song without a word.
        guard reader.status == .completed, !left.isEmpty else { throw DecodeError.undecodable(name) }
        return (StereoAudio(left: left, right: right), info)
    }
}
