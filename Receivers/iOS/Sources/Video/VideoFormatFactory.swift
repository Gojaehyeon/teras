import Foundation
import CoreMedia
import TerasProtocol

/// Builds `CMVideoFormatDescription` values from Annex-B parameter sets.
enum VideoFormatFactory {

    static func makeFormatDescription(codec: Codec, sets: AnnexB.ParameterSets) -> CMVideoFormatDescription? {
        switch codec {
        case .h264:
            guard let sps = sets.sps, let pps = sets.pps else { return nil }
            return make(parameterSets: [sps, pps], codec: .h264)
        case .hevc:
            guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps else { return nil }
            return make(parameterSets: [vps, sps, pps], codec: .hevc)
        }
    }

    private static func make(parameterSets: [Data], codec: Codec) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }

        // Copy into stable storage: the CoreMedia call keeps no ownership, but
        // the pointers must stay valid for the duration of the call.
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var sizes: [Int] = []
        buffers.reserveCapacity(parameterSets.count)
        sizes.reserveCapacity(parameterSets.count)
        defer { buffers.forEach { $0.deallocate() } }

        for set in parameterSets {
            guard !set.isEmpty else { return nil }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            buffers.append(buffer)
            sizes.append(set.count)
        }

        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        var description: CMVideoFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                guard let pointerBase = pointerBuffer.baseAddress, let sizeBase = sizeBuffer.baseAddress else {
                    return OSStatus(-1)
                }
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description)
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description)
                }
            }
        }
        guard status == noErr else { return nil }
        return description
    }

    /// Wraps length-prefixed sample data in a ready-to-display sample buffer.
    static func makeSampleBuffer(data: Data,
                                 formatDescription: CMVideoFormatDescription,
                                 presentationTime: CMTime) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: data.count,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: data.count,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: block,
                                           formatDescription: formatDescription,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sample = sampleBuffer else { return nil }

        // Display as soon as the frame arrives: there is no playback clock and
        // no B-frames (PROTOCOL §4).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            for index in 0..<count {
                let raw = CFArrayGetValueAtIndex(attachments, index)
                guard let raw else { continue }
                let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
