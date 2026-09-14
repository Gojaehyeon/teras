package app.teras.receiver.net

import app.teras.receiver.crypto.CryptoPrimitives
import app.teras.receiver.crypto.PairingCrypto
import app.teras.receiver.crypto.SessionCipher
import app.teras.receiver.store.PairedHostStore
import org.json.JSONArray
import org.json.JSONObject

/** The session lifecycle of PROTOCOL.md §8. */
enum class SessionState {
    AWAITING_HELLO,
    AWAITING_PAIR,
    AWAITING_AUTH,
    AWAITING_STREAM_CONFIG,
    READY,
    STREAMING,
    CLOSED,
}

/** Everything the state machine does to the outside world. */
interface SessionOutput {
    /** Queue one frame for the peer; the transport wraps it in ENC when armed. */
    fun send(type: Byte, payload: ByteArray)

    /** Arm the ENC envelope for both directions, effective from the next frame. */
    fun armEncryption(cipher: SessionCipher)

    /** Tear the connection down. */
    fun close(reason: String)
}

/** Session events the UI and the video pipeline care about. */
interface SessionListener {
    fun onHello(hello: Hello) {}

    /** A PIN must be shown to the user; [attemptsLeft] counts host tries. */
    fun onPinRequired(pin: String, attemptsLeft: Int) {}

    fun onPinDismissed() {}

    fun onPaired(hostId: String) {}

    fun onAuthenticated(hostId: String, encrypted: Boolean) {}

    fun onStreamConfig(config: StreamConfig) {}

    fun onVideo(frame: VideoFrame) {}

    /**
     * A PONG came back. [hostClockOffsetMicros] converts our monotonic clock to
     * the host's: `hostTime = ourTime + offset`, which is what turns a VIDEO
     * frame's `captureTimestampUs` into a glass-to-glass latency.
     */
    fun onRoundTrip(rttMicros: Long, hostClockOffsetMicros: Long) {}

    fun onBye(reason: String) {}

    fun onProtocolError(message: String) {}
}

/**
 * The receiver half of the Teras handshake and session, PROTOCOL.md §3 and §8.
 *
 * Deliberately free of Android and of sockets: it is fed frames and emits
 * frames, so the whole lifecycle including pairing and the switch to the
 * encrypted envelope is covered by plain JVM tests.
 *
 * Not internally synchronised — the transport calls [handle] from its single
 * reader thread and the timers call the `send*` helpers, all of which only
 * touch the output, so mutation stays on the reader thread.
 */
class SessionStateMachine(
    private val store: PairedHostStore,
    private val profileProvider: () -> DeviceProfile,
    private val output: SessionOutput,
    private val listener: SessionListener,
    /** False for a LAN peer; a USB peer always arrives over adb's loopback forward. */
    private val peerIsLoopback: Boolean,
    private val pinGenerator: () -> String = PairingCrypto::randomPin,
    private val nonceGenerator: () -> ByteArray = PairingCrypto::randomNonce,
    private val secretGenerator: () -> ByteArray = PairingCrypto::randomSecret,
) {
    var state: SessionState = SessionState.AWAITING_HELLO
        private set

    var hello: Hello? = null
        private set

    private var deviceNonce: ByteArray = ByteArray(0)
    private var currentPin: String? = null
    private var attemptsLeft: Int = Protocol.PAIR_MAX_ATTEMPTS
    private var authRequired: Boolean = true
    private var streamConfig: StreamConfig? = null

    /** Dispatches one inbound frame. Unknown types are skipped (PROTOCOL.md §9). */
    fun handle(type: Byte, payload: ByteArray) {
        if (state == SessionState.CLOSED) return
        try {
            when (type) {
                MessageType.HELLO -> handleHello(payload)
                MessageType.PAIR -> handlePair(payload)
                MessageType.AUTH -> handleAuth(payload)
                MessageType.STREAM_CONFIG -> handleStreamConfig(payload)
                MessageType.VIDEO -> handleVideo(payload)
                MessageType.PING -> handlePing(payload)
                MessageType.PONG -> handlePong(payload)
                MessageType.BYE -> handleBye(payload)
                else -> Unit // forward compatible: length prefix makes skipping safe
            }
        } catch (e: ProtocolException) {
            fail(e.message ?: "protocol error")
        }
    }

    // ---------------------------------------------------------------- handshake

    private fun handleHello(payload: ByteArray) {
        if (state != SessionState.AWAITING_HELLO) throw ProtocolException("unexpected HELLO in $state")
        val parsed = Hello.parse(payload)
        if (parsed.pv < 1) throw ProtocolException("unsupported protocol version ${parsed.pv}")
        hello = parsed
        listener.onHello(parsed)

        deviceNonce = nonceGenerator()
        // A peer that is not on loopback cannot be a USB peer: adb forwards to
        // 127.0.0.1. Trusting hello.transport alone would let anything on the
        // LAN claim "usb" and skip pairing entirely.
        authRequired = !(parsed.isUsb && peerIsLoopback)
        val paired = store.isPaired(parsed.hostId)

        output.send(MessageType.HELLO_ACK, helloAckJson(parsed, paired))

        state =
            when {
                !authRequired -> SessionState.AWAITING_STREAM_CONFIG
                paired -> SessionState.AWAITING_AUTH
                else -> {
                    beginPairing()
                    SessionState.AWAITING_PAIR
                }
            }
    }

    private fun helloAckJson(hello: Hello, paired: Boolean): ByteArray {
        val profile = profileProvider()
        val codecs = JSONArray().apply { profile.codecs.forEach { put(it) } }
        val features = JSONArray().apply { profile.features.forEach { put(it) } }
        val json =
            JSONObject()
                .put("pv", minOf(Protocol.VERSION, hello.pv))
                .put("deviceId", profile.deviceId)
                .put("deviceName", profile.deviceName)
                .put("platform", Protocol.PLATFORM)
                .put("model", profile.model)
                .put("deviceNonce", Json.encodeBase64(deviceNonce))
                .put("screen", profile.screen.toJson())
                .put("orientation", profile.orientation.wire)
                .put("codecs", codecs)
                .put(
                    "maxDecode",
                    JSONObject().put("w", profile.maxDecodeWidth).put("h", profile.maxDecodeHeight),
                )
                .put("features", features)
                .put("paired", paired)
                .put("authRequired", authRequired)
        return Json.bytes(json)
    }

    private fun beginPairing() {
        attemptsLeft = Protocol.PAIR_MAX_ATTEMPTS
        val pin = pinGenerator()
        currentPin = pin
        listener.onPinRequired(pin, attemptsLeft)
        output.send(
            MessageType.PAIR_REQUIRED,
            Json.bytes(JSONObject().put("attemptsLeft", attemptsLeft)),
        )
    }

    private fun handlePair(payload: ByteArray) {
        // A host that lost its secret sees paired = true and cannot AUTH. Letting
        // PAIR restart pairing from AWAITING_AUTH gives it a recovery path
        // without the receiver ever discarding a secret on an unauthenticated
        // peer's say-so (PROTOCOL.md §3.3 keeps the stored secret on AUTH_FAIL).
        if (state == SessionState.AWAITING_AUTH) {
            beginPairing()
            state = SessionState.AWAITING_PAIR
            return
        }
        if (state != SessionState.AWAITING_PAIR) throw ProtocolException("unexpected PAIR in $state")

        val currentHello = hello ?: throw ProtocolException("PAIR before HELLO")
        val pin = currentPin ?: throw ProtocolException("PAIR with no PIN in flight")
        val proof = Json.base64(Json.obj(payload), "proof")
        val profile = profileProvider()
        val expected =
            PairingCrypto.pairProof(
                PairingCrypto.pinKey(pin, profile.deviceId, currentHello.hostId),
                currentHello.hostNonce,
                deviceNonce,
            )

        if (!CryptoPrimitives.constantTimeEquals(proof, expected)) {
            attemptsLeft--
            val locked = attemptsLeft <= 0
            output.send(
                MessageType.PAIR_FAIL,
                Json.bytes(
                    JSONObject()
                        .put("attemptsLeft", maxOf(attemptsLeft, 0))
                        .put("locked", locked),
                ),
            )
            if (locked) {
                // Rotate so a watcher who saw the PIN cannot retry on reconnect.
                currentPin = pinGenerator()
                listener.onPinDismissed()
                output.close("pairing failed ${Protocol.PAIR_MAX_ATTEMPTS} times")
                state = SessionState.CLOSED
            } else {
                listener.onPinRequired(pin, attemptsLeft)
            }
            return
        }

        val secret = secretGenerator()
        store.store(currentHello.hostId, secret)
        currentPin = null
        listener.onPinDismissed()
        listener.onPaired(currentHello.hostId)

        val box =
            PairingCrypto.sealPairBox(
                PairingCrypto.pinKey(pin, profile.deviceId, currentHello.hostId),
                currentHello.hostNonce,
                deviceNonce,
                secret,
            )
        output.send(MessageType.PAIR_OK, Json.bytes(JSONObject().put("box", Json.encodeBase64(box))))
        state = SessionState.AWAITING_AUTH
    }

    private fun handleAuth(payload: ByteArray) {
        if (state != SessionState.AWAITING_AUTH) throw ProtocolException("unexpected AUTH in $state")
        val currentHello = hello ?: throw ProtocolException("AUTH before HELLO")
        val secret = store.secretFor(currentHello.hostId)
        if (secret == null) {
            authFail("no secret stored for this host")
            return
        }

        val proof = Json.base64(Json.obj(payload), "proof")
        val expected = PairingCrypto.authProof(secret, currentHello.hostNonce, deviceNonce)
        if (!CryptoPrimitives.constantTimeEquals(proof, expected)) {
            authFail("auth proof mismatch")
            return
        }

        val ack = PairingCrypto.authAckProof(secret, currentHello.hostNonce, deviceNonce)
        output.send(MessageType.AUTH_OK, Json.bytes(JSONObject().put("proof", Json.encodeBase64(ack))))

        // §3.3.3: the envelope starts with the very next frame each side sends,
        // so AUTH_OK above is the last plaintext frame.
        if (currentHello.encrypt) {
            output.armEncryption(
                SessionCipher.forReceiver(secret, currentHello.hostNonce, deviceNonce),
            )
        }
        listener.onAuthenticated(currentHello.hostId, currentHello.encrypt)
        state = SessionState.AWAITING_STREAM_CONFIG
    }

    private fun authFail(reason: String) {
        // The stored secret survives: a wrong proof from an unauthenticated peer
        // must not be able to unpair a host (PROTOCOL.md §3.3.4).
        output.send(MessageType.AUTH_FAIL, Json.bytes(JSONObject().put("reason", reason)))
        output.close(reason)
        state = SessionState.CLOSED
    }

    // ------------------------------------------------------------------ stream

    private fun handleStreamConfig(payload: ByteArray) {
        if (state == SessionState.AWAITING_HELLO ||
            state == SessionState.AWAITING_PAIR ||
            state == SessionState.AWAITING_AUTH
        ) {
            throw ProtocolException("STREAM_CONFIG before the handshake finished ($state)")
        }
        val config = StreamConfig.parse(payload)
        streamConfig = config
        listener.onStreamConfig(config)
        output.send(MessageType.READY, Json.bytes(JSONObject()))
        state = SessionState.READY
    }

    private fun handleVideo(payload: ByteArray) {
        if (state != SessionState.READY && state != SessionState.STREAMING) {
            throw ProtocolException("VIDEO in $state")
        }
        state = SessionState.STREAMING
        listener.onVideo(VideoFrame.parse(payload))
    }

    private fun handlePing(payload: ByteArray) {
        val echo = InputCodec.decodePing(payload)
        output.send(MessageType.PONG, InputCodec.encodePong(echo, monotonicMicros()))
    }

    private fun handlePong(payload: ByteArray) {
        val (echoMicros, hostReceiveMicros) = InputCodec.decodePong(payload)
        val now = monotonicMicros()
        val rtt = now - echoMicros
        // Standard one-way-delay estimate: the host stamped t_recv halfway
        // through the round trip, so the clocks differ by that much.
        val offset = hostReceiveMicros - (echoMicros + rtt / 2)
        listener.onRoundTrip(rtt, offset)
    }

    private fun handleBye(payload: ByteArray) {
        val reason =
            try {
                Json.obj(payload).optString("reason", "")
            } catch (_: ProtocolException) {
                ""
            }
        listener.onBye(reason)
        output.close(if (reason.isEmpty()) "peer sent BYE" else reason)
        state = SessionState.CLOSED
    }

    private fun fail(message: String) {
        listener.onProtocolError(message)
        output.close(message)
        state = SessionState.CLOSED
    }

    // ------------------------------------------------------------- outbound API

    fun sendKeyframeRequest() = output.send(MessageType.KEYFRAME_REQUEST, EMPTY)

    fun sendDeviceConfig(orientation: Orientation, screen: ScreenInfo) {
        output.send(
            MessageType.DEVICE_CONFIG,
            Json.bytes(
                JSONObject()
                    .put("orientation", orientation.wire)
                    .put("screen", screen.toJson()),
            ),
        )
    }

    fun sendTouch(phase: Byte, pointers: List<TouchPointer>) =
        output.send(MessageType.TOUCH, InputCodec.encodeTouch(phase, pointers))

    fun sendScroll(x: Float, y: Float, dx: Float, dy: Float, phase: Byte) =
        output.send(MessageType.SCROLL, InputCodec.encodeScroll(x, y, dx, dy, phase))

    fun sendKey(event: KeyEvent) = output.send(MessageType.KEY, event.toJsonBytes())

    fun sendPointer(kind: Byte, button: Byte, x: Float, y: Float) =
        output.send(MessageType.POINTER, InputCodec.encodePointer(kind, button, x, y))

    fun sendPing(sendMicros: Long) = output.send(MessageType.PING, InputCodec.encodePing(sendMicros))

    fun sendStats(stats: StatsSnapshot) = output.send(MessageType.STATS, stats.toJsonBytes())

    fun sendBye(reason: String) =
        output.send(MessageType.BYE, Json.bytes(JSONObject().put("reason", reason)))

    /** The PIN currently on screen, or null when none is in flight. */
    fun pin(): String? = currentPin

    fun streamConfig(): StreamConfig? = streamConfig

    private companion object {
        val EMPTY = ByteArray(0)

        fun monotonicMicros(): Long = System.nanoTime() / 1_000L
    }
}
