// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The state the SwiftUI overlay reflects: which windows to offer, their
/// thumbnails as they stream in, and the hint text under the title. The
/// event tap and Accessibility work all happen in `WindowLayoutService` and
/// `SnapAssistPanel`; the view only ever reads this, per "UI observes
/// services" (`CONTRIBUTING.md`).
final class SnapAssistPanelState: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var previews: [CGWindowID: CGImage] = [:]
    @Published var hint: String = ""
    /// The fixed column count the panel's own frame was sized for
    /// (`SnapAssistPanel.layout`). The view uses this exact number rather
    /// than an adaptive grid, so the space the panel reserves and the grid
    /// it draws can never disagree.
    @Published var columns: Int = 1
    var onSelect: ((SwitcherItem) -> Void)?
}

/// Borderless panels refuse key status by default; Esc needs it, and
/// `.nonactivatingPanel` already keeps `makeKey()` here from activating
/// Vorssaint itself or taking focus from the window that was just snapped —
/// the same trade RadialMenuService's `KeyableWheelPanel` makes.
private final class KeyableSnapAssistPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// `acceptsFirstMouse` on the whole content view, in addition to
/// `SnapAssistCardClickCatcher`'s own override on each card: belt and
/// suspenders for the same "non-activating, momentarily-not-key panel"
/// class of first-click loss every other genuinely clickable panel in this
/// codebase (`CommandBarView`, `ClipboardHistoryService`,
/// `ScratchpadView`, `ShelfTilesView`, …) already guards against on
/// whichever of their subviews actually receives the click.
private final class SnapAssistHostingView: NSHostingView<SnapAssistPanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the floating Snap Assist overlay on `WindowLayoutService`'s behalf
/// (spec §4): a dark translucent surface covering the free zone a snap just
/// left, filled with thumbnails of the other open windows. Unlike
/// `SnapLayoutsPanel` — which only ever draws a highlight while the existing
/// drag tap tracks hover and release — this panel is genuinely clickable:
/// there is no drag in progress once a placement has already landed, so
/// each card's own `SnapAssistCardClickCatcher` handles the pick directly.
final class SnapAssistPanel {
    private var panel: KeyableSnapAssistPanel?
    private let state = SnapAssistPanelState()
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var dismissTimer: Timer?
    /// Set right before `WindowLayoutService` activates a candidate's app
    /// itself, so the `didActivateApplicationNotification`(s) that
    /// activation posts are not mistaken for the person switching away —
    /// which would otherwise close the overlay (and defeat "try another
    /// window" on a failed placement, spec §4 point 4) the instant a pick
    /// is made, before the placement it triggered even has a result yet.
    /// A time window, not a one-shot flag: real-Mac testing found the very
    /// first pick closing the overlay before its placement even ran, which
    /// a single "ignore exactly the next notification" flag cannot protect
    /// against if more than one activation-related notification arrives
    /// (the app itself, then one of its windows, in either order) — every
    /// notification inside the window is ignored instead.
    private var suppressActivationDismissUntil: TimeInterval = 0
    private static let activationSuppressionWindow: TimeInterval = 1.0
    /// The app that owns the window `show` was just called for — the one
    /// that started this whole placement, by dragging its own title bar or
    /// otherwise. That drag or shortcut can itself activate the app (it may
    /// not have been frontmost to begin with), and that activation
    /// notification is not guaranteed to arrive before `show` — on a real
    /// Mac it arrived just after, and with no suppression armed yet at
    /// panel-open time (only `ignoreNextAppActivation`, called before a
    /// *candidate pick*, ever armed one) it read as the person switching
    /// away and closed the overlay within about a second of it appearing.
    /// This app's own activation is therefore never treated as a dismissal
    /// at all, for as long as it stays the current owner (until the next
    /// `show` names a different one).
    private var ignoredOwnerPID: pid_t?
    /// Belt and suspenders alongside `ignoredOwnerPID`: no activation of
    /// *any* app is treated as a dismissal until the panel has been showing
    /// this content for this long, so any other activation still settling
    /// from the gesture that opened the overlay — not necessarily the
    /// owner's — has time to arrive first.
    private var dismissArmedAt: TimeInterval = 0
    private static let dismissArmDelay: TimeInterval = 0.3

    /// Spec §4 point 4: eight seconds of inactivity closes the overlay and
    /// leaves the space free, the same as Esc or a click elsewhere.
    private static let inactivityTimeout: TimeInterval = 8
    private static let padding: CGFloat = 16
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
    /// placement re-enters `showSnapAssistIfNeeded`, which shows the next
    /// cell or hides) or leaves it open (a failed one, so the person can
    /// try another window).
    func show(in freeRect: CGRect,
             on screen: NSScreen,
             items: [SwitcherItem],
             hint: String,
             ignoringActivationOf ownerPID: pid_t,
             onSelect: @escaping (SwitcherItem) -> Void) {
        let (frame, columns) = layout(itemCount: items.count, freeRect: freeRect, visibleFrame: screen.visibleFrame)
        state.items = items
        state.previews = state.previews.filter { id, _ in items.contains { $0.windowID == id } }
        state.hint = hint
        state.columns = columns
        state.onSelect = onSelect
        ignoredOwnerPID = ownerPID
        dismissArmedAt = ProcessInfo.processInfo.systemUptime + Self.dismissArmDelay

        let panel = ensurePanel()
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.makeKey()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        installMonitors(for: panel)
        resetDismissTimer()
    }

    /// A thumbnail landed for one of the offered windows; called from
    /// `WindowPreviewProvider.refreshPreviews`'s update callback.
    func updatePreview(_ image: CGImage, for windowID: CGWindowID) {
        state.previews[windowID] = image
    }

    /// See `suppressActivationDismissUntil`'s doc comment. Called by
    /// `WindowLayoutService` immediately before it activates a chosen
    /// candidate's app.
    func ignoreNextAppActivation() {
        suppressActivationDismissUntil = ProcessInfo.processInfo.systemUptime + Self.activationSuppressionWindow
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeMonitors()
        state.onSelect = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// The panel's frame for `itemCount` items covering `freeRect`, and the
    /// fixed column count it was sized for: `columnCount` first picks how
    /// many columns fit `freeRect` (intersected with `visibleFrame`, so a
    /// free zone that pokes past a screen edge — a stale read mid
    /// reconfiguration — never grows the panel past it), `contentSize` then
    /// says how big that grid actually is, and the panel is inset a little
    /// so it reads as covering the zone rather than flush with its very
    /// edge. Never bigger than the zone it covers, never smaller than one
    /// row, and always finally clamped inside `visibleFrame` itself — the
    /// same size math the view's grid uses, so the two can never disagree
    /// (unlike an earlier version of this method, which sized the panel by
    /// a single always-one-column estimate while the view laid out an
    /// unrelated adaptive grid of its own).
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
                                           styleMask: [.borderless, .nonactivatingPanel],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let hostingView = SnapAssistHostingView(rootView: SnapAssistPanelView(state: state))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
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
        // Geometric containment, not `event.window === panel`: a click
        // physically over the panel is what matters, and checking identity
        // against `.window` instead was found, on a real Mac, to treat a
        // genuine click on a card as "outside" — closing the overlay before
        // the click ever reached the card underneath (`event.window` is not
        // dependable for every path an event can take to a borderless,
        // non-activating panel's own subviews). `NSEvent.mouseLocation` is
        // the authoritative screen position for a local monitor's own event
        // regardless of which window AppKit happens to have attributed it
        // to.
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if Self.mouseIsInside(panel) {
                self.resetDismissTimer()
            } else {
                self.hide()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return }
            if event.windowNumber != panel.windowNumber, !Self.mouseIsInside(panel) {
                self.hide()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.processIdentifier != self.ignoredOwnerPID
            else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now < self.suppressActivationDismissUntil || now < self.dismissArmedAt {
                return
            }
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

    private static func mouseIsInside(_ panel: NSPanel) -> Bool {
        panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
        screenParametersObserver = nil
    }
}
