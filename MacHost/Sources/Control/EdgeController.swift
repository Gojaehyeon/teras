import AppKit
import CoreGraphics
import Foundation

/// Which side of the Mac's desktop the phone sits on (CONTROL.md §7).
enum ControlEdge: String, Codable, CaseIterable, Sendable {
    case right
    case left
}

/// The pure geometry behind the capture state machine.
///
/// Everything here is arithmetic on CoreGraphics coordinates — y grows
/// downwards, unlike AppKit — so the edge rules can be unit tested without an
/// event tap, a display or a device.
struct EdgeGeometry: Equatable, Sendable {
    /// Union of every online display, in CG (top-left origin) coordinates.
    var displayUnion: CGRect
    /// Which Mac edge the phone is attached to.
    var edge: ControlEdge
    /// The phone's logical size in the current rotation.
    var phoneSize: CGSize
    /// Phone pixels per Mac point.
    var speed: CGFloat

    /// How far inside the edge the real cursor is parked after a release.
    static let releaseInset: CGFloat = 8
    /// The crossing threshold from CONTROL.md §7.
    static let crossingSlop: CGFloat = 1

    init(displayUnion: CGRect, edge: ControlEdge = .right, phoneSize: CGSize, speed: CGFloat = 1.5) {
        self.displayUnion = displayUnion
        self.edge = edge
        self.phoneSize = phoneSize
        self.speed = speed
    }

    /// The x of the Mac edge the phone is attached to.
    var edgeX: CGFloat {
        edge == .right ? displayUnion.maxX : displayUnion.minX
    }

    /// Where the real cursor is pinned while captured: the last pixel column
    /// inside the edge, at whatever height the cursor was already at.
    func pinPoint(cursorY: CGFloat) -> CGPoint {
        let y = min(max(cursorY, displayUnion.minY), displayUnion.maxY - 1)
        let x = edge == .right ? displayUnion.maxX - 1 : displayUnion.minX
        return CGPoint(x: x, y: y)
    }

    /// Has the pointer pushed past the capture edge?
    ///
    /// macOS clamps the cursor to the desktop, so the cursor itself can never
    /// be outside it. What signals the crossing is the cursor sitting on the
    /// edge column while the mouse keeps pushing outward.
    func crossesEdge(cursor: CGPoint, deltaX: CGFloat) -> Bool {
        guard cursor.y >= displayUnion.minY, cursor.y < displayUnion.maxY else { return false }
        switch edge {
        case .right:
            return cursor.x >= displayUnion.maxX - 1 && deltaX >= Self.crossingSlop
        case .left:
            return cursor.x <= displayUnion.minX && deltaX <= -Self.crossingSlop
        }
    }

    /// Where the virtual pointer appears on the phone when capture begins:
    /// the phone's edge facing the Mac, at the proportional height.
    func entryPoint(cursorY: CGFloat) -> CGPoint {
        let fraction = displayUnion.height > 0
            ? (cursorY - displayUnion.minY) / displayUnion.height
            : 0.5
        let y = clampY(fraction * phoneSize.height)
        let x: CGFloat = edge == .right ? 0 : max(phoneSize.width - 1, 0)
        return CGPoint(x: x, y: y)
    }

    /// Apply one mouse delta to the virtual pointer.
    ///
    /// The returned point is always inside the phone; `release` says the
    /// unclamped movement went past the phone edge that faces the Mac, which
    /// is what hands control back (CONTROL.md §7).
    func move(from point: CGPoint, deltaX: CGFloat, deltaY: CGFloat) -> (point: CGPoint, release: Bool) {
        let unclampedX = point.x + deltaX * speed
        let unclampedY = point.y + deltaY * speed
        let release: Bool
        switch edge {
        case .right: release = unclampedX < 0
        case .left: release = unclampedX > phoneSize.width
        }
        let clamped = CGPoint(x: clampX(unclampedX), y: clampY(unclampedY))
        return (clamped, release)
    }

    /// Where the real cursor is put when control returns to the Mac: just
    /// inside the edge, at the height matching the virtual pointer.
    func releaseCursorPoint(virtualY: CGFloat) -> CGPoint {
        let fraction = phoneSize.height > 0 ? virtualY / phoneSize.height : 0.5
        let y = min(max(displayUnion.minY + fraction * displayUnion.height, displayUnion.minY),
                    displayUnion.maxY - 1)
        let x = edge == .right
            ? displayUnion.maxX - Self.releaseInset
            : displayUnion.minX + Self.releaseInset
        return CGPoint(x: x, y: y)
    }

    private func clampX(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(phoneSize.width - 1, 0))
    }

    private func clampY(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(phoneSize.height - 1, 0))
    }

    /// Union of every online display, in CG coordinates.
    static func currentDisplayUnion() -> CGRect {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        var union = CGRect.null
        for id in ids.prefix(Int(count)) {
            union = union.union(CGDisplayBounds(id))
        }
        return union.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : union
    }
}

/// Scroll conversion constants, in one place because the right sign can only
/// be confirmed on a real phone.
enum ControlScroll {
    /// macOS reports scrolls in points; the wire format wants wheel notches.
    static let pointsPerStep: CGFloat = 10

    /// macOS `scrollingDeltaY` and Android `AXIS_VSCROLL` agree on their sign:
    /// a positive value means the content moves toward its top, revealing what
    /// is above. So vertical is passed through unchanged. Horizontal is
    /// inverted because Android's `AXIS_HSCROLL` is positive when the content
    /// moves toward its *end*, the opposite of `scrollingDeltaX`.
    /// Both signs live here so a device test can flip either one alone.
    static let invertVertical = false
    static let invertHorizontal = true

    static func steps(points: CGFloat, invert: Bool) -> Float {
        let steps = points / pointsPerStep
        return Float(invert ? -steps : steps)
    }
}

/// The capture state machine: a CGEvent tap that watches for the cursor
/// leaving the Mac and, once it has, turns the mouse and keyboard into Teras
/// Control messages instead of Mac input (CONTROL.md §7).
final class EdgeController: @unchecked Sendable {

    /// The escape chord that always hands control back.
    static let escapeKeyCode = 0x35   // kVK_Escape

    private let serial: String
    private let send: ([Data]) -> Void

    private let lock = NSLock()
    private var geometry: EdgeGeometry
    private var displayUnionRefreshedAt = Date.distantPast

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?

    private var isCaptured = false
    private var virtualPointer: CGPoint = .zero
    private var pinPoint: CGPoint = .zero
    private var heldKeys: Set<Int> = []
    private var heldButtons: Set<ControlButton> = []
    private var currentMeta: UInt32 = 0

    /// Called (off the main thread) when capture starts or stops.
    var onCaptureChanged: ((Bool) -> Void)?
    /// Called when the tap could not be created or was disabled for good.
    var onTapFailure: ((String) -> Void)?

    init(serial: String, phoneSize: CGSize, edge: ControlEdge, speed: CGFloat, send: @escaping ([Data]) -> Void) {
        self.serial = serial
        self.send = send
        self.geometry = EdgeGeometry(displayUnion: EdgeGeometry.currentDisplayUnion(),
                                     edge: edge,
                                     phoneSize: phoneSize,
                                     speed: speed)
    }

    deinit {
        stop()
    }

    var captured: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCaptured
    }

    // MARK: - Settings

    func update(phoneSize: CGSize) {
        lock.lock(); geometry.phoneSize = phoneSize; lock.unlock()
    }

    func update(edge: ControlEdge) {
        lock.lock(); geometry.edge = edge; lock.unlock()
    }

    func update(speed: CGFloat) {
        lock.lock(); geometry.speed = speed; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Create the tap on a thread of its own. The tap callback has to be
    /// serviced by a run loop, and the main run loop is busy with SwiftUI.
    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "app.teras.control.tap.\(serial)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        forceRelease()
        if let tapRunLoop, let runLoopSource {
            CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        thread = nil
    }

    /// Hand control back to the Mac without the user asking — the device went
    /// away, or the user turned the feature off.
    func forceRelease() {
        lock.lock()
        let wasCaptured = isCaptured
        lock.unlock()
        guard wasCaptured else { return }
        endCapture()
    }

    private func runTapLoop() {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: eventTapCallback,
                                          userInfo: userInfo) else {
            Log.error(.control, "Could not create the event tap for \(serial); Accessibility permission is missing")
            onTapFailure?("accessibility")
            return
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let runLoop = CFRunLoopGetCurrent()
        tapRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info(.control, "Edge watcher running for \(serial)")
        CFRunLoopRun()
        Log.debug(.control, "Edge watcher for \(serial) ended")
    }

    // MARK: - The tap callback

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // macOS disables a tap that blocks for too long. Turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info(.control, "Event tap for \(serial) was re-enabled after a timeout")
            return nil
        case .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        default:
            break
        }

        lock.lock()
        let capturing = isCaptured
        lock.unlock()

        return capturing ? handleCaptured(type: type, event: event) : handleIdle(type: type, event: event)
    }

    /// Idle: watch only. Nothing is swallowed, so the Mac behaves normally.
    private func handleIdle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let deltaX = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            refreshDisplayUnionIfStale()
            lock.lock()
            let geometry = self.geometry
            lock.unlock()
            if geometry.crossesEdge(cursor: event.location, deltaX: deltaX) {
                beginCapture(cursor: event.location, geometry: geometry)
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Captured: everything is swallowed and forwarded to the phone instead.
    private func handleCaptured(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let deltaX = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            let deltaY = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
            movePointer(deltaX: deltaX, deltaY: deltaY)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let button = Self.button(for: event, type: type) {
                lock.lock(); heldButtons.insert(button); let point = virtualPointer; lock.unlock()
                send([ControlProtocol.button(button, down: true, x: Float(point.x), y: Float(point.y))])
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let button = Self.button(for: event, type: type) {
                lock.lock(); heldButtons.remove(button); let point = virtualPointer; lock.unlock()
                send([ControlProtocol.button(button, down: false, x: Float(point.x), y: Float(point.y))])
            }

        case .scrollWheel:
            let vertical = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            let horizontal = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            if vertical != 0 || horizontal != 0 {
                lock.lock(); let point = virtualPointer; lock.unlock()
                send([ControlProtocol.scroll(x: Float(point.x),
                                             y: Float(point.y),
                                             horizontal: ControlScroll.steps(points: horizontal,
                                                                             invert: ControlScroll.invertHorizontal),
                                             vertical: ControlScroll.steps(points: vertical,
                                                                           invert: ControlScroll.invertVertical))])
            }

        case .keyDown:
            handleKeyDown(event)

        case .keyUp:
            handleKeyUp(event)

        case .flagsChanged:
            handleFlagsChanged(event)

        default:
            break
        }

        // Keep the real cursor parked so macOS never scrolls the desktop. Skip
        // it when this very event ended the capture, or the warp would undo
        // the one that just put the cursor back on the Mac.
        lock.lock()
        let stillCaptured = isCaptured
        let pin = pinPoint
        lock.unlock()
        if stillCaptured { CGWarpMouseCursorPosition(pin) }
        return nil
    }

    // MARK: - Pointer

    private func movePointer(deltaX: CGFloat, deltaY: CGFloat) {
        lock.lock()
        let result = geometry.move(from: virtualPointer, deltaX: deltaX, deltaY: deltaY)
        virtualPointer = result.point
        let point = result.point
        lock.unlock()

        if result.release {
            endCapture()
            return
        }
        send([ControlProtocol.pointerMove(x: Float(point.x), y: Float(point.y))])
    }

    private static func button(for event: CGEvent, type: CGEventType) -> ControlButton? {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp:
            // Anything past the middle button has no Android equivalent.
            return event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? .middle : nil
        default: return nil
        }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let meta = KeyMap.metaState(from: flags)
        lock.lock(); currentMeta = meta; lock.unlock()

        if handleChord(keyCode: keyCode, flags: flags) { return }

        let repeatCount = UInt32(event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? 1 : 0)
        if let android = KeyMap.androidKeyCode(forMacKeyCode: keyCode) {
            lock.lock(); heldKeys.insert(keyCode); lock.unlock()
            send([ControlProtocol.key(down: true, keyCode: android, metaState: meta, repeatCount: repeatCount)])
            return
        }

        // No key code for this layout position: type the characters instead.
        if let text = KeyMap.unicodeString(for: event), KeyMap.isPrintableFallback(text) {
            send(ControlProtocol.textFrames(text))
        }
    }

    private func handleKeyUp(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let meta = KeyMap.metaState(from: event.flags)
        lock.lock()
        currentMeta = meta
        let wasHeld = heldKeys.remove(keyCode) != nil
        lock.unlock()
        guard wasHeld, let android = KeyMap.androidKeyCode(forMacKeyCode: keyCode) else { return }
        send([ControlProtocol.key(down: false, keyCode: android, metaState: meta)])
    }

    /// Modifiers reach the tap as `flagsChanged`, not key up/down. Swallowing
    /// them is what stops ⌘ or ⇧ from sticking on the Mac while the phone has
    /// the keyboard.
    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let android = KeyMap.androidKeyCode(forMacKeyCode: keyCode) else { return }
        let meta = KeyMap.metaState(from: event.flags)
        lock.lock()
        currentMeta = meta
        let isDown: Bool
        if heldKeys.contains(keyCode) {
            heldKeys.remove(keyCode)
            isDown = false
        } else {
            heldKeys.insert(keyCode)
            isDown = true
        }
        lock.unlock()
        send([ControlProtocol.key(down: isDown, keyCode: android, metaState: meta)])
    }

    /// The chords from CONTROL.md §7. Returns true when the key was consumed.
    private func handleChord(keyCode: Int, flags: CGEventFlags) -> Bool {
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)

        if keyCode == Self.escapeKeyCode, control, option, command {
            endCapture()
            return true
        }
        guard command else { return false }

        switch keyCode {
        case 0x04:   // H
            tap(shift ? KeyMap.Android.appSwitch : KeyMap.Android.home)
            return true
        case 0x25 where !shift:   // L
            tap(KeyMap.Android.power)
            return true
        case 0x09 where !shift:   // V
            pasteClipboard()
            return true
        default:
            return false
        }
    }

    /// A complete press of one Android key, with no Mac modifiers attached —
    /// the phone should see HOME, not ⌘-HOME.
    private func tap(_ androidKeyCode: UInt32) {
        send([ControlProtocol.key(down: true, keyCode: androidKeyCode, metaState: 0),
              ControlProtocol.key(down: false, keyCode: androidKeyCode, metaState: 0)])
    }

    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(ControlProtocol.textFrames(text))
    }

    // MARK: - Capture transitions

    private func beginCapture(cursor: CGPoint, geometry: EdgeGeometry) {
        let entry = geometry.entryPoint(cursorY: cursor.y)
        let pin = geometry.pinPoint(cursorY: cursor.y)

        lock.lock()
        isCaptured = true
        virtualPointer = entry
        pinPoint = pin
        heldKeys.removeAll()
        heldButtons.removeAll()
        currentMeta = 0
        lock.unlock()

        // Detach the cursor from the mouse so the hardware keeps producing
        // deltas while the arrow stays put, then hide it.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        CGWarpMouseCursorPosition(pin)

        send([ControlProtocol.setPointerVisible(true),
              ControlProtocol.pointerMove(x: Float(entry.x), y: Float(entry.y))])
        Log.info(.control, "Captured input for \(serial) at \(Int(entry.x)),\(Int(entry.y))")
        onCaptureChanged?(true)
    }

    private func endCapture() {
        lock.lock()
        guard isCaptured else { lock.unlock(); return }
        isCaptured = false
        let point = virtualPointer
        let keys = heldKeys
        let buttons = heldButtons
        let meta = currentMeta
        let geometry = self.geometry
        heldKeys.removeAll()
        heldButtons.removeAll()
        currentMeta = 0
        lock.unlock()

        // Release anything still down, or the phone is left with a stuck
        // modifier and every later key arrives shifted.
        var frames: [Data] = []
        for button in buttons {
            frames.append(ControlProtocol.button(button, down: false, x: Float(point.x), y: Float(point.y)))
        }
        for keyCode in keys {
            guard let android = KeyMap.androidKeyCode(forMacKeyCode: keyCode) else { continue }
            frames.append(ControlProtocol.key(down: false, keyCode: android, metaState: meta))
        }
        frames.append(ControlProtocol.setPointerVisible(false))
        send(frames)

        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        CGWarpMouseCursorPosition(geometry.releaseCursorPoint(virtualY: point.y))
        Log.info(.control, "Released input for \(serial)")
        onCaptureChanged?(false)
    }

    // MARK: - Displays

    /// The arrangement can change while the tap runs. Re-reading it on every
    /// mouse move would be wasteful, so it is refreshed once a second.
    private func refreshDisplayUnionIfStale() {
        guard Date().timeIntervalSince(displayUnionRefreshedAt) > 1 else { return }
        displayUnionRefreshedAt = Date()
        let union = EdgeGeometry.currentDisplayUnion()
        lock.lock(); geometry.displayUnion = union; lock.unlock()
    }
}

/// C callback for the tap; hands the event to the controller behind `userInfo`.
private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EdgeController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}
