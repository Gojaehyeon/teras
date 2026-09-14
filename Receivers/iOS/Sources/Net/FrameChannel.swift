import Foundation
import TandemProtocol

/// The connection as the session state machine sees it. Keeping this a
/// protocol lets the state machine be tested without a socket.
protocol FrameChannel: AnyObject {
    /// `usb` when the peer dialled in over loopback (usbmuxd), else `lan`.
    var linkTransport: Transport { get }
    /// Enqueue a frame. Safe to call from any thread; ordering is preserved.
    func send(_ frame: Frame)
    /// Switch both directions to the AES-GCM envelope (PROTOCOL §2.1).
    /// Frames already queued before this call are sent in the clear.
    func enableEncryption(hostToReceiver: Data, receiverToHost: Data)
    /// Close the connection, optionally sending BYE first.
    func close(reason: String?)
    /// Host clock minus receiver clock, in microseconds, or nil before the
    /// first PONG.
    var clockOffsetUs: Int64? { get }
    /// Smoothed round-trip time in milliseconds.
    var roundTripMs: Double { get }
}
