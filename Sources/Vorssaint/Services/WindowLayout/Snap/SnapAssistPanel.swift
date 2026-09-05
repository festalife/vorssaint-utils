// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox


/// Borderless panels refuse key status by default, and this one genuinely
/// needs it — see `SnapAssistPanel`'s own doc comment for why a real
/// clickable panel needs a real key, activated window.
private final class KeyableSnapAssistPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Set for the duration of a left-button press that started inside
    /// this panel — `SnapAssistPanel.hide` consults it so a
    /// `didResignKeyNotification` that lands mid-click (a real-Mac report
    /// found one arriving between mouseDown and the click's own mouseUp,
    /// closing the overlay before the pick could run) never dismisses
    /// while the very click that is supposed to pick a card is still in
    /// flight.
    fileprivate var isLeftMouseDownInside = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isLeftMouseDownInside = true
            let windowPoint = event.locationInWindow
            let hit = contentView?.hitTest(windowPoint)
            let hitDescription = hit.map { String(describing: type(of: $0)) } ?? "nil"
            SnapLog.event("assist.panel-down",
                          "at=\(SnapLog.point(windowPoint)) hit=\(hitDescription) key=\(self.isKeyWindow)")
        case .leftMouseUp:
            isLeftMouseDownInside = false
            // Independent of key/activation state and of whether the
            // NSButton's own mouseDown/mouseUp tracking loop happened to
            // recognize this click as its own (a real-Mac report found
            // clicks that reached this window still not picking a card):
            // hit-test the button hierarchy directly and fire its
            // selection ourselves. `SnapAssistCardButton.triggerSelect`
            // is itself guarded against the NSButton action ALSO firing
            // for the same physical click, so doing both here is safe.
            let windowPoint = event.locationInWindow
            if let button = contentView?.hitTest(windowPoint) as? SnapAssistCardButton {
                button.triggerSelect(eventNumber: event.eventNumber, source: "panel hit-test fallback")
            }
        default:
            break
        }
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

    /// When the panel last called `show()`. A real-Mac report found a
    /// `didResignKeyNotification` landing almost immediately after
    /// `orderFrontRegardless`/`activate`/`makeKeyAndOrderFront` — plausibly
    /// the tail of that very activation sequence bouncing key status once
    /// before it settles — which dismissed the overlay before the person's
    /// click could ever reach a card. `hide` ignores a resign inside this
    /// window from `show`, the same way it already ignores one inside
    /// `resignSuppressionWindow` from a pick's own re-activation.
    private var shownAt: TimeInterval = 0
    private static let resignAfterShowGracePeriod: TimeInterval = 0.5

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
    var onDismiss: ((String) -> Void)?

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
        SnapLog.event("assist.overlay-show",
                      "frame=\(SnapLog.rect(frame)) columns=\(columns) items=\(items.count)")
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
        // Again, after activation: `NSApp.activate` reorders this app's
        // windows against everyone else's, and the ordering that survives that
        // is the one a person actually sees. Called on every `show`, so
        // advancing to the next free cell re-raises the panel too rather than
        // trusting it to have stayed on top for the whole session.
        panel.orderFrontRegardless()
        SnapLog.event("assist.overlay-level",
                      "level=\(panel.level.rawValue) visible=\(panel.isVisible) key=\(panel.isKeyWindow) "
                          + "alpha=\(String(format: "%.2f", panel.alphaValue)) advanced=\(wasVisible)")
        shownAt = ProcessInfo.processInfo.systemUptime
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            } completionHandler: { [weak panel] in
                // Belt and braces: an overlay that is ordered correctly but
                // still fully transparent is indistinguishable, from the
                // person's side, from one that never appeared.
                guard let panel, panel.isVisible else { return }
                panel.alphaValue = 1
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

    func hide(reason: String = "closed by WindowLayoutService") {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeMonitors()
        guard let panel, panel.isVisible else {
            SnapLog.event("assist.overlay-hide-noop", "reason=\(reason)")
            return
        }
        SnapLog.event("assist.overlay-hide", "reason=\(reason)")
        panel.orderOut(nil)
        onDismiss?(reason)
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
        // Above every ordinary application window, unconditionally. A real
        // user report had the overlay open and logged over a right half that
        // happened to be covered by three other apps' windows, and never saw
        // it: it was ordered into the window list correctly but sat behind
        // them. Snap Assist covers the space it is offering, so anything that
        // can end up in front of it defeats the whole feature.
        // `.popUpMenu` rather than `.statusBar`, which the preview, the Snap
        // Layouts bar and the divider hint use: those only ever draw, while
        // this one has to be clickable, so it must be the topmost of the four
        // as well as above every app.
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        // Explicit, not just the AppKit default: a click on any card must
        // never pass through to whatever sits behind the panel.
        panel.ignoresMouseEvents = false
        // No `.ignoresCycle`: it says nothing about ordering and, on a panel
        // that genuinely takes key status, only muddies what the window
        // server is being told about a window that is meant to be in front.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func resetDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.inactivityTimeout, repeats: false) { [weak self] _ in
            self?.hide(reason: "inactivity timeout")
        }
    }

    // MARK: - Dismissal

    private func installMonitors(for panel: KeyableSnapAssistPanel) {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isKeyWindow else { return event }
            self.resetDismissTimer()
            if event.keyCode == UInt16(kVK_Escape) {
                self.hide(reason: "Esc")
                return nil
            }
            return event
        }
        // A real, key, activating panel makes "clicked elsewhere" and
        // "switched app" the same event AppKit already tells every window
        // about on its own: losing key status. No click monitor of any
        // kind is needed to reconstruct that. Three cases never dismiss
        // even though they resign key: a pick's own re-activation
        // (`suppressResignDismissUntil`, unchanged), a resign landing
        // inside `resignAfterShowGracePeriod` of this very `show()` (a
        // real-Mac report found one arriving almost immediately after
        // activation, before any click could land), and a resign while a
        // left-button press that started inside this panel is still down
        // (a resign mid-click must never cut the click off before its own
        // mouseUp — and therefore its pick — gets a chance to run).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now < self.suppressResignDismissUntil {
                SnapLog.event("assist.resign-ignored", "reason=pick-reactivation-window")
                return
            }
            if now - self.shownAt < Self.resignAfterShowGracePeriod {
                SnapLog.event("assist.resign-ignored", "reason=within-grace-of-show")
                return
            }
            if panel.isLeftMouseDownInside {
                SnapLog.event("assist.resign-ignored", "reason=click-still-in-flight")
                return
            }
            self.hide(reason: "resigned key (click outside or app switch)")
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
            self?.hide(reason: "screen parameters changed")
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
