// Adapted from Side Screen (MIT, Copyright (c) 2025 Side Screen),
// https://github.com/tranvuongquocdat/SideScreen — see THIRD_PARTY_NOTICES.md.
// The low-latency configure fallbacks and the hardware-decoder search come from
// there; the Choreographer pacing, parameter-set injection and the Teras frame
// contract are new.
package app.teras.receiver.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import app.teras.receiver.net.VideoFrame
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MediaCodec decode of the Teras VIDEO stream onto a [Surface].
 *
 * Output buffers are released on the display's vsync rather than the instant
 * they appear: the newest frame is presented and anything older in the same
 * interval is discarded, which keeps the queue at one frame deep and the
 * picture as close to live as the panel allows.
 */
class VideoDecoder(
    private val surface: Surface,
    private val codec: String,
    private val width: Int,
    private val height: Int,
    private val refreshHz: Int,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        /** The stream is unusable until the host sends a fresh IDR/CRA. */
        fun onKeyframeNeeded(reason: String)

        /** The decoder could not be created or has failed terminally. */
        fun onFatalError(message: String)
    }

    private val mime = CodecCapabilities.mimeFor(codec)
    private val isHevc = mime == MediaFormat.MIMETYPE_VIDEO_HEVC

    private val stats = DecodeStats()
    private val running = AtomicBoolean(false)

    private var decoder: MediaCodec? = null
    private var codecThread: HandlerThread? = null
    private var codecHandler: Handler? = null

    private var vsyncThread: HandlerThread? = null
    private var vsyncHandler: Handler? = null
    private var choreographer: Choreographer? = null

    private val availableInputBuffers = ConcurrentLinkedQueue<Int>()
    private val pendingOutput = ConcurrentLinkedQueue<PendingFrame>()
    private val inFlight = java.util.concurrent.ConcurrentHashMap<Long, Submission>()

    /**
     * Bumped on every teardown. A MediaCodec callback captures the generation
     * it was installed for, so a callback already in flight when the decoder is
     * released cannot touch buffers belonging to a codec that is going away.
     */
    @Volatile private var generation = 0

    @Volatile private var needsKeyframe = true

    @Volatile private var csdSent = false

    @Volatile private var hostClockOffsetMicros: Long? = null

    private var lastKeyframeRequestNanos = 0L
    private var nextPresentationMicros = 0L

    private data class Submission(val submittedNanos: Long, val captureMicros: Long)

    private data class PendingFrame(val index: Int, val presentationMicros: Long)

    /**
     * Builds and starts the codec.
     *
     * @throws IllegalStateException when no decoder on the device can be
     *   configured for this stream; the caller should tear the session down.
     */
    fun start() {
        if (!running.compareAndSet(false, true)) return
        try {
            setupDecoder()
            startVsyncPacing()
        } catch (e: Exception) {
            running.set(false)
            releaseInternals()
            throw IllegalStateException("cannot start a $codec decoder at ${width}x$height", e)
        }
    }

    /** Host clock offset from PONG, used to report end-to-end latency. */
    fun setHostClockOffsetMicros(offsetMicros: Long) {
        hostClockOffsetMicros = offsetMicros
    }

    fun snapshot(rttMs: Double): DecodeStats.Snapshot =
        stats.takeSnapshot(queued = pendingOutput.size + inFlight.size, rttMs = rttMs)

    // --------------------------------------------------------------- decoding

    /** Feeds one VIDEO frame (PROTOCOL.md §4). Never blocks the reader thread. */
    fun submit(frame: VideoFrame) {
        if (!running.get()) return
        val codec = decoder ?: return

        if (frame.isDiscontinuity) {
            flushForDiscontinuity(codec)
        }

        if (needsKeyframe && !frame.isKeyframe) {
            stats.recordDropped()
            requestKeyframe("waiting for a keyframe")
            return
        }

        if (frame.hasParameterSets && !csdSent) {
            // The keyframe carries its parameter sets inline, but handing them
            // over separately with BUFFER_FLAG_CODEC_CONFIG is what decoders
            // that ignore inline sets need to lock on.
            ParameterSets.extract(
                frame.accessUnit,
                frame.accessUnitOffset,
                frame.accessUnitLength,
                isHevc,
            )?.let { csd ->
                val ok =
                    queueRaw(codec, csd.csd0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG) &&
                        (csd.csd1?.let { queueRaw(codec, it, MediaCodec.BUFFER_FLAG_CODEC_CONFIG) } ?: true)
                if (ok) csdSent = true
            }
        }

        val index = availableInputBuffers.poll()
        if (index == null) {
            // The input pool is exhausted, typically a burst over WiFi. Keep the
            // pipeline moving and rebuild the reference from a forced keyframe
            // rather than freezing until the queue drains.
            stats.recordDropped()
            requestKeyframe("no input buffer", force = true)
            return
        }

        // Presentation timestamps are ours, not the host's: they only have to be
        // monotonic for MediaCodec, and using them as the map key ties an output
        // buffer back to the moment it was submitted.
        val presentationMicros = ++nextPresentationMicros
        inFlight[presentationMicros] = Submission(System.nanoTime(), frame.captureTimestampUs)
        // A frame the codec swallows without producing output would otherwise
        // leave its entry behind; timestamps only increase, so anything this
        // far back is gone for good.
        if (inFlight.size > MAX_IN_FLIGHT) {
            val cutoff = presentationMicros - MAX_IN_FLIGHT
            inFlight.keys.removeAll { it <= cutoff }
        }

        try {
            val buffer = codec.getInputBuffer(index) ?: throw IllegalStateException("null input buffer")
            buffer.clear()
            buffer.put(frame.accessUnit, frame.accessUnitOffset, frame.accessUnitLength)
            codec.queueInputBuffer(index, 0, frame.accessUnitLength, presentationMicros, 0)
            if (frame.isKeyframe) needsKeyframe = false
        } catch (e: Exception) {
            inFlight.remove(presentationMicros)
            stats.recordDropped()
            needsKeyframe = true
            requestKeyframe("queueInputBuffer failed: ${e.message}", force = true)
            Log.w(TAG, "queueInputBuffer failed", e)
        }
    }

    private fun queueRaw(codec: MediaCodec, data: ByteArray, flags: Int): Boolean {
        val index = availableInputBuffers.poll() ?: return false
        return try {
            val buffer = codec.getInputBuffer(index) ?: return false
            buffer.clear()
            buffer.put(data)
            codec.queueInputBuffer(index, 0, data.size, 0, flags)
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not queue codec config", e)
            false
        }
    }

    private fun flushForDiscontinuity(codec: MediaCodec) {
        try {
            codec.flush()
            // flush() invalidates every buffer the callback handed us.
            availableInputBuffers.clear()
            pendingOutput.clear()
            inFlight.clear()
            codec.start()
        } catch (e: Exception) {
            Log.w(TAG, "flush after discontinuity failed", e)
        }
        needsKeyframe = true
        requestKeyframe("stream discontinuity", force = true)
    }

    private fun requestKeyframe(reason: String, force: Boolean = false) {
        val now = System.nanoTime()
        val interval = if (force) FORCE_KEYFRAME_INTERVAL_NS else KEYFRAME_INTERVAL_NS
        if (now - lastKeyframeRequestNanos < interval) return
        lastKeyframeRequestNanos = now
        callbacks.onKeyframeNeeded(reason)
    }

    // ---------------------------------------------------------------- pacing

    private fun startVsyncPacing() {
        val thread =
            HandlerThread("teras-vsync", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
        vsyncThread = thread
        val handler = Handler(thread.looper)
        vsyncHandler = handler
        handler.post {
            choreographer = Choreographer.getInstance()
            choreographer?.postFrameCallback(frameCallback)
        }
    }

    private val frameCallback =
        object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                if (!running.get()) return
                presentNewest(frameTimeNanos)
                choreographer?.postFrameCallback(this)
            }
        }

    /**
     * Presents the newest frame available at this vsync and discards the rest:
     * the stream has no B-frames, so an older buffer is only ever a frame the
     * panel already missed.
     */
    private fun presentNewest(frameTimeNanos: Long) {
        val codec = decoder ?: return
        var newest: PendingFrame? = null
        while (true) {
            val next = pendingOutput.poll() ?: break
            newest?.let { stale ->
                releaseQuietly(codec, stale.index, render = false)
                inFlight.remove(stale.presentationMicros)
                stats.recordDropped()
            }
            newest = next
        }
        val frame = newest ?: return

        val submission = inFlight.remove(frame.presentationMicros)
        try {
            codec.releaseOutputBuffer(frame.index, frameTimeNanos)
        } catch (e: Exception) {
            Log.w(TAG, "releaseOutputBuffer failed", e)
            stats.recordDropped()
            return
        }

        if (submission != null) {
            val decodeMicros = (System.nanoTime() - submission.submittedNanos) / 1_000L
            val e2e =
                hostClockOffsetMicros?.let { offset ->
                    // captureTimestampUs is on the host clock; shift it onto ours.
                    (System.nanoTime() / 1_000L) - (submission.captureMicros - offset)
                }
            stats.recordRendered(decodeMicros, e2e?.takeIf { it in 0..MAX_PLAUSIBLE_E2E_US })
        } else {
            stats.recordRendered(-1, null)
        }
    }

    private fun releaseQuietly(codec: MediaCodec, index: Int, render: Boolean) {
        try {
            codec.releaseOutputBuffer(index, render)
        } catch (_: Exception) {
            // The buffer is gone with the codec; nothing to release.
        }
    }

    // ------------------------------------------------------------- decoder set-up

    private fun setupDecoder() {
        val thread =
            HandlerThread("teras-decoder", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
        codecThread = thread
        val handler = Handler(thread.looper)
        codecHandler = handler

        val name = findBestDecoder()
        val codec =
            if (name != null) MediaCodec.createByCodecName(name) else MediaCodec.createDecoderByType(mime)

        val myGeneration = generation
        val callback =
            object : MediaCodec.Callback() {
                private val isCurrent: Boolean
                    get() = running.get() && generation == myGeneration

                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    if (!isCurrent) return
                    availableInputBuffers.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    if (!isCurrent) {
                        // The codec is being torn down; the buffer dies with it.
                        return
                    }
                    if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 || info.size == 0) {
                        releaseQuietly(codec, index, render = false)
                        return
                    }
                    pendingOutput.offer(PendingFrame(index, info.presentationTimeUs))
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    if (!isCurrent) return
                    Log.e(TAG, "codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    if (e.isRecoverable) {
                        try {
                            codec.stop()
                            codec.start()
                            availableInputBuffers.clear()
                            pendingOutput.clear()
                            inFlight.clear()
                        } catch (restartFailure: Exception) {
                            Log.e(TAG, "codec restart failed", restartFailure)
                            callbacks.onFatalError("decoder restart failed: ${restartFailure.message}")
                            return
                        }
                    } else if (!e.isTransient) {
                        callbacks.onFatalError("decoder failed: ${e.diagnosticInfo}")
                        return
                    }
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    if (!isCurrent) return
                    Log.i(TAG, "output format: $format")
                }
            }
        codec.setCallback(callback, handler)

        var configured = false
        // Attempt 1: full low-latency configuration.
        try {
            codec.configure(buildFormat(lowLatency = true), surface, null, 0)
            configured = true
        } catch (e: Exception) {
            Log.w(TAG, "low-latency configure failed: ${e.message}")
            codec.reset()
            codec.setCallback(callback, handler)
        }

        // Attempt 2: priority hint only.
        if (!configured) {
            try {
                codec.configure(buildFormat(lowLatency = false), surface, null, 0)
                configured = true
            } catch (e: Exception) {
                Log.w(TAG, "basic configure failed: ${e.message}")
                codec.reset()
                codec.setCallback(callback, handler)
            }
        }

        // Attempt 3: bare resolution.
        if (!configured) {
            codec.configure(MediaFormat.createVideoFormat(mime, width, height), surface, null, 0)
        }

        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        codec.start()
        decoder = codec
        needsKeyframe = true
        csdSent = false
        Log.i(TAG, "decoder started: $mime ${width}x$height @ ${refreshHz}Hz (${name ?: "default"})")
    }

    private fun buildFormat(lowLatency: Boolean): MediaFormat =
        MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            if (lowLatency) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setInteger(MediaFormat.KEY_OPERATING_RATE, refreshHz.coerceIn(24, 240))
            }
        }

    /** Prefers a hardware decoder that advertises the panel's rate at this size. */
    private fun findBestDecoder(): String? {
        return try {
            val targetRate = refreshHz.toDouble().coerceAtLeast(30.0)
            var hwRate: String? = null
            var hwSize: String? = null
            var swRate: String? = null
            var swSize: String? = null

            for (info in MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos) {
                if (info.isEncoder) continue
                val caps =
                    try {
                        info.getCapabilitiesForType(mime)
                    } catch (_: Exception) {
                        continue
                    }
                val videoCaps = caps.videoCapabilities ?: continue
                val isHardware =
                    !info.name.startsWith("c2.android.") && !info.name.startsWith("OMX.google.")
                if (!videoCaps.isSizeSupported(width, height)) continue
                val rateSupported =
                    try {
                        videoCaps.areSizeAndRateSupported(width, height, targetRate)
                    } catch (_: Exception) {
                        false
                    }
                when {
                    isHardware && rateSupported && hwRate == null -> hwRate = info.name
                    isHardware && hwSize == null -> hwSize = info.name
                    !isHardware && rateSupported && swRate == null -> swRate = info.name
                    !isHardware && swSize == null -> swSize = info.name
                }
            }
            hwRate ?: hwSize ?: swRate ?: swSize
        } catch (e: Exception) {
            Log.w(TAG, "decoder search failed", e)
            null
        }
    }

    // ------------------------------------------------------------------ teardown

    /**
     * Tears the decoder down and does not return until both worker threads have
     * stopped, so the caller can drop the [Surface] safely. Idempotent: a second
     * call, including one racing the first, is a no-op.
     */
    fun release() {
        if (!running.compareAndSet(true, false)) return
        releaseInternals()
    }

    private fun releaseInternals() {
        // Invalidate every callback still queued before touching the codec.
        generation++

        // 1. Stop the pacer and join its looper, so no frame callback can run
        //    against buffers that are about to be freed.
        val vsync = vsyncThread
        vsyncHandler?.post { choreographer?.removeFrameCallback(frameCallback) }
        vsync?.quitSafely()
        joinQuietly(vsync)
        vsyncThread = null
        vsyncHandler = null
        choreographer = null

        // 2. Stop the codec, which ends callback delivery, then join the thread
        //    those callbacks run on. Only then is release() safe: doing it
        //    while a callback is mid-flight is a use-after-free.
        val codec = decoder
        decoder = null
        try {
            codec?.stop()
        } catch (e: Exception) {
            // A codec already in an error state throws here; release still frees it.
            Log.d(TAG, "stop() failed during release", e)
        }

        val worker = codecThread
        worker?.quitSafely()
        joinQuietly(worker)
        codecThread = null
        codecHandler = null

        try {
            codec?.release()
        } catch (e: Exception) {
            // Nothing further can be done for a codec that will not release.
            Log.d(TAG, "release() failed", e)
        }

        availableInputBuffers.clear()
        pendingOutput.clear()
        inFlight.clear()
    }

    private fun joinQuietly(thread: HandlerThread?) {
        if (thread == null || thread === Thread.currentThread()) return
        try {
            thread.join(THREAD_JOIN_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private companion object {
        const val TAG = "TerasVideoDecoder"
        const val KEYFRAME_INTERVAL_NS = 1_000_000_000L

        /**
         * Floor for the forced path too. A decoder error storm can raise
         * hundreds of callbacks a second, and an unthrottled request per error
         * would flood the host with KEYFRAME_REQUEST frames.
         */
        const val FORCE_KEYFRAME_INTERVAL_NS = 500_000_000L
        const val THREAD_JOIN_MS = 500L
        const val MAX_PLAUSIBLE_E2E_US = 2_000_000L
        const val MAX_IN_FLIGHT = 64
    }
}
