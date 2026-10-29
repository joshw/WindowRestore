import ApplicationServices
import CoreGraphics
import Foundation

struct RestoreOutcome: Identifiable {
    enum Status: String {
        case restored = "Restored"
        case partial = "Partly restored"
        case notOpen = "Not open"
        case displayMissing = "Display not connected"
        case failed = "Failed"
    }

    let id = UUID()
    let window: SavedWindow
    let status: Status
    let notes: [String]
}

enum Restorer {
    static func restore(_ snapshot: Snapshot) -> [RestoreOutcome] {
        let live = WindowCatalog.list()
        let displays = Displays.active()
        let originalSpaces = Spaces.all()
        var claimed = Set<CGWindowID>()
        var privateMoveWorks = true
        var switchedDesktops = false
        defer {
            if switchedDesktops { SpaceSwitcher.showDesktops(originalSpaces, on: displays) }
        }

        return snapshot.windows.map { saved in
            guard let (window, exact) = saved.match(in: live, excluding: claimed) else {
                return RestoreOutcome(window: saved, status: .notOpen, notes: [])
            }
            claimed.insert(window.id)
            var notes = exact ? [] : ["Matched by app and title (original window was closed)"]

            guard let element = window.element else {
                return RestoreOutcome(window: saved, status: .failed, notes: notes + ["Accessibility access not granted"])
            }

            let target: DisplayInfo
            if let savedDisplay = saved.display {
                guard let d = savedDisplay.match(in: displays) else {
                    return RestoreOutcome(window: saved, status: .displayMissing,
                                          notes: notes + ["\(savedDisplay.name) is not connected"])
                }
                target = d
            } else if let d = Displays.best(for: saved.frame, in: displays) {
                target = d
            } else {
                return RestoreOutcome(window: saved, status: .failed, notes: notes + ["No displays found"])
            }

            var partial = false

            if window.isFullscreen && !saved.wasFullscreen {
                element.set("AXFullScreen", kCFBooleanFalse)
                Thread.sleep(forTimeInterval: 0.8) // let the exit animation finish
            }
            if window.isMinimized && !saved.wasMinimized {
                element.set(kAXMinimizedAttribute, kCFBooleanFalse)
            }

            // Moving the frame onto the target display also puts the window on
            // that display's current Space; the Space is fixed up afterwards.
            let frame = clamp(saved.relativeFrame.offsetBy(dx: target.frame.minX, dy: target.frame.minY),
                              to: target.frame)
            if !(window.isFullscreen && saved.wasFullscreen) {
                if !element.setFrame(frame) {
                    partial = true
                    notes.append("The app refused the new position or size")
                }
                if frame.size != saved.relativeFrame.size {
                    notes.append("Resized to fit \(target.name)")
                }
            }

            if !saved.onAllDesktops && !saved.wasMinimized && !saved.wasFullscreen {
                switch resolveSpace(saved, on: target) {
                case .found(let space):
                    if PrivateAPI.spaces(forWindow: window.id) == [space.id] { break }
                    if privateMoveWorks {
                        if PrivateAPI.moveWindow(window.id, toSpace: space.id) { break }
                        privateMoveWorks = false // blocked on this macOS; don't retry for each window
                    }
                    switchedDesktops = true
                    switch SpaceSwitcher.carry(element, id: window.id, pid: window.pid, to: space, on: target) {
                    case .success:
                        _ = element.setFrame(frame) // the drag nudged it
                    case .failure(let reason):
                        partial = true
                        notes.append("Could not move to Desktop \(space.desktopIndex ?? 0): \(reason)")
                    }
                case .missing(let reason):
                    partial = true
                    notes.append(reason)
                }
            }

            if saved.wasFullscreen && !window.isFullscreen {
                element.set("AXFullScreen", kCFBooleanTrue)
            }
            if saved.wasMinimized && !window.isMinimized {
                element.set(kAXMinimizedAttribute, kCFBooleanTrue)
            }

            return RestoreOutcome(window: saved, status: partial ? .partial : .restored, notes: notes)
        }
    }

    private enum SpaceResolution {
        case found(SpaceInfo)
        case missing(String)
    }

    /// Picks the Space on the target display: the exact Space if it still
    /// exists there, otherwise the desktop with the same number. Space IDs
    /// from a display that was unplugged are usually gone after it returns,
    /// which is why the desktop number matters.
    private static func resolveSpace(_ saved: SavedWindow, on display: DisplayInfo) -> SpaceResolution {
        guard PrivateAPI.hasSpacesSupport else { return .missing("Spaces are not accessible on this macOS version") }
        guard let ds = Spaces.forDisplay(display.uuid, in: Spaces.all()) else {
            return .missing("No desktops found for \(display.name)")
        }
        if let id = saved.spaceID, let s = ds.spaces.first(where: { $0.id == id }) { return .found(s) }
        if let uuid = saved.spaceUUID, let s = ds.spaces.first(where: { $0.uuid == uuid }) { return .found(s) }
        if let index = saved.desktopIndex {
            if let s = ds.spaces.first(where: { $0.desktopIndex == index }) { return .found(s) }
            return .missing("\(display.name) no longer has a Desktop \(index); left on its current desktop")
        }
        return .missing("Original desktop unknown; left on the display's current desktop")
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
