import ApplicationServices
import CoreGraphics
import Foundation

/// Undocumented SkyLight (window server) and HIServices symbols.
///
/// There is no public API for Spaces, or for reaching windows that live on a
/// Space other than the current one. Everything here is resolved at runtime
/// with dlsym, so if Apple removes a symbol the matching feature degrades
/// (e.g. windows land on the right display but not the right Space) instead
/// of the app failing to launch.
enum PrivateAPI {
    typealias ConnectionID = Int32

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func lookup<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let handle = skyLight, let p = dlsym(handle, name) { return unsafeBitCast(p, to: type) }
            if let p = dlsym(rtldDefault, name) { return unsafeBitCast(p, to: type) }
        }
        return nil
    }

    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindowsToManagedSpaceFn = @convention(c) (ConnectionID, CFArray, UInt64) -> Void
    private typealias SpaceSetCompatIDFn = @convention(c) (ConnectionID, UInt64, Int32) -> CGError
    private typealias SetWindowListWorkspaceFn = @convention(c) (ConnectionID, UnsafePointer<UInt32>, Int32, Int32) -> CGError
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let mainConnectionFn = lookup(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFn.self)
    private static let copyManagedDisplaySpacesFn = lookup(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindowsFn = lookup(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindowsFn.self)
    private static let moveWindowsToManagedSpaceFn = lookup(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"], as: MoveWindowsToManagedSpaceFn.self)
    private static let spaceSetCompatIDFn = lookup(["SLSSpaceSetCompatID", "CGSSpaceSetCompatID"], as: SpaceSetCompatIDFn.self)
    private static let setWindowListWorkspaceFn = lookup(["SLSSetWindowListWorkspace", "CGSSetWindowListWorkspace"], as: SetWindowListWorkspaceFn.self)
    private static let axGetWindowFn = lookup(["_AXUIElementGetWindow"], as: AXGetWindowFn.self)
    private static let axCreateWithRemoteTokenFn = lookup(["_AXUIElementCreateWithRemoteToken"], as: AXCreateWithRemoteTokenFn.self)

    static let connection: ConnectionID = mainConnectionFn?() ?? 0

    static var hasSpacesSupport: Bool { copyManagedDisplaySpacesFn != nil && copySpacesForWindowsFn != nil }
    static var hasRemoteTokenSupport: Bool { axCreateWithRemoteTokenFn != nil && axGetWindowFn != nil }

    /// Raw `SLSCopyManagedDisplaySpaces` output: one dictionary per display
    /// (or a single "Main" entry when "Displays have separate Spaces" is off).
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let fn = copyManagedDisplaySpacesFn, let array = fn(connection)?.takeRetainedValue() else { return [] }
        return array as? [[String: Any]] ?? []
    }

    /// Space IDs the window is assigned to. Empty for minimized or hidden
    /// windows; more than one for windows assigned to "All Desktops".
    static func spaces(forWindow wid: CGWindowID) -> [UInt64] {
        guard let fn = copySpacesForWindowsFn,
              let array = fn(connection, 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        else { return [] }
        return (array as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// Moves a window to a Space and reports whether the window server
    /// actually put it there.
    ///
    /// macOS 14.5 stopped honouring `SLSMoveWindowsToManagedSpace` from
    /// ordinary processes. The compat-ID route (tag the Space with a
    /// workspace number, move the window to that workspace, untag) still
    /// works on later releases, so it is tried first and the old call is
    /// kept as a fallback for older systems.
    static func moveWindow(_ wid: CGWindowID, toSpace sid: UInt64) -> Bool {
        if spaces(forWindow: wid) == [sid] { return true }

        if let setCompat = spaceSetCompatIDFn, let setWorkspace = setWindowListWorkspaceFn {
            let tag: Int32 = 0x7961_6265
            var window = wid
            _ = setCompat(connection, sid, tag)
            _ = setWorkspace(connection, &window, 1, tag)
            _ = setCompat(connection, sid, 0)
            usleep(50_000)
            if spaces(forWindow: wid).contains(sid) { return true }
        }

        if let move = moveWindowsToManagedSpaceFn {
            move(connection, [NSNumber(value: wid)] as CFArray, sid)
            usleep(50_000)
            if spaces(forWindow: wid).contains(sid) { return true }
        }
        return false
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindowFn else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// Builds an AX element from a remote token. Enumerating tokens is the
    /// only way to reach windows on Spaces other than the active one, since
    /// `kAXWindowsAttribute` only lists windows on the current Space.
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let fn = axCreateWithRemoteTokenFn else { return nil }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
        return fn(token as CFData)?.takeRetainedValue()
    }
}
