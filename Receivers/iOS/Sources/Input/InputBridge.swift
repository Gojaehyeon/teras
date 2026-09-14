import Foundation
import UIKit
import TerasProtocol

/// Transparent overlay that turns touches, Apple Pencil input, indirect
/// pointer hover and hardware key presses into protocol frames (PROTOCOL §6).
///
/// Coordinates are normalized over the *rendered picture rect* supplied by
/// `videoRectProvider`, so letterboxing never skews the cursor.
final class InputBridge: UIView {

    /// Rect the video occupies, in this view's coordinate space.
    var videoRectProvider: () -> CGRect = { .zero }
    /// Emits protocol frames. Called on the main thread.
    var onFrame: ((Frame) -> Void)?
    /// Triple tap toggles the stats overlay.
    var onTripleTap: (() -> Void)?

    private enum Mode {
        case idle
        case touching
        case scrolling
        case suppressed      // long press already turned into a right click
    }

    private struct Tracked {
        var id: UInt32
        var startLocation: CGPoint
        var location: CGPoint
    }

    private static let longPressDuration: TimeInterval = 0.5
    private static let movementSlop: CGFloat = 10

    private var mode: Mode = .idle
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var order: [ObjectIdentifier] = []
    private var nextPointerId: UInt32 = 1
    private var longPressWorkItem: DispatchWorkItem?
    private var scrollCentroid: CGPoint = .zero
    private var scrollBegan = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.numberOfTouchesRequired = 1
        tripleTap.cancelsTouchesInView = false
        tripleTap.delaysTouchesBegan = false
        tripleTap.delaysTouchesEnded = false
        addGestureRecognizer(tripleTap)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Hardware key presses only reach a first responder, and SwiftUI's
        // onAppear can fire before the view joins a window.
        if window != nil { becomeFirstResponder() } else { resignFirstResponder() }
    }

    @objc private func handleTripleTap() {
        onTripleTap?()
    }

    // MARK: - Normalization

    private func normalized(_ point: CGPoint) -> CGPoint? {
        VideoGeometry.normalize(point, in: videoRectProvider())
    }

    private func emit(_ frame: Frame) {
        onFrame?(frame)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if !isFirstResponder { becomeFirstResponder() }

        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard tracked[key] == nil else { continue }
            let location = touch.location(in: self)
            tracked[key] = Tracked(id: nextPointerId, startLocation: location, location: location)
            order.append(key)
            nextPointerId &+= 1
            if nextPointerId == 0 { nextPointerId = 1 }
        }

        switch mode {
        case .idle:
            if order.count == 1 {
                mode = .touching
                sendTouch(phase: .began, touches: touches)
                scheduleLongPress()
            } else {
                // Two fingers landed together: go straight to scrolling.
                beginScrolling()
            }
        case .touching:
            if order.count >= 2 {
                cancelLongPress()
                sendTouch(phase: .cancelled, touches: activeTouches(in: event))
                beginScrolling()
            }
        case .scrolling, .suppressed:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard var entry = tracked[key] else { continue }
            entry.location = touch.location(in: self)
            tracked[key] = entry
        }

        switch mode {
        case .touching:
            if let touch = touches.first, let entry = tracked[ObjectIdentifier(touch)] {
                let distance = hypot(entry.location.x - entry.startLocation.x,
                                     entry.location.y - entry.startLocation.y)
                if distance > Self.movementSlop { cancelLongPress() }
            }
            sendTouch(phase: .moved, touches: touches)
        case .scrolling:
            updateScroll()
        case .idle, .suppressed:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finishTouches(touches, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finishTouches(touches, phase: .cancelled)
    }

    private func finishTouches(_ touches: Set<UITouch>, phase: TouchPhase) {
        cancelLongPress()
        switch mode {
        case .touching:
            sendTouch(phase: phase, touches: touches)
        case .scrolling:
            updateScroll()
        case .idle, .suppressed:
            break
        }

        for touch in touches {
            let key = ObjectIdentifier(touch)
            tracked[key] = nil
            order.removeAll { $0 == key }
        }

        if order.isEmpty {
            if mode == .scrolling, scrollBegan {
                emit(ScrollEvent(x: Float(lastScrollNormalized.x), y: Float(lastScrollNormalized.y),
                                 dx: 0, dy: 0, phase: .ended).frame())
            }
            scrollBegan = false
            mode = .idle
        }
    }

    private func activeTouches(in event: UIEvent?) -> Set<UITouch> {
        guard let all = event?.allTouches else { return [] }
        return all.filter { tracked[ObjectIdentifier($0)] != nil }
    }

    // MARK: - TOUCH frames

    private func sendTouch(phase: TouchPhase, touches: Set<UITouch>) {
        var pointers: [TouchPointer] = []
        pointers.reserveCapacity(touches.count)
        for touch in touches {
            guard let entry = tracked[ObjectIdentifier(touch)] else { continue }
            guard let point = normalized(touch.location(in: self)) else { continue }
            pointers.append(makePointer(id: entry.id, touch: touch, point: point))
        }
        guard !pointers.isEmpty, pointers.count <= 255 else { return }
        emit(TouchEvent(phase: phase, pointers: pointers).frame())
    }

    private func makePointer(id: UInt32, touch: UITouch, point: CGPoint) -> TouchPointer {
        guard touch.type == .pencil else {
            return StylusMapping.fingerPointer(id: id, x: Float(point.x), y: Float(point.y))
        }
        return StylusMapping.pointer(id: id,
                                     x: Float(point.x),
                                     y: Float(point.y),
                                     force: touch.force,
                                     maximumForce: touch.maximumPossibleForce,
                                     altitudeAngle: touch.altitudeAngle,
                                     azimuthAngle: touch.azimuthAngle(in: self))
    }

    // MARK: - Long press → right click

    private func scheduleLongPress() {
        cancelLongPress()
        let item = DispatchWorkItem { [weak self] in self?.fireLongPress() }
        longPressWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDuration, execute: item)
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func fireLongPress() {
        longPressWorkItem = nil
        guard mode == .touching, order.count == 1,
              let key = order.first, let entry = tracked[key],
              let point = normalized(entry.location) else { return }
        let distance = hypot(entry.location.x - entry.startLocation.x,
                             entry.location.y - entry.startLocation.y)
        guard distance <= Self.movementSlop else { return }

        // Release the left button the host started on TOUCH began, then click
        // the right one where the finger rests.
        emit(TouchEvent(phase: .cancelled,
                        pointers: [StylusMapping.fingerPointer(id: entry.id,
                                                               x: Float(point.x),
                                                               y: Float(point.y))]).frame())
        emit(PointerEvent(kind: .down, button: .right, x: Float(point.x), y: Float(point.y)).frame())
        emit(PointerEvent(kind: .up, button: .right, x: Float(point.x), y: Float(point.y)).frame())
        mode = .suppressed
    }

    // MARK: - Two-finger scroll

    private var lastScrollNormalized = CGPoint(x: 0.5, y: 0.5)

    private func beginScrolling() {
        cancelLongPress()
        mode = .scrolling
        scrollBegan = false
        scrollCentroid = centroid()
    }

    private func centroid() -> CGPoint {
        let points = order.compactMap { tracked[$0]?.location }
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func updateScroll() {
        let current = centroid()
        guard let point = normalized(current) else { return }
        lastScrollNormalized = point
        // Finger movement in points; positive dy means the fingers moved down,
        // which matches macOS natural scrolling deltas.
        let dx = Float(current.x - scrollCentroid.x)
        let dy = Float(current.y - scrollCentroid.y)
        scrollCentroid = current

        let phase: ScrollPhase = scrollBegan ? .changed : .began
        scrollBegan = true
        if phase == .changed, dx == 0, dy == 0 { return }
        emit(ScrollEvent(x: Float(point.x), y: Float(point.y), dx: dx, dy: dy, phase: phase).frame())
    }

    // MARK: - Pointer hover (iPadOS trackpad/mouse)

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            guard let point = normalized(recognizer.location(in: self)) else { return }
            emit(PointerEvent(kind: .move, button: .left, x: Float(point.x), y: Float(point.y)).frame())
        default:
            break
        }
    }

    // MARK: - Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        MacKeyCodes.keyCommandInputs.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input, let usage = MacKeyCodes.usage(forKeyCommandInput: input) else { return }
        let code = MacKeyCodes.code(for: usage)
        // A key command carries no press/release pair, so synthesise both.
        sendKey(down: true, code: code, text: nil, mods: [])
        sendKey(down: false, code: code, text: nil, mods: [])
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let mods = MacKeyCodes.modifierNames(key.modifierFlags)
            // Unmodified arrows, tab and escape arrive through keyCommands.
            if mods.isEmpty, MacKeyCodes.keyCommandUsages.contains(key.keyCode.rawValue) { continue }
            let code = MacKeyCodes.code(for: key.keyCode)
            let text = code == nil ? nonEmpty(key.characters) : nil
            if code == nil, text == nil {
                unhandled.insert(press)
                continue
            }
            sendKey(down: down, code: code, text: text, mods: mods)
        }
        return unhandled
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func sendKey(down: Bool, code: Int?, text: String?, mods: [String]) {
        let event = KeyEvent(down: down, keyCode: code ?? MacKeyCodes.unknown, text: text, mods: mods)
        guard let frame = try? Frame.json(.key, event) else { return }
        emit(frame)
    }
}
