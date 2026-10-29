import CoreGraphics
import Foundation

struct SavedDisplay: Codable, Hashable {
    var uuid: String
    var name: String
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var frame: CGRect

    init(_ d: DisplayInfo) {
        uuid = d.uuid
        name = d.name
        vendor = d.vendor
        model = d.model
        serial = d.serial
        frame = d.frame
    }

    /// Finds this display among the connected ones: by UUID, then by
    /// vendor/model/serial in case the UUID was regenerated.
    func match(in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            ?? displays.first { serial != 0 && $0.vendor == vendor && $0.model == model && $0.serial == serial }
    }
}

struct SavedWindow: Codable, Identifiable {
    var id = UUID()
    var windowID: CGWindowID
    var pid: pid_t
    var bundleID: String?
    var appName: String
    var title: String
    var display: SavedDisplay?
    /// Global frame at capture time.
    var frame: CGRect
    /// Frame relative to the display's top-left corner, so the window lands
    /// in the right place even if the display arrangement has changed.
    var relativeFrame: CGRect
    var spaceID: UInt64?
    var spaceUUID: String?
    var desktopIndex: Int?
    var onAllDesktops: Bool
    var wasMinimized: Bool
    var wasFullscreen: Bool

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }

    var spaceLabel: String {
        if onAllDesktops { return "All desktops" }
        if wasFullscreen { return "Full screen" }
        if wasMinimized { return "Minimized" }
        return desktopIndex.map { "Desktop \($0)" } ?? "Unknown desktop"
    }

    init(_ w: LiveWindow, displays: [DisplayInfo], spaces: [DisplaySpaces]) {
        windowID = w.id
        pid = w.pid
        bundleID = w.bundleID
        appName = w.appName
        title = w.title
        frame = w.frame
        wasMinimized = w.isMinimized
        wasFullscreen = w.isFullscreen
        onAllDesktops = w.spaceIDs.count > 1

        let d = Displays.best(for: w.frame, in: displays)
        display = d.map(SavedDisplay.init)
        relativeFrame = d.map { w.frame.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) } ?? w.frame

        if w.spaceIDs.count == 1, let (_, space) = Spaces.find(w.spaceIDs[0], in: spaces) {
            spaceID = space.id
            spaceUUID = space.uuid.isEmpty ? nil : space.uuid
            desktopIndex = space.desktopIndex
        }
    }

    /// Finds the saved window among live ones. A live CGWindowID owned by
    /// the same process is the same window; otherwise fall back to the same
    /// app with the same title (e.g. after the app was relaunched).
    func match(in live: [LiveWindow], excluding claimed: Set<CGWindowID>) -> (LiveWindow, exact: Bool)? {
        if let w = live.first(where: { $0.id == windowID && $0.pid == pid && !claimed.contains($0.id) }) {
            return (w, true)
        }
        guard !title.isEmpty else { return nil }
        let sameApp = { (w: LiveWindow) in bundleID != nil ? w.bundleID == bundleID : w.appName == appName }
        if let w = live.first(where: { sameApp($0) && $0.title == title && !claimed.contains($0.id) }) {
            return (w, false)
        }
        return nil
    }
}

struct Snapshot: Codable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var windows: [SavedWindow]
}

final class SnapshotStore: ObservableObject {
    static let shared = SnapshotStore()

    @Published private(set) var snapshots: [Snapshot] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowRestore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshots.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshots = (try? decoder.decode([Snapshot].self, from: data)) ?? []
        }
    }

    func add(_ snapshot: Snapshot) {
        snapshots.append(snapshot)
        save()
    }

    func replace(_ snapshot: Snapshot) {
        guard let i = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { return }
        snapshots[i] = snapshot
        save()
    }

    func delete(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        save()
    }

    func named(_ name: String) -> Snapshot? {
        snapshots.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshots) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
