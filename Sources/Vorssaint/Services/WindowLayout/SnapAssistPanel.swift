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
    var onSelect: ((SwitcherItem) -> Void)?
}

/// Borderless panels refuse key status by default; Esc needs it, and
/// `.nonactivatingPanel` already keeps `makeKey()` here from activating
/// Vorssaint itself or taking focus from the window that was just snapped —
/// the same trade RadialMenuService's `KeyableWheelPanel` makes.
private final class KeyableSnapAssistPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the floating Snap Assist overlay on `WindowLayoutService`'s behalf
/// (spec §4): a dark translucent surface covering the free zone a snap just
/// left, filled with thumbnails of the other open windows. Unlike
/// `SnapLayoutsPanel` — which only ever draws a highlight while the existing
/// drag tap tracks hover and release — this panel is genuinely clickable:
/// there is no drag in progress once a placement has already landed, so a
/// card's own `Button` handles the pick directly.
final class SnapAssistPanel {
    private var panel: KeyableSnapAssistPanel?
    private let state = SnapAssistPanelState()
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var dismissTimer: Timer?

    /// Spec §4 point 4: eight seconds of inactivity closes the overlay and
    /// leaves the space free, the same as Esc or a click elsewhere.
    private static let inactivityTimeout: TimeInterval = 8
    private static let padding: CGFloat = 16
    static let itemSize = CGSize(width: 116, height: 92)
    static let spacing: CGFloat = 10
    private static let maxColumns = 5

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the overlay covering `freeRect` with `items` (already ordered
    /// most-recently-used first, spec §4 point 1) and `hint` as its footer.
    /// `onSelect` fires once, immediately followed by the panel hiding
    /// itself — the caller decides what happens next (placing the window,
    /// and by re-entering the same success path, whether another free cell
    /// follows).
    func show(in freeRect: CGRect,
             items: [SwitcherItem],
             hint: String,
             onSelect: @escaping (SwitcherItem) -> Void) {
        state.items = items
        state.previews = state.previews.filter { id, _ in items.contains { $0.windowID == id } }
        state.hint = hint
        state.onSelect = { [weak self] item in
            self?.hide()
            onSelect(item)
        }

        let panel = ensurePanel()
        let frame = clampedFrame(covering: freeRect, itemCount: items.count)
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

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeMonitors()
        state.onSelect = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// A near-copy of the free rect, inset a little so the overlay reads as
    /// covering the zone rather than flush with its very edge, and never
    /// smaller than one row's worth of cards even if the zone itself is
    /// tighter than that — a person still needs somewhere to read the hint
    /// and click a card.
    private func clampedFrame(covering freeRect: CGRect, itemCount: Int) -> CGRect {
        let inset: CGFloat = 6
        let minimum = SnapAssistSupport.contentSize(count: max(1, itemCount),
                                                     columns: 1,
                                                     itemSize: Self.itemSize,
                                                     spacing: Self.spacing,
                                                     padding: Self.padding)
        let width = max(minimum.width, freeRect.width - inset * 2)
        let height = max(minimum.height + 28 /* hint footer */, freeRect.height - inset * 2)
        return CGRect(x: freeRect.midX - width / 2,
                     y: freeRect.midY - height / 2,
                     width: width,
                     height: height).integral
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
        panel.contentViewController = NSHostingController(rootView: SnapAssistPanelView(state: state))
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
            guard let self, let panel, event.window === panel else { return event }
            self.resetDismissTimer()
            if event.keyCode == UInt16(kVK_Escape) {
                self.hide()
                return nil
            }
            return event
        }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if event.window === panel {
                self.resetDismissTimer()
            } else if !Self.mouseIsInside(panel) {
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
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            self.hide()
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
    }
}
