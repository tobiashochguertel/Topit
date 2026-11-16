// Raises an existing window (by CGWindowID) the same way NativePinManager does, and reports
// whether the raise actually changed stacking. Usage: axraise <windowNumber>
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

let target = CGWindowID(CommandLine.arguments[1])!

func frameOf(_ id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
          let first = list.first,
          let b = first["kCGWindowBounds"] as? [String: CGFloat] else { return nil }
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}

func positionInFrontToBackList(_ id: CGWindowID) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    return list.firstIndex(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id })
}

func occluders(_ id: CGWindowID) -> [String] {
    guard let frame = frameOf(id),
          let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] else { return [] }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return above.compactMap { w in
        if let wid = w["kCGWindowNumber"] as? CGWindowID, wid == id { return nil }
        guard let pid = w["kCGWindowOwnerPID"] as? pid_t, pid != ownPID,
              (w["kCGWindowLayer"] as? NSNumber) == 0,
              (w["kCGWindowAlpha"] as? NSNumber) != 0,
              let f = frameOf(w["kCGWindowNumber"] as? CGWindowID ?? 0),
              f.intersects(frame) else { return nil }
        return "\(w["kCGWindowOwnerName"] as? String ?? "?")#\(w["kCGWindowNumber"] as? CGWindowID ?? 0)"
    }
}

func axWindow(_ id: CGWindowID) -> AXUIElement? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
          let first = list.first,
          let pid = first["kCGWindowOwnerPID"] as? pid_t,
          let frame = frameOf(id) else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
          let windows = raw as? [AXUIElement] else { return nil }
    for ax in windows {
        var p: CFTypeRef?, s: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &p) == .success, let p { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &s) == .success, let s { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        if CGRect(origin: pos, size: size).equalTo(frame) { return ax }
    }
    return nil
}

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
print("frontmost before: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
print("target #\(target) index in front-to-back list: \(String(describing: positionInFrontToBackList(target)))")
print("occluders before: \(occluders(target))")

guard let ax = axWindow(target) else { print("could not resolve AXUIElement"); exit(1) }
let r = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
print("kAXRaiseAction -> \(r.rawValue) (0 = success)")
Thread.sleep(forTimeInterval: 0.3)
print("index after raise: \(String(describing: positionInFrontToBackList(target)))")
print("occluders after raise: \(occluders(target))")
print("frontmost after: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
