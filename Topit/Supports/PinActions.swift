//
//  PinActions.swift
//  Topit
//
//  Fork addition (AGPL-3.0, same license as upstream).
//
//  Single entry point for "pin this window" / "unpin this window", independent of the pin mode.
//  Upstream scattered that logic in `pnpUnderMouseWindow()` / `pnpFrontmostWindow()`, which always
//  went through ScreenCaptureKit — that is fine for mirror pins but it means native-only users
//  still get a Screen Recording prompt (acceptance criterion 6). Everything here resolves the
//  mode first and only touches ScreenCaptureKit when the mode really is `.mirror`.
//

import SwiftUI
import ScreenCaptureKit

enum PinActions {
    /// The mode the user selected in Settings → Windows. Read straight from `UserDefaults`
    /// because this is also used from non-UI code paths (hotkey handlers, status menu).
    /// The same key is bound by `@AppStorage("pinMode")` in `SettingsView`.
    static var currentMode: PinMode {
        get { PinMode(rawValue: ud.string(forKey: "pinMode") ?? "") ?? .mirror }
        set { ud.set(newValue.rawValue, forKey: "pinMode") }
    }

    /// Pin the window if it is not pinned, unpin it if it is — using whatever mode it uses.
    static func toggle(windowID: CGWindowID) {
        PinRegistry.shared.prune()
        if let mode = PinRegistry.shared.mode(for: windowID) {
            unpin(windowID: windowID, mode: mode)
        } else {
            pin(windowID: windowID)
        }
    }

    static func pin(windowID: CGWindowID) {
        switch currentMode {
        case .mirror:
            closeMainWindow()
            // Only mirror pins need a capture source — everything below is the point where a
            // native-only user would otherwise be asked for Screen Recording permission.
            guard let scWindow = getSCWindowWithID(windowID, noFilter: true),
                  let display = getSCDisplayWithMouse() else { return }
            createNewWindow(display: display, window: scWindow)
        case .native:
            NativePinManager.shared.pin(windowID: windowID)
        }
    }

    static func unpin(windowID: CGWindowID, mode: PinMode) {
        switch mode {
        case .mirror:
            closeMirrorPanel(windowID: windowID)
        case .native:
            NativePinManager.shared.unpin(windowID: windowID)
        }
    }

    /// Overlay panels are addressed by title, exactly as upstream does: `Topit Layer<windowID>`
    /// (and `Topit Layer<windowID>O` for the translucent variant).
    static func closeMirrorPanel(windowID: CGWindowID) {
        for w in NSApp.windows.filter({ $0.title == "Topit Layer\(windowID)"
            || $0.title == "Topit Layer\(windowID)O" }) {
            w.close()
        }
    }

    static func unpinAll() {
        for layer in NSApp.windows.filter({ $0.title.hasPrefix("Topit Layer") }) { layer.close() }
        NativePinManager.shared.unpinAll()
        PinRegistry.shared.removeAll()
        AvoidManager.shared.activedFrame = .zero
    }
}
