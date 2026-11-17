//
//  NativePinManager.swift
//  Topit
//
//  Fork addition (AGPL-3.0, same license as upstream).
//
//  Keeps a *foreign* window on top without capturing it. Upstream Topit only knows one pin kind:
//  a ScreenCaptureKit mirror rendered into Topit's own panel. That costs a live capture stream,
//  needs Screen Recording permission, and the mirror is not the real window (no text cursor, no
//  native drag & drop, extra GPU/CPU per pinned window).
//
//  Native mode instead works on the real window with the Accessibility API — the same API Topit
//  already uses for `activateWindow()`.
//
//  Why a raise loop and not a window level?
//  ---------------------------------------
//  `NSWindow.level` only accepts windows this process owns. There is no public API that moves a
//  foreign window to another `CGWindowLevel`; doing that needs either private SkyLight/CGS calls
//  (`SLSSetWindowLevel` and friends) or code injected into the owning process, which System
//  Integrity Protection blocks. See docs/research/native-always-on-top.md for the full
//  investigation (that document also records what ProToys-style pinning appears to rely on).
//  So the public-API equivalent is: watch for the events that make the WindowServer pull our
//  window behind another one, and re-issue `kAXRaiseAction` when that happens. That is exactly
//  the approach of the open-source `pin-window-on-top` utility referenced in the feature brief.
//
//  Cost of that design: the raise is only visible after the next activation change, so brief
//  flicker is inherent. `nativePinGentleMode` trades responsiveness for calm — it only re-raises
//  on application activation / Space changes instead of on a 150 ms timer.
//
//  Threading: everything runs on the main thread (AX actions belong there), so no locking is
//  needed around `pins`.
//

import SwiftUI
import Cocoa

final class NativePinManager: ObservableObject {
    static let shared = NativePinManager()

    /// Minimum interval between two raise attempts for the same window.
    static let raiseInterval: TimeInterval = 0.15
    /// Longest interval we ever wait after raises that did not visibly take effect.
    static let maxBackoff: TimeInterval = 2.0
    /// How quickly the keep-on-top timer polls.
    static let pollInterval: TimeInterval = 0.15
    /// Exponent cap for the backoff. `raiseInterval * 2^4 = 2.4 s`, so `maxBackoff` is what binds.
    private static let maxFailures = 4
    /// Attempts to resolve a window in Accessibility before giving up (150 ms × 20 ≈ 3 s).
    private static let maxLookupFailures = 20
    /// A raise can drag its window's app forward; handing focus back has to be throttled harder than
    /// the raise itself or it turns into focus ping-pong with the raise loop.
    private static let focusHandbackInterval: TimeInterval = 1.0

    private struct PinState {
        let pid: pid_t
        /// Cached because resolving a `CGWindowID` to an `AXUIElement` walks the owning app's
        /// whole window list and matches frames (see `getAXWindow(windowID:)`).
        var axWindow: AXUIElement?
        var lastAttempt: Date = .distantPast
        /// Consecutive raises that left the window below something else. Drives the backoff.
        var failures: Int = 0
        /// When we last handed focus back after a raise that stole it.
        var lastFocusHandback: Date = .distantPast
        /// Consecutive failures to resolve the window in Accessibility at all. Kept separate from
        /// `failures`: "could not raise it high enough" is normal and must not drop the pin, while
        /// "Accessibility never gave us this window" (no permission, or an app that does not expose
        /// its windows) must not turn into an endless poll either.
        var lookupFailures: Int = 0
    }

    private var pins: [CGWindowID: PinState] = [:]
    private var timer: Timer?
    private var observersInstalled = false

    @AppStorage("nativePinGentleMode") private var gentleMode: Bool = false

    private init() {}

    // MARK: - Public API

    /// Record a native pin and raise the window immediately.
    /// - Returns: `false` when the window could not be resolved in Accessibility (no permission yet,
    ///   or an app that does not expose its windows). Such a pin is still registered and retries for
    ///   ~3 s, so granting permission now is picked up without re-pinning.
    @discardableResult
    func pin(windowID: CGWindowID) -> Bool {
        guard let cgWindow = getCGWindowWithID(windowID),
              let pid = cgWindow["kCGWindowOwnerPID"] as? pid_t else { return false }

        let axWindow = getAXWindow(windowID: windowID)
        pins[windowID] = PinState(pid: pid, axWindow: axWindow)

        PinRegistry.shared.register(windowID: windowID,
                                    ownerPID: pid,
                                    mode: .native,
                                    appName: cgWindow["kCGWindowOwnerName"] as? String,
                                    title: cgWindow["kCGWindowName"] as? String)

        installObservers()
        startTimer()
        raise(windowID: windowID, force: true)
        return axWindow != nil
    }

    func unpin(windowID: CGWindowID) {
        pins.removeValue(forKey: windowID)
        PinRegistry.shared.unregister(windowID: windowID)
        stopTimerIfIdle()
    }

    func unpinAll() {
        let ids = Array(pins.keys)
        pins.removeAll()
        for id in ids { PinRegistry.shared.unregister(windowID: id) }
        stopTimerIfIdle()
    }

    /// Called on app quit so native pins of that app disappear instead of being re-raised.
    func handleTermination(pid: pid_t) {
        for id in Array(pins.keys) where pins[id]?.pid == pid { unpin(windowID: id) }
    }

    // MARK: - Observers

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self,
                           selector: #selector(activeApplicationChanged(_:)),
                           name: NSWorkspace.didActivateApplicationNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(spaceChanged(_:)),
                           name: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(applicationTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification,
                           object: nil)
    }

    /// The WindowServer pulls the pinned window behind the newly activated app's windows, so this
    /// is the main trigger for a re-raise.
    @objc private func activeApplicationChanged(_ notification: Notification) {
        // Turning Gentle Mode off takes effect here: the timer restarts on the next app switch.
        startTimer()
        raiseAll()
    }

    /// Switching Spaces rebuilds the visible window set — re-raise everything that is still here.
    @objc private func spaceChanged(_ notification: Notification) {
        raiseAll()
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        handleTermination(pid: app.processIdentifier)
    }

    // MARK: - Keep-on-top loop

    private func startTimer() {
        guard timer == nil, !gentleMode else { return }
        let newTimer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // A gentle-mode switch has to take effect without restarting the app: stop here and
            // let `activeApplicationChanged` start it again if the user switches back.
            if self.gentleMode { timer.invalidate(); self.timer = nil; return }
            self.tick()
        }
        timer = newTimer
        // `.common` so a keep-on-top re-raise also happens while a menu is being tracked
        // (in `.default` mode timers stop firing during menu tracking).
        RunLoop.main.add(newTimer, forMode: .common)
    }

    private func stopTimerIfIdle() {
        if pins.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Re-evaluate every pin: drop dead ones, skip paused ones, raise the rest.
    private func tick() {
        raiseAll()
    }

    private func raiseAll() {
        // Accessibility can be revoked at any moment in System Settings; without this check we would
        // keep hammering WindowServer with calls that cannot succeed. Pins survive an accidental
        // revoke and resume once permission comes back (pin-window-on-top does the same via
        // `checkTrust`).
        guard AXIsProcessTrusted() else { return }

        // Don't cover Topit's own windows — pinning while the Settings window is key would put a
        // foreign window on top of the UI you are trying to use.
        let selfIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard !selfIsFrontmost else { return }

        // Snapshot: `raise` can drop a pin (window destroyed, app quit) and mutating the dictionary
        // while iterating its `keys` view is not safe.
        // One window-list snapshot per tick instead of one per pin: `isOnscreen` used to call
        // `getAllCGWindows()` per pin, which is an IPC round trip to WindowServer for every pin on
        // every 150 ms tick.
        // Membership in this set is also our Space/minimised test: there is no public Space API, so
        // the documented-by-observation behaviour that `.optionOnScreenOnly` excludes minimised and
        // off-Space windows is what AltTab, pin-window-on-top and this fork all rely on.
        let onscreenIDs = Set(getAllCGWindows()?.compactMap { $0["kCGWindowNumber"] as? CGWindowID } ?? [])

        for windowID in Array(pins.keys) {
            guard onscreenIDs.contains(windowID) else {
                // Minimised, on another Space, or closed — nothing to raise. Pausing here also
                // stops us from yanking the user to another Space by raising an off-screen window.
                continue
            }
            raise(windowID: windowID)
        }
    }

    /// Other native pins must not count as occluders: two overlapping pins would otherwise raise
    /// themselves above each other forever.
    private func otherPinIDs(than windowID: CGWindowID) -> Set<CGWindowID> {
        Set(pins.keys.filter { $0 != windowID })
    }

    private func raise(windowID: CGWindowID, force: Bool = false) {
        guard var state = pins[windowID] else { return }

        // Window destroyed / app quit while pinned.
        guard getCGWindowWithID(windowID) != nil,
              NSRunningApplication(processIdentifier: state.pid) != nil else {
            unpin(windowID: windowID)
            return
        }

        // Resolve the Accessibility element first: whether we can even reach the window must not
        // depend on whether it happens to be covered right now, otherwise pins whose window is
        // never exposed in AX would never be cleaned up.
        if let cached = state.axWindow, !isValid(cached) { state.axWindow = nil }
        if state.axWindow == nil { state.axWindow = getAXWindow(windowID: windowID) }
        guard let axWindow = state.axWindow else {
            state.lookupFailures += 1
            pins[windowID] = state
            // 150 ms × 20 ≈ 3 s of trying: enough to cover "Accessibility permission granted a
            // moment ago", not enough to poll forever for windows that are never exposed.
            if state.lookupFailures > Self.maxLookupFailures { unpin(windowID: windowID) }
            return
        }
        state.lookupFailures = 0

        let ignored = otherPinIDs(than: windowID)
        let now = Date()
        let backoff = min(Self.raiseInterval * pow(2, Double(min(state.failures, Self.maxFailures))), Self.maxBackoff)
        // Occlusion (a window above us that actually overlaps us), not "nothing above me": otherwise
        // Topit's own overlays or unrelated windows elsewhere on screen would trigger endless raises.
        guard force || isWindowOccluded(windowID: windowID, ignoring: ignored),
              force || now.timeIntervalSince(state.lastAttempt) >= backoff else {
            pins[windowID] = state
            return
        }
        
        state.lastAttempt = now
        // `kAXRaiseAction` normally reorders without activating the owner, but some apps do come
        // forward. Hand focus straight back, otherwise keystrokes would be delivered to the
        // pinned window's app. This mirrors the "immediate focus handback" step of
        // turhe123/pin-window-on-top (see docs/research/ax-native-pin-techniques.md).
        let frontmostBefore = NSWorkspace.shared.frontmostApplication
        let result = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        // Only act when this raise actually changed the frontmost app (rather than on every raise),
        // and throttle it: together with the occlusion-driven re-raise this is otherwise a closed
        // loop of "raise → owner comes forward → hand back → covered again → raise" with visible
        // focus flicker in the app the user is typing in.
        if result == .success,
           let before = frontmostBefore,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != before.processIdentifier,
           now.timeIntervalSince(state.lastFocusHandback) >= Self.focusHandbackInterval {
            state.lastFocusHandback = now
            before.activate(options: [])
        }
        if result != .success {
            state.failures += 1
        } else if isWindowOccluded(windowID: windowID, ignoring: ignored) {
            // The raise was accepted but the window is still covered — typically while a different
            // app owns the screen. Back off instead of hammering WindowServer every 150 ms.
            state.failures += 1
        } else {
            state.failures = 0
        }
        pins[windowID] = state
    }

    // MARK: - Helpers
    private func isValid(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success
    }
}
