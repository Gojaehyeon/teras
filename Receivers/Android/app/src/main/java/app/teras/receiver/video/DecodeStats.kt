package app.teras.receiver.video

/** A rolling one-second window of decoder telemetry for STATS (PROTOCOL.md §7). */
class DecodeStats {
    private val decodeMicros = ArrayList<Long>(240)
    private val e2eMicros = ArrayList<Long>(240)
    private var rendered = 0
    private var dropped = 0
    private var windowStartNanos = System.nanoTime()

    @Synchronized
    fun recordRendered(decodeMicros: Long, endToEndMicros: Long?) {
        rendered++
        if (decodeMicros >= 0) this.decodeMicros.add(decodeMicros)
        if (endToEndMicros != null && endToEndMicros >= 0) e2eMicros.add(endToEndMicros)
    }

    @Synchronized
    fun recordDropped() {
        dropped++
    }

    /** Drains the window and returns per-second rates plus p50 latencies. */
    @Synchronized
    fun takeSnapshot(queued: Int, rttMs: Double): Snapshot {
        val now = System.nanoTime()
        val seconds = ((now - windowStartNanos) / 1_000_000_000.0).coerceAtLeast(0.001)
        val snapshot =
            Snapshot(
                fpsDecoded = rendered / seconds,
                fpsDropped = dropped / seconds,
                decodeMsP50 = percentile50(decodeMicros) / 1000.0,
                e2eMsP50 = percentile50(e2eMicros) / 1000.0,
                queued = queued,
                rttMs = rttMs,
            )
        rendered = 0
        dropped = 0
        decodeMicros.clear()
        e2eMicros.clear()
        windowStartNanos = now
        return snapshot
    }

    private fun percentile50(samples: List<Long>): Double {
        if (samples.isEmpty()) return 0.0
        val sorted = samples.sorted()
        return sorted[sorted.size / 2].toDouble()
    }

    data class Snapshot(
        val fpsDecoded: Double,
        val fpsDropped: Double,
        val decodeMsP50: Double,
        val e2eMsP50: Double,
        val queued: Int,
        val rttMs: Double,
    )
}
