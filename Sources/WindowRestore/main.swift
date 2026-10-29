import AppKit
import ApplicationServices
import Foundation

/// Command-line entry points, handy for binding restores to a hotkey via
/// Shortcuts, Raycast, skhd, etc. With no arguments the menu bar app runs.
enum CLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count > 1 else { return nil }
        _ = NSApplication.shared // NSScreen needs a window server connection

        switch args[1] {
        case "list":
            let spaces = Spaces.all()
            let displays = Displays.active()
            for d in displays {
                print("Display \(d.name)  uuid=\(d.uuid)  frame=\(d.frame)\(d.isMain ? "  (main)" : "")")
            }
            for ds in spaces {
                let desc = ds.spaces.map { $0.isFullscreen ? "FS(\($0.id))" : "D\($0.desktopIndex ?? 0)(\($0.id))" }
                print("Spaces on \(ds.displayIdentifier): \(desc.joined(separator: " ")) current=\(ds.currentSpaceID ?? 0)")
            }
            print("Accessibility trusted: \(AXIsProcessTrusted())")
            for w in WindowCatalog.list() {
                let display = Displays.best(for: w.frame, in: displays)?.name ?? "?"
                print("[\(w.id)] \(w.appName) — \(w.title.isEmpty ? "(untitled)" : w.title)  \(w.frame)  "
                    + "\(display) / \(Spaces.label(for: w.spaceIDs, in: spaces))\(w.element == nil ? "" : "  ax")")
            }
            return 0

        case "snapshots":
            for s in SnapshotStore.shared.snapshots {
                print("\(s.name)  (\(s.windows.count) windows, \(s.createdAt.formatted()))")
            }
            return 0

        case "restore" where args.count > 2:
            let name = args[2...].joined(separator: " ")
            guard let snapshot = SnapshotStore.shared.named(name) else {
                fputs("No snapshot named “\(name)”\n", stderr)
                return 1
            }
            let outcomes = Restorer.restore(snapshot)
            for o in outcomes {
                print("\(o.status.rawValue): \(o.window.label)")
                o.notes.forEach { print("    \($0)") }
            }
            return outcomes.allSatisfy { $0.status == .restored || $0.status == .notOpen } ? 0 : 2

        default:
            fputs("""
            usage: WindowRestore                  launch the menu bar app
                   WindowRestore list             show displays, desktops and windows
                   WindowRestore snapshots        list saved snapshots
                   WindowRestore restore <name>   restore a saved snapshot

            """, stderr)
            return 64
        }
    }
}

if let status = CLI.run(CommandLine.arguments) {
    exit(status)
}
WindowRestoreApp.main()
