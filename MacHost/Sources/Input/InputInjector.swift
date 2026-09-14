import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import TandemProtocol

/// Turns receiver input into real macOS events on the virtual display.
///
/// Coordinates arrive normalized over the encoded video frame (PROTOCOL §5.1),
/// so they map onto the display's global CoreGraphics bounds regardless of the
/// encode size, HiDPI or where the user dragged the display in Arrangement.
@MainActor
final class InputInjector {
    /// Supplies the current bounds of the display this session owns. Nil while
    /// there is no display, in which case every event is dropped.
    private let displayBounds: () -> CGRect?
    private let eventSource: CGEventSource?

    private var pressedButton: CGMouseButton?
    private var lastClickAt: Date?
    private var lastClickPoint: CGPoint = .zero
    private var clickState = 1

    /// Two taps closer than this in time and space count as a double click.
    private static let doubleClickInterval: TimeInterval = 0.4
    private static let doubleClickSlop: CGFloat = 6

    init(displayBounds: @escaping () -> CGRect?) {
        self.displayBounds = displayBounds
        eventSource = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: - Permission

    /// Whether this process may post synthetic events. Without it every call
    /// below silently does nothing, which is why the UI checks it up front.
    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Touch

    func handle(_ touch: TouchEvent) {
        // A single finger drives the pointer. Two-finger gestures reach us as
        // SCROLL from the receiver, which already knows the gesture semantics.
        guard let pointer = touch.pointers.first, touch.pointers.count == 1 else {
            if touch.phase == .ended || touch.phase == .cancelled { releaseHeldButton() }
            return
        }
        guard let point = location(x: pointer.x, y: pointer.y) else { return }

        switch touch.phase {
        case .began:
            press(.left, at: point, pressure: pointer.pressure)
        case .moved:
            drag(to: point, pressure: pointer.pressure)
        case .ended, .cancelled:
            release(.left, at: point)
        }
    }

    // MARK: - Pointer

    func handle(_ pointer: PointerEvent) {
        guard let point = location(x: pointer.x, y: pointer.y) else { return }
        let button: CGMouseButton = switch pointer.button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }

        switch pointer.kind {
        case .move:
            if pressedButton != nil {
                drag(to: point, pressure: 1)
            } else {
                post(type: .mouseMoved, at: point, button: .left, pressure: 0)
            }
        case .down:
            press(button, at: point, pressure: 1)
        case .up:
            release(button, at: point)
        }
    }

    // MARK: - Scroll

    func handle(_ scroll: ScrollEvent) {
        guard displayBounds() != nil else { return }
        if let point = location(x: scroll.x, y: scroll.y) {
            post(type: .mouseMoved, at: point, button: .left, pressure: 0)
        }
        // Pixel units keep the receiver's own scroll physics; wheel1 is
        // vertical, wheel2 horizontal, both inverted relative to content motion.
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(clamping: Int(scroll.dy.rounded())),
                                  wheel2: Int32(clamping: Int(scroll.dx.rounded())),
                                  wheel3: 0) else { return }
        let phase: Int64 = switch scroll.phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func handle(_ key: KeyEvent) {
        let flags = Self.flags(from: key.mods)

        if key.keyCode > 0, key.keyCode <= 0xFFFF {
            guard let event = CGEvent(keyboardEventSource: eventSource,
                                      virtualKey: CGKeyCode(key.keyCode),
                                      keyDown: key.down) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            return
        }

        // No virtual key code: insert the text itself. Only key-down carries
        // the characters; the matching key-up closes the event pair.
        guard let text = key.text, !text.isEmpty else { return }
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: key.down) else { return }
        var utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func flags(from mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in mods {
            switch mod.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "caps", "capslock": flags.insert(.maskAlphaShift)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    // MARK: - Mouse helpers

    private func press(_ button: CGMouseButton, at point: CGPoint, pressure: Float) {
        updateClickState(at: point)
        pressedButton = button
        post(type: downType(button), at: point, button: button, pressure: pressure)
    }

    private func drag(to point: CGPoint, pressure: Float) {
        guard let button = pressedButton else {
            post(type: .mouseMoved, at: point, button: .left, pressure: 0)
            return
        }
        post(type: dragType(button), at: point, button: button, pressure: pressure)
    }

    private func release(_ button: CGMouseButton, at point: CGPoint) {
        post(type: upType(button), at: point, button: button, pressure: 0)
        pressedButton = nil
    }

    private func releaseHeldButton() {
        guard let button = pressedButton, let bounds = displayBounds() else {
            pressedButton = nil
            return
        }
        let location = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        release(button, at: location)
    }

    private func post(type: CGEventType, at point: CGPoint, button: CGMouseButton, pressure: Float) {
        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        if pressure > 0 {
            event.setDoubleValueField(.mouseEventPressure, value: Double(min(max(pressure, 0), 1)))
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    private func updateClickState(at point: CGPoint) {
        let now = Date()
        if let last = lastClickAt,
           now.timeIntervalSince(last) < Self.doubleClickInterval,
           abs(point.x - lastClickPoint.x) < Self.doubleClickSlop,
           abs(point.y - lastClickPoint.y) < Self.doubleClickSlop {
            clickState = min(clickState + 1, 3)
        } else {
            clickState = 1
        }
        lastClickAt = now
        lastClickPoint = point
    }

    private func downType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    private func upType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    private func dragType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        default: return .otherMouseDragged
        }
    }

    /// Map a normalized point onto the display's global coordinates.
    private func location(x: Float, y: Float) -> CGPoint? {
        guard let bounds = displayBounds(), bounds.width > 0, bounds.height > 0 else { return nil }
        let clampedX = CGFloat(min(max(x, 0), 1))
        let clampedY = CGFloat(min(max(y, 0), 1))
        return CGPoint(x: bounds.minX + clampedX * (bounds.width - 1),
                       y: bounds.minY + clampedY * (bounds.height - 1))
    }
}
