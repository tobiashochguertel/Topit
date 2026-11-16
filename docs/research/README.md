# Research — keeping a foreign macOS window always on top

Two background research reports answer the question the fork started with:

> The brief assumed that *"with SIP enabled there is no proper solution"* to natively keep another
> app's window on top, and concluded ScreenCaptureKit mirroring was unavoidable. Is that true, and
> how does an app like ProToys pin windows without mirroring them?

| Report | Question it answers |
| --- | --- |
| [`native-always-on-top.md`](native-always-on-top.md) | Is a **level-based** pin possible at all? What does SIP actually block? What do ProToys, aloft, AlwaysOnTop, yabai… really do? |
| [`ax-native-pin-techniques.md`](ax-native-pin-techniques.md) | How to build the Accessibility keep-on-top loop correctly: reference implementations, `kAXRaiseAction` reliability, event tap vs polling, AXObserver pitfalls, Space/minimise detection, hit-testing, permission gating. |

## Verdict

**Yes, a native (non-mirror) always-on-top exists on stock macOS with SIP enabled — but it is a
"raise repeatedly" loop, not a window level. The brief's conclusion was right; its reasoning was
wrong, and the difference matters.**

1. **You cannot change another process's window level.** `SLSSetWindowLevel` /
   `CGSWindowSetLevel` / `CGSOrderWindow` either error or — worse — **return success and silently
   no-op** for windows not owned by the calling WindowServer connection. That is a **WindowServer
   ownership** policy, **not** SIP; root does not help.
   Sources: [KiwiDesk #424](https://github.com/KiwiCanopy/KiwiDesk/issues/424) (measured, SIP on),
   [aloft README](https://github.com/iammayron/aloft),
   [SO #3706167](https://stackoverflow.com/questions/3706167/making-a-another-applicationss-window-frontmost-and-focused).
2. **SIP blocks the escape hatch**, not the API. The only ways to become the "universal owner" are
   injecting into `Dock.app` via `task_for_pid` — [which SIP does block](https://developer.apple.com/documentation/security/disabling_and_enabling_system_integrity_protection)
   — or the private entitlement `com.apple.private.skylight.universal-owner`, which AMFI refuses to
   run. Both are unshippable.
3. **So every shipping app on modern macOS uses an Accessibility re-raise loop**, including the
   commercial app in question. ProToys documents both modes and says plainly that macOS has no
   official mechanism; its **Raise mode** *"re-asserts top position about four times a second"*:
   <https://protoys.app/docs/tools/always-on-top.html>
   There is no secret private API — the public-API design in this fork is the state of the art.

**Correction to the brief:** replace *"with SIP enabled there is no proper way to natively raise a
foreign window"* with *"with SIP enabled you cannot change a foreign window's **level**
(WindowServer ownership, not SIP); you can still **raise** it repeatedly via Accessibility, which is
what every shipping macOS app including ProToys does."*

### Ranked options

| # | Option | SIP on? | Permissions | Trade-offs |
| --- | --- | --- | --- | --- |
| 1 | **AX re-raise loop** (implemented here) | ✅ | Accessibility only | Sub-frame flash when another window takes the top; focus can briefly flicker; nothing above full-screen Spaces |
| 2 | Keep ScreenCaptureKit mirror (upstream) | ✅ | Accessibility + Screen Recording | You click a copy; CPU/GPU per pin |
| 3 | Hybrid: mirror only for full-screen-Space cases | ✅ | Accessibility (+ Screen Recording if mirror used) | Most surface area to maintain |
| 4 | SkyLight universal-owner entitlement | ❌ AMFI off | — | Will not launch on stock macOS |
| 5 | yabai-style `Dock.app` scripting addition | ❌ partial SIP off + root | — | Not shippable; breaks every macOS release |

### Two findings that shaped the implementation

- **App Sandbox blocks cross-process Accessibility entirely** ([Apple Developer Forums](https://developer.apple.com/forums/thread/836644),
  quoted in `native-always-on-top.md` §4.5). Any app doing this must ship **unsandboxed**
  (Developer ID, outside the Mac App Store). Topit's entitlements already contain no App Sandbox
  key, so it is fine — worth remembering before adding one.
- **`kAXRaiseAction` is not a stacking guarantee.** Apple's own docs hedge ("as frontmost as is
  allowed by the containing application's circumstances") and field evidence conflicts: AltTab found
  it only moves z-order without fronting the process, while
  [mctiler #8](https://github.com/tjukkefeiten/mctiler/issues/8) measured a *successful* raise that
  left the window below. Never trust the return code — verify by reading the window list back. That
  is why this fork raises, then checks occlusion again.

## Decisions taken from this research

| Decision | Because |
| --- | --- |
| Raise loop on app activation + Space change + 150 ms timer | ProToys re-asserts ~4 Hz; `turhe123/pin-window-on-top` and aloft both use 150–300 ms |
| Raise rate limit 150 ms/window, exponential backoff to 2 s | Two independent implementations rate-limit raises; prevents a raise storm when the raise cannot win |
| Occlusion test ("does an overlapping window sit above me") instead of "nothing above me" | `isWindowOnTop` is almost never true (Topit's own overlays, floating panels); pin-window-on-top uses `isAnyPinOccluded` |
| Space/minimise pause via `.optionOnScreenOnly` membership | No public Space API exists; `.optionOnScreenOnly` is current-Space-only *and* front-to-back ordered (`.optionAll` is unordered) |
| Re-activate the previously frontmost app if the raise stole focus | "AXRaise can steal focus" — explicit edge case in `pin-window-on-top`'s SPEC |
| 10 Hz mouse polling, not a `CGEventTap` | AutoRaise polls at 50 ms; taps need Input Monitoring, die on `kCGEventTapDisabledByTimeout` around sleep/wake, and can freeze all input |
| Poll the window frame instead of per-target `AXObserver` | `AXObserverAddNotification` commonly fails with `cannotComplete` (yabai hung on unbounded retries); Electron/Chromium rebuild elements keeping the same `CGWindowID` |
| Skip full-screen windows of other apps | They live in their own Space — a pin would vanish immediately |
| No SkyLight/CGS in this fork | Cross-process level writes silently no-op; documented in `NativePinManager.swift` |

## Uncertainties recorded by the research

See `ax-native-pin-techniques.md` §"Uncertain / conflicting claims" (U1–U8) and the flagged
conflicts in `native-always-on-top.md`. The ones that can bite this fork:

- **U: raise across apps is app-dependent** — expect "eventually correct with visible flicker",
  keep Mirror mode available as the fallback.
- **U: `AXFullScreen` is undocumented** — read it best-effort; unreadable is treated as
  "not full-screen" so the hover button still appears.
- **U: `-25205 (cannotComplete)` on macOS 26.7** has been reported for some apps (Calculator,
  System Settings), and SwiftUI windows are reported to fail AX raise systematically. Native pins
  therefore give up after ~3 s if Accessibility never resolves the window, rather than polling
  forever.
