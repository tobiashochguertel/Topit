//
//  HoverPinButton.swift
//  Topit
//
//  Fork addition (AGPL-3.0, same license as upstream).
//
//  A small pin button that follows the window under the cursor, so a window can be pinned without
//  going through the menu bar, the window selector or a hotkey. It reuses the existing
//  `buttonPosition` corner convention and toggles both pin modes through `PinActions`.
//
//  Design decisions (and why they deviate from the brief where they do):
//
//  • **10 Hz `Timer` polling `NSEvent.mouseLocation`, not a `CGEventTap`.**
//    A tap would need Input Monitoring permission on top of Accessibility, is silently disabled on
//    `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput` (typically around
//    sleep/wake), and worst case freezes all input if the callback stops returning events.
//    `sbmpost/AutoRaise` — the reference focus-follows-mouse implementation — polls at 50 ms for
//    exactly this reason, and Topit's own `WindowHighlighter` already uses the equivalent
//    `addGlobalMonitorForEvents(matching: .mouseMoved)`. See
//    docs/research/ax-native-pin-techniques.md §3.
//
//  • **Move/resize tracking by re-reading the window frame on the same poll, not by `AXObserver`.**
//    The brief prefers an `AXObserver` on `kAXMovedNotification`/`kAXResizedNotification`. Observers
//    are only worth their complexity for long-lived targets: `AXObserverAddNotification` commonly
//    returns `kAXErrorCannotComplete` for apps that are still launching or that never allow
//    subscription (yabai even hung on unbounded retries), and Electron/Chromium rebuild their
//    AXUIElement while keeping the same `CGWindowID`, after which the observer keeps delivering for
//    a dead element. A hover target changes constantly, so observers would be created and torn down
//    several times per second. The 10 Hz poll already has the window list in hand, so it repositions
//    the button for free — see docs/research/ax-native-pin-techniques.md §4.
//
//  • **No button on full-screen windows of other apps.** Those live in their own Space; showing a
//    control for them invites a pin that immediately disappears.
//
//  Threading: main thread only (AppKit panels + SwiftUI state).
//

import SwiftUI
import Cocoa

struct HoverPinButton: View {
    @EnvironmentObject var controller: HoverPinController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            guard let windowID = controller.targetWindowID else { return }
            // The window id is stored on the controller at hover time — never re-hit-tested here,
            // otherwise a click during a window switch would pin whatever moved under the cursor.
            PinActions.toggle(windowID: windowID)
        } label: {
            Image(systemName: controller.targetIsPinned ? "pin.circle.fill" : "pin.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(controller.targetIsPinned ? .buttonBlue : Color(white: colorScheme == .dark ? 0.25 : 0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                        .stroke(.secondary.opacity(0.5), lineWidth: 0.5).padding(0.5)
                )
        }
        .buttonStyle(.plain)
        .help(controller.targetIsPinned ? "Unpin This Window" : "Pin This Window")
    }
}

final class HoverPinController: ObservableObject {
    static let shared = HoverPinController()

    /// Poll rate for "which window is under the cursor" — 10 Hz, see file header.
    private static let pollInterval: TimeInterval = 0.1
    private static let buttonSize: CGFloat = 28
    private static let inset: CGFloat = 6

    @Published private(set) var targetWindowID: CGWindowID?
    @Published private(set) var targetIsPinned: Bool = false

    private var panel: NNSPanel?
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var hostedWindowID: CGWindowID?
    private var lastFrame: CGRect = .zero

    @AppStorage("showHoverPinButton") private var enabled: Bool = true
    @AppStorage("buttonPosition") private var buttonPosition: Int = 0

    private init() {}

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`. The setting toggle is honoured inside the
    /// poll, so switching it off takes effect immediately without restarting anything.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hideButton()
    }

    // MARK: - Poll

    private func tick() {
        guard enabled, !WindowHighlighter.shared.isSelecting else {
            if targetWindowID != nil { hideButton() }
            return
        }

        let mouse = NSEvent.mouseLocation

        // Self-hover: keep the button alive while the cursor is on the button itself, otherwise
        // moving towards it would hide it before the click lands.
        if let panel, panel.isVisible, panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
            cancelPendingHide()
            return
        }

        guard let window = eligibleWindowUnderMouse(mouse),
              let windowID = window["kCGWindowNumber"] as? CGWindowID,
              let frame = getCGWindowFrame(window: window) else {
            scheduleHide()
            return
        }

        cancelPendingHide()

        if windowID != targetWindowID {
            // A new target may be full-screen (own Space) — no button there.
            if isFullscreen(windowID: windowID) {
                scheduleHide()
                return
            }
            targetWindowID = windowID
            lastFrame = frame
            ensurePanel(windowID: windowID)
            showButton(at: frame)
        } else if frame != lastFrame {
            lastFrame = frame
            showButton(at: frame)
        }

        refreshPinnedState()
    }

    // MARK: - Panel

    private func ensurePanel(windowID: CGWindowID) {
        guard panel == nil else {
            hostedWindowID = windowID
            panel?.title = Self.panelTitle(windowID)
            return
        }
        let panel = NNSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.buttonSize, height: Self.buttonSize)),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        // Join every Space so the button never triggers a Space switch by following a window.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HoverPinButton().environmentObject(self))
        panel.title = Self.panelTitle(windowID)
        self.panel = panel
        hostedWindowID = windowID
    }

    private static func panelTitle(_ windowID: CGWindowID) -> String { "Topit Hover Pin \(windowID)" }

    /// Anchor the button to the hovered window using the same corner convention as the overlay
    /// buttons: 0 = top leading, 1 = bottom leading, 2 = top trailing, 3 = bottom trailing.
    private func showButton(at frame: CGRect) {
        guard let panel, let windowID = hostedWindowID else { return }
        let nsFrame = CGRectTransform(cgRect: frame)
        var origin = CGPoint()

        switch buttonPosition {
        case 0: origin = CGPoint(x: nsFrame.minX + Self.inset, y: nsFrame.maxY - Self.inset - Self.buttonSize)
        case 1: origin = CGPoint(x: nsFrame.minX + Self.inset, y: nsFrame.minY + Self.inset)
        case 2: origin = CGPoint(x: nsFrame.maxX - Self.inset - Self.buttonSize, y: nsFrame.maxY - Self.inset - Self.buttonSize)
        default: origin = CGPoint(x: nsFrame.maxX - Self.inset - Self.buttonSize, y: nsFrame.minY + Self.inset)
        }

        // Keep it reachable when the target window is partly off-screen (dual-monitor setups).
        if let screen = getScreenWithMouse() ?? NSScreen.main {
            let bounds = screen.frame.insetBy(dx: 4, dy: 4)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - Self.buttonSize)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - Self.buttonSize)
        }

        panel.setFrameOrigin(origin)
        if !panel.isVisible { panel.orderFront(self) }
        // Sit above the hovered window rather than merely floating, which is how the existing
        // selection mask does it too (WindowHighlighter.createMaskWindow).
        panel.order(.above, relativeTo: Int(windowID))
    }

    private func refreshPinnedState() {
        guard let windowID = hostedWindowID else { return }
        let pinned = PinRegistry.shared.isPinned(windowID)
        if pinned != targetIsPinned { targetIsPinned = pinned }
    }

    private func hideButton() {
        targetWindowID = nil
        targetIsPinned = false
        hostedWindowID = nil
        panel?.orderOut(nil)
    }

    // MARK: - Show/hide timing

    /// Seconds the button stays visible after the cursor leaves the window and the button.
    /// Not exposed in Settings (nothing else needs a UI for it); tweakable with
    /// `defaults write com.tobiashochgurtel.TopitFork hoverButtonDelay -float 1.0`.
    private var hideDelay: TimeInterval {
        let value = ud.object(forKey: "hoverButtonDelay") as? TimeInterval
        return max(0, min(value ?? 0.5, 5))
    }

    private func scheduleHide() {
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hideButton()
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func cancelPendingHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    // MARK: - Eligibility

    /// Top-most eligible window under the cursor.
    ///
    /// `getAllCGWindows()` already filters to `layer == 0`, non-transparent, non-desktop windows and
    /// — importantly — is ordered front-to-back because it uses `.optionOnScreenOnly`
    /// (`.optionAll` is *not* ordered, see docs/research/ax-native-pin-techniques.md §6). Own-app
    /// windows are skipped here so the button never appears over Topit's own overlays and the real
    /// window behind a mirror pin is not offered twice.
    private func eligibleWindowUnderMouse(_ mouse: NSPoint) -> [String: Any]? {
        guard let windows = getAllCGWindows() else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for window in windows {
            guard let pid = window["kCGWindowOwnerPID"] as? pid_t, pid != ownPID,
                  let frame = getCGWindowFrame(window: window) else { continue }
            let nsFrame = CGRectTransform(cgRect: frame)
            guard nsFrame.width > 40, nsFrame.height > 40, nsFrame.contains(mouse) else { continue }
            return window
        }
        return nil
    }

    /// `true` for full-screen windows of other apps.
    ///
    /// There is no public full-screen attribute; `kAXFullScreen` (the literal string used by
    /// `turhe123/pin-window-on-top`) is the de-facto one and is undocumented. It is read once per
    /// hover target, and if it cannot be read we assume the window is *not* full-screen so the
    /// button still appears.
    private func isFullscreen(windowID: CGWindowID) -> Bool {
        guard let axWindow = getAXWindow(windowID: windowID) else { return false }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &value)
        return result == .success && (value as? Bool) == true
    }
}
