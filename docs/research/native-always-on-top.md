# Native (non-mirror) always-on-top for foreign windows on macOS

**Research date:** 2026-11-16
**Scope:** macOS 13 → macOS 26/27
**Purpose:** Establish ground truth for whether the Topit fork can replace itscreenCaptureKit
mirror overlay with a *native* "raise the real foreign window and keep it on top" implementation.

> Verdict up front: **the fork's plan assumption is essentially correct — but for a subtly different
> reason than "SIP blocks it".** SIP does *not* block `SLSSetWindowLevel`; WindowServer
> **ownership** does. And the Accessibility re-raise loop is not a hack — it is what the commercial
> app **ProToys** itself ships as its documented "Raise mode". Details and sources below.

---

## Executive verdict

**Is there a native (non-mirror) always-on-top solution for foreign windows usable by an
unsandboxed, Accessibility-permitted app on stock macOS with SIP enabled?**

**Yes — but not a *level-based* one. There is exactly one production technique that works on stock
macOS with SIP on: an Accessibility keep-on-top ("re-raise") loop.** It is what every shipping
product on modern macOS uses, including the commercial app you are comparing against.

1. **You cannot set another process's window level.** `SLSSetWindowLevel` / `CGSWindowSetLevel` /
   `CGSOrderWindow` either return an error or *silently no-op* for windows not owned by the calling
   WindowServer connection. This is a **WindowServer ownership** policy, **not** SIP. Root does not
   help.
2. **The only escape hatch is the "universal owner" connection**, which is either (a) the Dock's own
   connection — requiring Mach injection into `Dock.app` via `task_for_pid`, **which SIP *does*
   block**, or (b) a private entitlement `com.apple.private.skylight.universal-owner`, which AMFI
   refuses to run. Both are off the table for a shipped app.
3. **Therefore the realistic answer is the AX re-raise loop**  — `AXUIElementPerformAction(window,
   kAXRaiseAction)` re-asserted on activation changes plus a ~150 ms / ~4 Hz timer.

**Options**
   - Wrong. I never touched them. I should mention briefly but not act.

Let me write.</think:6124c78e>Target is clear (that `ax-native-pin-techniques.md` is pre-existing from your main session — I'll leave it untouched). Re-writing my report to the correct absolute path now:<tool_calls:6124c78e><tool_call:6124c78e>write<arg_key:6124c78e>content</arg_key:6124c78e><arg_value:6124c78e># Native (non-mirror) always-on-top for foreign windows on macOS

**Research date:** 2026-11-16
**Scope:** macOS 13 → macOS 26/27
**Purpose:** Establish ground truth for whether the Topit fork can replace its ScreenCaptureKit
mirror overlay with a *native* "raise the real foreign window and keep it on top" implementation.

> Verdict up front: **the fork's plan assumption is essentially correct — but for a subtly different
> reason than "SIP blocks it".** SIP does *not* block `SLSSetWindowLevel`; WindowServer
> **ownership** does. And the Accessibility re-raise loop is not a hack — it is what the commercial
> app **ProToys** itself ships as its documented "Raise mode". Details and sources below.

---

## Executive verdict

**Is there a native (non-mirror) always-on-top solution for foreign windows usable by an
unsandboxed, Accessibility-permitted app on stock macOS with SIP enabled?**

**Yes — but not a *level-based* one. There is exactly one production technique that works on stock
macOS with SIP on: an Accessibility keep-on-top ("re-raise") loop.** It is what every shipping
product on modern macOS uses, including the commercial app you are comparing against.

1. **You cannot set another process's window level.** `SLSSetWindowLevel` / `CGSWindowSetLevel` /
   `CGSOrderWindow` either return an error or *silently no-op* for windows not owned by the calling
   WindowServer connection. This is a **WindowServer ownership** policy, **not** SIP. Root does not
   help.
2. **The only escape hatch is the "universal owner" connection**, which is either (a) the Dock's own
   connection — requiring Mach injection into `Dock.app` via `task_for_pid`, **which SIP *does*
   block**, or (b) a private entitlement `com.apple.private.skylight.universal-owner`, which AMFI
   refuses to run. Both are off the table for a shipped app.
3. **Therefore the realistic answer is the AX re-raise loop** — `AXUIElementPerformAction(window,
   kAXRaiseAction)` re-asserted on activation changes plus a ~150 ms / ~4 Hz timer.

**Ranked options**

| # | Option | Works with SIP on? | Permissions | Interactivity | Trade-offs |
|---|--------|--------------------|-------------|---------------|------------|
| 1 | **AX re-raise loop** (`kAXRaiseAction` + activation/observer triggers + timer) | ✅ Yes | Accessibility only | ✅ Full native: click, scroll, keyboard all normal | Sub-frame flash when another window takes the top; AX raise couples with activation in some apps so focus can briefly flicker; no overlay above full-screen Spaces |
| 2 | **Keep ScreenCaptureKit mirror** (current Topit) | ✅ Yes | Accessibility + **Screen Recording** | ⚠️ Degraded — you click a copy | CPU/GPU cost per pinned window; hit-testing fragile; no real interaction |
| 3 | Hybrid: mirror for full-screen-Space scenarios, raise mode for everything else | ✅ Yes | Accessibility + Screen Recording (only if user picks mirror) | Best of both | More surface area to maintain |
| 4 | SkyLight universal-owner via private entitlement | ❌ Needs AMFI off | `com.apple.private.skylight.universal-owner` | ✅ Perfect | Will not launch on stock macOS |
| 5 | yabai-style scripting addition injected into `Dock.app` | ❌ Needs **partial SIP disable** + root | — | ✅ Perfect | Not shippable to general users; breaks every macOS release |

**Correction to the fork's plan note:** replace *"with SIP enabled there is no proper way to natively
raise a foreign window and keep it on top"* with *"with SIP enabled you cannot change a foreign
window's **level** (WindowServer ownership, not SIP); you can still **raise** it repeatedly via
Accessibility, which is what every shipping macOS app including ProToys does."*

**One caveat on your premise of a "sandboxed" app:** an App-Sandboxed app **cannot use cross-process
Accessibility at all** — see [§4.5](#45-the-sandbox-problem). Topit must ship unsandboxed (Developer
ID, outside the Mac App Store) for any of this to work.

---

## 1. SkyLight / CoreGraphics private APIs

### 1.1 Can `CGSWindowSetLevel` / `SLSSetWindowLevel` change another process's window level?

**No.** Multiple independent sources agree, and they agree on the *mechanism* (ownership), not SIP:

- **KiwiDesk issue #424** (2026-07, updated 2026-10) — an explicitly measured, SIP-on finding:
  > "`SLSSetWindowLevel(cid, wid, level)` only affects windows owned by the **connection that issues
  > it** (`cid`). Our process can level its *own* windows … but the floats this feature targets belong
  > to **foreign apps' connections**, which we cannot write."
  > — https://github.com/KiwiCanopy/KiwiDesk/issues/424

- **Aloft** (a 2026 menu-bar app whose entire purpose is "any window, always on top") states it in
  its README:
  > "macOS does not let one app change another app's window level. `SLSSetWindowLevel` reports
  > success from a foreign connection and is ignored, and `SLSSetUniversalOwner` is
  > entitlement-gated. Doing it properly needs code injected into a process the window server trusts,
  > which needs SIP disabled."
  > — https://github.com/iammayron/aloft

  Note the important nuance: **the call reports success (`CGError` 0) and is silently ignored.** Do
  not trust a `0` return value.

- **StackOverflow #3706167** (the canonical older answer):
  > "Why it doesn't work: Without being the Universal Owner, you can't change the order of a window
  > owned by another process."
  > — https://stackoverflow.com/questions/3706167/making-a-another-applicationss-window-frontmost-and-focused

- **StackOverflow #79135637** (2024-10, Sonoma), comment by a well-known macOS internals developer:
  > "much of the CGS APIs are locked down through an 'ownership' model. Apps only 'own' their own
  > windows and are only allowed to move those. The Dock process is a 'universal owner' and can
  > manipulate all the windows. … the Universal ownership is locked through a special entitlement,
  > and when you give your own app that entitlement macOS will just not run it. The only way that I
  > know of to manipulate windows is to use the Accessibility API."
  > — https://stackoverflow.com/questions/79135637/unable-to-move-windows-on-sonoma-using-private-apis-in-swift

- **StackOverflow #34738375** — empirical error codes for `CGSOrderWindow` on a foreign window:
   - with your own connection: `1000` ("cid does not have permission to modify target window")
   - with the *owner's* cid obtained from `CGSGetWindowOwner`: `268435459` (0x10000003, "current app
     does not have permission to use this ConnectionId")
   > — https://stackoverflow.com/questions/34738375/controlling-level-and-focus-of-windows-other-apps-with-cgprivate-functions

- Historical framing, quoted in #36075213 from `CGSConnection.h`:
  > "Only the owner of a window can manipulate it. So, Apple has the concept of a universal owner
  > that owns all windows and can manipulate them all. There can only be one universal owner at a
  > time (the Dock)."
  > — https://stackoverflow.com/questions/36075213/set-non-owned-window-always-on-top-like-the-app-afloat

### 1.2 Does SIP block these calls specifically?

**No — this is the most important correction.** SIP and WindowServer ownership are two *different*gates:

| Mechanism | Enforced by | What it blocks |
|-----------|-------------|----------------|
| File-system protection (`/System`, `/usr`, `/bin`, `/sbin`, `/var`, pre-installed apps) | Kernel (SIP) | Writing protected paths even as root |
| Runtime protection — `task_for_pid()`, `processor_set_tasks()` return `EPERM`; no dyld injection; no DTrace on protected processes | Kernel (SIP) | Attaching to / injecting into **protected (Apple-signed, platform) processes** including `Dock.app` |
| Code injection into `Dock.app` (Mach/bootstrap) | SIP runtime protection | yabai's scripting addition |
| **Window level / order writes on foreign windows** | **WindowServer itself (ownership model)** | `SLSSetWindowLevel`, `CGSOrderWindow`, `SLSSetWindowSubLevel` from a foreign cid |
| Private entitlements (`com.apple.private.*`) | AMFI | App will not run unless AMFI is relaxed |

The authoritative statement on the yabai side is explicit about *which* gate applies to what:

> "To inject code into the Dock we use the mach APIs; in particular `task_for_pid`. … In addition to
> this the Dock process is also flagged as a universal owner; its connection to the WindowServer has
> elevated privileges and is authorized to modify window properties that can otherwise only be set
> by the application whom the window belongs to."
> — https://github.com/asmvik/yabai/issues/1863

So: **SIP blocks getting *into* the Dock. WindowServer blocks writing foreign windows *from outside*
the Dock.** Disabling SIP does not by itself make `SLSSetWindowLevel` work — you must additionally
be running *inside* the Dock's connection.

And conversely, the read-only SLS surface works fine with SIP on:

> "Private, undocumented functions from CoreGraphics framework … Work on fully secured systems (no
> SIP disablement required) … Used for querying state rather than privileged modifications"
> — DeepWiki, *SkyLight Services (SLS) Private APIs*, https://deepwiki.com/asmvik/yabai/8.2-skylight-services-(sls)-private-apis

### 1.3 The universal-owner escape hatch, and why we can't ship it

**yabai issue #2593** is the single most valuable document for this fork. In it, contributor
`AlexStrNik` says he started reverse-engineering SkyLight specifically to build a Topit-like app
that does not mirror:

> "I started digging into all of this because I wanted to build my own version of Topit—but instead
> of streaming window content to a proxy window, my approach directly changes the level of any
> window."
> — https://github.com/asmvik/yabai/issues/2593

His method (Swift, reproduced in the issue):

```swift
func gainUniversalOwner() {
    var connection: UInt32 = 0
    SLSNewConnection(0, &connection)
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")[0]
    kill(dock.processIdentifier, SIGKILL)
    SLSSetUniversalOwner(connection)
    SLSSetOtherUniversalConnection(connection, self.connectionId) // self.connectionId = SLSMainConnectionID()
    SLSReleaseConnection(connection)
}
```

Why it is not shippable (same source):

> "Unfortunately, this method does require a private entitlement
> (`com.apple.private.skylight.universal-owner`), which likely won't work unless AMFI is disabled."

yabai's author confirms the capability (so the *mechanism* is real) while declining to ship it:

> "I have actually done this in the past, and it works fine for getting the universal owner
> connection privileges. This will allow yabai to perform some of the operations that require code
> injection today; primarily the ones that manipulate windows and their properties."
> — koekeishiya, https://github.com/asmvik/yabai/issues/2593

**Conclusion:** it works only with a private entitlement + AMFI disabled; it requires SIGKILLing the
Dock momentarily; and it is an unsigned-private-API code path. **Do not ship this.**

### 1.4 Also-ruled-out: `SLSBridged*` "space level" trick

KiwiDesk measured this on **macOS 27.0 with SIP on** and rejected it (2026-09-27 comment in #424):

- Enumerated 100 `SLSBridged*` classes; **none sets a single window's level or z-order**. Only
  Space-level operations exist: `SpaceSetAbsoluteLevel`, `SpaceSetOrderingWeight`, `SpaceSetFrontPSN`.
- Creating a Space, moving another process's window into it (`MoveWindowsToManagedSpace` is "the one
  cross-app membership write that applies") and raising the Space level: "Visually the whole current
  Desktop disappeared … It is a Desktop switch in disguise, not a layer."
- Shaped variant (`SpaceSetShape`) looked like a layer at rest but "does not follow the window",
  clips at the old rectangle, redraws visibly while dragging, and clicking below brought that window
  in front.
> https://github.com/KiwiCanopy/KiwiDesk/issues/424

### 1.5 Header dumps / API signatures (for reference only — do not ship)

| Symbol set | Source |
|---|---|
| `CGSGetWindowLevel`, `CGSGetWindowOwner`, `CGSConnectionGetPID`, `CGSSetWindowLevel`, `CGSOrderWindow`, `_CGSDefaultConnection` | https://github.com/fjolnir/xnomad/blob/master/CGSPrivate.h |
| `CGSGetWindowLevel`, `CGSGetWindowOwner`, `CGSMainConnectionID` | https://github.com/NUIKit/CGSInternal/blob/master/CGSConnection.h |
| Swift `@_silgen_name` bindings for SkyLight/CGS (alt-tab) | https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/src/macos/api-wrappers/SkyLight.framework.swift |
| Swift bindings incl. `CGSGetWindowLevel` (DockDoor) | https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift |
| Rust `SLSSetWindowLevel`-adjacent bindings (rift) | https://github.com/acsandmann/rift/blob/e95944ea/src/sys/skylight.rs |
| `CGWindowLevel.h` (public level constants) | https://github.com/w0lfschild/cDock/blob/master/_resource/xcode/cDock-Bundle/CoreGraphics.framework/Versions/A/Headers/CGWindowLevel.h |
| Apple: `CGWindowLevelKey` — "Applications do not need to use them directly" | https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey |
| Apple: `CGWindowLevelForKey(_:)` — raw CG level keys "not recommended for use in applications" | https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:) |

### 1.6 Root privileges?

Running as root does not grant WindowServer ownership. The SO #34738375 author explicitly tried both
own-cid and owner-cid paths and notes attempts "running as root, disabling SIP" in SO #79135637 —
still failed. Ownership is keyed to the **connection**, not the uid.

---

## 2. Ground truth on SIP

### What SIP actually enforces (Apple documentation)

- **File system:** only `/System`, `/bin`, `/sbin`, `/usr` (minus `/usr/local`) and pre-installed
  Apple apps are protected; `/Applications`, `/Library`, `/usr/local`, `~/Library` remain writable.
  > https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/FileSystemProtections/FileSystemProtections.html
  > https://support.apple.com/en-us/102149
- **Runtime / process attachment:**
  > "Attempting to get the Mach task for a process using the `task_for_pid` function or attempting to
  > get the permissions of a set of tasks using the `processor_set_tasks` function fails, returning
  > `EPERM`. … Any dynamic linker (`dyld`) environment variables, such as `DYLD_LIBRARY_PATH`, are
  > purged when launching protected processes. … Attempting to attach to a system process, such as
  > with LLDB, fails—even when running as root with sudo."
  > https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html
- Overview: "protecting access to system locations and **restricting runtime attachment to system
  processes**" — https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/Introduction/Introduction.html

### What SIP explicitly does *not* do (relevant here)

- It does **not** gate Accessibility (`AXUIElement*`) on other processes. That is **TCC**
  (System Settings → Privacy & Security → Accessibility), plus **App Sandbox** (see §4.5).
- It does **not** gate read-only WindowServer queries (`SLSGetWindowLevel`, `CGWindowListCopyWindowInfo`,
  `SLSGetWindowOwner`).
- It does **not** gate writing *your own* windows' level.

### Precise mapping onto our question

| Thing we might want | Blocked by | Usable on stock macOS? |
|---|---|---|
| `SLSSetWindowLevel(cid, foreignWid, kCGFloatingWindowLevel)` | **WindowServer ownership** | ❌ No (silently ignored) |
| `CGSOrderWindow(cid, foreignWid, …)` | **WindowServer ownership** | ❌ No (err 1000 / 0x10000003) |
| `SLSSetUniversalOwner` | **AMFI** (private entitlement) | ❌ No |
| Mach-inject a payload into `Dock.app` then call SLS from inside | **SIP runtime protection** | ❌ No — needs `csrutil` |
| `AXUIElementPerformAction(foreignWindow, kAXRaiseAction)` | **TCC** only | ✅ Yes, once Accessibility granted |
| Read window list / levels / bounds | nothing (SIP-safe per yabai) | ✅ Yes |

yabai documents the exact SIP relaxation needed for the Dock-injection path:

```sh
# Apple Silicon, macOS 13+
csrutil enable --without fs --without debug --without nvram
```
> https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection

and lists which features require it — notably **"control window layers (make windows appear topmost
or on the desktop)"**, i.e. exactly always-on-top:
> https://github.com/asmvik/yabai/issues/1863 and https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc
> ("The following properties require System Integrity Protection to be partially disabled: sticky,
> sub-layer, opacity, scratchpad.")

yabai's author adds the honest caveat:
> "I am aware of solutions that try to re-create some of these features without touching SIP, but the
> reality is that there is no way to implement said features properly without functional limitations,
> when SIP is enabled."
> — https://github.com/asmvik/yabai/issues/1863

---

## 3. The public-API alternative: Accessibility keep-on-top loop

### 3.1 `AXUIElementPerformAction(window, kAXRaiseAction)`

Apple's own wording is the key legal-ish constraint:

> "Causes a window to become **as frontmost as is allowed by the containing application's
> circumstances**. Note that an application's floating windows (such as inspector windows) might
> remain above a window that performs the raise action."
> — https://developer.apple.com/documentation/applicationservices/kaxraiseaction

So: it raises within the constraints WindowServer allows, and floating/panel windows can still sit
above it.

### 3.2 Can a non-active app's window actually render above the active app's windows?

**Yes.** This is the crux of the whole question, and the evidence is behavioural, from shipping
products:

- **ProToys** ships this as a first-class documented mode (see §4.1): "Raise mode — ProToys keeps the
  real window on top within its own desktop Space. You're clicking the actual window…"
- **Aloft**: "a pin is a re-raise: Aloft watches the stacking order and lifts a pinned window back
  whenever something covers it, immediately on an app switch and every 150ms otherwise. **In practice
  it stays in front.**"
- **KiwiDesk #418** ships "the AX re-raise fallback (`kAXRaiseAction` on focus of a tiled window),
  which is good enough in practice."
- **alt-tab** internals separate the two operations explicitly: "`_SLPSSetFrontProcessWithOptions`
  sets the front process, while `makeKeyWindow` and `kAXRaiseAction` **only move the window in the
  z-order**." — https://github.com/lwouis/alt-tab-macos/commit/886f21a

So macOS does **not** hard-group all of an app's windows above all of another app's windows. Raising
one foreign window above the active app's window is possible; it just is not *sticky* — macOS's own
stacking will re-bury it on the next activation or click, which is why a loop is required.

### 3.3 Real limitations (documented, not hypothetical)

| Limitation | Source |
|---|---|
| One-shot only — "AXRaise brings a window to the front once, but the next click on any other window sends it behind again" | https://www.noticky.app/en/blog/always-on-top-apps-macos |
| Brief flash above the pinned window; ProToys re-asserts ~4×/second so a newly-opened window can appear over the pinned one for a fraction of a second | https://protoys.app/docs/tools/always-on-top.html |
| "a pinned window flashing behind for a frame as you click an overlapping one, because the window server is not enforcing anything — Aloft is putting it back" | https://github.com/iammayron/aloft |
| **AX couples raise with app activation**, so keyboard focus is briefly stolen and handed back ("border/keyboard-focus wobble") | https://github.com/KiwiCanopy/KiwiDesk/issues/424 |
| "Raising via AXRaise can steal focus in some apps, so re-activate the previously frontmost app right after" | https://github.com/turhe123/pin-window-on-top/blob/main/SPEC.md |
| Some windows can't be raised at all ("A few windows can't be raised. Some non-standard windows don't support being raised this way") | https://protoys.app/docs/tools/always-on-top.html |
| Doesn't work over another app's **full-screen Space** ("macOS doesn't allow arbitrary windows from one app to appear inside another app's full-screen view") | https://protoys.app/docs/tools/always-on-top.html |
| Electron apps: the AX element can go invalid (`kAXErrorInvalidUIElement`), after which `kAXRaise` silently no-ops | https://github.com/lwouis/alt-tab-macos/commit/eb4c08c |

### 3.4 The other public knobs

- `AXUIElementSetAttributeValue(app, kAXMainWindowAttribute, window)` and
  `kAXFocusedWindowAttribute` — settable app-level attributes; per-app only, do not change z-order
  across applications. Widely used in combination with the raise:
  https://github.com/vorssaint/vorssaint-utils/blob/main/Sources/Vorssaint/Services/Switcher/WindowActivator.swift
  and https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/SessionWindowFocuser.swift
- `AXUIElementSetAttributeValue(window, kAXMainAttribute / kAXFocusedAttribute, true)` — window-level;
  again no cross-app ordering guarantee.
- `NSRunningApplication.activate(options:)` — activates the **app**, raises *all* its windows; steals
  focus and, with `.activateAllWindows`, cannot target one window. Cited as the wrong tool twice:
  https://stackoverflow.com/questions/36075213/… ("it brings all windows owned by the process id … to
  the top") and https://github.com/takeiteasy/AppleLisp/issues/3 ("`raise(pid)` is implemented
  identically to `focus(pid)` — there is no actual window-level raise").
- AppleScript `set index of window X to 1` — scriptable apps only; "doesn't actually raise the
  window, but it makes it appear as window 1 to System Events, which can AXRaise it":
  https://superuser.com/questions/586806/… . Also "non-scriptable applications do not have a set
  index verb/property": https://apple.stackexchange.com/questions/233687/…
- **`Shortcuts automation delegation`** — the only route available to a *sandboxed* app; Shortcuts
  ships Find Windows / Move Window / Resize Window but **no raise/level action**, so it cannot
  implement always-on-top: https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox
- No new official always-on-top API through macOS 26: "the WindowServer still lacks a first-party
  overlay API. There's no built-in always on top mac tool or checkbox":
  https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e
  (secondary source; corroborated by every primary source above).

### 3.5 macOS 15/26 additions relevant to *overlays* (not to foreign windows)

These help the **mirror** path, not the native path, and are worth knowing either way (Apple DTS
recipe, May 2026):

- `NSWindow.CollectionBehavior.canJoinAllApplications` (macOS 13+): "Use this collection behavior for
  floating windows and system overlays." —
  https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications
- DTS: "`.screenSaver` (level 1000) is required, since `.floating` (3) and `.statusBar` (25) both sit
  below full-screen content." Panel recipe: `NSPanel(styleMask: [.nonactivatingPanel, …])`,
  `hidesOnDeanimate = false`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
  .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`, `orderFrontRegardless()` —
  https://developer.apple.com/forums/thread/826308
- Curated summary with links: https://github.com/Zelray/big-arrow-on-the-mac/blob/main/docs/research/2026-10-08-macos-overlay-apis-and-prior-art.md
- Deprecation watch-out: none of these are deprecated as of macOS 26, but macOS 26.3 RC regressed
  `ignoresMouseEvents` behaviour (FB21879511, fixed in 26.3 public) — same source as above.

---

## 4. What do real apps do?

### 4.1 ProToys — the app you are comparing against

ProToys has a dedicated docs page, and it **explicitly says macOS has no official mechanism** and
offers two modes:

> "macOS doesn't have an official way to keep another app's window on top, so ProToys offers two
> approaches."
> - **Mirror mode (default)** — "shows a live copy of the pinned window that floats above everything,
>   including over other apps in full-screen." Needs **Screen Recording**.
> - **Raise mode** — "ProToys keeps the real window on top within its own desktop Space. You're
>   clicking the actual window, so mouse, scroll, and keyboard feel completely normal." Needs only
>   **Accessibility**.
>   Trade-off: "Other windows may flash above briefly. **ProToys re-asserts top position about four
>   times a second**, so a newly-opened window can appear over the pinned one for a fraction of a
>   second before snapping back."
> - **Accessibility** "needed in both modes so ProToys can find your windows and move or raise them."
>
> — https://protoys.app/docs/tools/always-on-top.html

**Conclusion: ProToys has no secret private API.** Its non-mirror mode is a ~4 Hz Accessibility
re-raise loop. Your fork can match the commercial state of the art with public APIs alone.

### 4.2 Open-source keep-on-top apps (all AX re-raise)

| Project | Technique | SIP off? | Permissions |
|---|---|---|---|
| **turhe123/pin-window-on-top** (2026, Swift/SwiftUI, macOS 14+) | AX keep-on-top loop; "Track pinned windows by AX element and CGWindowID … Install an AXObserver per pinned app for focus changed and moved notifications, and also use NSWorkspace activation notifications. Whenever another app's window becomes active or a space changes, perform AXRaise on each pinned window **without activating its app, preserving focus** … rate limited to once every 150 milliseconds." Has a "Gentle mode" that raises only on activation change. Explicit limitation: "macOS does not let one app change the window level of another app's windows." **No Screen Recording requested.** | No | Accessibility only |
| **iammayron/aloft** (2026) | Re-raise on app switch + every 150 ms; Screen Recording used *only* for the picker's live previews | No | Accessibility + Screen Recording (picker only) |
| **itsabhishekolkha/AlwaysOnTop** (2025, 218★) | Accessibility timer every 0.5 s + AppleScript app activation throttled to 1/s | No | Accessibility |
| **iconoclas/Mac-Window-Pin** | "keep any window visually on top without stealing focus" | No | Accessibility |
| **justwy/PinWindow** | **Mirror**: "There's no public macOS API to change another app's window level. PinWindow works around this by creating a **live pixel-perfect mirror** … using ScreenCaptureKit" | No | Accessibility + Screen Recording |
| **southflowpeak/Pin** | **Mirror**: "Pin uses macOS's ScreenCaptureKit API … `SCStream` captures the target window's content in real-time" | No | Accessibility + Screen Recording |
| **lihaoyun6/Topit** (upstream of this fork) | Mirror | No | Accessibility + Screen Recording |
| **willweimike/Topit** (another fork) | Mirror; notes "macOS 14.0 and Later (**15.0 and Later is not valid due to API difference**)" — relevant version fragility for the mirror path | No | — |

Sources: https://github.com/turhe123/pin-window-on-top/blob/main/SPEC.md ·
https://github.com/turhe123/pin-window-on-top · https://github.com/iammayron/aloft ·
https://github.com/itsabhishekolkha/AlwaysOnTop · https://github.com/justwy/PinWindow ·
https://github.com/southflowpeak/Pin · https://github.com/iconoclas/Mac-Window-Pin ·
https://github.com/lihaoyun6/Topit · https://github.com/willweimike/Topit

**turhe123/pin-window-on-top is the closest thing to a reference implementation for what you want** —
read its `SPEC.md` §4 "Technical approach" and §5 "Edge cases" before writing code.

### 4.3 Injection-era and SIP-dependent tools

| Tool | Technique | SIP required |
|---|---|---|
| **yabai** (`--sticky`, sub-layer always-on-top) | Mach-injects a scripting addition into `Dock.app`; from inside, calls `SLSSetWindowSubLevel(SLSMainConnectionID(), wid, CGWindowLevelForKey(layer))` | **Yes — partial** (`csrutil enable --without fs --without debug --without nvram`); also needs root for `yabai --load-sa` |
| **Afloat** (classic) | SIMBL bundle injection into running apps; "The SIMBL approach is inherently fragile … With macOS 15 Sequoia's hardened runtime restrictions and SIP, Afloat may not function at all on modern Macs" | Effectively dead on modern macOS |
| **AfloatX** | Modern rewrite; still injection-based lineage | Reported working but fragile |
| **Stay** (Cordless Dog) | Restores saved window position/size via Accessibility — it does **not** implement always-on-top | No |
| **Helium** (floating browser) | Only floats *its own* window (sets its own `NSWindow.level`) — not applicable to foreign windows | No |
| **Rectangle Pro** / **BetterTouchTool** / **Floaty** pins | Closed-source; product pages describe "Always On Top Mode"/"Pin Window" behaviour consistent with either AX raise or mirror. Rectangle Pro's pinning is explicitly a per-window mode tied to its snapping | Not documented; **no evidence any of them use level writes** |

Sources: https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection ·
https://github.com/asmvik/yabai/issues/1863 · https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc ·
https://github.com/rxhanson/RectanglePro-Community/discussions/855 ·
https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e ·
https://apple.stackexchange.com/questions/219116/…

### 4.4 Useful adjacent prior art

- **Cua / `cua-driver`** — SkyLight reverse-engineering write-up: documents that `SLPSPostEventRecordTo`
  can flip a window's AppKit-active state **without raising it**, and reproduces yabai's
  `window_manager_focus_window_without_raise` pattern. Useful if you want to raise without stealing
  focus. https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md ·
  https://github.com/trycua/cua/blob/d1d2a7f37a8bb3a6a5686592a96487023d1f7ddc/libs/cua-driver/rust/crates/platform-macos/src/tools/bring_to_front.rs
- **BetterCmdTab** — public AX raise + a private `_SLPS…`-based `PrivateAPI.raiseWindow(pid:wid:)`
  for cross-Space correction: https://github.com/rokartur/BetterCmdTab/blob/main/BetterCmdTab/System/PrivateApis.swift
- **SkyLightWindow** (Lakr233) — shows what *own-connection* SkyLight level raising can do (your own
  windows above everything incl. full-screen, even the lock screen). Confirms the own-connection
  limitation is real. https://github.com/Lakr233/SkyLightWindow
- Community statement of the invariant: "The only way to keep a window on top of anything is if you
  as the app own that window, you can't make other app's window always-on-top. Hence why every app
  will use the same trick." — https://www.reddit.com/r/macapps/comments/1hu2rh3/make_a_window_float_on_top

### 4.5 The sandbox problem

Your brief said "sandboxed-but-Accessibility-permitted app". **That combination does not exist.**
App Sandbox blocks cross-process Accessibility outright:

- Apple Developer Forums thread: "write API (`AXUIElementSetAttributeValue`) does not function
  correctly within the App Sandbox, even when the user has granted Accessibility permission."
  — https://developer.apple.com/forums/thread/836644
- StackOverflow (2025-05): "To work with `AXUIElement`, you need to remove Sandbox. In sandbox, even
  though `AXIsProcessTrustedWithOptions` returns success, any calls to the API will return nil."
  — https://stackoverflow.com/questions/79606344/accessibility-api-axfocuseduielement-always-returns-nil
- Practitioner write-up quoting Apple DTS verbatim: "It's not possible to use the Accessibility APIs
  from a sandboxed app… your only path forward here is to directly distribute your app."
  — https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox

`CGWindowListCopyWindowInfo` **is** sandbox-legal, which is why you can always *enumerate*; only
*control* is forbidden. Topit must ship unsandboxed via Developer ID.

---

## 5. macOS version considerations (13 → 26/27)

| Version | Relevance |
|---|---|
| **macOS 13 Ventura** | Introduced `NSWindow.CollectionBehavior.canJoinAllApplications` (overlay authors' tool, not always-on-top). https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications |
| **macOS 14 Sonoma** | Private-API window manipulation already ownership-locked (SO #79135637, Oct 2024). AX raise unaffected. |
| **macOS 15 Sequoia** | Hardened runtime further breaks SIMBL/Afloat lineage. A Topit fork reports "15.0 and Later is not valid due to API difference" for the ScreenCaptureKit path — https://github.com/willweimike/Topit . **Test your SC mirror path specifically on 15+.** |
| **macOS 26 Tahoe** | No first-party always-on-top API (multiple 2026 round-ups agree). Notable gotcha for *enumeration*: "without Screen Recording, `kCGWindowOwnerName` for other apps' windows is nil" (Apple forums, Jul 2026) — https://developer.apple.com/forums/thread/839069 · curated at https://github.com/Zelray/big-arrow-on-the-mac/blob/main/docs/research/2026-10-08-macos-overlay-apis-and-prior-art.md |
| **macOS 26.3** | `ignoresMouseEvents` regression on transparent windows (FB21879511), fixed in 26.3 public; one unconfirmed report of recurrence in 26.4 beta. Relevant only to the mirror/overlay path. Same source. |
| **macOS 27** | KiwiDesk probe (27.0, SIP on) re-confirmed `SLSSetWindowLevel` still ownership-bound and no per-window `SLSBridged*` level/order op exists — https://github.com/KiwiCanopy/KiwiDesk/issues/424 . yabai's Dock injection needs new offsets/slices again (Dock is now fat with `arm64e` + `arm64e.x1`; `pacibsp`→`pacibsppc`) — https://github.com/asmvik/yabai/issues/2832 . This is a further argument against any Dock-injection design. |

**Deprecations:** none found that affect `kAXRaiseAction` or the AX attributes used. `CGShieldingWindowLevel()`
is discouraged by Apple ("this technique is not recommended") but not deprecated.

---

## 6. Recommendation for the Topit fork

**We did establish the truth first, and the truth is: do NOT ship SkyLight private APIs.** They are
not merely SIP-dependent — they are *ownership*-dependent, which is a harder wall, and the only
documented bypass (universal owner) needs a private entitlement that AMFI refuses.

What to implement:

1. **Ship a "Raise mode" alongside the existing Mirror mode**, mirroring ProToys' own product
   structure — this is the market-validated shape and users understand the trade-off immediately.
   Default it to Raise for interactivity; keep Mirror for "above another app's full-screen Space",
   which AX raise genuinely cannot do (and which even ProToys concedes).
2. **Implement the loop exactly as the successful OSS implementations do** (see
   turhe123/pin-window-on-top `SPEC.md` §4–5):
   - Resolve the target window once, keep both the `AXUIElement` and the `CGWindowID`, matched via
     `CGWindowListCopyWindowInfo` by owner PID + bounds + title (title alone is ambiguous).
   - `AXObserver` per pinned app for `kAXFocusedWindowChanged` / `kAXWindowMoved` /
     `kAXUIElementDestroyed`, **plus** `NSWorkspace` activation notifications, **plus** a
     ~150 ms timer as backstop (ProToys ≈ 4 Hz; aloft 150 ms; both are fine).
   - Raise with `AXUIElementPerformAction(window, kAXRaiseAction)`, then **immediately restore the
     previously frontmost application** to undo the AX raise↔activation coupling.
   - Offer a **"Gentle mode"** that raises only on activation change — much better battery/focus
     behaviour for users who tolerate the flash.
   - Pause pins when minimized, on another Space, or when a non-pinned app is in full-screen.
   - Drop the pin when the AX element becomes invalid or the app quits.
3. **Drop Screen Recording as a hard requirement.** With Raise mode you need only Accessibility. That
   alone removes the biggest privacy-prompt friction of the current design (and dodges the macOS 265{for the grep-ish `\u0000`...
Let me finish: - top-only of the output got truncated due to the timeout earlier — but I did get the key facts: two dirs (differ by one char: `github/tobiashochguertel` vs `github/tobiashochguertel`), the real git repo = "guertel" with `.git`, and pre-existing `docs/research/ax-native-pin-techniques.md` (71220 bytes) written at 19:30; my own earlier write landed in the wrong (no-.git) dir `.../github/tobiashochgurtel/topit/docs/research/` (only my file), created 19:27. Also there are pre-existing modified Swift files (`Topit/Supports/Accessibility.swift`, `Topit/TopitApp.swift`, `Topit/ViewModel/SettingsView.swift`) and untracked `Topit/Supports/NativePinManager.swift`, `PinActions.swift`, `PinRegistry.swift` + `docs/research/ax-native-pin-techniques.md` — these are NOT mine (my session cwd was the misspelled non-git dir, and I never issued any write except my report). 

So I should now: write my report (same content as before) to the correct absolute path with 'ue' spelling: `/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit/docs/research/native-always-on-top.md` — the user explicitly gave this EXACT path (with 'ue'). My file name `native-always-on-top.md` does NOT collide with the existing `ax-native-pin-techniques.md`. Good.

Also should I clean up the stray file in the wrong dir? The user said "Do not touch any other file, do not commit." Removing the stray dir might be considered touching. However it's my own artifact. Safer: leave it, but tell the user about it so they can delete it. Actually to keep things clean I'd rather mention it and ask... but I think mentioning is enough; they said don't touch other files. I'll mention it clearly.

Let me now write the file with the exact absolute path from the user's message (with 'ue'). I must be careful to use the 'ue' spelling. Let me use a python check afterward to verify the file exists at the git repo top-level path.

I'll do the write with the user's exact string (copy from their message): `/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit/docs/research/native-always-on-top.md`. In their message they wrote "/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit/docs/research/..." with 'ue'? Their message: "/Users/tobiashochgurtel/work/dev/github/tobiashochguertel/topit/docs/research/native-always-on-top.md" — has 'ue'. Yes.

But careful — the user's earlier (first) message also used the same string, and my write used the string from MY rendering, which apparently was the 'gurtel' (no ue) variant — because my pwd was the no-ue one. Hmm, actually the private string I typed — I just copy it again. To be safe, I'll write and then verify with python that it landed in the repo that has .git and also check whether both variants exist; if I accidentally write the wrong one again, I'll detect it (I'll check .git presence of the parent) and then use python to move it.

Let me write now with the full content (same as before, unchanged).</think:6124c78e>Root cause found: two directories differ by one character (`gurtel` vs `guertel`). My session's cwd — and therefore my first write — landed in the non-git `.../github/tobiashochgurtel/topit` instead of the real repo `.../github/tobiashochguertel/topit`. The pre-existing `docs/research/ax-native-pin-techniques.md` is from your main session; my filename doesn't collide with it. Writing to the exact absolute path now:<tool_calls:6124c78e><tool_call:6124c78e>write<arg_key:6124c78e>content</arg_key:6124c78e><arg_value:6124c78e># Native (non-mirror) always-on-top for foreign windows on macOS

**Research date:** 2026-11-16
**Scope:** macOS 13 → macOS 26/27
**Purpose:** Establish ground truth for whether the Topit fork can replace its ScreenCaptureKit
mirror overlay with a *native* "raise the real foreign window and keep it on top" implementation.

> Verdict up front: **the fork's plan assumption is essentially correct — but for a subtly different
> reason than "SIP blocks it".** SIP does *not* block `SLSSetWindowLevel`; WindowServer
> **ownership** does. And the Accessibility re-raise loop is not a hack — it is what the commercial
> app **ProToys** itself ships as its documented "Raise mode". Details and sources below.

---

## Executive verdict

**Is there a native (non-mirror) always-on-top solution for foreign windows usable by an
unsandboxed, Accessibility-permitted app on stock macOS with SIP enabled?**

**Yes — but not a *level-based* one. There is exactly one production technique that works on stock
macOS with SIP on: an Accessibility keep-on-top ("re-raise") loop.** It is what every shipping
product on modern macOS uses, including the commercial app you are comparing against.

1. **You cannot set another process's window level.** `SLSSetWindowLevel` / `CGSWindowSetLevel` /
   `CGSOrderWindow` either return an error or *silently no-op* for windows not owned by the calling
   WindowServer connection. This is a **WindowServer ownership** policy, **not** SIP. Root does not
   help.
2. **The only escape hatch is the "universal owner" connection**, which is either (a) the Dock's own
   connection — requiring Mach injection into `Dock.app` via `task_for_pid`, **which SIP *does*
   block**, or (b) a private entitlement `com.apple.private.skylight.universal-owner`, which AMFI
   refuses to run. Both are off the table for a shipped app.
3. **Therefore the realistic answer is the AX re-raise loop** — `AXUIElementPerformAction(window,
   kAXRaiseAction)` re-asserted on activation changes plus a ~150 ms / ~4 Hz timer.

**Ranked options**

| # | Option | Works with SIP on? | Permissions | Interactivity | Trade-offs |
|---|--------|--------------------|-------------|---------------|------------|
| 1 | **AX re-raise loop** (`kAXRaiseAction` + activation/observer triggers + timer) | ✅ Yes | Accessibility only | ✅ Full native: click, scroll, keyboard all normal | Sub-frame flash when another window takes the top; AX raise couples with activation in some apps so focus can briefly flicker; no overlay above full-screen Spaces |
| 2 | **Keep ScreenCaptureKit mirror** (current Topit) | ✅ Yes | Accessibility + **Screen Recording** | ⚠️ Degraded — you click a copy | CPU/GPU cost per pinned window; hit-testing fragile; no real interaction |
| 3 | Hybrid: mirror for full-screen-Space scenarios, raise mode for everything else | ✅ Yes | Accessibility + Screen Recording (only if user picks mirror) | Best of both | More surface area to maintain |
| 4 | SkyLight universal-owner via private entitlement | ❌ Needs AMFI off | `com.apple.private.skylight.universal-owner` | ✅ Perfect | Will not launch on stock macOS |
| 5 | yabai-style scripting addition injected into `Dock.app` | ❌ Needs **partial SIP disable** + root | — | ✅ Perfect | Not shippable to general users; breaks every macOS release |

**Correction to the fork's plan note:** replace *"with SIP enabled there is no proper way to natively
raise a foreign window and keep it on top"* with *"with SIP enabled you cannot change a foreign
window's **level** (WindowServer ownership, not SIP); you can still **raise** it repeatedly via
Accessibility, which is what every shipping macOS app including ProToys does."*

**One caveat on your premise of a "sandboxed" app:** an App-Sandboxed app **cannot use cross-process
Accessibility at all** — see [§4.5](#45-the-sandbox-problem). Topit must ship unsandboxed (Developer
ID, outside the Mac App Store) for any of this to work.

---

## 1. SkyLight / CoreGraphics private APIs

### 1.1 Can `CGSWindowSetLevel` / `SLSSetWindowLevel` change another process's window level?

**No.** Multiple independent sources agree, and they agree on the *mechanism* (ownership), not SIP:

- **KiwiDesk issue #424** (2026-07, updated 2026-10) — an explicitly measured, SIP-on finding:
  > "`SLSSetWindowLevel(cid, wid, level)` only affects windows owned by the **connection that issues
  > it** (`cid`). Our process can level its *own* windows … but the floats this feature targets belong
  > to **foreign apps' connections**, which we cannot write."
  > — https://github.com/KiwiCanopy/KiwiDesk/issues/424

- **Aloft** (a 2026 menu-bar app whose entire purpose is "any window, always on top") states it in
  its README:
  > "macOS does not let one app change another app's window level. `SLSSetWindowLevel` reports
  > success from a foreign connection and is ignored, and `SLSSetUniversalOwner` is
  > entitlement-gated. Doing it properly needs code injected into a process the window server trusts,
  > which needs SIP disabled."
  > — https://github.com/iammayron/aloft

  Note the important nuance: **the call reports success (`CGError` 0) and is silently ignored.** Do
  not trust a `0` return value.

- **StackOverflow #3706167** (the canonical older answer):
  > "Why it doesn't work: Without being the Universal Owner, you can't change the order of a window
  > owned by another process."
  > — https://stackoverflow.com/questions/3706167/making-a-another-applicationss-window-frontmost-and-focused

- **StackOverflow #79135637** (2024-10, Sonoma), comment by a well-known macOS internals developer:
  > "much of the CGS APIs are locked down through an 'ownership' model. Apps only 'own' their own
  > windows and are only allowed to move those. The Dock process is a 'universal owner' and can
  > manipulate all the windows. … the Universal ownership is locked through a special entitlement,
  > and when you give your own app that entitlement macOS will just not run it. The only way that I
  > know of to manipulate windows is to use the Accessibility API."
  > — https://stackoverflow.com/questions/79135637/unable-to-move-windows-on-sonoma-using-private-apis-in-swift

- **StackOverflow #34738375** — empirical error codes for `CGSOrderWindow` on a foreign window:
   - with your own connection: `1000` ("cid does not have permission to modify target window")
   - with the *owner's* cid obtained from `CGSGetWindowOwner`: `268435459` (0x10000003, "current app
     does not have permission to use this ConnectionId")
   > — https://stackoverflow.com/questions/34738375/controlling-level-and-focus-of-windows-other-apps-with-cgprivate-functions

- Historical framing, quoted in #36075213 from `CGSConnection.h`:
  > "Only the owner of a window can manipulate it. So, Apple has the concept of a universal owner
  > that owns all windows and can manipulate them all. There can only be one universal owner at a
  > time (the Dock)."
  > — https://stackoverflow.com/questions/36075213/set-non-owned-window-always-on-top-like-the-app-afloat

### 1.2 Does SIP block these calls specifically?

**No — this is the most important correction.** SIP and WindowServer ownership are two *different*
gates:

| Mechanism | Enforced by | What it blocks |
|-----------|-------------|----------------|
| File-system protection (`/System`, `/usr`, `/bin`, `/sbin`, `/var`, pre-installed apps) | Kernel (SIP) | Writing protected paths even as root |
| Runtime protection — `task_for_pid()`, `processor_set_tasks()` return `EPERM`; no dyld injection; no DTrace on protected processes | Kernel (SIP) | Attaching to / injecting into **protected (Apple-signed, platform) processes** including `Dock.app` |
| Code injection into `Dock.app` (Mach/bootstrap) | SIP runtime protection | yabai's scripting addition |
| **Window level / order writes on foreign windows** | **WindowServer itself (ownership model)** | `SLSSetWindowLevel`, `CGSOrderWindow`, `SLSSetWindowSubLevel` from a foreign cid |
| Private entitlements (`com.apple.private.*`) | AMFI | App will not run unless AMFI is relaxed |

The authoritative statement on the yabai side is explicit about *which* gate applies to what:

> "To inject code into the Dock we use the mach APIs; in particular `task_for_pid`. … In addition to
> this the Dock process is also flagged as a universal owner; its connection to the WindowServer has
> elevated privileges and is authorized to modify window properties that can otherwise only be set
> by the application whom the window belongs to."
> — https://github.com/asmvik/yabai/issues/1863

So: **SIP blocks getting *into* the Dock. WindowServer blocks writing foreign windows *from outside*
the Dock.** Disabling SIP does not by itself make `SLSSetWindowLevel` work — you must additionally
be running *inside* the Dock's connection.

And conversely, the read-only SLS surface works fine with SIP on:

> "Private, undocumented functions from CoreGraphics framework … Work on fully secured systems (no
> SIP disablement required) … Used for querying state rather than privileged modifications"
> — DeepWiki, *SkyLight Services (SLS) Private APIs*, https://deepwiki.com/asmvik/yabai/8.2-skylight-services-(sls)-private-apis

### 1.3 The universal-owner escape hatch, and why we can't ship it

**yabai issue #2593** is the single most valuable document for this fork. In it, contributor
`AlexStrNik` says he started reverse-engineering SkyLight specifically to build a Topit-like app
that does not mirror:

> "I started digging into all of this because I wanted to build my own version of Topit—but instead
> of streaming window content to a proxy window, my approach directly changes the level of any
> window."
> — https://github.com/asmvik/yabai/issues/2593

His method (Swift, reproduced in the issue):

```swift
func gainUniversalOwner() {
    var connection: UInt32 = 0
    SLSNewConnection(0, &connection)
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")[0]
    kill(dock.processIdentifier, SIGKILL)
    SLSSetUniversalOwner(connection)
    SLSSetOtherUniversalConnection(connection, self.connectionId) // self.connectionId = SLSMainConnectionID()
    SLSReleaseConnection(connection)
}
```

Why it is not shippable (same source):

> "Unfortunately, this method does require a private entitlement
> (`com.apple.private.skylight.universal-owner`), which likely won't work unless AMFI is disabled."

yabai's author confirms the capability (so the *mechanism* is real) while declining to ship it:

> "I have actually done this in the past, and it works fine for getting the universal owner
> connection privileges. This will allow yabai to perform some of the operations that require code
> injection today; primarily the ones that manipulate windows and their properties."
> — koekeishiya, https://github.com/asmvik/yabai/issues/2593

**Conclusion:** it works only with a private entitlement + AMFI disabled; it requires SIGKILLing the
Dock momentarily; and it is an unsigned-private-API code path. **Do not ship this.**

### 1.4 Also-ruled-out: `SLSBridged*` "space level" trick

KiwiDesk measured this on **macOS 27.0 with SIP on** and rejected it (2026-09-27 comment in #424):

- Enumerated 100 `SLSBridged*` classes; **none sets a single window's level or z-order**. Only
  Space-level operations exist: `SpaceSetAbsoluteLevel`, `SpaceSetOrderingWeight`, `SpaceSetFrontPSN`.
- Creating a Space, moving another process's window into it (`MoveWindowsToManagedSpace` is "the one
  cross-app membership write that applies") and raising the Space level: "Visually the whole current
  Desktop disappeared … It is a Desktop switch in disguise, not a layer."
- Shaped variant (`SpaceSetShape`) looked like a layer at rest but "does not follow the window",
  clips at the old rectangle, redraws visibly while dragging, and clicking below brought that window
  in front.
> https://github.com/KiwiCanopy/KiwiDesk/issues/424

### 1.5 Header dumps / API signatures (for reference only — do not ship)

| Symbol set | Source |
|---|---|
| `CGSGetWindowLevel`, `CGSGetWindowOwner`, `CGSConnectionGetPID`, `CGSSetWindowLevel`, `CGSOrderWindow`, `_CGSDefaultConnection` | https://github.com/fjolnir/xnomad/blob/master/CGSPrivate.h |
| `CGSGetWindowLevel`, `CGSGetWindowOwner`, `CGSMainConnectionID` | https://github.com/NUIKit/CGSInternal/blob/master/CGSConnection.h |
| Swift `@_silgen_name` bindings for SkyLight/CGS (alt-tab) | https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/src/macos/api-wrappers/SkyLight.framework.swift |
| Swift bindings incl. `CGSGetWindowLevel` (DockDoor) | https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift |
| Rust `SLSSetWindowLevel`-adjacent bindings (rift) | https://github.com/acsandmann/rift/blob/e95944ea/src/sys/skylight.rs |
| `CGWindowLevel.h` (public level constants) | https://github.com/w0lfschild/cDock/blob/master/_resource/xcode/cDock-Bundle/CoreGraphics.framework/Versions/A/Headers/CGWindowLevel.h |
| Apple: `CGWindowLevelKey` — "Applications do not need to use them directly" | https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey |
| Apple: `CGWindowLevelForKey(_:)` — raw CG level keys "not recommended for use in applications" | https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:) |

### 1.6 Root privileges?

Running as root does not grant WindowServer ownership. The SO #34738375 author explicitly tried both
own-cid and owner-cid paths and notes attempts "running as root, disabling SIP" in SO #79135637 —
still failed. Ownership is keyed to the **connection**, not the uid.

---

## 2. Ground truth on SIP

### What SIP actually enforces (Apple documentation)

- **File system:** only `/System`, `/bin`, `/sbin`, `/usr` (minus `/usr/local`) and pre-installed
  Apple apps are protected; `/Applications`, `/Library`, `/usr/local`, `~/Library` remain writable.
  > https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/FileSystemProtections/FileSystemProtections.html
  > https://support.apple.com/en-us/102149
- **Runtime / process attachment:**
  > "Attempting to get the Mach task for a process using the `task_for_pid` function or attempting to
  > get the permissions of a set of tasks using the `processor_set_tasks` function fails, returning
  > `EPERM`. … Any dynamic linker (`dyld`) environment variables, such as `DYLD_LIBRARY_PATH`, are
  > purged when launching protected processes. … Attempting to attach to a system process, such as
  > with LLDB, fails—even when running as root with sudo."
  > https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html
- Overview: "protecting access to system locations and **restricting runtime attachment to system
  processes**" — https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/Introduction/Introduction.html

### What SIP explicitly does *not* do (relevant here)

- It does **not** gate Accessibility (`AXUIElement*`) on other processes. That is **TCC**
  (System Settings → Privacy & Security → Accessibility), plus **App Sandbox** (see §4.5).
- It does **not** gate read-only WindowServer queries (`SLSGetWindowLevel`, `CGWindowListCopyWindowInfo`,
  `SLSGetWindowOwner`).
- It does **not** gate writing *your own* windows' level.

### Precise mapping onto our question

| Thing we might want | Blocked by | Usable on stock macOS? |
|---|---|---|
| `SLSSetWindowLevel(cid, foreignWid, kCGFloatingWindowLevel)` | **WindowServer ownership** | ❌ No (silently ignored) |
| `CGSOrderWindow(cid, foreignWid, …)` | **WindowServer ownership** | ❌ No (err 1000 / 0x10000003) |
| `SLSSetUniversalOwner` | **AMFI** (private entitlement) | ❌ No |
| Mach-inject a payload into `Dock.app` then call SLS from inside | **SIP runtime protection** | ❌ No — needs `csrutil` |
| `AXUIElementPerformAction(foreignWindow, kAXRaiseAction)` | **TCC** only | ✅ Yes, once Accessibility granted |
| Read window list / levels / bounds | nothing (SIP-safe per yabai) | ✅ Yes |

yabai documents the exact SIP relaxation needed for the Dock-injection path:

```sh
# Apple Silicon, macOS 13+
csrutil enable --without fs --without debug --without nvram
```
> https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection

and lists which features require it — notably **"control window layers (make windows appear topmost
or on the desktop)"**, i.e. exactly always-on-top:
> https://github.com/asmvik/yabai/issues/1863 and https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc
> ("The following properties require System Integrity Protection to be partially disabled: sticky,
> sub-layer, opacity, scratchpad.")

yabai's author adds the honest caveat:
> "I am aware of solutions that try to re-create some of these features without touching SIP, but the
> reality is that there is no way to implement said features properly without functional limitations,
> when SIP is enabled."
> — https://github.com/asmvik/yabai/issues/1863

---

## 3. The public-API alternative: Accessibility keep-on-top loop

### 3.1 `AXUIElementPerformAction(window, kAXRaiseAction)`

Apple's own wording is the key legal-ish constraint:

> "Causes a window to become **as frontmost as is allowed by the containing application's
> circumstances**. Note that an application's floating windows (such as inspector windows) might
> remain above a window that performs the raise action."
> — https://developer.apple.com/documentation/applicationservices/kaxraiseaction

So: it raises within the constraints WindowServer allows, and floating/panel windows can still sit
above it.

### 3.2 Can a non-active app's window actually render above the active app's windows?

**Yes.** This is the crux of the whole question, and the evidence is behavioural, from shipping
products:

- **ProToys** ships this as a first-class documented mode (see §4.1): "Raise mode — ProToys keeps the
  real window on top within its own desktop Space. You're clicking the actual window…"
- **Aloft**: "a pin is a re-raise: Aloft watches the stacking order and lifts a pinned window back
  whenever something covers it, immediately on an app switch and every 150ms otherwise. **In practice
  it stays in front.**"
- **KiwiDesk #418** ships "the AX re-raise fallback (`kAXRaiseAction` on focus of a tiled window),
  which is good enough in practice."
- **alt-tab** internals separate the two operations explicitly: "`_SLPSSetFrontProcessWithOptions`
  sets the front process, while `makeKeyWindow` and `kAXRaiseAction` **only move the window in the
  z-order**." — https://github.com/lwouis/alt-tab-macos/commit/886f21a

So macOS does **not** hard-group all of an app's windows above all of another app's windows. Raising
one foreign window above the active app's window is possible; it just is not *sticky* — macOS's own
stacking will re-bury it on the next activation or click, which is why a loop is required.

### 3.3 Real limitations (documented, not hypothetical)

| Limitation | Source |
|---|---|
| One-shot only — "AXRaise brings a window to the front once, but the next click on any other window sends it behind again" | https://www.noticky.app/en/blog/always-on-top-apps-macos |
| Brief flash above the pinned window; ProToys re-asserts ~4×/second so a newly-opened window can appear over the pinned one for a fraction of a second | https://protoys.app/docs/tools/always-on-top.html |
| "a pinned window flashing behind for a frame as you click an overlapping one, because the window server is not enforcing anything — Aloft is putting it back" | https://github.com/iammayron/aloft |
| **AX couples raise with app activation**, so keyboard focus is briefly stolen and handed back ("border/keyboard-focus wobble") | https://github.com/KiwiCanopy/KiwiDesk/issues/424 |
| "Raising via AXRaise can steal focus in some apps, so re-activate the previously frontmost app right after" | https://github.com/turhe123/pin-window-on-top/blob/main/SPEC.md |
| Some windows can't be raised at all ("A few windows can't be raised. Some non-standard windows don't support being raised this way") | https://protoys.app/docs/tools/always-on-top.html |
| Doesn't work over another app's **full-screen Space** ("macOS doesn't allow arbitrary windows from one app to appear inside another app's full-screen view") | https://protoys.app/docs/tools/always-on-top.html |
| Electron apps: the AX element can go invalid (`kAXErrorInvalidUIElement`), after which `kAXRaise` silently no-ops | https://github.com/lwouis/alt-tab-macos/commit/eb4c08c |

### 3.4 The other public knobs

- `AXUIElementSetAttributeValue(app, kAXMainWindowAttribute, window)` and
  `kAXFocusedWindowAttribute` — settable app-level attributes; per-app only, do not change z-order
  across applications. Widely used in combination with the raise:
  https://github.com/vorssaint/vorssaint-utils/blob/main/Sources/Vorssaint/Services/Switcher/WindowActivator.swift
  and https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/SessionWindowFocuser.swift
- `AXUIElementSetAttributeValue(window, kAXMainAttribute / kAXFocusedAttribute, true)` — window-level;
  again no cross-app ordering guarantee.
- `NSRunningApplication.activate(options:)` — activates the **app**, raises *all* its windows; steals
  focus and, with `.activateAllWindows`, cannot target one window. Cited as the wrong tool twice:
  https://stackoverflow.com/questions/36075213/… ("it brings all windows owned by the process id … to
  the top") and https://github.com/takeiteasy/AppleLisp/issues/3 ("`raise(pid)` is implemented
  identically to `focus(pid)` — there is no actual window-level raise").
- AppleScript `set index of window X to 1` — scriptable apps only; "doesn't actually raise the
  window, but it makes it appear as window 1 to System Events, which can AXRaise it":
  https://superuser.com/questions/586806/… . Also "non-scriptable applications do not have a set
  index verb/property": https://apple.stackexchange.com/questions/233687/…
- **`Shortcuts automation delegation`** — the only route available to a *sandboxed* app; Shortcuts
  ships Find Windows / Move Window / Resize Window but **no raise/level action**, so it cannot
  implement always-on-top: https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox
- No new official always-on-top API through macOS 26: "the WindowServer still lacks a first-party
  overlay API. There's no built-in always on top mac tool or checkbox":
  https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e
  (secondary source; corroborated by every primary source above).

### 3.5 macOS 15/26 additions relevant to *overlays* (not to foreign windows)

These help the **mirror** path, not the native path, and are worth knowing either way (Apple DTS
recipe, May 2026):

- `NSWindow.CollectionBehavior.canJoinAllApplications` (macOS 13+): "Use this collection behavior for
  floating windows and system overlays." —
  https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications
- DTS: "`.screenSaver` (level 1000) is required, since `.floating` (3) and `.statusBar` (25) both sit
  below full-screen content." Panel recipe: `NSPanel(styleMask: [.nonactivatingPanel, …])`,
  `hidesOnDeactivate = false`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
  .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`, `orderFrontRegardless()` —
  https://developer.apple.com/forums/thread/826308
- Curated summary with links: https://github.com/Zelray/big-arrow-on-the-mac/blob/main/docs/research/2026-10-08-macos-overlay-apis-and-prior-art.md
- Deprecation watch-out: none of these are deprecated as of macOS 26, but macOS 26.3 RC regressed
  `ignoresMouseEvents` behaviour (FB21879511, fixed in 26.3 public) — same source as above.

---

## 4. What do real apps do?

### 4.1 ProToys — the app you are comparing against

ProToys has a dedicated docs page, and it **explicitly says macOS has no official mechanism** and
offers two modes:

> "macOS doesn't have an official way to keep another app's window on top, so ProToys offers two
> approaches."
> - **Mirror mode (default)** — "shows a live copy of the pinned window that floats above everything,
>   including over other apps in full-screen." Needs **Screen Recording**.
> - **Raise mode** — "ProToys keeps the real window on top within its own desktop Space. You're
>   clicking the actual window, so mouse, scroll, and keyboard feel completely normal." Needs only
>   **Accessibility**.
>   Trade-off: "Other windows may flash above briefly. **ProToys re-asserts top position about four
>   times a second**, so a newly-opened window can appear over the pinned one for a fraction of a
>   second before snapping back."
> - **Accessibility** "needed in both modes so ProToys can find your windows and move or raise them."
>
> — https://protoys.app/docs/tools/always-on-top.html

**Conclusion: ProToys has no secret private API.** Its non-mirror mode is a ~4 Hz Accessibility
re-raise loop. Your fork can match the commercial state of the art with public APIs alone.

### 4.2 Open-source keep-on-top apps (all AX re-raise)

| Project | Technique | SIP off? | Permissions |
|---|---|---|---|
| **turhe123/pin-window-on-top** (2026, Swift/SwiftUI, macOS 14+) | AX keep-on-top loop; "Track pinned windows by AX element and CGWindowID … Install an AXObserver per pinned app for focus changed and moved notifications, and also use NSWorkspace activation notifications. Whenever another app's window becomes active or a space changes, perform AXRaise on each pinned window **without activating its app, preserving focus** … rate limited to once every 150 milliseconds." Has a "Gentle mode" that raises only on activation change. Explicit limitation: "macOS does not let one app change the window level of another app's windows." **No Screen Recording requested.** | No | Accessibility only |
| **iammayron/aloft** (2026) | Re-raise on app switch + every 150 ms; Screen Recording used *only* for the picker's live previews | No | Accessibility + Screen Recording (picker only) |
| **itsabhishekolkha/AlwaysOnTop** (2025, 218★) | Accessibility timer every 0.5 s + AppleScript app activation throttled to 1/s | No | Accessibility |
| **iconoclas/Mac-Window-Pin** | "keep any window visually on top without stealing focus" | No | Accessibility |
| **justwy/PinWindow** | **Mirror**: "There's no public macOS API to change another app's window level. PinWindow works around this by creating a **live pixel-perfect mirror** … using ScreenCaptureKit" | No | Accessibility + Screen Recording |
| **southflowpeak/Pin** | **Mirror**: "Pin uses macOS's ScreenCaptureKit API … `SCStream` captures the target window's content in real-time" | No | Accessibility + Screen Recording |
| **lihaoyun6/Topit** (upstream of this fork) | Mirror | No | Accessibility + Screen Recording |
| **willweimike/Topit** (another fork) | Mirror; notes "macOS 14.0 and Later (**15.0 and Later is not valid due to API difference**)" — relevant version fragility for the mirror path | No | — |

Sources: https://github.com/turhe123/pin-window-on-top/blob/main/SPEC.md ·
https://github.com/turhe123/pin-window-on-top · https://github.com/iammayron/aloft ·
https://github.com/itsabhishekolkha/AlwaysOnTop · https://github.com/justwy/PinWindow ·
https://github.com/southflowpeak/Pin · https://github.com/iconoclas/Mac-Window-Pin ·
https://github.com/lihaoyun6/Topit · https://github.com/willweimike/Topit

**turhe123/pin-window-on-top is the closest thing to a reference implementation for what you want** —
read its `SPEC.md` §4 "Technical approach" and §5 "Edge cases" before writing code.

### 4.3 Injection-era and SIP-dependent tools

| Tool | Technique | SIP required |
|---|---|---|
| **yabai** (`--sticky`, sub-layer always-on-top) | Mach-injects a scripting addition into `Dock.app`; from inside, calls `SLSSetWindowSubLevel(SLSMainConnectionID(), wid, CGWindowLevelForKey(layer))` | **Yes — partial** (`csrutil enable --without fs --without debug --without nvram`); also needs root for `yabai --load-sa` |
| **Afloat** (classic) | SIMBL bundle injection into running apps; "The SIMBL approach is inherently fragile … With macOS 15 Sequoia's hardened runtime restrictions and SIP, Afloat may not function at all on modern Macs" | Effectively dead on modern macOS |
| **AfloatX** | Modern rewrite; still injection-based lineage | Reported working but fragile |
| **Stay** (Cordless Dog) | Restores saved window position/size via Accessibility — it does **not** implement always-on-top | No |
| **Helium** (floating browser) | Only floats *its own* window (sets its own `NSWindow.level`) — not applicable to foreign windows | No |
| **Rectangle Pro** / **BetterTouchTool** / **Floaty** pins | Closed-source; product pages describe "Always On Top Mode"/"Pin Window" behaviour consistent with either AX raise or mirror. Rectangle Pro's pinning is explicitly a per-window mode tied to its snapping | Not documented; **no evidence any of them use level writes** |

Sources: https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection ·
https://github.com/asmvik/yabai/issues/1863 · https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc ·
https://github.com/rxhanson/RectanglePro-Community/discussions/855 ·
https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e ·
https://apple.stackexchange.com/questions/219116/…

### 4.4 Useful adjacent prior art

- **Cua / `cua-driver`** — SkyLight reverse-engineering write-up: documents that `SLPSPostEventRecordTo`
  can flip a window's AppKit-active state **without raising it**, and reproduces yabai's
  `window_manager_focus_window_without_raise` pattern. Useful if you want to raise without stealing
  focus. https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md ·
  https://github.com/trycua/cua/blob/d1d2a7f37a8bb3a6a5686592a96487023d1f7ddc/libs/cua-driver/rust/crates/platform-macos/src/tools/bring_to_front.rs
- **BetterCmdTab** — public AX raise + a private `_SLPS…`-based `PrivateAPI.raiseWindow(pid:wid:)`
  for cross-Space correction: https://github.com/rokartur/BetterCmdTab/blob/main/BetterCmdTab/System/PrivateApis.swift
- **SkyLightWindow** (Lakr233) — shows what *own-connection* SkyLight level raising can do (your own
  windows above everything incl. full-screen, even the lock screen). Confirms the own-connection
  limitation is real. https://github.com/Lakr233/SkyLightWindow
- Community statement of the invariant: "The only way to keep a window on top of anything is if you
  as the app own that window, you can't make other app's window always-on-top. Hence why every app
  will use the same trick." — https://www.reddit.com/r/macapps/comments/1hu2rh3/make_a_window_float_on_top

### 4.5 The sandbox problem

Your brief said "sandboxed-but-Accessibility-permitted app". **That combination does not exist.**
App Sandbox blocks cross-process Accessibility outright:

- Apple Developer Forums thread: "write API (`AXUIElementSetAttributeValue`) does not function
  correctly within the App Sandbox, even when the user has granted Accessibility permission."
  — https://developer.apple.com/forums/thread/836644
- StackOverflow (2025-05): "To work with `AXUIElement`, you need to remove Sandbox. In sandbox, even
  though `AXIsProcessTrustedWithOptions` returns success, any calls to the API will return nil."
  — https://stackoverflow.com/questions/79606344/accessibility-api-axfocuseduielement-always-returns-nil
- Practitioner write-up quoting Apple DTS verbatim: "It's not possible to use the Accessibility APIs
  from a sandboxed app… your only path forward here is to directly distribute your app."
  — https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox

`CGWindowListCopyWindowInfo` **is** sandbox-legal, which is why you can always *enumerate*; only
*control* is forbidden. Topit must ship unsandboxed via Developer ID.

---

## 5. macOS version considerations (13 → 26/27)

| Version | Relevance |
|---|---|
| **macOS 13 Ventura** | Introduced `NSWindow.CollectionBehavior.canJoinAllApplications` (overlay authors' tool, not always-on-top). https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications |
| **macOS 14 Sonoma** | Private-API window manipulation already ownership-locked (SO #79135637, Oct 2024). AX raise unaffected. |
| **macOS 15 Sequoia** | Hardened runtime further breaks SIMBL/Afloat lineage. A Topit fork reports "15.0 and Later is not valid due to API difference" for the ScreenCaptureKit path — https://github.com/willweimike/Topit . **Test your SC mirror path specifically on 15+.** |
| **macOS 26 Tahoe** | No first-party always-on-top API (multiple 2026 round-ups agree). Notable gotcha for *enumeration*: "without Screen Recording, `kCGWindowOwnerName` for other apps' windows is nil" (Apple forums, Jul 2026) — https://developer.apple.com/forums/thread/839069 · curated at https://github.com/Zelray/big-arrow-on-the-mac/blob/main/docs/research/2026-10-08-macos-overlay-apis-and-prior-art.md |
| **macOS 26.3** | `ignoresMouseEvents` regression on transparent windows (FB21879511), fixed in 26.3 public; one unconfirmed report of recurrence in 26.4 beta. Relevant only to the mirror/overlay path. Same source. |
| **macOS 27** | KiwiDesk probe (27.0, SIP on) re-confirmed `SLSSetWindowLevel` still ownership-bound and no per-window `SLSBridged*` level/order op exists — https://github.com/KiwiCanopy/KiwiDesk/issues/424 . yabai's Dock injection needs new offsets/slices again (Dock is now fat with `arm64e` + `arm64e.x1`; `pacibsp`→`pacibsppc`) — https://github.com/asmvik/yabai/issues/2832 . This is a further argument against any Dock-injection design. |

**Deprecations:** none found that affect `kAXRaiseAction` or the AX attributes used. `CGShieldingWindowLevel()`
is discouraged by Apple ("this technique is not recommended") but not deprecated.

---

## 6. Recommendation for the Topit fork

**We did establish the truth first, and the truth is: do NOT ship SkyLight private APIs.** They are
not merely SIP-dependent — they are *ownership*-dependent, which is a harder wall, and the only
documented bypass (universal owner) needs a private entitlement that AMFI refuses.

What to implement:

1. **Ship a "Raise mode" alongside the existing Mirror mode**, mirroring ProToys' own product
   structure — this is the market-validated shape and users understand the trade-off immediately.
   Default it to Raise for interactivity; keep Mirror for "above another app's full-screen Space",
   which AX raise genuinely cannot do (and which even ProToys concedes).
2. **Implement the loop exactly as the successful OSS implementations do** (see
   turhe123/pin-window-on-top `SPEC.md` §4–5):
   - Resolve the target window once, keep both the `AXUIElement` and the `CGWindowID`, matched via
     `CGWindowListCopyWindowInfo` by owner PID + bounds + title (title alone is ambiguous).
   - `AXObserver` per pinned app for `kAXFocusedWindowChanged` / `kAXWindowMoved` /
     `kAXUIElementDestroyed`, **plus** `NSWorkspace` activation notifications, **plus** a
     ~150 ms timer as backstop (ProToys ≈ 4 Hz; aloft 150 ms; both are fine).
   - Raise with `AXUIElementPerformAction(window, kAXRaiseAction)`, then **immediately restore the
     previously frontmost application** to undo the AX raise↔activation coupling.
   - Offer a **"Gentle mode"** that raises only on activation change — much better battery/focus
     behaviour for users who tolerate the flash.
   - Pause pins when minimized, on another Space, or when a non-pinned app is in full-screen.
   - Drop the pin when the AX element becomes invalid or the app quits.
3. **Drop Screen Recording as a hard requirement.** With Raise mode you need only Accessibility. That
   alone removes the biggest privacy-prompt friction of the current design (and dodges the macOS 26
   `kCGWindowOwnerName` = nil behaviour; use `NSWorkspace.runningApplications` matched against
   `kCGWindowOwnerPID` instead).
4. **Ship unsandboxed Developer ID.** Sandbox + Accessibility is impossible (§4.5). If you ever want
   MAS presence, the only known route is Shortcuts delegation, and Shortcuts has no raise/level
   action — so always-on-top is simply not achievable there.
5. **Do not** include `SLSSetWindowLevel` "for when it works". Per KiwiDesk and aloft it can return 0
   and do nothing, so you would ship a code path that silently appears to work. If you keep any
   SkyLight usage, restrict it to **read-only** queries (`SLSGetWindowLevel`, `SLSGetWindowOwner`),
   which are SIP-safe and useful for occlusion detection.
6. **Set expectations in the UI/docs**: a one-frame flash on app switch, occasional windows that
   cannot be raised (fall back to Mirror), and no coverage over another app's full-screen Space.
   These are the same limitations the $paid competitors state publicly.

---

## 7. Sources

Every non-obvious claim above maps to one of these. Primary/authoritative sources are marked ★.

| # | Claim | Source |
|---|---|---|
| 1 | ★ Apple: SIP protects `/System`, `/usr`, `/bin`, `/sbin`, `/var`, preinstalled apps; root restricted | https://support.apple.com/en-us/102149 |
| 2 | ★ Apple: SIP file-system protections detail | https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/FileSystemProtections/FileSystemProtections.html |
| 3 | ★ Apple: SIP runtime protections — `task_for_pid` → `EPERM`, no dyld injection, no LLDB attach even as root | https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html |
| 4 | ★ Apple: SIP overview — "restricting runtime attachment to systemᆵsystem processes" | https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/Introduction/Introduction.html |
| 5 | ★ Apple: `kAXRaiseAction` — "as frontmost as is allowed by the containing application's circumstances"; floating windows may remain above | https://developer.apple.com/documentation/applicationservices/kaxraiseaction |
| 6 | ★ Apple: `CGWindowLevelKey` — apps needn't use directly | https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey |
| 7 | ★ Apple: raw CG level keys "not recommended for use in applications" | https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:) |
| 8 | ★ Apple: `canJoinAllApplications` (macOS 13+) for floating windows/system overlays | https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications |
| 9 | ★ Apple DTS (May 2026) overlay recipe; `.screenSaver` level required above full-screen | https://developer.apple.com/forums/thread/826308 |
| 10 | ★ Apple forums: AX write API broken under App Sandbox even with permission granted | https://developer.apple.com/forums/thread/836644 |
| 11 | ★ Apple forums (Jul 2026): without Screen Recording, `kCGWindowOwnerName` nil for other apps' windows | https://developer.apple.com/forums/thread/839069 |
| 12 | `SLSSetWindowLevel` only affects windows owned by the issuing connection (measured, SIP on, macOS 27) | https://github.com/KiwiCanopy/KiwiDesk/issues/424 |
| 13 | No per-window level/order op among 100 `SLSBridged*` classes; Space-as-layer trick rejected | https://github.com/KiwiCanopy/KiwiDesk/issues/424 |
| 14 | KiwiDesk ships AX re-raise; AX couples raise with activation → focus wobble | https://github.com/KiwiCanopy/KiwiDesk/issues/424 · https://github.com/KiwiCanopy/KiwiDesk/issues/418 |
| 15 | Aloft: "macOS does not let one app change another app's window level"; `SLSSetWindowLevel` reports success and is ignored; `SLSSetUniversalOwner` entitlement-gated; 150 ms re-raise | https://github.com/iammayron/aloft |
| 16 | ProToys official docs: macOS has no official way; Mirror mode vs **Raise mode**; ~4 Hz re-assert; flash; Accessibility needed in both modes | https://protoys.app/docs/tools/always-on-top.html |
| 17 | Private entitlement `com.apple.private.skylight.universal-owner`; AMFI caveat; universal owner via Dock kill | https://github.com/asmvik/yabai/issues/2593 |
| 18 | Same person built this "instead of streaming window content to a proxy window" (Topit-like) | https://github.com/asmvik/yabai/issues/2593 |
| 19 | yabai: Dock is flagged universal owner; injection via `task_for_pid`; SIP must be partially disabled | https://github.com/asmvik/yabai/issues/1863 |
| 20 | yabai: which features need SIP off, incl. "control window layers (make windows appear topmost)"; "no way … without functional limitations when SIP is enabled" | https://github.com/asmvik/yabai/issues/1863 |
| 21 | yabai `csrutil enable --without fs --without debug --without nvram` | https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection |
| 22 | yabai: "sticky, sub-layer, opacity, scratchpad" require partial SIP disable | https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc |
| 23 | yabai macOS 27.2: Dock is fat `arm64e`+`arm64e.x1`, new PAC prologue — injection breaks each release | https://github.com/asmvik/yabai/issues/2832 |
| 24 | yabai uses `SLSSetWindowSubLevel` from inside the Dock payload, not `SLSSetWindowLevel` cross-process | DeepWiki https://deepwiki.com/asmvik/yabai/8.2-skylight-services-(sls)-private-apis |
| 25 | yabai overview: SA "loaded into Dock.app … requires partial SIP disabling" | DeepWiki (same) + https://github.com/asmvik/yabai/wiki |
| 26 | "Without being the Universal Owner, you can't change the order of a window owned by another process" | https://stackoverflow.com/questions/3706167/making-a-another-applicationss-window-frontmost-and-focused |
| 27 | CGS error codes for foreign windows: `1000` and `268435459`; root/activate don't help | https://stackoverflow.com/questions/34738375/controlling-level-and-focus-of-windows-other-apps-with-cgprivate-functions |
| 28 | "Only the owner of a window can manipulate it … one universal owner at a time (the Dock)" | https://stackoverflow.com/questions/36075213/set-non-owned-window-always-on-top-like-the-app-afloat |
| 29 | CGS ownership model on Sonoma; universal ownership entitlement means "macOS will just not run it"; only AX works | https://stackoverflow.com/questions/79135637/unable-to-move-windows-on-sonoma-using-private-apis-in-swift |
| 30 | Same-process vs foreign `NSWindow.setLevel:`; own-window group/child-window workaround and its flicker | https://stackoverflow.com/questions/36075213/… (same page) |
| 31 | Reference spec: AX keep-on-top loop, AXObserver, NSWorkspace notifications, 150 ms rate limit, focus handback, Gentle mode, no Screen Recording | https://github.com/turhe123/pin-window-on-top/blob/main/SPEC.md |
| 32 | Same project README: public statement of the ownership limitation; Accessibility-only permissions | https://github.com/turhe123/pin-window-on-top |
| 33 | AlwaysOnTop (218★): Accessibility + 0.5 s timer + throttled AppleScript activation | https://github.com/itsabhishekolkha/AlwaysOnTop |
| 34 | PinWindow: "no public macOS API to change another app's window level" → ScreenCaptureKit mirror | https://github.com/justwy/PinWindow |
| 35 | Pin: ScreenCaptureKit `SCStream` mirror | https://github.com/southflowpeak/Pin |
| 36 | Mac-Window-Pin: keep window on top without stealing focus | https://github.com/iconoclas/Mac-Window-Pin |
| 37 | Topit upstream (mirror) | https://github.com/lihaoyun6/Topit |
| 38 | Topit fork notes macOS 15 "not valid due to API difference" for the mirror path | https://github.com/willweimike/Topit |
| 39 | `_SLPSSetFrontProcessWithOptions` sets front process while `kAXRaiseAction` only moves z-order (cross-app raise is real) | https://github.com/lwouis/alt-tab-macos/commit/886f21a |
| 40 | Electron apps: invalid AX element makes `kAXRaise` no-op while the app ends up fronted | https://github.com/lwouis/alt-tab-macos/commit/eb4c08c |
| 41 | SkyLight private API layout + `_SLPSSetFrontProcessWithOptions` in alt-tab | https://github.com/lwouis/alt-tab-macos/blob/master/src/experimentations/PrivateApis.swift |
| 42 | Cached SkyLight/SLS Swift bindings (alt-tab) | https://raw.githubusercontent.com/lwouis/alt-tab-macos/master/src/macos/api-wrappers/SkyLight.framework.swift |
| 43 | `CGSPrivate.h`: `CGSGetWindowLevel`, `CGSGetWindowOwner`, `CGSSetWindowLevel` signatures | https://github.com/fjolnir/xnomad/blob/master/CGSPrivate.h |
| 44 | `CGSConnection.h`: `CGSMainConnectionID`, `CGSGetWindowOwner` | https://github.com/NUIKit/CGSInternal/blob/master/CGSConnection.h |
| 45 | Swift `@_silgen_name("CGSGetWindowLevel")` binding example (DockDoor) | https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift |
| 46 | Rust SkyLight bindings incl. `SLSMainConnectionID` (rift) | https://github.com/acsandmann/rift/blob/e95944ea/src/sys/skylight.rs |
| 47 | Own-connection SkyLight always-on-top (above full-screen, lock screen) — demonstrates the own-window boundary | https://github.com/Lakr233/SkyLightWindow |
| 48 | `CGWindowLevel.h` public constants | https://github.com/w0lfschild/cDock/blob/master/_resource/xcode/cDock-Bundle/CoreGraphics.framework/Versions/A/Headers/CGWindowLevel.h |
| 49 | Cua: SkyLight internals; `SLPSPostEventRecordTo` flips active state **without raising**; yabai focus-without-raise pattern | https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md |
| 50 | Cua `bring_to_front.rs`: AXRaise + `AXMain`/`AXFocused` write pattern | https://github.com/trycua/cua/blob/d1d2a7f37a8bb3a6a5686592a96487023d1f7ddc/libs/cua-driver/rust/crates/platform-macos/src/tools/bring_to_front.rs |
| 51 | AX raise + main/focused-window attribute writes in Swift (real-world usage) | https://github.com/vorssaint/vorssaint-utils/blob/main/Sources/Vorssaint/Services/Switcher/WindowActivator.swift |
| 52 | Minimal AX raise-after-activate pattern | https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/SessionWindowFocuser.swift |
| 53 | Fallback when a window doesn't support `kAXRaiseAction` (Electron); same-process AX raise is main-thread-only | https://github.com/XueshiQiao/AnyDrag/blob/main/AnyDrag/Sources/DragStrategy.swift |
| 54 | `raise(pid)` implemented as app activation — no real window-level raise | https://github.com/takeiteasy/AppleLisp/issues/3 |
| 55 | App Sandbox blocks Accessibility; Apple DTS: "not possible … directly distribute" | https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox |
| 56 | Sandbox: `AXUIElement` calls return nil despite trusted | https://stackoverflow.com/questions/79606344/accessibility-api-axfocuseduielement-always-returns-nil |
| 57 | "AXRaise brings a window to the front once, but the next click on any other window sends it behind again"; Rectangle Pro / BTT have always-on-top toggles; no AppleScript window-level setter | https://www.noticky.app/en/blog/always-on-top-apps-macos |
| 58 | AXRaise requires Accessibility since 10.9; `set index to 1` only makes it "window 1" to System Events | https://superuser.com/questions/586806/… · https://apple.stackexchange.com/questions/233687/… |
| 59 | Afloat = SIMBL injection; fragile; breaks on macOS 15 hardened runtime/SIP | https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e · https://apple.stackexchange.com/questions/219116/… |
| 60 | Rectangle Pro "Always On Top Mode" (closed-source) | https://github.com/rxhanson/RectanglePro-Community/discussions/855 |
| 61 | No first-party always-on-top through macOS 26 | https://medium.com/@ayincat/2026-macos-always-on-top-landscape-guide-floaty-for-macos-d98c6338244e (secondary) |
| 62 | Community statement of the ownership invariant | https://www.reddit.com/r/macapps/comments/1hu2rh3/make_a_window_float_on_top |
| 63 | Curated overlay-API research with DTS links, macOS 26.3 `ignoresMouseEvents` regression | https://github.com/Zelray/big-arrow-on-the-mac/blob/main/docs/research/2026-10-08-macos-overlay-apis-and-prior-art.md |
| 64 | BetterCmdTab: public AX raise + private `_SLPS…` `raiseWindow` for cross-Space correction | https://github.com/rokartur/BetterCmdTab/blob/main/BetterCmdTab/System/PrivateApis.swift |

**Conflicts / uncertainties stated explicitly**

- *Does `SLSSetWindowLevel` error or silently succeed on foreign windows?* **Conflict.** Aloft says it
  "reports success … and is ignored"; SO #34738375 reports hard errors (`1000`, `268435459`) for the
  related `CGSOrderWindow`; KiwiDesk says it "only affects windows owned by the connection that issues
  it". All three agree on the *outcome* (no effect). Treat any return of `0` as meaningless.
- *Is it blocked by SIP or by WindowServer?* Mostly settled: yabai (#1863) attributes its own
  always-on-top requirement to needing to inject into the Dock (SIP), while KiwiDesk (#424) and aloft
  attribute the level-write failure to connection ownership (not SIP). Both can be true and are
  distinct gates; §1.2 and §2 separate them. The one dissenting framing is casual commentary (e.g.
  Reddit "not possible without disabling SIP") which conflates the two — flagged as unreliable.
- *Could a "Space as layer" trick substitute?* Measured **no** on macOS 27 (#13). Do not retry.
- No source found that demonstrates any app successfully setting a **foreign** window's level on
  stock macOS 26/27 without Dock injection. Absence of evidence after broad searching across GitHub,
  StackOverflow, Apple forums, and vendor docs is itself treated here as evidence.
