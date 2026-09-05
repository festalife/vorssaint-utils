// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics

/// Every Accessibility read and write the snapping subsystem makes, in one
/// place, with explicit messaging timeouts on every element.
///
/// Two rules this type exists to enforce:
///
/// 1. **Never call in here from a CGEvent tap callback.** A tap callback runs
///    on the event delivery path; a synchronous AX round trip to a busy app
///    stalls every input event on the machine for as long as it takes.
///    `SnapController` forwards pointer events to itself and only touches
///    Accessibility once it is out of the callback.
/// 2. **Every element gets a timeout before it is used.** The system default
///    is measured in seconds. `Timeout.focused` (0.35s) is for the window the
///    person is actually interacting with, `Timeout.neighbour` (0.25s) for
///    background group members whose reads fan out several at a time. Both
///    were raised from an earlier, much tighter value that silently timed out
///    against Chromium/Electron apps and Finder under ordinary load — which
///    read from the outside exactly like "this member never resizes", while
///    a plain in-process Cocoa window such as TextEdit always answered fast
///    enough to look fine.
///
/// A read that times out is never proof of anything. Callers treat `nil` as
/// "not this round" and retry on the next one; nothing here ever evicts a
/// Snap Group member because one read did not land.
enum SnapAX {
    enum Timeout {
        /// The window being dragged, placed or hovered right now.
        static let focused: Float = 0.35
        /// A background Snap Group member, read as part of a fan-out.
        static let neighbour: Float = 0.25
    }

    /// The smallest window worth snapping at all — anything under this is a
    /// palette or a tool window, not something a layout applies to.
    static let minimumWindowSide: CGFloat = 80

    // MARK: - Coordinate space

    /// The `maxY` of whichever screen owns the menu bar: the fixed point
    /// Quartz (top-left origin) and AppKit (bottom-left origin) agree on.
    /// See `SnapCoordinates`, which does the actual arithmetic.
    static var menuBarTopY: CGFloat {
        let menuBarScreen = NSScreen.screens.first {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        }
        return (menuBarScreen ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    static func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        SnapCoordinates.appKitPoint(fromQuartz: point, menuBarTopY: menuBarTopY)
    }

    static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        SnapCoordinates.appKitRect(fromQuartz: rect, menuBarTopY: menuBarTopY)
    }

    static func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        SnapCoordinates.quartzRect(fromAppKit: rect, menuBarTopY: menuBarTopY)
    }

    // MARK: - Elements

    /// An application element with `timeout` already applied — never build one
    /// with `AXUIElementCreateApplication` directly anywhere in this
    /// subsystem, or the system default silently comes back.
    static func application(_ pid: pid_t, timeout: Float) -> AXUIElement {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, timeout)
        return axApp
    }

    /// The window element for `windowID` inside `axApp`, with `timeout`
    /// applied to the window element too — every later read or write through
    /// it is bounded, not just the lookup.
    static func window(_ windowID: CGWindowID, in axApp: AXUIElement, timeout: Float) -> AXUIElement? {
        guard let element = windows(of: axApp)?.first(where: { AXWindowResolver.windowID(for: $0) == windowID })
        else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// `window(_:in:timeout:)` retried once on a nil answer — cheap, since the
    /// app's AX tree is already warm from the first attempt, and enough to
    /// smooth over an Electron window that briefly lags behind its own
    /// reported geometry.
    static func windowRetrying(_ windowID: CGWindowID, in axApp: AXUIElement, timeout: Float) -> AXUIElement? {
        window(windowID, in: axApp, timeout: timeout) ?? window(windowID, in: axApp, timeout: timeout)
    }

    static func windows(of element: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) == .success
        else { return nil }
        return raw as? [AXUIElement]
    }

    static func windowAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    // MARK: - Attributes

    static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as String)
    }

    static func subrole(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXSubroleAttribute as String)
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        boolAttribute(element, kAXMinimizedAttribute as String)
    }

    static func canSetFrame(on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let position = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success
            && settable.boolValue
        settable = DarwinBoolean(false)
        let size = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
        return position && size
    }

    // MARK: - Frames

    /// `element`'s frame in Quartz space (top-left origin), or `nil` when
    /// either half of the read did not land.
    static func quartzFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, kAXPositionAttribute as String),
              let size = sizeAttribute(element, kAXSizeAttribute as String)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// `element`'s frame in AppKit space — what every geometry decision in
    /// this subsystem works in.
    static func frame(of element: AXUIElement) -> CGRect? {
        quartzFrame(of: element).map(appKitRect(fromQuartz:))
    }

    /// `frame(of:)` retried once on a nil answer, for the same reason
    /// `windowRetrying` exists.
    static func frameRetrying(of element: AXUIElement) -> CGRect? {
        frame(of: element) ?? frame(of: element)
    }

    /// Writes `rect` (AppKit space) and reads back what was actually
    /// accepted.
    ///
    /// Size first, then position, and the position is the one derived from the
    /// requested size — a window anchored to a far screen edge (a right half,
    /// a bottom quarter) is then never asked for an origin that belongs to a
    /// different width. The two attributes still land independently and
    /// asynchronously, so the returned frame may show one and not the other:
    /// callers must check `SnapGroupSupport.writeLanded` before concluding
    /// anything from it, never the immediate read-back alone.
    ///
    /// Reading back is also the only way to discover an app-enforced minimum
    /// size, which Accessibility exposes no way to query up front. `nil` means
    /// the read itself failed, so nothing is known about what landed either:
    /// callers treat that as "unreachable this pass", never as success.
    @discardableResult
    static func setFrame(_ rect: CGRect, on element: AXUIElement) -> CGRect? {
        let axRect = quartzRect(fromAppKit: rect)
        var size = axRect.size
        var origin = axRect.origin
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        return frame(of: element)
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Window server

    /// One window as the window server reports it — ground truth for "what is
    /// actually on screen", independent of any Accessibility answer.
    struct ServerWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        /// Quartz space, straight from `kCGWindowBounds`.
        let quartzFrame: CGRect
        /// The same rectangle in AppKit space.
        let appKitFrame: CGRect
    }

    /// Every real, layer-0 window currently on screen. `screen` filters to the
    /// ones overlapping that display.
    static func onScreenWindows(on screen: NSScreen? = nil) -> [ServerWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let topY = menuBarTopY
        return raw.compactMap { info -> ServerWindow? in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzFrame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let appKit = SnapCoordinates.appKitRect(fromQuartz: quartzFrame, menuBarTopY: topY)
            if let screen, !screen.frame.intersects(appKit) { return nil }
            return ServerWindow(windowID: windowID, ownerPID: ownerPID,
                                quartzFrame: quartzFrame, appKitFrame: appKit)
        }
    }

    /// Owning pid for every window the window server knows about, on screen or
    /// not. One scan, reused by every caller that needs several lookups —
    /// a pid is never cached across calls, since a relaunched app can reuse
    /// one.
    static func ownerPIDs() -> [CGWindowID: pid_t] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var result: [CGWindowID: pid_t] = [:]
        for info in raw {
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { continue }
            result[windowID] = pid
        }
        return result
    }

    static func allWindowIDs() -> Set<CGWindowID> {
        Set(ownerPIDs().keys)
    }

    /// Whether `element` is a window a placement could actually be written to:
    /// a real window (not a sheet or a floating palette), big enough to be
    /// worth tiling, and genuinely resizable. `allowMinimized` is for Snap
    /// Assist's minimized candidates only (spec §4 point 2) — `canSetFrame`
    /// is skipped for those, since it is not a reliable predictor while a
    /// window is minimized and the pick un-minimizes before writing anything.
    static func isPlaceableWindow(_ element: AXUIElement, allowMinimized: Bool = false) -> Bool {
        guard role(of: element) == (kAXWindowRole as String),
              allowMinimized || !isMinimized(element),
              subrole(of: element) != "AXFloatingWindow",
              let frame = quartzFrame(of: element),
              frame.width > minimumWindowSide,
              frame.height > minimumWindowSide
        else { return false }
        return allowMinimized || canSetFrame(on: element)
    }
}
