package app.tandem.receiver.video

/**
 * Pulls VPS/SPS/PPS out of an Annex-B access unit so they can be handed to
 * MediaCodec as codec-specific data.
 *
 * PROTOCOL.md §4 guarantees 4-byte start codes only and that keyframes are
 * prefixed with their parameter sets, so the scan can stay simple. It still
 * tolerates 3-byte start codes, because a host that emits them is a far more
 * likely failure than a device that cannot parse them.
 */
object ParameterSets {
    /** Codec-specific data for one access unit: `csd-0` and, for AVC, `csd-1`. */
    data class Csd(val csd0: ByteArray, val csd1: ByteArray?) {
        override fun equals(other: Any?): Boolean =
            this === other ||
                (
                    other is Csd && csd0.contentEquals(other.csd0) &&
                        (csd1?.contentEquals(other.csd1 ?: ByteArray(0)) ?: (other.csd1 == null))
                )

        override fun hashCode(): Int = csd0.contentHashCode() * 31 + (csd1?.contentHashCode() ?: 0)
    }

    /** One NAL unit: the offsets span the payload, excluding its start code. */
    data class Nal(val offset: Int, val length: Int, val startCodeLength: Int)

    /** Splits an Annex-B buffer into NAL units. */
    fun scan(data: ByteArray, from: Int, length: Int): List<Nal> {
        val end = from + length
        val nals = ArrayList<Nal>(8)
        var i = from
        var currentStart = -1
        var currentStartCode = 0

        while (i < end) {
            val startCodeLength = startCodeLengthAt(data, i, end)
            if (startCodeLength > 0) {
                if (currentStart >= 0) {
                    nals.add(Nal(currentStart, i - currentStart, currentStartCode))
                }
                currentStart = i + startCodeLength
                currentStartCode = startCodeLength
                i += startCodeLength
            } else {
                i++
            }
        }
        if (currentStart in 0 until end) {
            nals.add(Nal(currentStart, end - currentStart, currentStartCode))
        }
        return nals
    }

    private fun startCodeLengthAt(data: ByteArray, i: Int, end: Int): Int {
        if (i + 3 < end &&
            data[i].toInt() == 0 && data[i + 1].toInt() == 0 &&
            data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1
        ) {
            return 4
        }
        if (i + 2 < end &&
            data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1
        ) {
            return 3
        }
        return 0
    }

    /** HEVC NAL type, bits 1..6 of the first header byte. */
    fun hevcNalType(firstByte: Byte): Int = (firstByte.toInt() shr 1) and 0x3F

    /** AVC NAL type, the low 5 bits of the first header byte. */
    fun avcNalType(firstByte: Byte): Int = firstByte.toInt() and 0x1F

    private const val HEVC_VPS = 32
    private const val HEVC_SPS = 33
    private const val HEVC_PPS = 34
    private const val AVC_SPS = 7
    private const val AVC_PPS = 8

    /**
     * Extracts codec-specific data from an access unit, or null when it carries
     * no parameter sets.
     *
     * HEVC wants VPS‖SPS‖PPS in `csd-0`; AVC wants SPS in `csd-0` and PPS in
     * `csd-1`. Start codes are kept, which is what MediaCodec expects.
     */
    fun extract(data: ByteArray, from: Int, length: Int, isHevc: Boolean): Csd? {
        val nals = scan(data, from, length)
        if (nals.isEmpty()) return null

        val startCode = byteArrayOf(0, 0, 0, 1)
        val hevcSets = ArrayList<ByteArray>(3)
        var avcSps: ByteArray? = null
        var avcPps: ByteArray? = null

        for (nal in nals) {
            if (nal.length <= 0) continue
            val type =
                if (isHevc) hevcNalType(data[nal.offset]) else avcNalType(data[nal.offset])
            val keep =
                if (isHevc) {
                    type == HEVC_VPS || type == HEVC_SPS || type == HEVC_PPS
                } else {
                    type == AVC_SPS || type == AVC_PPS
                }
            if (!keep) continue
            val unit = startCode + data.copyOfRange(nal.offset, nal.offset + nal.length)
            if (isHevc) {
                hevcSets.add(unit)
            } else if (type == AVC_SPS) {
                avcSps = unit
            } else {
                avcPps = unit
            }
        }

        return if (isHevc) {
            if (hevcSets.isEmpty()) null else Csd(hevcSets.reduce { a, b -> a + b }, null)
        } else {
            val sps = avcSps ?: return null
            Csd(sps, avcPps)
        }
    }
}
