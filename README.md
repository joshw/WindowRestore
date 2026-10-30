# Window Restore

A menu bar app that remembers where a chosen set of windows are (display,
desktop/Space, position and size) and moves them back on demand. It is built
for this case: an external display is unplugged, macOS piles its windows
onto the built-in screen, the display comes back, and you want everything
returned where it was.

## Build and run

Needs the Xcode command line tools (no Xcode project).

```bash
./scripts/build-app.sh
open build/WindowRestore.app
```

On first launch, click **Grant Access…** and enable Window Restore under
System Settings → Privacy & Security → Accessibility, then **Check Again**.

The build is ad-hoc signed, so macOS treats every rebuild as a new app. The
old approval still shows as on in System Settings but no longer applies, and
the app keeps asking for access. After each rebuild, clear the stale entry,
relaunch, and approve it again:

```bash
tccutil reset Accessibility local.windowrestore
open build/WindowRestore.app
```

To avoid this, build with a stable signing identity:
`SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`.

## Use

- **Capture** tab: windows on every display and desktop, grouped by
  "Display — Desktop N". Tick the ones you want, name the snapshot, save.
- **Snapshots** tab, or the menu bar icon: **Restore**. A report lists each
  window as moved, already in place, partly restored, not open, or display
  not connected, with totals such as "3 moved, 5 already in place".
- **⋯ → Update with Current Positions** re-captures a snapshot's windows
  that are still open.

Command line (useful for a hotkey via Shortcuts, Raycast, skhd…):

```bash
build/WindowRestore.app/Contents/MacOS/WindowRestore list
build/WindowRestore.app/Contents/MacOS/WindowRestore restore "Desk setup"
```

When run from a terminal, the Accessibility permission belongs to the
terminal app, not Window Restore.

Snapshots are stored in `~/Library/Application Support/WindowRestore/snapshots.json`.

## How it works

| What | How |
|---|---|
| Find windows on all Spaces | `CGWindowListCopyWindowInfo(.optionAll)`, filtered with Accessibility to real document windows |
| Reach windows on other Spaces | Accessibility only lists current-Space windows, so off-Space ones are found by enumerating AX remote tokens (`_AXUIElementCreateWithRemoteToken`, the technique AltTab uses) |
| Identify a display | Display UUID (stable across reconnects), falling back to vendor/model/serial |
| Remember a position | Frame relative to the display's top-left, so it still works if you rearrange displays; clamped if the display's resolution changed |
| Identify a window | `CGWindowID` + PID (same window still open); otherwise the same app with the same title |
| Identify a desktop | Space ID, then Space UUID, then desktop number on that display. After a reconnect, the external display's Spaces are usually new, so "Desktop 2 of the LG monitor" is what still matches |
| Move to a desktop | Private SkyLight calls where the window server still allows them (up to macOS 14.x). On macOS 15 and later these are blocked for ordinary apps, so it drags the window by its title bar while pressing the "Move left/right a space" shortcut |

Restore order per window: leave full screen or unminimize if needed → set
the frame on the target display (macOS puts it on that display's current
desktop) → move it to the saved desktop → minimize or re-enter full screen if
that's how it was saved.

## Limitations

- **Moving windows between desktops on macOS 15+ is visible.** You'll see
  the desktops slide while windows are carried across. Don't touch the mouse
  until it finishes. Afterwards each display returns to the desktop it was
  showing. This needs the "Move left a space" / "Move right a space"
  shortcuts turned on (System Settings › Keyboard › Keyboard Shortcuts ›
  Mission Control). They're on by default.
- If a desktop move fails anyway, the window still goes to the right display
  and position, and the report says "Could not move to Desktop N" with the
  reason.
- If a desktop no longer exists (e.g. you had 3 on the external display and
  macOS recreated only 1), the window stays on that display's current desktop.
  The app does not create desktops.
- Windows set to "All Desktops" keep that setting. Only their frame is restored.
- Some apps limit their own window sizes or refuse AX moves (some Electron or
  Java apps, for example). These show up as "Partly restored".
- With "Displays have separate Spaces" turned off, desktop numbers are shared
  across displays.
