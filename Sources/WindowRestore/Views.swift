import AppKit
import SwiftUI

struct WindowRestoreApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Window Restore", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.store)
                .frame(minWidth: 640, minHeight: 480)
        }
        MenuBarExtra("Window Restore", systemImage: "macwindow.on.rectangle") {
            MenuContent()
                .environmentObject(model)
                .environmentObject(model.store)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SnapshotStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Window Restore…") { showMain() }
        Divider()
        if store.snapshots.isEmpty {
            Text("No snapshots yet")
        } else {
            Text("Restore")
            ForEach(store.snapshots) { snapshot in
                Button("\(snapshot.name)  (\(snapshot.windows.count))") {
                    model.restore(snapshot) { allRestored in
                        if !allRestored { showMain() }
                    }
                }
            }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.accessibilityTrusted {
                AccessibilityBanner()
            }
            TabView {
                CaptureView().tabItem { Text("Capture") }
                SnapshotsView().tabItem { Text("Snapshots") }
            }
            .padding()
        }
        .onAppear {
            model.refresh()
            // Ask on launch; a rebuild clears the approval and nothing else would prompt.
            if !AXIsProcessTrusted() { model.requestAccessibility() }
        }
    }
}

struct AccessibilityBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Window Restore needs Accessibility access to read window titles and move windows.")
            Spacer()
            Button("Grant Access…") { model.requestAccessibility() }
            Button("Check Again") { model.refresh() }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}

// MARK: - Capture

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    private struct Group: Identifiable {
        let id: String
        let windows: [LiveWindow]
    }

    /// Windows grouped as "Display — Desktop N", in display then desktop order.
    private var groups: [Group] {
        let keyed = Dictionary(grouping: model.windows) { w in
            "\(model.displayName(for: w)) — \(Spaces.label(for: w.spaceIDs, in: model.spaces))"
        }
        return keyed.keys.sorted().map { Group(id: $0, windows: keyed[$0]!.sorted { $0.appName < $1.appName }) }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Choose the windows to remember.").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh() }
                Button("All") { model.selection = Set(model.windows.map(\.id)) }
                Button("None") { model.selection.removeAll() }
            }
            List {
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.windows) { w in
                            Toggle(isOn: binding(for: w.id)) { WindowRow(window: w) }
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                TextField("Snapshot name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save Snapshot (\(model.selection.count))", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty)
            }
        }
    }

    private func save() {
        guard !model.selection.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        model.saveSnapshot(named: trimmed.isEmpty
            ? Date().formatted(date: .abbreviated, time: .shortened) : trimmed)
        name = ""
    }

    private func binding(for id: CGWindowID) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(id) },
            set: { if $0 { model.selection.insert(id) } else { model.selection.remove(id) } }
        )
    }
}

struct WindowRow: View {
    let window: LiveWindow

    var body: some View {
        HStack {
            if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(window.appName).fontWeight(.medium)
            Text(window.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(Int(window.frame.width))×\(Int(window.frame.height))")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

// MARK: - Snapshots

struct SnapshotsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SnapshotStore

    @AppStorage("reportHeight") private var reportHeight: Double = 200
    @State private var dragStartHeight: Double?

    // SwiftUI's VSplitView wouldn't let the divider move here, so the report
    // gets its own drag handle and a remembered height.
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                snapshotList
                    .frame(maxHeight: .infinity)
                if let outcomes = model.outcomes {
                    ResizeHandle()
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStartHeight ?? reportHeight
                                    dragStartHeight = start
                                    reportHeight = limit(start - drag.translation.height, in: geo.size.height)
                                }
                                .onEnded { _ in dragStartHeight = nil }
                        )
                    OutcomesView(title: model.outcomesTitle, outcomes: outcomes)
                        .frame(height: limit(reportHeight, in: geo.size.height))
                }
            }
        }
    }

    /// Keeps the report at least 80pt tall while leaving the list 120pt.
    private func limit(_ height: Double, in total: CGFloat) -> Double {
        min(max(height, 80), max(80, Double(total) - 120))
    }

    @ViewBuilder private var snapshotList: some View {
        if store.snapshots.isEmpty {
            Text("No snapshots yet. Select windows on the Capture tab and save them.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.snapshots.reversed()) { snapshot in
                    SnapshotRow(snapshot: snapshot)
                }
            }
        }
    }
}

struct ResizeHandle: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Divider()
            Capsule().fill(.tertiary).frame(width: 40, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }
}

struct SnapshotRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SnapshotStore
    let snapshot: Snapshot

    var body: some View {
        DisclosureGroup {
            ForEach(snapshot.windows) { w in
                HStack {
                    Text(w.label).lineLimit(1)
                    Spacer()
                    Text("\(w.display?.name ?? "Unknown display") · \(w.spaceLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(snapshot.name).fontWeight(.semibold)
                    Text("\(snapshot.windows.count) windows · \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore") { model.restore(snapshot) }
                    .disabled(model.isBusy)
                Menu {
                    Button("Update with Current Positions") { model.updateSnapshot(snapshot) }
                    Divider()
                    Button("Delete", role: .destructive) { store.delete(snapshot) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

struct OutcomesView: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let outcomes: [RestoreOutcome]

    var body: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(outcomes) { o in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: icon(o.status)).foregroundStyle(color(o.status))
                            VStack(alignment: .leading) {
                                Text("\(o.window.label) — \(o.status.rawValue)").lineLimit(1)
                                ForEach(o.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        } label: {
            HStack {
                Text(title).font(.headline)
                Text(RestoreOutcome.summary(outcomes)).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { model.outcomes = nil }.buttonStyle(.link)
            }
        }
    }

    private func icon(_ s: RestoreOutcome.Status) -> String {
        switch s {
        case .restored: "checkmark.circle.fill"
        case .alreadyInPlace: "checkmark.circle"
        case .skipped: "arrow.uturn.right.circle"
        case .partial: "exclamationmark.circle.fill"
        case .notOpen: "minus.circle"
        case .displayMissing: "display.trianglebadge.exclamationmark"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(_ s: RestoreOutcome.Status) -> Color {
        switch s {
        case .restored: .green
        case .alreadyInPlace, .skipped: .secondary
        case .partial, .displayMissing: .orange
        case .notOpen: .secondary
        case .failed: .red
        }
    }
}
