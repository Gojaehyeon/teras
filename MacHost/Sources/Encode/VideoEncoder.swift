import CoreMedia
import CoreVideo
import Foundation
import TerasProtocol
import VideoToolbox
import os

//
//  Adapted from SideScreen (MIT licence) — MacHost/Sources/VideoEncoder.swift.
//  Copyright (c) SideScreen contributors. See THIRD_PARTY_NOTICES.md.
//

/// One encoded access unit, ready to become a VIDEO frame.
struct EncodedFrame: Sendable {
    var annexB: Data
    var isKeyframe: Bool
    var hasParameterSets: Bool
    var captureTimestampUs: UInt64
}

enum VideoEncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "VideoToolbox could not create a compression session (status \(status))."
        }
    }
}

/// VideoToolbox HEVC/H.264 encoder tuned for real-time screen streaming:
/// no frame reordering, no frame delay, one keyframe per second, and Annex-B
/// output with the parameter sets carried on every keyframe so a receiver can
/// join the stream at any IDR.
final class VideoEncoder: @unchecked Sendable {
    private struct State {
        var forceKeyframe = false
    }

    let codec: Codec
    let width: Int
    let height: Int
    let fps: Int

    private var session: VTCompressionSession?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let callbackLock = OSAllocatedUnfairLock(initialState: 0)

    /// Invoked on VideoToolbox's callback thread. Keep the work here short.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    init(width: Int, height: Int, codec: Codec, fps: Int, bitrateBps: Int) throws {
        self.width = width
        self.height = height
        self.codec = codec
        self.fps = max(1, fps)

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }
        session = created
        configure(session: created, bitrateBps: bitrateBps)
        VTCompressionSessionPrepareToEncodeFrames(created)

        Log.info(.encode, "Encoder ready: \(codec.rawValue) \(width)x\(height) @ \(self.fps)fps, "
                 + "\(bitrateBps / 1_000_000) Mbps")
    }

    deinit {
        invalidate()
    }

    private func configure(session: VTCompressionSession, bitrateBps: Int) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                Log.debug(.encode, "Encoder property \(key) rejected (status \(status))")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Main profile decodes on every hardware decoder we care about; High
        // adds tools some low-end Android OMX decoders refuse.
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrateBps as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // One keyframe per second: enough to recover quickly from a decoder
        // reset without paying for an all-intra stream.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1.0 as CFNumber)
        // No B-frames and no frame delay: the receiver displays in arrival order.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        // Tag the bitstream BT.709 so every receiver's YUV→RGB conversion
        // matches what we captured instead of guessing.
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    /// Change the target bitrate without rebuilding the session.
    func setBitrate(_ bitrateBps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
    }

    /// Make the next encoded picture an IDR. Used when a receiver asks for one
    /// and after we drop frames, so its decoder can resynchronise immediately.
    func requestKeyframe() {
        state.withLock { $0.forceKeyframe = true }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, captureTimestampUs: UInt64) {
        guard let session else { return }

        let force = state.withLock { current -> Bool in
            guard current.forceKeyframe else { return false }
            current.forceKeyframe = false
            return true
        }
        let properties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        // The capture timestamp rides along with the frame so the receiver can
        // measure true glass-to-glass latency.
        let refcon = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        refcon.storeBytes(of: captureTimestampUs, as: UInt64.self)

        let pts = CMTime(value: CMTimeValue(captureTimestampUs), timescale: 1_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: properties,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )
        if status != noErr {
            refcon.deallocate()
            Log.error(.encode, "VTCompressionSessionEncodeFrame failed (status \(status))")
        }
    }

    func invalidate() {
        guard let session else { return }
        self.session = nil
        onEncodedFrame = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    fileprivate func deliver(_ frame: EncodedFrame) {
        onEncodedFrame?(frame)
    }
}

private let annexBStartCode: [UInt8] = [0, 0, 0, 1]

/// Pull the parameter sets (VPS/SPS/PPS for HEVC, SPS/PPS for H.264) out of a
/// format description as Annex-B NAL units.
private func parameterSets(from formatDescription: CMFormatDescription, codec: Codec) -> Data {
    var count = 0
    let countStatus: OSStatus = codec == .hevc
        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0,
                                                             parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                             parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0,
                                                             parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                             parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
    guard countStatus == noErr, count > 0 else {
        Log.error(.encode, "Could not read parameter sets (status \(countStatus))")
        return Data()
    }

    var out = Data()
    for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: index,
                                                                 parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                 parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: index,
                                                                 parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                 parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer, size > 0 else { continue }
        out.append(contentsOf: annexBStartCode)
        out.append(pointer, count: size)
    }
    return out
}

/// Convert the length-prefixed NAL units VideoToolbox produces into Annex-B.
private func annexB(from dataPointer: UnsafeMutablePointer<Int8>, length: Int) -> Data {
    var out = Data(capacity: length + 64)
    var offset = 0
    while offset + 4 <= length {
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        let size = Int(UInt32(bigEndian: nalLength))
        offset += 4
        guard size > 0, offset + size <= length else { break }
        out.append(contentsOf: annexBStartCode)
        dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: size) { bytes in
            out.append(bytes, count: size)
        }
        offset += size
    }
    return out
}

private let encoderOutputCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, _, sampleBuffer in
    let captureUs: UInt64
    if let sourceFrameRefcon {
        captureUs = sourceFrameRefcon.load(as: UInt64.self)
        sourceFrameRefcon.deallocate()
    } else {
        captureUs = monotonicMicros()
    }

    guard let refcon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    guard status == noErr, let sampleBuffer else {
        if status != noErr { Log.error(.encode, "Encode callback status \(status)") }
        return
    }
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                      lengthAtOffsetOut: &lengthAtOffset,
                                      totalLengthOut: &totalLength,
                                      dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
          let dataPointer, totalLength > 0 else { return }

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    let isKeyframe = !notSync

    var payload = Data()
    var hasParameterSets = false
    if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
        let sets = parameterSets(from: formatDescription, codec: encoder.codec)
        if !sets.isEmpty {
            payload.append(sets)
            hasParameterSets = true
        }
    }
    payload.append(annexB(from: dataPointer, length: totalLength))
    guard !payload.isEmpty else { return }

    encoder.deliver(EncodedFrame(annexB: payload,
                                 isKeyframe: isKeyframe,
                                 hasParameterSets: hasParameterSets,
                                 captureTimestampUs: captureUs))
}
