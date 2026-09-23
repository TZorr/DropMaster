//
//  MP3Encoder.swift
//  DropMaster
//
//  The right box of the diagram for the one format Core Audio cannot write.
//
//  This is a thin shell over libmp3lame: set the input rate and channel
//  count, pick CBR or VBR from the Quality choice, then push Float32 chunks
//  through `lame_encode_buffer_ieee_float` and append whatever bytes come
//  back. LAME's `ieee_float` entry point takes samples already in ±1.0, which
//  is exactly what the decoder hands us — no scaling in between.
//
//  Two details that are easy to get wrong:
//
//  * The file must be opened for *reading as well as writing*. After the
//    stream is flushed, LAME's Info/Xing tag is written back over a
//    placeholder frame it reserved at offset 0; `lame_get_lametag_frame`
//    hands us those bytes and we seek back to overwrite them. Skip that and
//    players show no duration and cannot seek accurately.
//
//  * MP3 is MPEG-1/2 audio: mono or stereo only, and 8–48 kHz. A source
//    outside that range is resampled by LAME on the way in (`out_samplerate`
//    below); more channels than two is refused rather than silently folded.
//
//  libmp3lame is compiled into the app from DropMaster/LAME.
//

import Foundation
import AVFoundation

nonisolated final class MP3Encoder: AudioEncoder {

    private var gfp: OpaquePointer?
    private let handle: FileHandle
    private let channelCount: Int
    private var mp3Buffer = [UInt8](repeating: 0, count: 1 << 16)

    private static let mpegSampleRates: Set<Int> =
        [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    init(destination: URL, quality: QualityOption, sourceFormat: AVAudioFormat) throws {
        channelCount = Int(sourceFormat.channelCount)
        guard channelCount == 1 || channelCount == 2 else {
            throw ConversionError.encoderSetupFailed("MP3 supports mono or stereo only; this file has \(channelCount) channels.")
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forUpdating: destination) else {
            throw ConversionError.encoderSetupFailed("Could not create the MP3 file.")
        }
        self.handle = handle

        guard let gfp = lame_init() else {
            throw ConversionError.encoderSetupFailed("LAME would not initialise.")
        }
        self.gfp = gfp

        let inRate = Int(sourceFormat.sampleRate.rounded())
        let outRate = Self.mpegSampleRates.contains(inRate)
            ? inRate
            : (inRate > 48000 ? 48000 : 44100)

        lame_set_in_samplerate(gfp, Int32(inRate))
        lame_set_out_samplerate(gfp, Int32(outRate))
        lame_set_num_channels(gfp, Int32(channelCount))
        lame_set_mode(gfp, channelCount == 1 ? MONO : JOINT_STEREO)
        lame_set_quality(gfp, 2)   // LAME's own "near best, still fast" setting
        lame_set_bWriteVbrTag(gfp, 1)

        switch quality.kind {
        case .constantBitrate(let kbps):
            lame_set_VBR(gfp, vbr_off)
            lame_set_brate(gfp, Int32(kbps))
        case .variableBitrate(let v):
            lame_set_VBR(gfp, vbr_mtrh)
            lame_set_VBR_q(gfp, Int32(v))
        case .bitDepth:
            throw ConversionError.encoderSetupFailed("Bit depth is not an MP3 setting.")
        }

        guard lame_init_params(gfp) >= 0 else {
            throw ConversionError.encoderSetupFailed("LAME rejected these settings.")
        }
    }

    // MARK: AudioEncoder

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let gfp, let channels = buffer.floatChannelData else { return }
        let frames = Int32(buffer.frameLength)
        guard frames > 0 else { return }

        let left = channels[0]
        let right = channelCount > 1 ? channels[1] : channels[0]

        // Worst case LAME output is 1.25 * samples + 7200 bytes; grow if a
        // large chunk ever needs it.
        let needed = Int(Double(buffer.frameLength) * 1.25) + 7200
        if mp3Buffer.count < needed { mp3Buffer = [UInt8](repeating: 0, count: needed) }

        let written = mp3Buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_buffer_ieee_float(gfp, left, right, frames, out.baseAddress, Int32(out.count))
        }
        guard written >= 0 else {
            throw ConversionError.encodeFailed("LAME encode error \(written).")
        }
        if written > 0 {
            handle.write(Data(mp3Buffer[0..<Int(written)]))
        }
    }

    func finish() throws {
        guard let gfp else { return }

        let flushed = mp3Buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_flush(gfp, out.baseAddress, Int32(out.count))
        }
        if flushed > 0 {
            handle.write(Data(mp3Buffer[0..<Int(flushed)]))
        }

        // Replace the reserved leading frame with the real Info/Xing tag.
        var tag = [UInt8](repeating: 0, count: 4096)
        let tagSize = tag.withUnsafeMutableBufferPointer { buf in
            lame_get_lametag_frame(gfp, buf.baseAddress, buf.count)
        }
        if tagSize > 0 && tagSize <= tag.count {
            try? handle.seek(toOffset: 0)
            handle.write(Data(tag[0..<tagSize]))
        }

        try? handle.close()
        lame_close(gfp)
        self.gfp = nil
    }

    func cancel() {
        try? handle.close()
        if let gfp {
            lame_close(gfp)
            self.gfp = nil
        }
    }
}
