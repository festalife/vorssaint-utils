// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import QuartzCore
import os.log

enum WindowLayoutError: Equatable {
    case missingAccessibility
    case noWindow
    case noRestore
    case failed
}

enum WindowLayoutResult: Equatable {
    case success(restored: Bool)
    case failure(WindowLayoutError)
}

/// Window placement through explicit panel actions, global shortcuts and an
/// optional pointer gesture. The active taps only perform Accessibility work
/// after a deliberate gesture. Edge snapping changes an event only after the
/// same window has visibly followed the pointer to the top of a screen.
final class WindowLayoutService: ObservableObject {
    static let shared = WindowLayoutService()

    @Published private(set) var lastResult: WindowLayoutResult?
    /// Bumped on every published result, so a late settle failure can tell
    /// whether it still owns the feedback slot.
    private var resultGeneration = 0
    @Published private(set) var failedShortcutActions: Set<WindowLayoutAction> = []
    @Published private(set) var directionalShortcutRegistrationFailed = false
    @Published private(set) var isGestureRunning = false

    private var frameHistory = WindowLayoutHistory()
    private var lastActions: [WindowLayoutWindowKey: WindowLayoutAction] = [:]
    private var hotKeyRefs: [WindowLayoutAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var registeredShortcuts: [WindowLayoutAction: GlobalShortcut] = [:]
    private var directionalHotKeyRef: EventHotKeyRef?
    private var registeredDirectionalShortcut: GlobalShortcut?
    private var directionalSession: WindowDirectionalSession?
    private var directionalTimer: Timer?
    private var directionalIndicatorPanel: NSPanel?
    private var directionalTap: CFMachPort?
    private var directionalTapSource: CFRunLoopSource?
    private var gestureTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private var edgeSnapTap: CFMachPort?
    private var edgeSnapRunLoopSource: CFRunLoopSource?
    private var activeGesture: WindowPointerGesture?
    private var pendingGesture: PendingWindowGesture?
    private var edgeSnapPressOrigin: CGPoint?
    private var edgeSnapPressCandidate: WindowServerWindowCandidate?
    private var edgeSnapSequenceSuppressed = false
    private var edgeSnapResolveAttempts = 0
    private var edgeSnapLastResolveAt: TimeInterval = 0
    private var edgeSnapDrag: WindowEdgeSnapDrag?
    private var edgeSnapSequenceGeneration = 0
    private var edgeSnapPreviewPanel: NSPanel?
    private var edgeSnapPreviewGeneration = 0
    private var snapLayoutsPanel: SnapLayoutsPanel?
    /// The screen the open Snap Layouts panel is anchored to, remembered so
    /// later drag samples can ask "should it stay open" against the same
    /// screen even once the pointer has moved past the narrow strip that
    /// first triggered it (see `resolvedEdgeSnapTarget`). Cleared together
    /// with the panel everywhere it hides.
    private var snapLayoutsActiveScreen: WindowEdgeSnapScreen?
    /// The Snap Assist overlay (spec §4), shown after any placement leaves
    /// free space on screen. Unlike `snapLayoutsPanel`, it is genuinely
    /// clickable and owns its own dismissal (Esc, click outside, another
    /// drag starting elsewhere, an app switch, or eight seconds of
    /// inactivity), so it is created lazily and otherwise left alone here.
    private var snapAssistPanel: SnapAssistPanel?
    /// The Snap Assist session currently open, if any — see
    /// `SnapAssistSupport.SnapAssistSession`'s own doc comment for why this
    /// is the single source of truth for which cell is offered next,
    /// instead of re-deriving it from Snap Group membership on every
    /// placement. `nil` whenever nothing is open.
    private var snapAssistSession: SnapAssistSupport.SnapAssistSession?
    /// One Snap Group per physical display, in memory only — cleared on
    /// relaunch like the rest of this service's session state. Keyed by
    /// display id rather than `NSScreen` identity, which AppKit is free to
    /// invalidate on a reconfiguration (`AppKitExtensions.swift` explains
    /// the same choice for `isStillAttached`).
    private var snapGroups: [CGDirectDisplayID: SnapGroup] = [:]
    /// Every Snap Group member currently being watched for a linked resize
    /// (spec §6) — one entry per window, kept in lockstep with `snapGroups`'
    /// combined membership by `syncLinkedResizeObservers()` every time a
    /// group is created, updated or pruned. Empty whenever
    /// `windowSnapLinkedResizeEnabled` is off, matching how every other tap
    /// in this service only touches Accessibility once a feature is on.
    /// The actual `AXObserver` each member's notifications flow through is
    /// not stored here — it is shared per *process* in
    /// `linkedResizeAppObservers` below, since several members can belong
    /// to the same app (several Chrome windows tiled together, say).
    private var linkedResizeObservers: [CGWindowID: LinkedResizeObservation] = [:]
    private struct LinkedResizeObservation {
        let window: AXUIElement
        /// Recorded so a notification, and every later read, can be
        /// rejected the moment it turns out to belong to a different
        /// process — `CGWindowID` values are reused by the window server,
        /// so the id alone is not proof this is still the same window.
        let pid: pid_t
    }
    /// One shared `AXObserver` per *process*, not per window: an app with
    /// several watched windows (Chrome with three tiled tabs' windows, say)
    /// registered a fresh `AXObserver` — and a fresh
    /// `kAXWindowResizedNotification`/`kAXWindowMovedNotification`
    /// registration on the very same application element — per window
    /// before this, which is both wasteful and, worse, meant every one of
    /// those observers received every one of that app's window move/resize
    /// notifications, not just the one for its own window. One observer per
    /// pid, created the moment its first window starts being watched and
    /// torn down the moment its last one stops, with the app-level
    /// registration made exactly once. Per-window `kAXResizedNotification`
    /// /`kAXMovedNotification` are still registered on this same shared
    /// observer, once per window element, alongside it — `AXObserver`
    /// supports watching any number of elements and notifications at once,
    /// there was never a need for more than one per process.
    private var linkedResizeAppObservers: [pid_t: LinkedResizeAppObservation] = [:]
    private struct LinkedResizeAppObservation {
        let observer: AXObserver
        let app: AXUIElement
        /// Every window of this process currently watched under `observer`
        /// — consulted to resolve an app-level notification's `element` to
        /// one of *our* windowIDs (`resolveLinkedResizeWindowID`) and to
        /// know when the last one leaving means the whole observation
        /// should be torn down rather than just one window's registration.
        var watchedWindows: Set<CGWindowID> = []
    }
    /// The exact frame this service last wrote to a window itself, and
    /// when — so the resize/move notification that write provokes can be
    /// told apart from a notification a genuine, ongoing user drag
    /// produced. Comparing a *live-read* frame against this recorded one
    /// (`isSelfInitiatedEcho`), not a fixed time window, is deliberate: an
    /// earlier version used a 0.5s window against a 33ms throttle, which
    /// swallowed every real notification for up to half a second after any
    /// write this service made — long enough for a 3+-member row to desync
    /// and only catch up on some later, unrelated event. `at` is kept only
    /// as a short fallback expiry for the rare case a written frame is
    /// never read back at all (the window closed mid-write, say), not as
    /// the primary signal.
    private var linkedResizeSelfInitiated: [CGWindowID: (frame: CGRect, at: TimeInterval)] = [:]
    /// ≤ 3 × `linkedResizeThrottleInterval` (1/30s), matching the review
    /// guidance: long enough to cover one throttled tick plus margin, short
    /// enough that a marker never meaningfully outlives the write it guards.
    private let linkedResizeSelfInitiatedFallbackExpiry: TimeInterval = 0.1
    private let linkedResizeSelfInitiatedFrameTolerance: CGFloat = 2
    /// Members with a linked-resize notification already scheduled but not
    /// yet processed — a resize drag emits many notifications in a burst,
    /// and this coalesces them: further notifications for the same window
    /// arriving before `linkedResizeThrottleInterval` elapses are dropped,
    /// and the one scheduled run reads whatever the live frame is by the
    /// time it actually fires, which is the last geometry of the burst.
    private var linkedResizePendingWindows: Set<CGWindowID> = []
    private let linkedResizeThrottleInterval: TimeInterval = 1.0 / 30.0
    /// Accessibility exposes no way to ask a window for its minimum size
    /// up front, so a first pass guesses this floor — the same 80×80 floor
    /// `focusedTarget` already uses to decide a window is worth acting on
    /// at all — and `applyLinkedResizeAdjustments` corrects course with a
    /// second pass using whatever size Accessibility actually accepted,
    /// whenever that turns out to be larger.
    private static let linkedResizeMinimumSizeGuess = CGSize(width: 80, height: 80)
    /// A per-element Accessibility messaging timeout used only for
    /// linked-resize member windows — a fan-out of synchronous writes across
    /// up to four members, each capable of blocking on the system default
    /// (multiple seconds) if that member's app has hung, could otherwise
    /// freeze the whole app for the duration of one throttled tick. 0.1s
    /// (the original value) turned out too tight for a real read or write
    /// against Chromium/Electron apps and Finder under ordinary load —
    /// every AX round trip to those was timing out, silently, well before
    /// they had actually failed to respond, which read exactly like "this
    /// member never resizes" from the outside. 0.25s is still short enough
    /// to bound a single hung app's cost to a fraction of one throttled
    /// tick, but long enough that a healthy Chromium/Electron/Finder window
    /// answers well within it.
    private static let linkedResizeMessagingTimeout: Float = 0.25
    /// Hard ceiling on how long one throttled pass may spend writing member
    /// frames, across both the first pass and the corrective pass —
    /// bounds the worst case where several members are all slow at once
    /// (each capped at `linkedResizeMessagingTimeout`) instead of letting
    /// them add up unbounded. Remaining members are simply left alone for
    /// this tick; the next notification tries again. Sized for up to four
    /// members each legitimately taking close to `linkedResizeMessagingTimeout`
    /// (Chromium/Electron under load, say) without the budget cutting a
    /// perfectly healthy pass short partway through.
    private static let linkedResizeApplyBudget: TimeInterval = 0.6
    /// Diagnostics for the whole linked-resize path — observer registration,
    /// every notification received, every early return and its reason, and
    /// every write attempt with its frame and `AXError`. `.debug` level
    /// only, so it costs nothing unless something is actually streaming or
    /// showing debug-level logs (`log stream --level debug --predicate
    /// 'subsystem == "<bundle id>" && category == "linkedResize"'`), the
    /// same convention `Notifier`/`AppDelegate`/`BrightnessService` already
    /// use elsewhere in this app — no separate env-var gate needed.
    private static let linkedResizeLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                                category: "linkedResize")
    private var assistiveModeSuspensions: [CGWindowID: EnhancedUserInterfaceSuspension] = [:]
    private var settleTimers: [CGWindowID: Timer] = [:]
    private var gestureAssistiveMode: EnhancedUserInterfaceSuspension?
    /// Stamped on the press this service gives back to the system so none of
    /// our own taps mistake it for a fresh one.
    private static let syntheticEventMarker: Int64 = 0x564F5253
    /// Read on every pointer event, so it is resolved once instead of per
    /// click.
    private static let ownProcessID = Int64(getpid())
    private let frameTolerance = WindowLayoutGeometry.frameTolerance
    private let anchorTolerance: CGFloat = 36
    private let moveGestureUpdateInterval: TimeInterval = 1.0 / 120.0
    // AX frame mutations are not atomic. Complex windows can visibly render
    // the intermediate size and position when they receive resize writes at
    // pointer-reporting speed, so resize is deliberately coalesced to 60 Hz.
    private let resizeGestureUpdateInterval: TimeInterval = 1.0 / 60.0
    private let edgeSnapSampleInterval: TimeInterval = 1.0 / 30.0

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in self?.syncWithPreferences() }
        startObservingScreenParameters()
    }

    func syncWithPreferences() {
        let available = AppFeature.windowLayout.isAvailable
        let trusted = SessionActivitySupport.tapShouldRun(
            featureWanted: available,
            accessibilityGranted: AXIsProcessTrusted(),
            sessionIsActive: SessionActivity.shared.isActive)
        let wantsShortcuts = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled)
            && trusted
        wantsShortcuts ? registerHotkeys() : unregisterHotkeys()

        let wantsDirectional = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowDirectionalEnabled)
            && trusted
        wantsDirectional ? registerDirectionalHotkey() : unregisterDirectionalHotkey()

        let wantsGesture = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureEnabled)
            && trusted
        wantsGesture ? startGestureTap() : stopGestureTap()

        let wantsEdgeSnap = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled)
            && !WindowEdgeSnapSupport.isSystemTilingEnabled
            && trusted
        wantsEdgeSnap ? startEdgeSnapTap() : stopEdgeSnapTap()

        syncLinkedResizeObservers()
    }

    /// Whether a linked resize should react at all right now — the same
    /// three gates every other Window Layout tap checks (`available`,
    /// `trusted`, its own toggle), read together here since
    /// `syncLinkedResizeObservers()` and every notification handler need the
    /// identical answer. `synchronize()` first for the same reason
    /// `snapAssistEnabled` needs it: a toggle flipped by another process
    /// (`defaults write`, live during testing) is not guaranteed to be
    /// folded into `UserDefaults.standard`'s in-memory copy promptly
    /// otherwise — every other Window Layout toggle is only ever changed
    /// in-process through this app's own Settings UI and never needed this,
    /// but this read sits on the same "checked on every notification" path
    /// `snapAssistEnabled` does, so it gets the same nudge.
    private var linkedResizeFeatureAvailable: Bool {
        UserDefaults.standard.synchronize()
        let available = AppFeature.windowLayout.isAvailable
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLinkedResizeEnabled)
        let trusted = AXIsProcessTrusted()
        let result = available && enabled && trusted
        if !result {
            Self.linkedResizeLog.debug("""
                linkedResizeFeatureAvailable = false \
                (isAvailable=\(available, privacy: .public) \
                enabled=\(enabled, privacy: .public) \
                trusted=\(trusted, privacy: .public))
                """)
        }
        return result
    }

    /// Stops every Window Layout input hook before Accessibility is revoked or
    /// the process terminates. Idempotent so permission and feature changes can
    /// call it freely.
    func suspend() {
        unregisterHotkeys()
        unregisterDirectionalHotkey()
        stopGestureTap()
        stopEdgeSnapTap()
        hideSnapAssist()
        for windowID in Array(linkedResizeObservers.keys) { stopWatchingLinkedResize(windowID) }
        linkedResizeSelfInitiated.removeAll()
        for timer in settleTimers.values { timer.invalidate() }
        settleTimers.removeAll()
        let suspensions = assistiveModeSuspensions.values
        assistiveModeSuspensions.removeAll()
        // With the grant already revoked there is no safe way to touch the
        // apps again; the flag comes back when the assistive client sets it.
        guard AXIsProcessTrusted() else { return }
        for suspension in suspensions { suspension.resume() }
    }

    func shortcutConflictTitle(_ shortcut: GlobalShortcut) -> String? {
        shortcutConflictTitle(shortcut, excluding: nil)
    }

    func shortcutConflictTitle(_ shortcut: GlobalShortcut, excluding excluded: WindowLayoutAction?) -> String? {
        guard AppFeature.windowLayout.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled) else { return nil }
        let text = FeatureStrings.windowLayout(L10n.shared.language)
        return WindowLayoutAction.shortcutActions.first {
            $0 != excluded && $0.savedShortcut == shortcut
        }?.title(text)
    }

    func directionalShortcutConflictTitle(_ shortcut: GlobalShortcut) -> String? {
        if let role = GlobalShortcutRole.conflict(for: shortcut, excluding: nil) {
            return role.title(L10n.shared.s)
        }
        return shortcutConflictTitle(shortcut)
    }

    @discardableResult
    func apply(_ action: WindowLayoutAction) -> WindowLayoutResult {
        guard AXIsProcessTrusted() else {
            return finish(.failure(.missingAccessibility))
        }
        guard let target = focusedTarget(for: action) else {
            return finish(.failure(.noWindow))
        }
        pruneWindowState(keeping: target.key)

        if action == .restore {
            guard let previous = frameHistory.popPrevious(for: target.key,
                                                          current: target.frame) else {
                return finish(.failure(.noRestore))
            }
            if setFrame(previous, on: target.window, windowKey: target.key) {
                lastActions.removeValue(forKey: target.key)
                removeFromAllSnapGroups(target.windowID)
                return finish(.success(restored: true))
            }
            frameHistory.record(previous, for: target.key)
            return finish(.failure(.failed))
        }

        if action == .fullScreen {
            // A placement still settling must never write its old frame over
            // the native full-screen transition that replaces it.
            cancelSettle(for: target.windowID)
            assistiveModeSuspensions.removeValue(forKey: target.windowID)?.resume()
            // The native full screen the green button gives, toggled through
            // the same attribute the button writes. The system owns the frame
            // from here, so nothing is remembered for restore.
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(target.window, "AXFullScreen" as CFString, &raw)
            let isFullScreen = (raw as? NSNumber)?.boolValue ?? false
            let flipped = (isFullScreen ? kCFBooleanFalse : kCFBooleanTrue) as CFTypeRef
            let applied = AXUIElementSetAttributeValue(target.window,
                                                       "AXFullScreen" as CFString,
                                                       flipped) == .success
            // Remembered like any other placement, or the "same half twice
            // means maximize" rule would still be looking at whatever the
            // window did before it went full screen.
            if applied {
                if isFullScreen {
                    lastActions.removeValue(forKey: target.key)
                } else {
                    lastActions[target.key] = .fullScreen
                }
                removeFromAllSnapGroups(target.windowID)
            }
            return applied ? finish(.success(restored: false)) : finish(.failure(.failed))
        }
        let screens = NSScreen.screens
        guard let screen = bestScreen(for: target.frame, screens: screens) else {
            return finish(.failure(.failed))
        }
        let currentRect = appKitFrame(fromAX: target.frame)
        if action == .previousDisplay || action == .nextDisplay {
            guard let destination = adjacentScreen(to: screen,
                                                   screens: screens,
                                                   movingForward: action == .nextDisplay) else {
                return finish(.failure(.failed))
            }
            let rect = WindowLayoutGeometry.rectForDisplay(current: currentRect,
                                                           sourceVisibleFrame: screen.visibleFrame,
                                                           destinationVisibleFrame: destination.visibleFrame)
            frameHistory.record(target.frame, for: target.key)
            if setFrame(axFrame(fromAppKit: rect),
                        targetRect: rect,
                        screenVisibleFrame: destination.visibleFrame,
                        action: action,
                        on: target.window,
                        windowKey: target.key) {
                lastActions[target.key] = action
                removeFromAllSnapGroups(target.windowID)
                return finish(.success(restored: false))
            }
            frameHistory.discardLatest(for: target.key)
            return finish(.failure(.failed))
        }
        if let crossing = WindowLayoutGeometry.displayCrossing(for: action,
                                                               previousAction: lastActions[target.key]),
           accepted(actual: target.frame,
                    targetRect: placement(for: action,
                                          current: target.frame,
                                          visibleFrame: screen.visibleFrame,
                                          excluding: target.windowID).rect,
                    action: action),
           let destination = sidewaysScreen(to: screen,
                                            screens: screens,
                                            movingRight: crossing.movingRight) {
            // The window is already parked on that side, so the same shortcut
            // keeps pushing in the same direction: over to the display beside
            // it, snapped against the edge it came in through. Without a
            // display on that side the placement below simply leaves it where
            // it is.
            //
            // It leaves whatever Snap Group it belonged to on `screen` here,
            // same as the dedicated previousDisplay/nextDisplay branch above
            // — `applyPlacement` below only ever registers membership on
            // `destination`, so without this its old screen's group would
            // keep a stale entry for a window that is no longer there.
            removeFromAllSnapGroups(target.windowID)
            return applyPlacement(crossing.action,
                                  to: target,
                                  visibleFrame: destination.visibleFrame,
                                  cyclesRepeatedAction: false)
        }
        return applyPlacement(action,
                              to: target,
                              visibleFrame: screen.visibleFrame)
    }

    /// Applies a pointer-selected snap target to one exact external window.
    /// Dock Preview resolves the target from the drop location; the frame still
    /// goes through the same settling and recovery path as every Window Layout
    /// placement instead of maintaining a second AX mutation algorithm.
    @discardableResult
    private func finish(_ result: WindowLayoutResult) -> WindowLayoutResult {
        resultGeneration += 1
        lastResult = result
        return result
    }

    private func applyPlacement(_ action: WindowLayoutAction,
                                to target: WindowLayoutTarget,
                                visibleFrame: NSRect,
                                historyFrame: WindowLayoutFrame? = nil,
                                cyclesRepeatedAction: Bool = true,
                                fromSnapAssist: Bool = false) -> WindowLayoutResult {
        let currentRect = appKitFrame(fromAX: target.frame)
        let previousAction = cyclesRepeatedAction ? lastActions[target.key] : nil
        let effectiveAction = WindowLayoutGeometry.effectiveAction(for: action,
                                                                   current: currentRect,
                                                                   visibleFrame: visibleFrame,
                                                                   previousAction: previousAction)
        let placement = placement(for: effectiveAction,
                                  current: target.frame,
                                  visibleFrame: visibleFrame,
                                  excluding: target.windowID)
        if placement.frame == target.frame {
            lastActions[target.key] = effectiveAction
            return finish(.success(restored: false))
        }
        frameHistory.record(historyFrame ?? target.frame, for: target.key)
        if setFrame(placement.frame,
                    targetRect: placement.rect,
                    screenVisibleFrame: visibleFrame,
                    action: effectiveAction,
                    on: target.window,
                    windowKey: target.key) {
            lastActions[target.key] = effectiveAction
            updateSnapGroup(action: effectiveAction,
                            windowID: target.windowID,
                            appliedRect: placement.rect,
                            visibleFrame: visibleFrame,
                            fallbackFrame: target.frame)
            // Every placement path funnels through here (shortcut, edge
            // snap, a directional gesture, the Snap Layouts panel, and a
            // Snap Assist pick itself), so this is the one place a real,
            // successful partial-zone placement is known to have happened —
            // exactly the signal spec §4 wants (never for maximize,
            // restore, full screen or center, none of which reach this
            // branch: they are handled earlier in `apply(_:)` and never
            // call `applyPlacement`). `fromSnapAssist` distinguishes a pick
            // the overlay itself just performed from every other, genuinely
            // user-initiated path here — see `handleSnapAssist`'s own doc
            // comment for why that distinction is what stops a session from
            // re-triggering itself.
            handleSnapAssist(action: effectiveAction,
                             windowID: target.windowID,
                             visibleFrame: visibleFrame,
                             fallbackFrame: target.frame,
                             fromSnapAssist: fromSnapAssist)
            return finish(.success(restored: false))
        }
        frameHistory.discardLatest(for: target.key)
        return finish(.failure(.failed))
    }

    private func focusedTarget(for action: WindowLayoutAction) -> WindowLayoutTarget? {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownKeyWindow = NSApp.keyWindow
        let hasFocusedResizableOwnWindow = NSApp.isActive
            && ownKeyWindow?.styleMask.contains(.resizable) == true
            && !(ownKeyWindow is NSPanel)
        let frontmost = hasFocusedResizableOwnWindow
            ? ownPID
            : NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pids = ([frontmost].compactMap { $0 } + WindowUseTracker.shared.apps).reduce(into: [pid_t]()) { result, pid in
            if !result.contains(pid) { result.append(pid) }
        }

        guard let onScreenWindowIDs = onScreenWindowIDs() else { return nil }
        for pid in pids {
            let isFocusedOwnApp = pid == ownPID && hasFocusedResizableOwnWindow
            // One lookup by pid, not a fresh bridge of every running app on
            // each turn of a list that can hold dozens of them. The edge-snap
            // drag in this same file already resolves its app this way.
            // isTerminated is explicit because runningApplications drops a dead
            // pid on its own and NSRunningApplication(processIdentifier:) does
            // not: it answers with a terminated instance.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated,
                  isFocusedOwnApp
                    || (app.activationPolicy == .regular && !app.isHidden
                        && app.bundleIdentifier != ownBundleID)
            else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            // Bounded AX: a hung app in the MRU list must not stall the main
            // thread (and every event tap) for the default timeout.
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window = windowAttribute(axApp, attribute as String),
                   let target = target(from: window,
                                       app: app,
                                       onScreenWindowIDs: onScreenWindowIDs,
                                       capability: action.targetCapability) {
                    return target
                }
            }
            if let windows = windowsAttribute(axApp),
               let first = windows.compactMap({ target(from: $0,
                                                        app: app,
                                                        onScreenWindowIDs: onScreenWindowIDs,
                                                        capability: action.targetCapability) }).first {
                return first
            }
        }
        return nil
    }

    private func target(from window: AXUIElement,
                        app: NSRunningApplication,
                        onScreenWindowIDs: Set<CGWindowID>,
                        capability: WindowLayoutTargetCapability) -> WindowLayoutTarget? {
        guard role(of: window) == (kAXWindowRole as String),
              !boolAttribute(window, kAXMinimizedAttribute as String),
              stringAttribute(window, kAXSubroleAttribute as String) != "AXFloatingWindow",
              let windowID = AXWindowResolver.windowID(for: window),
              onScreenWindowIDs.contains(windowID),
              let frame = frame(of: window),
              frame.size.width > 80,
              frame.size.height > 80
        else { return nil }
        let isFullScreen = boolAttribute(window, "AXFullScreen")
        guard capability == .fullScreen || !isFullScreen else { return nil }
        let hasRequiredCapability: Bool
        switch capability {
        case .position:
            hasRequiredCapability = canSetPosition(on: window)
        case .frame:
            hasRequiredCapability = canSetFrame(on: window)
        case .fullScreen:
            hasRequiredCapability = canSetFullScreen(on: window)
        }
        guard hasRequiredCapability else { return nil }
        let key = WindowLayoutWindowKey(
            processID: app.processIdentifier,
            processLaunchTime: app.launchDate?.timeIntervalSinceReferenceDate ?? 0,
            windowID: windowID
        )
        return WindowLayoutTarget(window: window, key: key, frame: frame)
    }

    private func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(windows.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    /// Removes histories whose process or window no longer exists. This runs
    /// only for an explicit layout action, never from a timer or input tap.
    private func pruneWindowState(keeping current: WindowLayoutWindowKey) {
        guard var activeWindows = activeWindowKeys() else { return }
        activeWindows.insert(current)
        frameHistory.removeStaleWindows(keeping: activeWindows)
        lastActions = lastActions.filter { activeWindows.contains($0.key) }
    }

    private func activeWindowKeys() -> Set<WindowLayoutWindowKey>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var launchTimes: [pid_t: TimeInterval] = [:]
        var keys = Set<WindowLayoutWindowKey>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            if launchTimes[pid] == nil {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else { continue }
                launchTimes[pid] = app.launchDate?.timeIntervalSinceReferenceDate ?? 0
            }
            guard let launchTime = launchTimes[pid] else { continue }
            keys.insert(WindowLayoutWindowKey(processID: pid,
                                              processLaunchTime: launchTime,
                                              windowID: windowID))
        }
        return keys.isEmpty ? nil : keys
    }

    /// `excluding` is the window this placement is *for*: when it already
    /// belongs to the Snap Group being consulted (re-snapping a window that
    /// was already a member), its own old zone must never shrink its own
    /// new one.
    private func placement(for action: WindowLayoutAction,
                           current: WindowLayoutFrame,
                           visibleFrame: NSRect,
                           excluding windowID: CGWindowID? = nil) -> WindowLayoutPlacement {
        let rect = WindowLayoutGeometry.rect(for: action,
                                             current: appKitFrame(fromAX: current),
                                             visibleFrame: visibleFrame,
                                             windowGap: WindowLayoutGaps.windowGap,
                                             screenGap: WindowLayoutGaps.screenGap)
        let adjusted = freeSpaceAdjusted(for: action,
                                         theoreticalZone: rect,
                                         visibleFrame: visibleFrame,
                                         fallbackFrame: current,
                                         excluding: windowID)
        let integral = adjusted.integral
        return WindowLayoutPlacement(frame: axFrame(fromAppKit: integral), rect: integral)
    }

    /// Whether Window Layout should snap into the real space a resized
    /// neighbour leaves, rather than always the fixed theoretical half/third/
    /// corner. Off restores today's behavior exactly (spec §5 Windows
    /// setting "Quando ridimensiono, aggancia allo spazio disponibile").
    private var fillsFreeSpaceEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapFillsFreeSpace)
    }

    /// Substitutes `theoreticalZone` with the free space
    /// `SnapGroupSupport.freeSpace` computes, when there is a Snap Group on
    /// the matching screen with at least one other member — otherwise
    /// returns `theoreticalZone` unchanged, so every caller can pass its
    /// already-computed rect through here unconditionally instead of
    /// special-casing the "no group yet" case itself. `fallbackFrame` (the
    /// window's own current AX frame) resolves the screen when no live
    /// `NSScreen` still reports exactly `visibleFrame` — a display can be
    /// reconfigured between a target being computed and read back.
    private func freeSpaceAdjusted(for action: WindowLayoutAction,
                                   theoreticalZone: CGRect,
                                   visibleFrame: NSRect,
                                   fallbackFrame: WindowLayoutFrame,
                                   excluding windowID: CGWindowID?) -> CGRect {
        // Non-partial actions (maximize, full screen, restore, center, a
        // display change) never join a group and must never be adjusted —
        // checked first, before resolving a screen or touching Accessibility
        // at all, so a stale group on this screen can never influence one.
        guard fillsFreeSpaceEnabled, SnapGroupSupport.joinsGroup(action) else { return theoreticalZone }
        guard let screen = screen(matchingVisibleFrame: visibleFrame, fallbackFrame: fallbackFrame),
              let storedGroup = snapGroups[screen.displayID], !storedGroup.members.isEmpty
        else { return theoreticalZone }

        // Prune against a live Accessibility read and persist the result
        // before doing anything else: a member that closed, was minimized,
        // or was dragged off its own zone is dropped from `snapGroups` right
        // here, once, instead of being re-resolved (and re-failing) on every
        // subsequent drag sample this same group is consulted for.
        var group = prunedGroup(storedGroup, on: screen)
        if let windowID {
            group.members.removeAll { $0.windowID == windowID }
        }
        guard !group.members.isEmpty else { return theoreticalZone }

        let liveFrames = currentFrames(for: group, on: screen).frames
        let result = SnapGroupSupport.freeSpace(for: action,
                                                theoreticalZone: theoreticalZone,
                                                group: group,
                                                gap: WindowLayoutGaps.windowGap,
                                                currentFrames: liveFrames)
        // freeSpace() already falls back to theoreticalZone under its own
        // minimum, but a defensive check costs nothing and keeps a
        // degenerate rect (a bad Accessibility read producing NaN or an
        // inverted size) from ever reaching a preview or setFrame.
        guard result.width.isFinite, result.height.isFinite,
              result.width > 0, result.height > 0
        else {
            logSnapGroup(action: action, theoreticalZone: theoreticalZone, group: group,
                        liveFrames: liveFrames, result: theoreticalZone, discarded: result)
            return theoreticalZone
        }
        logSnapGroup(action: action, theoreticalZone: theoreticalZone, group: group,
                    liveFrames: liveFrames, result: result, discarded: nil)
        return result
    }

    /// Field diagnosis channel for the free-space computation above, silent
    /// unless `VORSSAINT_SNAP_LOG=1` is set in the environment — this path
    /// runs on every drag sample once a group exists, so it stays off by
    /// default rather than adding unified-log volume for everyone. Prints
    /// exactly what `freeSpaceAdjusted` decided from: every member's
    /// recorded zone, its live frame read this call, and the free rect
    /// (or, if discarded as degenerate, what it would have been) — enough
    /// to tell, from a `log stream` capture alone, whether a specific
    /// neighbour was even considered without needing a debugger attached.
    private static let snapGroupLogEnabled = ProcessInfo.processInfo.environment["VORSSAINT_SNAP_LOG"] == "1"
    private static let snapGroupLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                             category: "snapGroup")

    private func logSnapGroup(action: WindowLayoutAction,
                              theoreticalZone: CGRect,
                              group: SnapGroup,
                              liveFrames: [CGWindowID: CGRect],
                              result: CGRect,
                              discarded: CGRect?) {
        guard Self.snapGroupLogEnabled else { return }
        let members = group.members.map { member -> String in
            let live = liveFrames[member.windowID].map { String(describing: $0) } ?? "no live frame"
            return "  windowID=\(member.windowID) action=\(member.action) zone=\(String(describing: member.frame)) live=\(live)"
        }.joined(separator: "\n")
        let discardedNote = discarded.map { " (discarded degenerate rect \(String(describing: $0)), fell back to theoretical)" } ?? ""
        let summary = "freeSpace for=\(action) theoreticalZone=\(String(describing: theoreticalZone))"
            + " -> \(String(describing: result))\(discardedNote)\n"
            + (members.isEmpty ? "  (no members)" : members)
        Self.snapGroupLog.debug("\(summary, privacy: .public)")
    }

    /// Prunes `group` against Accessibility read right now and, if that
    /// dropped anything, writes the smaller group back to `snapGroups` —
    /// so a member that closed or drifted off its zone is forgotten once,
    /// not re-resolved (and re-failed) on the next sample or placement.
    private func prunedGroup(_ group: SnapGroup, on screen: NSScreen) -> SnapGroup {
        let snapshot = currentFrames(for: group, on: screen)
        let pruned = SnapGroupSupport.pruned(group: group,
                                             currentFrames: snapshot.frames,
                                             gone: snapshot.gone,
                                             minimized: snapshot.minimized,
                                             gap: WindowLayoutGaps.windowGap)
        // Not just a count comparison: spec §7's isMinimized mark can flip
        // on a member without the group's size changing at all (minimizing
        // or un-minimizing one of several members), and that mark still
        // has to make it back into `snapGroups` for Dock Preview's "Show
        // group" and the next `freeSpace` computation to see it.
        guard pruned != group else { return group }
        if pruned.members.isEmpty {
            snapGroups.removeValue(forKey: screen.displayID)
        } else {
            snapGroups[screen.displayID] = pruned
        }
        syncLinkedResizeObservers()
        return pruned
    }

    /// The screen a previously computed `visibleFrame` belongs to. Matched
    /// by whichever screen's full `frame` contains that visible frame's
    /// center point, not by comparing `visibleFrame` values for equality:
    /// edge-snap dragging hovers right at a screen's physical edge, exactly
    /// where the Dock or Notification Center can reveal itself and shift
    /// `visibleFrame` between the moment a target was resolved and the
    /// moment its placement is written — `frame` does not move with them.
    /// Falls back to an exact `visibleFrame` match, then to whichever
    /// screen the window itself currently overlaps most, for the remaining
    /// edge case of a display actually reconfigured or unplugged between
    /// the two reads.
    private func screen(matchingVisibleFrame visibleFrame: NSRect,
                        fallbackFrame: WindowLayoutFrame) -> NSScreen? {
        let center = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.visibleFrame == visibleFrame }
            ?? bestScreen(for: fallbackFrame)
    }

    /// Records or replaces `windowID`'s Snap Group membership on the screen
    /// `visibleFrame` belongs to, right after a placement wrote `action`
    /// there successfully — the single point every placement path (shortcut,
    /// directional gesture, edge snap, Snap Layouts) funnels through via
    /// `applyPlacement`.
    private func updateSnapGroup(action: WindowLayoutAction,
                                 windowID: CGWindowID,
                                 appliedRect: CGRect,
                                 visibleFrame: NSRect,
                                 fallbackFrame: WindowLayoutFrame) {
        guard let screen = screen(matchingVisibleFrame: visibleFrame, fallbackFrame: fallbackFrame) else { return }
        let group = snapGroups[screen.displayID] ?? SnapGroup(screenID: screen.displayID)
        let snapshot = currentFrames(for: group, on: screen)
        let updated = SnapGroupSupport.updated(group: group,
                                               windowID: windowID,
                                               action: action,
                                               appliedFrame: appliedRect,
                                               preSnapSize: appKitFrame(fromAX: fallbackFrame).size,
                                               currentFrames: snapshot.frames,
                                               gone: snapshot.gone,
                                               minimized: snapshot.minimized,
                                               gap: WindowLayoutGaps.windowGap)
        if updated.members.isEmpty {
            snapGroups.removeValue(forKey: screen.displayID)
        } else {
            snapGroups[screen.displayID] = updated
        }
        syncLinkedResizeObservers()
    }

    // MARK: - Snap Group memory across screen changes (spec §8)

    /// Started once, in `init()`, and never stopped: unlike an input tap,
    /// listening for a screen reconfiguration costs nothing while idle, and
    /// `reflowSnapGroupsForScreenChange()` itself already gates every real
    /// action on the feature being available and Accessibility being
    /// trusted, so there is nothing to suspend separately in `suspend()`.
    private var screenParametersObserver: NSObjectProtocol?

    private func startObservingScreenParameters() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSnapGroupReflow()
        }
    }

    /// `didChangeScreenParametersNotification` typically fires several
    /// times in a burst for one physical event (a monitor waking, macOS
    /// settling on a resolution) — coalesced the same way
    /// `KeepAwakeManager`'s own screen-parameters handling is, with enough
    /// delay that the new `NSScreen.screens` values have actually settled
    /// before anything reads them.
    private var snapGroupReflowScheduled = false

    private func scheduleSnapGroupReflow() {
        guard !snapGroupReflowScheduled else { return }
        snapGroupReflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.snapGroupReflowScheduled = false
            self?.reflowSnapGroupsForScreenChange()
        }
    }

    /// Spec §8: recomputes and re-places every Snap Group after a display
    /// reconfiguration (resolution change, connect, reconnect, arrangement
    /// change). A group whose screen no longer exists at all (disconnected)
    /// is simply dropped — there is no geometry left to recompute it
    /// against, and Vorssaint does not persist a group across a display
    /// actually going away and coming back in a later session, only within
    /// one still-connected screen changing shape. A minimized member is
    /// left alone (it has no on-screen position to write to right now);
    /// spec §7's own un-minimize handling puts it back once it reappears.
    private func reflowSnapGroupsForScreenChange() {
        guard AppFeature.windowLayout.isAvailable, AXIsProcessTrusted() else { return }
        for (displayID, group) in snapGroups {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                snapGroups.removeValue(forKey: displayID)
                continue
            }
            let relocations = SnapGroupSupport.relocatedZones(for: group,
                                                               newVisibleFrame: screen.visibleFrame,
                                                               windowGap: WindowLayoutGaps.windowGap,
                                                               screenGap: WindowLayoutGaps.screenGap)
            var updatedGroup = group
            for (windowID, rect) in relocations {
                guard let index = updatedGroup.members.firstIndex(where: { $0.windowID == windowID }),
                      !updatedGroup.members[index].isMinimized,
                      rect != updatedGroup.members[index].frame,
                      let actual = writeGroupMemberFrame(rect, windowID: windowID)
                else { continue }
                updatedGroup.members[index].frame = actual
            }
            if updatedGroup != group {
                snapGroups[displayID] = updatedGroup
            }
        }
        syncLinkedResizeObservers()
    }

    /// Writes `rect` (AppKit space) directly to `windowID`'s real window via
    /// a freshly resolved `AXUIElement` — unlike `writeLinkedResizeFrame`,
    /// this never requires an existing linked-resize observation, since a
    /// screen reflow must move every Snap Group member regardless of
    /// whether the separate Linked Resize toggle happens to be on for it.
    /// Marks the same self-initiated-echo record `writeLinkedResizeFrame`
    /// does, so a member that *is* also watched by linked resize never
    /// mistakes this write for a fresh user drag the moment its own
    /// notification arrives.
    @discardableResult
    private func writeGroupMemberFrame(_ rect: CGRect, windowID: CGWindowID) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
              }),
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.groupMemberMessagingTimeout)
        guard let axWindow = axElement(windowID: windowID, in: axApp) else { return nil }
        let axRect = axFrame(fromAppKit: rect)
        var size = axRect.size
        var origin = axRect.origin
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        }
        guard let actual = frame(of: axWindow) else { return nil }
        let actualFrame = appKitFrame(fromAX: actual)
        linkedResizeSelfInitiated[windowID] = (actualFrame, ProcessInfo.processInfo.systemUptime)
        return actualFrame
    }

    /// Drops `windowID` from every Snap Group it might be in — used wherever
    /// a placement leaves the group outright (maximize, full screen,
    /// restore, a display change) rather than moving within it.
    private func removeFromAllSnapGroups(_ windowID: CGWindowID) {
        for screenID in snapGroups.keys {
            snapGroups[screenID]?.members.removeAll { $0.windowID == windowID }
            if snapGroups[screenID]?.members.isEmpty == true {
                snapGroups.removeValue(forKey: screenID)
            }
        }
        syncLinkedResizeObservers()
    }

    // MARK: - Snap Group in Dock Preview / Switcher (spec §7/§12)

    /// Every other member of `windowID`'s Snap Group, each paired with its
    /// owning pid — `DockPreviewService`'s "Show group" reads this to raise
    /// them all. `nil` when `windowID` is not a group member at all, or is
    /// the group's only member (nothing to "show" beyond the window
    /// itself). Resolves each member's pid fresh from `CGWindowList` rather
    /// than storing one on `SnapGroupMember`, matching every other lookup
    /// in this file that needs a window's owner (`rawCurrentFrames`,
    /// `writeGroupMemberFrame`): a pid can outlive the process that had it
    /// (relaunched under a new one) between when a member joined and when
    /// this is asked, so it is never worth caching.
    func snapGroupPeers(of windowID: CGWindowID) -> [(windowID: CGWindowID, pid: pid_t)]? {
        guard let group = snapGroups.values.first(where: { grp in grp.members.contains { $0.windowID == windowID } }),
              group.members.count > 1,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var ownerPIDs: [CGWindowID: pid_t] = [:]
        for window in windows {
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { continue }
            ownerPIDs[id] = pid
        }
        let peers = group.members.compactMap { member -> (windowID: CGWindowID, pid: pid_t)? in
            guard member.windowID != windowID, let pid = ownerPIDs[member.windowID] else { return nil }
            return (member.windowID, pid)
        }
        return peers.isEmpty ? nil : peers
    }

    /// How long a cached `currentFrames(for:on:)` result stays usable.
    /// Deliberately *not* `edgeSnapSampleInterval`: that constant only
    /// throttles the *classification* half of `updateEdgeSnapDrag`, gated by
    /// `!drag.isMoving` — once a drag is classified as moving, every single
    /// `leftMouseDragged` callback the OS delivers (which can run well past
    /// 30 Hz on a fast mouse or trackpad) calls straight through to
    /// `resolvedEdgeSnapTarget` with no throttle of its own. Reusing that
    /// 33ms constant here would have refreshed on nearly every callback
    /// anyway; a materially longer window is what actually amortizes the
    /// Accessibility cost across many samples of one held position.
    private static let groupFramesCacheTTL: TimeInterval = 0.2

    /// Per-screen cache of `rawCurrentFrames(for:)`. Without it, a live drag
    /// would run a full `CGWindowListCopyWindowInfo` scan plus one
    /// Accessibility round trip per group member on every single
    /// mouse-moved event — and `groupMemberMessagingTimeout` below caps only
    /// the *per-member* worst case, not how often that worst case can be
    /// paid.
    private var groupFramesCache: [CGDirectDisplayID: (snapshot: GroupFrameSnapshot, at: TimeInterval)] = [:]

    private func currentFrames(for group: SnapGroup, on screen: NSScreen) -> GroupFrameSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = groupFramesCache[screen.displayID], now - cached.at < Self.groupFramesCacheTTL {
            return cached.snapshot
        }
        let snapshot = rawCurrentFrames(for: group)
        groupFramesCache[screen.displayID] = (snapshot, now)
        return snapshot
    }

    /// Accessibility messaging timeout for a Snap Group member's
    /// *background* frame read — a window the user is not currently
    /// interacting with, matching `focusedTarget(for:)`'s own 0.35s. An
    /// earlier, much shorter value here (issue found in on-device testing:
    /// TextEdit, an in-process Cocoa window, always answered fast enough to
    /// pass, while Chrome, Finder and Electron apps routinely did not,
    /// making free-space adaptation silently only work for the one kind of
    /// app it was tested against) traded a real timing risk for a
    /// correctness bug against exactly the apps most people actually use.
    /// The per-screen cache above, plus `SnapGroupSupport.pruned` no longer
    /// evicting on a merely-missing read (see `GroupFrameSnapshot`), are
    /// what keep this safe: the cost is paid at most once per
    /// `groupFramesCacheTTL`, and a slow read no longer costs the member
    /// its membership even when it is paid.
    private static let groupMemberMessagingTimeout: Float = 0.35

    /// The result of one Accessibility sweep over a Snap Group's members:
    /// `frames` for whichever ones answered with a usable frame; `gone` for
    /// the ones confirmed absent from `CGWindowList` entirely (closed) —
    /// `SnapGroupSupport.pruned` always evicts these; `minimized` for the
    /// ones confirmed minimized — spec §7, `pruned` keeps and marks these
    /// instead of evicting. Everything else (present in `CGWindowList`, not
    /// minimized, but Accessibility did not answer in time or answered with
    /// nothing usable) is in none of the three: not proof of anything
    /// except that this one read did not land, so the member is kept
    /// unmarked and simply contributes no edge to `freeSpace` this round.
    private struct GroupFrameSnapshot {
        var frames: [CGWindowID: CGRect] = [:]
        var gone: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
    }

    /// Live frames for a Snap Group's members, read via Accessibility right
    /// now. Never `member.frame`, which is the zone a member was placed into
    /// and stays fixed as the neighbour-adjacency reference
    /// (`SnapGroupSupport`); never cached at this layer (`currentFrames(for:
    /// on:)` above is the caching wrapper every caller actually uses), since
    /// noticing a hand-resized neighbour is the entire point of this
    /// feature. One retry immediately follows a failed per-window
    /// Accessibility read before giving up on it for this sweep — cheap
    /// (the app's own AX tree is already warm from the first attempt) and
    /// enough to smooth over an Electron window that briefly lags a frame
    /// behind its own reported geometry.
    private func rawCurrentFrames(for group: SnapGroup) -> GroupFrameSnapshot {
        guard !group.members.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return GroupFrameSnapshot() }
        var ownerPIDs: [CGWindowID: pid_t] = [:]
        for window in windows {
            guard let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { continue }
            ownerPIDs[windowID] = pid
        }
        var apps: [pid_t: AXUIElement] = [:]
        var snapshot = GroupFrameSnapshot()
        for member in group.members {
            guard let pid = ownerPIDs[member.windowID] else {
                // Not in CGWindowList at all under any owner: confirmed closed.
                snapshot.gone.insert(member.windowID)
                continue
            }
            let axApp = apps[pid] ?? {
                let created = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(created, Self.groupMemberMessagingTimeout)
                apps[pid] = created
                return created
            }()
            // Present in CGWindowList under this pid, so a lookup failure
            // here is Accessibility not answering, not the window being
            // gone — retried once before giving up on it for this sweep.
            guard let axWindow = retrying({ axElement(windowID: member.windowID, in: axApp) })
            else { continue }
            if boolAttribute(axWindow, kAXMinimizedAttribute as String) {
                snapshot.minimized.insert(member.windowID)
                continue
            }
            guard let frame = retrying({ frame(of: axWindow) }) else { continue }
            snapshot.frames[member.windowID] = appKitFrame(fromAX: frame)
        }
        return snapshot
    }

    /// Runs `read` once, and again if it came back nil — the whole retry
    /// budget `rawCurrentFrames` gives a single Accessibility read, cheap
    /// because the app's own AX tree is already warm from the first
    /// attempt, and enough to smooth over an Electron window that briefly
    /// lags a frame behind its own reported geometry.
    private func retrying<T>(_ read: () -> T?) -> T? {
        read() ?? read()
    }

    private func axElement(windowID: CGWindowID, in axApp: AXUIElement) -> AXUIElement? {
        windowsAttribute(axApp)?.first { AXWindowResolver.windowID(for: $0) == windowID }
    }

    // MARK: - Snap Assist (spec §4)

    /// Whether Snap Assist should react at all: the feature toggle, plus the
    /// same Accessibility/session gates every other Window Layout surface
    /// checks before touching AX or opening a panel.
    private var snapAssistEnabled: Bool {
        snapAssistMode != .off && snapAssistGatesPass
    }

    /// Phase 4's mode (spec §4's automatic-fill option): `.ask` opens the
    /// overlay exactly as before, `.auto` fills the first free cell
    /// immediately, `.off` matches the feature disabled entirely. See
    /// `SnapAssistSupport.Mode.resolved` for the migration from the legacy
    /// bool key.
    private var snapAssistMode: SnapAssistSupport.Mode {
        UserDefaults.standard.synchronize()
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.windowSnapAssistMode)
        let legacy = UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapAssistEnabled)
        return SnapAssistSupport.Mode.resolved(storedRawValue: stored, legacyEnabled: legacy)
    }

    /// The same Accessibility/session gates every other Window Layout
    /// surface checks before touching AX or opening a panel, independent of
    /// the mode toggle itself.
    private var snapAssistGatesPass: Bool {
        // `synchronize()` is deprecated, but still the one reliable nudge
        // to fold in a value another process just wrote (`defaults write`,
        // used to flip this key live during testing without a relaunch):
        // every other Window Layout toggle is only ever changed in-process,
        // through this same app's own Settings UI, so `UserDefaults`'s
        // in-memory copy is never behind for them, and none of them needed
        // this. This is the one read on a path exercised every time a
        // partial-zone placement lands, so the cost of asking is bounded to
        // exactly the moments it can matter.
        UserDefaults.standard.synchronize()
        return AppFeature.windowLayout.isAvailable && AXIsProcessTrusted()
    }

    /// Reacts to `action` just placing `windowID` successfully (spec §4):
    /// either advances the Snap Assist session already open because Snap
    /// Assist itself performed this placement (`fromSnapAssist`), or —
    /// every other case — starts a brand new session for this
    /// user-initiated placement, discarding whatever session, if any, was
    /// open before. Never re-derives "what's next" from live Snap Group
    /// membership the way an earlier version of this method did; see
    /// `SnapAssistSupport.SnapAssistSession`'s own doc comment for why that
    /// could loop.
    private func handleSnapAssist(action: WindowLayoutAction,
                                  windowID: CGWindowID,
                                  visibleFrame: NSRect,
                                  fallbackFrame: WindowLayoutFrame,
                                  fromSnapAssist: Bool) {
        guard snapAssistEnabled,
              SnapGroupSupport.joinsGroup(action),
              let screen = screen(matchingVisibleFrame: visibleFrame, fallbackFrame: fallbackFrame)
        else {
            if Self.snapAssistDebugLogging {
                let detail = "handleSnapAssist bailing before any session logic: action=\(action) " +
                    "windowID=\(windowID) fromSnapAssist=\(fromSnapAssist) enabled=\(self.snapAssistEnabled) " +
                    "joinsGroup=\(SnapGroupSupport.joinsGroup(action)) " +
                    "screenResolved=\(self.screen(matchingVisibleFrame: visibleFrame, fallbackFrame: fallbackFrame) != nil)"
                Self.snapAssistLog.debug("\(detail, privacy: .public)")
            }
            snapAssistSession = nil
            hideSnapAssist()
            return
        }

        if fromSnapAssist {
            // A pick can only ever advance the session it was made from —
            // never start a new one (spec: "placements performed by Snap
            // Assist itself never start a new session"). A session missing
            // entirely, or open on a different screen, means the pick
            // somehow outlived its own session (e.g. it was dismissed
            // between the click and this callback); nothing to advance.
            guard var session = snapAssistSession, session.screenID == screen.displayID else {
                snapAssistSession = nil
                hideSnapAssist()
                return
            }
            session = session.pick(action)
            guard let cell = session.currentCell else {
                // Every free cell in this layout is now filled — the
                // session is finished (spec: "or, if none remain, ends the
                // session").
                snapAssistSession = nil
                hideSnapAssist()
                return
            }
            snapAssistSession = session
            presentCell(cell, action: action, windowID: windowID, screen: screen,
                       visibleFrame: visibleFrame, fallbackFrame: fallbackFrame)
            return
        }

        // A user-initiated placement always starts fresh, occupancy
        // recomputed live from whatever is actually on screen right now —
        // never from a Set of cells some earlier session happened to have
        // tracked, which is what let a stale session keep re-opening
        // itself. Superseding whatever session was open before matches
        // spec: "starts a new session only if that layout still has free
        // cells" — halves with both halves now filled naturally yields no
        // session at all, ending Marco's loop.
        let occupied = occupiedSiblingCells(of: action, on: screen, excluding: windowID)
        let session = SnapAssistSupport.SnapAssistSession.start(from: action,
                                                                 screenID: screen.displayID,
                                                                 occupiedCells: occupied)
        if Self.snapAssistDebugLogging {
            let detail = "handleSnapAssist user-initiated: action=\(action) " +
                "windowID=\(windowID) siblings=\(SnapAssistSupport.siblingZones(of: action)) " +
                "occupied=\(occupied) " +
                "session=\(session.map { String(describing: $0.freeCells) } ?? "nil (no free cells)")"
            Self.snapAssistLog.debug("\(detail, privacy: .public)")
        }
        guard let session, let cell = session.currentCell else {
            snapAssistSession = nil
            hideSnapAssist()
            return
        }

        // Phase 4 (spec §4's automatic option): fill the first free cell
        // right away with no overlay and no session — the recursive
        // `handleSnapAssist(fromSnapAssist: true)` this triggers finds
        // `snapAssistSession` still `nil` and stops there on its own,
        // which is exactly spec §11's "for quarters fill only the first
        // free cell" (never chains through the rest of the layout).
        guard snapAssistMode == .ask else {
            autoFillCell(cell, windowID: windowID, screen: screen,
                        visibleFrame: visibleFrame, fallbackFrame: fallbackFrame)
            return
        }
        snapAssistSession = session
        presentCell(cell, action: action, windowID: windowID, screen: screen,
                   visibleFrame: visibleFrame, fallbackFrame: fallbackFrame)
    }

    /// Which of `action`'s sibling cells (`SnapAssistSupport.siblingZones`)
    /// already have some window — a Snap Group member or not — covering
    /// `SnapAssistSupport.occupiedCoverageThreshold` or more of them right
    /// now: essentially filling the cell, not merely sitting somewhere that
    /// happens to overlap it (see that constant's own doc comment for the
    /// on-device finding that set the bar there). Read from live on-screen
    /// window frames (`onScreenWindows`), not from Snap Group membership,
    /// which is only ever a record of windows *this feature* placed and
    /// would miss one the person dragged into place by hand.
    private func occupiedSiblingCells(of action: WindowLayoutAction,
                                      on screen: NSScreen,
                                      excluding windowID: CGWindowID) -> Set<WindowLayoutAction> {
        let cells = SnapAssistSupport.siblingZones(of: action)
        guard !cells.isEmpty else { return [] }
        let onScreen = onScreenWindows(on: screen).filter { $0.windowID != windowID }
        let frames = onScreen.map(\.appKitFrame)
        var occupied: Set<WindowLayoutAction> = []
        for cell in cells {
            let rect = WindowLayoutGeometry.rect(for: cell,
                                                 current: screen.visibleFrame,
                                                 visibleFrame: screen.visibleFrame,
                                                 windowGap: WindowLayoutGaps.windowGap,
                                                 screenGap: WindowLayoutGaps.screenGap)
            let isOccupied = SnapAssistSupport.cellIsOccupied(cellFrame: rect, by: frames)
            if Self.snapAssistDebugLogging {
                let cellArea = rect.width * rect.height
                let coverage = onScreen.map { window -> String in
                    let overlap = rect.intersection(window.appKitFrame)
                    let ratio = (overlap.isNull || cellArea <= 0) ? 0 : (overlap.width * overlap.height) / cellArea
                    return "windowID=\(window.windowID) pid=\(window.ownerPID) " +
                           "appKitFrame=\(window.appKitFrame) coverage=\(String(format: "%.2f", ratio))"
                }.joined(separator: " | ")
                let detail = "occupiedSiblingCells cell=\(cell) " +
                    "cellRect=\(rect) occupied=\(isOccupied) " +
                    "windows: \(coverage.isEmpty ? "(none on screen)" : coverage)"
                Self.snapAssistLog.debug("\(detail, privacy: .public)")
            }
            if isOccupied {
                occupied.insert(cell)
            }
        }
        return occupied
    }

    /// Phase 4's automatic option: places the most recently used offerable
    /// candidate straight into `cell`, with no overlay and no session —
    /// `presentCell`'s sibling for `.auto` mode, sharing its exact
    /// candidate/free-space computation so the window it picks is the same
    /// one `.ask` mode would have shown first. Does nothing (silently) when
    /// there is no candidate or the free space is not worth filling, same
    /// as `presentCell`'s own bailouts.
    private func autoFillCell(_ cell: WindowLayoutAction,
                              windowID: CGWindowID,
                              screen: NSScreen,
                              visibleFrame: NSRect,
                              fallbackFrame: WindowLayoutFrame) {
        guard let offering = snapAssistOffering(for: cell, windowID: windowID, screen: screen,
                                                visibleFrame: visibleFrame, fallbackFrame: fallbackFrame),
              let candidate = offering.items.first, let candidateWindowID = candidate.windowID
        else { return }
        applySnapAssistPlacement(cell, windowID: candidateWindowID, pid: candidate.windowOwnerPID, screen: screen)
    }

    /// The candidate list and free-space rect for `cell` — shared by
    /// `presentCell` (the overlay, spec §4's "ask") and `autoFillCell`
    /// (spec §4's "auto"), which differ only in what they do with the
    /// result, never in how it is computed. `nil` means there is nothing
    /// worth offering: no candidate window at all, or the free space left
    /// is not worth filling (spec §9's oversized-minimum-window bailout).
    private func snapAssistOffering(for cell: WindowLayoutAction,
                                    windowID: CGWindowID,
                                    screen: NSScreen,
                                    visibleFrame: NSRect,
                                    fallbackFrame: WindowLayoutFrame) -> (freeRect: CGRect, items: [SwitcherItem])? {
        var excluded: Set<CGWindowID> = [windowID]
        let group = prunedGroup(snapGroups[screen.displayID] ?? SnapGroup(screenID: screen.displayID), on: screen)
        excluded.formUnion(group.members.map(\.windowID))

        let items = snapAssistCandidates(on: screen, excluding: excluded)
        guard !items.isEmpty else { return nil }

        let theoreticalZone = WindowLayoutGeometry.rect(for: cell,
                                                        current: visibleFrame,
                                                        visibleFrame: visibleFrame,
                                                        windowGap: WindowLayoutGaps.windowGap,
                                                        screenGap: WindowLayoutGaps.screenGap)
        let freeRect = freeSpaceAdjusted(for: cell,
                                         theoreticalZone: theoreticalZone,
                                         visibleFrame: visibleFrame,
                                         fallbackFrame: fallbackFrame,
                                         excluding: nil)
        // Spec §9: a sliver of free space is not worth an overlay — the
        // same bailout `SnapGroupSupport.freeSpace` already applies to an
        // oversized minimum window.
        guard SnapAssistSupport.isOfferable(freeRect: freeRect) else {
            if Self.snapAssistDebugLogging {
                let detail = "snapAssistOffering: freeRect not offerable. cell=\(cell) " +
                    "theoreticalZone=\(theoreticalZone) " +
                    "freeRect=\(freeRect)"
                Self.snapAssistLog.debug("\(detail, privacy: .public)")
            }
            return nil
        }
        if Self.snapAssistDebugLogging {
            let detail = "snapAssistOffering: cell=\(cell) freeRect=\(freeRect) itemCount=\(items.count)"
            Self.snapAssistLog.debug("\(detail, privacy: .public)")
        }
        return (freeRect, items)
    }

    /// Builds the candidate list and free-space rect for `cell` and either
    /// presents it or, finding nothing worth showing, hides — the tail end
    /// shared by both `handleSnapAssist` branches (starting a session and
    /// advancing one).
    private func presentCell(_ cell: WindowLayoutAction,
                             action: WindowLayoutAction,
                             windowID: CGWindowID,
                             screen: NSScreen,
                             visibleFrame: NSRect,
                             fallbackFrame: WindowLayoutFrame) {
        guard let offering = snapAssistOffering(for: cell, windowID: windowID, screen: screen,
                                                visibleFrame: visibleFrame, fallbackFrame: fallbackFrame)
        else {
            snapAssistSession = nil
            hideSnapAssist()
            return
        }
        presentSnapAssist(cell: cell, freeRect: offering.freeRect, items: offering.items, screen: screen)
    }

    /// One window a Snap Assist candidate list or occupancy test can reason
    /// about — window-server ground truth, not the Switcher's own
    /// configurable view of it.
    private struct SnapAssistWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        /// Window-server space (top-left origin, Y down) — `kCGWindowBounds`'s
        /// own convention, matching `SwitcherItem.frame`.
        let quartzFrame: CGRect
        /// The same rect converted to AppKit space, for comparing against a
        /// theoretical cell rect (`WindowLayoutGeometry.rect`).
        let appKitFrame: CGRect
    }

    /// Every real, on-screen, layer-0 window overlapping `screen` right
    /// now, read straight from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
    /// — ground truth for "what does the person actually see on this
    /// display," independent of `WindowEnumerator`'s own Switcher-specific
    /// visibility rules (current-Space-only, per-app hide rules, and so
    /// on), none of which have anything to do with Snap Assist. Used both
    /// for the occupancy test (`occupiedSiblingCells`) and, filtered
    /// further, as the on-screen half of the candidate list
    /// (`snapAssistCandidates`).
    private func onScreenWindows(on screen: NSScreen) -> [SnapAssistWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { info -> SnapAssistWindow? in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzFrame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let appKit = appKitFrame(fromAX: WindowLayoutFrame(origin: quartzFrame.origin, size: quartzFrame.size))
            guard screen.frame.intersects(appKit) else { return nil }
            return SnapAssistWindow(windowID: windowID, ownerPID: ownerPID,
                                    quartzFrame: quartzFrame, appKitFrame: appKit)
        }
    }

    /// Whether `window` could actually be placed by a Snap Assist pick —
    /// the same core checks `target(from:)` applies to every other
    /// placement path (real `AXWindow` role, not a floating/dialog
    /// auxiliary window, big enough to be worth tiling, and genuinely
    /// resizable), applied here too so a candidate that would silently fail
    /// to move is never offered in the first place. On-device testing found
    /// exactly this: Chrome's own small, fixed-size "Chi usa Chrome?"
    /// profile-picker window was offered, and picking it raised the window
    /// without ever moving or resizing it — `AXUIElementIsAttributeSettable`
    /// for `kAXSizeAttribute` returns false for it, so `canSetFrame` alone
    /// would have caught it before it was ever shown as a card.
    /// `allowMinimized` is `true` only for the separate minimized-window
    /// walk in `snapAssistCandidates`, which is offering exactly those
    /// windows on purpose (spec §4 point 2) — everywhere else a minimized
    /// window is never placeable as-is. `canSetFrame` is skipped for a
    /// minimized window too: `activateSnapAssistTarget` un-minimizes before
    /// ever writing a frame, and `AXUIElementIsAttributeSettable` for
    /// `kAXPositionAttribute`/`kAXSizeAttribute` on a still-minimized window
    /// is not a reliable predictor of whether it will be resizable once
    /// restored, so checking it here risks dropping a perfectly placeable
    /// window rather than the unplaceable ones this exists to catch.
    private func isPlaceableSnapAssistCandidate(_ window: AXUIElement, allowMinimized: Bool = false) -> Bool {
        guard role(of: window) == (kAXWindowRole as String),
              allowMinimized || !boolAttribute(window, kAXMinimizedAttribute as String),
              stringAttribute(window, kAXSubroleAttribute as String) != "AXFloatingWindow",
              frame(of: window).map({ $0.size.width > 80 && $0.size.height > 80 }) ?? false
        else { return false }
        return allowMinimized || canSetFrame(on: window)
    }

    /// Debug record of one enumerated window and, if it was left out of the
    /// final candidate list, why — the field diagnosis spec §4 point 2
    /// asked for directly: "a debug log listing enumerated vs offered
    /// window IDs with the drop reason."
    private static let snapAssistCandidateLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                                        category: "snap-assist-candidates")

    /// Every window worth offering on `screen`: every on-screen, layer-0
    /// window there (`onScreenWindows`) plus every minimized window
    /// belonging to a regular running app (never in `.optionOnScreenOnly`
    /// by definition, so a separate Accessibility walk finds them), minus
    /// `excluded` — the window just placed, and every current Snap Group
    /// member. Deliberately bypasses `WindowEnumerator` entirely: both of
    /// its own entry points read `switcherCurrentSpaceOnly` and apply the
    /// Switcher's own per-app rules regardless of caller, neither of which
    /// spec §4 point 2 wants here. Ordered most recently used first
    /// (`WindowUseTracker`), with anything MRU never heard of appended
    /// after, on-screen before minimized.
    private func snapAssistCandidates(on screen: NSScreen, excluding excluded: Set<CGWindowID>) -> [SwitcherItem] {
        var itemsByWindowID: [CGWindowID: SwitcherItem] = [:]
        var enumeratedIDs: [CGWindowID] = []
        var dropped: [CGWindowID: String] = [:]
        var axAppsByPID: [pid_t: AXUIElement] = [:]
        func axApp(for pid: pid_t) -> AXUIElement {
            if let existing = axAppsByPID[pid] { return existing }
            let created = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(created, 0.35)
            axAppsByPID[pid] = created
            return created
        }

        for window in onScreenWindows(on: screen) {
            enumeratedIDs.append(window.windowID)
            guard window.ownerPID != ProcessInfo.processInfo.processIdentifier else {
                dropped[window.windowID] = "owned by Vorssaint itself"
                continue
            }
            guard !excluded.contains(window.windowID) else {
                dropped[window.windowID] = "excluded (just placed or Snap Group member)"
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: window.ownerPID), !app.isTerminated,
                  app.activationPolicy == .regular
            else {
                dropped[window.windowID] = "owner is not a regular running app"
                continue
            }
            guard let axWindow = axElement(windowID: window.windowID, in: axApp(for: window.ownerPID)) else {
                dropped[window.windowID] = "no AXUIElement resolved for this window"
                continue
            }
            guard isPlaceableSnapAssistCandidate(axWindow) else {
                dropped[window.windowID] = "not placeable (role/subrole/size/resizability)"
                continue
            }
            let title = stringAttribute(axWindow, kAXTitleAttribute as String) ?? ""
            itemsByWindowID[window.windowID] = .window(id: window.windowID,
                                                       title: title,
                                                       appName: app.localizedName ?? "",
                                                       pid: window.ownerPID,
                                                       isOnScreen: true,
                                                       frame: window.quartzFrame)
        }

        // Minimized windows never appear in `.optionOnScreenOnly` by
        // definition (spec §4 point 2: "plus minimized windows of running
        // apps"), so a separate Accessibility walk over every regular
        // running app finds them. Not filtered to this screen — a
        // minimized window has no meaningful on-screen position to test
        // against one.
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular
                && !app.isTerminated
                && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let windows = windowsAttribute(axApp(for: app.processIdentifier)) else { continue }
            for window in windows {
                guard boolAttribute(window, kAXMinimizedAttribute as String),
                      let windowID = AXWindowResolver.windowID(for: window)
                else { continue }
                enumeratedIDs.append(windowID)
                guard !excluded.contains(windowID) else {
                    dropped[windowID] = "excluded (just placed or Snap Group member)"
                    continue
                }
                guard itemsByWindowID[windowID] == nil else { continue }
                guard isPlaceableSnapAssistCandidate(window, allowMinimized: true) else {
                    dropped[windowID] = "not placeable (role/subrole/size)"
                    continue
                }
                let title = stringAttribute(window, kAXTitleAttribute as String) ?? ""
                let quartzFrame = frame(of: window).map { CGRect(origin: $0.origin, size: $0.size) } ?? .zero
                itemsByWindowID[windowID] = .window(id: windowID,
                                                    title: title,
                                                    appName: app.localizedName ?? "",
                                                    pid: app.processIdentifier,
                                                    isOnScreen: false,
                                                    isMinimized: true,
                                                    frame: quartzFrame)
            }
        }

        let mru = WindowUseTracker.shared.windows.filter { itemsByWindowID[$0] != nil }
        var ordered = mru.compactMap { itemsByWindowID[$0] }
        let mruSet = Set(mru)
        ordered.append(contentsOf: itemsByWindowID.keys.filter { !mruSet.contains($0) }.compactMap { itemsByWindowID[$0] })

        if Self.snapAssistDebugLogging {
            let offeredIDs = Set(ordered.compactMap(\.windowID))
            let lines = enumeratedIDs.map { id -> String in
                if offeredIDs.contains(id) { return "  windowID=\(id) -> offered" }
                return "  windowID=\(id) -> dropped (\(dropped[id] ?? "not found in final candidate map"))"
            }
            Self.snapAssistCandidateLog.debug(
                "Snap Assist candidates on screen \(screen.displayID): \(lines.joined(separator: "\n"), privacy: .public)")
        }

        return ordered
    }

    private func presentSnapAssist(cell: WindowLayoutAction,
                                   freeRect: CGRect,
                                   items: [SwitcherItem],
                                   screen: NSScreen) {
        let panel = snapAssistPanel ?? {
            let created = SnapAssistPanel()
            created.onDismiss = { [weak self] in self?.snapAssistSession = nil }
            snapAssistPanel = created
            return created
        }()
        let text = FeatureStrings.windowLayout(L10n.shared.language)
        panel.show(in: freeRect, on: screen, items: items, hint: text.snapAssistHint) { [weak self] item in
            self?.selectSnapAssistCandidate(item, cell: cell, screen: screen)
        }
        WindowPreviewProvider.shared.refreshPreviews(for: items) { [weak panel] windowID, image in
            panel?.updatePreview(image, for: windowID)
        }
    }

    private func hideSnapAssist() {
        snapAssistPanel?.hide()
    }

    /// Debug channel for Snap Assist placement failures, opted into with
    /// `VORSSAINT_SNAP_ASSIST_DEBUG` set in the environment: a click that
    /// reaches `selectSnapAssistCandidate` but never moves anything is
    /// otherwise silent, since `applySnapAssistPlacement` fails closed on
    /// purpose (spec §4's "try another window") rather than surfacing an
    /// error anywhere in the UI. Off by default so this still-experimental
    /// path stays quiet in the unified log for everyone else.
    private static let snapAssistDebugLogging =
        ProcessInfo.processInfo.environment["VORSSAINT_SNAP_ASSIST_DEBUG"] != nil
    private static let snapAssistLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                              category: "snap-assist")

    private func logSnapAssistFailure(_ reason: String,
                                      windowID: CGWindowID,
                                      pid: pid_t,
                                      window: AXUIElement?) {
        guard Self.snapAssistDebugLogging else { return }
        var detail = reason
        if let window {
            detail += " role=\(role(of: window) ?? "nil")"
            detail += " minimized=\(boolAttribute(window, kAXMinimizedAttribute as String))"
            detail += " subrole=\(stringAttribute(window, kAXSubroleAttribute as String) ?? "nil")"
            detail += " frame=\(String(describing: frame(of: window)))"
            detail += " fullScreen=\(boolAttribute(window, "AXFullScreen"))"
            detail += " canSetFrame=\(canSetFrame(on: window))"
        } else {
            detail += " (no AXUIElement resolved)"
        }
        Self.snapAssistLog.debug(
            "Snap Assist placement failed: \(detail, privacy: .public) windowID=\(windowID) pid=\(pid)")
    }

    /// A Snap Assist card was clicked: places the chosen window into `cell`
    /// through the exact same `applyPlacement` path every other placement
    /// uses, so it joins the Snap Group and free space is recomputed.
    /// `applyPlacement`'s own success hook fires again from inside this
    /// call, which is what offers the next free cell in the same layout
    /// without any extra bookkeeping here.
    ///
    /// On failure, nothing here hides the overlay: the same cell keeps
    /// showing (or, if closed already, is re-opened by the next placement)
    /// so the person can try a different window instead of losing the
    /// whole overlay to one failed pick.
    private func selectSnapAssistCandidate(_ item: SwitcherItem, cell: WindowLayoutAction, screen: NSScreen) {
        guard let windowID = item.windowID else { return }
        snapAssistPanel?.ignorePendingResign()
        applySnapAssistPlacement(cell, windowID: windowID, pid: item.windowOwnerPID, screen: screen)
    }

    /// Places an arbitrary window — not necessarily the focused one, unlike
    /// every other entry point in this file — into `action`'s zone on
    /// `screen`. Snap Assist is the only caller: its candidates come from
    /// the Switcher/Dock Preview machinery, which already knows about
    /// windows this service's own `focusedTarget(for:)` walk never looks at
    /// (a minimized window, or one behind the frontmost app).
    @discardableResult
    private func applySnapAssistPlacement(_ action: WindowLayoutAction,
                                          windowID: CGWindowID,
                                          pid: pid_t,
                                          screen: NSScreen) -> WindowLayoutResult {
        guard AXIsProcessTrusted() else { return finish(.failure(.missingAccessibility)) }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let window = axElement(windowID: windowID, in: axApp) else {
            logSnapAssistFailure("no AXUIElement for windowID", windowID: windowID, pid: pid, window: nil)
            return finish(.failure(.noWindow))
        }
        activateSnapAssistTarget(window: window, axApp: axApp, pid: pid)
        // `target(from:)` requires every candidate window id to already
        // appear "on screen", which a window just brought back from
        // minimized has not necessarily reported yet. Every window this
        // helper is ever asked about came from a live enumeration a moment
        // ago, so this pass allows the fuller `.optionAll` set instead of
        // gating on `.optionOnScreenOnly`.
        guard let allWindowIDs = allWindowIDs(),
              let app = NSRunningApplication(processIdentifier: pid),
              let target = target(from: window,
                                  app: app,
                                  onScreenWindowIDs: allWindowIDs,
                                  capability: action.targetCapability)
        else {
            logSnapAssistFailure("target(from:) rejected the window", windowID: windowID, pid: pid, window: window)
            return finish(.failure(.noWindow))
        }
        pruneWindowState(keeping: target.key)
        return applyPlacement(action, to: target, visibleFrame: screen.visibleFrame, fromSnapAssist: true)
    }

    /// Un-minimizes and raises `window` directly through the AXUIElement
    /// `applySnapAssistPlacement` already resolved — no second resolution
    /// pass — and activates its owning app without going through
    /// `WindowActivator.activate`, whose `ActivationHandoff.yield(to:)`
    /// always calls `NSApp.activate(ignoringOtherApps: true)` before
    /// yielding to the target. That dance exists for the Switcher/Dock
    /// Preview case, where Vorssaint's own panel is genuinely key and
    /// frontmost and the handoff has to hand real activation away cleanly;
    /// Snap Assist's panel is deliberately never activating in the first
    /// place (spec §4 must not steal focus), so routing through it anyway
    /// briefly activated Vorssaint for no reason and, on a real Mac, left
    /// the target app still mid activation-transition at the exact moment
    /// `target(from:)` tried to read it — failing the placement silently.
    /// A direct `app.activate(from:options:)`, the same call
    /// `WindowActivator` itself falls through to, needs no such preamble:
    /// it is documented to work regardless of which app is currently
    /// active.
    private func activateSnapAssistTarget(window: AXUIElement, axApp: AXUIElement, pid: pid_t) {
        if boolAttribute(window, kAXMinimizedAttribute as String) {
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

    private func allWindowIDs() -> Set<CGWindowID>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(windows.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    /// The owning process of an on-screen window, looked up by a single
    /// window-server scan — the same lookup `rawCurrentFrames` inlines for
    /// every member at once, factored out here because starting to watch a
    /// linked-resize member happens one window at a time, on group changes
    /// that are rare compared to the 30 Hz a drag samples at.
    private func ownerPID(for windowID: CGWindowID) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID else { continue }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }

    // MARK: - Linked resize of snapped neighbours (spec §6)

    /// Every member of `group`'s *theoretical* zone on `screen` — the
    /// `WindowLayoutAction`'s own rect (halves/thirds/quarters/sixths math,
    /// gap included), computed fresh from `member.action` every time,
    /// never read from `member.frame`. `member.frame` is the *placed*
    /// rect, which free-space snapping (spec §5) can legitimately differ
    /// from the theoretical one — a neighbour placed into the space
    /// another member's earlier resize freed lands somewhere other than
    /// the plain half/third/quarter — and `SnapLinkedResizeSupport`
    /// needs the theoretical rect specifically for its adjacency test, so
    /// two members placed by different paths (one exactly on its
    /// theoretical zone, one free-space-adjusted) are still correctly
    /// found touching. `current` is passed as `screen.visibleFrame` for
    /// every `joinsGroup` action `WindowLayoutGeometry.rect` computes here
    /// (halves, thirds, quarters, sixths, corners) — none of them read it,
    /// only actions this function is never asked about (restore, center,
    /// a display change, ...) do.
    private func theoreticalZones(for group: SnapGroup, on screen: NSScreen) -> [CGWindowID: CGRect] {
        var zones: [CGWindowID: CGRect] = [:]
        for member in group.members {
            zones[member.windowID] = WindowLayoutGeometry.rect(for: member.action,
                                                                current: screen.visibleFrame,
                                                                visibleFrame: screen.visibleFrame,
                                                                windowGap: WindowLayoutGaps.windowGap,
                                                                screenGap: WindowLayoutGaps.screenGap)
        }
        return zones
    }

    /// Makes the set of watched Accessibility observers match every current
    /// Snap Group member exactly, across every screen — called after every
    /// group mutation (`updateSnapGroup`, `prunedGroup`,
    /// `removeFromAllSnapGroups`) and once from `syncWithPreferences()` so
    /// toggling the feature itself starts or stops watching immediately
    /// instead of waiting for the next placement.
    private func syncLinkedResizeObservers() {
        let wanted: Set<CGWindowID> = linkedResizeFeatureAvailable
            ? Set(snapGroups.values.flatMap { $0.members.map(\.windowID) })
            : []
        let watching = Set(linkedResizeObservers.keys)
        let toStop = watching.subtracting(wanted)
        let toStart = wanted.subtracting(watching)
        if !toStop.isEmpty || !toStart.isEmpty {
            Self.linkedResizeLog.debug("""
                syncLinkedResizeObservers: watching=\(watching, privacy: .public) \
                wanted=\(wanted, privacy: .public) \
                stopping=\(toStop, privacy: .public) starting=\(toStart, privacy: .public)
                """)
        }
        for windowID in toStop { stopWatchingLinkedResize(windowID) }
        for windowID in toStart { startWatchingLinkedResize(windowID) }
    }

    /// A short, human-readable tag for a process — bundle id when
    /// available, else the raw pid — spliced into every linked-resize log
    /// line so "which app" is legible at a glance in a `log stream` across
    /// several apps at once, instead of having to cross-reference a bare
    /// pid.
    private func appLabel(for pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }

    private func startWatchingLinkedResize(_ windowID: CGWindowID) {
        guard let pid = ownerPID(for: windowID) else {
            Self.linkedResizeLog.debug("startWatching \(windowID): no owner pid found via CGWindowList")
            return
        }
        let label = appLabel(for: pid)

        // One `AXObserver` — and one app-level notification registration —
        // per process, reused across every window of that process already
        // being watched (an app with several tiled windows, Chrome say,
        // must never end up with N observers all receiving every one of
        // that app's N windows' notifications).
        let appObservation: LinkedResizeAppObservation
        if let existing = linkedResizeAppObservers[pid] {
            appObservation = existing
        } else {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.linkedResizeMessagingTimeout)
            var observerRef: AXObserver?
            let createError = AXObserverCreate(pid, windowLayoutLinkedResizeAXCallback, &observerRef)
            guard createError == .success, let observer = observerRef else {
                Self.linkedResizeLog.debug("""
                    startWatching \(windowID) \(label, privacy: .public): AXObserverCreate failed \
                    (\(String(describing: createError), privacy: .public))
                    """)
                return
            }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            // Registered on the *application* element, once per process:
            // per Apple's own header comments these are posted "at the end
            // of the window move/resize" with the resized/moved window as
            // the notification's element — this is the pair standard
            // AppKit windows actually post, and the one that matters for a
            // real drag or an external AX write to be noticed at all.
            let windowResizedError = AXObserverAddNotification(observer, axApp,
                                                                kAXWindowResizedNotification as CFString, refcon)
            let windowMovedError = AXObserverAddNotification(observer, axApp,
                                                              kAXWindowMovedNotification as CFString, refcon)
            Self.linkedResizeLog.debug("""
                startWatching \(label, privacy: .public): app-level \
                AXWindowResized=\(String(describing: windowResizedError), privacy: .public) \
                AXWindowMoved=\(String(describing: windowMovedError), privacy: .public)
                """)
            guard windowResizedError == .success || windowMovedError == .success else {
                Self.linkedResizeLog.debug("startWatching \(label, privacy: .public): app-level registration failed entirely, not watching")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let created = LinkedResizeAppObservation(observer: observer, app: axApp)
            linkedResizeAppObservers[pid] = created
            appObservation = created
        }

        guard let axWindow = axElement(windowID: windowID, in: appObservation.app) else {
            Self.linkedResizeLog.debug("startWatching \(windowID) \(label, privacy: .public): no matching AX window element")
            stopAppObservationIfUnused(pid: pid)
            return
        }
        // Every subsequent write/read through this specific element — every
        // one `writeLinkedResizeFrame` and `processLinkedResize` make — is
        // bounded by this timeout, not the system default, which is what
        // keeps one hung member's app from stalling the main thread.
        AXUIElementSetMessagingTimeout(axWindow, Self.linkedResizeMessagingTimeout)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registered on the window element: some apps do post these for
        // geometry changes, but an ordinary Cocoa window (TextEdit
        // included) generally does not — kept as a defensive extra
        // alongside the app-level pair above, not the primary signal.
        let resizedError = AXObserverAddNotification(appObservation.observer, axWindow,
                                                      kAXResizedNotification as CFString, refcon)
        let movedError = AXObserverAddNotification(appObservation.observer, axWindow,
                                                    kAXMovedNotification as CFString, refcon)
        Self.linkedResizeLog.debug("""
            startWatching \(windowID) \(label, privacy: .public): window-level \
            AXResized=\(String(describing: resizedError), privacy: .public) \
            AXMoved=\(String(describing: movedError), privacy: .public)
            """)

        linkedResizeObservers[windowID] = LinkedResizeObservation(window: axWindow, pid: pid)
        linkedResizeAppObservers[pid]?.watchedWindows.insert(windowID)
        Self.linkedResizeLog.debug("startWatching \(windowID) \(label, privacy: .public): now watching (shared app observer)")
    }

    private func stopWatchingLinkedResize(_ windowID: CGWindowID) {
        guard let observation = linkedResizeObservers.removeValue(forKey: windowID) else { return }
        Self.linkedResizeLog.debug("stopWatching \(windowID) \(self.appLabel(for: observation.pid), privacy: .public)")
        if let appObservation = linkedResizeAppObservers[observation.pid] {
            AXObserverRemoveNotification(appObservation.observer, observation.window, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(appObservation.observer, observation.window, kAXMovedNotification as CFString)
            linkedResizeAppObservers[observation.pid]?.watchedWindows.remove(windowID)
        }
        linkedResizePendingWindows.remove(windowID)
        linkedResizeSelfInitiated.removeValue(forKey: windowID)
        stopAppObservationIfUnused(pid: observation.pid)
    }

    /// Tears down the shared per-process observer once nothing of that
    /// process is being watched any more — called after every window
    /// leaves (`stopWatchingLinkedResize`) and after a failed window-level
    /// registration (`startWatchingLinkedResize`), so a process that never
    /// ends up with a single successfully watched window does not leave an
    /// app-level observer running for nothing.
    private func stopAppObservationIfUnused(pid: pid_t) {
        guard let appObservation = linkedResizeAppObservers[pid], appObservation.watchedWindows.isEmpty else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObservation.observer), .commonModes)
        AXObserverRemoveNotification(appObservation.observer, appObservation.app, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(appObservation.observer, appObservation.app, kAXWindowMovedNotification as CFString)
        linkedResizeAppObservers.removeValue(forKey: pid)
    }

    /// Resolves an app-level notification's `element` (the window that
    /// actually moved/resized, per Apple's own header comments for
    /// `kAXWindowResizedNotification`/`kAXWindowMovedNotification`) to one
    /// of `pid`'s watched windowIDs. Three passes, cheapest first:
    ///
    /// 1. The private `_AXUIElementGetWindow` bridge `AXWindowResolver`
    ///    wraps — usually exact and free of any extra AX round trip, but
    ///    reported flaky specifically for Chromium/Electron windows, which
    ///    do not always back it with a value that resolves.
    /// 2. Element identity: `AXUIElement` supports `CFEqual` for "the same
    ///    underlying accessibility object", so the cached element from
    ///    `startWatchingLinkedResize` is compared directly against the
    ///    notification's `element` — exact, and also free of any AX call.
    /// 3. Frame matching: reads `element`'s own live frame and the frame of
    ///    every one of `pid`'s watched windows, and returns whichever one is
    ///    close enough to count as the same window. The one path that costs
    ///    real AX round trips, kept last and only reached when the first two
    ///    both come up empty — which the flaky-identifier apps this exists
    ///    for are exactly the case that needs it.
    private func resolveLinkedResizeWindowID(element: AXUIElement, pid: pid_t) -> CGWindowID? {
        guard let watched = linkedResizeAppObservers[pid]?.watchedWindows, !watched.isEmpty else { return nil }

        if let windowID = AXWindowResolver.windowID(for: element), watched.contains(windowID) {
            return windowID
        }
        if let matched = watched.first(where: { windowID in
            guard let cached = linkedResizeObservers[windowID]?.window else { return false }
            return CFEqual(cached, element)
        }) {
            return matched
        }
        guard let elementFrame = frame(of: element) else { return nil }
        return watched.first { windowID in
            guard let cached = linkedResizeObservers[windowID]?.window,
                  let cachedFrame = frame(of: cached)
            else { return false }
            return elementFrame.isClose(to: cachedFrame, tolerance: 2)
        }
    }

    /// Called from the C observer callback (on the main run loop, since the
    /// observer's run-loop source was added there — no further dispatch
    /// needed, matching `AutoQuitService.handleAX`). Resolves the notifying
    /// element to one of *this process's* watched windows
    /// (`resolveLinkedResizeWindowID`) before doing anything else — a
    /// shared observer now receives every one of a process's watched
    /// windows' notifications together, so telling them apart correctly is
    /// the whole job here, not an afterthought.
    func handleLinkedResizeNotification(element: AXUIElement, notification: String) {
        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        let label = appLabel(for: elementPID)
        guard elementPID != 0, linkedResizeAppObservers[elementPID] != nil else {
            Self.linkedResizeLog.debug("""
                notification \(notification, privacy: .public) \(label, privacy: .public): \
                no app observation for this pid, ignoring
                """)
            return
        }
        guard let windowID = resolveLinkedResizeWindowID(element: element, pid: elementPID) else {
            Self.linkedResizeLog.debug("""
                notification \(notification, privacy: .public) \(label, privacy: .public): \
                could not resolve the notifying element to any watched window of this process \
                (tried AX window id, element identity, and frame matching) — skipping this notification
                """)
            return
        }
        Self.linkedResizeLog.debug("notification \(notification, privacy: .public) window \(windowID) \(label, privacy: .public): scheduling")
        scheduleLinkedResizeProcessing(windowID: windowID)
    }

    /// Coalesces a burst of notifications for one window down to a single
    /// throttled pass. The self-initiated echo check happens once, inside
    /// `processLinkedResize`, against a live-read frame — not here — since
    /// only a live read can tell an echo of this service's own write apart
    /// from a genuine new resize that happens to start in the same instant.
    private func scheduleLinkedResizeProcessing(windowID: CGWindowID) {
        guard linkedResizeFeatureAvailable else { return }
        guard linkedResizePendingWindows.insert(windowID).inserted else {
            Self.linkedResizeLog.debug("schedule \(windowID): already pending, coalesced into the queued pass")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + linkedResizeThrottleInterval) { [weak self] in
            self?.processLinkedResize(windowID: windowID)
        }
    }

    /// Whether `liveFrame` for `windowID` is just the echo of a frame this
    /// service wrote to it a moment ago, rather than a fresh notification
    /// from the user's own drag. Frame correlation, not a time window: a
    /// notification is only ever swallowed when the window's *current*
    /// geometry still actually matches what was written, within
    /// `linkedResizeSelfInitiatedFrameTolerance` — a genuine resize that
    /// starts moments after a linked write (three or more members chained
    /// together, say) is caught immediately because its live frame no
    /// longer matches, instead of being silently dropped for however long a
    /// fixed window happened to be open.
    private func isSelfInitiatedEcho(windowID: CGWindowID, liveFrame: CGRect) -> Bool {
        guard let marked = linkedResizeSelfInitiated[windowID],
              ProcessInfo.processInfo.systemUptime - marked.at < linkedResizeSelfInitiatedFallbackExpiry
        else { return false }
        let tolerance = linkedResizeSelfInitiatedFrameTolerance
        return abs(liveFrame.minX - marked.frame.minX) <= tolerance
            && abs(liveFrame.minY - marked.frame.minY) <= tolerance
            && abs(liveFrame.width - marked.frame.width) <= tolerance
            && abs(liveFrame.height - marked.frame.height) <= tolerance
    }

    /// The throttled linked-resize pass: reads `windowID`'s live frame right
    /// now (not whatever frame the triggering notification carried, which
    /// may be stale by the time a coalesced burst finishes), compares it
    /// against the group's stored zone for that member — the same
    /// reference `SnapGroupSupport` uses everywhere else — and, if that is
    /// a genuine resize touching a neighbour, applies the adjustments.
    /// Whether spec §1's drag-away restore is on — checked, like every
    /// other Window Layout toggle, right before it can matter rather than
    /// cached.
    private var restoreSizeOnDragEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapRestoreSizeOnDrag)
    }

    /// Writes `member`'s pre-snap size back, keeping it under the pointer's
    /// current position (`NSEvent.mouseLocation`, the same global AppKit
    /// space `newFrame` is already in) via `SnapRestoreOnDragSupport
    /// .restoredFrame`, then drops it from every group — it is no longer
    /// snapped, exactly like any other window moved by hand. Reuses
    /// `writeLinkedResizeFrame` so this write is marked self-initiated the
    /// same way a linked-resize write is, and never mistaken for a second,
    /// independent drag once its own notification arrives.
    private func performRestoreOnDrag(windowID: CGWindowID, member: SnapGroupMember, newFrame: CGRect, label: String) {
        guard let restoreSize = member.restoreSize else { return }
        let cursor = NSEvent.mouseLocation
        let restored = SnapRestoreOnDragSupport.restoredFrame(currentFrame: newFrame,
                                                               restoreSize: restoreSize,
                                                               cursor: cursor)
        Self.linkedResizeLog.debug("""
            restore-on-drag \(windowID) \(label, privacy: .public): left its zone, restoring to \
            \(String(describing: restored), privacy: .public)
            """)
        writeLinkedResizeFrame(restored, windowID: windowID)
        removeFromAllSnapGroups(windowID)
    }

    private func processLinkedResize(windowID: CGWindowID) {
        linkedResizePendingWindows.remove(windowID)
        guard linkedResizeFeatureAvailable else {
            Self.linkedResizeLog.debug("process \(windowID): feature not available, aborting")
            return
        }
        guard let observation = linkedResizeObservers[windowID] else {
            Self.linkedResizeLog.debug("process \(windowID): no observation for this window (not/no longer watched)")
            return
        }
        let label = appLabel(for: observation.pid)
        // The owning app quitting is the one way a member stops existing
        // without ever posting a notification this service would otherwise
        // notice — checked before touching Accessibility at all, since a
        // terminated process is exactly the case a messaging timeout exists
        // to protect against, not something to spend one on.
        guard let runningApp = NSRunningApplication(processIdentifier: observation.pid), !runningApp.isTerminated
        else {
            Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): owning app gone, dropping observer")
            stopWatchingLinkedResize(windowID)
            return
        }
        // A read that times out (a real risk against Chromium/Electron and
        // Finder under load, even at `linkedResizeMessagingTimeout`) is
        // never treated as "this member is gone" — it simply skips this one
        // notification and leaves the member watched, so the next
        // notification tries again instead of the neighbour silently
        // losing its link.
        guard !boolAttribute(observation.window, kAXMinimizedAttribute as String) else {
            Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): window is minimized, skipping this notification")
            return
        }
        guard let liveAXFrame = frame(of: observation.window) else {
            Self.linkedResizeLog.debug("""
                process \(windowID) \(label, privacy: .public): could not read the live AX frame (timeout or \
                transient AX failure) — skipping this notification, member stays watched, next notification retries
                """)
            return
        }
        let newFrame = appKitFrame(fromAX: liveAXFrame)
        guard !isSelfInitiatedEcho(windowID: windowID, liveFrame: newFrame) else {
            Self.linkedResizeLog.debug("""
                process \(windowID) \(label, privacy: .public): live frame \
                \(String(describing: newFrame), privacy: .public) matches a recent self-initiated write, \
                treating as an echo
                """)
            return
        }

        guard let group = snapGroups.values.first(where: { grp in grp.members.contains { $0.windowID == windowID } }),
              let resizedMember = group.members.first(where: { $0.windowID == windowID })
        else {
            Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): window is not a member of any Snap Group right now")
            return
        }
        let oldFrame = resizedMember.frame
        guard oldFrame != newFrame else {
            Self.linkedResizeLog.debug("""
                process \(windowID) \(label, privacy: .public): live frame matches the stored zone \
                \(String(describing: oldFrame), privacy: .public), nothing changed
                """)
            return
        }
        Self.linkedResizeLog.debug("""
            process \(windowID) \(label, privacy: .public): old=\(String(describing: oldFrame), privacy: .public) \
            new=\(String(describing: newFrame), privacy: .public)
            """)

        // A genuine resize of a group member is "another action" (spec §4):
        // Snap Assist is offering a candidate for a *different* free cell,
        // and the person just started reshaping the layout instead of
        // picking one, so the overlay has nothing left to be right about.
        // Checked before `adjustments` below on purpose — this fires even
        // when the moved edge faces open screen and no neighbour ends up
        // adjusted, since it is the resize itself, not its knock-on effect,
        // that makes the offer stale. A plain move — size unchanged within
        // `SnapLinkedResizeSupport.moveSizeTolerance`, the same tolerance
        // `adjustments` itself uses to tell a move from a resize — leaves
        // the overlay alone.
        let sizeDelta = max(abs(newFrame.width - oldFrame.width), abs(newFrame.height - oldFrame.height))
        if sizeDelta > SnapLinkedResizeSupport.moveSizeTolerance {
            hideSnapAssist()
        }

        // Spec §1's last row: a plain move (never a resize — `sizeDelta`
        // uses the exact tolerance `SnapLinkedResizeSupport.adjustments`
        // itself uses to tell the two apart) that carried the member off
        // its own zone is a title-bar drag-away, not a reshape of the
        // layout. Restoring here, before `adjustments` even runs, is what
        // keeps this from ever fighting the linked-resize path: a genuine
        // resize never reaches this branch (`stillAnchored` stays true for
        // a resize along the snapped edge, by the same rule the group's own
        // lazy prune uses), so the two features can never both react to the
        // same notification.
        if sizeDelta <= SnapLinkedResizeSupport.moveSizeTolerance,
           restoreSizeOnDragEnabled,
           SnapRestoreOnDragSupport.shouldRestore(member: resizedMember, newFrame: newFrame,
                                                  gap: WindowLayoutGaps.windowGap) {
            performRestoreOnDrag(windowID: windowID, member: resizedMember, newFrame: newFrame, label: label)
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayID == group.screenID }) else {
            Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): could not resolve a screen for this group's displayID")
            return
        }
        let zones = theoreticalZones(for: group, on: screen)

        var liveFrames = rawCurrentFrames(for: group).frames
        liveFrames[windowID] = newFrame

        let adjustments = SnapLinkedResizeSupport.adjustments(
            resizedWindowID: windowID,
            oldFrame: oldFrame,
            newFrame: newFrame,
            group: group,
            theoreticalZones: zones,
            gap: WindowLayoutGaps.windowGap,
            currentFrames: liveFrames,
            minimumSize: { _ in Self.linkedResizeMinimumSizeGuess })
        guard !adjustments.isEmpty else {
            Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): no neighbour touches the edge(s) that moved")
            return
        }
        Self.linkedResizeLog.debug("process \(windowID) \(label, privacy: .public): \(adjustments.count) adjustment(s) computed, applying")

        applyLinkedResizeAdjustments(adjustments,
                                     resizedWindowID: windowID,
                                     oldFrame: oldFrame,
                                     newFrame: newFrame,
                                     group: group,
                                     theoreticalZones: zones)
    }

    /// Writes every adjustment's frame, then, only when a neighbour's actual
    /// size came back smaller than requested (Accessibility can shrink
    /// further than requested when an app enforces its own minimum size,
    /// something Accessibility has no attribute to query in advance), runs
    /// one corrective pass that pulls the resized window's own edge back to
    /// match, so the two frames end up flush rather than overlapping (spec
    /// §6: "the divider stops at the minimum").
    ///
    /// Deliberately never touches `snapGroups[group.screenID]`: a member's
    /// stored `frame` is its *zone* — fixed at the moment it joined the
    /// group, exactly as `SnapGroupSupport`/`SnapLinkedResizeSupport`
    /// document and rely on for every adjacency decision — and a linked
    /// resize is not a placement, so it must never touch it. Writing the
    /// live result back in here used to be exactly the bug: after the
    /// first step of a resize drag rewrote the *neighbour's* stored zone to
    /// its new live size while the *resized* window's own stored zone (only
    /// ever written when a pushback happened to occur) stayed behind, the
    /// two members' zones silently drifted out of the flush relationship
    /// `touchingEdges` checks, and every following step in the same drag
    /// read "not touching" and did nothing. Every caller that needs a
    /// member's *current* boundary already re-reads it live via
    /// Accessibility at the moment it needs it (`currentFrames`,
    /// `rawCurrentFrames`) — the zone was never the right place to keep
    /// that up to date.
    private func applyLinkedResizeAdjustments(_ adjustments: [SnapLinkedResizeSupport.Adjustment],
                                              resizedWindowID: CGWindowID,
                                              oldFrame: CGRect,
                                              newFrame: CGRect,
                                              group: SnapGroup,
                                              theoreticalZones: [CGWindowID: CGRect]) {
        // One shared deadline for both the first pass below and the
        // corrective pass further down — each member write is already
        // capped individually by `linkedResizeMessagingTimeout`, but this
        // bounds how long several slow members in a row are allowed to add
        // up to before the rest are simply left for the next tick.
        let budgetDeadline = ProcessInfo.processInfo.systemUptime + Self.linkedResizeApplyBudget
        let appliedFrames = writeAdjustments(adjustments, deadline: budgetDeadline)

        var discoveredMinimums: [CGWindowID: CGSize] = [:]
        for adjustment in adjustments where adjustment.windowID != resizedWindowID {
            guard let actual = appliedFrames[adjustment.windowID],
                  abs(actual.width - adjustment.frame.width) > frameTolerance
                    || abs(actual.height - adjustment.frame.height) > frameTolerance
            else { continue }
            discoveredMinimums[adjustment.windowID] = actual.size
        }

        guard !discoveredMinimums.isEmpty, ProcessInfo.processInfo.systemUptime < budgetDeadline else { return }
        var liveFrames = appliedFrames
        liveFrames[resizedWindowID] = newFrame
        let corrected = SnapLinkedResizeSupport.adjustments(
            resizedWindowID: resizedWindowID,
            oldFrame: oldFrame,
            newFrame: newFrame,
            group: group,
            theoreticalZones: theoreticalZones,
            gap: WindowLayoutGaps.windowGap,
            currentFrames: liveFrames,
            minimumSize: { discoveredMinimums[$0] ?? Self.linkedResizeMinimumSizeGuess })
        for adjustment in corrected where adjustment.windowID == resizedWindowID {
            writeLinkedResizeFrame(adjustment.frame, windowID: resizedWindowID)
        }
    }

    /// Writes every adjustment's frame in order, stopping — without writing
    /// the rest — the moment `deadline` passes: bounds the worst case where
    /// several members in a row are all slow (each individually capped at
    /// `linkedResizeMessagingTimeout`, but a run of them could otherwise
    /// still add up to seconds on the main thread). A member skipped this
    /// way is simply absent from the result, which already reads as "could
    /// not be reached" to every caller downstream (`SnapLinkedResizeSupport`
    /// skips a missing frame rather than guessing at it, and the corrective
    /// pass below never discovers a minimum for it either) — it is picked
    /// up again on the next notification instead.
    private func writeAdjustments(_ adjustments: [SnapLinkedResizeSupport.Adjustment],
                                  deadline: TimeInterval) -> [CGWindowID: CGRect] {
        var appliedFrames: [CGWindowID: CGRect] = [:]
        for adjustment in adjustments {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            appliedFrames[adjustment.windowID] = writeLinkedResizeFrame(adjustment.frame, windowID: adjustment.windowID)
        }
        return appliedFrames
    }

    /// Writes `rect` (AppKit coordinates) to `windowID` via the Accessibility
    /// observer already kept for it, then reads back what was actually
    /// accepted — the only way to discover an app-enforced minimum size
    /// Accessibility never exposes directly — and records that as the new
    /// self-initiated marker (`isSelfInitiatedEcho`) so the notification
    /// this write provokes is not mistaken for a fresh user drag. Returns
    /// `nil` when the window cannot be reached at all (closed mid-drag, the
    /// short `linkedResizeMessagingTimeout` tripping on a hung app, ...), in
    /// which case the caller leaves its stored zone as it was and skips it
    /// for any further correction this pass.
    @discardableResult
    private func writeLinkedResizeFrame(_ rect: CGRect, windowID: CGWindowID) -> CGRect? {
        guard let observation = linkedResizeObservers[windowID] else {
            Self.linkedResizeLog.debug("write \(windowID): no observation window element, cannot write")
            return nil
        }
        let axWindow = observation.window
        let label = appLabel(for: observation.pid)
        let axRect = axFrame(fromAppKit: rect)
        var size = axRect.size
        var origin = axRect.origin
        let sizeError: AXError
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            sizeError = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        } else {
            sizeError = .failure
        }
        let positionError: AXError
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            positionError = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        } else {
            positionError = .failure
        }
        // A failed read-back (the short timeout tripping, most likely) means
        // there is no way to know what — if anything — actually landed, so
        // this is reported as a miss rather than assumed to have succeeded:
        // the stored zone is better left stale than set to a frame nobody
        // ever confirmed, and a member reported this way is exactly what
        // `writeAdjustments` and the corrective pass already treat as
        // unreachable.
        guard let actual = frame(of: axWindow) else {
            Self.linkedResizeLog.debug("""
                write \(windowID) \(label, privacy: .public) requested \(String(describing: rect), privacy: .public): \
                setSize=\(String(describing: sizeError), privacy: .public) \
                setPosition=\(String(describing: positionError), privacy: .public) \
                read-back failed (timeout or transient AX failure) — member stays watched, treated as \
                unreachable for this pass only
                """)
            return nil
        }
        let actualFrame = appKitFrame(fromAX: actual)
        Self.linkedResizeLog.debug("""
            write \(windowID) \(label, privacy: .public) requested \(String(describing: rect), privacy: .public): \
            setSize=\(String(describing: sizeError), privacy: .public) \
            setPosition=\(String(describing: positionError), privacy: .public) \
            actual=\(String(describing: actualFrame), privacy: .public)
            """)
        linkedResizeSelfInitiated[windowID] = (actualFrame, ProcessInfo.processInfo.systemUptime)
        return actualFrame
    }

    private func setFrame(_ frame: WindowLayoutFrame,
                          on window: AXUIElement,
                          windowKey: WindowLayoutWindowKey) -> Bool {
        setFrame(frame,
                 targetRect: appKitFrame(fromAX: frame),
                 screenVisibleFrame: appKitFrame(fromAX: frame),
                 action: .restore,
                 on: window,
                 windowKey: windowKey)
    }

    private func setFrame(_ frame: WindowLayoutFrame,
                          targetRect: NSRect,
                          screenVisibleFrame: NSRect,
                          action: WindowLayoutAction,
                          on window: AXUIElement,
                          windowKey: WindowLayoutWindowKey) -> Bool {
        let windowID = windowKey.windowID
        cancelSettle(for: windowID)
        assistiveModeSuspensions.removeValue(forKey: windowID)?.resume()
        assistiveModeSuspensions[windowID] = EnhancedUserInterfaceSuspension.suspend(forAppOf: window)

        let original = self.frame(of: window)
        if attempt(frame, targetRect: targetRect, action: action, on: window) {
            assistiveModeSuspensions.removeValue(forKey: windowID)?.resume()
            return true
        }

        // Some apps commit Accessibility size changes with a short delay, so
        // the reads above can still see the old frame. Judging failure now and
        // restoring the original is what used to leave windows moved but never
        // resized (issue #334): let the window settle before deciding.
        scheduleSettle(SettleContext(window: window,
                                     windowID: windowID,
                                     frame: frame,
                                     targetRect: targetRect,
                                     screenVisibleFrame: screenVisibleFrame,
                                     action: action,
                                     original: original,
                                     previousAction: lastActions[windowKey],
                                     windowKey: windowKey,
                                     resultGeneration: resultGeneration + 1),
                       attempt: 0)
        return true
    }

    private func scheduleSettle(_ context: SettleContext, attempt: Int) {
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.settleTimers[context.windowID] = nil
            self.continueSettle(context, attempt: attempt)
        }
        settleTimers[context.windowID] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func continueSettle(_ context: SettleContext, attempt: Int) {
        if verified(context) {
            concludeSettle(context, success: true)
            return
        }
        if self.attempt(context.frame,
                        targetRect: context.targetRect,
                        action: context.action,
                        on: context.window) {
            concludeSettle(context, success: true)
            return
        }
        if attempt == 0 {
            scheduleSettle(context, attempt: 1)
            return
        }
        if let original = context.original, shouldUseMaximizeFallback(for: context.action) {
            // An ungapped scratch frame that coaxes a stubborn window into
            // resizing; the gapped target is re-applied right after.
            let currentRect = appKitFrame(fromAX: original)
            let maxFrame = axFrame(fromAppKit: WindowLayoutGeometry.rect(for: .maximize,
                                                                         current: currentRect,
                                                                         visibleFrame: context.screenVisibleFrame))
            applyFrame(maxFrame, on: context.window)
            if self.attempt(context.frame,
                            targetRect: context.targetRect,
                            action: context.action,
                            on: context.window) {
                concludeSettle(context, success: true)
                return
            }
        }
        concludeSettle(context, success: false)
    }

    private func verified(_ context: SettleContext) -> Bool {
        guard let actual = frame(of: context.window) else { return false }
        return actual.isClose(to: context.frame, tolerance: frameTolerance)
            || accepted(actual: actual, targetRect: context.targetRect, action: context.action)
    }

    // The action already reported success while the window was settling, so a
    // refusal this late restores the window, undoes the bookkeeping and
    // republishes the result the panel feedback listens to.
    private func concludeSettle(_ context: SettleContext, success: Bool) {
        assistiveModeSuspensions.removeValue(forKey: context.windowID)?.resume()
        guard !success else { return }
        if let original = context.original {
            applyFrame(original, on: context.window)
        }
        if context.action == .restore {
            frameHistory.record(context.frame, for: context.windowKey)
        } else {
            frameHistory.discardLatest(for: context.windowKey)
        }
        if let previousAction = context.previousAction {
            lastActions[context.windowKey] = previousAction
        } else {
            lastActions.removeValue(forKey: context.windowKey)
        }
        // A second action already published a fresh result; this stale
        // failure must not overwrite the feedback the person is reading.
        if context.resultGeneration == resultGeneration {
            lastResult = .failure(.failed)
        }
    }

    private func cancelSettle(for windowID: CGWindowID) {
        settleTimers.removeValue(forKey: windowID)?.invalidate()
    }

    private func attempt(_ frame: WindowLayoutFrame,
                         targetRect: NSRect,
                         action: WindowLayoutAction,
                         on window: AXUIElement) -> Bool {
        let visibleFrame = bestScreen(for: frame)?.visibleFrame ?? targetRect
        for _ in 0..<3 {
            applyFrame(frame,
                       targetRect: targetRect,
                       visibleFrame: visibleFrame,
                       action: action,
                       on: window)
            guard let actual = self.frame(of: window) else { continue }
            if actual.isClose(to: frame, tolerance: frameTolerance)
                || accepted(actual: actual, targetRect: targetRect, action: action) {
                return true
            }
        }
        return false
    }

    private func shouldUseMaximizeFallback(for action: WindowLayoutAction) -> Bool {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
                .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                .topLeftSixth, .topCenterSixth, .topRightSixth,
                .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                .topLeft, .topRight, .bottomLeft, .bottomRight, .marginMaximize:
            return true
        default:
            return false
        }
    }

    private func applyFrame(_ frame: WindowLayoutFrame, on window: AXUIElement) {
        _ = setSize(frame.size, on: window)
        _ = setPosition(frame.origin, on: window)
        _ = setSize(frame.size, on: window)
        _ = setPosition(frame.origin, on: window)
    }

    private func applyFrame(_ frame: WindowLayoutFrame,
                            targetRect: NSRect,
                            visibleFrame: NSRect,
                            action: WindowLayoutAction,
                            on window: AXUIElement) {
        let requestedRect = WindowLayoutGeometry.anchoredRect(for: action,
                                                              targetRect: targetRect,
                                                              actualSize: frame.size,
                                                              visibleFrame: visibleFrame)
        let requestedFrame = axFrame(fromAppKit: requestedRect)
        _ = setPosition(requestedFrame.origin, on: window)
        _ = setSize(frame.size, on: window)
        let acceptedSize = self.frame(of: window)?.size ?? frame.size
        let anchoredRect = WindowLayoutGeometry.anchoredRect(for: action,
                                                            targetRect: targetRect,
                                                            actualSize: acceptedSize,
                                                            visibleFrame: visibleFrame)
        let anchoredFrame = axFrame(fromAppKit: anchoredRect)
        _ = setPosition(anchoredFrame.origin, on: window)
        _ = setSize(frame.size, on: window)
        let finalSize = self.frame(of: window)?.size ?? acceptedSize
        let finalRect = WindowLayoutGeometry.anchoredRect(for: action,
                                                         targetRect: targetRect,
                                                         actualSize: finalSize,
                                                         visibleFrame: visibleFrame)
        _ = setPosition(axFrame(fromAppKit: finalRect).origin, on: window)
    }

    private func accepted(actual: WindowLayoutFrame,
                          targetRect: NSRect,
                          action: WindowLayoutAction) -> Bool {
        let actualRect = appKitFrame(fromAX: actual)
        return WindowLayoutGeometry.accepts(actualRect: actualRect,
                                            targetRect: targetRect,
                                            action: action,
                                            anchorTolerance: anchorTolerance)
    }

    // MARK: - Shortcuts

    private func registerHotkeys() {
        // Cleared shortcuts are simply absent: their key combo stays free for
        // other apps, which is the whole point of clearing them (issue #169).
        let shortcuts = Dictionary(uniqueKeysWithValues: WindowLayoutAction.shortcutActions.compactMap { action in
            action.savedShortcut.map { (action, $0) }
        })
        if !hotKeyRefs.isEmpty, shortcuts == registeredShortcuts { return }
        unregisterHotkeys()

        ensureHotKeyEventHandler()

        var failures = Set<WindowLayoutAction>()
        for action in WindowLayoutAction.shortcutActions {
            guard let shortcut = shortcuts[action] else { continue }
            let id = EventHotKeyID(signature: 0x5655_574C, id: action.shortcutID) // 'VUWL'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                             shortcut.carbonModifiers,
                                             id,
                                             GetEventDispatcherTarget(),
                                             0,
                                             &ref)
            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else {
                failures.insert(action)
            }
        }
        registeredShortcuts = shortcuts
        failedShortcutActions = failures
    }

    private func ensureHotKeyEventHandler() {
        if eventHandler == nil {
            var specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                if let event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
                }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userData).takeUnretainedValue()
                let kind = event.map(GetEventKind) ?? 0
                if id.signature == 0x5655_5744 { // 'VUWD'
                    DispatchQueue.main.async {
                        kind == UInt32(kEventHotKeyPressed)
                            ? service.beginDirectionalGesture()
                            : service.finishDirectionalGesture()
                    }
                    return noErr
                }
                guard id.signature == 0x5655_574C,
                      kind == UInt32(kEventHotKeyPressed),
                      let action = WindowLayoutAction(shortcutID: id.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { service.apply(action) }
                return noErr
            }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
    }

    /// Lets go of the layout keys while a shortcut field is listening, so the
    /// user can record a combination the layout actions already use. The
    /// gesture tap is left alone: it watches the mouse, not the keyboard. The
    /// next `syncWithPreferences` takes the keys back.
    func suspendShortcuts() { unregisterHotkeys() }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        registeredShortcuts.removeAll()
        failedShortcutActions.removeAll()
    }

    private func registerDirectionalHotkey() {
        guard let shortcut = UserDefaults.standard.string(forKey: DefaultsKey.windowDirectionalShortcut)
            .flatMap(GlobalShortcut.init(storageValue:)) else {
            directionalShortcutRegistrationFailed = true
            return
        }
        if directionalHotKeyRef != nil, registeredDirectionalShortcut == shortcut { return }
        unregisterDirectionalHotkey()
        ensureHotKeyEventHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5655_5744, id: 56)
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers, id,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            directionalHotKeyRef = ref
            registeredDirectionalShortcut = shortcut
            directionalShortcutRegistrationFailed = false
        } else {
            directionalShortcutRegistrationFailed = true
        }
    }

    private func unregisterDirectionalHotkey() {
        if let directionalHotKeyRef { UnregisterEventHotKey(directionalHotKeyRef) }
        directionalHotKeyRef = nil
        registeredDirectionalShortcut = nil
        directionalShortcutRegistrationFailed = false
        cancelDirectionalGesture()
    }

    private func beginDirectionalGesture() {
        guard directionalSession == nil,
              let target = focusedTarget(for: .leftHalf),
              let screen = bestScreen(for: target.frame) else { return }
        directionalSession = WindowDirectionalSession(target: target,
                                                      visibleFrame: screen.visibleFrame,
                                                      pointerOrigin: NSEvent.mouseLocation,
                                                      action: nil,
                                                      manualOverride: nil)
        showDirectionalIndicator(at: NSEvent.mouseLocation, action: nil)
        directionalTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.updateDirectionalGesture()
        }
        startDirectionalTap()
    }

    private func startDirectionalTap() {
        guard directionalTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.observeDirectionalEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        directionalTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        directionalTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func observeDirectionalEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var session = directionalSession else { return Unmanaged.passUnretained(event) }

        if type == .scrollWheel {
            let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedDeltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let scrollY = deltaY != 0 ? deltaY : Double(fixedDeltaY)

            if scrollY > 0.5 {
                session.manualOverride = .maximize
                directionalSession = session
                updateDirectionalIndicator(action: .maximize)
                let preview = placement(for: .maximize, current: session.target.frame,
                                        visibleFrame: session.visibleFrame).rect
                showEdgeSnapPreview(frame: preview)
            } else if scrollY < -0.5 {
                session.manualOverride = .minimize
                directionalSession = session
                updateDirectionalIndicator(action: .minimize)
                hideEdgeSnapPreview(immediately: true)
            }
            return nil
        }

        if type == .leftMouseDown {
            session.manualOverride = .maximize
            directionalSession = session
            updateDirectionalIndicator(action: .maximize)
            let preview = placement(for: .maximize, current: session.target.frame,
                                    visibleFrame: session.visibleFrame).rect
            showEdgeSnapPreview(frame: preview)
            return nil
        }

        if type == .rightMouseDown {
            session.manualOverride = .minimize
            directionalSession = session
            updateDirectionalIndicator(action: .minimize)
            hideEdgeSnapPreview(immediately: true)
            return nil
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 || keyCode == 36 || keyCode == 126 { // Space, Return, Up
                session.manualOverride = .maximize
                directionalSession = session
                updateDirectionalIndicator(action: .maximize)
                let preview = placement(for: .maximize, current: session.target.frame,
                                        visibleFrame: session.visibleFrame).rect
                showEdgeSnapPreview(frame: preview)
                return nil
            } else if keyCode == 46 || keyCode == 125 { // M, Down
                session.manualOverride = .minimize
                directionalSession = session
                updateDirectionalIndicator(action: .minimize)
                hideEdgeSnapPreview(immediately: true)
                return nil
            } else if keyCode == 53 { // Escape
                cancelDirectionalGesture()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func updateDirectionalGesture() {
        guard var session = directionalSession else { return }
        let currentMouse = NSEvent.mouseLocation
        let distance = hypot(currentMouse.x - session.pointerOrigin.x,
                             currentMouse.y - session.pointerOrigin.y)

        let directionalAction = WindowDirectionalGestureSupport.action(
            from: session.pointerOrigin,
            to: currentMouse
        )

        if distance >= WindowDirectionalGestureSupport.activationDistance {
            session.manualOverride = nil
        }

        let action = session.manualOverride ?? directionalAction
        guard action != session.action else { return }

        session.action = action
        directionalSession = session
        updateDirectionalIndicator(action: action)

        guard let action else {
            hideEdgeSnapPreview(immediately: false)
            return
        }

        if let layoutAction = action.layoutAction {
            let preview = placement(for: layoutAction, current: session.target.frame,
                                    visibleFrame: session.visibleFrame,
                                    excluding: session.target.windowID).rect
            showEdgeSnapPreview(frame: preview)
        } else {
            hideEdgeSnapPreview(immediately: true)
        }
    }

    private func finishDirectionalGesture() {
        stopDirectionalTap()
        guard let session = directionalSession else { return }
        directionalTimer?.invalidate()
        directionalTimer = nil
        directionalSession = nil
        hideEdgeSnapPreview(immediately: true)
        hideDirectionalIndicator()

        guard let action = session.action else { return }
        if let layoutAction = action.layoutAction {
            _ = applyPlacement(layoutAction, to: session.target, visibleFrame: session.visibleFrame,
                               cyclesRepeatedAction: false)
        } else if action == .minimize {
            _ = minimize(target: session.target)
        }
    }

    private func cancelDirectionalGesture() {
        stopDirectionalTap()
        directionalTimer?.invalidate()
        directionalTimer = nil
        directionalSession = nil
        hideEdgeSnapPreview(immediately: true)
        hideDirectionalIndicator()
    }

    private func stopDirectionalTap() {
        if let directionalTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), directionalTapSource, .commonModes)
        }
        directionalTapSource = nil
        if let directionalTap {
            CGEvent.tapEnable(tap: directionalTap, enable: false)
            CFMachPortInvalidate(directionalTap)
        }
        directionalTap = nil
    }

    @discardableResult
    private func minimize(target: WindowLayoutTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let status = AXUIElementSetAttributeValue(target.window,
                                                  kAXMinimizedAttribute as CFString,
                                                  kCFBooleanTrue)
        return status == .success
    }

    private func showDirectionalIndicator(at pointer: CGPoint, action: WindowDirectionalAction?) {
        let size = CGSize(width: 180, height: 180)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)
        let panel: NSPanel
        if let directionalIndicatorPanel {
            panel = directionalIndicatorPanel
        } else {
            panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                        .transient, .ignoresCycle]
            panel.animationBehavior = .none
            panel.contentView = WindowDirectionalIndicatorView(frame: CGRect(origin: .zero, size: size))
            directionalIndicatorPanel = panel
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        updateDirectionalIndicator(action: action)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func updateDirectionalIndicator(action: WindowDirectionalAction?) {
        guard let view = directionalIndicatorPanel?.contentView as? WindowDirectionalIndicatorView else { return }
        view.action = action
    }

    private func hideDirectionalIndicator() {
        directionalIndicatorPanel?.orderOut(nil)
    }

    // MARK: - Drag to screen edge

    /// The callback copies scalar values and gets out of the input path before
    /// any Accessibility or UI work. It only adjusts the exact top coordinate
    /// after a window move has already been confirmed on the main queue.
    private func startEdgeSnapTap() {
        guard edgeSnapTap == nil else { return }
        // `.mouseMoved` is here only for spec §3/§12's hover-the-zoom-button
        // trigger (`handleZoomHoverMouseMoved`) — every other branch below
        // still only ever reacts to a mouse button, unchanged. Reusing this
        // already-running tap (rather than a second one) means the hover
        // feature exists only while edge snapping itself is on, which is
        // also where `snapLayoutsPanel` and everything it needs already
        // lives; `handleZoomHoverMouseMoved` throttles and cheaply bails
        // before touching Accessibility on almost every sample, so the
        // extra event type costs nothing while the pointer is not near a
        // window's own zoom button.
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.observeEdgeSnapEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        edgeSnapTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        edgeSnapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEdgeSnapTap() {
        edgeSnapSequenceGeneration += 1
        edgeSnapPressOrigin = nil
        edgeSnapPressCandidate = nil
        edgeSnapSequenceSuppressed = false
        edgeSnapResolveAttempts = 0
        edgeSnapDrag = nil
        hideEdgeSnapPreview(immediately: true)
        snapLayoutsPanel?.hide()
        snapLayoutsPanel = nil
        snapLayoutsActiveScreen = nil
        zoomHoverPanelActive = false
        zoomHoverStartedAt = nil
        zoomHoverSuppressedUntilLeave = false
        zoomHoverCache = nil
        dividerHintPanel?.orderOut(nil)
        dividerHintPanel = nil
        dividerHintActive = false
        dividerHintStartedAt = nil
        dividerHintCachedHint = nil
        if let edgeSnapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), edgeSnapRunLoopSource, .commonModes)
        }
        if let edgeSnapTap {
            CGEvent.tapEnable(tap: edgeSnapTap, enable: false)
            CFMachPortInvalidate(edgeSnapTap)
        }
        edgeSnapTap = nil
        edgeSnapRunLoopSource = nil
        edgeSnapPreviewPanel = nil
    }

    private func observeEdgeSnapEvent(type: CGEventType,
                                      event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if SessionActivity.shared.isActive, AXIsProcessTrusted(), let edgeSnapTap {
                CGEvent.tapEnable(tap: edgeSnapTap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.syncWithPreferences() }
            }
            DispatchQueue.main.async { [weak self] in self?.cancelEdgeSnapTracking() }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownProcessID
        else { return Unmanaged.passUnretained(event) }

        // Spec §3/§12: hovering the zoom button is entirely outside the
        // press/drag state machine below (no button is ever held for it),
        // so it is handled here and returns immediately — never reaching,
        // and never disturbed by, `edgeSnapSequenceSuppressed` or any of
        // the drag bookkeeping that follows.
        if type == .mouseMoved {
            let location = event.location
            DispatchQueue.main.async { [weak self] in
                self?.handleZoomHoverMouseMoved(atQuartzPoint: location)
                self?.handleDividerHintMouseMoved(atQuartzPoint: location)
            }
            return Unmanaged.passUnretained(event)
        }
        // A press or release is also always relevant to a hover-shown Snap
        // Layouts panel (a click on one of its cells, or anywhere else that
        // should dismiss it) regardless of what the drag state machine
        // below decides to do with the same event — dispatched as a second,
        // independent side effect so neither path can affect the other's
        // decisions. The panel `ignoresMouseEvents`, so nothing here ever
        // needs to consume the event.
        if type == .leftMouseDown || type == .leftMouseUp {
            let location = event.location
            let isDown = type == .leftMouseDown
            DispatchQueue.main.async { [weak self] in
                self?.handleZoomHoverClick(atQuartzPoint: location, isDown: isDown)
            }
        }

        if type == .leftMouseDown {
            edgeSnapSequenceSuppressed = WindowEdgeSnapSupport.isSystemTilingEnabled
        } else if edgeSnapSequenceSuppressed {
            if type == .leftMouseUp { edgeSnapSequenceSuppressed = false }
            return Unmanaged.passUnretained(event)
        }
        guard !edgeSnapSequenceSuppressed else { return Unmanaged.passUnretained(event) }

        let input: WindowEdgeSnapPointerInput
        switch type {
        case .leftMouseDown:
            input = .down(location: event.location, flags: event.flags)
        case .leftMouseDragged:
            let originalLocation = event.location
            input = .dragged(location: originalLocation)
            if let drag = edgeSnapDrag,
               drag.isMoving,
               drag.protectsSystemTopEdge {
                event.location = WindowEdgeSnapSupport.locationAvoidingSystemTopDrag(
                    originalLocation,
                    screenFrames: drag.quartzScreenFrames
                )
            }
        case .leftMouseUp:
            input = .up(location: event.location)
        default:
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { [weak self] in self?.handleEdgeSnapInput(input) }
        return Unmanaged.passUnretained(event)
    }

    private func handleEdgeSnapInput(_ input: WindowEdgeSnapPointerInput) {
        switch input {
        case .down(let location, let flags):
            cancelEdgeSnapTracking()
            edgeSnapSequenceSuppressed = false
            guard AppFeature.windowLayout.isAvailable,
                  UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled),
                  !WindowEdgeSnapSupport.isSystemTilingEnabled,
                  AXIsProcessTrusted(),
                  !edgeSnapConflictsWithWindowGesture(flags: flags)
            else {
                edgeSnapSequenceSuppressed = true
                return
            }
            guard let candidate = WindowServerWindowHitTest.candidate(at: location, pidIsEligible: {
                guard let app = NSRunningApplication(processIdentifier: $0) else { return false }
                return !app.isTerminated && app.activationPolicy == .regular
            }),
            !WindowEdgeSnapSupport.startsAtResizeHandle(location, frame: candidate.frame)
            else {
                edgeSnapSequenceSuppressed = true
                return
            }
            edgeSnapPressOrigin = location
            edgeSnapPressCandidate = candidate
            edgeSnapResolveAttempts = 0
            edgeSnapLastResolveAt = 0

        case .dragged(let location):
            guard let pressOrigin = edgeSnapPressOrigin,
                  let pressCandidate = edgeSnapPressCandidate,
                  activeGesture == nil, pendingGesture == nil
            else {
                cancelEdgeSnapTracking()
                return
            }
            if edgeSnapDrag == nil,
               WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location) {
                let now = ProcessInfo.processInfo.systemUptime
                if edgeSnapResolveAttempts < 4, now - edgeSnapLastResolveAt >= 0.08 {
                    edgeSnapResolveAttempts += 1
                    edgeSnapLastResolveAt = now
                    edgeSnapDrag = makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                    pressCandidate: pressCandidate)
                }
            }
            updateEdgeSnapDrag(at: location, forceSample: false)

        case .up(let location):
            let pressOrigin = edgeSnapPressOrigin
            let pressCandidate = edgeSnapPressCandidate
            if edgeSnapDrag == nil,
               let pressOrigin, let pressCandidate,
               WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location) {
                edgeSnapDrag = makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                pressCandidate: pressCandidate)
            }
            updateEdgeSnapDrag(at: location, forceSample: true)
            let completed = edgeSnapDrag
            edgeSnapPressOrigin = nil
            edgeSnapPressCandidate = nil
            edgeSnapResolveAttempts = 0
            edgeSnapDrag = nil
            hideEdgeSnapPreview(immediately: false)
            hideSnapLayoutsPanel()
            let generation = edgeSnapSequenceGeneration
            guard let completed else {
                guard let pressOrigin, let pressCandidate,
                      WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, generation == self.edgeSnapSequenceGeneration,
                          let delayed = self.makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                              pressCandidate: pressCandidate)
                    else { return }
                    self.applyDelayedEdgeSnapIfMoved(delayed, releaseLocation: location)
                }
                return
            }
            if !completed.isMoving {
                guard let pressOrigin,
                      WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, generation == self.edgeSnapSequenceGeneration else { return }
                    self.applyDelayedEdgeSnapIfMoved(completed, releaseLocation: location)
                }
                return
            }
            guard let target = completed.target else { return }
            // The callback has already forwarded this mouse-up. One
            // more main-loop turn lets the target app finish its own drag
            // before the placement writes the final frame.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.edgeSnapSequenceGeneration else { return }
                self.applyEdgeSnap(completed, target: target)
            }
        }
    }

    private func applyDelayedEdgeSnapIfMoved(_ drag: WindowEdgeSnapDrag,
                                             releaseLocation: CGPoint) {
        guard let current = frame(of: drag.window),
              WindowEdgeSnapSupport.classify(
                initialFrame: drag.initialFrame,
                currentFrame: CGRect(origin: current.origin, size: current.size),
                pointerStart: drag.pointerStart,
                pointerNow: releaseLocation
              ) == .moving,
              let target = edgeSnapTarget(atQuartzPoint: releaseLocation)
        else { return }
        applyEdgeSnap(drag, target: target)
    }

    private func edgeSnapConflictsWithWindowGesture(flags: CGEventFlags) -> Bool {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureEnabled) else { return false }
        let move = WindowGestureSupport.modifiers(
            from: UserDefaults.standard.string(forKey: DefaultsKey.windowGestureModifiers)
        )
        return WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: move)
            || WindowGestureSupport.modifiersMatch(
                eventFlags: flags,
                expected: WindowGestureSupport.resizeModifiers(from: move)
            )
    }

    private func makeEdgeSnapDrag(pointerStart: CGPoint,
                                  pressCandidate: WindowServerWindowCandidate) -> WindowEdgeSnapDrag? {
        guard let app = NSRunningApplication(processIdentifier: pressCandidate.pid),
              !app.isTerminated, app.activationPolicy == .regular else { return nil }
        let axApp = AXUIElementCreateApplication(pressCandidate.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let window = windowsAttribute(axApp)?.first(where: {
                  AXWindowResolver.windowID(for: $0) == pressCandidate.windowID
              }) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard let onScreenWindowIDs = onScreenWindowIDs(),
              let target = target(from: window,
                                  app: app,
                                  onScreenWindowIDs: onScreenWindowIDs,
                                  capability: .frame) else { return nil }
        return WindowEdgeSnapDrag(window: target.window,
                                  key: target.key,
                                  initialFrame: pressCandidate.frame,
                                  pointerStart: pointerStart,
                                  protectsSystemTopEdge: WindowEdgeSnapSupport.isSystemTopWindowOverviewDragEnabled,
                                  quartzScreenFrames: edgeSnapQuartzScreenFrames(),
                                  lastSampleAt: 0,
                                  mismatchCount: 0,
                                  isMoving: false,
                                  target: nil)
    }

    private func updateEdgeSnapDrag(at location: CGPoint, forceSample: Bool) {
        guard var drag = edgeSnapDrag else { return }
        if !drag.isMoving {
            let now = ProcessInfo.processInfo.systemUptime
            guard forceSample || now - drag.lastSampleAt >= edgeSnapSampleInterval else { return }
            drag.lastSampleAt = now
            guard let current = frame(of: drag.window) else {
                cancelEdgeSnapTracking()
                return
            }
            let currentFrame = CGRect(origin: current.origin, size: current.size)
            switch WindowEdgeSnapSupport.classify(initialFrame: drag.initialFrame,
                                                  currentFrame: currentFrame,
                                                  pointerStart: drag.pointerStart,
                                                  pointerNow: location) {
            case .waiting:
                edgeSnapDrag = drag
                return
            case .moving:
                drag.isMoving = true
                drag.mismatchCount = 0
            case .resizing:
                cancelEdgeSnapTracking()
                return
            case .unrelated:
                drag.mismatchCount += 1
                if drag.mismatchCount >= 3 {
                    cancelEdgeSnapTracking()
                } else {
                    edgeSnapDrag = drag
                }
                return
            }
        }

        let target = resolvedEdgeSnapTarget(atQuartzPoint: location)
        if target != drag.target {
            drag.target = target
            // Bumped on every target change, including to nil — a fresh
            // dwell always has to start over. Without this, A→B→A within
            // the delay window would let the *first* scheduled A show fire
            // late and display instantly, since by the time it ran the live
            // target (now A again, having passed through B) matched its
            // captured value even though the pointer had only been back on
            // A for a moment — target equality alone cannot tell a
            // continuous dwell apart from a coincidental revisit.
            edgeSnapPreviewScheduleGeneration += 1
            if let target {
                // Spec §1: the preview appears only after ~150ms of dwell
                // at the edge, not instantly on the very sample that first
                // resolves a target — but still disappears immediately
                // (the `else` branch, unchanged) the moment the pointer
                // leaves the zone, matching "sparisce subito uscendo dalla
                // zona." `scheduleEdgeSnapPreview` re-checks the live target
                // and generation when its delay elapses, so a pointer that
                // keeps moving through several zones inside 150ms never
                // flashes any of the ones it only passed through.
                scheduleEdgeSnapPreview(target)
            } else {
                hideEdgeSnapPreview(immediately: false)
            }
        }
        edgeSnapDrag = drag
    }

    /// How long the pointer must hold still over one target before the live
    /// preview appears (spec §1's "appare dopo ~150 ms di permanenza al
    /// bordo").
    private static let edgeSnapPreviewDelay: TimeInterval = 0.15

    /// Invalidates a pending `scheduleEdgeSnapPreview` closure whenever the
    /// target changes again before it fires — see the comment where it is
    /// bumped, in `updateEdgeSnapDrag`.
    private var edgeSnapPreviewScheduleGeneration: UInt64 = 0

    private func scheduleEdgeSnapPreview(_ target: WindowEdgeSnapTarget) {
        let generation = edgeSnapPreviewScheduleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.edgeSnapPreviewDelay) { [weak self] in
            // The generation check alone would be enough (it already
            // invalidates on every target change, nil included), but the
            // target equality is kept too as a second, independent guard —
            // cheap, and it costs nothing to never rely on a single check
            // for whether real user-visible geometry gets drawn.
            guard let self,
                  generation == self.edgeSnapPreviewScheduleGeneration,
                  self.edgeSnapDrag?.target == target
            else { return }
            self.showEdgeSnapPreview(frame: target.frame)
        }
    }

    private func edgeSnapTarget(atQuartzPoint point: CGPoint) -> WindowEdgeSnapTarget? {
        let hoverPoint = appKitPoint(fromQuartz: point)
        let screens = NSScreen.screens.map {
            WindowEdgeSnapScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        // Spec §12: halves/corners activate up to `earlyEdgeActivationDistance`
        // from the edge when `windowSnapEarlyEdge` is on; the top strip that
        // opens Snap Layouts keeps the classic `activationDistance` either way.
        return WindowEdgeSnapSupport.target(at: hoverPoint,
                                            screens: screens,
                                            distance: WindowEdgeSnapSupport.edgeActivationDistance(
                                                earlyEdgeEnabled: earlyEdgeEnabled),
                                            topDistance: WindowEdgeSnapSupport.activationDistance)
    }

    /// Whether spec §12's "let me snap it without dragging all the way to
    /// the screen edge" is on — the widened activation band `edgeSnapTarget`
    /// passes through for halves and corners.
    private var earlyEdgeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapEarlyEdge)
    }

    private func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: menuBarScreenTopY - point.y)
    }

    /// Whether the Snap Layouts panel is wanted right now: the feature is
    /// available, both the panel toggle and classic edge snapping are on
    /// (the panel hooks into the same drag the edge-snap tap already
    /// tracks — there is no separate tap for it), and every existing
    /// edge-snap guard still applies.
    private var snapLayoutsEnabled: Bool {
        AppFeature.windowLayout.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLayoutsEnabled)
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled)
            && !WindowEdgeSnapSupport.isSystemTilingEnabled
            && AXIsProcessTrusted()
    }

    /// The classic edge-snap target, or whatever the open Snap Layouts panel
    /// currently resolves to.
    ///
    /// Opening the panel and keeping it open ask different questions
    /// (`SnapLayoutPresets.shouldShowPanel`'s doc comment has the reasoning):
    /// while it is already visible, this keeps asking that question against
    /// the screen it opened on rather than re-deriving a trigger screen from
    /// the narrow top strip alone, since by the time the pointer is over the
    /// panel's own cards it may no longer be in that strip at all. Only once
    /// the panel is neither open-and-reachable nor freshly triggered does
    /// this fall back to the classic corner/half behavior unchanged, so
    /// `WindowEdgeSnapDrag.target` keeps flowing into the same
    /// `applyEdgeSnap` regardless of which path produced it.
    private func resolvedEdgeSnapTarget(atQuartzPoint point: CGPoint) -> WindowEdgeSnapTarget? {
        // The live preview has to show exactly the rectangle a release would
        // write (spec §5's "what you see is what you get"), so every branch
        // below funnels through the same free-space adjustment before
        // returning, regardless of which one produced the raw target —
        // the classic corner/half fallback, an open panel's hovered cell, or
        // its own maximize/corner fallback.
        rawResolvedEdgeSnapTarget(atQuartzPoint: point).map(snapGroupAdjusted)
    }

    private func rawResolvedEdgeSnapTarget(atQuartzPoint point: CGPoint) -> WindowEdgeSnapTarget? {
        guard snapLayoutsEnabled else {
            hideSnapLayoutsPanel()
            return edgeSnapTarget(atQuartzPoint: point)
        }
        let hoverPoint = appKitPoint(fromQuartz: point)

        if let activeScreen = snapLayoutsActiveScreen,
           SnapLayoutPresets.shouldShowPanel(at: hoverPoint,
                                             panelFrame: snapLayoutsPanel?.frame,
                                             visibleFrame: activeScreen.visibleFrame,
                                             isCurrentlyShown: true) {
            return openPanelTarget(at: hoverPoint, on: activeScreen)
        }

        guard let triggerScreen = snapLayoutsTriggerScreen(atQuartzPoint: point) else {
            hideSnapLayoutsPanel()
            return edgeSnapTarget(atQuartzPoint: point)
        }
        snapLayoutsActiveScreen = triggerScreen
        showSnapLayoutsPanel(on: triggerScreen)
        return openPanelTarget(at: hoverPoint, on: triggerScreen)
    }

    /// Replaces a preview target's theoretical frame with the real free
    /// space its Snap Group neighbours leave, using the same adjustment
    /// `placement(for:current:visibleFrame:excluding:)` applies to the frame
    /// that eventually gets written — this is the preview half of that
    /// parity, with the dragged window itself (if it was already a group
    /// member) excluded so its own old zone never shrinks its own preview.
    private func snapGroupAdjusted(_ target: WindowEdgeSnapTarget) -> WindowEdgeSnapTarget {
        let adjusted = freeSpaceAdjusted(for: target.action,
                                         theoreticalZone: target.frame,
                                         visibleFrame: target.visibleFrame,
                                         fallbackFrame: axFrame(fromAppKit: target.frame),
                                         excluding: edgeSnapDrag?.key.windowID)
        guard adjusted != target.frame else { return target }
        return WindowEdgeSnapTarget(action: target.action, frame: adjusted.integral, visibleFrame: target.visibleFrame)
    }

    /// The target while the panel is open (or just opened this sample):
    /// whichever cell the pointer hovers, or — Windows' own drag-to-top
    /// behavior once a panel is offering every halved/thirded choice as an
    /// explicit cell (upstream issue #894) — maximize, unless the pointer
    /// is still over a corner sub-zone, which keeps its classic corner
    /// target so `target(at:)` and this never disagree at the corners.
    private func openPanelTarget(at hoverPoint: CGPoint, on screen: WindowEdgeSnapScreen) -> WindowEdgeSnapTarget? {
        if let hovered = snapLayoutsPanel?.updateHover(at: hoverPoint, visibleFrame: screen.visibleFrame) {
            return hovered
        }
        let action = WindowEdgeSnapSupport.openPanelFallbackAction(at: hoverPoint, screen: screen)
        let rect = WindowLayoutGeometry.rect(for: action,
                                             current: screen.visibleFrame,
                                             visibleFrame: screen.visibleFrame,
                                             windowGap: WindowLayoutGaps.windowGap,
                                             screenGap: WindowLayoutGaps.screenGap)
        return WindowEdgeSnapTarget(action: action, frame: rect.integral, visibleFrame: screen.visibleFrame)
    }

    private func snapLayoutsTriggerScreen(atQuartzPoint point: CGPoint) -> WindowEdgeSnapScreen? {
        let hoverPoint = appKitPoint(fromQuartz: point)
        let screens = NSScreen.screens.map {
            WindowEdgeSnapScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        return WindowEdgeSnapSupport.snapLayoutsTriggerScreen(at: hoverPoint, screens: screens)
    }

    private func showSnapLayoutsPanel(on screen: WindowEdgeSnapScreen) {
        // `availablePresets` always includes at least `.halves`, so this
        // list is never empty — no guard needed before showing it.
        let presets = SnapLayoutPresets.availablePresets(for: screen.visibleFrame)
        let panel = snapLayoutsPanel ?? {
            let created = SnapLayoutsPanel()
            snapLayoutsPanel = created
            return created
        }()
        panel.show(visibleFrame: screen.visibleFrame, presets: presets)
    }

    private func hideSnapLayoutsPanel() {
        snapLayoutsPanel?.hide()
        snapLayoutsActiveScreen = nil
        // The two triggers share one `snapLayoutsPanel` instance, so hiding
        // it here (the top-edge-drag path's own cleanup) must also clear
        // the hover trigger's idea of whether its panel is still showing —
        // otherwise a hover already open when a drag starts elsewhere would
        // leave `zoomHoverPanelActive` stuck true after this hides it out
        // from under it, and the hover trigger would never re-show until
        // the pointer left and returned to the button.
        zoomHoverPanelActive = false
    }

    // MARK: - Snap Layouts on zoom-button hover (spec §3/§12)

    /// Whether spec §3's hover trigger should react at all: the feature
    /// available, its own toggle, the parent Snap Layouts toggle (this
    /// panel is the same panel, just a different way to open it), and
    /// Accessibility trusted.
    private var zoomHoverEnabled: Bool {
        // `object(forKey:)`, never `.bool(forKey:)`: the toggle has no
        // registered default (see `Defaults.swift`), so this is the only
        // way to tell "never written" apart from "written false" — exactly
        // what `zoomHoverDefaultEnabled` needs to know whether to fall
        // back to the native-menu-aware default at all.
        let stored = UserDefaults.standard.object(forKey: DefaultsKey.windowSnapLayoutsOnZoomButton) as? Bool
        let wanted = SnapLayoutPresets.zoomHoverDefaultEnabled(
            storedValue: stored,
            nativeMenuAvailable: WindowEdgeSnapSupport.isSystemZoomButtonHoverMenuAvailable)
        return AppFeature.windowLayout.isAvailable
            && wanted
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapLayoutsEnabled)
            && AXIsProcessTrusted()
    }

    /// How long a cached "is this hover trigger even on" answer stays
    /// usable — shared by the zoom-button and divider-hint triggers, whose
    /// underlying reads (`UserDefaults`, `AXIsProcessTrusted()`) are cheap
    /// individually but not free at the sample rate a real trackpad or
    /// mouse can deliver `mouseMoved` events, and are asked on nearly every
    /// one of them by both triggers.
    private static let hoverEnabledCacheTTL: TimeInterval = 1.0
    private var zoomHoverEnabledCache = false
    private var zoomHoverEnabledCacheRefreshedAt: TimeInterval = 0

    /// `zoomHoverEnabled`, refreshed at most once per `hoverEnabledCacheTTL`
    /// — the only thing `handleZoomHoverMouseMoved` still does after its own
    /// sample throttle passes besides a couple of scalar comparisons.
    private func zoomHoverEnabledCached(now: TimeInterval) -> Bool {
        if now - zoomHoverEnabledCacheRefreshedAt >= Self.hoverEnabledCacheTTL {
            zoomHoverEnabledCache = zoomHoverEnabled
            zoomHoverEnabledCacheRefreshedAt = now
        }
        return zoomHoverEnabledCache
    }

    /// The frontmost regular app's focused window's zoom button, refreshed
    /// at most every `zoomHoverCacheTTL` — cheap enough to pay on a timer
    /// but not on every one of the many `mouseMoved` samples a real trackpad
    /// or mouse can deliver, which `handleZoomHoverMouseMoved` tests the
    /// pointer against first.
    private struct ZoomHoverButton {
        let windowID: CGWindowID
        /// AppKit space, matching `NSEvent`/`NSScreen` coordinates.
        let frame: CGRect
    }
    private var zoomHoverCache: ZoomHoverButton?
    private var zoomHoverCacheRefreshedAt: TimeInterval = 0
    private static let zoomHoverCacheTTL: TimeInterval = 0.5
    private var zoomHoverLastSampleAt: TimeInterval = 0
    private static let zoomHoverSampleInterval: TimeInterval = 1.0 / 20.0
    private var zoomHoverStartedAt: TimeInterval?
    // Spec's on-device finding: our panel has to appear *before* macOS's
    // own zoom-button hover menu (which showed up after ~1s on macOS 26),
    // so this is short — 0.5s, the figure spec §3 itself quotes, would
    // often lose that race.
    private static let zoomHoverDwellInterval: TimeInterval = 0.3
    /// A little under where the native menu appeared on-device: once a
    /// continuous hover reaches this, our panel is force-hidden (never
    /// left showing alongside the native menu) and no longer re-arms on
    /// its own — see `zoomHoverSuppressedUntilLeave` — until the pointer
    /// actually leaves the button and comes back for a fresh hover.
    private static let zoomHoverAutoHideInterval: TimeInterval = 0.9
    private var zoomHoverPanelActive = false
    /// Set once a continuous hover passes `zoomHoverAutoHideInterval`, so a
    /// person who keeps the pointer resting on the button (where the
    /// native menu is now showing) never sees Vorssaint's own panel pop
    /// back up moments later when the next dwell interval would otherwise
    /// have elapsed again. Cleared by `cancelZoomHover()`, which runs
    /// whenever the pointer actually leaves the button (among other
    /// resets) — exactly the "leave" this waits for.
    private var zoomHoverSuppressedUntilLeave = false
    /// The exact preset list the currently-open hover panel was shown with
    /// — `handleZoomHoverClick` hit-tests against this, never a freshly
    /// recomputed list, so a hit can never disagree with what is actually
    /// on screen even if the pointer crossed onto a different display
    /// between the panel opening and the release.
    private var zoomHoverPresets: [SnapLayoutPreset] = []

    /// Every `mouseMoved` sample the edge-snap tap forwards while the
    /// feature is on: cheaply bails whenever there is nothing to do (an
    /// active drag already owns the panel, the sample arrived before the
    /// throttle interval, or the pointer is nowhere near the cached button)
    /// before ever touching Accessibility.
    private func handleZoomHoverMouseMoved(atQuartzPoint point: CGPoint) {
        // The throttle runs before anything else touches UserDefaults or
        // Accessibility — a `mouseMoved` event tap can fire far faster than
        // `zoomHoverSampleInterval`, and every sample this drops costs
        // nothing but a timestamp compare.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - zoomHoverLastSampleAt >= Self.zoomHoverSampleInterval else { return }
        zoomHoverLastSampleAt = now

        guard zoomHoverEnabledCached(now: now), edgeSnapDrag == nil, edgeSnapPressOrigin == nil,
              snapLayoutsActiveScreen == nil
        else {
            cancelZoomHover()
            return
        }

        if zoomHoverCache == nil || now - zoomHoverCacheRefreshedAt >= Self.zoomHoverCacheTTL {
            zoomHoverCache = resolveFocusedZoomButton()
            zoomHoverCacheRefreshedAt = now
        }
        guard let button = zoomHoverCache else {
            cancelZoomHover()
            return
        }
        let hoverPoint = appKitPoint(fromQuartz: point)
        guard button.frame.insetBy(dx: -4, dy: -4).contains(hoverPoint) else {
            cancelZoomHover()
            return
        }
        // Still on the same button after the auto-hide cutoff already
        // fired once this hover: wait for an actual leave (which clears
        // this via `cancelZoomHover()`) rather than re-arming on the very
        // next sample, which would just show our panel again right on top
        // of the still-open native menu.
        guard !zoomHoverSuppressedUntilLeave else { return }

        if zoomHoverStartedAt == nil {
            zoomHoverStartedAt = now
        }
        guard let startedAt = zoomHoverStartedAt else { return }
        guard now - startedAt < Self.zoomHoverAutoHideInterval else {
            // Spec: never leave both visible. Hide unconditionally (a
            // no-op if nothing was showing yet) and suppress until the
            // pointer leaves, since the native menu is likely open by now
            // regardless of whether our own dwell ever got to show anything.
            cancelZoomHover()
            zoomHoverSuppressedUntilLeave = true
            return
        }
        guard SnapLayoutPresets.hoverDwellElapsed(startedAt: startedAt, now: now, dwell: Self.zoomHoverDwellInterval)
        else { return }
        guard !zoomHoverPanelActive else { return }
        presentZoomHoverPanel(button: button)
    }

    /// The frontmost regular app's focused (or main, for an app whose focus
    /// AX does not track precisely) window's zoom button, in AppKit space —
    /// `nil` for a full-screen window (no partial-zone snap applies to it)
    /// or one with no zoom button at all (some dialogs and utility panels).
    private func resolveFocusedZoomButton() -> ZoomHoverButton? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let window = windowAttribute(axApp, kAXFocusedWindowAttribute as String)
                ?? windowAttribute(axApp, kAXMainWindowAttribute as String),
              !boolAttribute(window, "AXFullScreen"),
              let windowID = AXWindowResolver.windowID(for: window),
              // `windowAttribute` is a generic AXUIElement-typed attribute
              // getter despite its name (see its own definition) — reused
              // here for the zoom button rather than adding a second,
              // near-identical helper.
              let button = windowAttribute(window, kAXZoomButtonAttribute as String),
              let buttonFrame = frame(of: button)
        else { return nil }
        return ZoomHoverButton(windowID: windowID, frame: appKitFrame(fromAX: buttonFrame))
    }

    private func presentZoomHoverPanel(button: ZoomHoverButton) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(button.frame.origin) })
                ?? bestScreen(for: WindowLayoutFrame(origin: button.frame.origin, size: button.frame.size))
        else { return }
        let presets = SnapLayoutPresets.availablePresets(for: screen.visibleFrame)
        let panel = snapLayoutsPanel ?? {
            let created = SnapLayoutsPanel()
            snapLayoutsPanel = created
            return created
        }()
        panel.showBelowButton(buttonFrame: button.frame, visibleFrame: screen.visibleFrame, presets: presets)
        zoomHoverPanelActive = true
        zoomHoverPresets = presets
    }

    /// Resets every piece of hover-tracking state and hides the panel if
    /// this trigger is the one that opened it — safe to call whenever
    /// anything (a drag starting, the pointer leaving the button, the
    /// feature turning off mid-hover) means the hover trigger no longer
    /// applies, including when it was never showing anything to begin with.
    private func cancelZoomHover() {
        zoomHoverStartedAt = nil
        zoomHoverSuppressedUntilLeave = false
        guard zoomHoverPanelActive else { return }
        zoomHoverPanelActive = false
        snapLayoutsPanel?.hide()
    }

    /// The click side-channel `observeEdgeSnapEvent` dispatches for every
    /// press and release while this trigger's panel might be showing —
    /// independent of the drag state machine, since no button is ever held
    /// down to reach this panel in the first place. A release lands either
    /// on a cell (apply it to the focused window, the same one the button
    /// belonged to) or elsewhere (dismiss without acting, matching the
    /// classic panel's own click-outside behavior) — either way the panel
    /// closes. A press is otherwise ignored: `updateHover`-less panel has
    /// no state to react to until the matching release.
    private func handleZoomHoverClick(atQuartzPoint point: CGPoint, isDown: Bool) {
        guard !isDown, zoomHoverPanelActive, let panel = snapLayoutsPanel, let panelFrame = panel.frame
        else { return }
        let hoverPoint = appKitPoint(fromQuartz: point)
        defer { cancelZoomHover() }
        guard let hit = SnapLayoutPresets.hit(at: hoverPoint, presets: zoomHoverPresets, panelFrame: panelFrame),
              let target = focusedTarget(for: hit.action),
              let screen = bestScreen(for: target.frame)
        else { return }
        pruneWindowState(keeping: target.key)
        _ = applyPlacement(hit.action, to: target, visibleFrame: screen.visibleFrame)
    }

    // MARK: - Snap Group divider hint (spec §6/§12)

    private var dividerHintPanel: NSPanel?
    private var dividerHintActive = false
    private var dividerHintStartedAt: TimeInterval?
    private var dividerHintCachedHint: SnapDividerHintSupport.DividerHint?
    private var dividerHintLastSampleAt: TimeInterval = 0
    private static let dividerHintSampleInterval: TimeInterval = 1.0 / 20.0
    /// Spec §1's own "~150 ms of dwell" figure, reused here for the same
    /// kind of hover-confirmation pause rather than inventing a second
    /// number with no stated reason to differ.
    private static let dividerHintDwellInterval: TimeInterval = 0.15
    private static let dividerHintTolerance: CGFloat = 6

    private var dividerHintEnabled: Bool {
        AppFeature.windowLayout.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapDividerHint)
            && AXIsProcessTrusted()
    }

    /// `dividerHintEnabled`, cached the same way and for the same reason
    /// `zoomHoverEnabledCached` is — see that one's own doc comment.
    private var dividerHintEnabledCache = false
    private var dividerHintEnabledCacheRefreshedAt: TimeInterval = 0

    private func dividerHintEnabledCached(now: TimeInterval) -> Bool {
        if now - dividerHintEnabledCacheRefreshedAt >= Self.hoverEnabledCacheTTL {
            dividerHintEnabledCache = dividerHintEnabled
            dividerHintEnabledCacheRefreshedAt = now
        }
        return dividerHintEnabledCache
    }

    /// The other half of the mouseMoved sample `handleZoomHoverMouseMoved`
    /// already receives: independent of it (a person can be near a zoom
    /// button or a group seam, never usefully both at once, but neither
    /// path assumes the other ran), and gated the same way — cancels
    /// itself the moment a real drag starts, since dragging a boundary is
    /// exactly what Phase 5's linked resize already reacts to, and a hint
    /// bar drawn on top of that would only be visual noise.
    private func handleDividerHintMouseMoved(atQuartzPoint point: CGPoint) {
        // Throttle first, before any UserDefaults/Accessibility read — see
        // `handleZoomHoverMouseMoved`'s own comment on why this has to be
        // the very first thing that runs.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - dividerHintLastSampleAt >= Self.dividerHintSampleInterval else { return }
        dividerHintLastSampleAt = now

        guard dividerHintEnabledCached(now: now), edgeSnapDrag == nil, edgeSnapPressOrigin == nil else {
            cancelDividerHint()
            return
        }

        let hoverPoint = appKitPoint(fromQuartz: point)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(hoverPoint) }),
              let group = snapGroups[screen.displayID],
              group.members.count >= 2
        else {
            cancelDividerHint()
            return
        }
        // The same cached, throttled live-frame read `freeSpaceAdjusted`
        // already pays for during a drag — reused here rather than a
        // second Accessibility sweep, since the seam a person actually
        // sees has to be between real, possibly-resized frames, never the
        // fixed zone a member joined the group with.
        let liveFrames = currentFrames(for: group, on: screen).frames
        let members = group.members.compactMap { member -> (windowID: CGWindowID, frame: CGRect)? in
            guard let frame = liveFrames[member.windowID] else { return nil }
            return (member.windowID, frame)
        }
        guard let hint = SnapDividerHintSupport.dividerHint(at: hoverPoint, members: members,
                                                             tolerance: Self.dividerHintTolerance)
        else {
            cancelDividerHint()
            return
        }
        if dividerHintCachedHint != hint {
            dividerHintStartedAt = now
            dividerHintCachedHint = hint
        }
        guard let startedAt = dividerHintStartedAt,
              SnapLayoutPresets.hoverDwellElapsed(startedAt: startedAt, now: now, dwell: Self.dividerHintDwellInterval)
        else { return }
        presentDividerHint(hint)
    }

    private func presentDividerHint(_ hint: SnapDividerHintSupport.DividerHint) {
        let panel = dividerHintPanel ?? {
            let created = makeDividerHintPanel()
            dividerHintPanel = created
            return created
        }()
        if panel.frame != hint.frame {
            panel.setFrame(hint.frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        dividerHintActive = true
    }

    /// Hides the bar (spec §12: "the bar hides on mouse down") and resets
    /// every piece of dwell-tracking state — safe to call whenever anything
    /// means the hint no longer applies, including when nothing was
    /// showing to begin with.
    private func cancelDividerHint() {
        dividerHintStartedAt = nil
        dividerHintCachedHint = nil
        guard dividerHintActive else { return }
        dividerHintActive = false
        dividerHintPanel?.orderOut(nil)
    }

    private func makeDividerHintPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.55)
        panel.isOpaque = false
        panel.hasShadow = false
        // Never intercepts the click that starts a real resize drag — the
        // app's own resize cursor and Phase 5's linked resize both keep
        // working exactly as if this bar did not exist.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .transient, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    private func edgeSnapQuartzScreenFrames() -> [CGRect] {
        let top = menuBarScreenTopY
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX,
                   y: top - $0.frame.maxY,
                   width: $0.frame.width,
                   height: $0.frame.height)
        }
    }

    private func applyEdgeSnap(_ drag: WindowEdgeSnapDrag,
                               target: WindowEdgeSnapTarget) {
        guard AppFeature.windowLayout.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled),
              !WindowEdgeSnapSupport.isSystemTilingEnabled,
              AXIsProcessTrusted(),
              canSetFrame(on: drag.window),
              AXWindowResolver.windowID(for: drag.window) == drag.key.windowID,
              let currentFrame = frame(of: drag.window)
        else { return }
        var processID = pid_t(0)
        guard AXUIElementGetPid(drag.window, &processID) == .success,
              processID == drag.key.processID else { return }

        let layoutTarget = WindowLayoutTarget(window: drag.window,
                                              key: drag.key,
                                              frame: currentFrame)
        pruneWindowState(keeping: drag.key)
        let history = WindowLayoutFrame(origin: drag.initialFrame.origin,
                                        size: drag.initialFrame.size)
        _ = applyPlacement(target.action,
                           to: layoutTarget,
                           visibleFrame: target.visibleFrame,
                           historyFrame: history,
                           cyclesRepeatedAction: false)
    }

    private func cancelEdgeSnapTracking() {
        edgeSnapSequenceGeneration += 1
        edgeSnapPressOrigin = nil
        edgeSnapPressCandidate = nil
        edgeSnapSequenceSuppressed = true
        edgeSnapResolveAttempts = 0
        edgeSnapDrag = nil
        hideEdgeSnapPreview(immediately: false)
        hideSnapLayoutsPanel()
        cancelDividerHint()
    }

    private func showEdgeSnapPreview(frame: CGRect) {
        edgeSnapPreviewGeneration += 1
        let panel: NSPanel
        if let existing = edgeSnapPreviewPanel {
            panel = existing
        } else {
            panel = makeEdgeSnapPreviewPanel()
            edgeSnapPreviewPanel = panel
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideEdgeSnapPreview(immediately: Bool) {
        guard let panel = edgeSnapPreviewPanel, panel.isVisible else { return }
        edgeSnapPreviewGeneration += 1
        let generation = edgeSnapPreviewGeneration
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
            guard let self, let panel,
                  generation == self.edgeSnapPreviewGeneration else { return }
            panel.orderOut(nil)
        }
    }

    private func makeEdgeSnapPreviewPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = WindowEdgeSnapPreviewView(frame: .zero)
        return panel
    }

    // MARK: - Move and resize gesture

    private func startGestureTap() {
        guard gestureTap == nil else {
            isGestureRunning = true
            return
        }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handleGestureEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isGestureRunning = false
            return
        }

        gestureTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        gestureRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isGestureRunning = true
    }

    private func stopGestureTap() {
        // A press still under custody has to go back to the app before the
        // tap that is holding it disappears, or that click is simply lost.
        flushPending(proxy: nil, at: nil)
        if let gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
            CFMachPortInvalidate(gestureTap)
        }
        gestureTap = nil
        gestureRunLoopSource = nil
        activeGesture = nil
        pendingGesture = nil
        endGestureAssistiveMode()
        isGestureRunning = false
    }

    private var gestureState: WindowGestureState {
        if activeGesture != nil { return .active }
        if pendingGesture != nil { return .pending }
        return .idle
    }

    private var trackedGestureButton: WindowPointerGesture.Button? {
        activeGesture?.button ?? pendingGesture?.button
    }

    /// Whether the button that started the press is still down. Only worth
    /// asking when the tap was switched off, because that is the one moment
    /// the release can reach the app without passing through here.
    private func isTrackedButtonDown() -> Bool {
        guard let button = trackedGestureButton else { return false }
        return CGEventSource.buttonState(.combinedSessionState,
                                         button: button == .primary ? .left : .right)
    }

    /// A press that carries the chord is held back, not taken: the app only
    /// loses it once the pointer moves far enough to mean a window gesture.
    /// A press that ends where it started is handed straight back, so an
    /// ordinary modifier click keeps working in every app.
    private func handleGestureEvent(proxy: CGEventTapProxy?,
                                    type: CGEventType,
                                    event: CGEvent) -> Unmanaged<CGEvent>? {
        // The press this service gave back to the system. Looking at it again
        // would take it right back and never let go.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownProcessID {
            return Unmanaged.passUnretained(event)
        }

        let tapDisabled = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        if tapDisabled, let gestureTap {
            if SessionActivity.shared.isActive, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: gestureTap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.syncWithPreferences() }
            }
        }

        var chord: (button: WindowPointerGesture.Button, wantsResize: Bool)?
        let input: WindowGestureInput
        if tapDisabled {
            input = .tapDisabled(buttonStillDown: isTrackedButtonDown())
        } else if !AXIsProcessTrusted() {
            // Never enter Accessibility from a live tap after the grant is
            // revoked. A blocked AX call here would stall system input.
            input = .accessibilityLost
        } else {
            switch type {
            case .leftMouseDown, .rightMouseDown:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseDown ? .primary : .secondary
                chord = gestureChord(type: type, flags: event.flags)
                input = .buttonDown(sameButton: button == trackedGestureButton,
                                    chordMatched: chord != nil)
            case .leftMouseDragged, .rightMouseDragged:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseDragged ? .primary : .secondary
                let pastSlop = pendingGesture.map {
                    WindowGestureSupport.exceedsDragSlop(from: $0.origin, to: event.location)
                } ?? false
                input = .buttonDragged(tracked: button == trackedGestureButton, pastSlop: pastSlop)
            case .leftMouseUp, .rightMouseUp:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseUp ? .primary : .secondary
                input = .buttonUp(tracked: button == trackedGestureButton)
            default:
                input = .otherEvent
            }
        }

        var decision = WindowGestureSupport.decide(state: gestureState, input: input)
        switch decision {
        case .restartAsIdle:
            pendingGesture = nil
            decision = WindowGestureSupport.decide(state: .idle, input: input)
        case .flushThenRestart:
            flushPending(proxy: proxy, at: event.location)
            decision = WindowGestureSupport.decide(state: .idle, input: input)
        default:
            break
        }

        switch decision {
        case .passThrough, .restartAsIdle, .flushThenRestart:
            return Unmanaged.passUnretained(event)

        case .hold:
            return nil

        case .arm:
            guard let chord else { return Unmanaged.passUnretained(event) }
            return arm(chord: chord, event: event)

        case .promote:
            guard let pending = pendingGesture else { return nil }
            promote(pending, pointer: event.location)
            return nil

        case .applyMove:
            guard var gesture = activeGesture else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            let updateInterval: TimeInterval
            switch gesture.kind {
            case .move:
                updateInterval = moveGestureUpdateInterval
            case .resize:
                updateInterval = resizeGestureUpdateInterval
            }
            if now - gesture.lastAppliedAt >= updateInterval {
                apply(gesture, pointer: event.location)
                gesture.lastAppliedAt = now
                activeGesture = gesture
            }
            return nil

        case .applyFinish:
            if let gesture = activeGesture {
                apply(gesture, pointer: event.location)
            }
            activeGesture = nil
            endGestureAssistiveMode()
            return nil

        case .replayThenPass:
            // The held press goes back first and this release closes the pair,
            // so the app sees one ordinary click and never half of one.
            flushPending(proxy: proxy, at: event.location)
            return Unmanaged.passUnretained(event)

        case .flushThenPass:
            // A disabled tap carries no position, and its proxy is no longer a
            // dependable way back into the stream.
            flushPending(proxy: tapDisabled ? nil : proxy,
                         at: tapDisabled ? nil : event.location)
            return Unmanaged.passUnretained(event)

        case .dropState:
            activeGesture = nil
            pendingGesture = nil
            endGestureAssistiveMode()
            return Unmanaged.passUnretained(event)
        }
    }

    private func endGestureAssistiveMode() {
        let suspension = gestureAssistiveMode
        gestureAssistiveMode = nil
        // With the grant revoked there is no safe way to touch the app again;
        // the flag comes back when the assistive client sets it.
        guard AXIsProcessTrusted() else { return }
        suspension?.resume()
    }

    private func gestureChord(type: CGEventType,
                              flags: CGEventFlags) -> (button: WindowPointerGesture.Button,
                                                       wantsResize: Bool)? {
        let moveModifiers = WindowGestureSupport.modifiers(
            from: UserDefaults.standard.string(forKey: DefaultsKey.windowGestureModifiers)
        )
        let resizeModifiers = WindowGestureSupport.resizeModifiers(from: moveModifiers)
        if type == .leftMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: moveModifiers) {
            return (.primary, false)
        }
        if type == .leftMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: resizeModifiers) {
            return (.primary, true)
        }
        if type == .rightMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: moveModifiers) {
            return (.secondary, true)
        }
        return nil
    }

    /// Takes custody of a press that matches the chord over a window this
    /// service can actually move. Anything it cannot move keeps its click.
    private func arm(chord: (button: WindowPointerGesture.Button, wantsResize: Bool),
                     event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let target = gestureTarget(at: event.location,
                                         requiresResize: chord.wantsResize)
        else { return Unmanaged.passUnretained(event) }

        let resolvedKind: WindowPointerGesture.Kind
        if chord.wantsResize {
            let frame = CGRect(origin: target.frame.origin, size: target.frame.size)
            let edges = WindowGestureSupport.resizeEdges(at: event.location, in: frame)
            guard !edges.isEmpty else { return Unmanaged.passUnretained(event) }
            resolvedKind = .resize(edges)
        } else {
            resolvedKind = .move
        }

        // Without a copy there is nothing to give back, and keeping a press
        // that can never be returned is worse than not holding it at all.
        guard let down = event.copy() else { return Unmanaged.passUnretained(event) }
        pendingGesture = PendingWindowGesture(down: down,
                                              button: chord.button,
                                              kind: resolvedKind,
                                              window: target.window,
                                              app: target.app,
                                              originalFrame: CGRect(origin: target.frame.origin,
                                                                    size: target.frame.size),
                                              origin: event.location)
        return nil
    }

    /// The press became a gesture. Raising happens here and not at the press,
    /// so a plain modifier click never activates or reorders a window.
    private func promote(_ pending: PendingWindowGesture, pointer: CGPoint) {
        pendingGesture = nil
        // Suspended for the whole gesture, not per frame write: the writes come
        // at pointer speed and the flag only needs to move twice.
        gestureAssistiveMode?.resume()
        gestureAssistiveMode = EnhancedUserInterfaceSuspension.suspend(forAppOf: pending.window)
        if UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureRaiseWindow) {
            _ = pending.app.activate(options: [])
            AXUIElementPerformAction(pending.window, kAXRaiseAction as CFString)
        }
        // The press point stays the anchor: measuring from where the slop was
        // crossed would leave the window trailing the pointer for good.
        var gesture = WindowPointerGesture(window: pending.window,
                                           kind: pending.kind,
                                           button: pending.button,
                                           originalFrame: pending.originalFrame,
                                           pointerStart: pending.origin,
                                           lastAppliedAt: ProcessInfo.processInfo.systemUptime)
        apply(gesture, pointer: pointer)
        gesture.lastAppliedAt = ProcessInfo.processInfo.systemUptime
        activeGesture = gesture
    }

    /// Puts a held press back into the stream. It carries the release point
    /// and the current time so the app reads the pair as one short click on
    /// one element, however long the button was held.
    private func flushPending(proxy: CGEventTapProxy?, at point: CGPoint?) {
        guard let pending = pendingGesture else { return }
        pendingGesture = nil
        let down = pending.down
        down.location = point ?? pending.origin
        down.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        if let proxy {
            // Posted through the tap it is leaving, which places it ahead of
            // the event this callback is about to return.
            down.tapPostEvent(proxy)
        } else {
            down.post(tap: .cgSessionEventTap)
        }
    }

    private func apply(_ gesture: WindowPointerGesture, pointer: CGPoint) {
        switch gesture.kind {
        case .move:
            let origin = WindowGestureSupport.movedOrigin(from: gesture.originalFrame.origin,
                                                          pointerStart: gesture.pointerStart,
                                                          pointerNow: pointer)
            _ = setPosition(origin, on: gesture.window)
        case .resize(let edges):
            let frame = WindowGestureSupport.resizedFrame(from: gesture.originalFrame,
                                                          pointerStart: gesture.pointerStart,
                                                          pointerNow: pointer,
                                                          edges: edges)
            // Size must be written first. Moving a full-size window to the
            // requested top or left origin exposes a large intermediate frame
            // before AX applies the size, which appears as a jump or blank
            // content in windows with asynchronous layout.
            guard setSize(frame.size, on: gesture.window) else { return }

            let acceptedFrame = self.frame(of: gesture.window)
            let acceptedSize = acceptedFrame?.size ?? frame.size
            // Right and bottom resizing keeps the original origin, so the
            // helper returns nil instead of adding a non-atomic position write.
            guard let anchoredOrigin = WindowGestureSupport.anchoredOriginIfNeeded(
                original: gesture.originalFrame,
                requestedOrigin: frame.origin,
                acceptedSize: acceptedSize,
                edges: edges
            ) else { return }
            if let currentOrigin = acceptedFrame?.origin {
                if abs(currentOrigin.x - anchoredOrigin.x) > 0.5
                    || abs(currentOrigin.y - anchoredOrigin.y) > 0.5 {
                    _ = setPosition(anchoredOrigin, on: gesture.window)
                }
            } else {
                _ = setPosition(anchoredOrigin, on: gesture.window)
            }
        }
    }

    private func gestureTarget(at point: CGPoint,
                               requiresResize: Bool) -> WindowGestureTarget? {
        let system = AXUIElementCreateSystemWide()
        // No cap here: on the system-wide element a timeout is the default for
        // every question this process asks, whoever asks it (#938).
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &rawElement) == .success,
              let element = rawElement
        else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let window: AXUIElement?
        if role(of: element) == (kAXWindowRole as String) {
            window = element
        } else {
            window = windowAttribute(element, kAXWindowAttribute as String)
                ?? windowAttribute(element, kAXTopLevelUIElementAttribute as String)
        }
        guard let window else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)

        var pid = pid_t(0)
        guard role(of: window) == (kAXWindowRole as String),
              !boolAttribute(window, "AXFullScreen"),
              canSetPosition(on: window),
              (!requiresResize || canSetSize(on: window)),
              AXUIElementGetPid(window, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              app.activationPolicy == .regular,
              let frame = frame(of: window),
              frame.size.width > 80,
              frame.size.height > 80
        else { return nil }
        return WindowGestureTarget(window: window, app: app, frame: frame)
    }

    private func canSetFrame(on window: AXUIElement) -> Bool {
        canSetPosition(on: window) && canSetSize(on: window)
    }

    private func canSetPosition(on window: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              kAXPositionAttribute as CFString,
                                              &positionSettable) == .success
            && positionSettable.boolValue
    }

    private func canSetSize(on window: AXUIElement) -> Bool {
        var sizeSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              kAXSizeAttribute as CFString,
                                              &sizeSettable) == .success
            && sizeSettable.boolValue
    }

    private func canSetFullScreen(on window: AXUIElement) -> Bool {
        var fullScreenSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              "AXFullScreen" as CFString,
                                              &fullScreenSettable) == .success
            && fullScreenSettable.boolValue
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    private func frame(of element: AXUIElement) -> WindowLayoutFrame? {
        guard let origin = pointAttribute(element, kAXPositionAttribute as String),
              let size = sizeAttribute(element, kAXSizeAttribute as String),
              size.width > 0,
              size.height > 0
        else { return nil }
        return WindowLayoutFrame(origin: origin, size: size)
    }

    private func bestScreen(for frame: WindowLayoutFrame,
                            screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let appKitFrame = appKitFrame(fromAX: frame)
        return screens.max { lhs, rhs in
            lhs.frame.intersection(appKitFrame).area < rhs.frame.intersection(appKitFrame).area
        } ?? NSScreen.main ?? screens.first
    }

    private func adjacentScreen(to current: NSScreen,
                                screens: [NSScreen],
                                movingForward: Bool) -> NSScreen? {
        guard let currentIndex = screens.firstIndex(where: { $0 === current }),
              let destinationIndex = WindowLayoutGeometry.adjacentDisplayIndex(
                currentIndex: currentIndex,
                frames: screens.map(\.frame),
                movingForward: movingForward
              )
        else { return nil }
        return screens[destinationIndex]
    }

    private func sidewaysScreen(to current: NSScreen,
                                screens: [NSScreen],
                                movingRight: Bool) -> NSScreen? {
        guard let currentIndex = screens.firstIndex(where: { $0 === current }),
              let destinationIndex = WindowLayoutGeometry.horizontalNeighbourIndex(
                currentIndex: currentIndex,
                frames: screens.map(\.frame),
                movingRight: movingRight
              )
        else { return nil }
        return screens[destinationIndex]
    }

    private func axFrame(fromAppKit rect: NSRect) -> WindowLayoutFrame {
        WindowLayoutFrame(origin: CGPoint(x: rect.minX, y: menuBarScreenTopY - rect.maxY),
                          size: rect.size)
    }

    private func appKitFrame(fromAX frame: WindowLayoutFrame) -> NSRect {
        NSRect(x: frame.origin.x,
               y: menuBarScreenTopY - frame.origin.y - frame.size.height,
               width: frame.size.width,
               height: frame.size.height)
    }

    private var menuBarScreenTopY: CGFloat {
        let menuBarScreen = NSScreen.screens.first {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        }
        return (menuBarScreen ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return false }
        return (value as? Bool) ?? false
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func windowAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func windowsAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let values = value as? [AXUIElement]
        else { return nil }
        return values
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

private struct WindowLayoutTarget {
    let window: AXUIElement
    let key: WindowLayoutWindowKey
    let frame: WindowLayoutFrame

    var windowID: CGWindowID { key.windowID }
}

private struct WindowDirectionalSession {
    let target: WindowLayoutTarget
    let visibleFrame: NSRect
    let pointerOrigin: CGPoint
    var action: WindowDirectionalAction?
    var manualOverride: WindowDirectionalAction?
}

/// Native glass-ring container; no upstream artwork or media is bundled.
private final class WindowDirectionalIndicatorView: NSView {
    private let canvas: WindowDirectionalIndicatorCanvasView

    var action: WindowDirectionalAction? {
        didSet { canvas.action = action }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: frameRect.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        canvas = WindowDirectionalIndicatorCanvasView(
            frame: CGRect(origin: .zero, size: frameRect.size))
        canvas.autoresizingMask = [.width, .height]
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(effect)
        addSubview(canvas, positioned: .above, relativeTo: effect)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// The canvas stays separate from `NSVisualEffectView`: AppKit may composite
/// the material after a visual-effect subclass draws, hiding custom artwork.
private final class WindowDirectionalIndicatorCanvasView: NSView {
    var action: WindowDirectionalAction? { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        let outerRadius: CGFloat = 84
        let innerRadius: CGFloat = 46
        let track = annulus(center: center, outer: outerRadius, inner: innerRadius)

        // 1. Subtle frosted track background
        context.saveGState()
        context.addPath(track)
        context.setFillColor(NSColor(white: 0.10, alpha: 0.35).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        // 2. Soft borders for track
        context.saveGState()
        context.addPath(track)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
        context.restoreGState()

        // 3. Highlight active sector if one of the 8 directions is active
        if let direction = Direction(action: action) {
            let highlight = sector(center: center,
                                   outer: outerRadius - 1.5,
                                   inner: innerRadius + 1.5,
                                   centerAngle: direction.angle)
            context.saveGState()
            context.addPath(highlight)
            context.clip()

            let accent = NSColor.controlAccentColor
            let lighterAccent = accent.blended(withFraction: 0.30, of: .white) ?? accent
            let colors = [
                lighterAccent.withAlphaComponent(0.85).cgColor,
                accent.withAlphaComponent(0.75).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                let rad = direction.angle * .pi / 180
                let startPoint = CGPoint(x: center.x + cos(rad) * innerRadius,
                                         y: center.y + sin(rad) * innerRadius)
                let endPoint = CGPoint(x: center.x + cos(rad) * outerRadius,
                                       y: center.y + sin(rad) * outerRadius)
                context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
            }
            context.restoreGState()
        }

        // 4. Subtle dividers between the 8 sectors
        drawDividers(center: center, inner: innerRadius + 4, outer: outerRadius - 4, context: context)

        // 5. Directional pips on the outer ring
        drawDirectionPips(center: center, radius: (innerRadius + outerRadius) / 2, activeDirection: Direction(action: action), context: context)

        // 6. Center Hub & Glyph
        drawCenterHub(center: center, action: action, context: context)
    }

    private func annulus(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                   width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                                   width: inner * 2, height: inner * 2))
        return path
    }

    private func sector(center: CGPoint, outer: CGFloat, inner: CGFloat,
                        centerAngle: CGFloat) -> CGPath {
        let start = (centerAngle - 22.5) * .pi / 180
        let end = (centerAngle + 22.5) * .pi / 180
        let path = CGMutablePath()
        path.addArc(center: center, radius: outer, startAngle: start,
                    endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end,
                    endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func drawDividers(center: CGPoint, inner: CGFloat, outer: CGFloat,
                              context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.6)
        for angle in stride(from: CGFloat(22.5), to: 360, by: 45) {
            let radians = angle * .pi / 180
            context.move(to: CGPoint(x: center.x + cos(radians) * inner,
                                     y: center.y + sin(radians) * inner))
            context.addLine(to: CGPoint(x: center.x + cos(radians) * outer,
                                        y: center.y + sin(radians) * outer))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawDirectionPips(center: CGPoint, radius: CGFloat,
                                   activeDirection: Direction?, context: CGContext) {
        for direction in Direction.allCases {
            let isActive = direction == activeDirection
            let rad = direction.angle * .pi / 180
            let pipCenter = CGPoint(x: center.x + cos(rad) * radius,
                                    y: center.y + sin(rad) * radius)
            let pipRadius: CGFloat = isActive ? 3.5 : 2.0
            let pipRect = CGRect(x: pipCenter.x - pipRadius,
                                 y: pipCenter.y - pipRadius,
                                 width: pipRadius * 2,
                                 height: pipRadius * 2)
            context.saveGState()
            if isActive {
                context.setShadow(offset: .zero, blur: 8,
                                  color: NSColor.white.withAlphaComponent(0.8).cgColor)
                context.setFillColor(NSColor.white.cgColor)
            } else {
                context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            }
            context.fillEllipse(in: pipRect)
            context.restoreGState()
        }
    }

    private func drawCenterHub(center: CGPoint, action: WindowDirectionalAction?, context: CGContext) {
        let radius: CGFloat = 38
        let hub = CGRect(x: center.x - radius, y: center.y - radius,
                         width: radius * 2, height: radius * 2)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)

        if action == .maximize {
            let accent = NSColor.controlAccentColor
            context.setFillColor(accent.withAlphaComponent(0.30).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(accent.withAlphaComponent(0.80).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        } else if action == .minimize {
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.22).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        } else {
            context.setFillColor(NSColor(white: 0.14, alpha: 0.80).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        }

        // Miniature macOS window frame
        let window = CGRect(x: center.x - 16, y: center.y - 12, width: 32, height: 24)
        let outline = CGPath(roundedRect: window, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)

        context.saveGState()
        context.addPath(outline)
        if action == .maximize {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        } else if action == .minimize {
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.90).cgColor)
        } else if action != nil {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        } else {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.50).cgColor)
        }
        context.setLineWidth(1.4)
        context.strokePath()
        context.restoreGState()

        // Content area inside window
        if action == .minimize {
            let arrowPath = CGMutablePath()
            arrowPath.move(to: CGPoint(x: center.x, y: center.y + 4.5))
            arrowPath.addLine(to: CGPoint(x: center.x, y: center.y - 3.5))
            arrowPath.move(to: CGPoint(x: center.x - 4, y: center.y - 0.5))
            arrowPath.addLine(to: CGPoint(x: center.x, y: center.y - 4.5))
            arrowPath.addLine(to: CGPoint(x: center.x + 4, y: center.y - 0.5))

            context.saveGState()
            context.addPath(arrowPath)
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        } else if action == .maximize {
            let inner = window.insetBy(dx: 2.5, dy: 2.5)
            context.saveGState()
            let fillPath = CGPath(roundedRect: inner, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            context.addPath(fillPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
            context.fillPath()
            context.restoreGState()
        } else if let action, let region = glyphRegion(for: action, in: window.insetBy(dx: 2.5, dy: 2.5)) {
            context.saveGState()
            let fillPath = CGPath(roundedRect: region, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(fillPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }

    private func glyphRegion(for action: WindowDirectionalAction, in rect: CGRect) -> CGRect? {
        switch action {
        case .leftHalf: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .rightHalf: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .topHalf: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .bottomHalf: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .topLeft: return CGRect(x: rect.minX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .topRight: return CGRect(x: rect.midX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .bottomLeft: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height / 2)
        case .bottomRight: return CGRect(x: rect.midX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .maximize: return rect
        case .minimize: return nil
        }
    }

    private enum Direction: CaseIterable {
        case right, topRight, top, topLeft, left, bottomLeft, bottom, bottomRight

        var angle: CGFloat {
            switch self {
            case .right: return 0
            case .topRight: return 45
            case .top: return 90
            case .topLeft: return 135
            case .left: return 180
            case .bottomLeft: return 225
            case .bottom: return 270
            case .bottomRight: return 315
            }
        }

        var action: WindowDirectionalAction {
            switch self {
            case .right: return .rightHalf
            case .topRight: return .topRight
            case .top: return .topHalf
            case .topLeft: return .topLeft
            case .left: return .leftHalf
            case .bottomLeft: return .bottomLeft
            case .bottom: return .bottomHalf
            case .bottomRight: return .bottomRight
            }
        }

        init?(action: WindowDirectionalAction?) {
            guard let action, let value = Self.allCases.first(where: { $0.action == action }) else {
                return nil
            }
            self = value
        }
    }
}

/// C trampoline for the linked-resize `AXObserver` — no captures, so it
/// bridges to a C function pointer; the service is recovered from the
/// refcon, same pattern as `autoQuitAXCallback`.
private func windowLayoutLinkedResizeAXCallback(_ observer: AXObserver,
                                                 _ element: AXUIElement,
                                                 _ notification: CFString,
                                                 _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let service = Unmanaged<WindowLayoutService>.fromOpaque(refcon).takeUnretainedValue()
    service.handleLinkedResizeNotification(element: element, notification: notification as String)
}

/// Everything the deferred settle verification needs to finish judging a
/// discrete layout action after the grace period.
private struct SettleContext {
    let window: AXUIElement
    let windowID: CGWindowID
    let frame: WindowLayoutFrame
    let targetRect: NSRect
    let screenVisibleFrame: NSRect
    let action: WindowLayoutAction
    let original: WindowLayoutFrame?
    let previousAction: WindowLayoutAction?
    let windowKey: WindowLayoutWindowKey
    /// Which published result this settle belongs to; a late failure only
    /// speaks when no newer action has published since.
    let resultGeneration: Int
}

private struct WindowLayoutPlacement {
    let frame: WindowLayoutFrame
    let rect: NSRect
}

private struct WindowGestureTarget {
    let window: AXUIElement
    let app: NSRunningApplication
    let frame: WindowLayoutFrame
}

private enum WindowEdgeSnapPointerInput {
    case down(location: CGPoint, flags: CGEventFlags)
    case dragged(location: CGPoint)
    case up(location: CGPoint)
}

private struct WindowEdgeSnapDrag {
    let window: AXUIElement
    let key: WindowLayoutWindowKey
    let initialFrame: CGRect
    let pointerStart: CGPoint
    let protectsSystemTopEdge: Bool
    let quartzScreenFrames: [CGRect]
    var lastSampleAt: TimeInterval
    var mismatchCount: Int
    var isMoving: Bool
    var target: WindowEdgeSnapTarget?
}

/// A press the tap is holding while it is still undecided. It keeps the
/// original event so the click can be handed back untouched, with its
/// modifiers and its click count intact.
private struct PendingWindowGesture {
    let down: CGEvent
    let button: WindowPointerGesture.Button
    let kind: WindowPointerGesture.Kind
    let window: AXUIElement
    let app: NSRunningApplication
    let originalFrame: CGRect
    let origin: CGPoint
}

private struct WindowPointerGesture {
    enum Button {
        case primary
        case secondary
    }

    enum Kind {
        case move
        case resize(WindowGestureResizeEdges)
    }

    let window: AXUIElement
    let kind: Kind
    let button: Button
    let originalFrame: CGRect
    let pointerStart: CGPoint
    var lastAppliedAt: TimeInterval
}

private final class WindowEdgeSnapPreviewView: NSView {
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

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
