import Foundation
import CoreGraphics
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
var raw: CFTypeRef?
let r = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
print("kAXWindows -> \(r.rawValue) count=\((raw as? [AXUIElement])?.count ?? -1)")
if let ws = raw as? [AXUIElement] {
    for (i, w) in ws.enumerated() {
        var p: CFTypeRef?, s: CFTypeRef?, t: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s)
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
        if let p { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        print("  [\(i)] pos=\(pos) size=\(size) title=\(t as? String ?? "")")
    }
}
// attribute names probe
var names: CFArray?
let nr = AXUIElementCopyAttributeNames(app, &names)
print("app attributes error=\(nr.rawValue): \((names as? [String])?.prefix(8) ?? [])")
