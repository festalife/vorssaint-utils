// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// What `SnapController` needs from `WindowLayoutService` to actually move a
/// window. Every placement still goes through the service's own settling and
/// recovery path — there is deliberately no second AX mutation algorithm in
/// this subsystem.
protocol SnapPlacementHost: AnyObject {
    /// The window a keyboard- or menu-initiated action would act on.
    func snapFocusedTarget(for action: WindowLayoutAction) -> WindowLayoutTarget?

    /// An arbitrary window, by id — Snap Assist candidates and the dragged
    /// window both resolve through here. `allowOffScreen` relaxes the
    /// "already on screen" check for a window just brought back from
    /// minimized, which has not necessarily reported itself on screen yet.
    func snapTarget(windowID: CGWindowID,
                    pid: pid_t,
                    capability: WindowLayoutTargetCapability,
                    allowOffScreen: Bool) -> WindowLayoutTarget?

    /// Writes the placement. Returns whether it succeeded — including the
    /// "the window was already exactly there" case, which counts as success
    /// and still runs the whole post-placement pipeline.
    @discardableResult
    func snapApplyPlacement(_ action: WindowLayoutAction,
                            to target: WindowLayoutTarget,
                            visibleFrame: NSRect,
                            historyFrame: WindowLayoutFrame?,
                            cyclesRepeatedAction: Bool,
                            origin: SnapPlacementOrigin) -> Bool
}

/// The whole Windows-11-style snapping layer, as one object with one explicit
/// state machine (`SnapStateMachine`), one Snap Group store, and one log
/// channel.
///
/// **Log vocabulary** — every line is `snap.<area>.<event>`, at `.default`
/// level, in category `snap`:
///
/// | Prefix | Covers |
/// |---|---|
/// | `state` | every `SnapStateMachine` transition, with the reason |
/// | `drag` | press armed/rejected, drag confirmed, target changes, cancel |
/// | `preview` | the translucent zone rectangle showing/hiding |
/// | `layouts` | the top-edge bar and the zoom-button flyout |
/// | `divider` | the seam hint bar |
/// | `place` | a placement requested, landed, or refused, and by whom |
/// | `group` | Snap Group join/leave/prune/reflow and the live frame sweep |
/// | `free` | free-space substitution (spec §5) |
/// | `assist` | session start/skip, overlay present, pick, advance, dismiss |
/// | `link` | linked-resize watching, notifications, adjustments, writes |
/// | `restore` | drag-away restore to the pre-snap size |
///
/// `log show --last 5m --predicate 'category == "snap"'` therefore reads as a
/// transcript: what the pointer did, what was decided, and — for every early
/// return — why, with the frames and cell lists the decision was made from.
final class SnapController {
    static let shared = SnapController()

    weak var host: SnapPlacementHost?

    // MARK: - State

    private var machine = SnapStateMachine()
    /// Set while `transition` is closing the Snap Assist panel, so the
    /// panel's own `onDismiss` cannot re-enter the machine.
    private var isLeavingAssist = false

    /// Snap Group membership, live frames and linked resize — everything that
    /// remembers *where windows are*, kept out of this file so what is left
    /// here is only what reacts to the pointer.
    let groups = SnapGroupStore()

    // Drag tracking.
    private var pressOrigin: CGPoint?
    private var pressCandidate: WindowServerWindowCandidate?
    private var sequenceSuppressed = false
    private var resolveAttempts = 0
    private var lastResolveAt: TimeInterval = 0
    private var drag: SnapEdgeDrag?
    private var sequenceGeneration = 0
    private let dragSampleInterval: TimeInterval = 1.0 / 30.0

    // Panels.
    private var previewPanel: NSPanel?
    private var previewGeneration = 0
    private var previewScheduleGeneration: UInt64 = 0
    private var layoutsPanel: SnapLayoutsPanel?
    private var layoutsScreen: WindowEdgeSnapScreen?
    private var assistPanel: SnapAssistPanel?
    private var dividerPanel: NSPanel?

    // Zoom-button hover (spec §3/§12).
    private var zoomHoverButton: ZoomHoverButton?
    private var zoomHoverCacheAt: TimeInterval = 0
    private var zoomHoverSampleAt: TimeInterval = 0
    private var zoomHoverStartedAt: TimeInterval?
    private var zoomHoverPanelOpen = false
    private var zoomHoverSuppressedUntilLeave = false
    private var zoomHoverPresets: [SnapLayoutPreset] = []

    // Divider hint (spec §6/§12).
    private var dividerHintVisible = false
    private var dividerHintStartedAt: TimeInterval?
    private var dividerHintCached: SnapDividerHintSupport.DividerHint?
    private var dividerHintSampleAt: TimeInterval = 0

    // Cached "is this toggle on" answers, refreshed at most once a second —
    // the reads are cheap individually but not at `mouseMoved` rates.
    private var hoverGatesCache: (zoom: Bool, divider: Bool) = (false, false)
    private var hoverGatesCacheAt: TimeInterval = 0

    private static let previewDelay: TimeInterval = 0.15
    private static let hoverGatesTTL: TimeInterval = 1.0
    private static let zoomHoverSampleInterval: TimeInterval = 1.0 / 20.0
    private static let zoomHoverCacheTTL: TimeInterval = 0.5
    /// Short on purpose: macOS's own zoom-button menu appeared after ~1s
    /// on-device, and our panel has to win that race or not appear at all.
    private static let zoomHoverDwell: TimeInterval = 0.3
    /// A little under where the native menu showed up. Past this the panel is
    /// force-hidden and does not re-arm until the pointer leaves the button,
    /// so the two are never on screen together.
    private static let zoomHoverAutoHide: TimeInterval = 0.9
    private static let dividerHintSampleInterval: TimeInterval = 1.0 / 20.0
    private static let dividerHintDwell: TimeInterval = 0.15
    private static let dividerHintTolerance: CGFloat = 6

    private init() {
        groups.onLayoutReshaped = { [weak self] reason in
            guard let self else { return }
            // Spec §4: reshaping the layout by hand is "another action" — the
            // overlay is offering a cell that may no longer be right.
            self.hideAssist(reason: reason)
        }
    }

    // MARK: - Lifecycle

    /// Called from `WindowLayoutService.syncWithPreferences()`. Everything
    /// this subsystem runs on its own (the AX observers) is started or stopped
    /// here; every panel and timer is owned by a phase and torn down with it.
    func syncWithPreferences() {
        groups.syncWatcher(enabled: linkedResizeEnabled)
    }

    /// Stops everything before Accessibility is revoked or the process exits.
    /// Idempotent.
    func suspend() {
        SnapLog.event("state.suspend", "phase=\(machine.phase.name) groups=\(groups.groupCount)")
        transition(.reset(reason: "suspended"))
        groups.suspend()
        cancelTracking(reason: "suspended")
        hideAssist(reason: "suspended")
        hideLayoutsPanel()
        cancelZoomHover()
        cancelDividerHint()
        hidePreview(immediately: true)
        previewPanel = nil
        layoutsPanel = nil
        dividerPanel = nil
    }

    /// The edge-snap event tap just started. Nothing to arm — every surface
    /// here is created on demand — but it bookends the log.
    func tapStarted() {
        SnapLog.event("tap.start")
        // The tap starts when the feature is switched on and when
        // Accessibility is granted, which are exactly the moments any
        // membership still on record is from a different world. Windows
        // snapped before a settings flip must never come back as neighbours.
        groups.resetAll(reason: "edge-snap tap started")
    }

    /// The tap was torn down, so no pointer event can arrive any more: every
    /// pointer-driven surface closes and every tracking state resets.
    func tapStopped() {
        cancelTracking(reason: "edge-snap tap stopped")
        cancelZoomHover()
        cancelDividerHint()
        hidePreview(immediately: true)
        SnapLog.event("tap.stop")
    }

    // MARK: - State machine

    /// Applies one event, logs the result, and — the single rule that keeps
    /// the overlay from ever outliving its own phase — closes the Snap Assist
    /// panel whenever the machine leaves `.assisting` for any reason at all,
    /// including a fresh drag superseding it (spec §9's "doppia richiesta").
    /// Nothing else anywhere hides that panel on a phase change, so the two
    /// cannot drift apart.
    @discardableResult
    private func transition(_ event: SnapEvent) -> SnapPhase {
        let result = machine.apply(event)
        if result.changed {
            SnapLog.event("state", "\(result.from.name) -> \(result.to.name) reason=\(result.reason)")
        } else {
            SnapLog.event("state.hold", "\(result.from.name) reason=\(result.reason)")
        }
        if case .assisting = result.from, !isLeavingAssist {
            if case .assisting = result.to {} else {
                // The panel's own dismissal calls back in here; the flag stops
                // that from re-entering as a second, meaningless transition.
                isLeavingAssist = true
                assistPanel?.hide(reason: result.reason)
                isLeavingAssist = false
            }
        }
        return result.to
    }

    // MARK: - Preferences

    private var edgeSnapEnabled: Bool {
        AppFeature.windowLayout.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled)
            && !WindowEdgeSnapSupport.isSystemTilingEnabled
            && AXIsProcessTrusted()
    }

    private var earlyEdgeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapEarlyEdge)
    }

    private var layoutsEnabled: Bool {
        edgeSnapEnabled && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLayoutsEnabled)
    }

    private var fillsFreeSpaceEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapFillsFreeSpace)
    }

    private var restoreOnDragEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapRestoreSizeOnDrag)
    }

    private var linkedResizeEnabled: Bool {
        AppFeature.windowLayout.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLinkedResizeEnabled)
            && AXIsProcessTrusted()
    }

    /// `.ask` opens the overlay, `.auto` fills the first free cell straight
    /// away, `.off` does nothing. `synchronize()` first because this key is
    /// routinely flipped from outside the process (`defaults write`) while
    /// testing, unlike every other Window Layout toggle.
    private var assistMode: SnapAssistSupport.Mode {
        UserDefaults.standard.synchronize()
        return SnapAssistSupport.Mode.resolved(
            storedRawValue: UserDefaults.standard.string(forKey: DefaultsKey.windowSnapAssistMode),
            legacyEnabled: UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapAssistEnabled))
    }

    /// Spec §3/§12. Read with `object(forKey:)`, never `bool(forKey:)`: the
    /// key has no registered default, so this is the only way to tell "never
    /// written" from "written false" — which is exactly what the
    /// native-menu-aware default depends on. macOS 15+ shows its own menu on
    /// the green button, so the default there is off; an explicit choice
    /// always wins either way.
    private var zoomHoverEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: DefaultsKey.windowSnapLayoutsOnZoomButton) as? Bool
        let wanted = SnapLayoutPresets.zoomHoverDefaultEnabled(
            storedValue: stored,
            nativeMenuAvailable: WindowEdgeSnapSupport.isSystemZoomButtonHoverMenuAvailable)
        return AppFeature.windowLayout.isAvailable
            && wanted
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLayoutsEnabled)
            && AXIsProcessTrusted()
    }

    private var dividerHintEnabled: Bool {
        AppFeature.windowLayout.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapDividerHint)
            && AXIsProcessTrusted()
    }

    private func hoverGates(now: TimeInterval) -> (zoom: Bool, divider: Bool) {
        if now - hoverGatesCacheAt >= Self.hoverGatesTTL {
            hoverGatesCache = (zoomHoverEnabled, dividerHintEnabled)
            hoverGatesCacheAt = now
        }
        return hoverGatesCache
    }

    // MARK: - Pointer input (spec §1, §3, §12)
    //
    // Every entry point here runs on the main thread, dispatched out of
    // `WindowLayoutService`'s edge-snap CGEvent tap. Nothing in this section
    // is ever called from inside the tap callback itself except
    // `adjustedDragLocation`, which touches no Accessibility at all.

    /// The location the system should see for this drag event. Dragging to the
    /// physical top edge risks triggering macOS's own window overview, so the
    /// point the *system* sees is nudged by a point while Vorssaint keeps
    /// classifying the real one as "at the edge". Reads only cached scalars —
    /// safe to call from the tap callback.
    func adjustedDragLocation(_ location: CGPoint) -> CGPoint {
        guard let drag, drag.isMoving, drag.protectsSystemTopEdge else { return location }
        return WindowEdgeSnapSupport.locationAvoidingSystemTopDrag(location,
                                                                   screenFrames: drag.quartzScreenFrames)
    }

    /// Whether the tap should even bother dispatching: `false` suppresses the
    /// rest of a sequence that started while the system's own tiling was on.
    func beginPointerSequence() -> Bool {
        sequenceSuppressed = WindowEdgeSnapSupport.isSystemTilingEnabled
        if sequenceSuppressed {
            SnapLog.event("drag.arm-skip", "reason=macOS-tiling-enabled")
        }
        return !sequenceSuppressed
    }

    var isSequenceSuppressed: Bool { sequenceSuppressed }

    func endSuppressedSequence() {
        sequenceSuppressed = false
    }

    func handlePointerDown(atQuartz location: CGPoint, flags: CGEventFlags) {
        cancelTracking(reason: "new press")
        sequenceSuppressed = false
        guard edgeSnapEnabled else {
            sequenceSuppressed = true
            SnapLog.event("drag.arm-skip", "reason=edge-snap-disabled-or-untrusted")
            return
        }
        guard !conflictsWithWindowGesture(flags: flags) else {
            sequenceSuppressed = true
            SnapLog.event("drag.arm-skip", "reason=window-gesture-modifiers-held")
            return
        }
        guard let candidate = WindowServerWindowHitTest.candidate(at: location, pidIsEligible: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && app.activationPolicy == .regular
        }) else {
            sequenceSuppressed = true
            SnapLog.event("drag.arm-skip", "reason=no-window-under-pointer at=\(SnapLog.point(location))")
            return
        }
        guard !WindowEdgeSnapSupport.startsAtResizeHandle(location, frame: candidate.frame) else {
            sequenceSuppressed = true
            SnapLog.event("drag.arm-skip", "reason=press-on-resize-handle windowID=\(candidate.windowID)")
            return
        }
        pressOrigin = location
        pressCandidate = candidate
        resolveAttempts = 0
        lastResolveAt = 0
        SnapLog.event("drag.arm", "windowID=\(candidate.windowID) pid=\(candidate.pid) at=\(SnapLog.point(location))")
    }

    func handlePointerDragged(atQuartz location: CGPoint) {
        guard let pressOrigin, let pressCandidate else { return }
        if drag == nil, WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location) {
            let now = ProcessInfo.processInfo.systemUptime
            // Resolving the AX window can legitimately fail for the first
            // moments of a drag while the app is still settling; retried a
            // few times, spaced out, rather than giving up on the first miss.
            if resolveAttempts < 4, now - lastResolveAt >= 0.08 {
                resolveAttempts += 1
                lastResolveAt = now
                drag = makeDrag(pointerStart: pressOrigin, candidate: pressCandidate)
                if drag == nil {
                    SnapLog.event("drag.resolve-miss",
                                  "windowID=\(pressCandidate.windowID) attempt=\(resolveAttempts)")
                }
            }
        }
        updateDrag(at: location, forceSample: false)
    }

    func handlePointerUp(atQuartz location: CGPoint) {
        let origin = pressOrigin
        let candidate = pressCandidate
        if drag == nil, let origin, let candidate,
           WindowGestureSupport.exceedsDragSlop(from: origin, to: location) {
            drag = makeDrag(pointerStart: origin, candidate: candidate)
        }
        updateDrag(at: location, forceSample: true)

        let completed = drag
        pressOrigin = nil
        pressCandidate = nil
        resolveAttempts = 0
        drag = nil
        hidePreview(immediately: false)
        hideLayoutsPanel()
        let generation = sequenceGeneration

        guard let completed else {
            guard let origin, let candidate,
                  WindowGestureSupport.exceedsDragSlop(from: origin, to: location)
            else {
                transition(.dragEnded(reason: "release without a tracked drag"))
                return
            }
            // The window may only have caught up with the pointer after the
            // release; one more resolve attempt a frame later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, generation == self.sequenceGeneration,
                      let delayed = self.makeDrag(pointerStart: origin, candidate: candidate)
                else { return }
                self.applyIfStillMoving(delayed, releaseLocation: location)
            }
            return
        }

        guard completed.isMoving else {
            guard let origin, WindowGestureSupport.exceedsDragSlop(from: origin, to: location) else {
                transition(.dragEnded(reason: "release without movement"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, generation == self.sequenceGeneration else { return }
                self.applyIfStillMoving(completed, releaseLocation: location)
            }
            return
        }

        guard let target = completed.target else {
            transition(.dragEnded(reason: "release over open screen, no zone"))
            return
        }
        transition(.dragEnded(reason: "release on \(target.action)"))
        // The callback already forwarded this mouse-up; one more run-loop turn
        // lets the app finish its own drag before the final frame is written.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.sequenceGeneration else { return }
            self.applyDragPlacement(completed, target: target)
        }
    }

    /// The `mouseMoved` half of the tap: the zoom-button flyout and the
    /// divider hint, both throttled before anything else runs.
    func handlePointerMoved(atQuartz location: CGPoint) {
        handleZoomHover(atQuartz: location)
        handleDividerHint(atQuartz: location)
    }

    /// A press or release, forwarded independently of the drag state machine
    /// so a click on the hover-shown Snap Layouts flyout is handled even
    /// though no button is ever held to reach it.
    func handlePointerClickForZoomHover(atQuartz location: CGPoint, isDown: Bool) {
        guard !isDown, zoomHoverPanelOpen, let panel = layoutsPanel, let panelFrame = panel.frame else { return }
        let point = SnapAX.appKitPoint(fromQuartz: location)
        defer { cancelZoomHover() }
        guard let hit = SnapLayoutPresets.hit(at: point, presets: zoomHoverPresets, panelFrame: panelFrame) else {
            SnapLog.event("layouts.zoom-click", "outside every cell at=\(SnapLog.point(point))")
            return
        }
        guard let host, let target = host.snapFocusedTarget(for: hit.action) else {
            SnapLog.event("layouts.zoom-click", "cell=\(hit.action) but no focused window to place")
            return
        }
        guard let screen = screen(containing: SnapAX.appKitRect(fromQuartz: target.frame.cgRect)) else {
            SnapLog.event("layouts.zoom-click", "cell=\(hit.action) but no screen resolved")
            return
        }
        SnapLog.event("layouts.zoom-click", "cell=\(hit.action) windowID=\(target.windowID)")
        host.snapApplyPlacement(hit.action, to: target, visibleFrame: screen.visibleFrame,
                                historyFrame: nil, cyclesRepeatedAction: true, origin: .user)
    }

    func cancelTracking(reason: String) {
        sequenceGeneration += 1
        pressOrigin = nil
        pressCandidate = nil
        resolveAttempts = 0
        if drag != nil {
            SnapLog.event("drag.cancel", "reason=\(reason)")
            transition(.dragEnded(reason: reason))
        }
        drag = nil
        hidePreview(immediately: false)
        hideLayoutsPanel()
        cancelDividerHint()
    }

    /// Abandons the sequence and refuses the rest of it — used when the tap
    /// itself was disabled mid-drag.
    func abortSequence(reason: String) {
        cancelTracking(reason: reason)
        sequenceSuppressed = true
    }

    private func conflictsWithWindowGesture(flags: CGEventFlags) -> Bool {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureEnabled) else { return false }
        let move = WindowGestureSupport.modifiers(
            from: UserDefaults.standard.string(forKey: DefaultsKey.windowGestureModifiers))
        return WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: move)
            || WindowGestureSupport.modifiersMatch(eventFlags: flags,
                                                   expected: WindowGestureSupport.resizeModifiers(from: move))
    }

    private func makeDrag(pointerStart: CGPoint, candidate: WindowServerWindowCandidate) -> SnapEdgeDrag? {
        guard let host,
              let target = host.snapTarget(windowID: candidate.windowID, pid: candidate.pid,
                                           capability: .frame, allowOffScreen: false)
        else { return nil }
        return SnapEdgeDrag(window: target.window,
                            key: target.key,
                            initialFrame: candidate.frame,
                            pointerStart: pointerStart,
                            protectsSystemTopEdge: WindowEdgeSnapSupport.isSystemTopWindowOverviewDragEnabled,
                            quartzScreenFrames: quartzScreenFrames())
    }

    private func updateDrag(at location: CGPoint, forceSample: Bool) {
        guard var drag else { return }
        if !drag.isMoving {
            let now = ProcessInfo.processInfo.systemUptime
            guard forceSample || now - drag.lastSampleAt >= dragSampleInterval else { return }
            drag.lastSampleAt = now
            guard let current = SnapAX.quartzFrame(of: drag.window) else {
                self.drag = drag
                cancelTracking(reason: "dragged window stopped answering Accessibility")
                return
            }
            switch WindowEdgeSnapSupport.classify(initialFrame: drag.initialFrame,
                                                  currentFrame: current,
                                                  pointerStart: drag.pointerStart,
                                                  pointerNow: location) {
            case .waiting:
                self.drag = drag
                return
            case .resizing:
                self.drag = drag
                cancelTracking(reason: "gesture is a resize, not a move")
                return
            case .unrelated:
                drag.mismatchCount += 1
                self.drag = drag
                if drag.mismatchCount >= 3 {
                    cancelTracking(reason: "window is not following the pointer")
                }
                return
            case .moving:
                drag.isMoving = true
                drag.mismatchCount = 0
                self.drag = drag
                SnapLog.event("drag.begin", "windowID=\(drag.key.windowID) from=\(SnapLog.rect(drag.initialFrame))")
                transition(.dragBegan(windowID: drag.key.windowID))
            }
        }

        let target = resolvedTarget(atQuartz: location)
        guard target != drag.target else {
            self.drag = drag
            return
        }
        drag.target = target
        self.drag = drag
        transition(.dragTargetChanged(target?.action))
        // Bumped on every change, nil included: a fresh dwell always starts
        // over, so A→B→A inside the delay window never lets the first
        // scheduled A fire late and appear instantly.
        previewScheduleGeneration += 1
        guard let target else {
            hidePreview(immediately: false)
            return
        }
        schedulePreview(target)
    }

    private func applyIfStillMoving(_ drag: SnapEdgeDrag, releaseLocation: CGPoint) {
        guard let current = SnapAX.quartzFrame(of: drag.window),
              WindowEdgeSnapSupport.classify(initialFrame: drag.initialFrame,
                                             currentFrame: current,
                                             pointerStart: drag.pointerStart,
                                             pointerNow: releaseLocation) == .moving
        else {
            SnapLog.event("drag.late-skip", "windowID=\(drag.key.windowID) reason=window-never-moved")
            return
        }
        guard let raw = edgeTarget(atQuartz: releaseLocation) else {
            SnapLog.event("drag.late-skip", "windowID=\(drag.key.windowID) reason=no-zone-at-release")
            return
        }
        let target: WindowEdgeSnapTarget? = freeSpaceAdjustedTarget(raw, excluding: drag.key.windowID)
        guard let target else {
            SnapLog.event("drag.late-skip", "windowID=\(drag.key.windowID) reason=no-zone-at-release")
            return
        }
        applyDragPlacement(drag, target: target)
    }

    private func applyDragPlacement(_ drag: SnapEdgeDrag, target: WindowEdgeSnapTarget) {
        guard edgeSnapEnabled else {
            SnapLog.event("place.refuse", "reason=edge-snap-disabled windowID=\(drag.key.windowID)")
            return
        }
        guard SnapAX.canSetFrame(on: drag.window),
              AXWindowResolver.windowID(for: drag.window) == drag.key.windowID
        else {
            SnapLog.event("place.refuse", "reason=window-changed-or-not-resizable windowID=\(drag.key.windowID)")
            return
        }
        var pid = pid_t(0)
        guard AXUIElementGetPid(drag.window, &pid) == .success, pid == drag.key.processID else {
            SnapLog.event("place.refuse", "reason=pid-mismatch windowID=\(drag.key.windowID)")
            return
        }
        guard let currentFrame = SnapAX.quartzFrame(of: drag.window), let host else {
            SnapLog.event("place.refuse", "reason=no-current-frame windowID=\(drag.key.windowID)")
            return
        }
        let layoutTarget = WindowLayoutTarget(window: drag.window, key: drag.key,
                                              frame: WindowLayoutFrame(origin: currentFrame.origin,
                                                                       size: currentFrame.size))
        SnapLog.event("place.request",
                      "source=drag windowID=\(drag.key.windowID) action=\(target.action) rect=\(SnapLog.rect(target.frame))")
        host.snapApplyPlacement(target.action,
                                to: layoutTarget,
                                visibleFrame: target.visibleFrame,
                                historyFrame: WindowLayoutFrame(origin: drag.initialFrame.origin,
                                                                size: drag.initialFrame.size),
                                cyclesRepeatedAction: false,
                                origin: .user)
    }

    // MARK: - Target resolution

    /// The zone a release right now would apply — the classic edge/corner
    /// target, or whichever Snap Layouts cell the pointer is over — always
    /// passed through the free-space substitution, so the preview shows
    /// exactly the rectangle the release will write (spec §5).
    private func resolvedTarget(atQuartz location: CGPoint) -> WindowEdgeSnapTarget? {
        guard let raw = rawTarget(atQuartz: location) else { return nil }
        return freeSpaceAdjustedTarget(raw, excluding: drag?.key.windowID)
    }

    private func rawTarget(atQuartz location: CGPoint) -> WindowEdgeSnapTarget? {
        guard layoutsEnabled else {
            hideLayoutsPanel()
            return edgeTarget(atQuartz: location)
        }
        let point = SnapAX.appKitPoint(fromQuartz: location)

        // Opening the bar and keeping it open ask different questions: the
        // pointer has to leave the narrow top strip to reach the cards, so
        // once shown, reachability is decided against the panel itself.
        if let active = layoutsScreen,
           SnapLayoutPresets.shouldShowPanel(at: point,
                                             panelFrame: layoutsPanel?.frame,
                                             visibleFrame: active.visibleFrame,
                                             isCurrentlyShown: true) {
            return openPanelTarget(at: point, on: active)
        }
        guard let trigger = layoutsTriggerScreen(atQuartz: location) else {
            hideLayoutsPanel()
            return edgeTarget(atQuartz: location)
        }
        layoutsScreen = trigger
        showLayoutsPanel(on: trigger)
        return openPanelTarget(at: point, on: trigger)
    }

    private func edgeTarget(atQuartz location: CGPoint) -> WindowEdgeSnapTarget? {
        let point = SnapAX.appKitPoint(fromQuartz: location)
        let screens = NSScreen.screens.map { WindowEdgeSnapScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        // Spec §12: halves and corners activate early (a wider band) when the
        // preference is on; the top strip that opens the bar keeps the classic
        // distance either way.
        return WindowEdgeSnapSupport.target(
            at: point,
            screens: screens,
            distance: WindowEdgeSnapSupport.edgeActivationDistance(earlyEdgeEnabled: earlyEdgeEnabled),
            topDistance: WindowEdgeSnapSupport.activationDistance)
    }

    private func layoutsTriggerScreen(atQuartz location: CGPoint) -> WindowEdgeSnapScreen? {
        let point = SnapAX.appKitPoint(fromQuartz: location)
        let screens = NSScreen.screens.map { WindowEdgeSnapScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return WindowEdgeSnapSupport.snapLayoutsTriggerScreen(at: point, screens: screens)
    }

    /// While the bar is open: whichever cell is hovered, or — spec §1's
    /// "release outside the cells maximizes" — maximize, unless the pointer is
    /// still in a corner sub-zone, which keeps its classic corner target so
    /// the two never disagree at the corners.
    private func openPanelTarget(at point: CGPoint, on screen: WindowEdgeSnapScreen) -> WindowEdgeSnapTarget? {
        if let hovered = layoutsPanel?.updateHover(at: point, visibleFrame: screen.visibleFrame) {
            return hovered
        }
        let action = WindowEdgeSnapSupport.openPanelFallbackAction(at: point, screen: screen)
        let rect = WindowLayoutGeometry.rect(for: action,
                                             current: screen.visibleFrame,
                                             visibleFrame: screen.visibleFrame,
                                             windowGap: WindowLayoutGaps.windowGap,
                                             screenGap: WindowLayoutGaps.screenGap)
        return WindowEdgeSnapTarget(action: action, frame: rect.integral, visibleFrame: screen.visibleFrame)
    }

    /// `excluding` is the window this target is *for*: when it is already a
    /// Snap Group member (re-snapping it), its own old zone must never shrink
    /// its own new one. Passed explicitly rather than read from `drag`, which
    /// the late-release path has already cleared by the time it asks.
    private func freeSpaceAdjustedTarget(_ target: WindowEdgeSnapTarget,
                                         excluding windowID: CGWindowID?) -> WindowEdgeSnapTarget {
        let adjusted = freeSpace(for: target.action,
                                 theoreticalZone: target.frame,
                                 visibleFrame: target.visibleFrame,
                                 fallbackRect: target.frame,
                                 excluding: windowID)
        guard adjusted != target.frame else { return target }
        return WindowEdgeSnapTarget(action: target.action, frame: adjusted.integral, visibleFrame: target.visibleFrame)
    }

    private func quartzScreenFrames() -> [CGRect] {
        let top = SnapAX.menuBarTopY
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
    }

    // MARK: - Preview panel (spec §1)

    /// The directional gesture draws the same zone rectangle a drag does —
    /// one panel, one look, one code path.
    func showZonePreview(frame: CGRect, action: WindowLayoutAction) {
        showPreview(frame: frame, action: action)
    }

    func hideZonePreview(immediately: Bool) {
        hidePreview(immediately: immediately)
    }


    private func schedulePreview(_ target: WindowEdgeSnapTarget) {
        let generation = previewScheduleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay) { [weak self] in
            guard let self,
                  generation == self.previewScheduleGeneration,
                  self.drag?.target == target
            else { return }
            self.showPreview(frame: target.frame, action: target.action)
        }
    }

    private func showPreview(frame: CGRect, action: WindowLayoutAction) {
        previewGeneration += 1
        let panel = previewPanel ?? {
            let created = SnapController.makePreviewPanel()
            previewPanel = created
            return created
        }()
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        SnapLog.event("preview.show", "action=\(action) rect=\(SnapLog.rect(frame))")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePreview(immediately: Bool) {
        guard let panel = previewPanel, panel.isVisible else { return }
        previewGeneration += 1
        let generation = previewGeneration
        SnapLog.event("preview.hide", immediately ? "immediate" : "faded")
        if immediately {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel, generation == self.previewGeneration else { return }
            panel.orderOut(nil)
        }
    }

    private static func makePreviewPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = SnapPreviewView(frame: .zero)
        return panel
    }

    // MARK: - Snap Layouts bar (spec §3)

    private func showLayoutsPanel(on screen: WindowEdgeSnapScreen) {
        let presets = SnapLayoutPresets.availablePresets(for: screen.visibleFrame)
        let panel = layoutsPanel ?? {
            let created = SnapLayoutsPanel()
            layoutsPanel = created
            return created
        }()
        let wasVisible = panel.isVisible
        panel.show(visibleFrame: screen.visibleFrame, presets: presets)
        guard !wasVisible else { return }
        SnapLog.event("layouts.show", "trigger=top-edge presets=\(presets.count) screen=\(SnapLog.rect(screen.visibleFrame))")
        transition(.layoutsPanelChanged(true))
    }

    private func hideLayoutsPanel() {
        let wasVisible = layoutsPanel?.isVisible ?? false
        layoutsPanel?.hide()
        layoutsScreen = nil
        // Both triggers share one panel instance, so hiding it here must also
        // clear the hover trigger's idea of whether its panel is showing.
        zoomHoverPanelOpen = false
        guard wasVisible else { return }
        SnapLog.event("layouts.hide")
        // Only a drag has a phase to tell: the bar is also closed while idle
        // (a cancelled sequence, the tap stopping), and reporting that as an
        // ignored event would be noise in the transcript, not information.
        if case .dragging = machine.phase { transition(.layoutsPanelChanged(false)) }
    }

    // MARK: - Snap Layouts on zoom-button hover (spec §3/§12)

    private struct ZoomHoverButton {
        let windowID: CGWindowID
        /// AppKit space.
        let frame: CGRect
    }

    private func handleZoomHover(atQuartz location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - zoomHoverSampleAt >= Self.zoomHoverSampleInterval else { return }
        zoomHoverSampleAt = now

        guard hoverGates(now: now).zoom, drag == nil, pressOrigin == nil, layoutsScreen == nil else {
            cancelZoomHover()
            return
        }
        if zoomHoverButton == nil || now - zoomHoverCacheAt >= Self.zoomHoverCacheTTL {
            zoomHoverButton = resolveFocusedZoomButton()
            zoomHoverCacheAt = now
        }
        guard let button = zoomHoverButton else {
            cancelZoomHover()
            return
        }
        let point = SnapAX.appKitPoint(fromQuartz: location)
        guard button.frame.insetBy(dx: -4, dy: -4).contains(point) else {
            cancelZoomHover()
            return
        }
        guard !zoomHoverSuppressedUntilLeave else { return }
        if zoomHoverStartedAt == nil { zoomHoverStartedAt = now }
        guard let startedAt = zoomHoverStartedAt else { return }
        guard now - startedAt < Self.zoomHoverAutoHide else {
            SnapLog.event("layouts.zoom-yield", "reason=macOS-native-zoom-menu-is-likely-open")
            cancelZoomHover()
            zoomHoverSuppressedUntilLeave = true
            return
        }
        guard SnapLayoutPresets.hoverDwellElapsed(startedAt: startedAt, now: now, dwell: Self.zoomHoverDwell)
        else { return }
        guard !zoomHoverPanelOpen else { return }
        presentZoomHoverPanel(button: button)
    }

    private func resolveFocusedZoomButton() -> ZoomHoverButton? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let axApp = SnapAX.application(app.processIdentifier, timeout: SnapAX.Timeout.focused)
        guard let window = SnapAX.windowAttribute(axApp, kAXFocusedWindowAttribute as String)
                ?? SnapAX.windowAttribute(axApp, kAXMainWindowAttribute as String),
              !SnapAX.boolAttribute(window, "AXFullScreen"),
              let windowID = AXWindowResolver.windowID(for: window),
              let button = SnapAX.windowAttribute(window, kAXZoomButtonAttribute as String),
              let frame = SnapAX.frame(of: button)
        else { return nil }
        return ZoomHoverButton(windowID: windowID, frame: frame)
    }

    private func presentZoomHoverPanel(button: ZoomHoverButton) {
        guard let screen = screen(containing: button.frame) else {
            SnapLog.event("layouts.zoom-skip", "reason=no-screen-for-button")
            return
        }
        let presets = SnapLayoutPresets.availablePresets(for: screen.visibleFrame)
        let panel = layoutsPanel ?? {
            let created = SnapLayoutsPanel()
            layoutsPanel = created
            return created
        }()
        panel.showBelowButton(buttonFrame: button.frame, visibleFrame: screen.visibleFrame, presets: presets)
        zoomHoverPanelOpen = true
        zoomHoverPresets = presets
        SnapLog.event("layouts.show",
                      "trigger=zoom-button windowID=\(button.windowID) presets=\(presets.count) button=\(SnapLog.rect(button.frame))")
    }

    private func cancelZoomHover() {
        zoomHoverStartedAt = nil
        zoomHoverSuppressedUntilLeave = false
        guard zoomHoverPanelOpen else { return }
        zoomHoverPanelOpen = false
        layoutsPanel?.hide()
        SnapLog.event("layouts.hide", "trigger=zoom-button")
    }

    // MARK: - Divider hint (spec §6/§12)

    private func handleDividerHint(atQuartz location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - dividerHintSampleAt >= Self.dividerHintSampleInterval else { return }
        dividerHintSampleAt = now

        guard hoverGates(now: now).divider, drag == nil, pressOrigin == nil else {
            cancelDividerHint()
            return
        }
        let point = SnapAX.appKitPoint(fromQuartz: location)
        // The seam a person sees is between the real, possibly-resized frames,
        // never the fixed zones — the same cached live read a drag already
        // pays for, reused rather than a second sweep.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let members = groups.liveMemberFrames(on: screen), members.count >= 2
        else {
            cancelDividerHint()
            return
        }
        guard let hint = SnapDividerHintSupport.dividerHint(at: point, members: members,
                                                            tolerance: Self.dividerHintTolerance)
        else {
            cancelDividerHint()
            return
        }
        if dividerHintCached != hint {
            dividerHintStartedAt = now
            dividerHintCached = hint
        }
        guard let startedAt = dividerHintStartedAt,
              SnapLayoutPresets.hoverDwellElapsed(startedAt: startedAt, now: now, dwell: Self.dividerHintDwell)
        else { return }
        presentDividerHint(hint)
    }

    private func presentDividerHint(_ hint: SnapDividerHintSupport.DividerHint) {
        let panel = dividerPanel ?? {
            let created = SnapController.makeDividerPanel()
            dividerPanel = created
            return created
        }()
        if panel.frame != hint.frame { panel.setFrame(hint.frame, display: true) }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            SnapLog.event("divider.show", "rect=\(SnapLog.rect(hint.frame)) vertical=\(hint.isVertical)")
        }
        dividerHintVisible = true
    }

    private func cancelDividerHint() {
        dividerHintStartedAt = nil
        dividerHintCached = nil
        guard dividerHintVisible else { return }
        dividerHintVisible = false
        dividerPanel?.orderOut(nil)
        SnapLog.event("divider.hide")
    }

    private static func makeDividerPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.55)
        panel.isOpaque = false
        panel.hasShadow = false
        // Never intercepts the click that starts a real resize drag: the app's
        // own resize cursor and the linked resize both work as if it were not
        // there at all.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    // MARK: - Screens

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            ?? NSScreen.screens.max(by: { lhs, rhs in
                lhs.frame.intersection(rect).area < rhs.frame.intersection(rect).area
            })
    }

    /// The screen a previously computed `visibleFrame` belongs to, matched by
    /// whichever screen's full `frame` contains its center — not by comparing
    /// `visibleFrame` values, which the Dock or Notification Center can shift
    /// between a target being resolved and its placement being written.
    private func screen(matchingVisibleFrame visibleFrame: NSRect, fallbackRect: CGRect) -> NSScreen? {
        let center = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.visibleFrame == visibleFrame }
            ?? screen(containing: fallbackRect)
    }
}

// MARK: - Drag state

/// One in-flight window drag the edge-snap tap is tracking.
struct SnapEdgeDrag {
    let window: AXUIElement
    let key: WindowLayoutWindowKey
    /// Quartz space, as the window server reported it at press time.
    let initialFrame: CGRect
    let pointerStart: CGPoint
    let protectsSystemTopEdge: Bool
    let quartzScreenFrames: [CGRect]
    var lastSampleAt: TimeInterval = 0
    var mismatchCount: Int = 0
    var isMoving: Bool = false
    var target: WindowEdgeSnapTarget?
}

/// The translucent rectangle drawn over the zone a release would apply.
final class SnapPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateAppearance()
        setAccessibilityElement(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer.borderColor = accent.withAlphaComponent(0.88).cgColor
        layer.borderWidth = 2
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

extension WindowLayoutFrame {
    var cgRect: CGRect { CGRect(origin: origin, size: size) }
}

// MARK: - Placement pipeline and Snap Assist (spec §4, §5)

extension SnapController {
    /// The zone a placement should actually use: `theoreticalZone` with every
    /// edge a Snap Group neighbour touches replaced by that neighbour's real
    /// current edge (spec §5). `WindowLayoutService` calls this for every
    /// placement it computes, and the drag preview calls it too, so what is
    /// previewed is exactly what gets written.
    ///
    /// `fallbackRect` (the window's own current frame, AppKit space) only
    /// resolves the screen when no live `NSScreen` still reports exactly
    /// `visibleFrame` — a display can be reconfigured between a target being
    /// computed and it being written.
    func freeSpace(for action: WindowLayoutAction,
                   theoreticalZone: CGRect,
                   visibleFrame: NSRect,
                   fallbackRect: CGRect,
                   excluding windowID: CGWindowID?) -> CGRect {
        guard SnapGroupSupport.joinsGroup(action) else { return theoreticalZone }
        guard let screen = screen(matchingVisibleFrame: visibleFrame, fallbackRect: fallbackRect) else {
            return theoreticalZone
        }
        return groups.freeSpace(for: action, theoreticalZone: theoreticalZone,
                                on: screen, excluding: windowID)
    }

    /// Every successful placement funnels through here — shortcut, drag,
    /// Snap Layouts cell, zoom-button flyout, directional gesture, and a Snap
    /// Assist pick alike.
    ///
    /// It runs **whether or not the window physically moved**. A placement
    /// that found the window already exactly on its zone still updates the
    /// group and still decides about Snap Assist: skipping that no-op case is
    /// what made the overlay appear the first time a window was snapped left
    /// and not the second, with nothing in the log to say why.
    func placementDidLand(action: WindowLayoutAction,
                          windowID: CGWindowID,
                          appliedRect: CGRect,
                          preSnapRect: CGRect,
                          visibleFrame: NSRect,
                          movedWindow: Bool,
                          origin: SnapPlacementOrigin) {
        guard let screen = screen(matchingVisibleFrame: visibleFrame, fallbackRect: preSnapRect) else {
            SnapLog.event("place.landed-orphan",
                          "windowID=\(windowID) action=\(action) reason=no-screen-for-\(SnapLog.rect(visibleFrame))")
            transition(.reset(reason: "placement landed on no resolvable screen"))
            return
        }
        SnapLog.event("place.landed",
                      "windowID=\(windowID) action=\(action) rect=\(SnapLog.rect(appliedRect)) "
                          + "screen=\(screen.displayID) moved=\(movedWindow) "
                          + "origin=\(origin == .user ? "user" : "assist")")

        if SnapGroupSupport.joinsGroup(action) {
            groups.record(action: action, windowID: windowID, appliedRect: appliedRect,
                          preSnapSize: preSnapRect.size, on: screen)
        } else {
            groups.remove(windowID, reason: "placed with \(action), which claims the whole screen")
        }

        transition(.placementLanded(SnapPlacement(windowID: windowID, action: action, screenID: screen.displayID),
                                    origin: origin))
        decideAssist(action: action, windowID: windowID, screen: screen, origin: origin)
    }

    /// A window left every Snap Group: maximized, restored, went full screen,
    /// centered, or crossed to another display.
    func windowLeftGroups(_ windowID: CGWindowID, reason: String) {
        groups.remove(windowID, reason: reason)
    }

    /// Dock Preview's "Show group" — every other member of this window's Snap
    /// Group, with its owning pid.
    func snapGroupPeers(of windowID: CGWindowID) -> [(windowID: CGWindowID, pid: pid_t)]? {
        groups.peers(of: windowID)
    }

    // MARK: Snap Assist

    private var assistGatesPass: Bool {
        AppFeature.windowLayout.isAvailable && AXIsProcessTrusted()
    }

    /// What a landed placement means for the overlay.
    private func decideAssist(action: WindowLayoutAction,
                              windowID: CGWindowID,
                              screen: NSScreen,
                              origin: SnapPlacementOrigin) {
        guard origin == .user else {
            advanceAssist(pickedCell: action, windowID: windowID, screen: screen)
            return
        }
        let mode = assistMode
        guard mode != .off else {
            SnapLog.event("assist.skip", "windowID=\(windowID) reason=mode-off")
            endAssist(reason: "Snap Assist is off")
            return
        }
        guard assistGatesPass else {
            SnapLog.event("assist.skip", "windowID=\(windowID) reason=feature-unavailable-or-untrusted")
            endAssist(reason: "feature unavailable")
            return
        }
        guard SnapGroupSupport.joinsGroup(action) else {
            SnapLog.event("assist.skip", "windowID=\(windowID) action=\(action) reason=action-leaves-no-free-cell")
            endAssist(reason: "\(action) leaves no sibling cell")
            return
        }
        let siblings = SnapAssistSupport.siblingZones(of: action)
        let occupied = occupiedSiblings(of: action, on: screen, excluding: windowID)
        guard let session = SnapAssistSupport.SnapAssistSession.start(from: action,
                                                                      screenID: screen.displayID,
                                                                      occupiedCells: occupied) else {
            SnapLog.event("assist.skip",
                          "windowID=\(windowID) action=\(action) siblings=[\(Self.list(siblings))] "
                              + "occupied=[\(Self.list(Array(occupied)))] reason=every-sibling-already-filled")
            endAssist(reason: "every sibling cell is already filled")
            return
        }
        guard let cell = session.currentCell else {
            endAssist(reason: "session opened with no cell")
            return
        }
        SnapLog.event("assist.session",
                      "windowID=\(windowID) action=\(action) mode=\(mode.rawValue) "
                          + "siblings=[\(Self.list(siblings))] occupied=[\(Self.list(Array(occupied)))] "
                          + "free=[\(Self.list(session.freeCells))]")

        guard mode == .ask else {
            // Auto fills only the first free cell and opens no session at all,
            // so it can never chain through the rest of the layout.
            autoFill(cell: cell, placedWindowID: windowID, screen: screen)
            return
        }
        transition(.assistSessionOpened(session))
        presentAssist(cell: cell, placedWindowID: windowID, screen: screen)
    }

    /// A Snap Assist pick just landed: advance the session it came from, or
    /// finish it. Never starts a new one.
    private func advanceAssist(pickedCell: WindowLayoutAction, windowID: CGWindowID, screen: NSScreen) {
        let phase = transition(.assistCellPicked(pickedCell))
        guard case .assisting(let session) = phase, let next = session.currentCell else {
            SnapLog.event("assist.finish", "windowID=\(windowID) filled=\(pickedCell)")
            hideAssist(reason: "every free cell filled")
            return
        }
        SnapLog.event("assist.advance", "filled=\(pickedCell) next=\(next)")
        presentAssist(cell: next, placedWindowID: windowID, screen: screen)
    }

    /// Which of `action`'s sibling cells the Snap Group already holds.
    ///
    /// Only a group member can take a cell out of the offer — matching
    /// Windows, which asks whether the snapped layout already has something in
    /// that slot, not whether some window happens to be sitting over it. An
    /// ordinary, never-snapped window parked over the right half no longer
    /// means snapping left offers nothing.
    private func occupiedSiblings(of action: WindowLayoutAction,
                                  on screen: NSScreen,
                                  excluding windowID: CGWindowID) -> Set<WindowLayoutAction> {
        let cells = SnapAssistSupport.siblingZones(of: action)
        guard !cells.isEmpty else { return [] }
        let members = groups.occupancyMembers(on: screen, excluding: windowID)
        let tolerance = max(3, WindowLayoutGaps.windowGap + 3)
        var occupied: Set<WindowLayoutAction> = []
        for cell in cells {
            let rect = WindowLayoutGeometry.rect(for: cell,
                                                 current: screen.visibleFrame,
                                                 visibleFrame: screen.visibleFrame,
                                                 windowGap: WindowLayoutGaps.windowGap,
                                                 screenGap: WindowLayoutGaps.screenGap)
            let holder = SnapAssistSupport.occupant(of: cell, cellFrame: rect,
                                                    members: members, zoneTolerance: tolerance)
            SnapLog.event("assist.cell",
                          "cell=\(cell) rect=\(SnapLog.rect(rect)) "
                              + (holder.map { "occupied-by=\($0)" } ?? "free")
                              + " members=\(members.count)")
            if holder != nil { occupied.insert(cell) }
        }
        return occupied
    }

    /// The free rectangle and the candidate list for `cell` — shared by the
    /// overlay and by auto mode, which differ only in what they do with it.
    private func offering(for cell: WindowLayoutAction,
                          placedWindowID: CGWindowID,
                          screen: NSScreen) -> (freeRect: CGRect, items: [SwitcherItem])? {
        var excluded: Set<CGWindowID> = [placedWindowID]
        excluded.formUnion(groups.pruned(on: screen).members.map(\.windowID))

        let items = candidates(on: screen, excluding: excluded)
        guard !items.isEmpty else {
            SnapLog.event("assist.no-candidates", "cell=\(cell) excluded=\(excluded.count)")
            return nil
        }
        let theoretical = WindowLayoutGeometry.rect(for: cell,
                                                    current: screen.visibleFrame,
                                                    visibleFrame: screen.visibleFrame,
                                                    windowGap: WindowLayoutGaps.windowGap,
                                                    screenGap: WindowLayoutGaps.screenGap)
        let freeRect = groups.freeSpace(for: cell, theoreticalZone: theoretical, on: screen, excluding: nil)
        guard SnapAssistSupport.isOfferable(freeRect: freeRect) else {
            SnapLog.event("assist.not-offerable",
                          "cell=\(cell) theoretical=\(SnapLog.rect(theoretical)) free=\(SnapLog.rect(freeRect)) "
                              + "minimum=\(Int(SnapAssistSupport.minimumOfferableSpace))")
            return nil
        }
        return (freeRect, items)
    }

    private func presentAssist(cell: WindowLayoutAction, placedWindowID: CGWindowID, screen: NSScreen) {
        guard let offering = offering(for: cell, placedWindowID: placedWindowID, screen: screen) else {
            endAssist(reason: "nothing worth offering for \(cell)")
            return
        }
        let panel = assistPanel ?? {
            let created = SnapAssistPanel()
            created.onDismiss = { [weak self] reason in
                guard let self else { return }
                SnapLog.event("assist.dismiss", "reason=\(reason)")
                self.transition(.assistDismissed(reason: reason))
            }
            assistPanel = created
            return created
        }()
        SnapLog.event("assist.present",
                      "cell=\(cell) free=\(SnapLog.rect(offering.freeRect)) candidates=\(offering.items.count) "
                          + "screen=\(screen.displayID)")
        let text = FeatureStrings.windowLayout(L10n.shared.language)
        panel.show(in: offering.freeRect, on: screen, items: offering.items, hint: text.snapAssistHint) { [weak self] item in
            self?.pick(item, cell: cell, screen: screen)
        }
        WindowPreviewProvider.shared.refreshPreviews(for: offering.items) { [weak panel] windowID, image in
            panel?.updatePreview(image, for: windowID)
        }
    }

    /// Auto mode: place the most recently used candidate straight into `cell`,
    /// no overlay, no session.
    private func autoFill(cell: WindowLayoutAction, placedWindowID: CGWindowID, screen: NSScreen) {
        guard let offering = offering(for: cell, placedWindowID: placedWindowID, screen: screen),
              let candidate = offering.items.first, let windowID = candidate.windowID
        else {
            SnapLog.event("assist.auto-skip", "cell=\(cell) reason=no-candidate")
            endAssist(reason: "auto mode had nothing to place")
            return
        }
        SnapLog.event("assist.auto", "cell=\(cell) windowID=\(windowID) title=\(candidate.displayTitle)")
        place(windowID: windowID, pid: candidate.windowOwnerPID, into: cell, on: screen)
    }

    private func pick(_ item: SwitcherItem, cell: WindowLayoutAction, screen: NSScreen) {
        guard let windowID = item.windowID else {
            SnapLog.event("assist.pick-skip", "cell=\(cell) reason=card-has-no-window-id")
            return
        }
        SnapLog.event("assist.pick", "cell=\(cell) windowID=\(windowID) title=\(item.displayTitle)")
        // The pick re-activates the chosen window's app, which makes this
        // panel resign key; that resign must not be read as "clicked away".
        assistPanel?.ignorePendingResign()
        place(windowID: windowID, pid: item.windowOwnerPID, into: cell, on: screen)
    }

    /// Places an arbitrary window — not the focused one — into `cell`, through
    /// the same host placement path everything else uses, so it joins the
    /// group and the session advances from `placementDidLand`.
    ///
    /// On failure nothing hides: the same cell keeps showing so the person can
    /// try a different window instead of losing the overlay to one bad pick.
    private func place(windowID: CGWindowID, pid: pid_t, into cell: WindowLayoutAction, on screen: NSScreen) {
        guard let host else { return }
        guard AXIsProcessTrusted() else {
            SnapLog.event("place.refuse", "source=assist windowID=\(windowID) reason=accessibility-not-trusted")
            return
        }
        let axApp = SnapAX.application(pid, timeout: SnapAX.Timeout.focused)
        guard let window = SnapAX.window(windowID, in: axApp, timeout: SnapAX.Timeout.focused) else {
            SnapLog.event("place.refuse", "source=assist windowID=\(windowID) pid=\(pid) reason=no-ax-element")
            return
        }
        activate(window: window, axApp: axApp, pid: pid)
        // A window just un-minimized has not necessarily reported itself on
        // screen yet, so the "already on screen" check is relaxed here.
        guard let target = host.snapTarget(windowID: windowID, pid: pid,
                                           capability: cell.targetCapability, allowOffScreen: true) else {
            SnapLog.event("place.refuse",
                          "source=assist windowID=\(windowID) pid=\(pid) reason=window-not-placeable "
                              + "frame=\(SnapLog.rect(SnapAX.frame(of: window)))")
            return
        }
        SnapLog.event("place.request", "source=assist windowID=\(windowID) action=\(cell)")
        let placed = host.snapApplyPlacement(cell, to: target, visibleFrame: screen.visibleFrame,
                                             historyFrame: nil, cyclesRepeatedAction: false,
                                             origin: .snapAssist)
        if !placed {
            SnapLog.event("place.fail", "source=assist windowID=\(windowID) action=\(cell)")
        }
    }

    /// Un-minimizes and raises the picked window and activates its app
    /// directly — not through `WindowActivator`, whose handoff always
    /// activates Vorssaint first. Doing that left the target app mid
    /// activation-transition at the exact moment the placement tried to read
    /// it, failing silently.
    private func activate(window: AXUIElement, axApp: AXUIElement, pid: pid_t) {
        if SnapAX.isMinimized(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if !app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) {
            app.activate(options: [.activateAllWindows])
        }
    }

    /// Every window worth offering on `screen`: every on-screen layer-0 window
    /// there, plus every minimized window of a regular running app (spec §4
    /// point 2 — those never appear in an on-screen enumeration), minus the
    /// window just placed and every current group member. Ordered most
    /// recently used first.
    ///
    /// Deliberately bypasses `WindowEnumerator`: both of its entry points
    /// apply the Switcher's own current-Space and per-app visibility rules,
    /// none of which have anything to do with Snap Assist.
    private func candidates(on screen: NSScreen, excluding excluded: Set<CGWindowID>) -> [SwitcherItem] {
        var byWindowID: [CGWindowID: SwitcherItem] = [:]
        var enumerated = 0
        var dropped: [String: Int] = [:]
        var axApps: [pid_t: AXUIElement] = [:]
        func axApp(_ pid: pid_t) -> AXUIElement {
            if let existing = axApps[pid] { return existing }
            let created = SnapAX.application(pid, timeout: SnapAX.Timeout.focused)
            axApps[pid] = created
            return created
        }
        func drop(_ reason: String) { dropped[reason, default: 0] += 1 }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in SnapAX.onScreenWindows(on: screen) {
            enumerated += 1
            guard window.ownerPID != ownPID else { drop("own window"); continue }
            guard !excluded.contains(window.windowID) else { drop("already in the group"); continue }
            guard let app = NSRunningApplication(processIdentifier: window.ownerPID), !app.isTerminated,
                  app.activationPolicy == .regular
            else { drop("not a regular app"); continue }
            guard let element = SnapAX.window(window.windowID, in: axApp(window.ownerPID),
                                              timeout: SnapAX.Timeout.focused)
            else { drop("no AX element"); continue }
            guard SnapAX.isPlaceableWindow(element) else { drop("not placeable"); continue }
            byWindowID[window.windowID] = .window(id: window.windowID,
                                                  title: SnapAX.stringAttribute(element, kAXTitleAttribute as String) ?? "",
                                                  appName: app.localizedName ?? "",
                                                  pid: window.ownerPID,
                                                  isOnScreen: true,
                                                  frame: window.quartzFrame)
        }

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != ownPID {
            guard let windows = SnapAX.windows(of: axApp(app.processIdentifier)) else { continue }
            for element in windows {
                guard SnapAX.isMinimized(element),
                      let windowID = AXWindowResolver.windowID(for: element)
                else { continue }
                enumerated += 1
                guard !excluded.contains(windowID) else { drop("already in the group"); continue }
                guard byWindowID[windowID] == nil else { continue }
                guard SnapAX.isPlaceableWindow(element, allowMinimized: true) else {
                    drop("not placeable")
                    continue
                }
                let quartz = SnapAX.quartzFrame(of: element) ?? .zero
                byWindowID[windowID] = .window(id: windowID,
                                               title: SnapAX.stringAttribute(element, kAXTitleAttribute as String) ?? "",
                                               appName: app.localizedName ?? "",
                                               pid: app.processIdentifier,
                                               isOnScreen: false,
                                               isMinimized: true,
                                               frame: quartz)
            }
        }

        let mru = WindowUseTracker.shared.windows.filter { byWindowID[$0] != nil }
        var ordered = mru.compactMap { byWindowID[$0] }
        let seen = Set(mru)
        ordered.append(contentsOf: byWindowID.keys.filter { !seen.contains($0) }.compactMap { byWindowID[$0] })
        let dropSummary = dropped.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        SnapLog.event("assist.candidates",
                      "screen=\(screen.displayID) enumerated=\(enumerated) offered=\(ordered.count) "
                          + "dropped=[\(dropSummary)]")
        return ordered
    }

    /// Ends the session without an overlay dismissal having happened — the
    /// controller itself deciding there is nothing to offer.
    private func endAssist(reason: String) {
        if case .assisting = machine.phase {
            transition(.assistDismissed(reason: reason))
        } else {
            transition(.reset(reason: reason))
        }
        assistPanel?.hide(reason: reason)
    }

    /// Closes the overlay from outside (a fresh drag, a hand resize, suspend).
    func hideAssist(reason: String) {
        if case .assisting = machine.phase {
            SnapLog.event("assist.cancel", "reason=\(reason)")
            transition(.assistDismissed(reason: reason))
        }
        assistPanel?.hide(reason: reason)
    }

    private static func list(_ actions: [WindowLayoutAction]) -> String {
        actions.map { "\($0)" }.sorted().joined(separator: ",")
    }
}
