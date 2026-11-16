//
//  TopitApp.swift
//  Topit
//
//  Created by apple on 2024/11/17.
//

import SwiftUI
import Cocoa
import Foundation
import ScreenCaptureKit
import KeyboardShortcuts

let ud = UserDefaults.standard
let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

var isMacOS13 = false
var isMacOS12 = false
var axPerm = false
var scPerm = false

@main
struct TopitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
                .background(
                    WindowAccessor(
                        onWindowOpen: { w in
                            if let w = w {
                                w.level = .floating
                                w.titlebarSeparatorStyle = .none
                                guard let nsSplitView = findNSSplitVIew(view: w.contentView),
                                      let controller = nsSplitView.delegate as? NSSplitViewController else { return }
                                controller.splitViewItems.first?.canCollapse = false
                                controller.splitViewItems.first?.minimumThickness = 140
                                controller.splitViewItems.first?.maximumThickness = 140
                                w.orderFront(nil)
                            }
                        })
                )
        }.commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    @AppStorage("showOnDock") private var showOnDock: Bool = true
    @AppStorage("showMenubar") private var showMenubar: Bool = true
    /// Fork: dynamic list of currently pinned windows (both modes), filled in `menuNeedsUpdate`.
    private let pinsMenu = NSMenu()
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        if #unavailable(macOS 14) { isMacOS13 = true }
        if #unavailable(macOS 13) { isMacOS12 = true }
        if showOnDock { NSApp.setActivationPolicy(.regular) }
        if let button = statusBarItem.button {
            button.target = self
            button.image = NSImage(named: "statusIcon")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Pin a Window".local, action: #selector(selectWindowToPin), keyEquivalent: "p")
        menu.addItem(withTitle: "Unpin all Windows".local, action: #selector(unPinAll), keyEquivalent: "u")
        // Fork: native-pinned windows are real windows and cannot carry Topit's overlay buttons,
        // so the status menu is one of the few places where they can be unpinned.
        pinsMenu.delegate = self
        let pinsItem = NSMenuItem(title: "Pinned Windows".local, action: nil, keyEquivalent: "")
        pinsItem.submenu = pinsMenu
        menu.addItem(pinsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Window Selector".local, action: #selector(openFromMenuBar), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…".local, action: #selector(settings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…".local, action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Topit".local, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusBarItem.menu = menu
        statusBarItem.isVisible = showMenubar
        
        KeyboardShortcuts.onKeyDown(for: .unpinAll) { self.unPinAll() }
        KeyboardShortcuts.onKeyDown(for: .openMainPanel) { _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
        KeyboardShortcuts.onKeyDown(for: .selectWindow) { WindowHighlighter.shared.registerMouseMonitor() }
        KeyboardShortcuts.onKeyDown(for: .pinUnpin) { pnpUnderMouseWindow() }
        KeyboardShortcuts.onKeyDown(for: .pinUnpinTopmost) { pnpFrontmostWindow() }
        
        tips("Topit uses the accessibility permissions\nand screen recording permissions\nto control and capture your windows.".local, id: "topit.how-to-use.note")
        tips("macOS will prevent any notifications from appearing while Topit is running\nIt's not a bug or Topit's fault!".local, id: "topit.no-notifications.note")
        // Fork: only mirror mode has a reason to touch ScreenCaptureKit at launch. Probing it
        // unconditionally means every native-mode user is greeted by a Screen Recording prompt.
        scPerm = PinActions.currentMode == .mirror ? (SCManager.updateAvailableContentSync() != nil) : false
        axPerm = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as NSDictionary)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fork: the Selector panel captures every window for its thumbnails, so opening it at launch
        // would trigger the Screen Recording prompt even for someone who only uses native mode.
        // In native mode Topit starts as a menu-bar app + hover button; the Selector is still one
        // dock/menu-bar click away (and still legitimately needs Screen Recording when used).
        if showOnDock, PinActions.currentMode == .mirror {
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        }
        // Fork: hover pin button. Started unconditionally; the `showHoverPinButton` setting is
        // honoured inside the poll so toggling it needs no restart.
        HoverPinController.shared.start()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if NSApp.windows.first(where: { $0.title == "Topit" })?.isVisible != true {
            axPerm = AXIsProcessTrusted()
            let mainPanel = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            if axPerm && scPerm { mainPanel.level = .floating }
            mainPanel.title = "Topit"
            mainPanel.titlebarSeparatorStyle = .none
            mainPanel.titlebarAppearsTransparent = true
            mainPanel.isMovableByWindowBackground = true
            mainPanel.toolbarStyle = .unifiedCompact
            let contentView = NSHostingView(rootView: ContentView())
            mainPanel.contentView = contentView
            mainPanel.makeKeyAndOrderFront(self)
            mainPanel.center()
        }
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        unPinAll()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Pin a Window".local, action: #selector(selectWindowToPin), keyEquivalent: "")
        menu.addItem(withTitle: "Unpin all Windows".local, action: #selector(unPinAll), keyEquivalent: "")
        return menu
    }
    
    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
    
    @objc func unPinAll() {
        DispatchQueue.main.async { PinActions.unpinAll() }
    }
    
    @objc func about() {
        openAboutPanel()
    }
    
    @objc func settings() {
        openSettingPanel()
    }
    
    @objc func openFromMenuBar() {
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    }
    
    @objc func selectWindowToPin() {
        WindowHighlighter.shared.registerMouseMonitor()
    }
}

/// Pin / unpin whatever window is currently under the cursor.
///
/// Fork change: this used to resolve the window to an `SCWindow` up front, which makes
/// `SCShareableContent.getExcludingDesktopWindows` run and pops the Screen Recording prompt even
/// when the pin is going to be a native one. The mode decides now, not the lookup.
func pnpUnderMouseWindow() {
    guard let window = getWindowUnderMouse(),
          let windowID = window["kCGWindowNumber"] as? UInt32 else { return }
    PinActions.toggle(windowID: windowID)
}

func pnpFrontmostWindow() {
    // `getFrontmostCGWindow()` (not `getFrontmostWindow()`) so the native path stays
    // ScreenCaptureKit-free.
    guard let window = getFrontmostCGWindow(),
          let windowID = window["kCGWindowNumber"] as? UInt32 else { return }
    PinActions.toggle(windowID: windowID)
}

func closeMainWindow() {
    NSApp.windows.first(where: { $0.title == "Topit" })?.close()
}

func openAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel()
}

func getMenuBarHeight() -> CGFloat {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    if let screen = screen {
        return screen.frame.height - screen.visibleFrame.height - (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1
    }
    return 0.0
}

func tips(_ message: String, title: String? = nil, id: String, switchButton: Bool = false, width: Int? = nil, action: (() -> Void)? = nil) {
    let never = (ud.object(forKey: "neverRemindMe") as? [String]) ?? []
    if !never.contains(id) {
        if switchButton {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: "OK", button2: "Don't remind me again", width: width).runModal()
            if alert == .alertSecondButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
            if alert == .alertFirstButtonReturn { action?() }
        } else {
            let alert = createAlert(title: title ?? Bundle.main.appName + " Tips".local, message: message, button1: "Don't remind me again", button2: "OK", width: width).runModal()
            if alert == .alertFirstButtonReturn { ud.setValue(never + [id], forKey: "neverRemindMe") }
            if alert == .alertSecondButtonReturn { action?() }
        }
    }
}

func createAlert(level: NSAlert.Style = .warning, title: String, message: String, button1: String, button2: String = "", width: Int? = nil) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title.local
    alert.informativeText = message.local
    alert.addButton(withTitle: button1.local)
    if button2 != "" { alert.addButton(withTitle: button2.local) }
    alert.alertStyle = level
    if let width = width {
        alert.accessoryView = NSView(frame: NSMakeRect(0, 0, Double(width), 0))
    }
    return alert
}

func openSettingPanel() {
    closeMainWindow()
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        NSApp.mainMenu?.items.first?.submenu?.item(at: 3)?.performAction()
    }else if #available(macOS 13, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

func findNSSplitVIew(view: NSView?) -> NSSplitView? {
    var queue = [NSView]()
    if let root = view { queue.append(root) }
    
    while !queue.isEmpty {
        let current = queue.removeFirst()
        if current is NSSplitView { return current as? NSSplitView }
        for subview in current.subviews { queue.append(subview) }
    }
    return nil
}

// MARK: - Pinned windows menu (fork addition)

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt every time the submenu is about to be displayed, so it always reflects live state
    /// (a mirror panel can be closed by the user, a native window can go away on its own).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === pinsMenu else { return }
        menu.removeAllItems()
        PinRegistry.shared.prune()
        let entries = PinRegistry.shared.entries.sorted { $0.pinnedAt < $1.pinnedAt }

        guard !entries.isEmpty else {
            let item = NSMenuItem(title: "No Pinned Windows".local, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for entry in entries {
            let name = [entry.appName, entry.title].filter { !$0.isEmpty }.joined(separator: " — ")
            let item = NSMenuItem(title: "\(name) · \(entry.mode.displayName)",
                                  action: #selector(unpinFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            // `windowID` is a UInt32; `tag` is an Int, but only for backwards compatibility with
            // tag-based lookups — `representedObject` carries the id without truncation risk.
            item.representedObject = entry.id
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let unpinAll = NSMenuItem(title: "Unpin All Pinned Windows".local, action: #selector(unPinAll), keyEquivalent: "")
        unpinAll.target = self
        menu.addItem(unpinAll)
    }

    @objc func unpinFromMenu(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? CGWindowID,
              let mode = PinRegistry.shared.mode(for: windowID) else { return }
        PinActions.unpin(windowID: windowID, mode: mode)
    }
}

extension NSMenuItem {
    func performAction() {
        guard let menu else { return }
        menu.performActionForItem(at: menu.index(of: self))
    }
}

class NNSPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
}

class EscPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        self.close()
        WindowHighlighter.shared.stopMouseMonitor()
    }
    override var canBecomeKey: Bool {
        return true
    }
}

extension Scene {
    func myWindowIsContentResizable() -> some Scene {
        if #available(macOS 13.0, *) {
            return self.windowResizability(.contentSize)
        }
        else {
            return self
        }
    }
}

extension Bundle {
    var appName: String {
        let appName = self.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                     ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                     ?? "Unknown App Name"
        return appName
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension SCDisplay {
    var nsScreen: NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == self.displayID })
    }
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
}
