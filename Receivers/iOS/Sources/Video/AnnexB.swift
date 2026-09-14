import Foundation
import TerasProtocol

/// Annex-B bitstream helpers.
///
/// The host sends one access unit per VIDEO frame, Annex-B framed
/// (PROTOCOL §4). VideoToolbox wants AVCC/HVCC: length-prefixed NAL units
/// plus a `CMVideoFormatDescription` built from the parameter sets. This type
/// does the byte-level half of that conversion and is deliberately free of
/// CoreMedia so it can be unit tested on its own.
enum AnnexB {

    /// Parameter sets carried by a keyframe access unit.
    struct ParameterSets: Equatable {
        var vps: Data?
        var sps: Data?
        var pps: Data?

        var isCompleteH264: Bool { sps != nil && pps != nil }
        var isCompleteHEVC: Bool { vps != nil && sps != nil && pps != nil }

        func isComplete(for codec: Codec) -> Bool {
            switch codec {
            case .h264: return isCompleteH264
            case .hevc: return isCompleteHEVC
            }
        }
    }

    /// NAL unit payloads (start codes stripped), in stream order.
    /// Accepts both 4-byte and 3-byte start codes; the protocol mandates
    /// 4-byte but tolerating 3-byte costs nothing and avoids a black screen
    /// if an encoder emits them.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }

        var starts: [(index: Int, codeLength: Int)] = []
        var i = 0
        let n = bytes.count
        while i + 2 < n {
            if bytes[i] == 0x00 && bytes[i + 1] == 0x00 {
                if bytes[i + 2] == 0x01 {
                    starts.append((i + 3, 3))
                    i += 3
                    continue
                }
                if i + 3 < n && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01 {
                    starts.append((i + 4, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }

        var units: [Data] = []
        units.reserveCapacity(starts.count)
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].index - starts[offset + 1].codeLength : n
            guard end > start.index else { continue }
            units.append(Data(bytes[start.index..<end]))
        }
        return units
    }

    /// NAL unit type as defined by the codec's NAL header.
    static func nalType(_ nal: Data, codec: Codec) -> UInt8? {
        guard let first = nal.first else { return nil }
        switch codec {
        case .h264:
            return first & 0x1F
        case .hevc:
            return (first >> 1) & 0x3F
        }
    }

    enum H264NAL {
        static let idr: UInt8 = 5
        static let sei: UInt8 = 6
        static let sps: UInt8 = 7
        static let pps: UInt8 = 8
        static let accessUnitDelimiter: UInt8 = 9
    }

    enum HEVCNAL {
        static let idrWRadl: UInt8 = 19
        static let idrNLP: UInt8 = 20
        static let cra: UInt8 = 21
        static let vps: UInt8 = 32
        static let sps: UInt8 = 33
        static let pps: UInt8 = 34
        static let accessUnitDelimiter: UInt8 = 35
    }

    static func isParameterSet(type: UInt8, codec: Codec) -> Bool {
        switch codec {
        case .h264: return type == H264NAL.sps || type == H264NAL.pps
        case .hevc: return type == HEVCNAL.vps || type == HEVCNAL.sps || type == HEVCNAL.pps
        }
    }

    static func isAccessUnitDelimiter(type: UInt8, codec: Codec) -> Bool {
        switch codec {
        case .h264: return type == H264NAL.accessUnitDelimiter
        case .hevc: return type == HEVCNAL.accessUnitDelimiter
        }
    }

    static func isKeyframe(type: UInt8, codec: Codec) -> Bool {
        switch codec {
        case .h264: return type == H264NAL.idr
        case .hevc: return type == HEVCNAL.idrWRadl || type == HEVCNAL.idrNLP || type == HEVCNAL.cra
        }
    }

    /// Extracts the last parameter set of each kind found in the access unit.
    static func parameterSets(in data: Data, codec: Codec) -> ParameterSets {
        var sets = ParameterSets()
        for nal in nalUnits(in: data) {
            guard let type = nalType(nal, codec: codec) else { continue }
            switch codec {
            case .h264:
                if type == H264NAL.sps { sets.sps = nal }
                if type == H264NAL.pps { sets.pps = nal }
            case .hevc:
                if type == HEVCNAL.vps { sets.vps = nal }
                if type == HEVCNAL.sps { sets.sps = nal }
                if type == HEVCNAL.pps { sets.pps = nal }
            }
        }
        return sets
    }

    /// True if the access unit contains a keyframe slice.
    static func containsKeyframe(in data: Data, codec: Codec) -> Bool {
        for nal in nalUnits(in: data) {
            if let type = nalType(nal, codec: codec), isKeyframe(type: type, codec: codec) { return true }
        }
        return false
    }

    /// Converts an Annex-B access unit into length-prefixed (4-byte, big
    /// endian) sample data. Parameter sets and access unit delimiters are
    /// dropped: the former belong in the format description, the latter carry
    /// no picture data.
    static func lengthPrefixed(_ data: Data, codec: Codec) -> Data {
        var out = Data(capacity: data.count)
        for nal in nalUnits(in: data) {
            guard let type = nalType(nal, codec: codec) else { continue }
            if isParameterSet(type: type, codec: codec) { continue }
            if isAccessUnitDelimiter(type: type, codec: codec) { continue }
            out.appendBigEndianUInt32(UInt32(nal.count))
            out.append(nal)
        }
        return out
    }
}

extension Data {
    /// Local big-endian append; `TerasProtocol`'s equivalent is internal to
    /// that module.
    mutating func appendBigEndianUInt32(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
