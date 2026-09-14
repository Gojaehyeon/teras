// Adapted from Side Screen (MIT, Copyright (c) 2025 Side Screen),
// https://github.com/tranvuongquocdat/SideScreen — see THIRD_PARTY_NOTICES.md.
package app.teras.receiver.video

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * One-shot decoder capability probe feeding HELLO_ACK's `codecs` preference
 * order and `maxDecode` (PROTOCOL.md §3.2).
 *
 * "Has HEVC" means a *usable hardware* HEVC decoder, not merely one that
 * advertises the type. Two classes of device are routed to H.264 instead:
 * software-only HEVC (far too slow for a live desktop), and vendor hardware
 * HEVC that configures and starts but never renders to a Surface (Unisoc).
 * Both have a working hardware H.264 decoder.
 */
object CodecCapabilities {
    const val CODEC_HEVC = "hevc"
    const val CODEC_H264 = "h264"

    /** Decoder-name prefixes whose HEVC path never renders to a Surface. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    private const val BLOCK_ALIGN = 16

    /** Wire codec name to the MediaFormat mime type. */
    fun mimeFor(codec: String): String =
        when (codec.lowercase()) {
            CODEC_HEVC, "h265", "hvc1" -> MediaFormat.MIMETYPE_VIDEO_HEVC
            CODEC_H264, "avc", "avc1" -> MediaFormat.MIMETYPE_VIDEO_AVC
            else -> MediaFormat.MIMETYPE_VIDEO_AVC
        }

    private fun isUsableHardwareDecoder(info: MediaCodecInfo, mime: String): Boolean {
        if (info.isEncoder) return false
        if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return false
        val name = info.name.lowercase()
        val isSoftware = name.startsWith("c2.android.") || name.startsWith("omx.google.")
        val isBrokenHevc =
            mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
                BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
        return !isSoftware && !isBrokenHevc
    }

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any {
                isUsableHardwareDecoder(it, MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
        } catch (_: Exception) {
            false // fail closed: H.264 works everywhere, a bad HEVC guess shows black
        }
    }

    val hasAvcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any {
                isUsableHardwareDecoder(it, MediaFormat.MIMETYPE_VIDEO_AVC)
            }
        } catch (_: Exception) {
            true
        }
    }

    /** HELLO_ACK `codecs`, most preferred first. */
    fun preferredCodecs(): List<String> =
        buildList {
            if (hasHevcDecoder) add(CODEC_HEVC)
            add(CODEC_H264)
        }

    /**
     * HELLO_ACK `maxDecode`: the largest frame any usable hardware decoder
     * advertises across the codecs we offer. Falls back to 1080p, which every
     * API 26 device can decode, when the probe fails.
     */
    fun maxDecodeSize(): Pair<Int, Int> {
        val sizes = preferredCodecs().mapNotNull { nominalMaxDecodeSize(mimeFor(it)) }
        if (sizes.isEmpty()) return 1920 to 1080
        return sizes.maxByOrNull { it.first.toLong() * it.second.toLong() }!!
    }

    private val nominalSizeCache = HashMap<String, Pair<Int, Int>?>()

    /**
     * The `size` limit the largest usable hardware decoder for [mime] advertises.
     *
     * Nominal, not achievable: vendor decoders routinely advertise a size far
     * above what their blocks-per-second budget sustains. Use [maxStreamSize]
     * for anything the host will actually encode.
     */
    fun nominalMaxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(nominalSizeCache) {
            nominalSizeCache.getOrPut(mime.lowercase()) {
                bestVideoCapabilities(mime)?.let {
                    it.supportedWidths.upper to it.supportedHeights.upper
                }
            }
        }

    private fun bestVideoCapabilities(mime: String): MediaCodecInfo.VideoCapabilities? =
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS)
                .codecInfos
                .asSequence()
                .filter { isUsableHardwareDecoder(it, mime) }
                .mapNotNull { info ->
                    try {
                        info.getCapabilitiesForType(mime).videoCapabilities
                    } catch (_: Exception) {
                        null
                    }
                }
                .maxByOrNull { it.supportedWidths.upper.toLong() * it.supportedHeights.upper.toLong() }
        } catch (_: Exception) {
            null
        }

    /**
     * The largest frame the host should encode: no larger than the panel can
     * show and within what the decoder sustains at [fps]. Shrinks stepwise
     * because the decode budget counts aligned macroblocks, and null when no
     * usable decoder exists.
     */
    fun maxStreamSize(mime: String, panelWidth: Int, panelHeight: Int, fps: Int): Pair<Int, Int>? {
        if (panelWidth <= 0 || panelHeight <= 0) return null
        val caps = bestVideoCapabilities(mime) ?: return null
        val rate = fps.coerceAtLeast(1).toDouble()

        var w = panelWidth.coerceAtMost(caps.supportedWidths.upper)
        var h = panelHeight.coerceAtMost(caps.supportedHeights.upper)
        val aspect = panelWidth.toDouble() / panelHeight.toDouble()

        repeat(40) {
            val alignedW = (w / BLOCK_ALIGN) * BLOCK_ALIGN
            val alignedH = (h / BLOCK_ALIGN) * BLOCK_ALIGN
            if (alignedW < 256 || alignedH < 256) return null
            val supported =
                try {
                    caps.areSizeAndRateSupported(alignedW, alignedH, rate)
                } catch (_: IllegalArgumentException) {
                    false
                } catch (_: Exception) {
                    return null
                }
            if (supported) return alignedW to alignedH
            w = (w * 0.95).toInt()
            h = (w / aspect).toInt()
        }
        return null
    }
}
