package app.tandem.receiver

import android.app.Application
import android.util.Log
import android.view.Surface
import app.tandem.receiver.discovery.NsdAdvertiser
import app.tandem.receiver.input.InputSink
import app.tandem.receiver.net.DeviceProfile
import app.tandem.receiver.net.Hello
import app.tandem.receiver.net.KeyEvent
import app.tandem.receiver.net.Protocol
import app.tandem.receiver.net.SessionListener
import app.tandem.receiver.net.StatsSnapshot
import app.tandem.receiver.net.StatsSource
import app.tandem.receiver.net.StreamConfig
import app.tandem.receiver.net.TandemConnection
import app.tandem.receiver.net.TandemServer
import app.tandem.receiver.net.TouchPointer
import app.tandem.receiver.net.VideoFrame
import app.tandem.receiver.store.PairedHostStore
import app.tandem.receiver.store.Settings
import app.tandem.receiver.store.SharedPreferencesHostStore
import app.tandem.receiver.video.CodecCapabilities
import app.tandem.receiver.video.DecodeStats
import app.tandem.receiver.video.VideoDecoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Where the receiver is in its session lifecycle, as the UI sees it. */
enum class ReceiverPhase { IDLE, PAIRING, CONNECTED, STREAMING }

/** Everything the UI renders. */
data class ReceiverUiState(
    val phase: ReceiverPhase = ReceiverPhase.IDLE,
    val deviceName: String = "",
    val listening: Boolean = false,
    val listenError: String? = null,
    val network: NetworkStatus = NetworkStatus(false, null),
    val pin: String? = null,
    val attemptsLeft: Int = Protocol.PAIR_MAX_ATTEMPTS,
    val hostName: String? = null,
    val streamConfig: StreamConfig? = null,
    val stats: DecodeStats.Snapshot? = null,
    val encrypted: Boolean = false,
    val lastError: String? = null,
    val showStats: Boolean = false,
    val keepScreenOn: Boolean = true,
    val pairedHostCount: Int = 0,
)

/**
 * Owns the listening socket, the decoder and the Bonjour registration, and
 * turns session callbacks into UI state.
 *
 * Session callbacks arrive on the connection's reader thread, so all mutable
 * state here is either a [MutableStateFlow] or guarded by [decoderLock].
 */
class ReceiverController(
    private val application: Application,
    val settings: Settings = Settings(application),
    private val store: PairedHostStore = SharedPreferencesHostStore(application),
) : SessionListener, StatsSource {
    private val _state = MutableStateFlow(ReceiverUiState())
    val state: StateFlow<ReceiverUiState> = _state.asStateFlow()

    private val advertiser = NsdAdvertiser(application)

    private val decoderLock = Any()
    private var decoder: VideoDecoder? = null
    private var surface: Surface? = null
    private var pendingConfig: StreamConfig? = null

    @Volatile private var connection: TandemConnection? = null

    @Volatile private var lastSurfaceKeyframeRequestNanos = 0L

    private val server =
        TandemServer(
            store = store,
            profileProvider = ::deviceProfile,
            listener = this,
            statsSource = this,
        ).apply {
            onSessionStarted = { conn -> connection = conn }
            onSessionEnded = { conn, reason -> onSessionEnded(conn, reason) }
            onListenFailed = { error ->
                _state.update { it.copy(listening = false, listenError = error.message) }
            }
        }

    /** The input path used by the display view. */
    val inputSink: InputSink =
        object : InputSink {
            override fun touch(phase: Byte, pointers: List<TouchPointer>) {
                connection?.session?.sendTouch(phase, pointers)
            }

            override fun scroll(x: Float, y: Float, dx: Float, dy: Float, phase: Byte) {
                connection?.session?.sendScroll(x, y, dx, dy, phase)
            }

            override fun pointer(kind: Byte, button: Byte, x: Float, y: Float) {
                connection?.session?.sendPointer(kind, button, x, y)
            }

            override fun key(event: KeyEvent) {
                connection?.session?.sendKey(event)
            }
        }

    // ------------------------------------------------------------------ startup

    fun start() {
        refreshSettingsState()
        server.start()
        _state.update {
            it.copy(
                listening = server.isListening,
                listenError = if (server.isListening) null else it.listenError,
            )
        }
        advertiser.register(store.deviceId(), settings.deviceName)
        refreshNetwork()
    }

    fun stop() {
        advertiser.unregister()
        server.stop()
        releaseDecoder()
        connection = null
        _state.update {
            it.copy(
                phase = ReceiverPhase.IDLE,
                listening = false,
                pin = null,
                streamConfig = null,
                stats = null,
                hostName = null,
            )
        }
    }

    fun refreshNetwork() {
        _state.update { it.copy(network = NetworkProbe.current(application)) }
    }

    fun refreshSettingsState() {
        _state.update {
            it.copy(
                deviceName = settings.deviceName,
                showStats = settings.showStats,
                keepScreenOn = settings.keepScreenOn,
                pairedHostCount = store.pairedHostIds().size,
            )
        }
    }

    fun setDeviceName(name: String) {
        settings.deviceName = name
        refreshSettingsState()
        advertiser.register(store.deviceId(), settings.deviceName)
    }

    fun setShowStats(show: Boolean) {
        settings.showStats = show
        refreshSettingsState()
    }

    fun toggleShowStats() = setShowStats(!settings.showStats)

    fun setKeepScreenOn(keep: Boolean) {
        settings.keepScreenOn = keep
        refreshSettingsState()
    }

    fun forgetPairedHosts() {
        store.forgetAll()
        refreshSettingsState()
    }

    // ------------------------------------------------------------------- surface

    /** Called when the display view's surface appears or goes away. */
    fun attachSurface(newSurface: Surface?) {
        synchronized(decoderLock) {
            // surfaceChanged fires repeatedly for the same surface; building a
            // second decoder onto it would strand the first one.
            if (newSurface === surface && (newSurface == null || decoder != null)) return
            surface = newSurface
            releaseDecoderLocked()
            if (newSurface == null) return
            pendingConfig?.let { startDecoderLocked(it) }
        }
    }

    /** Rotation or a resize: tell the host to rebuild its virtual display. */
    fun onDeviceConfigurationChanged() {
        val session = connection?.session ?: return
        session.sendDeviceConfig(
            DeviceMetrics.orientation(application),
            DeviceMetrics.screenInfo(application),
        )
    }

    // ------------------------------------------------------------ SessionListener

    override fun onHello(hello: Hello) {
        _state.update {
            it.copy(
                phase = ReceiverPhase.CONNECTED,
                hostName = hello.hostName.ifBlank { hello.hostId },
                lastError = null,
            )
        }
    }

    override fun onPinRequired(pin: String, attemptsLeft: Int) {
        _state.update {
            it.copy(phase = ReceiverPhase.PAIRING, pin = pin, attemptsLeft = attemptsLeft)
        }
    }

    override fun onPinDismissed() {
        _state.update { it.copy(pin = null) }
    }

    override fun onPaired(hostId: String) {
        refreshSettingsState()
    }

    override fun onAuthenticated(hostId: String, encrypted: Boolean) {
        _state.update { it.copy(phase = ReceiverPhase.CONNECTED, encrypted = encrypted, pin = null) }
    }

    override fun onStreamConfig(config: StreamConfig) {
        synchronized(decoderLock) {
            val existing = decoder
            val unchanged = pendingConfig?.decoderIdentity() == config.decoderIdentity()
            pendingConfig = config
            // §3.4: only codec or frame size force a reset.
            if (existing != null && unchanged) return@synchronized
            releaseDecoderLocked()
            if (surface != null) startDecoderLocked(config)
        }
        _state.update { it.copy(phase = ReceiverPhase.STREAMING, streamConfig = config) }
    }

    override fun onVideo(frame: VideoFrame) {
        val active = synchronized(decoderLock) { decoder }
        if (active == null) {
            // The surface is not up yet. Ask for a keyframe so the picture
            // appears the moment it is, but not once per arriving frame.
            val now = System.nanoTime()
            if (now - lastSurfaceKeyframeRequestNanos > KEYFRAME_REQUEST_INTERVAL_NS) {
                lastSurfaceKeyframeRequestNanos = now
                connection?.session?.sendKeyframeRequest()
            }
            return
        }
        active.submit(frame)
    }

    override fun onRoundTrip(rttMicros: Long, hostClockOffsetMicros: Long) {
        synchronized(decoderLock) { decoder }?.setHostClockOffsetMicros(hostClockOffsetMicros)
    }

    override fun onBye(reason: String) {
        Log.i(TAG, "host said goodbye: $reason")
    }

    override fun onProtocolError(message: String) {
        Log.w(TAG, "protocol error: $message")
        _state.update { it.copy(lastError = message) }
    }

    // ---------------------------------------------------------------- StatsSource

    override fun snapshot(rttMs: Double): StatsSnapshot? {
        val active = synchronized(decoderLock) { decoder } ?: return null
        val snapshot = active.snapshot(rttMs)
        _state.update { it.copy(stats = snapshot) }
        return StatsSnapshot(
            fpsDecoded = snapshot.fpsDecoded,
            fpsDropped = snapshot.fpsDropped,
            decodeMsP50 = snapshot.decodeMsP50,
            queued = snapshot.queued,
            rttMs = snapshot.rttMs,
            e2eMsP50 = snapshot.e2eMsP50,
        )
    }

    // --------------------------------------------------------------------- inner

    private fun onSessionEnded(ended: TandemConnection, reason: String) {
        if (connection !== ended) return
        connection = null
        releaseDecoder()
        synchronized(decoderLock) { pendingConfig = null }
        _state.update {
            it.copy(
                phase = ReceiverPhase.IDLE,
                pin = null,
                hostName = null,
                streamConfig = null,
                stats = null,
                encrypted = false,
            )
        }
        Log.i(TAG, "session ended: $reason")
    }

    private fun startDecoderLocked(config: StreamConfig) {
        val target = surface ?: return
        if (!target.isValid) return
        val refresh = DeviceMetrics.screenInfo(application).refreshHz
        val created =
            try {
                VideoDecoder(
                    surface = target,
                    codec = config.codec,
                    width = config.wPx,
                    height = config.hPx,
                    refreshHz = refresh,
                    callbacks =
                        object : VideoDecoder.Callbacks {
                            override fun onKeyframeNeeded(reason: String) {
                                connection?.session?.sendKeyframeRequest()
                            }

                            override fun onFatalError(message: String) {
                                _state.update { it.copy(lastError = message) }
                                connection?.shutdownGracefully("decoder failed: $message")
                            }
                        },
                ).apply { start() }
            } catch (e: IllegalStateException) {
                Log.e(TAG, "decoder start failed", e)
                _state.update { it.copy(lastError = e.message) }
                connection?.shutdownGracefully("no usable decoder for ${config.codec}")
                null
            }
        decoder = created
        // A decoder that appears after the stream started has missed the host's
        // opening keyframe.
        if (created != null) connection?.session?.sendKeyframeRequest()
    }

    private fun releaseDecoder() = synchronized(decoderLock) { releaseDecoderLocked() }

    private fun releaseDecoderLocked() {
        decoder?.release()
        decoder = null
    }

    private fun deviceProfile(): DeviceProfile {
        val (maxW, maxH) = CodecCapabilities.maxDecodeSize()
        return DeviceProfile(
            deviceId = store.deviceId(),
            deviceName = settings.deviceName,
            model = DeviceMetrics.model(),
            screen = DeviceMetrics.screenInfo(application),
            orientation = DeviceMetrics.orientation(application),
            codecs = CodecCapabilities.preferredCodecs(),
            maxDecodeWidth = maxW,
            maxDecodeHeight = maxH,
            features = FEATURES,
        )
    }

    private companion object {
        const val TAG = "ReceiverController"
        const val KEYFRAME_REQUEST_INTERVAL_NS = 500_000_000L
        val FEATURES = listOf("touch", "pencil", "keyboard", "scroll", "hover")
    }
}
