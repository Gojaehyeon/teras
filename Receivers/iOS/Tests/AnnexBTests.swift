import XCTest
import TerasProtocol
@testable import TerasReceiver

final class AnnexBTests: XCTestCase {

    private let startCode4 = Data([0x00, 0x00, 0x00, 0x01])
    private let startCode3 = Data([0x00, 0x00, 0x01])

    private func annexB(_ nals: [Data], startCode: Data) -> Data {
        var out = Data()
        for nal in nals {
            out.append(startCode)
            out.append(nal)
        }
        return out
    }

    // MARK: - NAL splitting

    func testSplitsFourByteStartCodes() {
        let a = Data([0x65, 0xAA, 0xBB])
        let b = Data([0x41, 0xCC])
        let units = AnnexB.nalUnits(in: annexB([a, b], startCode: startCode4))
        XCTAssertEqual(units, [a, b])
    }

    func testSplitsThreeByteStartCodes() {
        let a = Data([0x67, 0x01, 0x02, 0x03])
        let b = Data([0x68, 0x04])
        let units = AnnexB.nalUnits(in: annexB([a, b], startCode: startCode3))
        XCTAssertEqual(units, [a, b])
    }

    func testIgnoresPayloadWithoutStartCode() {
        XCTAssertTrue(AnnexB.nalUnits(in: Data([0x65, 0x01, 0x02, 0x03])).isEmpty)
        XCTAssertTrue(AnnexB.nalUnits(in: Data()).isEmpty)
    }

    func testEmulationPreventionBytesDoNotSplitNALs() {
        // 00 00 03 01 is an escaped 00 00 01 and must stay inside the NAL.
        let nal = Data([0x65, 0x00, 0x00, 0x03, 0x01, 0xFF])
        let units = AnnexB.nalUnits(in: annexB([nal], startCode: startCode4))
        XCTAssertEqual(units, [nal])
    }

    // MARK: - Parameter sets

    func testExtractsH264ParameterSets() {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let idr = Data([0x65, 0x88, 0x84])
        let sets = AnnexB.parameterSets(in: annexB([sps, pps, idr], startCode: startCode4), codec: .h264)
        XCTAssertEqual(sets.sps, sps)
        XCTAssertEqual(sets.pps, pps)
        XCTAssertNil(sets.vps)
        XCTAssertTrue(sets.isComplete(for: .h264))
        XCTAssertFalse(sets.isComplete(for: .hevc))
    }

    func testExtractsHEVCParameterSets() {
        let vps = Data([0x40, 0x01, 0x0C])     // type 32
        let sps = Data([0x42, 0x01, 0x01])     // type 33
        let pps = Data([0x44, 0x01, 0xC1])     // type 34
        let idr = Data([0x26, 0x01, 0xAF])     // type 19 (IDR_W_RADL)
        let sets = AnnexB.parameterSets(in: annexB([vps, sps, pps, idr], startCode: startCode4), codec: .hevc)
        XCTAssertEqual(sets.vps, vps)
        XCTAssertEqual(sets.sps, sps)
        XCTAssertEqual(sets.pps, pps)
        XCTAssertTrue(sets.isComplete(for: .hevc))
    }

    func testNALTypeDecoding() {
        XCTAssertEqual(AnnexB.nalType(Data([0x67]), codec: .h264), 7)
        XCTAssertEqual(AnnexB.nalType(Data([0x65]), codec: .h264), 5)
        XCTAssertEqual(AnnexB.nalType(Data([0x40]), codec: .hevc), 32)
        XCTAssertEqual(AnnexB.nalType(Data([0x26]), codec: .hevc), 19)
        XCTAssertNil(AnnexB.nalType(Data(), codec: .h264))
    }

    func testKeyframeDetection() {
        let h264 = annexB([Data([0x65, 0x01])], startCode: startCode4)
        XCTAssertTrue(AnnexB.containsKeyframe(in: h264, codec: .h264))
        let h264Delta = annexB([Data([0x41, 0x01])], startCode: startCode4)
        XCTAssertFalse(AnnexB.containsKeyframe(in: h264Delta, codec: .h264))

        let hevcCRA = annexB([Data([0x2A, 0x01])], startCode: startCode4)   // type 21
        XCTAssertTrue(AnnexB.containsKeyframe(in: hevcCRA, codec: .hevc))
        let hevcTrail = annexB([Data([0x02, 0x01])], startCode: startCode4) // type 1
        XCTAssertFalse(AnnexB.containsKeyframe(in: hevcTrail, codec: .hevc))
    }

    // MARK: - Length-prefixed conversion

    func testLengthPrefixedStripsParameterSetsAndDelimiters() {
        let aud = Data([0x09, 0xF0])
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE])
        let idr = Data([0x65, 0x88, 0x84, 0x21])
        let input = annexB([aud, sps, pps, idr], startCode: startCode4)

        let output = AnnexB.lengthPrefixed(input, codec: .h264)

        var expected = Data()
        expected.appendBigEndianUInt32(UInt32(idr.count))
        expected.append(idr)
        XCTAssertEqual(output, expected)
    }

    func testLengthPrefixedKeepsMultipleSlices() {
        let first = Data([0x41, 0x01, 0x02])
        let second = Data([0x41, 0x03])
        let input = annexB([first, second], startCode: startCode4)

        let output = AnnexB.lengthPrefixed(input, codec: .h264)

        var expected = Data()
        expected.appendBigEndianUInt32(UInt32(first.count))
        expected.append(first)
        expected.appendBigEndianUInt32(UInt32(second.count))
        expected.append(second)
        XCTAssertEqual(output, expected)
        XCTAssertEqual(output.count, 4 + first.count + 4 + second.count)
    }

    func testLengthPrefixedHEVCDropsParameterSets() {
        let vps = Data([0x40, 0x01])
        let sps = Data([0x42, 0x01])
        let pps = Data([0x44, 0x01])
        let slice = Data([0x26, 0x01, 0xAF, 0x0B])
        let output = AnnexB.lengthPrefixed(annexB([vps, sps, pps, slice], startCode: startCode4), codec: .hevc)
        XCTAssertEqual(output.count, 4 + slice.count)
        XCTAssertEqual(output.readUInt32BigEndian(at: 0), UInt32(slice.count))
    }

    func testLengthPrefixedOnParameterSetsOnlyIsEmpty() {
        let sps = Data([0x67, 0x42])
        let pps = Data([0x68, 0xCE])
        XCTAssertTrue(AnnexB.lengthPrefixed(annexB([sps, pps], startCode: startCode4), codec: .h264).isEmpty)
    }

    // MARK: - Format descriptions

    func testFormatDescriptionRequiresCompleteParameterSets() {
        var sets = AnnexB.ParameterSets()
        sets.sps = Data([0x67, 0x42, 0x00, 0x1E])
        XCTAssertNil(VideoFormatFactory.makeFormatDescription(codec: .h264, sets: sets))

        var hevcSets = AnnexB.ParameterSets()
        hevcSets.sps = Data([0x42, 0x01])
        hevcSets.pps = Data([0x44, 0x01])
        XCTAssertNil(VideoFormatFactory.makeFormatDescription(codec: .hevc, sets: hevcSets))
    }
}

private extension Data {
    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        return (UInt32(self[index]) << 24) | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8) | UInt32(self[index + 3])
    }
}
