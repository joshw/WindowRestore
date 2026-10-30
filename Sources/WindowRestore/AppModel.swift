import AppKit
import ApplicationServices
import Foundation

final class AppModel: ObservableObject {
    @Published var windows: [LiveWindow] = []
    @Published var displays: [DisplayInfo] = []
    @Published var spaces: [DisplaySpaces] = []
    @Published var selection: Set<CGWindowID> = []
    @Published var isBusy = false
    @Published var outcomes: [RestoreOutcome]?
    @Published var outcomesTitle = ""
    @Published var accessibilityTrusted = AXIsProcessTrusted()

    let store = SnapshotStore.shared
    private let worker = DispatchQueue(label: "WindowRestore.worker", qos: .userInitiated)

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        waitForAccessibility()
    }

    /// Notices when access is granted in System Settings and reloads, so
    /// the banner clears without pressing Check Again.
    private func waitForAccessibility() {
        guard !AXIsProcessTrusted() else {
            accessibilityTrusted = true
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.waitForAccessibility() }
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        isBusy = true
        worker.async {
            // Background tabs follow the tab that's showing, so only that one is offered.
            let windows = WindowCatalog.list().filter { !$0.isBackgroundTab }
            let spaces = Spaces.all()
            DispatchQueue.main.async {
                self.windows = windows
                self.spaces = spaces
                self.displays = Displays.active()
                self.selection.formIntersection(windows.map(\.id))
                self.isBusy = false
            }
        }
    }

    func saveSnapshot(named name: String) {
        let chosen = windows.filter { selection.contains($0.id) }
        let snapshot = Snapshot(name: name, windows: chosen.map { SavedWindow($0, displays: displays, spaces: spaces) })
        store.add(snapshot)
        selection.removeAll()
    }

    /// Re-captures current positions of the windows in a snapshot that are
    /// still open; closed ones keep their old entries.
    func updateSnapshot(_ snapshot: Snapshot) {
        isBusy = true
        worker.async {
            let live = WindowCatalog.list()
            let spaces = Spaces.all()
            DispatchQueue.main.async {
                let displays = Displays.active()
                var claimed = Set<CGWindowID>()
                var updated = snapshot
                updated.windows = snapshot.windows.map { saved in
                    guard let (matched, _) = saved.match(in: live, excluding: claimed),
                          let w = matched.host(in: live), !claimed.contains(w.id)
                    else { return saved }
                    claimed.insert(matched.id)
                    claimed.insert(w.id)
                    var fresh = SavedWindow(w, displays: displays, spaces: spaces)
                    fresh.id = saved.id
                    return fresh
                }
                self.store.replace(updated)
                self.isBusy = false
            }
        }
    }

    func restore(_ snapshot: Snapshot, completion: ((Bool) -> Void)? = nil) {
        isBusy = true
        worker.async {
            let outcomes = Restorer.restore(snapshot)
            DispatchQueue.main.async {
                self.outcomes = outcomes
                self.outcomesTitle = "Restored “\(snapshot.name)” at \(Date().formatted(date: .omitted, time: .shortened))"
                self.isBusy = false
                completion?(outcomes.allSatisfy(\.status.succeeded))
            }
        }
    }

    func displayName(for window: LiveWindow) -> String {
        Displays.best(for: window.frame, in: displays)?.name ?? "Unknown display"
    }
}
