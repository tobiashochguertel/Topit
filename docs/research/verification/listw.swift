import Foundation
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for (i, w) in list.enumerated().prefix(20) {
    let id = w["kCGWindowNumber"] as? CGWindowID ?? 0
    let owner = w["kCGWindowOwnerName"] as? String ?? "?"
    let pid = w["kCGWindowOwnerPID"] as? pid_t ?? 0
    let b = w["kCGWindowBounds"] as? [String: CGFloat] ?? [:]
    print("\(i) #\(id) pid=\(pid) \(owner) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) title=\(w["kCGWindowName"] as? String ?? "")")
}
