import AppKit
import CoreGraphics

/// A connected display. `frame` is in global CoreGraphics coordinates
/// (origin at the top-left of the main display, y grows downward), which is
/// the same space used by CGWindowList bounds and AX positions.
struct DisplayInfo: Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let frame: CGRect
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var isMain: Bool { CGDisplayIsMain(id) != 0 }

    var name: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}

enum Displays {
    static func active() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                id: id,
                uuid: uuid(of: id),
                frame: CGDisplayBounds(id),
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)
            )
        }
    }

    /// The display UUID is derived from the panel's vendor/model/serial, so
    /// unlike `CGDirectDisplayID` it survives unplugging and replugging.
    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display holding the largest part of `rect`, falling back to the
    /// one nearest its centre for windows parked entirely off-screen.
    static func best(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        func overlap(_ d: DisplayInfo) -> CGFloat {
            let r = d.frame.intersection(rect)
            return r.isNull ? 0 : r.width * r.height
        }
        if let d = displays.max(by: { overlap($0) < overlap($1) }), overlap(d) > 0 { return d }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.min { distance(center, $0.frame) < distance(center, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
