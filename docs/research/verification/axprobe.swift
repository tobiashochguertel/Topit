// Probe of the exact predicates Topit Fork uses for native pinning + hover hit-testing.
// Not part of the app: a throwaway harness that mirrors Supports/Accessibility.swift logic so the
// behaviour can be observed on a real system (macOS 26/27 line) without running the GUI app.
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

func getAllCGWindows() -> [[String: Any]]? {
    guard var windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    windowList = windowList.filter({
        !["SystemUIServer", "Window Server"].contains($0["kCGWindowOwnerName"] as? String)
        && $0["kCGWindowAlpha"] as? NSNumber != 0
        && $0["kCGWindowLayer"] as? NSNumber == 0
    })
    return windowList
}

func getCGWindowFrame(_ window: [String: Any]) -> CGRect? {
    guard let b = window["kCGWindowBounds"] as? [String: CGFloat] else { return nil }
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}

let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
func cgRectToNS(_ r: CGRect) -> NSRect {
    NSRect(x: r.origin.x, y: mainHeight - r.origin.y - r.height, width: r.width, height: r.height)
}

func isWindowOccluded(windowID: CGWindowID) -> Bool {
    guard let frame = getCGWindowFrame(getAllCGWindows()?.first(where: { ($0["kCGWindowNumber"] as? CGWindowID) == windowID }) ?? [:]) else { return false }
    guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]] else { return false }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    for w in above {
        if let wid = w["kCGWindowNumber"] as? CGWindowID, wid == windowID { continue }
        guard let pid = w["kCGWindowOwnerPID"] as? pid_t, pid != ownPID,
              (w["kCGWindowLayer"] as? NSNumber) == 0,
              (w["kCGWindowAlpha"] as? NSNumber) != 0,
              let other = getCGWindowFrame(w) else { continue }
        if other.intersects(frame) { return true }
    }
    return false
}

print("== environment ==")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
print("own pid: \(ProcessInfo.processInfo.processIdentifier)")
print("main screen height: \(CGDisplayBounds(CGMainDisplayID()).height)")
print("mouseLocation (NS, bottom-left origin): \(NSEvent.mouseLocation)")

print("\n== top 5 on-screen windows (front-to-back) ==")
let windows = getAllCGWindows() ?? []
for w in windows.prefix(5) {
    let id = w["kCGWindowNumber"] as? CGWindowID ?? 0
    let owner = w["kCGWindowOwnerName"] as? String ?? "?"
    let frame = getCGWindowFrame(w) ?? .zero
    print("  #\(id) \(owner) frame=\(frame) occluded=\(isWindowOccluded(windowID: id))")
}

print("\n== eligible hover target under the cursor (excluding own pid) ==")
let mouse = NSEvent.mouseLocation
var found: (CGWindowID, String)? = nil
let ownPID = ProcessInfo.processInfo.processIdentifier
for w in windows {
    guard let pid = w["kCGWindowOwnerPID"] as? pid_t, pid != ownPID,
          let frame = getCGWindowFrame(w) else { continue }
    let ns = cgRectToNS(frame)
    guard ns.width > 40, ns.height > 40, ns.contains(mouse) else { continue }
    found = (w["kCGWindowNumber"] as? CGWindowID ?? 0, w["kCGWindowOwnerName"] as? String ?? "?")
    break
}
if let found { print("  -> #\(found.0) \(found.1)") } else { print("  -> none (desktop or an excluded window)") }

print("\n== AXFullScreen readability (de-facto attribute) ==")
if let target = found?.0,
   let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], target) as? [[String: Any]],
   let first = list.first,
   let pid = first["kCGWindowOwnerPID"] as? pid_t {
    let appEl = AXUIElementCreateApplication(pid)
    var rawWindows: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &rawWindows) == .success,
       let axWindows = rawWindows as? [AXUIElement],
       let targetFrame = getCGWindowFrame(first) {
        var matched: AXUIElement? = nil
        for ax in axWindows {
            var p: CFTypeRef?; var s: CFTypeRef?
            var pos = CGPoint.zero; var size = CGSize.zero
            if AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &p) == .success, let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &s) == .success, let s, CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            if CGRect(origin: pos, size: size).equalTo(targetFrame) { matched = ax; break }
        }
        if let matched {
            var v: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(matched, "AXFullScreen" as CFString, &v)
            print("  kAXFullScreen -> error=\(r.rawValue) value=\(v.map { String(describing: $0) } ?? "nil")")
            var role: CFTypeRef?
            let rr = AXUIElementCopyAttributeValue(matched, kAXRoleAttribute as CFString, &role)
            print("  kAXRole -> error=\(rr.rawValue) value=\(role.map { String(describing: $0) } ?? "nil")")
            if AXIsProcessTrusted() {
                let raise = AXUIElementPerformAction(matched, kAXRaiseAction as CFString)
                print("  kAXRaiseAction -> \(raise.rawValue) ; occluded after raise = \(isWindowOccluded(windowID: target))")
            }
        } else {
            print("  no AXUIElement matched the CG frame")
        }
    } else {
        print("  window list via AX unavailable (accessibility not granted or app exposes no windows)")
    }
}
