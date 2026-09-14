package app.teras.receiver.video

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Annex-B scanning, PROTOCOL.md §4. */
class ParameterSetsTest {
    private val start = byteArrayOf(0, 0, 0, 1)

    private fun avcNal(type: Int, vararg body: Byte): ByteArray =
        start + byteArrayOf(type.toByte()) + body

    private fun hevcNal(type: Int, vararg body: Byte): ByteArray =
        start + byteArrayOf((type shl 1).toByte(), 1) + body

    @Test
    fun `scan splits four byte start codes`() {
        val data = avcNal(7, 1, 2) + avcNal(8, 3) + avcNal(5, 4, 5, 6)
        val nals = ParameterSets.scan(data, 0, data.size)

        assertEquals(3, nals.size)
        assertEquals(7, ParameterSets.avcNalType(data[nals[0].offset]))
        assertEquals(8, ParameterSets.avcNalType(data[nals[1].offset]))
        assertEquals(5, ParameterSets.avcNalType(data[nals[2].offset]))
        assertEquals(3, nals[0].length)
        assertEquals(4, nals[2].length)
    }

    @Test
    fun `scan tolerates three byte start codes`() {
        val data = byteArrayOf(0, 0, 1, 0x67, 9) + byteArrayOf(0, 0, 1, 0x68, 8)
        val nals = ParameterSets.scan(data, 0, data.size)

        assertEquals(2, nals.size)
        assertEquals(3, nals[0].startCodeLength)
    }

    @Test
    fun `avc extraction splits sps into csd zero and pps into csd one`() {
        val sps = avcNal(7, 0x42, 0x00)
        val pps = avcNal(8, 0xCE.toByte())
        val idr = avcNal(5, 1, 2, 3)
        val data = sps + pps + idr

        val csd = ParameterSets.extract(data, 0, data.size, isHevc = false)
        assertNotNull(csd)
        assertArrayEquals(sps, csd!!.csd0)
        assertArrayEquals(pps, csd.csd1)
    }

    @Test
    fun `hevc extraction concatenates vps sps and pps into csd zero`() {
        val vps = hevcNal(32, 1)
        val sps = hevcNal(33, 2)
        val pps = hevcNal(34, 3)
        val idr = hevcNal(19, 9, 9)
        val data = vps + sps + pps + idr

        val csd = ParameterSets.extract(data, 0, data.size, isHevc = true)
        assertNotNull(csd)
        assertArrayEquals(vps + sps + pps, csd!!.csd0)
        assertNull(csd.csd1)
    }

    @Test
    fun `extraction honours the offset into a larger buffer`() {
        val header = ByteArray(13) { 0x7F }
        val sps = avcNal(7, 1)
        val pps = avcNal(8, 2)
        val data = header + sps + pps

        val csd = ParameterSets.extract(data, header.size, data.size - header.size, isHevc = false)
        assertArrayEquals(sps, csd!!.csd0)
    }

    @Test
    fun `a unit without parameter sets yields nothing`() {
        val data = avcNal(1, 1, 2, 3)
        assertNull(ParameterSets.extract(data, 0, data.size, isHevc = false))
    }

    @Test
    fun `hevc and avc type extraction read different bit fields`() {
        assertEquals(33, ParameterSets.hevcNalType((33 shl 1).toByte()))
        assertEquals(7, ParameterSets.avcNalType(0x67.toByte()))
    }
}
