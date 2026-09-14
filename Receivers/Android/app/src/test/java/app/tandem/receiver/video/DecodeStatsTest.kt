package app.tandem.receiver.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The STATS window of PROTOCOL.md §7. */
class DecodeStatsTest {
    @Test
    fun `p50 is the median of the window`() {
        val stats = DecodeStats()
        listOf(1_000L, 5_000L, 3_000L, 9_000L, 2_000L).forEach { stats.recordRendered(it, null) }

        val snapshot = stats.takeSnapshot(queued = 2, rttMs = 1.5)
        assertEquals(3.0, snapshot.decodeMsP50, 0.001)
        assertEquals(2, snapshot.queued)
        assertEquals(1.5, snapshot.rttMs, 0.001)
        assertTrue(snapshot.fpsDecoded > 0.0)
    }

    @Test
    fun `the window resets after a snapshot`() {
        val stats = DecodeStats()
        stats.recordRendered(1_000L, 20_000L)
        stats.recordDropped()
        stats.takeSnapshot(0, 0.0)

        val second = stats.takeSnapshot(0, 0.0)
        assertEquals(0.0, second.fpsDecoded, 0.001)
        assertEquals(0.0, second.fpsDropped, 0.001)
        assertEquals(0.0, second.decodeMsP50, 0.001)
        assertEquals(0.0, second.e2eMsP50, 0.001)
    }

    @Test
    fun `an empty window reports zero rather than dividing by zero`() {
        val snapshot = DecodeStats().takeSnapshot(0, 0.0)
        assertEquals(0.0, snapshot.decodeMsP50, 0.0)
        assertEquals(0.0, snapshot.fpsDecoded, 0.0)
    }
}
