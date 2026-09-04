// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox

/// Field diagnosis for a click that never reaches a card — opted into with
/// `VORSSAINT_SNAP_ASSIST_DEBUG`, the same env var `WindowLayoutService`
/// already gates its own Snap Assist logging behind. Logs, for every
/// left-mouse-down this panel's `sendEvent` sees, the event's window-space
/// location, the panel's own frame, and what `hitTest` resolves that point
/// to — the one place that can distinguish "the window never got the
/// event" from "the window got it but routed it to the wrong view." Uses
/// `NSLog` rather than `Logger.debug`: `debug`-level `os.Logger` messages
/// are filtered out of `log stream` by default (a prior investigation on
/// this feature lost time to exactly that before finding `--level debug`),
/// and this diagnostic exists specifically to be grabbed off a running
/// process with the least ceremony possible.
private let snapAssistPanelDebugLogging =
    ProcessInfo.processInfo.environment["VORSSAINT_SNAP_ASSIST_DEBUG"] != nil

/// Borderless panels refuse key status by default, and this one genuinely
/// needs it — see `SnapAssistPanel`'s own doc comment for why a real
/// clickable panel needs a real key, activated window.
private final class KeyableSnapAssistPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        guard snapAssistPanelDebugLogging, event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }
        let windowPoint = event.locationInWindow
        let hit = contentView?.hitTest(windowPoint)
        let hitDescription = hit.map { String(describing: type(of: $0)) } ?? "nil"
        NSLog("[snap-assist-panel] sendEvent leftMouseDown windowPoint=\(windowPoint) " +
              "panelFrame=\(frame) contentViewFrame=\(String(describing: contentView?.frame)) " +
              "hitTest=\(hitDescription) isKeyWindow=\(isKeyWindow)")
        super.sendEvent(event)
    }
}

/// Owns the floating Snap Assist overlay on `WindowLayoutService`'s behalf
/// (spec §4): a dark translucent surface covering the free zone a snap just
/// left, filled with thumbnails of the other open windows, each a genuine
/// `NSButton` — a real `AXButton` with a real `AXPress` action.
///
/// This panel activates Vorssaint and takes real key status while it is
/// open, unlike `SnapLayoutsPanel` (which only ever draws a highlight while
/// the existing drag tap owns hover and release, and deliberately never
/// activates anything). Two earlier versions of both this panel and its
/// content tried to avoid that: a `.nonactivatingPanel` with `makeKey()`
/// plus a plain SwiftUI `Button`, and then the same panel with a hand-rolled
/// `NSView` hit test once the `Button` proved unreliable. Both passed a
/// synthetic-coordinate test harness, but Marco's own trackpad clicks on a
/// real Mac still selected nothing. A screenshot-driven re-test (real
/// clicks landing dead-center on a visible card) confirmed it was not a
/// geometry problem: the panel's owning app was never actually becoming the
/// frontmost application — `NSApp.activate(ignoringOtherApps:)` called from
/// deep inside an event-tap-driven call chain, for an `LSUIElement`
/// accessory app with no Dock presence, did not reliably transfer real
/// activation the way it does for a menu-bar shortcut's own direct handler
/// (`CommandBarService`, `ScratchpadService`). Without genuine activation, a
/// SwiftUI `Button`'s tap gesture — and, this rework found, that dependency
/// runs deeper than SwiftUI — never reliably fires for a real trackpad
/// click, only for `AXUIElementPerformAction`, which bypasses window-server
/// click delivery entirely. `SnapAssistContentView` (`SnapAssistPanelView.
/// swift`) replaces the whole SwiftUI tree with plain `NSButton`s instead,
/// whose click handling is native AppKit and does not depend on the owning
/// app being frontmost at all — only on the window being key, which
/// `makeKeyAndOrderFront` already grants a non-activating panel on its own.
/// Snap Assist is a modal-ish picker exactly like Windows' own — briefly
/// taking focus while it is open is acceptable (spec §4) even where it
/// turns out not to be load-bearing for the click itself — and
/// `WindowLayoutService` activates the placed window's app again right
/// after a pick, so focus lands where the person would expect it to next.
final class SnapAssistPanel {
    private var panel: KeyableSnapAssistPanel?
    private var contentView: SnapAssistContentView?
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var dismissTimer: Timer?
    /// Set right before `WindowLayoutService` activates the placed window's
    /// app after a pick, so the resulting `didResignKeyNotification` this
    /// panel's own window posts — activating any other app resigns key from
    /// whichever window currently holds it — is not mistaken for the person
    /// clicking away on their own. A time window, not a one-shot flag: that
    /// activation is requested asynchronously (`NSRunningApplication.
    /// activate`), so exactly when the resulting resign notification lands
    /// relative to a following `show()` call for the next free cell is not
    /// guaranteed.
    private var suppressResignDismissUntil: TimeInterval = 0
    private static let resignSuppressionWindow: TimeInterval = 1.0

    /// Fires once at the end of every `hide()` that actually closed a
    /// visible panel — Esc, a click outside (`didResignKeyNotification`),
    /// an app switch (the same notification), the inactivity timer, a
    /// screen-parameters change, or `WindowLayoutService` closing the
    /// overlay itself because a Snap Assist session ended. Never fires from
    /// `show()` re-filling an already-visible panel to advance to the next
    /// free cell, since that path never calls `hide()` at all — see
    /// `show`'s own doc comment. `WindowLayoutService` uses this as the
    /// single place its `snapAssistSession` is cleared, so a dismissal this
    /// panel notices on its own (Esc, losing key) ends the session exactly
    /// as reliably as one `WindowLayoutService` itself decided on.
    var onDismiss: (() -> Void)?

    /// Spec §4 point 4: eight seconds of inactivity closes the overlay and
    /// leaves the space free, the same as Esc or a click elsewhere.
    private static let inactivityTimeout: TimeInterval = 8
    static let padding: CGFloat = 16
    private static let footerHeight: CGFloat = 28
    private static let outerInset: CGFloat = 6
    static let itemSize = CGSize(width: 116, height: 92)
    static let spacing: CGFloat = 10
    static let maxColumns = 5

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the overlay covering `freeRect` (clamped to both `freeRect`
    /// itself and `screen.visibleFrame`, spec §9's "never past the screen")
    /// with `items` (already ordered most-recently-used first, spec §4
    /// point 1) and `hint` as its footer. `onSelect` fires on every pick —
    /// the caller decides whether that closes the overlay (a successful
    /// placement re-enters `handleSnapAssist`, which shows the next cell or
    /// hides) or leaves it open (a failed one, so the person can try
    /// another window).
    func show(in freeRect: CGRect,
             on screen: NSScreen,
             items: [SwitcherItem],
             hint: String,
             onSelect: @escaping (SwitcherItem) -> Void) {
        let (frame, columns) = layout(itemCount: items.count, freeRect: freeRect, visibleFrame: screen.visibleFrame)
        let panel = ensurePanel()
        let content = contentView ?? {
            let created = SnapAssistContentView(frame: .zero)
            self.contentView = created
            panel.contentView = created
            return created
        }()
        content.configure(items: items, columns: columns, hint: hint, onSelect: onSelect)

        panel.setFrame(frame, display: true)
        if snapAssistPanelDebugLogging {
            NSLog("[snap-assist-panel] show computedFrame=\(frame) panelFrameAfterSetFrame=\(panel.frame) " +
                  "contentViewFrame=\(String(describing: content.frame)) contentViewBounds=\(content.bounds) columns=\(columns) items=\(items.count)")
        }
        assert(!panel.ignoresMouseEvents,
              "SnapAssistPanel must always accept mouse events — a card that cannot be clicked is the whole bug this type exists to avoid")

        let wasVisible = panel.isVisible
        if !wasVisible {
            panel.alphaValue = 0
        }
        // `orderFrontRegardless()` first: it takes effect synchronously,
        // independent of app activation, so the window server already
        // considers this panel the frontmost window at this screen
        // location before anything else runs. `NSApp.activate` (real
        // activation, not just `makeKey()`; see the type's own doc comment
        // for the real-Mac finding that made that necessary) and
        // `makeKeyAndOrderFront` still follow, but a click landing in the
        // gap between this call returning and activation actually
        // completing now still hits this window, not whatever used to be
        // frontmost underneath the free zone (e.g. the desktop) — the
        // "click reached the wallpaper and triggered Show Desktop" failure
        // mode a real-Mac report found.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        installMonitors(for: panel)
        resetDismissTimer()
    }

    /// A thumbnail landed for one of the offered windows; called from
    /// `WindowPreviewProvider.refreshPreviews`'s update callback.
    func updatePreview(_ image: CGImage, for windowID: CGWindowID) {
        contentView?.updatePreview(image, for: windowID)
    }

    /// See `suppressResignDismissUntil`'s doc comment. Called by
    /// `WindowLayoutService` immediately before it activates a picked
    /// window's app.
    func ignorePendingResign() {
        suppressResignDismissUntil = ProcessInfo.processInfo.systemUptime + Self.resignSuppressionWindow
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        onDismiss?()
    }

    /// The panel's frame for `itemCount` items covering `freeRect`, and the
    /// fixed column count it was sized for: `columnCount` first picks how
    /// many columns fit `freeRect` (intersected with `visibleFrame`, so a
    /// free zone that pokes past a screen edge — a stale read mid
    /// reconfiguration — never grows the panel past it), `contentSize` then
    /// says how big that grid actually is, and the panel is inset a little
    /// so it reads as covering the zone rather than flush with its very
    /// edge. Never bigger than the zone it covers, never smaller than one
    /// row, and always finally clamped inside `visibleFrame` itself.
    private func layout(itemCount: Int, freeRect: CGRect, visibleFrame: CGRect) -> (frame: CGRect, columns: Int) {
        let bounds = freeRect.intersection(visibleFrame)
        let usableBounds = bounds.isNull || bounds.isEmpty ? freeRect : bounds
        let availableWidth = max(Self.itemSize.width, usableBounds.width - Self.outerInset * 2)
        let columns = SnapAssistSupport.columnCount(count: itemCount,
                                                    boundsWidth: availableWidth,
                                                    itemWidth: Self.itemSize.width,
                                                    spacing: Self.spacing,
                                                    maxColumns: Self.maxColumns)
        let content = SnapAssistSupport.contentSize(count: itemCount,
                                                    columns: columns,
                                                    itemSize: Self.itemSize,
                                                    spacing: Self.spacing,
                                                    padding: Self.padding)
        let maxHeight = max(Self.itemSize.height + Self.padding * 2 + Self.footerHeight,
                            usableBounds.height - Self.outerInset * 2)
        let width = min(max(content.width, Self.itemSize.width + Self.padding * 2), availableWidth)
        let height = min(content.height + Self.footerHeight, maxHeight)
        var frame = CGRect(x: usableBounds.midX - width / 2,
                           y: usableBounds.midY - height / 2,
                           width: width,
                           height: height)
        // A last clamp inside the screen's own visible frame: `usableBounds`
        // already sits inside it, but a panel wider or taller than the zone
        // (the one-row/one-column minimum above) can still poke past the
        // screen at its very edge.
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - frame.height))
        return (frame.integral, columns)
    }

    private func ensurePanel() -> KeyableSnapAssistPanel {
        if let panel { return panel }
        let panel = KeyableSnapAssistPanel(contentRect: .zero,
                                           styleMask: [.borderless],
                                           backing: .buffered,
                                           defer: false)
        panel.title = "Vorssaint"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.acceptsMouseMovedEvents = true
        // Explicit, not just the AppKit default: a click on any card must
        // never pass through to whatever sits behind the panel.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func resetDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.inactivityTimeout, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    // MARK: - Dismissal

    private func installMonitors(for panel: NSPanel) {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isKeyWindow else { return event }
            self.resetDismissTimer()
            if event.keyCode == UInt16(kVK_Escape) {
                self.hide()
                return nil
            }
            return event
        }
        // A real, key, activating panel makes "clicked elsewhere" and
        // "switched app" the same event AppKit already tells every window
        // about on its own: losing key status. No click monitor of any
        // kind is needed to reconstruct that.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime < self.suppressResignDismissUntil { return }
            self.hide()
        }
        // A display reconfiguration (unplugged, resolution change, a
        // reshuffled arrangement) can move or invalidate the very screen
        // the free zone was computed against — the overlay would otherwise
        // sit over stale geometry, or over nothing at all.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
        screenParametersObserver = nil
    }
}
