//
//  PinRegistry.swift
//  Topit
//
//  Fork addition (AGPL-3.0, same license as upstream).
//
//  Upstream Topit has exactly one kind of "pin": a ScreenCaptureKit mirror inside Topit's own
//  overlay panel. The state of those pins lives in `SCManager.pinnedWdinwows` (an `[SCWindow]`
//  mutated from `OverlayView`), which means every consumer has to go through ScreenCaptureKit —
//  even when it only needs to know "is this window id pinned?".
//
//  This registry is the single source of truth for *all* pin kinds, keyed by `CGWindowID`:
//
//      .mirror  — upstream behaviour: Topit captures the window and floats a mirror panel
//      .native  — new: the real window is kept on top with the Accessibility API
//
//  Everything that needs pin state (`pnpUnderMouseWindow`, `pnpFrontmostWindow`, the menu bar
//  list, `unPinAll`, the hover pin button) reads from here, so both kinds behave identically
//  from the user's point of view.
//
//  Threading: `PinRegistry` is main-thread only — every mutation happens from UI handlers, the
//  status menu delegate and `NativePinManager`'s main-thread timer.
//

import SwiftUI
import ScreenCaptureKit

/// How a window is kept on top.
enum PinMode: String, CaseIterable, Identifiable {
    /// ScreenCaptureKit capture rendered into Topit's own floating panel (upstream behaviour).
    case mirror
    /// The real window is re-raised with the Accessibility API.
    case native

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mirror: return "Mirror"
        case .native: return "Native"
        }
    }
}

/// One pinned window. `id` is the `CGWindowID` (`kCGWindowNumber`), which is stable for the
/// lifetime of a window and unique system-wide — unlike an `AXUIElement`, which may be
/// recreated by the owning app, and unlike a window title, which is not unique.
struct PinEntry: Identifiable, Equatable {
    let id: CGWindowID
    var ownerPID: pid_t
    var mode: PinMode
    var appName: String
    var title: String
    var pinnedAt: Date

    static func == (lhs: PinEntry, rhs: PinEntry) -> Bool { lhs.id == rhs.id }
}

final class PinRegistry: ObservableObject {
    static let shared = PinRegistry()

    /// Published so SwiftUI (status menu, future pin list UI) can observe it.
    @Published private(set) var entries: [PinEntry] = []

    /// Mirror pins are removed by their overlay panel closing, which happens a moment after
    /// registration. Without a grace period a prune running in between would drop a healthy pin.
    private static let mirrorRegistrationGrace: TimeInterval = 3

    private init() {}

    // MARK: - Queries

    func isPinned(_ windowID: CGWindowID) -> Bool { entries.contains { $0.id == windowID } }

    func mode(for windowID: CGWindowID) -> PinMode? { entries.first(where: { $0.id == windowID })?.mode }

    var isEmpty: Bool { entries.isEmpty }

    func entries(of mode: PinMode) -> [PinEntry] { entries.filter { $0.mode == mode } }

    // MARK: - Mutations

    func register(windowID: CGWindowID,
                  ownerPID: pid_t,
                  mode: PinMode,
                  appName: String? = nil,
                  title: String? = nil) {
        let entry = PinEntry(id: windowID,
                             ownerPID: ownerPID,
                             mode: mode,
                             appName: appName ?? "",
                             title: title ?? "",
                             pinnedAt: Date())
        if let index = entries.firstIndex(where: { $0.id == windowID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func unregister(windowID: CGWindowID) {
        entries.removeAll(where: { $0.id == windowID })
    }

    /// Drop every pin belonging to an application (used when that app quits).
    func unregister(pid: pid_t) {
        entries.removeAll(where: { $0.ownerPID == pid })
    }

    func removeAll() {
        entries.removeAll()
    }

    // MARK: - Pruning

    /// Remove pins whose window or owning application no longer exists.
    ///
    /// Called before the registry is read by UI, so stale entries never show up in the menu.
    /// `NativePinManager` additionally prunes its own state on every timer tick.
    func prune() {
        let now = Date()
        let overlayTitles = Set(NSApp.windows.map { $0.title })

        entries.removeAll { entry in
            switch entry.mode {
            case .mirror:
                // A mirror pin lives exactly as long as its overlay panel ("Topit Layer<id>").
                if overlayTitles.contains("Topit Layer\(entry.id)")
                    || overlayTitles.contains("Topit Layer\(entry.id)O") {
                    return false
                }
                return now.timeIntervalSince(entry.pinnedAt) > PinRegistry.mirrorRegistrationGrace
            case .native:
                // There is no public API to enumerate Spaces, so "window still exists" is the
                // only safe signal: an off-screen (minimised / other Space) window is still
                // listed by `optionIncludingWindow`, a destroyed one is not.
                // See docs/research/ax-native-pin-techniques.md.
                if getCGWindowWithID(entry.id) == nil { return true }
                return NSRunningApplication(processIdentifier: entry.ownerPID) == nil
            }
        }
    }
}
