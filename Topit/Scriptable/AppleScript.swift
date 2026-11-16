//
//  AppleScript.swift
//  Topit
//
//  Created by apple on 2024/12/1.
//

import AppKit
import Foundation

class selectWindow: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        WindowHighlighter.shared.registerMouseMonitor()
    }
}

class showSelector: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        AppDelegate.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    }
}

class pnpFront: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { pnpFrontmostWindow() }
}

class pnpMouse: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { pnpUnderMouseWindow() }
}

class unpinAllWindows: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Fork: route through PinActions so AppleScript also unpins native pins — this used to
        // duplicate AppDelegate.unPinAll's mirror-only implementation.
        DispatchQueue.main.async { PinActions.unpinAll() }
    }
}
