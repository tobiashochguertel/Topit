# Reviews of the fork additions

Two parallel reviews of the `feat/hover-pin-button` branch (which contains `feat/native-pin-mode`
and `chore/fork-identity`):

| Report | Focus |
| --- | --- |
| [`clean-code-review.md`](clean-code-review.md) | Correctness, resource use, clean code, faithfulness to upstream, license compliance |
| [`acceptance-criteria-audit.md`](acceptance-criteria-audit.md) | The 7 acceptance criteria traced through the actual call sites |

**Verdict at review time:** *fix before ship.* Two blockers (inverted raise backoff, AppleScript
commands no longer resolving after the product rename) plus several majors.

## Status of the findings

| Finding | Status |
| --- | --- |
| B1 inverted failure bookkeeping → permanent 150 ms raise storm | ✅ fixed (`15c72e9`, independently diagnosed by both reviews) |
| B2 overlapping native pins re-raise each other forever | ✅ fixed — `isWindowOccluded(windowID:ignoring:)` and the raise loop passes the other native pin ids |
| B3 `PRODUCT_NAME` rename broke the sdef → AppleScript dead | ✅ fixed — `PRODUCT_MODULE_NAME = Topit` (verified: the build now emits `Topit.swiftmodule`) |
| F4 mirror pin state duplicated in `PinRegistry`, nothing unregisters it | ✅ fixed — panels unregister on close, the timing grace is gone, `MirrorPanel` owns the title format |
| F5 one window-list copy per pin per tick | ✅ fixed — once per tick, read from a snapshot |
| F6 hover poll hits WindowServer 10×/s while idle | ✅ fixed — idle cursor returns immediately |
| F7 full-screen target leaves the previous window id armed | ✅ fixed — hides immediately |
| F8 focus handback can fight the raise loop | ✅ mitigated — only when the raise actually changed the frontmost app, throttled to 1/s per window |
| F9 native `pin()` result discarded → up to 3 s of phantom pins | ⚠️ **accepted, not fixed.** Keeping the pin for ~3 s is deliberate: Accessibility lookup can legitimately fail for a moment (permission just granted, app still launching) and the retry loop picks it up. A truly unreachable window disappears on its own after 20 attempts. |
| F10 AppKit ordering / coordinate details | ✅ addressed — single best-effort `order(_:relativeTo:)` when the panel appears, clamp against the union of screens, `lastFrame` reset on hide |
| F11 Sparkle UI alive although the updater is inert | ✅ fixed — both update items are hidden when no feed is configured; `docs/fork.md` corrected |
| F12 accidental upstream behaviour changes (main panel closing from every entry point, panel no longer floating in native mode, missing red flash) | ✅ fixed — `closeMainWindowIfPinningMirror` restores upstream's scope, panel floats in native mode, click-to-select flashes red again for non-capturable windows |
| Criterion 6 FAIL: Selector auto-opens at launch → Screen Recording prompt even in native mode | ✅ fixed — the Selector no longer auto-opens in native mode |
| Minors (dead API, id-only `Equatable`, magic numbers, duplicated title strings) | ✅ mostly fixed; `PinMode.id` kept because `CaseIterable + Identifiable` is idiomatic for a picker |

## Not done

- No **runtime** verification of the raise itself. The dev session was locked (`loginwindow`
  frontmost → apps expose no real AX windows), so see
  [`../research/verification/README.md`](../research/verification/README.md) for the probes that
  close that gap.
- Gentle mode and `hoverButtonDelay` were never exercised interactively.
- `"AXFullScreen"` remains a de-facto (undocumented) attribute; both reviews agreed it is acceptable
  because it fails open.
