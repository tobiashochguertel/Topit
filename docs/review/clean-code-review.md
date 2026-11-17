# Clean-code / correctness review — `feat/hover-pin-button`

Repo: `/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit`
Branch under review: `feat/hover-pin-button` (baseline diffed against `main`)
Diff scope: `git diff main..HEAD` (25 files, +3686/−53; working tree clean — no untracked additions)
Review date: 2026-11-16 · Reviewer: subagent (strict review, no edits made)

> **Scope note / concurrency.** This review reads the code as of commit `a730bfa`
> (`git diff main..HEAD` at review time, working tree clean). While the review was being written a
> parallel session pushed `15c72e9 "fix(pin): audit fixes for raise backoff, mode coverage and Screen
> Recording gating"` onto the same branch, which fixes some of what is below. See
> **Addendum: status vs. `15c72e9`** at the end for what is now resolved and what is still open;
> line numbers below refer to `a730bfa` unless the addendum says otherwise. My own findings were
> derived independently of that commit.

> Note on the path given in the task: the session working directory
> `/Users/tobiashochgurtel/work/dev/github/tobiashochgurtel/topit` contains only `docs/research/`.
> The real checkout (with the Swift sources, `Topit.xcodeproj`, `.git`) is
> `/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit` — note `guertel`, not `gurtel`.
> Everything below reviews that checkout. Someone should clean up the stray empty directory.

---

## Verdict: **fix before ship**

The two features are well researched, well documented and mostly well structured — but the
native raise loop contains two defects that turn it into a WindowServer hammer in exactly the
situations it is supposed to be calm in, and the fork-identity change silently broke AppleScript
support. None of the three is expensive to fix.

Three most important findings:

1. **Backoff branches are inverted** — `Topit/Supports/NativePinManager.swift:249-257`. A raise that
   succeeds *but leaves the window still occluded* resets `failures` to `0` (no backoff → re-raise on
   every 150 ms tick), while a raise that succeeds and *fixes* the occlusion *increments* `failures`
   (up to 2 s of needless latency). This is the inverse of what the comment above the branch says it
   does, and it is the one mechanism that was supposed to prevent a raise storm.
2. **Two overlapping native pins re-raise each other forever** — `isWindowOccluded` excludes Topit's
   own windows but not other *pinned* windows (`Topit/Supports/Accessibility.swift:208-224`, consumed at
   `NativePinManager.swift:222,251`). Pin A sees pin B as an occluder and raises; next tick B sees A and
   raises. At ~6.7 Hz per pin, forever, with `kAXRaiseAction` on every iteration.
3. **AppleScript support is broken by the rename** — `Topit.xcodeproj/project.pbxproj:298,328` sets
   `PRODUCT_NAME = "Topit Fork"` without pinning `PRODUCT_MODULE_NAME`, so the Swift module is now
   `Topit_Fork` (confirmed: `DerivedData/.../Build/Products/Debug/Topit_Fork.swiftmodule`), while
   `Topit/Scriptable/Scriptable.sdef:7-23` still declares `<cocoa class="Topit.selectWindow"/>` etc.
   Every script command will fail to resolve.

Beyond that: mirror-mode pin state now lives in a *second* place (`PinRegistry`) that nothing
unregisters on overlay close, which introduces real behaviour drift against the upstream baseline
(see F4), and both new hot loops do redundant full window-list copies (F5, F6).

---

## Blockers

### B1 · Inverted failure bookkeeping defeats the backoff (raise storm)
**Severity: blocker** · `Topit/Supports/NativePinManager.swift:249-257`

```swift
if result != .success {
    state.failures += 1
} else if isWindowOccluded(windowID: windowID) {
    state.failures = 0            // ← still covered → NO backoff
} else {
    // comment says: "raise accepted but still below another one … Back off"
    state.failures += 1           // ← actually on top → backoff grows anyway
}
```

The `else if` and `else` bodies are swapped with respect to both their own comment and the
`backoff` computed at line 219. Consequences:

- Persistent occlusion (the common case for a pinned window: another app's window genuinely
  overlaps it) → `failures` stays `0` → `backoff == raiseInterval == 0.15` → the condition at
  line 223 is satisfied on every tick → **one `AXUIElementPerformAction(kAXRaiseAction)` per pin per
  150 ms, plus two `CGWindowListCopyWindowInfo` calls per tick, indefinitely**. This is precisely the
  "raise storm" the file header promises to avoid.
- A successful raise that *does* clear the occlusion increments `failures` up to the cap, so the
  *next* time the window is covered, the first re-raise can be delayed by up to 2 s → the visible
  flicker window grows with success, not with failure.

Fix — swap the bodies and keep the intent explicit:

```swift
if result != .success {
    state.failures += 1
} else if isWindowOccluded(windowID: windowID) {
    // Raise accepted, still covered (other app owns the screen): back off.
    state.failures = min(state.failures + 1, 4)
} else {
    state.failures = 0
}
```

### B2 · Pinned windows are not excluded from the occlusion test (mutual raise ping-pong)
**Severity: blocker** · `Topit/Supports/Accessibility.swift:208-224`, called from
`NativePinManager.swift:222` and `:251`

`isWindowOccluded` skips only Topit's own PID. Any *other* pinned window of another app is treated
as a legitimate occluder, so two native pins whose frames intersect (very common: pinning a browser
and a terminal side by side where they slightly overlap, or any two pins on one screen) will each
raise itself above the other on successive ticks. Neither pin is ever "correctly placed", so the
loop is unbounded, at ~6.7 AX raises/second/pin, and each raise also triggers the focus handback
below (B3) — i.e. focus ping-pong too.

Fix — pass the set of window IDs to ignore:

```swift
func isWindowOccluded(windowID: CGWindowID, ignoring ignoredIDs: Set<CGWindowID> = []) -> Bool {
    …
    if ignoredIDs.contains(wid) { continue }   // other pins are allowed above us
```

and call it with `Set(NativePinManager.shared.pins.keys)` (or `PinRegistry` native ids).

### B3 · AppleScript commands no longer resolve (`Topit` → `Topit_Fork` module rename)
**Severity: blocker** · `Topit.xcodeproj/project.pbxproj:298,328` +
`Topit/Scriptable/Scriptable.sdef:7,11,15,19,23`

`PRODUCT_NAME = "Topit Fork"` with no `PRODUCT_MODULE_NAME` override makes the Swift module name
`Topit_Fork` (verified: the last successful build emitted `Topit_Fork.swiftmodule`; the built app's
`CFBundleName` is `Topit Fork`). The sdef declares all five commands as `Topit.<class>`. The `cocoa
class="Module.Class"` attribute must match the runtime ObjC name, so `selectWindow`, `showSelector`,
`pnpFront`, `pnpMouse` and `unpinAllWindows` stop resolving — silently, because nothing validates
the sdef at build time. `NSAppleScriptEnabled` and `OSAScriptingDefinition` are still set, so the
suite is advertised to users and then fails.

Fix (preferred — keeps every other string stable):

```
PRODUCT_MODULE_NAME = Topit;      // add to both Debug and Release configurations
```

Alternative: rewrite the five `cocoa class=` values to `Topit_Fork.*` (brittle across further
renames). Verification after the fix: `sdef /Applications/Topit\ Fork.app` and a smoke test with
`osascript -e 'tell application "Topit Fork" to pnp mouse'`.

---

## Major

### F4 · `PinRegistry` duplicates mirror pin state and drifts from reality (upstream behaviour change)
**Severity: major** · `Topit/Supports/PinRegistry.swift:63-67,120-142` ·
`Topit/Supports/Accessibility.swift:84-88` · `Topit/ViewModel/OverlayView.swift:78-93`

`createNewWindow` registers every mirror pin into the registry, but **nothing unregisters it when
the overlay closes**. `OverlayView`'s `onWindowClose` cleans `SCManager.pinnedWdinwows` and
`AvoidManager`, and never touches the registry. The registry therefore reconstructs "is this mirror
pinned?" by *guessing* from panel titles plus a 3-second grace window
(`PinRegistry.mirrorRegistrationGrace`). Observable regressions:

- **3-second dead zone.** Close a mirror overlay with its own close button, press the `pinUnpin`
  hotkey within 3 s: `PinActions.toggle` finds the surviving `.mirror` entry, calls
  `PinActions.unpin` → `closeMirrorPanel` closes nothing → *nothing happens*. Upstream re-pinned
  immediately (`SCManager.pinnedWdinwows` had already been cleaned by `onWindowClose`).
- **Wrong pinned state in the hover button.** `HoverPinController.refreshPinnedState`
  (`HoverPinButton.swift:213-217`) reads `PinRegistry.shared.isPinned` *without* pruning, so after a
  manual overlay close the button keeps showing the filled "pinned" icon until something else prunes
  (opening the status menu, or the next `toggle`).
- **Menu item that does nothing.** `AppDelegate.unpinFromMenu` (`TopitApp.swift:286-290`) reads the
  mode from the same possibly-stale registry; for a dead mirror entry the item performs an empty
  unpin and the entry survives until the next prune.

Fix — make the registry the *derived* view, not a second source of truth:

1. Unregister where the pin actually dies: add `PinRegistry.shared.unregister(windowID:)` to
   `OverlayView`/`OverlayView12`/`OverlayViewOpacity` `onWindowClose` (alongside the existing
   `SCManager.pinnedWdinwows.removeAll`).
2. Then delete `mirrorRegistrationGrace` and the title-sniffing branch entirely; `prune()` for
   `.mirror` reduces to "entry has no live panel" with no timing guess.

### F5 · `raiseAll` copies the whole window list once per pin per tick
**Severity: major** · `Topit/Supports/NativePinManager.swift:198-205` + `:263-270`

`isOnscreen(windowID:)` calls `getAllCGWindows()` — a full `CGWindowListCopyWindowInfo` (filtered,
but still every on-screen window as dictionaries). It is called **per pin, per tick**: 5 pins at
6.7 Hz ≈ 33 window-list copies per second, plus `isWindowOccluded` (two more copies per pin per
tick) ≈ 100 IPC round trips/s to WindowServer. This is the "unbounded work" concern and it scales
with both pin count and window count.

Fix — snapshot once per tick and query that:

```swift
private func raiseAll() {
    guard AXIsProcessTrusted() else { return }
    guard !isOwnAppFrontmost else { return }
    let onscreen = Set(getAllCGWindows()?.compactMap { $0["kCGWindowNumber"] as? CGWindowID } ?? [])
    for windowID in Array(pins.keys) where onscreen.contains(windowID) {
        raise(windowID: windowID)
    }
}
```

Same for the hover poll (F6).

### F6 · Hover poll hits WindowServer 10×/s even when nothing moved
**Severity: major** · `Topit/ViewModel/HoverPinButton.swift:114-154,260-272`

Every tick calls `eligibleWindowUnderMouse` → `getAllCGWindows()`, unconditionally, even when the
cursor has not moved a pixel and even while the button is hidden. That is 10 full window-list copies
per second forever, starting at launch (`TopitApp.swift:104`). Cheap fix that preserves semantics:

```swift
private var lastMouse: NSPoint = .zero
private func tick() {
    …
    let mouse = NSEvent.mouseLocation
    defer { lastMouse = mouse }
    guard mouse != lastMouse || panel?.isVisible == true else { return }
```

Note this also removes the per-frame `CGRectTransform` conversion of every window in the list.

### F7 · Full-screen target leaves the previous window id armed
**Severity: major** · `Topit/ViewModel/HoverPinButton.swift:138-147`

```swift
if windowID != targetWindowID {
    if isFullscreen(windowID: windowID) { scheduleHide(); return }   // returns WITHOUT clearing state
    targetWindowID = windowID
```

Between moving onto a full-screen window and the hide firing `hideDelay` later (default 0.5 s), the
button is still visible, still bound to `targetWindowID` of the *previous* window, and still
clickable. A user sliding the cursor across a full-screen window towards another app and clicking
can therefore pin/unpin the window they came from.

Fix — clear immediately, then schedule the hide:

```swift
if self.isFullscreen(windowID: windowID) {
    hideButton()
    return
}
```

### F8 · Focus handback can fight the raise loop
**Severity: major** · `Topit/Supports/NativePinManager.swift:242-248`

Every raise captures `frontmostBefore`, performs the AX raise, and re-activates the previous
frontmost app if it changed. Combined with the raise being re-issued on occlusion (B1/B2), this is a
closed loop: raise → owner app comes forward → hand back → previous app's window(s) come forward →
occlusion again → raise. Each iteration can also deliver a visible focus flicker in the app the user
is actually typing in. Suggestions:

- Only hand focus back when the *current* frontmost app is the pinned window's owner **and** it was
  different before (i.e. the raise actually stole focus) — today the handback runs on every raise.
- Throttle the handback independently of `raiseInterval` (e.g. at most once per second per window),
  and/or drop it behind an `AppStorage` toggle next to Gentle Mode, since "calm" users will prefer
  no handback at all.

### F9 · Native `pin()` result is discarded → dead pins appear in the UI
**Severity: major** · `Topit/Supports/PinActions.swift:53` · `NativePinManager.swift:79-97`

`NativePinManager.pin` is `@discardableResult` and returns `false` when the AX element cannot be
resolved (no permission yet, or an app that does not expose windows), but it still registers the pin
in `PinRegistry` before raising. Until the 20-tick `lookupFailures` escape hatch fires (~3 s), the
window appears in the "Pinned Windows" submenu and the hover button shows the filled icon, although
it will never be raised. `PinActions.pin` should handle failure:

```swift
case .native:
    if !NativePinManager.shared.pin(windowID: windowID) {
        PinRegistry.shared.unregister(windowID: windowID)
        // surface it: status-menu note or `tips(...)`, as upstream does for other failures
    }
```

### F10 · Global-timer + AppKit ordering details
**Severity: major (minor each, aggregate significant)**

- `Topit/ViewModel/HoverPinButton.swift:206-210`: `panel.orderFront(self)` followed by
  `panel.order(.above, relativeTo: Int(windowID))`. Two ordering calls per reposition, and the second
  one takes a **foreign** window number — `NSWindow.order(_:relativeTo:)` is documented in terms of
  AppKit window numbers and is not guaranteed to work across processes; it happens to work today and
  upstream relies on it too (`WindowHighlighter.swift:133`). Since the panel is already at
  `.floating` level (above all `layer == 0` windows) the second call is largely redundant. Either
  drop it and rely on the level (simpler, less WindowServer chatter), or keep it and add a comment
  that it is best-effort.
- `Topit/ViewModel/HoverPinButton.swift:187-204` (coordinate math): `CGRectTransform` flips CG
  top-left coordinates using the **main screen height** (`Accessibility.swift:169-178`), then the
  result is clamped to `getScreenWithMouse()?.frame`, which is in the global AppKit coordinate space.
  On arrangements where a secondary display is above/below the main display, those two spaces do not
  agree, so the flip is wrong and the clamp can push the button onto another screen. Upstream has the
  same limitation for its overlays, so this is "consistent with the baseline" — but the hover button
  is a new UI that is *supposed* to be reachable anywhere, so it is worth using
  `NSScreen.screens.first { $0.frame.contains(frame.origin) }` for the flip, or simply clamping to the
  union frame of `NSScreen.screens`.
- `Topit/ViewModel/HoverPinButton.swift:219-224`: `hideButton()` clears `targetWindowID` and
  `hostedWindowID` but leaves `lastFrame` set, so re-entering a window whose frame equals the stale
  value silently skips the first reposition (harmless today because `ensurePanel` runs first — but
  the invariant is accidental). Reset `lastFrame = .zero` in `hideButton()`.

### F11 · Sparkle was made inert but its UI was not
**Severity: major** · `Topit/Supports/Sparkle.swift:11-19` · `Topit/TopitApp.swift:46,80,136-138` ·
`Topit/Info.plist:8-21`

With `SUFeedURL` removed, `hasConfiguredFeed == false` and the updater never starts, yet:

- `TopitApp.swift:46` still installs `CheckForUpdatesView(updater: updaterController.updater)` in the
  app's `commands`, and
- the status-menu item "Check for Updates…" (`:80`) still calls `updaterController.checkForUpdates(nil)`
  unconditionally.

Both are dead UI in the fork. `docs/fork.md` claims the item "shows up *disabled*" — that is true
only for the SwiftUI `CheckForUpdatesView`, not for the AppKit menu item, so the document currently
overstates the behaviour. Fix: gate both on `hasConfiguredFeed` (expose it as `var`), or hide the two
items when there is no feed, and align `docs/fork.md` with whatever you implement.

### F12 · Upstream behaviour changes that look accidental
**Severity: major** · `Topit/Supports/PinActions.swift:46` · `Topit/TopitApp.swift:96`

- `PinActions.pin(.mirror)` calls `closeMainWindow()` (closes the window titled `"Topit"`,
  `TopitApp.swift:179-183`) for **every** pin entry point. Upstream only did this from
  `pnpUnderMouseWindow`/`pnpFrontmostWindow`. The two remaining entry points — window selection in
  `ContentView.swift:51` and the click mask in `WindowHighlighter.swift:37` — therefore now also close
  Topit's main panel, which upstream did not (ContentView already closed its own `panel` explicitly).
  If that is desired, it belongs in the two call sites; if not, it is a regression.
- `scPerm` is now only probed in mirror mode (`:96`), which is right for the Screen Recording prompt,
  but it is also used for `mainPanel.level = .floating` (`:111`). In native mode the main panel
  silently stops floating. Consider `if axPerm && (scPerm || PinActions.currentMode == .native)`.
- `WindowHighlighter.swift:34-38`: replacing the `SCWindow` lookup with `getCGWindowWithID` means the
  "flash red" branch is now unreachable for any on-screen `layer == 0` window, including ones that are
  not capturable. In mirror mode `PinActions.pin` then fails silently after `closeMainWindow()`. Keep
  a user-visible failure (red flash / `tips`) for that case.

---

## Minor

| # | Severity | File:line | Issue / fix |
|---|---|---|---|
| M1 | minor | `NativePinManager.swift:44-45` | Doc comment says the timer "polls `isWindowOnTop`" — it polls `isWindowOccluded`. Fix the comment. |
| M2 | minor | `NativePinManager.swift:219,232` | Magic numbers `4` (exponent cap) and `20` (lookup-failure budget): promote to named constants (`maxFailures`, `maxLookupFailures`) so the "≈3 s" comment has a single source of truth. The cap makes `min(0.15·2⁴, 2.0) == 2.0`, i.e. the cap is effectively 3 — harmless but undocumentable. |
| M3 | minor | `NativePinManager.swift:66`, `HoverPinButton.swift:87-88` | `@AppStorage` inside plain classes works but does not publish; in a `final class` singleton it is fine, yet it is an easy trap for future maintainers. Prefer a small `UserDefaults` wrapper or injecting the setting (upstream uses `@AppStorage` in `View`s only). |
| M4 | minor | `NativePinManager.swift:72,74` | `windowIDs` and `isPinned(_:)` are dead (no call sites). Delete. Same for `PinRegistry.isEmpty`/`entries(of:)` (`PinRegistry.swift:77,79`), `PinMode.id` (`:35`) and `HoverPinController.stop()` (`HoverPinButton.swift:106-110`, never called). |
| M5 | minor | `PinRegistry.swift:56` | `static func ==` comparing `id` only — an `Equatable` that ignores every other field is a footgun (`entries == other` would be true for entries with different modes/titles). `Equatable` is not needed at all here; drop it or synthesise. |
| M6 | minor | `PinActions.swift:68-73` vs `:76` vs `Accessibility.swift:49` vs `PinRegistry.swift:128-129` | The `"Topit Layer<id>[O]"` title format is constructed/parsed in **four** places, and `"Topit Screen Cover"`/`"Topit Mask Window"` in two more. Extract e.g. `enum MirrorPanel { static func title(windowID: CGWindowID, opacity: Bool) -> String; static func close(windowID: CGWindowID) }` and use it in all of them — otherwise the next format change silently desynchronises `prune()` from `closeMirrorPanel`. |
| M7 | minor | `TopitApp.swift:274-275` | Comment explains `tag` truncation risk for a lookup that does not use `tag` at all. Delete the comment (or the dead `representedObject`/`tag` discussion) — comments that explain code that isn't there are worse than none. |
| M8 | minor | `HoverPinButton.swift:255-259` | The comment claims skipping own-app windows means "the real window behind a mirror pin is not offered twice". It is: Topit's overlay is skipped (own PID) and the *source* window underneath is then the top eligible hit, so hovering a mirror offers the source window. Rephrase, or explicitly exclude windows that are already mirrored if that is the intent. |
| M9 | minor | `Accessibility.swift:113-117` | New doc comment on `getFrontmostCGWindow` is good, but `PinActions.swift:10` refers to "acceptance criterion 6" — a planning artefact leaking into shipped source. Replace with the actual rationale. |
| M10 | minor | `PinRegistry.swift:65-67` | Comment says the grace period exists because "a prune running in between would drop a healthy pin"; the panel is created synchronously before registration, so the actual need is different. With F4 fixed the whole mechanism disappears — otherwise rewrite the comment to match reality. |
| M11 | minor | `TopitApp.swift:125-127` | `applicationWillTerminate` → `unPinAll()` → `DispatchQueue.main.async`. The block may never run during termination, so native pins are not released on quit. Since the process exits, this is harmless in practice, but either make `unPinAll()` synchronous there or note it. |
| M12 | minor | `TopitApp.swift:255-266` | `menuNeedsUpdate` calls `PinRegistry.shared.prune()`, which is O(entries) with two IPC calls per entry, on **every** submenu open. Fine after F4/F5; today it also means the menu can take ~10 ms per pinned window to appear. |
| M13 | minor | `TopitApp.swift:286-290` | `unpinFromMenu` trusts a possibly stale registry entry. Add `PinRegistry.shared.prune()` before reading the mode (or after fixing F4 this is moot). |
| M14 | minor | `HoverPinButton.swift:177` → `:42` | `NSHostingView(rootView: HoverPinButton().environmentObject(self))` plus `self.panel = panel` forms a retain cycle controller → panel → hosting view → root view → controller. Harmless for a singleton, but if the controller ever becomes non-global this leaks a panel. Consider a `@Published` state struct owned by the panel's content view and a weak back-reference, or at least comment the intentionality. |
| M15 | minor | `SettingsView.swift:100-118` | New rows are plain English literals while every neighbouring string uses the `"key".local` pattern, so the zh-Hans/zh-Hant UI is half-translated. Per the brief this is acceptable, but the *tooltips* are long sentences — worth at least adding English `Localizable.strings` entries so they can be translated later. |
| M16 | minor | `HoverPinButton.swift:183` | `"Topit Hover Pin \(windowID)"` hard-codes the old app name even though the product is now `Topit Fork`, and unlike the overlay panels it is not derived from anything. Use a single `Self.panelTitle` + a shared prefix constant, or drop the title entirely (nothing looks it up — the panel is not pruned by title). |
| M17 | minor | `SettingsView.swift:104-113` | `SPicker("Pin Mode", …)` lets the user switch modes while windows are pinned in the other mode. Nothing re-pins or warns. Either migrate existing pins on change, or add a note that the change applies to the next pin. Also: `nativePinGentleMode` only affects newly-started timers (see B-series comment at `NativePinManager.swift:140`) — turning Gentle Mode *off* has no effect until the next app switch; document it in the tooltip. |
| M18 | minor | `WindowHighlighter.swift:107` | Owner-name comparison against `Bundle.main.appName` relies on CFBundleDisplayName-or-CFBundleName being exactly equal to the process display name (`CFBundleName` = `Topit Fork`, verified). It works, but it is still string matching against a localisable value; comparing `kCGWindowOwnerPID` to `ProcessInfo.processInfo.processIdentifier` (as `isWindowOccluded` and the hover eligibility already do) would be immune to renames. |
| M19 | minor | `HoverPinButton.swift:124` | Self-hover uses `panel.frame.insetBy(dx: -8, dy: -8)` — magic `8`. And `buttonSize`/`inset` are constants while `4` (`showButton:201`) is not. Naming one more (`Self.hoverSlop`) completes the set. |
| M20 | minor | `HoverPinButton.swift:231-234` | `hideDelay` clamps to `[0, 5]` but is documented only in a comment as a `defaults write` tweak. Fine, though reading `ud.object(forKey:)` on every hide could just as well be `@AppStorage` with a clamp, which also makes it observable. |

---

## License / compliance

- **Attribution intact.** `LICENSE` is the unmodified AGPL-3.0 text; `README.md:23-33` adds a clear
  fork notice with a link to `lihaoyun6/Topit`; `NSHumanReadableCopyright` still credits
  `lihaoyun6` (`project.pbxproj:290,320`); `Credits.rtf` (Base/zh-Hans/zh-Hant) still point at the
  upstream repository. `docs/fork.md` documents identity, defaults domain and Sparkle changes. New
  source files carry an explicit "Fork addition (AGPL-3.0, same license as upstream)" header, which
  satisfies AGPL §5(a)'s "prominent notices of modification".
- **No private/undocumented APIs** beyond the one already documented: the code uses only public
  `CGWindowListCopyWindowInfo`, `AXUIElement*`, `NSWorkspace` notifications. The single stringly-typed
  private attribute is `"AXFullScreen"` (`HoverPinButton.swift:283`) — intentional, documented, and
  fail-open. Everything else (`SkyLight`, `CGS`) appears only as prose in `docs/research/`.
  Keep it that way: nothing in the diff links against a private framework.
- **One doc nit:** `README.md:39` still instructs users to `brew install lihaoyun6/tap/topit`, which
  installs *stock* Topit, not this fork. Either remove the Homebrew line for the fork or mark it
  clearly as "upstream".
- `Info.plist` keeps `NSAppleScriptEnabled` + `OSAScriptingDefinition` while the suite is broken per
  B3 — either fix B3 or remove the keys so you do not advertise a dead interface.

---

## Things done right

- **The AX raise loop avoids ScreenCaptureKit properly.** Splitting `getFrontmostCGWindow()` out of
  `getFrontmostWindow()` (`Accessibility.swift:118-136`) is the right seam, and gating the launch-time
  `SCManager.updateAvailableContentSync()` on the mode (`TopitApp.swift:96`) is the change that makes
  "native-only users never see a Screen Recording prompt" actually true rather than aspirational.
- **Occlusion instead of "nothing above me".** `isWindowOccluded` is the correct predicate, and the
  rationale comment (why `isWindowOnTop` is unusable) is genuinely useful. Same for skipping Topit's
  own windows via PID rather than name.
- **Single panel, ever.** `HoverPinController` allocates exactly one `NNSPanel` and re-titles it per
  target (`ensurePanel`, `HoverPinButton.swift:158-181`) — no per-hovered-window panel leak, which is
  the failure mode most implementations of this feature fall into.
- **Window id is captured at hover time, not at click time** (`HoverPinButton.swift:47-50`) — exactly
  the right call, and stated as such.
- **Everything on the main thread.** Both `Timer`s are created with `Timer(timeInterval:repeats:)`
  and added to `RunLoop.main` (`.common` for the pin loop — including the menu-tracking rationale),
  both callbacks use `[weak self]` plus `invalidate()`, and all AppKit/AX calls happen on main. No
  locks needed and none claimed incorrectly.
- **Self-healing bounds.** `lookupFailures > 20` and the `AXIsProcessTrusted()` gate keep the loop
  from hammering WindowServer forever when Accessibility is missing or an app exposes no windows;
  `PinState` caching the `AXUIElement` (with an `isValid` re-check) avoids re-walking the owner app's
  window list on every raise.
- **Observers installed once, and the raising loop is defensive about Space changes.** `raiseAll`
  refusing to raise off-screen windows (`isOnscreen`) is the right way to avoid dragging the user to
  another Space, and it is documented honestly as relying on `optionOnScreenOnly` because there is no
  public Space API.
- **Menu-driven unpin for native pins** (`TopitApp.swift:252-291`) closes a real functional gap —
  without it, a native pin has no UI at all. Building it in `menuNeedsUpdate` rather than caching is
  correct.
- **Diff hygiene:** baseline files are touched surgically; `AvoidManager`, the Sparkle view model,
  localization and AppleScript (other than B3's module-name fallout) keep working, and the research
  documents make the design reviewable. No `--no-cache`-style blunt instruments anywhere.

---

## Addendum: status vs. `15c72e9`

`15c72e9` (landed 20:29, after this review started) touches `NativePinManager`, `PinRegistry`,
`HoverPinButton`, `ContentView`, the three `OverlayView*` files, `SCManager` and `TopitApp`
(9 files, +54/−18). Mapping my findings onto it:

| Finding | Status after `15c72e9` |
|---|---|
| **B1** inverted backoff branches | **Fixed** — the `else if`/`else` bodies are now swapped (`NativePinManager.swift:255-260` at `15c72e9`). The commit message confirms the diagnosis independently. |
| **B2** pinned windows occlude each other | **Still open** — `Accessibility.swift:208` unchanged; nothing excludes other pins from the occlusion test. |
| **B3** AppleScript / module rename | **Still open** — no `project.pbxproj` change; the module is still `Topit_Fork` vs. `Topit.` in the sdef. |
| **F4** mirror registry drift | **Mostly fixed** — mirror pins now unregister in `OverlayView*/OverlayViewOpacity/OverlayView12` `onWindowClose`, and `mirrorRegistrationGrace` dropped from 3 s to 0.3 s (`PinRegistry.swift:69`). The residual risk is now only 300 ms wide, and the duplicate title-format parsing (M6) is what keeps it alive at all — with M6 fixed the grace could go to zero. |
| **F5** per-pin `getAllCGWindows()` in `raiseAll` | **Still open** — unchanged at `NativePinManager.swift:199` / `:274`. |
| **F6** hover poll hits WindowServer when idle | **Still open** — unchanged at `HoverPinButton.swift:114`. |
| **F7** full-screen target keeps previous id armed | **Still open** — unchanged at `HoverPinButton.swift:142-148`. |
| **F8** focus handback vs. raise loop | **Still open** — unchanged at `NativePinManager.swift:~248-257`. Now interacts with the corrected backoff, so it is bounded to ~2 s intervals rather than 150 ms; still worth throttling. |
| **F9** discarded `pin()` result | Partially mitigated (the AX element is now resolved before the occlusion guard, so unresolvable pins are cleaned up) but the `Bool` from `NativePinManager.pin` is still discarded at `PinActions.swift:53`, so a failed native pin still shows up in the menu and as "pinned" in the hover button for one cleanup cycle. |
| **F11** Sparkle UI alive though inert | **Still open** — no change to `Sparkle.swift` / `TopitApp.swift` menu wiring. `15c72e9` *does* stop the Selector panel auto-opening at launch in native mode (good, same family of "don't demand Screen Recording you don't need"). |
| **F12** accidental upstream behaviour changes | `ContentView`'s Selector button now routes through `PinActions` (good), but `PinActions.pin`'s `closeMainWindow()` still fires for entry points that never closed the main panel upstream. Still open. |
| M1–M20 | Untouched by `15c72e9`; still valid. |

Net effect: **two blockers were one blocker** after `15c72e9` (B1 gone), and the remaining blockers are
B2 (raise ping-pong between two overlapping native pins) and B3 (AppleScript).
