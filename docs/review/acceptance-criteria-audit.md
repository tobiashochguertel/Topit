# Acceptance-criteria audit — native pin mode + hover pin button

Date: 2026-11-16 · Auditor: subagent (read-only) · Branch under test: `feat/hover-pin-button`

> **Path note.** The audit brief named the repo as
> `.../github/tobiashochgurtel/topit` ("gurtel", no `e`). That directory is **not** the fork — it contains only
> `docs/research/*.md`. The real fork (`.git`, `Topit.xcodeproj`, Swift sources) is at
> `/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit`
> (`tobiashochgu**e**rtel`). This report therefore lives in that repo. Nothing outside this file was created
> or modified; no file was edited, nothing was committed, no permission was reset.

Commits audited (`git log --oneline main..HEAD`, 6 commits, 25 files, +3686/−53):

```
a730bfa fix(pin): snapshot pin ids before iterating
45e868e fix(pin): close three gaps in mode handling found while tracing every call site
24da210 docs: native always-on-top research, implementation notes, verification probes
b77ba65 feat(hover): floating pin button on the hovered window
355b587 feat(pin): add native keep-on-top mode next to mirror mode
db39306 chore(fork): separate fork identity from upstream Topit
```

---

## 1. Verdict table

| # | Criterion | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | xcodebuild clean build, no new warnings | **PASS** | `xcodebuild -project Topit.xcodeproj -scheme Topit -configuration Debug clean build CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` → `** BUILD SUCCEEDED **`, 0 errors. 11 distinct warnings, **all** in `Topit/Supports/SCManager.swift` (lines 9, 69, 75, 92, 98, 260, 294 ×2, 295, 296, 304), all pre-existing ScreenCaptureKit `#SendableClosureCaptures` / `#AddPreconcurrencyImport`. No warning from `NativePinManager.swift`, `PinRegistry.swift`, `PinActions.swift`, `HoverPinButton.swift`, `TopitApp.swift`, `Accessibility.swift`, `ContentView.swift`, `SettingsView.swift`, `WindowHighlighter.swift`, `AppleScript.swift`, `Sparkle.swift`. Pre-existence checked by comparing each warning line against `git show main:Topit/Supports/SCManager.swift` with the +2 line shift (the only change there is `Supports/SCManager.swift:148-150`, comment + `let`→`var`). |
| 2 | Mirror mode unchanged (pin → overlay, unpin removes it, hotkeys/menubar) | **CANNOT-VERIFY-STATICALLY** (code-equivalent; 2 divergences found) | Mirror pin still ends in the same upstream calls in the same order: `PinActions.pin` (`Supports/PinActions.swift:44-51`) → `closeMainWindow()` → `getSCWindowWithID(_:noFilter:)` → `getSCDisplayWithMouse()` → `createNewWindow(display:window:)` (`Supports/Accessibility.swift:48`), vs `git show main:Topit/TopitApp.swift` which did the same inline. Unpin still closes `Topit Layer<id>` / `Topit Layer<id>O` panels (`Supports/PinActions.swift:68-73`, identical to upstream). Menu bar items and hotkey wiring unchanged (`Topit/TopitApp.swift:68-90`, `SettingsView.swift:167-176`). Divergences noted in §3, defects **D4** and **D5**. Manual runtime pass still required. |
| 3 | Native mode keeps a real window on top, clicks land in it, unpin restores order | **CANNOT-VERIFY-STATICALLY** (loop is wired correctly, but two logic defects) | Loop is complete: `PinActions.pin` → `NativePinManager.pin` (`Supports/NativePinManager.swift:80-97`) installs observers (`:119-135`), starts the 150 ms timer (`:157-170`), raises once forced (`:95`). Raise is `AXUIElementPerformAction(_, kAXRaiseAction)` with focus handback (`:242-248`); nothing changes window level, so "unpin restores normal ordering" is inherent (`unpin` → `:99-103`). No `SCK` on this path. **But** the failure/backoff accounting is inverted (**D1**, `:249-257`) and the documented "unresolvable window is dropped after ~3 s" only fires while the window is occluded (**D2**, `:226-234`). Runtime verification needed (raise has never been exercised — see `docs/native-pin-mode.md:146`). |
| 4 | Hover button: appears, follows, toggles in active mode, shows pinned state, hides on leave, dual-monitor | **CANNOT-VERIFY-STATICALLY** (all loops present; 1 state-refresh defect) | 10 Hz `Timer` started from `applicationDidFinishLaunching` (`Topit/TopitApp.swift:104` → `HoverPinButton.swift:96-104`); target selection `tick` (`:114-154`); frame follow-up on every tick (`:148-151`); panel created `.floating` + `order(.above, relativeTo:)` (`:158-211`); click → `PinActions.toggle(windowID:)` with the id captured at hover time (`:46-51`); hide 0.5 s after leave (`:236-244`, delay `:231-234`); dual-monitor handled by clamping to `getScreenWithMouse()` (`:199-204`) and the main-screen-height flip in `CGRectTransform` (`Accessibility.swift:169-178`). **But** pinned state is not refreshed while the cursor rests on the button (**D3**, `:124-127`). |
| 5 | Hotkey "Pin / Unpin Under-Mouse Window" respects the active mode for pin *and* unpin | **PASS** (by construction) | `SettingsView.swift:172` recorder `.pinUnpin` → `SettingsView.swift:200` `KeyboardShortcuts.Name.pinUnpin` → registered `TopitApp.swift:89` → `pnpUnderMouseWindow()` (`TopitApp.swift:166-170`, CG-only, no SCK) → `PinActions.toggle` (`Supports/PinActions.swift:27-34`): unpin uses `PinRegistry.shared.mode(for:)`, pin uses `PinActions.currentMode` (`:21-24`, key `pinMode`, same key bound by `@AppStorage("pinMode")` in `SettingsView.swift:101`). Sibling hotkey `.pinUnpinTopmost` equally mode-clean (`TopitApp.swift:172-178` → `getFrontmostCGWindow`, `Accessibility.swift:118`). |
| 6 | No Screen Recording prompt using only native mode + hover button | **FAIL (static)** | The app reaches ScreenCaptureKit at **launch**, before and independent of the pin mode: `AppDelegate.applicationDidFinishLaunching` (`Topit/TopitApp.swift:100-105`) calls `applicationShouldHandleReopen` whenever `showOnDock` is true (`:54`, default `true`) → builds the main panel hosting `ContentView` (`:117-119`) → `ContentView.onAppear { viewModel.setupStreams(...) }` (`ViewModel/ContentView.swift:168`) → `SCManager.updateAvailableContent` (`Supports/SCManager.swift:256`) → `SCShareableContent.getExcludingDesktopWindows` (`:166`) **and one `SCStream` capture per window** (`:268-286`). `pinMode` is not consulted anywhere on this path. Full map in §2. |
| 7 | Small focused commits, conventional style, comments where non-obvious, no secrets/telemetry | **PASS** (one nit) | 6 commits, all `type(scope): subject`; per-commit diffs are 1–6 files (see stat above); only `24da210` is large (2670 lines) and it is docs-only. Comments are extensive and cite sources (e.g. `NativePinManager.swift:15-31`, `HoverPinButton.swift:11-35`, `PinRegistry.swift:5-23`). Secrets: `git diff main..HEAD \| grep -E "api[_-]?key\|token\|secret\|password\|analytics\|telemetry\|sentry\|mixpanel\|posthog\|firebase"` → only GitHub/doc URLs and the *removal* of upstream's Sparkle key; no `URLSession`, no new network use. `Topit/Info.plist` **removes** `SUFeedURL`/`SUPublicEDKey`; `Supports/Sparkle.swift:11-18` starts Sparkle inert. Nit: `24da210` ("docs") bundles 2670 lines of research docs in one commit. |

---

## 2. Reachability map — ScreenCaptureKit vs user-visible entry points

Every call site that can reach SCK (`updateAvailableContentSync`, `SCShareableContent`, `getSCWindowWithID`,
`getSCDisplayWithMouse`, `createNewWindow`, `setupStreams`), and whether it is reachable for a user who set
**Pin Mode = Native** and uses only the hover button / hotkeys.

| # | Call site | Reached from | Reachable in native-only use? |
| --- | --- | --- | --- |
| 1 | `Topit/TopitApp.swift:96` `SCManager.updateAvailableContentSync()` | `applicationWillFinishLaunching` | **No** — gated by `PinActions.currentMode == .mirror` (`TopitApp.swift:96`). Correct. |
| 2 | `Supports/Accessibility.swift:19` (`getSCWindowWithID`) → `updateAvailableContentSync` | (a) `PinActions.swift:49` — **mirror branch only**; (b) `Accessibility.swift:133` (`getFrontmostWindow()`) — **no remaining caller** (grep: only its own definition; all in-app callers now use `getFrontmostCGWindow`) | **No** |
| 3 | `Supports/Accessibility.swift:24` `getSCDisplayWithMouse` | reads cached `SCManager.availableContent`; called from `PinActions.swift:50` (mirror), `OverlayView.swift:179`, `OverlayViewOpacity.swift:165` | **No** — needs an existing mirror overlay or an explicit mirror pin. Does not itself prompt. |
| 4 | `Supports/Accessibility.swift:48` `createNewWindow` | `PinActions.swift:51` (mirror branch), `ContentView.swift:215`, `OverlayView.swift:181`, `OverlayViewOpacity.swift:167` | **Only via #6 below / existing overlays** — see row 6. |
| 5 | `supports/SCManager.swift:255` `setupStreams` → `updateAvailableContent` → `getExcludingDesktopWindows` + `SCStream` per window | `ContentView.onAppear` (`ContentView.swift:168`), "Update Window List" buttons (`:34`, `:195`), tab/noTitle changes (`:57`, `:173`, `:221`), error recovery (`:57`, `:221`) | **YES — at every launch.** See row 6. |
| 6 | _Launch chain (composite)_ | `applicationDidFinishLaunching` (`TopitApp.swift:100-105`) → `applicationShouldHandleReopen` (`TopitApp.swift:101`, guard only checks no visible "Topit" panel) → `NSHostingView(ContentView())` + `makeKeyAndOrderFront` (`:117-120`) → `ContentView.onAppear` (`ContentView.swift:168`) → row 5 | **YES, unconditional.** `showOnDock` defaults to `true` (`TopitApp.swift:54`, `SettingsView.swift:40`), so this runs on a stock install in native mode. This single path invalidates criterion 6 and it is not mentioned in `docs/native-pin-mode.md:111-119`, which audits only rows 1–3. |
| 7 | "Window Selector" menu (`TopitApp.swift:77` / hotkey `.openMainPanel`, `TopitApp.swift:87`) and dock re-open | same `applicationShouldHandleReopen` | **Yes** — user-triggered; arguably legitimate because it is the mirror-mode picker, but it is one keystroke away in native mode. |
| 8 | `OverlayView.swift:178-181`, `OverlayViewOpacity.swift:164-167` (re-create overlay with opacity) | inside an existing mirror overlay | **No** — requires a mirror pin to exist. |

Additional amplification: if the user declines, `SCManager.updateAvailableContent` retries itself after 1 s
forever (`Supports/SCManager.swift:169-172`), so the prompt can reappear rather than being a one-off.

**Criterion 6 would only hold in this configuration:** "Show Topit on Dock" off (`TopitApp.swift:54`,
`SettingsView.swift:63`) and the user never opens the Window Selector (`TopitApp.swift:77` menu item,
`.openMainPanel` hotkey `TopitApp.swift:87`). That is not the default and it is not stated in
`docs/native-pin-mode.md:149`, which claims row 6 is satisfied.

---

## 3. Defects found while tracing

### D1 — Raise-loop backoff accounting is inverted (medium)

`Topit/Supports/NativePinManager.swift:249-257`

```swift
if result != .success {
    state.failures += 1
} else if isWindowOccluded(windowID: windowID) {
    state.failures = 0        // ← raise did not take effect, yet the counter is reset
} else {
    state.failures += 1       // ← raise worked, yet the counter grows
}
```

The intent (and the documentation, `docs/native-pin-mode.md:62-64` "when a raise is accepted but occlusion
persists, the interval doubles up to 2 s") is the opposite. Consequences:

- When the raise cannot win (a foreign app owns the screen — the exact case the backoff exists for),
  `failures` stays 0 → backoff stays `raiseInterval` = 0.15 s → **a raise attempt every 150 ms indefinitely**,
  i.e. the raise storm the docs say is prevented; maximum visible flicker.
- When the raise succeeds, `failures` climbs, so the *next* needed raise is delayed by up to 2 s
  (`:219`) even though nothing failed.

Fix: swap the two branches —

```swift
} else if isWindowOccluded(windowID: windowID) { state.failures += 1 } else { state.failures = 0 }
```

### D2 — "Unresolvable window is dropped after ~3 s" rarely triggers (low)

`Topit/Supports/NativePinManager.swift:222-234`

`lookupFailures` only increments when `raise` gets past the occlusion/rate-limit guard at `:222-223`. A freshly
pinned window that is **not** occluded therefore never accumulates lookup failures, and a window that
Accessibility never exposes stays registered forever: it shows up in the status menu
(`TopitApp.swift:255-284`) and in `PinRegistry`, is never raised, and is never cleaned up (the app is still
running and the CG window still exists, so `PinRegistry.prune()` keeps it — `PinRegistry.swift:133-139`).
Fix: move the AX-resolution and `lookupFailures` accounting above the occlusion/rate-limit guard, or do the
lookup in `tick()` instead of only inside `raise`, as the doc (`docs/native-pin-mode.md:71-73`) implies.

### D3 — Hover button's pinned state is not refreshed while the cursor is on the button (medium, UX)

`Topit/ViewModel/HoverPinButton.swift:124-127`

```swift
if let panel, panel.isVisible, panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
    cancelPendingHide()
    return                 // ← skips refreshPinnedState() at :153
}
```

After clicking, the cursor is still inside that rect, so `targetIsPinned` is never recomputed: the icon keeps
showing `pin.circle` for a now-pinned window (and vice versa). The next click toggles *back*, i.e. the user can
pin and immediately unpin without any visual feedback — this is criterion 4's "shows pinned state" row.
Fix: call `refreshPinnedState()` before the `return` (and/or immediately after `PinActions.toggle` in the
button action at `:46-51`).

Related, lower impact: the same early return also means the button never hides while the cursor sits on it —
if the target window is destroyed underneath, the button for a dead window stays on screen.

### D4 — Window Selector's main pin button ignores the active pin mode (medium)

`Topit/ViewModel/ContentView.swift:210-215` still calls `createNewWindow(display:window:)` directly, while the
macOS 12/13 variant six lines above was converted to the mode-aware entry point (`ContentView.swift:51`
→ `PinActions.pin`). Selecting a window in the Selector and pressing **Topit!** therefore always creates a
mirror overlay and consumes a capture — even with Pin Mode = Native — and the user is asked for Screen
Recording permission from inside native mode. It also contradicts the Click-to-select path, which *is*
mode-aware (`WindowHighlighter.swift:35-38`).
Fix: replace `createNewWindow(display: display, window: window)` with `PinActions.pin(windowID: window.windowID)`
and keep `display` only for the availability check.

### D5 — Up to 3 s dead window after manually closing a mirror overlay (low)

`Topit/Supports/PinRegistry.swift:65-67, 120-141` + `Topit/Supports/PinActions.swift:27-33`

Upstream decided "is it pinned?" via `SCManager.pinnedWdinwows`, which `OverlayView`'s `onWindowClose`
removes synchronously (`OverlayView.swift:85-93`). The registry instead takes `mirrorRegistrationGrace = 3`
seconds before it may drop a mirror entry whose panel is gone. During those 3 s, `toggle` sees the id as still
pinned and calls `unpin` — which closes a panel that no longer exists — so pressing the un/pin hotkey on that
window appears to do nothing (twice, in fact: unpin-then-pin needs two further presses).
Fix: have the overlay's `onWindowClose` (or an `NSWindow.willCloseNotification` observer for titles starting
with `Topit Layer`) call `PinRegistry.shared.unregister(windowID:)`, and keep the grace period only as a
fallback.

### D6 — Updater menu item is inert (informational / fork intent)

`Topit/Supports/Sparkle.swift:11-18` + `Topit/Info.plist`

`SUFeedURL` was removed (correct: upstream's key cannot sign this fork), so `hasConfiguredFeed` is `false` and
the updater never starts; "Check for Updates…" (`TopitApp.swift:80, 136-138`) will do nothing rather than tell
the user why. Not an acceptance-criteria failure, but worth either hiding the item or disabling it when
`hasConfiguredFeed == false`.

### D7 — In native mode the Selector panel silently loses `.floating` (informational)

`Topit/TopitApp.swift:96` + `:111`

`scPerm` is now forced to `false` whenever the mode is not `.mirror`, and `applicationShouldHandleReopen` does
`if axPerm && scPerm { mainPanel.level = .floating }`. So in native mode the "Topit" panel opens at normal
level and can be covered by other windows. Side effect of a correct change (no SCK probe), but the coupling is
implicit — if the Selector is ever made native-safe, remember the level too.

### Non-defects checked on request

- `Topit/Scriptable/AppleScript.swift:30-35` — `unpinAllWindows` now routes through `PinActions.unpinAll()`,
  so AppleScript unpins native pins too. Behaviour preserved for mirror pins.
- `Topit/Supports/WindowAccessor.swift` — **unchanged** vs `main` (`git diff main..HEAD --stat` shows nothing),
  still used by `SettingsView` (`TopitApp.swift:29-43`) and every overlay (`OverlayView.swift:74-94`).
- `Topit/ViewModel/WindowHighlighter.swift` — the fork only swaps the mode check, the pin entry point and
  `"Topit"` → `Bundle.main.appName` (`:107`, needed because `PRODUCT_NAME` is now `Topit Fork`); the mask, the
  mouse monitors and `stopMouseMonitor()` are untouched. `HighlightMask.windowID` is used as a CG window id in
  `order(.above, relativeTo:)` (`:29`, `:133`) exactly as upstream did; the hover button copies that idiom
  (`HoverPinButton.swift:210`), and since its panel is `.floating` it is above normal windows anyway — low
  risk, not counted as a defect. The `"Topit"` → `Bundle.main.appName` swap was verified safe from the built
  product: `Debug/Topit Fork.app/Contents/Info.plist` has `CFBundleName = "Topit Fork"` (no
  `CFBundleDisplayName`), which is also the window owner name — so own-app windows are still excluded.

---

## 4. What still needs a human at a Mac

1. **Criterion 6**: gate the Selector (or its `setupStreams`) on `PinActions.currentMode == .mirror`, or make
   `ContentView` skip thumbnail capture in native mode. Then re-test with
   `tccutil reset ScreenCapture com.tobiashochgurtel.TopitFork` and no prior grant.
2. **Criterion 3**: run `docs/research/verification/axraise.swift <windowID>` unlocked (the doc at
   `docs/native-pin-mode.md:146` records that this was never done) to confirm `kAXRaiseAction` actually reorders
   on this macOS build; then fix **D1** and re-measure flicker.
3. **Criteria 2 & 4**: one manual pass each — mirror pin/unpin + every hotkey and menu item; hover button
   appearance, following, pinned icon (**D3**), hide-on-leave, and a second display.
