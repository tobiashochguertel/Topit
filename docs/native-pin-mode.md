# Native pin mode + hover pin button

Implementation notes for this fork of [Topit](https://github.com/lihaoyun6/Topit) (AGPL-3.0).
Background and sources: [research/](research/README.md).

Status: **code complete and building** (`xcodebuild … Debug build` succeeds, no new warnings);
runtime behaviour verified only partially — see [Test matrix](#test-matrix).

## Why

Upstream pins a window by capturing it with ScreenCaptureKit and floating the capture inside Topit's
own panel. That costs a live capture stream per pin, needs **Screen Recording** permission, and the
thing you click is a copy.

The fork adds a second mode that keeps the **real** window on top:

| | Mirror (upstream) | Native (this fork) |
| --- | --- | --- |
| What floats | A captured copy in Topit's panel | The actual window |
| Interaction | Through Topit's overlay activation | Native — click, scroll, typing go straight to the app |
| Permissions | Accessibility **+ Screen Recording** | Accessibility only |
| Above full-screen Spaces | Yes | No |
| Cost | One `SCStream` per pin | One window-list read per 150 ms |
| Visual artefact | None (it is a copy) | Brief flash when another window takes the top |

## Architecture

```
status menu ─┐
hotkeys ─────┼─► PinActions.toggle(windowID) ─► mode? ─┬─► .mirror → createNewWindow (upstream path)
hover button ┘                                         └─► .native → NativePinManager.pin(windowID)
                        │
                        └─► PinRegistry  (single source of truth, keyed by CGWindowID)
```

| File | Role |
| --- | --- |
| `Topit/Supports/PinRegistry.swift` | All pins, both modes, keyed by `CGWindowID`. Prunes pins whose overlay is gone, whose window was destroyed, or whose app quit. `ObservableObject`, main-thread only. |
| `Topit/Supports/NativePinManager.swift` | Keep-on-top loop for `.native` pins. |
| `Topit/Supports/PinActions.swift` | Mode-aware pin/unpin/unpinAll. The only place that decides whether ScreenCaptureKit is touched. |
| `Topit/ViewModel/HoverPinButton.swift` | Hover detection + the floating pin button. |
| `Topit/Supports/Accessibility.swift` | Added `isWindowOccluded()`, `getFrontmostCGWindow()`; `createNewWindow` now registers mirror pins. |

### Keep-on-top loop

```
didActivateApplicationNotification ─┐
activeSpaceDidChangeNotification ───┼─► raiseAll()
didTerminateApplicationNotification ─┤    └─ for each pin: skip if not on current Space/minimised,
Timer @150 ms (skipped in Gentle mode)┘       raise if occluded and ≥150 ms since last attempt
```

Details that matter (each one documented in the source):

- **Trigger choice.** `didActivateApplicationNotification` is the main trigger because the
  WindowServer pulls the pinned window behind the newly activated app. The 150 ms timer is a
  backstop for everything else (a window opening, a drag, another pin being added). ProToys'
  documented raise mode polls ~4 Hz; `turhe123/pin-window-on-top` uses 300 ms; aloft 150 ms.
- **Occlusion, not topmost.** `isWindowOccluded(windowID:)` asks whether a window that *intersects*
  the pinned window sits above it. Upstream's `isWindowOnTop` ("nothing above me at all") is almost
  never true — Topit's own overlay panels are above it — and would raise forever.
- **Rate limit + backoff.** One raise per window per 150 ms; when a raise is accepted but occlusion
  persists, the interval doubles up to 2 s. This is what keeps the loop from becoming a raise storm
  in cases where the raise cannot win (documented, e.g. [mctiler #8](https://github.com/tjukkefeiten/mctiler/issues/8)).
- **Focus handback.** `kAXRaiseAction` can activate the window's app. If the frontmost app changed,
  it is re-activated immediately so keystrokes never land in the pinned app. Same step appears in
  `pin-window-on-top`'s SPEC.
- **Standing down.** Raising is skipped entirely while Accessibility is not trusted (revocable at
  runtime in System Settings) and while Topit itself is frontmost (otherwise a foreign window would
  cover the Settings UI).
- **Auto-unpin.** A pin whose window disappears from `CGWindowListCopyWindowInfo(.optionIncludingWindow)`
  or whose app terminated is removed. A pin whose window never resolves in Accessibility is dropped
  after ~3 s (20 attempts) instead of polling forever.
- **Gentle mode** (`nativePinGentleMode`, default off) drops the timer entirely: re-raise only on app
  and Space changes. Calmer, but the window can stay covered for a moment.

### Why no SkyLight/CGS

`SLSSetWindowLevel` / `CGSWindowSetLevel` do **not** work across processes — they return success and
are silently ignored, because the WindowServer only lets a connection change windows it owns. This
is ownership policy, not SIP. The only bypasses are Mach injection into `Dock.app` (blocked by SIP)
or the private `com.apple.private.skylight.universal-owner` entitlement (AMFI refuses to launch it).
Full write-up with measurements: [research/native-always-on-top.md](research/native-always-on-top.md).

### Hover pin button

Small `.nonactivatingPanel` at `.floating` level, ordered above the hovered window, anchored to the
corner selected by the existing `buttonPosition` setting. Clicking toggles the pin of the window id
captured at hover time.

| Choice | Reason |
| --- | --- |
| 10 Hz `Timer` polling `NSEvent.mouseLocation`, **not** a `CGEventTap` | A tap needs Input Monitoring on top of Accessibility, is silently disabled on `kCGEventTapDisabledByTimeout`/`ByUserInput` (sleep/wake), and can freeze all input if the callback stops returning events. AutoRaise — the reference focus-follows-mouse tool — polls at 50 ms for the same reason. |
| Frame polled every tick, **not** an `AXObserver` per hover target | The brief preferred `AXObserver` on moved/resized. `AXObserverAddNotification` commonly fails with `cannotComplete` for launching apps (yabai hung on unbounded retries), Electron/Chromium rebuild their AX element while keeping the same `CGWindowID`, and a hover target changes several times per second. The 10 Hz poll already has the window list, so repositioning is free. Notable deviation from the brief — flagged deliberately. |
| Full-screen windows skipped | They live in their own Space; the pin would vanish immediately. Detected via the de-facto (undocumented) `AXFullScreen` attribute, assumed `false` when unreadable. |
| Own-app windows skipped | Otherwise the button would appear over Topit's own mirror overlays. |

Hides 0.5 s after the cursor leaves both the window and the button; stays visible on self-hover.
`hoverButtonDelay` (seconds) can be overridden without a UI:
`defaults write com.tobiashochgurtel.TopitFork hoverButtonDelay -float 1.0`.

## Permissions

| Feature | Accessibility | Screen Recording |
| --- | --- | --- |
| Native pin mode | required | **not required** |
| Hover pin button | required | not required |
| Mirror pin mode | required | required (upstream behaviour) |
| Window selector thumbnails | — | required (upstream behaviour) |

Audit of the ScreenCaptureKit paths:

- `AppDelegate.applicationWillFinishLaunching` previously called
  `SCManager.updateAvailableContentSync()` unconditionally, which prompts for Screen Recording at
  launch. It now runs **only in mirror mode**.
- `pnpUnderMouseWindow` / `pnpFrontmostWindow` previously resolved the window to an `SCWindow` via
  `getSCWindowWithID` (which itself calls `updateAvailableContentSync()`). They now stay on
  `CGWindowList` and only convert to `SCWindow` when the mode really is `.mirror`.
- Click-to-select (`WindowHighlighter`) no longer touches ScreenCaptureKit at all.

Note: **an App Sandbox app cannot use cross-process Accessibility at all**, so this app must stay
unsandboxed (Developer ID, outside the Mac App Store). Topit's entitlements contain no sandbox key —
do not add one.

## Known limitations

- **Flicker is inherent.** After you activate another app, its windows take the top; our next raise
  (150 ms later, or immediately in gentle mode) puts the pinned window back. There can be a visible
  flash. This is exactly what ProToys documents for its raise mode.
- **The raise is not guaranteed.** `kAXRaiseAction` may return success without changing stacking for
  some apps; reported failures include `-25205` on macOS 26.7 for some system apps and SwiftUI
  windows. Mirror mode is the fallback.
- **Nothing floats above a full-screen Space.** Native pins are paused when their window is not on
  the current Space, so a full-screen app always covers them. Use mirror mode for that case.
- **Space/minimise detection is a proxy.** No public API enumerates Spaces; membership in
  `.optionOnScreenOnly` is the documented-by-observation proxy used by AltTab, pin-window-on-top and
  this fork.
- **Unpinned overlays are still per-window panels** — mirror mode behaviour is untouched.

## Test matrix

| # | Acceptance criterion | Result |
| --- | --- | --- |
| 1 | `xcodebuild` clean build, no new warnings | ✅ **PASS** — `xcodebuild -project Topit.xcodeproj -scheme Topit -configuration Debug clean build` succeeds; every remaining warning is a pre-existing `SCManager.swift` ScreenCaptureKit Sendable warning from upstream. Verified by diffing the warning list per file against the unmodified tree. |
| 2 | Mirror mode unchanged (pin → overlay, unpin removes it, existing hotkeys/menubar) | ⚠️ **Code-equivalent, not runtime-tested.** Paths are unchanged apart from now going through `PinActions` (same `closeMainWindow()` + `createNewWindow()` + panel-close-by-title logic). Needs a manual pass. |
| 3 | Native mode keeps a Safari/Preview window on top across app switches, real clicks land in it, unpin restores order | ⚠️ **Partially verified.** Window-list ordering and the occlusion predicate were verified against the real system with the probes in [research/verification](research/verification/README.md) (macOS 27.2.1). The raise itself could not be sent because the dev session was locked (`loginwindow` frontmost → apps expose no real AX windows). Run `./axraise <windowID>` unlocked to close this row. |
| 4 | Hover button appears, follows the window, toggles in the active mode, shows pinned state, hides on leave, dual-monitor | ⚠️ **Partially verified.** The CG→NS conversion and the "eligible window under cursor" predicate were exercised by the same probes on a multi-display setup; the panel itself needs a manual pass. |
| 5 | Hotkey "Pin / Unpin Under-Mouse Window" respects the mode for pin *and* unpin | ✅ **By construction** — single `PinActions.toggle` entry point reads the mode from the registry entry for unpin, and from settings for pin. |
| 6 | No Screen Recording prompt using only native mode + hover button | ✅ **Gated (audit PASS).** Every reachable path was traced (see [docs/review/acceptance-criteria-audit.md](review/acceptance-criteria-audit.md)): the launch probe, the two hotkey entry points, click-to-select and — after that audit caught it — the Selector panel that used to auto-open at launch in native mode. `WindowSelectorViewModel.setupStreams` remains reachable if the user deliberately opens the Selector, which inherently captures thumbnails. Re-test from a clean state with `tccutil reset ScreenCapture com.tobiashochgurtel.TopitFork`. |
| 7 | Small focused commits, conventional style, comments where non-obvious, no secrets/telemetry | ✅ **PASS** — three commits across `chore/fork-identity`, `feat/native-pin-mode`, `feat/hover-pin-button`; no analytics or network calls added. |

To re-check criterion 6 cleanly:

```bash
tccutil reset ScreenCapture com.tobiashochgurtel.TopitFork
```

## Upstreaming

Both features are self-contained and useful upstream (lihaoyun6/Topit, AGPL-3.0). Worth proposing as
a PR: **native pin mode** (the interesting one — it removes the Screen Recording requirement and the
per-pin capture cost). Suggested framing: it is opt-in (`pinMode` defaults to `mirror`), so existing
users are unaffected, and it is public-API-only. The hover pin button is a UX addition that probably
needs upstream's blessing on placement and localisation first; note that this fork hardcoded English
strings for the new UI.
