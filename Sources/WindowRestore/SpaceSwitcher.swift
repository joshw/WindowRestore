import AppKit
import ApplicationServices
import CoreGraphics

/// Public-API fallback for moving a window to another desktop, used when the
/// window server rejects the private move (macOS 15 and later). It does what
/// a person would: hold the window by its title bar and press the "Move
/// left/right a space" shortcut until the target desktop is showing. The
/// visible desktop changes while it runs, and the mouse must be left alone.
enum SpaceSwitcher {
    enum Failure: Error, CustomStringConvertible {
        case shortcutDisabled
        case spaceNotOnDisplay
        case noGrabPoint
        case switchTimedOut
        case windowDidNotFollow

        var description: String {
            switch self {
            case .shortcutDisabled:
                "turn on “Move left/right a space” in System Settings › Keyboard › Keyboard Shortcuts › Mission Control"
            case .spaceNotOnDisplay: "the window's desktop is not on the target display"
            case .noGrabPoint: "found no empty spot on the title bar to hold"
            case .switchTimedOut: "the desktop did not change"
            case .windowDidNotFollow: "the window did not follow the desktop switch"
            }
        }
    }

    private enum Direction { case left, right }

    private struct Hotkey {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Carries a window to `target` on `display`. The window must already be
    /// on that display (restoring its frame puts it there).
    static func carry(_ window: AXUIElement, id wid: CGWindowID, pid: pid_t,
                      to target: SpaceInfo, on display: DisplayInfo) -> Result<Void, Failure> {
        let cursor = CGEvent(source: nil)?.location
        defer { cursor.map(warp) }

        // The window can only be grabbed while its desktop is showing.
        guard let current = PrivateAPI.spaces(forWindow: wid).first else { return .failure(.spaceNotOnDisplay) }
        mouse(.mouseMoved, CGPoint(x: display.frame.midX, y: display.frame.midY))
        if case .failure(let f) = show(current, on: display) { return .failure(f) }

        let app = AXUIElementCreateApplication(pid)
        app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 0.25)
        guard let grab = grabPoint(window, app: app) else { return .failure(.noGrabPoint) }

        let held = CGPoint(x: grab.x + 2, y: grab.y)
        mouse(.mouseMoved, grab)
        mouse(.leftMouseDown, grab)
        Thread.sleep(forTimeInterval: 0.05)
        mouse(.leftMouseDragged, CGPoint(x: grab.x + 1, y: grab.y))
        mouse(.leftMouseDragged, held)
        Thread.sleep(forTimeInterval: 0.1)
        let switched = show(target.id, on: display)
        mouse(.leftMouseUp, held)
        Thread.sleep(forTimeInterval: 0.15)

        if case .failure(let f) = switched { return .failure(f) }
        return PrivateAPI.spaces(forWindow: wid).contains(target.id) ? .success(()) : .failure(.windowDidNotFollow)
    }

    /// Switches each display back to the desktop it was showing in `original`.
    static func showDesktops(_ original: [DisplaySpaces], on displays: [DisplayInfo]) {
        let cursor = CGEvent(source: nil)?.location
        defer { cursor.map(warp) }
        for display in displays {
            guard let id = Spaces.forDisplay(display.uuid, in: original)?.currentSpaceID else { continue }
            mouse(.mouseMoved, CGPoint(x: display.frame.midX, y: display.frame.midY))
            _ = show(id, on: display)
        }
    }

    /// Presses Move left/right a space until `spaceID` is showing. The
    /// shortcut acts on the display under the mouse, which callers arrange.
    private static func show(_ spaceID: UInt64, on display: DisplayInfo) -> Result<Void, Failure> {
        for _ in 0..<16 {
            guard let ds = Spaces.forDisplay(display.uuid, in: Spaces.all()),
                  let from = ds.spaces.firstIndex(where: { $0.id == ds.currentSpaceID }),
                  let to = ds.spaces.firstIndex(where: { $0.id == spaceID })
            else { return .failure(.spaceNotOnDisplay) }
            if from == to { return .success(()) }
            guard let key = hotkey(to < from ? .left : .right) else { return .failure(.shortcutDisabled) }
            press(key)
            guard waitForSwitch(on: display, awayFrom: ds.currentSpaceID) else { return .failure(.switchTimedOut) }
        }
        return .failure(.switchTimedOut)
    }

    private static func waitForSwitch(on display: DisplayInfo, awayFrom old: UInt64?) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if Spaces.forDisplay(display.uuid, in: Spaces.all())?.currentSpaceID != old {
                Thread.sleep(forTimeInterval: 0.35) // let the slide animation finish
                return true
            }
        }
        return false
    }

    /// Finds a point on the title bar that drags the window: right of the
    /// traffic lights, where a hit test lands on the window itself or its
    /// toolbar background rather than a control.
    private static func grabPoint(_ window: AXUIElement, app: AXUIElement) -> CGPoint? {
        guard let frame = window.frame else { return nil }
        let buttons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
            .compactMap { window.value($0) }
            .compactMap { ($0 as! AXUIElement).frame }
        let y = buttons.first?.midY ?? frame.minY + 14
        var x = (buttons.map(\.maxX).max() ?? frame.minX) + 8
        var titleText: CGPoint?

        while x < frame.maxX - 20 {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &hit) == .success, let hit {
                let role = hit.string(kAXRoleAttribute)
                if CFEqual(hit, window) || role == kAXToolbarRole { return CGPoint(x: x, y: y) }
                if role == kAXStaticTextRole, titleText == nil { titleText = CGPoint(x: x, y: y) }
            }
            x += 12
        }
        return titleText
    }

    /// The user's "Move left/right a space" shortcut (Mission Control
    /// shortcuts 79 and 81), or nil if it is turned off.
    private static func hotkey(_ direction: Direction) -> Hotkey? {
        let fallback = Hotkey(keyCode: direction == .left ? 123 : 124, flags: [.maskControl, .maskSecondaryFn])
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        guard let entry = all?[direction == .left ? "79" : "81"] as? [String: Any] else { return fallback }
        if (entry["enabled"] as? NSNumber)?.boolValue == false { return nil }
        guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], params.count == 3
        else { return fallback }
        return Hotkey(keyCode: CGKeyCode(params[1].intValue), flags: CGEventFlags(rawValue: params[2].uint64Value))
    }

    private static func press(_ key: Hotkey) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down)
            event?.flags = key.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func mouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func warp(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
