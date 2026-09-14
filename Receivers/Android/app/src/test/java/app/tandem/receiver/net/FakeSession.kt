package app.tandem.receiver.net

import app.tandem.receiver.crypto.SessionCipher

/** Captures what the state machine sends, standing in for the socket. */
class RecordingOutput : SessionOutput {
    val sent = mutableListOf<Frame>()
    var armedCipher: SessionCipher? = null
    var closeReason: String? = null

    override fun send(type: Byte, payload: ByteArray) {
        sent.add(Frame(type, payload))
    }

    override fun armEncryption(cipher: SessionCipher) {
        armedCipher = cipher
    }

    override fun close(reason: String) {
        closeReason = reason
    }

    fun last(): Frame = sent.last()

    fun typesSent(): List<String> = sent.map { MessageType.name(it.type) }

    fun firstOf(type: Byte): Frame? = sent.firstOrNull { it.type == type }
}

/** Records the listener callbacks a session produces. */
class RecordingListener : SessionListener {
    var hello: Hello? = null
    var pin: String? = null
    var attemptsLeft: Int = -1
    var pinDismissed = false
    var pairedHostId: String? = null
    var authenticatedHostId: String? = null
    var authenticatedEncrypted = false
    var streamConfig: StreamConfig? = null
    val videoFrames = mutableListOf<VideoFrame>()
    var byeReason: String? = null
    var protocolError: String? = null
    var rttMicros: Long? = null
    var clockOffsetMicros: Long? = null

    override fun onHello(hello: Hello) {
        this.hello = hello
    }

    override fun onPinRequired(pin: String, attemptsLeft: Int) {
        this.pin = pin
        this.attemptsLeft = attemptsLeft
    }

    override fun onPinDismissed() {
        pinDismissed = true
        pin = null
    }

    override fun onPaired(hostId: String) {
        pairedHostId = hostId
    }

    override fun onAuthenticated(hostId: String, encrypted: Boolean) {
        authenticatedHostId = hostId
        authenticatedEncrypted = encrypted
    }

    override fun onStreamConfig(config: StreamConfig) {
        streamConfig = config
    }

    override fun onVideo(frame: VideoFrame) {
        videoFrames.add(frame)
    }

    override fun onRoundTrip(rttMicros: Long, hostClockOffsetMicros: Long) {
        this.rttMicros = rttMicros
        clockOffsetMicros = hostClockOffsetMicros
    }

    override fun onBye(reason: String) {
        byeReason = reason
    }

    override fun onProtocolError(message: String) {
        protocolError = message
    }
}
