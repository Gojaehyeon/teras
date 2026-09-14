package app.tandem.receiver.input

/**
 * Maps a point in the display view onto normalised video coordinates.
 *
 * PROTOCOL.md §5.1 normalises input over the *encoded video frame*, so the
 * letterbox bars an aspect-fit layout leaves at the sides or top must be
 * subtracted first. Pure arithmetic, so the mapping is covered by JVM tests.
 */
data class VideoViewport(
    val viewWidth: Int,
    val viewHeight: Int,
    val videoWidth: Int,
    val videoHeight: Int,
) {
    /** Left edge of the video inside the view, in view pixels. */
    val left: Float
    val top: Float
    val width: Float
    val height: Float

    init {
        if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) {
            left = 0f
            top = 0f
            width = viewWidth.toFloat().coerceAtLeast(1f)
            height = viewHeight.toFloat().coerceAtLeast(1f)
        } else {
            val viewAspect = viewWidth.toFloat() / viewHeight
            val videoAspect = videoWidth.toFloat() / videoHeight
            if (videoAspect > viewAspect) {
                // Wider than the view: full width, bars top and bottom.
                width = viewWidth.toFloat()
                height = viewWidth / videoAspect
                left = 0f
                top = (viewHeight - height) / 2f
            } else {
                height = viewHeight.toFloat()
                width = viewHeight * videoAspect
                top = 0f
                left = (viewWidth - width) / 2f
            }
        }
    }

    /**
     * Normalises a view-space x to `[0,1]` over the video. Clamped, so a drag
     * that runs into the letterbox still reaches the edge of the desktop rather
     * than jumping.
     */
    fun normalizedX(viewX: Float): Float = (((viewX - left) / width)).coerceIn(0f, 1f)

    fun normalizedY(viewY: Float): Float = (((viewY - top) / height)).coerceIn(0f, 1f)

    /** True when the point is inside the picture rather than on a letterbox bar. */
    fun contains(viewX: Float, viewY: Float): Boolean =
        viewX >= left && viewX <= left + width && viewY >= top && viewY <= top + height
}
