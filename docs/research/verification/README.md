# Verification probes

Small, self-contained Swift harnesses that exercise the *actual* predicates Topit Fork relies on,
so behaviour can be checked without running the GUI app and without granting it anything new.
They mirror `Topit/Supports/Accessibility.swift` line by line — keep them in sync when that file
changes.

```bash
cd docs/research/verification
swiftc -O listw.swift   -o listw   && ./listw            # front-to-back window list + pids
swiftc -O axprobe.swift -o axprobe && ./axprobe          # trust state, occlusion, hover hit-test
swiftc -O axraise.swift -o axraise && ./axraise 12345    # raise one window id, report stacking
swiftc -O axdbg.swift   -o axdbg   && ./axdbg 16909      # what an app exposes via AX
```

Run them while the session is **unlocked**. macOS does not expose other apps' windows while the
login window owns the screen (see results below).

## Results from the development machine

macOS 27.2.1 (26B131), multi-display (main 3840×2160), Terminal already trusted for Accessibility:

| Check | Result |
| --- | --- |
| `CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly])` is front-to-back ordered | ✅ Confirmed (menubar/status items first, then app windows) |
| `isWindowOccluded` logic distinguishes covered vs topmost windows | ✅ Confirmed: e.g. 1Password `#6925` → occluded by `CoreServicesUIAgent #21732`; Docky `#19629` → not occluded |
| CG (top-left) → NS (bottom-left) conversion against `CGDisplayBounds(CGMainDisplayID())` | ✅ Confirmed consistent with the window list |
| `kAXRaiseAction` actually restacks across apps | ⚠️ **Inconclusive — session was locked.** Every app answered `kAXWindowsAttribute` with a single 0×0 element (the well-known locked-session behaviour), so no real `AXUIElement` could be resolved and no raise could be sent |

Re-run `./axraise <windowID>` on an unlocked session to close the last row; pick a window id from
`./listw`. If the raise leaves `occluders after raise` unchanged while `kAXRaiseAction -> 0`, that is
the documented "successful raise that does not restack" case — see
[`../ax-native-pin-techniques.md`](../ax-native-pin-techniques.md) §2.
