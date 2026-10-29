import AppKit
import ApplicationServices
import CoreGraphics

/// A window that exists right now, on any Space or display.
struct LiveWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let spaceIDs: [UInt64]
    /// nil when Accessibility access has not been granted.
    let element: AXUIElement?
}

enum WindowCatalog {
    /// Time allowed per app for brute-forcing AX tokens of off-Space windows.
    private static let bruteForceBudget: TimeInterval = 0.3

    static func list() -> [LiveWindow] {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let trusted = AXIsProcessTrusted()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        struct Candidate {
            let wid: CGWindowID
            let app: NSRunningApplication
            let cgTitle: String?
            let frame: CGRect
            let onScreen: Bool
            let spaces: [UInt64]
        }

        var apps: [pid_t: NSRunningApplication?] = [:]
        let candidates: [Candidate] = info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            if apps[pid] == nil { apps[pid] = NSRunningApplication(processIdentifier: pid) }
            guard let app = apps[pid] ?? nil, app.activationPolicy == .regular else { return nil }
            return Candidate(
                wid: wid,
                app: app,
                cgTitle: d[kCGWindowName as String] as? String,
                frame: frame,
                onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false,
                spaces: PrivateAPI.spaces(forWindow: wid)
            )
        }

        var elements: [CGWindowID: AXUIElement] = [:]
        if trusted {
            for (pid, group) in Dictionary(grouping: candidates, by: { $0.app.processIdentifier }) {
                // Windows visible on the current Space come back from
                // kAXWindowsAttribute; only off-Space ones need brute force.
                let offSpace = Set(group.filter { !$0.onScreen && !$0.spaces.isEmpty }.map(\.wid))
                elements.merge(axWindows(pid: pid, needing: offSpace)) { a, _ in a }
            }
        }

        return candidates.compactMap { c in
            let element = elements[c.wid]
            if trusted {
                // AX tells real document windows apart from the many
                // invisible helper windows apps keep at layer 0.
                guard element != nil else { return nil }
            } else if c.spaces.isEmpty {
                return nil
            }
            let axTitle = element?.string(kAXTitleAttribute)
            return LiveWindow(
                id: c.wid,
                pid: c.app.processIdentifier,
                appName: c.app.localizedName ?? c.app.bundleIdentifier ?? "pid \(c.app.processIdentifier)",
                bundleID: c.app.bundleIdentifier,
                title: [axTitle, c.cgTitle].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                frame: c.frame,
                isMinimized: element?.bool(kAXMinimizedAttribute) ?? false,
                isFullscreen: element?.bool("AXFullScreen") ?? false,
                spaceIDs: c.spaces,
                element: element
            )
        }
    }

    private static func axWindows(pid: pid_t, needing offSpace: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        let app = AXUIElementCreateApplication(pid)
        for window in app.elements(kAXWindowsAttribute) where window.isStandardWindow {
            if let wid = PrivateAPI.windowID(of: window) { found[wid] = window }
        }

        var missing = offSpace.subtracting(found.keys)
        guard !missing.isEmpty, PrivateAPI.hasRemoteTokenSupport else { return found }

        let deadline = Date().addingTimeInterval(bruteForceBudget)
        for elementID: UInt64 in 0..<1000 {
            if missing.isEmpty || Date() > deadline { break }
            guard let element = PrivateAPI.element(pid: pid, elementID: elementID),
                  element.isStandardWindow,
                  let wid = PrivateAPI.windowID(of: element), found[wid] == nil
            else { continue }
            found[wid] = element
            missing.remove(wid)
        }
        return found
    }
}

extension AXUIElement {
    func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }
    func elements(_ attribute: String) -> [AXUIElement] { value(attribute) as? [AXUIElement] ?? [] }

    @discardableResult
    func set(_ attribute: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    var isStandardWindow: Bool {
        guard string(kAXRoleAttribute) == kAXWindowRole else { return false }
        let subrole = string(kAXSubroleAttribute)
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Position, then size, then position again: moving to a smaller display
    /// can make macOS clamp the size against the old position, and resizing
    /// first can push the window off the edge of the old display.
    func setFrame(_ rect: CGRect) -> Bool {
        var origin = rect.origin, size = rect.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return false }
        let first = set(kAXPositionAttribute, p)
        let sized = set(kAXSizeAttribute, s)
        let second = set(kAXPositionAttribute, p)
        return (first == .success || second == .success) && sized != .cannotComplete
    }
}
