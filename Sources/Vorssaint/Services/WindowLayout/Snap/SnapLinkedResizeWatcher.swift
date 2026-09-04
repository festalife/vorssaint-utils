// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics

/// Watches every Snap Group member for a move or a resize and reports each one
/// exactly once per throttled tick (spec §6).
///
/// One `AXObserver` per *process*, never per window: an app with several tiled
/// windows would otherwise get one observer per window, each of them receiving
/// every one of that app's window notifications. The app-level
/// `kAXWindowResizedNotification`/`kAXWindowMovedNotification` pair is the one
/// ordinary AppKit windows actually post ("at the end of the window
/// move/resize", per Apple's own header comments, with the moved window as the
/// notification's element); the per-window `kAXResizedNotification`/
/// `kAXMovedNotification` pair is registered on the same shared observer as a
/// defensive extra for the apps that do post those.
///
/// The watcher deliberately knows nothing about geometry: it resolves "which
/// of my watched windows just changed" and hands that windowID to
/// `SnapController`, which reads the live frame and decides what it means.
final class SnapLinkedResizeWatcher {
    /// Called on the main run loop, at most once per `throttleInterval` per
    /// window, with a window whose geometry may have changed.
    var onChange: ((CGWindowID) -> Void)?

    private struct WindowObservation {
        let element: AXUIElement
        /// Recorded so a notification can be rejected the moment it turns out
        /// to belong to a different process — window ids are reused by the
        /// window server, so the id alone proves nothing.
        let pid: pid_t
    }

    private struct AppObservation {
        let observer: AXObserver
        let app: AXUIElement
        var watched: Set<CGWindowID> = []
    }

    private var windows: [CGWindowID: WindowObservation] = [:]
    private var apps: [pid_t: AppObservation] = [:]
    private var pending: Set<CGWindowID> = []

    /// A resize drag emits notifications in a burst; further ones for the same
    /// window inside this interval are folded into the one scheduled pass,
    /// which reads whatever the live frame is by the time it fires.
    private let throttleInterval: TimeInterval = 1.0 / 30.0

    var watchedWindowIDs: Set<CGWindowID> { Set(windows.keys) }

    /// The element `SnapController` writes through for `windowID` — already
    /// resolved and already carrying `SnapAX.Timeout.neighbour`, so a linked
    /// write costs no extra lookup.
    func element(for windowID: CGWindowID) -> AXUIElement? {
        windows[windowID]?.element
    }

    func pid(for windowID: CGWindowID) -> pid_t? {
        windows[windowID]?.pid
    }

    // MARK: - Membership

    /// Makes the watched set exactly `wanted`. Called after every Snap Group
    /// mutation and from `syncWithPreferences`, so toggling the feature starts
    /// or stops watching immediately rather than at the next placement.
    func watch(_ wanted: Set<CGWindowID>) {
        let watching = Set(windows.keys)
        let toStop = watching.subtracting(wanted)
        let toStart = wanted.subtracting(watching)
        guard !toStop.isEmpty || !toStart.isEmpty else { return }
        SnapLog.event("link.sync",
                      "watching=\(watching.count) wanted=\(wanted.count) start=\(toStart.count) stop=\(toStop.count)")
        for windowID in toStop { stop(windowID) }
        for windowID in toStart { start(windowID) }
    }

    func stopAll() {
        for windowID in Array(windows.keys) { stop(windowID) }
        pending.removeAll()
    }

    private func start(_ windowID: CGWindowID) {
        guard let pid = SnapAX.ownerPIDs()[windowID] else {
            SnapLog.event("link.watch-skip", "windowID=\(windowID) reason=no-owner-pid")
            return
        }
        let observation: AppObservation
        if let existing = apps[pid] {
            observation = existing
        } else {
            guard let created = makeAppObservation(pid: pid) else { return }
            apps[pid] = created
            observation = created
        }
        guard let element = SnapAX.window(windowID, in: observation.app, timeout: SnapAX.Timeout.neighbour) else {
            SnapLog.event("link.watch-skip", "windowID=\(windowID) pid=\(pid) reason=no-ax-element")
            dropAppObservationIfUnused(pid: pid)
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observation.observer, element, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(observation.observer, element, kAXMovedNotification as CFString, refcon)
        windows[windowID] = WindowObservation(element: element, pid: pid)
        apps[pid]?.watched.insert(windowID)
        SnapLog.event("link.watch", "windowID=\(windowID) pid=\(pid) app=\(Self.label(for: pid))")
    }

    private func makeAppObservation(pid: pid_t) -> AppObservation? {
        let axApp = SnapAX.application(pid, timeout: SnapAX.Timeout.neighbour)
        var observerRef: AXObserver?
        let createError = AXObserverCreate(pid, snapLinkedResizeAXCallback, &observerRef)
        guard createError == .success, let observer = observerRef else {
            SnapLog.event("link.watch-skip", "pid=\(pid) reason=observer-create-failed error=\(createError.rawValue)")
            return nil
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let resized = AXObserverAddNotification(observer, axApp, kAXWindowResizedNotification as CFString, refcon)
        let moved = AXObserverAddNotification(observer, axApp, kAXWindowMovedNotification as CFString, refcon)
        guard resized == .success || moved == .success else {
            SnapLog.event("link.watch-skip",
                          "pid=\(pid) reason=app-registration-failed resized=\(resized.rawValue) moved=\(moved.rawValue)")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return AppObservation(observer: observer, app: axApp)
    }

    private func stop(_ windowID: CGWindowID) {
        guard let observation = windows.removeValue(forKey: windowID) else { return }
        if let app = apps[observation.pid] {
            AXObserverRemoveNotification(app.observer, observation.element, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(app.observer, observation.element, kAXMovedNotification as CFString)
            apps[observation.pid]?.watched.remove(windowID)
        }
        pending.remove(windowID)
        SnapLog.event("link.unwatch", "windowID=\(windowID) pid=\(observation.pid)")
        dropAppObservationIfUnused(pid: observation.pid)
    }

    /// Tears the shared per-process observer down once nothing of that process
    /// is watched any more — including after a failed window registration, so
    /// a process that never ends up with a single watched window does not
    /// leave an app-level observer running for nothing.
    private func dropAppObservationIfUnused(pid: pid_t) {
        guard let app = apps[pid], app.watched.isEmpty else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(app.observer), .commonModes)
        AXObserverRemoveNotification(app.observer, app.app, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(app.observer, app.app, kAXWindowMovedNotification as CFString)
        apps.removeValue(forKey: pid)
    }

    // MARK: - Notifications

    /// Called from the C observer callback, already on the main run loop (the
    /// observer's source was added there), so no further dispatch is needed.
    func handle(element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0, apps[pid] != nil else { return }
        guard let windowID = resolve(element: element, pid: pid) else {
            SnapLog.event("link.notify-unresolved", "pid=\(pid) notification=\(notification)")
            return
        }
        schedule(windowID)
    }

    /// Which of `pid`'s watched windows the notification's element is. Three
    /// passes, cheapest first, because none of them is reliable alone:
    ///
    /// 1. `AXWindowResolver`'s private window-id bridge — usually exact and
    ///    free of an extra round trip, but reported flaky specifically for
    ///    Chromium/Electron windows.
    /// 2. Element identity: `AXUIElement` supports `CFEqual` for "the same
    ///    underlying accessibility object", compared against the cached
    ///    element. Also free of any AX call.
    /// 3. Frame matching, which does cost real round trips and so comes last —
    ///    and is exactly what the flaky-identifier apps need.
    private func resolve(element: AXUIElement, pid: pid_t) -> CGWindowID? {
        guard let watched = apps[pid]?.watched, !watched.isEmpty else { return nil }
        if let windowID = AXWindowResolver.windowID(for: element), watched.contains(windowID) {
            return windowID
        }
        if let matched = watched.first(where: { windowID in
            guard let cached = windows[windowID]?.element else { return false }
            return CFEqual(cached, element)
        }) {
            return matched
        }
        guard let elementFrame = SnapAX.quartzFrame(of: element) else { return nil }
        return watched.first { windowID in
            guard let cached = windows[windowID]?.element,
                  let cachedFrame = SnapAX.quartzFrame(of: cached)
            else { return false }
            return abs(elementFrame.minX - cachedFrame.minX) <= 2
                && abs(elementFrame.minY - cachedFrame.minY) <= 2
                && abs(elementFrame.width - cachedFrame.width) <= 2
                && abs(elementFrame.height - cachedFrame.height) <= 2
        }
    }

    private func schedule(_ windowID: CGWindowID) {
        guard pending.insert(windowID).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + throttleInterval) { [weak self] in
            guard let self else { return }
            self.pending.remove(windowID)
            guard self.windows[windowID] != nil else { return }
            self.onChange?(windowID)
        }
    }

    static func label(for pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }
}

/// The C trampoline `AXObserverCreate` needs. Kept at file scope, as
/// `AXObserverCallback` is a plain C function pointer that cannot capture.
private func snapLinkedResizeAXCallback(observer: AXObserver,
                                        element: AXUIElement,
                                        notification: CFString,
                                        refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<SnapLinkedResizeWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(element: element, notification: notification as String)
}
