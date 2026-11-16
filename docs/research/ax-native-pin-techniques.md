# Native AX window pinning on macOS — research report

**Repository:** `topit` (fork of <https://github.com/lihaoyun6/Topit>, AGPL-3.0)
**Goal:** replace the ScreenCaptureKit "mirror window" pin with a **native** pin that keeps the real
window on top using only public APIs (Accessibility + CoreGraphics window list).
**Date:** 2026-11-16
**Scope:** research only — no code was changed.

---

## Executive summary

1. **Reference implementations.** `turhe123/pin-window-on-top` (MIT) is essentially the planned
   design already written down in Swift: pinned registry keyed by `AXUIElement` + matched
   `CGWindowID`, `AXObserver` per pinned PID, `NSWorkspace.didActivateApplicationNotification` +
   `activeSpaceDidChangeNotification` + a **0.3 s** `Timer`, **150 ms raise rate limit**, gentle
   mode, full-screen pause, Space/minimize pause via `.optionOnScreenOnly`, auto-unpin on
   `kAXUIElementDestroyedNotification` / app terminate, and a re-activate-the-previous-app dance
   because "AXRaise can steal focus".
   `itsabhishekolkha/AlwaysOnTop` (cruder): 0.5 s timer + `kAXMainAttribute` + `AXRaise` + throttled
   AppleScript `activate` once per second.
   Both are **Accessibility-only**, no Screen Recording. Relevant adjacent prior art: AltTab,
   AutoRaise, Swindler, AeroSpace, Peekaboo, mctiler.

2. **Does `kAXRaiseAction` raise a foreign window above the ACTIVE app?** **Yes, but it is not a
   guarantee, and this is the single biggest risk in the design.** Apple's own doc hedges ("as
   frontmost as is allowed by the containing application's circumstances"), and there is directly
   conflicting field evidence:
   - AltTab's own commit: "`_SLPSSetFrontProcessWithOptions` sets the front process, while
     `makeKeyWindow` and `kAXRaiseAction` **only move the window in the z-order**" — i.e. AXRaise does
     change z-order across apps but does *not* front the process.
   - mctiler #8 (2026): `AXRaise` returned **success (0)** yet the WindowServer front-to-back list
     still placed an overlapping foreground iTerm window above System Settings: "successful AXRaise
     responses **do not establish the requested global stacking result**".
   - SO #21541561 (2014): AXRaise "only brings the window forward past all the windows of the same
     application" — accepted answer = additionally activate the app.
   Treat "raise wins over the active app" as **probabilistic / app-dependent**, design for "eventually
   correct with visible flicker", and keep the existing mirrored mode as fallback.

3. **Hover detection.** Use **polling**, not a tap. AutoRaise — the most widely used
   focus-follows-mouse implementation on macOS — polls `NSEvent.mouseLocation` on a timer
   (`-pollMillis`, default 50 ms, min 20 ms). Topit's own `WindowHighlighter` already uses
   `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])`. A filtering `CGEventTap` is the
   worst option here: it needs Input Monitoring **and** (for `.defaultTap`) Accessibility, is silently
   killed by `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` (especially around
   sleep/wake), can come back inert after re-signing, and — worst case — **freezes all input** if your
   callback stops returning events. A listen-only tap for `.mouseMoved` only is the only tap worth
   considering, and even it is unnecessary at 10 Hz.

4. **AXObserver pitfalls.** Observer must be attached to a run loop before it delivers anything; add
   `AXObserverGetRunLoopSource()` to `CFRunLoopGetMain()`. `AXObserverAddNotification` commonly returns
   `kAXErrorCannotComplete` (app still launching / permission not yet effective / some processes such
   as `UIKitSystem` never allow subscription) — CopilotForXcode logs "will try again later";
   yabai hit an **infinite retry loop** on it, so bound retries. Electron/Chromium rebuild the
   AXUIElement while keeping the same `CGWindowID` and post **no** destroyed notification, after which
   `AXRaise` silently no-ops with `kAXErrorInvalidUIElement` (AltTab `eb4c08c`).

5. **Space / minimized / closed with public APIs.** There is **no public Space enumeration API**. The
   reliable public proxy is: `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`
   contains essentially only the windows of the **current Space** (AltTab #14: "when removing
   `.optionOnScreenOnly` … the windows from other spaces are returned"); membership in that set ⇒
   on-current-Space-and-not-minimized. Absence ⇒ other Space, minimized, or closed. Use
   `kAXMinimizedAttribute` to disambiguate minimized. The optional `kCGWindowWorkspace` key exists but
   AltTab found private `CGSGetWindowWorkspace` broken since 10.8; treat any workspace-id reading as
   best-effort only.

6. **Hit-testing.** `kCGWindowBounds` / `AXPosition` are **top-left origin**; `NSEvent.mouseLocation`
   is **bottom-left origin of the *main* display**; multi-monitor uses negative coordinates off the
   main display. Convert with `y = CGDisplayBounds(CGMainDisplayID()).height - y` (rob mayoff,
   SO #75406300), which is also what pin-window-on-top does with `NSScreen.screens.first!.frame.maxY`.
   Use `NSScreen.frame` for "which screen contains the point" (`NSMouseInRect`), **not**
   `visibleFrame` (excludes menubar/Dock). Use `AXUIElementCopyElementAtPosition` **only with a
   cross-check**: it "sees through" windows that are invisible to AX (Quick Look previews — AutoRaise
   #292) and happily returns `kAXErrorSuccess` for the app underneath.

7. **Screen Recording gating.** Accessibility alone covers everything in this design (pin-window-on-top
   explicitly states it requests no Screen Recording). But merely **constructing** ScreenCaptureKit
   content — `SCShareableContent` — triggers the Screen Recording prompt: Apple's own sample says
   "The first time you run this sample, the system prompts you to grant the app Screen Recording
   permission", and `NSScreenCaptureUsageDescription` is required. So a native mode must
   **lazily/dynamically avoid loading or touching SCManager code paths**, including things like
   `SCManager.updateAvailableContentSync()` used by Topit's existing `getSCWindowWithID`.

---

## 1. Reference implementations (source read)

### 1.1 `turhe123/pin-window-on-top` — MIT

Cloned and read line-by-line (`Sources/Services/PinManager.swift`, `AXHelpers.swift`,
`BorderOverlay.swift`, plus `README.md` and `SPEC.md`).
Repo metadata via API: MIT, Swift, default branch `main`, **0 stars, single commit dated
2026-10-21**, and `README.md` states it was "written by Claude Code inside an automated pipeline,
from a plain-English spec". It is therefore a *spec-shaped* reference, not battle-tested code — but
it is the closest existing articulation of the design and worth mining.

Algorithm (all from `PinManager.swift`):

| Concern | Implementation | Location |
| --- | --- | --- |
| Pin identity | `AXUIElement` + `pid` + `CGWindowID` + title | `PinnedWindow` |
| WindowID↔AX matching | `CGWindowListCopyWindowInfo` filtered by owner PID, scoring bounds (±2 pt) then title; skip already-taken IDs; returns `0` if ambiguous | `CGWindowInfo.match` |
| Keep-on-top triggers | `didActivateApplicationNotification`, `activeSpaceDidChangeNotification`, `didTerminateApplicationNotification`, `kAXFocusedWindowChanged`/`kAXMainWindowChanged`, plus `Timer` @ **0.3 s** | `PinManager.start`, `handleAX` |
| Occlusion check | rather than "is it topmost": take the on-screen list filtered to `layer == 0` and not-own-PID, find the pinned ID's index, and ask whether **any non-pinned window before it intersects its bounds** | `isAnyPinOccluded` |
| Rate limit | `minRaiseInterval = 0.15 s`; `scheduleRaise()` coalesces and `asyncAfter`s the remainder | `scheduleRaise` |
| Gentle mode | `UserDefaults "gentleMode"` → skip the timer-driven raise entirely, only raise on activation/focus changes | `tick`, `handleAX` |
| Full-screen pause | `AX.frontmostIsFullScreen()` reads a **literal `"AXFullScreen"`** attribute string on the frontmost app's focused window; preference `pauseInFullScreen` defaults **true** | `isFullScreenPaused`, `AXHelpers` |
| Space / minimize pause | `hidden = kAXMinimizedAttribute || windowID not in CGWindowInfo.onScreen()`; sets `paused`, overlay hidden | `refresh` |
| Closed detection | `kAXUIElementDestroyedNotification` → `removePins`; also polling `AX.isAlive(element)` = `AXUIElementCopyAttributeValue(kAXRoleAttribute) != .invalidUIElement` | `handleAX`, `AX.isAlive` |
| Focus steal mitigation | after raising all pins, if the frontmost app is not one of the pinned PIDs, re-`activate()` it after **0.05 s** and only if it is still not frontmost | `raisePinned` |
| Own-window guard | bail out if `NSWorkspace.frontmostApplication` is our own PID (don't cover our Settings) | `raisePinned` |
| Permission revoked at runtime | every tick re-checks `AXIsProcessTrusted()`; on loss, tears down all observers + overlays; on regain, re-observes | `checkTrust` |
| Notifications | window: `kAXMoved`, `kAXResized`, `kAXUIElementDestroyed`, `kAXWindowMiniaturized`, `kAXWindowDeminiaturized`, `kAXTitleChanged`; app: `kAXFocusedWindowChanged`, `kAXMainWindowChanged` | `PinManager.windowNotifications` |
| Overlay panel | `NSPanel` with `[.borderless, .nonactivatingPanel]`, `ignoresMouseEvents = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`; positioned by flipping Y against `NSScreen.screens.first!.frame.maxY` | `BorderOverlay` |

`SPEC.md` edge cases restate these explicitly, including: "Avoid infinite raise loops by rate limiting
raises to once every 150 milliseconds", "pinned windows that become minimized or move to another
Space are paused and resume when visible", "Raising via AXRaise can steal focus in some apps, so
re-activate the previously frontmost app right after".

Known limitation it documents honestly: "a pinned window can briefly sit behind another one until the
next raise" — i.e. the approach is a *repair loop*, not a stacking guarantee.

### 1.2 `itsabhishekolkha/AlwaysOnTop` — cruder, same family

Read `Main/WindowManager.swift` (1121 lines). Approach:

- `Timer` @ **0.5 s** while pinned (`pinCheckInterval`), calling `setWindowLevel(_:level:)`.
- `setWindowLevel` sets `kAXMainAttribute` = true, then `AXUIElementPerformAction(window, kAXRaiseAction)`,
  and then **re-applies the window's own position and size** to "simulate level change".
- If raise fails → AppleScript fallback `tell app activate / set index of window 1 to 1`, throttled to
  **once per second** (`appleScriptThrottleInterval`).
- Short-circuits when `kAXFrontmostAttribute` is already true.
- Unpins on `didTerminateApplicationNotification`.

The author describes it publicly: "Instead of using ScreenCaptureKit to stream window content,
AlwaysOnTop leverages the Accessibility API (AXUIElement) to set the target window's main attribute
and raise it, combined with AppleScript to activate the app and maintain focus", "relying on a timer
checking every 0.5 seconds to maintain the window's position".

**Takeaway:** two independent implementations independently chose ~0.15–0.5 s timers + raise
rate/AppleScript throttling. The position/size re-apply trick is a hack with no public-API basis — do
not copy it.

### 1.3 Other prior art worth reading (all AX-based, not exhaustive)

| Project | Relevance | License |
| --- | --- | --- |
| `lwouis/alt-tab-macos` | Deepest public corpus of AXRaise/z-order war stories; several commits are pure AXRaise race analysis (see §2) | MIT |
| `sbmpost/AutoRaise` | Focus-follows-mouse: **polls** mouse @ 50 ms, `AXUIElementCopyElementAtPosition` hit test with `CGWindowList` fallback | GPL-3.0 |
| `tmandry/Swindler` | "All window managers on macOS must use the C-based accessibility APIs, which are difficult to use and are **surprisingly buggy themselves**"; documents event-ordering bugs (`MainWindowChanged` before `WindowCreated`) | MIT |
| `nikitabobko/AeroSpace` | Avoids native Spaces entirely ("their considerable limitations"); documents the AX-raise/activate race | MIT |
| `openclaw/Peekaboo` | `docs/focus.md` is an unusually complete write-up of cross-Space focus policy with public APIs | — |
| `tjukkefeiten/mctiler` | Issue #8 is the clearest published counter-example to "AXRaise ⇒ correct stacking" | — |

---

## 2. Does `kAXRaiseAction` put a foreign window above the ACTIVE app's windows?

### The documentation position

Apple's doc for `kAXRaiseAction`:

> "Causes a window to become as frontmost as is allowed by the containing application's
> circumstances. Note that an application's floating windows (such as inspector windows) might remain
> above a window that performs the raise action."
> — <https://developer.apple.com/documentation/applicationservices/kaxraiseaction>

That wording ("as is allowed by the containing application's circumstances") is the whole problem: it
is not a cross-process stacking primitive, it is a request forwarded to the *owning* app.

### Evidence that it does change cross-app z-order

- AltTab `886f21a`: "`_SLPSSetFrontProcessWithOptions` sets the front process, while `makeKeyWindow`
  and `kAXRaiseAction` **only move the window in the z-order**." This is a maintainer who measures
  WindowServer behaviour daily, describing AXRaise as a z-order call that works across apps.
- AltTab `886f21a` also quantifies the cost: "The raise is a raw `AXUIElementPerformAction` against
  another app, bounded only by the **1s messaging timeout**" → raises are *synchronous IPC to another
  process*, which is why every implementation serialises and rate-limits them.
- SO #48490864: "if you're looking to change the order of a normal-level window relative to others
  then you're probably looking for Accessibility's `kAXRaiseAction`".
- Both reference implementations above demonstrably do keep foreign windows above other apps most of
  the time using exactly this primitive.

### Evidence that it is not reliable

- **mctiler #8 (2026-09-16, still open):** "System Settings … last AXRaise result is 0 (success).
  Nevertheless, the WindowServer front-to-back list places an overlapping foreground iTerm window
  above Settings. … This confirms that **successful AXRaise responses do not establish the requested
  global stacking result**. The delayed raises did not resolve the issue."
- **SO #21541561 (2014):** "It only brings the window forward past all the windows of the same
  application, which is not what happens when you click the title bar of an app." Accepted answer:
  select the window **and then activate the application** (`-[NSRunningApplication activateWithOptions:]`).
- **Peekaboo #801 (macOS 26.7):** Calculator and System Settings **list** `AXRaise` among their
  actions but answer it with `kAXErrorAttributeUnsupported (-25205)` even when frontmost. Peekaboo's
  conclusion: "A native `AXRaise` response of action-unsupported … adds no raise dispatch unit …
  Unsupported raise does not itself prove focus".
- **stim #2496 / PR #2503:** SwiftUI `WindowGroup` windows systematically fail a guard requiring
  `AXUIElementPerformAction(window, kAXRaiseAction)` to succeed. AppKit windows work, SwiftUI windows
  do not.
- **AltTab `eb4c08c`:** for Electron/Zoom, "kAXRaise then **no-ops** while `_SLPS` only fronts the
  process, so the window ends up focused but still behind another app."

**Design conclusion:** never trust the return code. Always verify by reading back the on-screen
window list and comparing order, exactly as `isAnyPinOccluded()` does. If verification fails N times
in a row for a given window, surface it (e.g. offer the legacy mirrored mode for that window).

### Sub-cases

**Fullscreen / Split View / native full screen.** A full-screen window occupies its own Space. You
cannot stack above it with public APIs, and it is the reason the reference implementations added an
explicit pause. pin-window-on-top pauses pins whenever the frontmost app's focused window reports
`AXFullScreen == true` **and** that app owns no pin; noticky's 2026 guide is blunt about the general
landscape: tools built on window pinning are "weak across fullscreen Spaces" because "once you enter
a fullscreen Space, most pinned … windows disappear". Split View behaves like two windows on one
Space — normal rules apply, but the second half belongs to the active app and will win on activation.

**Stage Manager.** No public API exposes Stage Manager state; there is no documented interaction with
AXRaise at all. The only concrete field data found is negative: third-party utilities report that when
Stage Manager is enabled, window geometry/state retrieval degrades (e.g. `get_window_state` capturing
thumbnail-sized windows), and Stage Manager "breaks" position/size scripts. **Recommendation: treat
Stage Manager as untested/unsupported in v1, and detect it only indirectly** — e.g. `AXFullScreen`
false but `CGWindowListCopyWindowInfo` showing the pinned window with a frame that does not match the
AX frame, or the window being absent from `.optionOnScreenOnly`.

**Windows on other Spaces.** This is the case the design must *pause*, not repair — and it is also the
case with the least public API surface:
- System Events/AppleScript cannot even see windows in other Spaces ("System Events can see the
  windows in the desktop you're currently IN. It cannot see the windows that are in open desktops
  your are NOT currently IN.").
- `kAXWindowsAttribute` "returns `[]` for apps that have windows in another space" (AltTab #14) —
  so you literally cannot obtain the `AXUIElement` to raise.
- Raising does **not** itself switch Spaces: Peekaboo's focus policy needs an explicit
  `--space-switch` / `--bring-to-current-space` flag and by default "Refuse an unintended Space
  switch" and "Switches Spaces only with explicit foreground consent". Anything that *does* move you
  across Spaces (AltTab, HyperSwitch) uses private APIs or the "invisible windows on each Space"
  trick: "they place invisible windows on each space that they use to first make that space focus,
  and then they re-focus the target window" (AltTab #447; also broken since macOS 12.3 per that
  thread).
- Related macOS user preference worth knowing: "when switching to an application, switch to a Space
  with open windows for that application" — if enabled, the **re-activate-previous-app** step of the
  raise loop can yank the user to another Space. Another reason to make that step optional.

**Minimized windows.** `AXRaise` on a minimized window is a documented no-op in practice
("macOS: click-to-focus fails silently when target terminal window is minimized (AXRaise is a
no-op)"). You must set `kAXMinimizedAttribute = false` (or simply pause) instead. Both reference
implementations pause.

---

## 3. Event tap vs polling for hover detection

| Approach | Permissions | Failure modes | Works while not frontmost? |
| --- | --- | --- | --- |
| `CGEvent.tapCreate` with `.listenOnly` | **Input Monitoring** (`CGPreflightListenEventAccess`) | disabled by timeout / user input; can be silently inert after re-signing | yes |
| `CGEvent.tapCreate` with `.defaultTap` | Input Monitoring **+ Accessibility** | same, plus **input freeze** if your callback stalls (filtering taps hold the event stream) | yes |
| `NSEvent.addGlobalMonitorForEvents` | **Accessibility** (per Apple's Quinn, thread 707680: "the former requires the Accessibility privilege whereas the latter requires the Input Monitoring privilege" — "for weird historical reasons") | not reliable for every event class (media keys missed); monitor blocks the runloop inside MenuBarExtra menus | yes |
| `Timer` polling `NSEvent.mouseLocation` | **none** | only "stale by one tick"; CPU cost at high frequency | yes |

**What open-source apps actually do:**

- **AutoRaise** — the canonical focus-follows-mouse tool — **polls**: `-pollMillis: How often to poll
  the mouse position and consider a raise/focus. Lower values increase responsiveness but also CPU
  load. Minimum = 20 and default = 50`. It resolves the window under the cursor with
  `AXUIElementCopyElementAtPosition` and keeps a `fallback()`/`topwindow()` path through
  `CGWindowListCopyWindowInfo`.
- **Topit itself** already uses `NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])` in
  `WindowHighlighter.registerMouseMonitor()` plus `NSEvent.mouseLocation` in several places — so the
  hover-pinning feature should follow the existing house style rather than introduce a tap.
- **AeroSpace** has CGEventTap only on its wishlist (issue #1012 "Investigate a possibility to use
  `CGEvent.tapCreate` API for global hotkeys") — i.e. even a very mature window manager avoids taps
  for its main loops.

**Recommendation:** 10 Hz (100 ms) `Timer` — or reuse the existing global-monitor — and *never* a
tap. Justification, all sourced:
- Tap disable handling is mandatory boilerplate: `kCGEventTapDisabledByTimeout` /
  `kCGEventTapDisabledByUserInput` must be caught in the callback and re-enabled with
  `CGEvent.tapEnable` (SO #2817680; the legacy Quartz Event Services reference states "If an event
  tap becomes unresponsive, or if a user requests that event taps be disabled, then a
  `kCGEventTapDisabled` event is passed to the event tap callback function"). Reported real-world
  breakage: keybindings permanently dead after sleep/wake; input capture dying permanently when the
  display turns off; input frozen for the whole system when trust is revoked while the callback keeps
  re-enabling.
- "**A non-nil tap is not a healthy tap.** Always verify `tapIsEnabled` at runtime, not just at
  install time." Taps can also be installed but functionally inert after re-signing + Launch Services
  launch.
- Secure Input blocks taps for keyboard events entirely — less relevant for `.mouseMoved`, but it is
  the classic "why did my tap stop" report.
- Fullscreen apps: no evidence found that taps stop working, but the *hit test* result is what
  matters and a fullscreen Space has nothing to hover over.

**Note on `.cgSessionEventTap` vs `.cgHIDEventTap`:** taps must be attached to a `CFRunLoop` source
(`CFMachPortCreateRunLoopSource`) and added to a run loop (`CFRunLoopGetCurrent()` or
`CFRunLoopGetMain()`) — another moving part polling avoids entirely.

---

## 4. AXObserver pitfalls

### Lifecycle

- Create per **PID** with `AXObserverCreate(pid, callback, &observer)`.
- **Must be attached to a run loop before it can deliver anything**: the AXUIElement.h reference states
  "The observer must be added to a run loop before it can receive notifications. Note that releasing
  the `AXObserverRef` automatically removes …". In Swift: `CFRunLoopAddSource(CFRunLoopGetMain(),
  AXObserverGetRunLoopSource(observer), .defaultMode)` (what pin-window-on-top does) or `.commonModes`
  (what oomol-lab/CloseUp does). Notifications arrive on the run loop you added the source to — so a
  main-run-loop source means callbacks on the main thread, which is also where you want to touch
  SwiftUI/`@Published`. Swift 6 note: the callback is a C function pointer; hop to `MainActor` inside
  it if your storage is actor-isolated.
- One observer per PID can watch both the application element and individual window elements. Do
  **not** create one observer per window (pin-window-on-top keeps `[pid: AXObserver]`).
- Tear down with `AXObserverRemoveNotification` per notification and
  `CFRunLoopRemoveSource` before dropping the observer.

### Notifications worth subscribing to

- `kAXUIElementDestroyedNotification` — window closed. **Primary close signal.**
- `kAXMovedNotification`, `kAXResizedNotification` — for following the window (overlay/hover panel).
  Caveat from SO #15303973: notifications may be delivered only *after* the move finished, so do not
  expect a continuous stream during a drag; if you need smooth following you must poll.
- `kAXWindowMiniaturizedNotification` / `kAXWindowDeminiaturizedNotification`
- `kAXTitleChangedNotification`
- App-level: `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`,
  `kAXApplicationActivatedNotification`.
- **Feedback-loop warning (important):** AltTab `3d1d207` — "On app activation macOS raises the app's
  on-Space windows, emitting one focus event (808) per window. **Those are RAISES, not focus
  changes**". If your raise loop reacts to every focus-ish notification, your own raise can re-trigger
  it. This is exactly why a rate limit + a "did anything actually change" check is mandatory.

### Failure modes

| Error | Cause | Handling |
| --- | --- | --- |
| `kAXErrorCannotComplete` from `AXObserverAddNotification` | app still launching; permission just granted but not effective; some processes never allow it | bounded retry with backoff. CopilotForXcode logs `"AXObserver: Failed to observe \(name), will try again later"`. **yabai #439: an unguarded retry loop spun forever** on `UIKitSystem` |
| `AXObserverCreate` failure | untrusted process | check `AXIsProcessTrusted()` first and re-verify (permission can be revoked at runtime → observers become useless; pin-window-on-top tears them down and re-creates on regain) |
| `kAXErrorInvalidUIElement` on later calls | **Electron/Chromium/Zoom silently rebuild the AXUIElement while keeping the same `CGWindowID` and posting no destroyed notification** (AltTab `eb4c08c`). AXRaise then no-ops | re-resolve the element from `kAXWindowsAttribute` by `CGWindowID`, re-subscribe, retry once |
| Missing notifications for Java/GTK/SDL/wine apps | non-native toolkits have incomplete AX implementations | AutoRaise ships an `OLD_ACTIVATION_METHOD` compile flag precisely because "applications … us[e] a non native graphic technology like GTK or SDL"; Swindler exists largely to paper over missing/out-of-order AX events. **Always have a polling fallback; never rely on notifications alone.** |
| Chromium lazy AX tree | Chromium builds its AX tree lazily | freeflow keeps a no-op observer alive purely to force Chromium to build and update the tree ("alone is enough to keep Chromium's accessibility tree built and updated; we never act on the events") |

### Throughput

AX is IPC-bound. "Window managers on macOS rely on IPC: you *ask* an application for a window's
position, *wait* for it to respond … Most of the time this works okay, but it works at the mercy of
the remote application's event loop, which can lead to long, multi-second delays" (Swindler README).
AeroSpace's #131 was literally "Performance. Implement thread-per-application to circumvent macOS
blocking AX API". **Do not issue AX calls from the hover timer at 10 Hz; batch them and keep AX work
on one serial queue per destination PID.**

---

## 5. Space / minimized / closed detection with public APIs

There is **no public API to enumerate Spaces** or to ask "which Space is window X on?". Confirmed by
multiple independent projects:
- Rectangle's maintainers publicly declined Spaces support because "they don't have public APIs"
  (relayed in AltTab #14).
- AeroSpace "employs its own emulation of virtual workspaces instead of relying on native macOS Spaces
  due to their considerable limitations".
- Private alternatives are fragile: `CGSGetWindowWorkspace` "stopped returning correct values in
  10.8"; `CGSCopyManagedDisplaySpaces` only works with a specific system setting enabled and only
  gives a list of Spaces; `CGSAddWindowsToSpaces` broke in 12.3/12.3.1. All private/undocumented →
  out of scope for this fork.

**Practical public proxies, in order of reliability:**

1. **Membership in `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`.**
   AltTab #14: "when removing `.optionOnScreenOnly` in the `CGWindowListCopyWindowInfo` call, the
   windows from other spaces are returned" ⇒ with it, you effectively get **current Space only**.
   DockDoor uses the complementary fact — it switched to `[.excludeDesktopElements]` precisely in a
   commit titled "robust main-window validation **across Spaces**".
   This single call simultaneously tells you: not minimized, not hidden, not on another Space,
   and gives you front-to-back order. `pin-window-on-top` uses exactly
   `Set(CGWindowInfo.onScreen().map(\.id))` as its "is visible" oracle.
2. **`kAXMinimizedAttribute`** — distinguishes "minimized" (still owned by your AX element) from
   "gone". Must be read, not assumed. Also: AltTab [#14] shows `kAXWindowsAttribute` returns `[]` for
   apps whose windows are entirely on another Space, so *absence of the AX element* is itself a Space
   signal.
3. **`kCGWindowIsOnscreen`** — present in the dictionary (`CGWindow.h`, available since 10.5) but
   **notoriously true for everything** (SO #10258676: "I tried to use `kCGWindowIsOnscreen` to detect
   hidden/minimised windows but it always give TRUE for all windows"), and the OP's own conclusion was
   that list membership is the real signal and `kCGWindowIsOnscreen` was only misleading because of a
   weird MS Word window. Keyboard Maestro's forum does describe it as "informing you whether a given
   window is on the currently active desktop" — treat as a weak secondary hint only.
4. **`kCGWindowWorkspace`** — the key exists in `CGWindow.h`/docs ("extract the (optional)
   `kCGWindowWorkspace` key"), and real dumps do show `kCGWindowWorkspace = 1`. But attempts to use it
   programmatically fail (SO #15642398: the obvious snippet "doesn't work"), and AltTab found even
   the private equivalent broken. **Unreliable; do not build logic on it.**
5. **Closed**: `kAXUIElementDestroyedNotification`, plus the polling check
   `AXUIElementCopyAttributeValue(el, kAXRoleAttribute) == .invalidUIElement` (`AX.isAlive`).
   Also cross-check the PID still exists (`NSWorkspace.didTerminateApplicationNotification` +
   `NSRunningApplication(processIdentifier:) == nil`) because some apps do not emit destroyed.

---

## 6. "Window under cursor" hit-testing pitfalls

### Coordinate spaces (the #1 bug source)

| Source | Origin | Y direction |
| --- | --- | --- |
| `kCGWindowBounds` from `CGWindowListCopyWindowInfo` | top-left of **main** display | down |
| `kAXPositionAttribute` (as `AXValue` `.cgPoint`) | top-left of **main** display | down |
| `NSEvent.mouseLocation` | **bottom-left** of main display | up |
| `NSScreen.frame` | bottom-left of main display | up |
| `CGDisplayBounds(id)` | top-left of main display | down |

rob mayoff (SO #75406300) states the rule: "The origin (0, 0) of the CoreGraphics global geometry is
always at the top-left of the 'main' display (`CGMainDisplayID()`). The origin of the AppKit global
geometry is always at the bottom-left of the main display. To convert between the two geometries,
**subtract your y coordinate from the height of the main display**." He also warns to subscribe to
`NSApplication.didChangeScreenParametersNotification` if you cache the main-display height.

pin-window-on-top implements this as
`CGRect(x: axFrame.minX, y: primary.frame.maxY - axFrame.maxY, ...)` using
`NSScreen.screens.first` — note it uses `frame`, not `visibleFrame`.

Multi-monitor: secondary displays sit at negative X and/or negative Y relative to the main display, so
do **not** clamp to `(0, 0, w, h)` and do **not** take `abs()`. Pick the screen with
`NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })` — Topit already
does this in `getScreenWithMouse()` and `TopitApp.swift`.

`NSScreen.frame` vs `visibleFrame`: use `frame` for hit-testing and coordinate math; `visibleFrame`
subtracts the menubar and Dock and will make windows near the screen edges unhittable. Relatedly, when
walking the front-to-back list, skip the Dock/menubar (they live above `layer == 0`); `.excludeDesktopElements`
removes most of them, and Topit's overlay already uses `level = .statusBar` for its own full-screen
cover panels.

### Two hit-testing strategies — use both

1. **CGWindowList walk (recommended primary).** Take
   `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`; it is ordered
   **front-to-back** — but *only* `.optionOnScreenOnly` gives you order. This is not obvious and is a
   real bug people ship: BetterCmdTab #279 measured
   ```
   .optionAll:          artur, Applications, Documents, Downloads
   .optionOnScreenOnly: Applications, Downloads, artur, Documents
   ```
   and concluded "`CGWindow.h` documents front-to-back order only for
   `kCGWindowListOptionOnScreenOnly`. For `kCGWindowListOptionAll` it gives no order … `.optionAll`
   keeps creation order, the on-screen list follows each raise."
   **Consequence for us:** the "is my pin topmost?" check must use `.optionOnScreenOnly` too (which
   pin-window-on-top's `isAnyPinOccluded` does) — otherwise you will raise forever because the list
   never reflects your raise.
   Then: filter layer 0, drop your own PID's helper windows, and take the first entry whose
   `kCGWindowBounds` (after Y-flip) contains the point.

2. **`AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &el)`** with `x`/`y` in
   **top-left-origin** screen coordinates (documented: "Returns the accessibility object at the
   specified position in top-left relative screen coordinates"). Then walk up via
   `kAXTopLevelUIElementAttribute` to get the window (SO #79092953 recommends that attribute over
   walking parents) and `AXUIElementGetPid`.
   **Must be cross-checked.** AutoRaise #292: the AX hit test does not see Quick Look preview windows
   and returns `kAXErrorSuccess` pointing at whatever app is underneath — "Once the AX hit test has
   succeeded, compare the pid it returned with the owner pid of the topmost on-screen window
   containing the point (in `CGWindowListCopyWindowInfo` front-to-back order). If the pids differ, the
   AX result is for a window that is actually covered." That is a ready-made algorithm for us: **use
   CGWindowList as the authority and AX only to enrich** (resolve PID → `AXUIElement` for the actual
   raise).

Also note AutoRaise hits the real limit of AX hit-testing generally: "AutoRaise works on windows.
Panes drawn inside a single window, such as tmux or iTerm splits, are not windows as far as macOS is
concerned."

---

## 7. Screen Recording permission gating

- **Accessibility alone is sufficient.** `pin-window-on-top`'s README: "The app does **not** request
  Screen Recording, Microphone, Camera, or network access. It does not read or capture window
  contents. It reads only window titles, positions and sizes." Only permission listed as required:
  Accessibility (plus optional `SMAppService` login item).
- **Touching ScreenCaptureKit triggers the prompt even for enumeration.** Apple's ScreenCaptureKit
  sample: "The first time you run this sample, the system prompts you to grant the app Screen
  Recording permission. After you grant permission, you need to restart the app" — the sample's first
  call is `SCShareableContent` (windows/displays enumeration, no pixels). The framework doc likewise
  instructs adding `NSScreenCaptureUsageDescription` "with a description of why your app requires
  screen recording access". The documented escape hatch is the system picker (`SCContentSharingPicker`),
  which "means apps don't need to build their own window/screen selection UI … when you use this
  picker UI, you don't need to ask for screen recording [permission]" — not applicable to pinning.
- **Practical implication for Topit:** the native mode must not call
  `SCManager.updateAvailableContentSync()` / `SCShareableContent` at all. Topit's current
  `getSCWindowWithID(_:noFilter:)` in `Topit/Supports/Accessibility.swift` does exactly that, so the
  hover flow needs an AX/CGWindow path that never routes through it. Topit's README currently tells
  users it "needs screen recording **and** accessibility permissions" — that statement should become
  conditional on which pin mode is active.

---

## Recommended Swift pseudo-code

All guards annotated with the source that motivates them. This is *design-level* code; it is not meant
to compile as-is.

### 7.1 `NativePinManager` — keep-on-top manager

```swift
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Model

final class NativePin {
    let pid: pid_t
    var element: AXUIElement          // MUST be re-resolvable: see §4 Electron/AltTab eb4c08c
    var windowID: CGWindowID          // 0 == not matched yet
    var title: String
    var paused = false                // minimized / other Space / fullscreen pause
    var raiseFailures = 0             // §2: never trust the AXRaise return code
}

// MARK: - Window list helpers  (§5, §6)

enum CGW {
    /// FRONT-TO-BACK, current Space only.
    /// - `.optionOnScreenOnly` is what both restricts to the current Space (AltTab #14)
    ///   AND gives front-to-back ordering (BetterCmdTab #279 measured `.optionAll` == creation order).
    static func onScreenFrontToBack() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                    kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    /// Top-left-origin bounds (kCGWindowBounds is already top-left origin: SO #75406300).
    static func bounds(_ d: [String: Any]) -> CGRect? {
        guard let b = d[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    /// AppKit (bottom-left) -> CoreGraphics (top-left). rob mayoff, SO #75406300.
    /// Cache `mainHeight` and refresh on NSApplication.didChangeScreenParametersNotification.
    static func toCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: CGDisplayBounds(CGMainDisplayID()).height - p.y)
    }
}

// MARK: - Manager

@MainActor
final class NativePinManager: ObservableObject {

    // Tunables, all taken from/consistent with prior art:
    //   0.15 s  -> pin-window-on-top minRaiseInterval (SPEC: "Avoid infinite raise loops")
    //   0.3 s   -> pin-window-on-top Timer interval
    //   0.5 s   -> AlwaysOnTop pinCheckInterval
    //   0.05 s  -> pin-window-on-top focus hand-back delay
    private let minRaiseInterval: TimeInterval = 0.15
    private let tickInterval:     TimeInterval = 0.30
    private let focusHandBackDelay: TimeInterval = 0.05
    private let maxConsecutiveFailures = 5

    private var pins: [NativePin] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: Timer?
    private var lastRaise = Date.distantPast
    private var raiseScheduled = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // MARK: Start

    func start() {
        let ws = NSWorkspace.shared.notificationCenter

        // pin-window-on-top: primary trigger for a raise
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                       queue: .main) { [weak self] _ in self?.scheduleRaise() }

        // Space change re-evaluates visibility AND then raises
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                       queue: .main) { [weak self] _ in
            self?.refreshVisibility()
            self?.scheduleRaise()
        }

        // Auto-unpin on app quit
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                       queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.removePins { $0.pid == app.processIdentifier }
        }

        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: Trust

    /// Re-check every tick: permission can be revoked at runtime (pin-window-on-top checkTrust).
    @discardableResult
    private func checkTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted { teardownObservers() }            // observers are useless without trust
        else if !pins.isEmpty && observers.isEmpty { pins.forEach(installObserver) }
        return trusted
    }

    // MARK: Tick

    private func tick() {
        guard checkTrust(), !pins.isEmpty else { return }
        refreshVisibility()
        // Gentle mode == activation-only (pin-window-on-top "gentleMode" default false).
        guard !UserDefaults.standard.bool(forKey: "gentleMode") else { return }
        if anyPinOccluded() { scheduleRaise() }
    }

    // MARK: Visibility / pause  (§5)

    /// minimised | other-Space | closed -> paused. Mirrors pin-window-on-top `refresh()`.
    private func refreshVisibility() {
        removePins { !isAlive($0.element) }            // closed (kAXErrorInvalidUIElement)
        let visibleIDs = Set(CGW.onScreenFrontToBack().compactMap { CGWindowID.from($0) })
        let fullscreenPause = isFullScreenPaused()

        for pin in pins {
            // kAXMinimizedAttribute read explicitly: never infer from absence alone.
            let minimized = AX.bool(pin.element, kAXMinimizedAttribute)
            let offScreen = pin.windowID != 0 && !visibleIDs.contains(pin.windowID)
            // Other-Space is indistinguishable from closed here; that is fine, we only pause.
            pin.paused = minimized || offScreen || fullscreenPause

            // AX element absent entirely => app's windows are all on another Space (AltTab #14:
            // kAXWindowsAttribute returns [] for those); keep the pin, stay paused.
            if pin.windowID == 0 && !minimized {
                pin.windowID = matchWindowID(pid: pin.pid, axFrame: AX.frame(pin.element),
                                             title: pin.title, excluding: Set(pins.map(\.windowID)))
            }
        }
    }

    /// pin-window-on-top `isFullScreenPaused()`: AX reads literal "AXFullScreen" on the
    /// frontmost focused window; skip if the fullscreen app owns one of our pins.
    private func isFullScreenPaused() -> Bool {
        guard UserDefaults.standard.bool(forKey: "pauseInFullScreen") else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              !pins.contains(where: { $0.pid == front }) else { return false }
        guard let w = AX.focusedWindow(pid: front) else { return false }
        return AX.bool(w, "AXFullScreen")
    }

    /// True when a non-pinned, layer-0, other-app window overlaps a pin and sits ABOVE it.
    /// Uses `.optionOnScreenOnly` because that is the only option whose order follows raises.
    private func anyPinOccluded() -> Bool {
        let list = CGW.onScreenFrontToBack().filter {
            CGW.layer($0) == 0 && CGW.pid($0) != ownPID
        }
        let pinnedIDs = Set(pins.map(\.windowID))
        for pin in pins where !pin.paused && pin.windowID != 0 {
            guard let idx = list.firstIndex(where: { CGW.id($0) == pin.windowID }),
                  let bounds = CGW.bounds(list[idx]) else { continue }
            let covered = list[..<idx].contains { e in
                !pinnedIDs.contains(CGW.id(e)) &&
                (CGW.bounds(e)?.intersects(bounds) ?? false)
            }
            if covered { return true }
        }
        return false
    }

    // MARK: Raise (coalesced + rate-limited)

    private func scheduleRaise() {
        guard !pins.isEmpty, !raiseScheduled else { return }
        let wait = max(0, minRaiseInterval - Date().timeIntervalSince(lastRaise))
        raiseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.raiseScheduled = false
            self?.raisePinned()
        }
    }

    private func raisePinned() {
        guard checkTrust() else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // Never cover our own windows (pin-window-on-top raisePinned).
        guard front?.processIdentifier != ownPID else { return }
        refreshVisibility()
        let active = pins.filter { !$0.paused }
        guard !active.isEmpty else { return }
        lastRaise = Date()

        for pin in active {
            // Re-resolve stale elements BEFORE raising. AltTab eb4c08c: Electron silently rebuilds
            // the AXUIElement under the same CGWindowID, after which AXRaise no-ops with
            // kAXErrorInvalidUIElement.
            if let fresh = reresolve(pin) { pin.element = fresh; resubscribe(pin) }

            let err = AXUIElementPerformAction(pin.element, kAXRaiseAction as CFString)
            if err == .success {
                pin.raiseFailures = 0
            } else {
                pin.raiseFailures += 1
                // mctiler #8: success does not prove stacking either, so failures are only a hint.
                if pin.raiseFailures >= maxConsecutiveFailures {
                    notifyUnreliable(pin)   // offer the legacy mirrored mode for this window
                }
            }
            // NOTE: deliberately NOT setting kAXMainAttribute / activating the pinned app:
            // - NSRunningApplication.activate can drag the user to another Space when the
            //   "switch to a Space with open windows for that application" pref is on.
            // - AlwaysOnTop's kAXMain + activate combination is what causes focus stealing.
        }

        // Hand focus back (pin-window-on-top raisePinned: "AXRaise can steal focus in some apps").
        if let front, !active.contains(where: { $0.pid == front.processIdentifier }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + focusHandBackDelay) { [weak self] in
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != front.processIdentifier {
                    front.activate()
                }
            }
        }
    }

    // MARK: AXObserver  (§4)

    private static let windowNotifications: [String] = [
        kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification
    ]
    private static let appNotifications: [String] = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification
    ]

    private func installObserver(_ pin: NativePin) {
        guard observers[pin.pid] == nil else { subscribe(pin); return }
        var created: AXObserver?
        guard AXObserverCreate(pin.pid, axCallback, &created) == .success, let observer = created else {
            return
        }
        // §4: the observer MUST be attached to a run loop before it delivers anything.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pin.pid] = observer
        subscribe(pin)

        let app = AXUIElementCreateApplication(pin.pid)
        for name in Self.appNotifications {
            let e = AXObserverAddNotification(observer, app, name as CFString, refcon())
            // §4: kAXErrorCannotComplete is normal while the target app is still launching.
            //     Re-arm with bounded backoff; yabai #439 shows an unbounded retry loop hangs.
            if e == .cannotComplete { retrySoon(pin.pid, name) }
        }
    }

    private func subscribe(_ pin: NativePin) {
        guard let observer = observers[pin.pid] else { return }
        for name in Self.windowNotifications {
            let e = AXObserverAddNotification(observer, pin.element, name as CFString, refcon())
            if e == .cannotComplete { retrySoon(pin.pid, name) }
        }
    }

    private var retryBudget: [String: Int] = [:]      // cap retries, cf. yabai #439
    private func retrySoon(_ pid: pid_t, _ name: String) {
        let key = "\(pid)-\(name)"
        retryBudget[key, default: 0] += 1
        guard retryBudget[key]! <= 8 else { return }  // give up; polling fallback covers us
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.installObserver(NativePin(pid: pid, /*…*/))  // re-attempt; §4 CopilotForXcode pattern
        }
    }

    /// AltTab 3d1d207: app activation emits one focus-ish event PER RAISED WINDOW ("Those are
    /// RAISES, not focus changes"). Never raise straight from an AX callback — always coalesce and
    /// always re-verify with anyPinOccluded().
    fileprivate func handleAX(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXUIElementDestroyedNotification:
            removePins { CFEqual($0.element, element) || !isAlive($0.element) }
        case kAXMovedNotification, kAXResizedNotification:
            repositionHoverPanel()
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            refreshVisibility()
        case kAXTitleChangedNotification:
            if let pin = pins.first(where: { CFEqual($0.element, element) }) {
                pin.title = AX.string(element, kAXTitleAttribute) ?? pin.title
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if !UserDefaults.standard.bool(forKey: "gentleMode") { scheduleRaise() }
        default:
            refreshVisibility(); scheduleRaise()
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement,
                        _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let m = Unmanaged<NativePinManager>.fromOpaque(refcon).takeUnretainedValue()
    let note = notification as String
    Task { @MainActor in m.handleAX(note, element: element) }   // hop to the actor that owns state
}
```

### 7.2 `HoverPinController` — hover detection + floating panel

```swift
import AppKit

@MainActor
final class HoverPinController {

    // WHY POLLING AND NOT A TAP (§3):
    //  * AutoRaise, the reference focus-follows-mouse tool, polls at 50 ms by default
    //    ("-pollMillis … Minimum = 20 and default = 50") precisely because taps are fragile.
    //  * A filtering CGEventTap can freeze ALL input if the callback stalls; it is disabled by
    //    kCGEventTapDisabledByTimeout / ByUserInput (commonly around sleep/wake) and may come
    //    back inert after re-signing ("A non-nil tap is not a healthy tap").
    //  * NSEvent.addGlobalMonitorForEvents needs Accessibility; a listen-only tap needs
    //    Input Monitoring (Apple forum 707680). Polling needs NO permission at all.
    //  * Topit already uses NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) in
    //    WindowHighlighter — prefer that existing style over introducing a CGEventTap.
    private let pollInterval: TimeInterval = 0.10      // 10 Hz per the design; AutoRaise uses 0.05
    private var pollTimer: Timer?
    private let panel: NSPanel

    init() {
        // Non-activating floating panel; same shape pin-window-on-top uses for its border overlay.
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // NOTE: unlike the border overlay, this one must receive clicks -> ignoresMouseEvents = false
    }

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        // 1. Mouse location is AppKit/bottom-left origin (SO #75406300); convert to CG/top-left once.
        let cg = CGW.toCG(NSEvent.mouseLocation)

        // 2. PRIMARY hit test: front-to-back CURRENT-SPACE window list.
        //    Requires .optionOnScreenOnly — .optionAll is unordered (BetterCmdTab #279).
        let list = CGW.onScreenFrontToBack()
        let hit = list.first { d in
            guard CGW.layer(d) == 0,                          // skip Dock / menubar / helpers
                  CGW.pid(d) != ProcessInfo.processInfo.processIdentifier,
                  let b = CGW.bounds(d) else { return false }
            return b.contains(cg)
        }

        // 3. SECONDARY: enrich with AX, but CROSS-CHECK the PID.
        //    AutoRaise #292: AXUIElementCopyElementAtPosition returns success even when the real
        //    topmost window (Quick Look, popups) is invisible to AX, pointing at the app underneath.
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                   Float(cg.x), Float(cg.y), &el)
        if err == .success, let el {
            var hitPID: pid_t = 0
            AXUIElementGetPid(el, &hitPID)
            if let hit, hitPID != CGW.pid(hit) {
                // AX saw *through* the topmost window -> trust CGWindowList, not AX.
                place(panel, over: hit)
            } else if let window = topLevelWindow(of: el) {
                // kAXTopLevelUIElementAttribute, not parent-walking (SO #79092953).
                place(panel, over: windowAXFrame(of: window))
            }
        } else if let hit {
            place(panel, over: hit)
        } else {
            panel.orderOut(nil)
        }
    }

    /// Panel frame from a TOP-LEFT-origin AX/CG rect. Same flip as pin-window-on-top BorderOverlay:
    ///   cocoa.y = NSScreen.screens.first!.frame.maxY - rect.maxY
    private func place(_ panel: NSPanel, over rect: CGRect) {
        guard let primary = NSScreen.screens.first else { panel.orderOut(nil); return }
        let cocoa = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        // Anchor the pin button near the top-right of the window's title area.
        panel.setFrame(CGRect(x: cocoa.maxX - 44, y: cocoa.maxY - 26, width: 40, height: 22),
                       display: true)
        panel.orderFrontRegardless()
    }
}
```

Notes on the hover panel itself:

- `styleMask: [.borderless, .nonactivatingPanel]` — a *non-activating* panel will not steal focus,
  which matters because stealing focus is exactly what we are trying to avoid in §2.
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]` — `canJoinAllSpaces` keeps the button
  available on every Space; `fullScreenAuxiliary` is what lets it survive next to a full-screen Space
  (that combination is what pin-window-on-top uses for its always-visible border overlay).
- Do **not** use `visibleFrame` anywhere in this path (`visibleFrame` excludes menubar/Dock and yields
  off-by-menubar-height placement near the top of the screen).

### 7.3 Auto-unpin matrix

| Event | Detection | Action |
| --- | --- | --- |
| Window closed | `kAXUIElementDestroyedNotification`, or `kAXRoleAttribute` read → `.invalidUIElement` (polling fallback) | drop pin |
| App quit | `NSWorkspace.didTerminateApplicationNotification` | drop all pins for PID |
| Minimized | `kAXMinimizedAttribute == true` or `kAXWindowMiniaturizedNotification` | `paused = true` (do **not** raise — AXRaise is a no-op on minimized windows); unminimize explicitly or just wait |
| Other Space | windowID absent from `CGWindowListCopyWindowInfo([.optionOnScreenOnly, …])` | `paused = true`; `activeSpaceDidChangeNotification` resumes |
| Full-screen frontmost | literal `"AXFullScreen"` on frontmost focused window (and that app owns no pin) | `paused = true` — fullscreen lives in its own Space and cannot be stacked over with public APIs |
| Trust revoked | `AXIsProcessTrusted()` false on a tick | tear down observers + overlays, show the warning row; re-arm when trust returns |
| Repeated raise failure | verified-occlusion stays true after N raises | surface "native pin not working for this window" → offer the legacy mirrored mode |

---

## Uncertain / conflicting claims (read before implementing)

| # | Claim | Status |
| --- | --- | --- |
| U1 | `kAXRaiseAction` reliably puts a non-active app's window above the active app's windows | **CONFLICTING.** Pro: AltTab `886f21a` ("AXRaise … only move[s] the window in the z-order"), two reference implementations shipping this way. Con: mctiler #8 (success return, wrong stacking, still open), SO #21541561 (same-app only), Peekaboo #801 (`-25205` on macOS 26.7), stim #2496/PR #2503 (SwiftUI windows). Treat as best-effort; verify by read-back. |
| U2 | `.optionOnScreenOnly` ⇒ current Space only | **Strong but inferential.** AltTab #14 measured that removing it returns other-Space windows; DockDoor's mirror-image change supports it. No Apple doc states it. |
| U3 | `kCGWindowIsOnscreen` indicates Space membership | **Weak / unreliable.** SO #10258676 found it always true; Keyboard Maestro forum claims it tracks the active desktop. Use list membership instead. |
| U4 | `kCGWindowWorkspace` gives a Space ID | **Exists but unreliable.** Key is documented/observed; programmatic use reported failing, and the private equivalent is broken since 10.8. |
| U5 | `AXObserver` must be created on the main thread | **Partly wrong framing.** The *observer* can be created anywhere; its **run loop source** must be added to a run loop before delivery, and pin-window-on-top/CloseUp add it to the main run loop. Callbacks then arrive on that run loop. |
| U6 | `NSEvent.addGlobalMonitorForEvents` needs Accessibility vs Input Monitoring | **Conflicting but well-sourced.** Apple's Quinn (forum 707680) says NSEvent monitor → Accessibility, CGEventTap → Input Monitoring. Other sources say `.defaultTap` also needs Accessibility. Safest: assume Accessibility for *any* global input observation, which we already require. |
| U7 | Stage Manager behaviour with AXRaise | **Unknown.** No authoritative source found; only third-party degradation reports. Treat as unsupported in v1. |
| U8 | `turhe123/pin-window-on-top` maturity | **Caveat:** MIT, 0 stars, single commit (2026-10-21), README states it was AI-generated from a spec. Its *design* is sound and matches prior art; its *testing* status is unknown. Do not copy code verbatim; copy the guard list. |

---

## Sources

| # | Claim it supports | URL |
| --- | --- | --- |
| S1 | `kAXRaiseAction` official semantics ("as frontmost as is allowed by the containing application's circumstances"; floating windows may stay above) | <https://developer.apple.com/documentation/applicationservices/kaxraiseaction> |
| S2 | AXRaise "only brings the window forward past all the windows of the same application"; accepted fix = activate the app | <https://stackoverflow.com/questions/21541561/osx-accessibility-how-to-bring-window-allll-the-way-to-the-front> |
| S3 | Reference impl #1: `turhe123/pin-window-on-top` (MIT, AX-only, 150 ms rate limit, gentle mode, Space/minimize pause) | <https://github.com/turhe123/pin-window-on-top> · `Sources/Services/PinManager.swift`, `Sources/Services/AXHelpers.swift`, `Sources/Services/BorderOverlay.swift`, `SPEC.md`, `README.md` |
| S4 | Reference impl #2: AlwaysOnTop 0.5 s timer + kAXMain + AXRaise + AppleScript throttled to 1 s | <https://github.com/itsabhishekolkha/AlwaysOnTop> (`Main/WindowManager.swift`) |
| S5 | Author's own description of AlwaysOnTop's AX + timer approach vs Topit's ScreenCaptureKit approach | <https://www.reddit.com/r/macapps/comments/1l02m1u/open_source_released_alwaysontop_keep_any_macos/> |
| S6 | AltTab: "_SLPSSetFrontProcessWithOptions sets the front process, while makeKeyWindow and kAXRaiseAction only move the window in the z-order"; 1 s AX messaging timeout; raise can stay in flight for seconds | <https://github.com/lwouis/alt-tab-macos/commit/886f21a026edf33027d0e20515876f56d20f7892> |
| S7 | **Counter-example:** AXRaise returns success (0) yet WindowServer keeps the foreground window above it — "successful AXRaise responses do not establish the requested global stacking result" | <https://github.com/tjukkefeiten/mctiler/issues/8> |
| S8 | Electron silently rebuilds AXUIElement under same CGWindowID; `kAXRaise` no-ops with `kAXErrorInvalidUIElement` | <https://github.com/lwouis/alt-tab-macos/commit/eb4c08ca8f2b222ceaac7f931f8f93ad391771d1> |
| S9 | On app activation macOS emits one focus event per *raised* window — "Those are RAISES, not focus changes" (feedback-loop risk) | <https://github.com/lwouis/alt-tab-macos/commit/3d1d207> |
| S10 | macOS 26.7: Calculator/System Settings list AXRaise then answer `kAXErrorAttributeUnsupported (-25205)` | <https://github.com/openclaw/Peekaboo/issues/801> |
| S11 | SwiftUI `WindowGroup` windows fail a guard requiring AXRaise; AppKit windows pass | <https://github.com/appandflow/stim/issues/2496> · <https://github.com/appandflow/stim/pull/2503> |
| S12 | AXRaise is the right tool for reordering a normal-level window; CGWindowLevel cannot be set for foreign windows | <https://stackoverflow.com/questions/48490864/accessing-nswindow-level-for-all-applications-windows-on-screen> |
| S13 | Space membership via `.optionOnScreenOnly`; `kAXWindowsAttribute` returns `[]` for other-Space apps; Rectangle declined Spaces support for lack of public APIs; private `CGSGetWindowWorkspace` broken since 10.8 | <https://github.com/lwouis/alt-tab-macos/issues/14> |
| S14 | Private-API cross-Space tricks (invisible windows per Space) and their macOS 12.3 breakage | <https://github.com/lwouis/alt-tab-macos/issues/447> |
| S15 | Space switching must be explicit consent; `--space-switch` forces it — implies raising alone does not switch Spaces | <https://github.com/openclaw/Peekaboo/blob/main/docs/focus.md> |
| S16 | Cross-Space focus side effects; macOS bug when focusing a window across Spaces | <https://github.com/lwouis/alt-tab-macos/commit/cd9d56d> |
| S17 | `kCGWindowIsOnscreen` always true in practice; list membership is the real signal | <https://stackoverflow.com/questions/10258676/how-to-know-whether-a-window-is-minimised-or-not> |
| S18 | Keyboard Maestro forum: `kCGWindowIsOnscreen` "inform[s] you whether a given window is on the currently active desktop"; System Events cannot see other-Space windows | <https://forum.keyboardmaestro.com/t/how-to-list-all-windows-of-one-app-that-are-open-in-all-desktops/23986> |
| S19 | Real CGWindowList dump showing `kCGWindowIsOnscreen` and `kCGWindowWorkspace` keys | <https://stackoverflow.com/questions/7850685/determine-which-screen-a-window-is-on-given-the-window-id> |
| S20 | `kCGWindowWorkspace` exists as an optional key; attempts to use it fail | <https://stackoverflow.com/questions/15642398/how-can-i-get-the-id-of-the-active-desktop-of-mac-os-x> |
| S21 | `kCGWindowIsOnscreen` header declaration (available since 10.5) | <https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.8.sdk/System/Library/Frameworks/CoreGraphics.framework/Versions/A/Headers/CGWindow.h> |
| S22 | **`.optionAll` list has NO order; only `.optionOnScreenOnly` is front-to-back** — measured probe | <https://github.com/rokartur/BetterCmdTab/issues/279> |
| S23 | DockDoor commit "robust main-window validation across Spaces" switching away from `.optionOnScreenOnly` | <https://github.com/ejbills/DockDoor/commit/00114045b8ced99b85c7d31ac9c9e5c5a824ebb3> |
| S24 | **Coordinate conversion rule** by rob mayoff: CG origin = top-left of main display, AppKit = bottom-left; subtract y from main display height; cache + observe screen-parameter changes | <https://stackoverflow.com/questions/75406300/how-to-convert-the-position-in-cgdisplaybounds-to-global-coordinate-like-nse> |
| S25 | AppKit vs CG y-axis flip (Chromium's own conversion) | <https://chromium.googlesource.com/chromium/src/+/342b1287ed7d4496377fe3453092eef482be0d28/ui/gfx/screen_mac.mm> |
| S26 | `CGDisplayBounds` (top-left) vs `NSEvent::mouseLocation()` (bottom-left) table | <https://github.com/crafter-station/open-screenstudio/commit/eb4c5dadefeb26610517e934f8f93ad391771d1> |
| S27 | AutoRaise: **polls** mouse (`-pollMillis`, min 20, default 50); works on windows not panes; `OLD_ACTIVATION_METHOD` for GTK/SDL apps | <https://github.com/sbmpost/AutoRaise> |
| S28 | **AX hit test sees through Quick Look windows and returns success** for the app underneath; recommended cross-check of hit PID vs topmost CGWindowList owner PID | <https://github.com/sbmpost/AutoRaise/issues/292> |
| S29 | `AXUIElementCopyElementAtPosition` documented for top-left relative screen coordinates | <https://developer.apple.com/documentation/applicationservices/axuielement_h> |
| S30 | Use `kAXTopLevelUIElementAttribute` to get the window from an arbitrary element | <https://stackoverflow.com/questions/79092953/how-do-i-get-the-frontmost-window-at-an-arbitrary-screen-location> |
| S31 | Apple (Quinn): NSEvent global monitor → Accessibility, CGEventTap → Input Monitoring; Input Monitoring is available to sandboxed apps | <https://developer.apple.com/forums/thread/707680> |
| S32 | Event tap disabled by timeout must be re-enabled with `CGEventTapEnable` | <https://stackoverflow.com/questions/2817680/mac-event-tap-just-delays-discarded-events> |
| S33 | Legacy Quartz Event Services reference: "If an event tap becomes unresponsive, or if a user requests that event taps be disabled, then a `kCGEventTapDisabled` event is passed to the event tap callback function" | <https://leopard-adc.pepas.com/documentation/Carbon/Reference/QuartzEventServicesRef/QuartzEventServicesRef.pdf> |
| S34 | Tap health must be checked at runtime; Input Monitoring preflight; `.defaultTap` may additionally need Accessibility; re-sign/Launch Services can make a tap inert | <https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/> |
| S35 | Real breakage: keybindings permanently dead after sleep/wake (`kCGEventTapDisabledByTimeout` never re-enabled) | <https://github.com/glzr-io/glazewm/issues/1420> |
| S36 | Real breakage: input capture dies permanently when display turns off; also re-enabling a tap after trust is revoked can freeze input | <https://github.com/deskflow/deskflow/issues/10296> · <https://github.com/alanshurafa/handy-keys/pull/2> |
| S37 | The "AltTab/yabai pattern" — window raise sequence `_SLPSSetFrontProcessWithOptions` → `SLPSPostEventRecordTo` → `kAXRaiseAction` (private APIs; cited for context only) | <https://github.com/samzong/etui/pull/5> |
| S38 | **AXUIElement.h: "The observer must be added to a run loop before it can receive notifications"** | <https://developer.apple.com/library/mac/documentation/ApplicationServices/Reference/AXUIElement_header_reference> |
| S39 | `AXObserverAddNotification` `.cannotComplete` → "will try again later" (retry pattern) | <https://github.com/github/CopilotForXcode/blob/2ba57a27/Tool/Sources/AXNotificationStream/AXNotificationStream.swift> |
| S40 | Unbounded retry on `kAXErrorCannotComplete` caused an infinite loop (yabai) | <https://github.com/asmvik/yabai/issues/439> |
| S41 | `CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)` pattern in production code | <https://raw.githubusercontent.com/oomol-lab/CloseUp/main/Sources/CloseUpKit/MissionControl/MissionControlObserver.swift> |
| S42 | `kAXWindowMoved` may only fire after the move finishes (no continuous updates) | <https://stackoverflow.com/questions/15303973/axwindowmoved-via-axobserver-continuous-updates> |
| S43 | Chromium builds its AX tree lazily; keeping a no-op observer forces it to stay built | <https://github.com/zachlatta/freeflow/blob/c618e444f997f47a7d5060f5f38ece6d86c34da/Sources/AccessibilityWakeManager.swift> |
| S44 | Swindler: AX APIs are "surprisingly buggy"; IPC latency can be multi-second; `MainWindowChanged` can arrive before `WindowCreated` | <https://github.com/tmandry/Swindler> |
| S45 | AeroSpace avoids native Spaces "due to their considerable limitations"; thread-per-app needed to work around blocking AX | <https://github.com/nikitabobko/AeroSpace> |
| S46 | Focusing a window of a non-frontmost app is a race: AX raise says which window should be main, but activating makes macOS restore its own choice | <https://github.com/nikitabobko/AeroSpace/pull/2213/files> |
| S47 | ScreenCaptureKit sample prompts for Screen Recording on first run (even for `SCShareableContent` enumeration) | <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos> |
| S48 | `NSScreenCaptureUsageDescription` required for screen recording access | <https://developer.apple.com/documentation/screencapturekit> |
| S49 | System picker (`SCContentSharingPicker`) is the only documented no-permission route | <https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma> |
| S50 | 2026 landscape: desktop pinning tools are "weak across fullscreen Spaces"; "once you enter a fullscreen Space, most pinned windows disappear" | <https://www.noticky.app/en/blog/keep-window-on-top-mac> |
| S51 | AppleScript System Events has AXRaise but "there is no AppleScript command to set a window's level"; "AXRaise brings a window to the front once, but the next click on any other window sends it behind again" | <https://www.noticky.app/en/blog/keep-window-on-top-mac> |
| S52 | AppleScript AXRaise raises above other apps' windows but keeps the current app's own windows above it | <https://apple.stackexchange.com/questions/58355/how-can-i-bring-a-window-to-frontmost-without-focusing-it-using-applescript-in-o> |
| S53 | AXRaise is a no-op on a minimized window | <https://github.com/777genius/agent-notifications/issues/67> |
| S54 | Deskshare tools use `AXUIElementCopyElementAtPosition` + kAXMain + AXRaise + kAXFrontmost for click-to-focus | <https://github.com/deskflow/deskflow/issues/9852> |
| S55 | "A one-time AXEnhancedUserInterface nudge per app per launch handles Chromium's usual Accessibility API quirks"; apps running as root or with full-screen space privileges are unreachable via AX | <https://github.com/Dot-Fun/windowkit> |
| S56 | macOS user preference that can cause Space switching on app activation (relevant to the focus hand-back step) | <https://www.reddit.com/r/MacOS/comments/1jzzss1/unexpected_space_switching/> |

**Source count: 56 distinct URLs** (plus 2 repositories read in full, not counted as single URLs).

---

## Open questions for the user

1. **Fallback policy when native pinning silently fails** (U1 / mctiler #8): should Topit auto-fall
   back to the mirrored ScreenCaptureKit panel per-window after N failed raises, or surface a warning
   only?
2. **Stage Manager** (U7): ship as explicitly unsupported, or attempt detection via the
   "AX frame ≠ CG bounds" heuristic?
3. **Hover panel activation**: should clicking the hover pin button activate the target window before
   pinning (reliable AX element acquisition, but steals focus), or stay strictly non-activating?
