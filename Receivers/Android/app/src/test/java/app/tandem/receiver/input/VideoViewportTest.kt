package app.tandem.receiver.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Normalisation over the encoded frame, PROTOCOL.md §5.1. */
class VideoViewportTest {
    @Test
    fun `a matching aspect ratio fills the view`() {
        val viewport = VideoViewport(1000, 500, 2000, 1000)

        assertEquals(0f, viewport.left, 0f)
        assertEquals(0f, viewport.top, 0f)
        assertEquals(1000f, viewport.width, 0f)
        assertEquals(500f, viewport.height, 0f)
        assertEquals(0.5f, viewport.normalizedX(500f), 1e-6f)
        assertEquals(0.5f, viewport.normalizedY(250f), 1e-6f)
    }

    @Test
    fun `a wide video letterboxes top and bottom`() {
        // 2:1 video inside a 1:1 view: 500 px tall, centred.
        val viewport = VideoViewport(1000, 1000, 2000, 1000)

        assertEquals(0f, viewport.left, 0f)
        assertEquals(250f, viewport.top, 0f)
        assertEquals(1000f, viewport.width, 0f)
        assertEquals(500f, viewport.height, 0f)

        assertEquals(0f, viewport.normalizedY(250f), 1e-6f)
        assertEquals(0.5f, viewport.normalizedY(500f), 1e-6f)
        assertEquals(1f, viewport.normalizedY(750f), 1e-6f)
    }

    @Test
    fun `a tall video pillarboxes left and right`() {
        // 1:2 video inside a 1:1 view: 500 px wide, centred.
        val viewport = VideoViewport(1000, 1000, 1000, 2000)

        assertEquals(250f, viewport.left, 0f)
        assertEquals(0f, viewport.top, 0f)
        assertEquals(0f, viewport.normalizedX(250f), 1e-6f)
        assertEquals(1f, viewport.normalizedX(750f), 1e-6f)
    }

    @Test
    fun `points on a letterbox bar clamp to the edge of the picture`() {
        val viewport = VideoViewport(1000, 1000, 2000, 1000)

        assertEquals(0f, viewport.normalizedY(0f), 0f)
        assertEquals(1f, viewport.normalizedY(1000f), 0f)
        assertFalse(viewport.contains(500f, 100f))
        assertTrue(viewport.contains(500f, 500f))
    }

    @Test
    fun `a degenerate size stays in range instead of dividing by zero`() {
        val viewport = VideoViewport(0, 0, 0, 0)

        // A view with no size can still receive a stray event before layout;
        // the contract is a finite value in [0,1], not a particular one.
        assertTrue(viewport.normalizedX(10f) in 0f..1f)
        assertTrue(viewport.normalizedY(10f) in 0f..1f)
        assertTrue(viewport.normalizedX(-10f) in 0f..1f)
    }
}
