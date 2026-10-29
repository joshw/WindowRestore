import CoreGraphics
import Foundation

struct SpaceInfo: Hashable {
    let id: UInt64
    /// Stable within a login session, but empty for the main display's first
    /// desktop, so it is only one of several ways a saved Space is matched.
    let uuid: String
    let isFullscreen: Bool
    /// 1-based position among the display's regular desktops ("Desktop 2").
    let desktopIndex: Int?
}

struct DisplaySpaces {
    /// Display UUID, or "Main" when "Displays have separate Spaces" is off and
    /// every display shares one list.
    let displayIdentifier: String
    let spaces: [SpaceInfo]
    let currentSpaceID: UInt64?

    var isShared: Bool { displayIdentifier == "Main" }
}

enum Spaces {
    static func all() -> [DisplaySpaces] {
        PrivateAPI.managedDisplaySpaces().map { entry in
            let current = (entry["Current Space"] as? [String: Any]).flatMap(spaceID)
            var desktopCount = 0
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).map { space -> SpaceInfo in
                // type 0 is a regular desktop, 4 is a full-screen app.
                let fullscreen = (space["type"] as? NSNumber)?.intValue == 4
                if !fullscreen { desktopCount += 1 }
                return SpaceInfo(
                    id: spaceID(space) ?? 0,
                    uuid: space["uuid"] as? String ?? "",
                    isFullscreen: fullscreen,
                    desktopIndex: fullscreen ? nil : desktopCount
                )
            }
            return DisplaySpaces(
                displayIdentifier: entry["Display Identifier"] as? String ?? "",
                spaces: spaces,
                currentSpaceID: current
            )
        }
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        ((dict["id64"] ?? dict["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    static func forDisplay(_ uuid: String, in all: [DisplaySpaces]) -> DisplaySpaces? {
        all.first { $0.displayIdentifier.caseInsensitiveCompare(uuid) == .orderedSame }
            ?? all.first(where: \.isShared)
    }

    static func find(_ id: UInt64, in all: [DisplaySpaces]) -> (DisplaySpaces, SpaceInfo)? {
        for display in all {
            if let space = display.spaces.first(where: { $0.id == id }) { return (display, space) }
        }
        return nil
    }

    static func label(for spaceIDs: [UInt64], in all: [DisplaySpaces]) -> String {
        if spaceIDs.isEmpty { return "Minimized or hidden" }
        if spaceIDs.count > 1 { return "All desktops" }
        guard let (_, space) = find(spaceIDs[0], in: all) else { return "Unknown space" }
        if space.isFullscreen { return "Full screen" }
        return "Desktop \(space.desktopIndex ?? 0)"
    }
}
