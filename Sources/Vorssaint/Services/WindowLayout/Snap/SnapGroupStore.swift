// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics

/// Which windows are snapped together on each screen, where they actually are
/// right now, and what happens when one of them is resized (spec §5, §6, §7,
/// §8).
///
/// Split out of `SnapController` on purpose: this half remembers *state about
/// windows*, the other half reacts to the pointer. The two only meet at
/// `record(...)` (a placement landed) and `freeSpace(...)` (a zone is being
/// computed).
///
/// Two rectangles per member, never conflated — the distinction the whole
/// feature turns on:
/// - `SnapGroupMember.frame` is the **zone** the member was placed into, fixed
///   at that moment. It decides *whether* two members are neighbours.
/// - The live Accessibility frame decides *where* the shared edge is right
///   now. It is re-read, never stored back into the zone: a linked resize is
///   not a placement, and writing its result into the zone made two members'
///   zones drift apart until they read as "not touching" mid-drag.
final class SnapGroupStore {
    /// Called when a member is resized by hand — the layout is being reshaped,
    /// so anything offering a cell (Snap Assist) has gone stale.
    var onLayoutReshaped: ((String) -> Void)?

    /// One group per display, in memory only for the session, matching how
    /// Windows itself forgets a Snap Group once the session ends. Keyed by
    /// display id, never by `NSScreen` identity, which AppKit is free to
    /// invalidate on a reconfiguration.
    private var groups: [CGDirectDisplayID: SnapGroup] = [:]

    private let watcher = SnapLinkedResizeWatcher()
    private var watcherEnabled = false

    /// The last frame each member was actually observed at, and when — set by
    /// a placement, by every notification processed, and by every frame this
    /// store writes itself. The timestamp is what keeps a remembered frame
    /// from being trusted forever: past `cachedFrameLifetime` it is no longer
    /// evidence of anything.
    ///
    /// Deliberately separate from `SnapGroupMember.frame`. The zone must stay
    /// fixed (it is what decides adjacency), but "did this window move or was
    /// it resized" can only be answered against where it last actually was.
    /// Comparing a live frame against the zone instead is a bug that only
    /// appears *after* a linked resize, when the two have legitimately
    /// diverged — see `SnapMemberMotion` for the capture that found it.
    private var lastLiveFrames: [CGWindowID: (frame: CGRect, at: TimeInterval)] = [:]
    /// How long a remembered frame may still stand in for a live read that
    /// did not land. Long enough to cover a slow app for several pointer
    /// samples, far too short to let a window that has since been moved or
    /// closed keep distorting a placement.
    private static let cachedFrameLifetime: TimeInterval = 2

    /// The smallest size each member's app has actually been observed to
    /// accept. Accessibility cannot be asked for this, so it is only ever
    /// learned by writing something smaller and reading back what came out.
    /// Remembered so the *next* step of the same seam drag clamps up front
    /// instead of rediscovering the floor — which is what made a clamped
    /// neighbour get rewritten, and re-anchored, on every notification.
    /// Cleared when the member is placed again or leaves the group.
    private var acceptedMinimums: [CGWindowID: CGSize] = [:]

    /// Frames this store wrote itself, and when. The AX notification a write
    /// provokes must not be mistaken for a fresh user drag — correlated by
    /// *frame*, not by a time window, so a genuine resize starting moments
    /// after a linked write is caught immediately (its live frame no longer
    /// matches) instead of being swallowed for a fixed interval.
    private var selfWrites: [CGWindowID: (frame: CGRect, at: TimeInterval)] = [:]
    private let selfWriteExpiry: TimeInterval = 0.1
    private let selfWriteTolerance: CGFloat = 2

    /// Live frames per screen, refreshed at most every `framesCacheTTL`.
    /// Without it a drag would run a full window-server scan plus one AX round
    /// trip per member on every pointer sample; `SnapAX.Timeout.neighbour`
    /// caps the per-member worst case, not how often it is paid.
    private var framesCache: [CGDirectDisplayID: (snapshot: GroupFrames, at: TimeInterval)] = [:]
    private static let framesCacheTTL: TimeInterval = 0.2

    private var screenObserver: NSObjectProtocol?
    private var reflowScheduled = false

    /// Accessibility cannot be asked for a window's minimum size, so the first
    /// pass guesses this floor and a corrective pass uses whatever size was
    /// actually accepted.
    private static let minimumSizeGuess = CGSize(width: 80, height: 80)
    /// Hard ceiling on one linked-resize pass across both of its passes. Each
    /// member write is capped individually by `SnapAX.Timeout.neighbour`, but
    /// a run of slow members could otherwise add up unbounded on the main
    /// thread. Members left over are simply picked up on the next
    /// notification.
    private static let linkedResizeBudget: TimeInterval = 0.6

    init() {
        watcher.onChange = { [weak self] windowID in self?.geometryChanged(windowID) }
        // Costs nothing while idle, unlike an input tap, and every real action
        // it triggers re-checks the feature gates itself.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.scheduleReflow() }
    }

    var groupCount: Int { groups.count }

    // MARK: - Membership

    /// Records `windowID`'s membership after a placement wrote `action` on
    /// `screen`. The single point every placement path funnels through.
    func record(action: WindowLayoutAction,
                windowID: CGWindowID,
                appliedRect: CGRect,
                preSnapSize: CGSize,
                on screen: NSScreen) {
        let existing = groups[screen.displayID] ?? SnapGroup(screenID: screen.displayID)
        let snapshot = liveFrames(for: existing, on: screen)
        // The member's zone is the action's *theoretical* rect on this screen,
        // never the rect the placement actually wrote. The two differ exactly
        // when free space borrowed room from a neighbour, and recording the
        // borrowed rect made the zone grow with it — so the next placement
        // measured against an inflated "half" and grew again.
        let zone = theoreticalZone(for: action, on: screen)
        let updated = SnapGroupSupport.updated(group: existing,
                                               windowID: windowID,
                                               action: action,
                                               zone: zone,
                                               preSnapSize: preSnapSize,
                                               currentFrames: snapshot.frames,
                                               gone: snapshot.gone,
                                               minimized: snapshot.minimized,
                                               gap: WindowLayoutGaps.windowGap)
        store(updated, on: screen.displayID)
        // The frame that was actually written is the member's first live
        // frame: where it is, as opposed to which cell it holds.
        observe(appliedRect, for: windowID)
        acceptedMinimums.removeValue(forKey: windowID)
        SnapLog.event("group.join",
                      "windowID=\(windowID) action=\(action) screen=\(screen.displayID) "
                          + "zone=\(SnapLog.rect(zone)) placed=\(SnapLog.rect(appliedRect)) "
                          + "members=\(updated.members.count) zones=[\(Self.describe(updated))]")
        syncWatcher(enabled: watcherEnabled)
    }

    /// The theoretical rect of `action` on `screen` — the only thing a
    /// member's zone is ever allowed to be.
    private func theoreticalZone(for action: WindowLayoutAction, on screen: NSScreen) -> CGRect {
        WindowLayoutGeometry.rect(for: action,
                                  current: screen.visibleFrame,
                                  visibleFrame: screen.visibleFrame,
                                  windowGap: WindowLayoutGaps.windowGap,
                                  screenGap: WindowLayoutGaps.screenGap)
    }

    private func observe(_ frame: CGRect, for windowID: CGWindowID) {
        lastLiveFrames[windowID] = (frame, ProcessInfo.processInfo.systemUptime)
    }

    /// Forgets every group, every remembered frame and every discovered
    /// minimum. Called when the edge-snap tap starts — which is also when
    /// Accessibility is granted and when the feature is switched back on — so
    /// membership recorded before a settings flip, a permission change or a
    /// long idle period can never come back to distort a placement.
    func resetAll(reason: String) {
        guard !groups.isEmpty || !lastLiveFrames.isEmpty || !acceptedMinimums.isEmpty else { return }
        SnapLog.event("group.reset", "reason=\(reason) groups=\(groups.count)")
        groups.removeAll()
        lastLiveFrames.removeAll()
        acceptedMinimums.removeAll()
        selfWrites.removeAll()
        framesCache.removeAll()
        syncWatcher(enabled: watcherEnabled)
    }

    /// Drops `windowID` from every group — for a placement that leaves the
    /// group outright (maximize, full screen, restore, a display change).
    func remove(_ windowID: CGWindowID, reason: String) {
        var touched = false
        for screenID in groups.keys {
            guard groups[screenID]?.members.contains(where: { $0.windowID == windowID }) == true else { continue }
            touched = true
            groups[screenID]?.members.removeAll { $0.windowID == windowID }
            if groups[screenID]?.members.isEmpty == true { groups.removeValue(forKey: screenID) }
        }
        guard touched else { return }
        lastLiveFrames.removeValue(forKey: windowID)
        acceptedMinimums.removeValue(forKey: windowID)
        SnapLog.event("group.leave", "windowID=\(windowID) reason=\(reason)")
        syncWatcher(enabled: watcherEnabled)
    }

    /// Every other member of `windowID`'s group, with its owning pid — Dock
    /// Preview's "Show group" reads this. `nil` when `windowID` is not in a
    /// group, or is its only member.
    func peers(of windowID: CGWindowID) -> [(windowID: CGWindowID, pid: pid_t)]? {
        guard let group = groups.values.first(where: { grp in grp.members.contains { $0.windowID == windowID } }),
              group.members.count > 1
        else { return nil }
        let owners = SnapAX.ownerPIDs()
        let peers = group.members.compactMap { member -> (windowID: CGWindowID, pid: pid_t)? in
            guard member.windowID != windowID, let pid = owners[member.windowID] else { return nil }
            return (member.windowID, pid)
        }
        return peers.isEmpty ? nil : peers
    }

    func group(on screen: NSScreen) -> SnapGroup? {
        groups[screen.displayID]
    }

    /// This screen's Snap Group members as the Snap Assist occupancy test
    /// needs them: zone plus live frame, pruned first so a member that closed
    /// or was dragged away cannot keep a cell reserved. `excluding` is the
    /// window that was just placed, which is never its own obstacle.
    func occupancyMembers(on screen: NSScreen,
                          excluding windowID: CGWindowID) -> [SnapAssistSupport.OccupyingMember] {
        let group = pruned(on: screen)
        guard !group.members.isEmpty else { return [] }
        let resolved = resolvedFrames(for: group, on: screen)
        return group.members
            .filter { $0.windowID != windowID }
            .map {
                SnapAssistSupport.OccupyingMember(windowID: $0.windowID,
                                                  action: $0.action,
                                                  zone: $0.frame,
                                                  liveFrame: resolved.frames[$0.windowID])
            }
    }

    /// Live frames of every member on `screen`, ready for the divider hint.
    /// `nil` when there is no group there at all.
    func liveMemberFrames(on screen: NSScreen) -> [(windowID: CGWindowID, frame: CGRect)]? {
        guard let group = groups[screen.displayID], !group.members.isEmpty else { return nil }
        let live = liveFrames(for: group, on: screen).frames
        return group.members.compactMap { member in
            guard let frame = live[member.windowID] else { return nil }
            return (member.windowID, frame)
        }
    }

    private func store(_ group: SnapGroup, on screenID: CGDirectDisplayID) {
        if group.members.isEmpty {
            groups.removeValue(forKey: screenID)
        } else {
            groups[screenID] = group
        }
    }

    /// Prunes against a live read and persists the smaller group, so a member
    /// that closed, was minimized, or was dragged off its zone is forgotten
    /// once rather than re-resolved (and re-failing) on every later sample.
    @discardableResult
    func pruned(on screen: NSScreen) -> SnapGroup {
        let group = groups[screen.displayID] ?? SnapGroup(screenID: screen.displayID)
        guard !group.members.isEmpty else { return group }
        let snapshot = liveFrames(for: group, on: screen)
        let pruned = SnapGroupSupport.pruned(group: group,
                                             currentFrames: snapshot.frames,
                                             gone: snapshot.gone,
                                             minimized: snapshot.minimized,
                                             gap: WindowLayoutGaps.windowGap)
        // Not a count comparison: the minimized mark can flip without the
        // member count changing, and that mark still has to be persisted.
        guard pruned != group else { return group }
        SnapLog.event("group.prune",
                      "screen=\(screen.displayID) before=\(group.members.count) after=\(pruned.members.count) "
                          + "gone=\(snapshot.gone.count) minimized=\(snapshot.minimized.count)")
        store(pruned, on: screen.displayID)
        syncWatcher(enabled: watcherEnabled)
        return pruned
    }

    // MARK: - Free space (spec §5)

    /// The zone actually available for `action` on `screen`: `theoreticalZone`
    /// with every edge a neighbour touches replaced by that neighbour's real
    /// current edge, so a neighbour that grew shrinks this zone and one that
    /// shrank lets it extend. Falls back to `theoreticalZone` whenever the
    /// preference is off, there is no group, or the result would be a sliver.
    ///
    /// `excluding` is the window this placement is *for*: when it is already a
    /// member (re-snapping), its own old zone must never shrink its new one.
    func freeSpace(for action: WindowLayoutAction,
                   theoreticalZone: CGRect,
                   on screen: NSScreen,
                   excluding windowID: CGWindowID?) -> CGRect {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapFillsFreeSpace) else {
            return theoreticalZone
        }
        guard SnapGroupSupport.joinsGroup(action) else { return theoreticalZone }
        var group = pruned(on: screen)
        if let windowID { group.members.removeAll { $0.windowID == windowID } }
        guard !group.members.isEmpty else { return theoreticalZone }

        let resolved = resolvedFrames(for: group, on: screen)
        let raw = SnapGroupSupport.freeSpace(for: action,
                                             theoreticalZone: theoreticalZone,
                                             group: group,
                                             gap: WindowLayoutGaps.windowGap,
                                             currentFrames: resolved.frames)
        // A neighbour may only move the edge it shares with this zone; every
        // edge the placement anchors to a screen edge stays where the screen
        // put it, whatever a neighbour's frame claims.
        let result = SnapGroupSupport.clampedToAnchors(raw, action: action,
                                                       theoreticalZone: theoreticalZone)
        if result != raw {
            SnapLog.event("free.clamp",
                          "action=\(action) raw=\(SnapLog.rect(raw)) -> \(SnapLog.rect(result)) "
                              + "reason=neighbour-moved-an-anchored-edge")
        }
        // Logged whether or not the zone changed: "why did this placement get
        // the plain theoretical half" is exactly the question a transcript has
        // to answer, and silence when nothing changed answered it least.
        let neighbours = group.members.map { member in
            "\(member.windowID):\(member.action) zone=\(SnapLog.rect(member.frame)) "
                + "used=\(SnapLog.rect(resolved.frames[member.windowID])) "
                + "source=\(resolved.sources[member.windowID] ?? "unknown")"
        }.joined(separator: " | ")
        guard result.width.isFinite, result.height.isFinite, result.width > 0, result.height > 0 else {
            SnapLog.event("free.discard",
                          "action=\(action) theoretical=\(SnapLog.rect(theoreticalZone)) "
                              + "degenerate=\(SnapLog.rect(result)) neighbours=[\(neighbours)]")
            return theoreticalZone
        }
        SnapLog.event("free.space",
                      "action=\(action) theoretical=\(SnapLog.rect(theoreticalZone)) "
                          + "-> \(SnapLog.rect(result))"
                          + (result == theoreticalZone ? " (unchanged)" : "")
                          + " neighbours=[\(neighbours)]")
        return result
    }

    // MARK: - Live frames

    /// One Accessibility sweep over a group's members. `frames` for the ones
    /// that answered; `gone` for the ones confirmed absent from the window
    /// server (closed); `minimized` for the ones confirmed minimized.
    /// A member in none of the three simply did not answer this round — not
    /// proof of anything, so it is kept, unmarked, and tried again next time.
    struct GroupFrames {
        var frames: [CGWindowID: CGRect] = [:]
        var gone: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
        /// Which members the window server showed on this screen during the
        /// sweep — carried on the snapshot so it is cached with everything
        /// else. `resolvedFrames` is asked on every pointer sample during a
        /// drag; a second uncached `CGWindowList` scan there would undo the
        /// whole point of the cache.
        var onScreen: Set<CGWindowID> = []
    }

    func liveFrames(for group: SnapGroup, on screen: NSScreen) -> GroupFrames {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = framesCache[screen.displayID], now - cached.at < Self.framesCacheTTL {
            return cached.snapshot
        }
        let snapshot = readFrames(for: group, on: screen)
        framesCache[screen.displayID] = (snapshot, now)
        return snapshot
    }

    /// One sweep. A member is `gone` when the window server no longer shows it
    /// on this screen at layer 0 and Accessibility does not say it is merely
    /// minimized — closed, moved to another Space, or moved to another
    /// display. Keeping such a member was the ghost bug: windows snapped in an
    /// earlier session went on contributing an edge to every free-space
    /// computation and went on holding their cell against Snap Assist, long
    /// after they had stopped being part of anything.
    private func readFrames(for group: SnapGroup, on screen: NSScreen) -> GroupFrames {
        guard !group.members.isEmpty else { return GroupFrames() }
        let owners = SnapAX.ownerPIDs()
        let onScreen = Set(SnapAX.onScreenWindows(on: screen).map(\.windowID))
        var apps: [pid_t: AXUIElement] = [:]
        var snapshot = GroupFrames()
        snapshot.onScreen = onScreen.intersection(group.members.map(\.windowID))
        for member in group.members {
            guard let pid = owners[member.windowID] else {
                snapshot.gone.insert(member.windowID)
                continue
            }
            if !onScreen.contains(member.windowID) {
                // Not on this screen right now. Minimized is the one case that
                // keeps its place in the group (spec §7); everything else has
                // left, and a member that has left may not keep reserving a
                // cell or shrinking a zone.
                let axApp = apps[pid] ?? {
                    let created = SnapAX.application(pid, timeout: SnapAX.Timeout.neighbour)
                    apps[pid] = created
                    return created
                }()
                if let element = SnapAX.window(member.windowID, in: axApp, timeout: SnapAX.Timeout.neighbour),
                   SnapAX.isMinimized(element) {
                    snapshot.minimized.insert(member.windowID)
                } else {
                    snapshot.gone.insert(member.windowID)
                }
                continue
            }
            let axApp = apps[pid] ?? {
                let created = SnapAX.application(pid, timeout: SnapAX.Timeout.neighbour)
                apps[pid] = created
                return created
            }()
            // Present under this pid, so a lookup miss is Accessibility not
            // answering — never "the window is gone". Retried once, then left
            // for the next sweep.
            guard let element = SnapAX.windowRetrying(member.windowID, in: axApp,
                                                      timeout: SnapAX.Timeout.neighbour)
            else { continue }
            if SnapAX.isMinimized(element) {
                snapshot.minimized.insert(member.windowID)
                continue
            }
            guard let frame = SnapAX.frameRetrying(of: element) else { continue }
            snapshot.frames[member.windowID] = frame
            // A fresh answer is the newest thing anyone knows about this
            // member, so it becomes the fallback every later sweep that misses
            // will use — and the reference the move-vs-resize test measures
            // from.
            observe(frame, for: member.windowID)
        }
        return snapshot
    }

    /// A live frame for every member, and where each one came from: the
    /// Accessibility sweep this instant (`fresh`), or the last frame the
    /// member was actually observed at (`cached`).
    ///
    /// A read that times out is not information, and treating it as one is
    /// what made free space unreliable: a member whose read missed simply
    /// contributed no edge, so a placement silently fell back to the plain
    /// theoretical half — "A snapped left, dragging B to the right edge does
    /// not always fill the remaining space". A remembered frame from a moment
    /// ago is a far better answer than no answer, and it is exactly the frame
    /// that member is still at unless something moved it, in which case a
    /// notification is already on its way. Members confirmed `gone` or
    /// `minimized` contribute nothing either way.
    private func resolvedFrames(for group: SnapGroup,
                                on screen: NSScreen) -> (frames: [CGWindowID: CGRect],
                                                         sources: [CGWindowID: String]) {
        let snapshot = liveFrames(for: group, on: screen)
        let now = ProcessInfo.processInfo.systemUptime
        var frames: [CGWindowID: CGRect] = [:]
        var sources: [CGWindowID: String] = [:]
        for member in group.members {
            if let fresh = snapshot.frames[member.windowID] {
                frames[member.windowID] = fresh
                sources[member.windowID] = "fresh"
            } else if snapshot.gone.contains(member.windowID) {
                sources[member.windowID] = "gone"
            } else if snapshot.minimized.contains(member.windowID) {
                sources[member.windowID] = "minimized"
            } else if let cached = lastLiveFrames[member.windowID],
                      now - cached.at < Self.cachedFrameLifetime,
                      snapshot.onScreen.contains(member.windowID) {
                frames[member.windowID] = cached.frame
                sources[member.windowID] = "cached"
            } else {
                // No usable answer. The member contributes no edge at all this
                // round rather than an old one: a stale frame is worse than
                // none, because it silently distorts a placement instead of
                // leaving it at its honest theoretical zone.
                sources[member.windowID] = "stale"
            }
        }
        return (frames, sources)
    }

    /// Every member's *theoretical* zone on `screen` — the action's own rect,
    /// computed fresh from `member.action`, never read from `member.frame`.
    /// Free-space snapping can legitimately place a member away from its
    /// theoretical zone; adjacency has to be decided against something that
    /// never drifts, or two members placed by different paths stop reading as
    /// neighbours the moment one of them is resized.
    func theoreticalZones(for group: SnapGroup, on screen: NSScreen) -> [CGWindowID: CGRect] {
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

    // MARK: - Screen changes (spec §8)

    /// `didChangeScreenParameters` fires several times for one physical event,
    /// so it is coalesced with enough delay for `NSScreen.screens` to settle.
    private func scheduleReflow() {
        guard !reflowScheduled else { return }
        reflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reflowScheduled = false
            self?.reflowForScreenChange()
        }
    }

    /// Recomputes and re-places every group after a display reconfiguration. A
    /// group whose screen is gone entirely is dropped — there is no geometry
    /// left to recompute it against. Every zone action is already a fraction
    /// of the visible frame, so "in proportion" falls out of simply
    /// re-deriving each member's rect.
    private func reflowForScreenChange() {
        framesCache.removeAll()
        guard AppFeature.windowLayout.isAvailable, AXIsProcessTrusted() else {
            SnapLog.event("group.reflow-skip", "reason=feature-unavailable-or-untrusted")
            return
        }
        for (displayID, group) in groups {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                SnapLog.event("group.reflow", "screen=\(displayID) gone, dropping \(group.members.count) member(s)")
                groups.removeValue(forKey: displayID)
                continue
            }
            let relocations = SnapGroupSupport.relocatedZones(for: group,
                                                              newVisibleFrame: screen.visibleFrame,
                                                              windowGap: WindowLayoutGaps.windowGap,
                                                              screenGap: WindowLayoutGaps.screenGap)
            var updated = group
            var moved = 0
            for (windowID, rect) in relocations {
                guard let index = updated.members.firstIndex(where: { $0.windowID == windowID }),
                      !updated.members[index].isMinimized,
                      rect != updated.members[index].frame,
                      let actual = write(rect, to: windowID)
                else { continue }
                updated.members[index].frame = actual
                moved += 1
            }
            if updated != group {
                groups[displayID] = updated
                SnapLog.event("group.reflow", "screen=\(displayID) moved=\(moved)/\(group.members.count)")
            }
        }
        syncWatcher(enabled: watcherEnabled)
    }

    // MARK: - Writes

    /// Writes `rect` (AppKit space) to `windowID` and reads back what was
    /// accepted, marking the result as self-initiated so the notification the
    /// write provokes is not mistaken for a user drag. `nil` when the window
    /// could not be reached at all — treated as "unreachable this pass", never
    /// as success.
    @discardableResult
    private func write(_ rect: CGRect, to windowID: CGWindowID) -> CGRect? {
        let element: AXUIElement
        if let watched = watcher.element(for: windowID) {
            element = watched
        } else {
            guard let pid = SnapAX.ownerPIDs()[windowID],
                  let resolved = SnapAX.window(windowID, in: SnapAX.application(pid, timeout: SnapAX.Timeout.neighbour),
                                               timeout: SnapAX.Timeout.neighbour)
            else {
                SnapLog.event("link.write-miss", "windowID=\(windowID) reason=no-ax-element")
                return nil
            }
            element = resolved
        }
        guard let actual = SnapAX.setFrame(rect, on: element) else {
            SnapLog.event("link.write-miss",
                          "windowID=\(windowID) requested=\(SnapLog.rect(rect)) reason=read-back-failed")
            return nil
        }
        selfWrites[windowID] = (actual, ProcessInfo.processInfo.systemUptime)
        // A frame this store wrote is the member's new observed position, so
        // the next notification is measured from here, not from before it.
        observe(actual, for: windowID)
        framesCache.removeAll()
        SnapLog.event("link.write",
                      "windowID=\(windowID) requested=\(SnapLog.rect(rect)) actual=\(SnapLog.rect(actual))")
        return actual
    }

    private func isSelfWriteEcho(windowID: CGWindowID, liveFrame: CGRect) -> Bool {
        guard let marked = selfWrites[windowID],
              ProcessInfo.processInfo.systemUptime - marked.at < selfWriteExpiry
        else { return false }
        return abs(liveFrame.minX - marked.frame.minX) <= selfWriteTolerance
            && abs(liveFrame.minY - marked.frame.minY) <= selfWriteTolerance
            && abs(liveFrame.width - marked.frame.width) <= selfWriteTolerance
            && abs(liveFrame.height - marked.frame.height) <= selfWriteTolerance
    }

    // MARK: - Linked resize (spec §6) and drag-away restore (spec §1)

    /// Makes the watched set match every current member exactly. `enabled` is
    /// the linked-resize feature gate: off means watch nothing at all, so no
    /// Accessibility observer exists while the feature is off.
    func syncWatcher(enabled: Bool) {
        watcherEnabled = enabled
        let members = Set(groups.values.flatMap { $0.members.map(\.windowID) })
        lastLiveFrames = lastLiveFrames.filter { members.contains($0.key) }
        acceptedMinimums = acceptedMinimums.filter { members.contains($0.key) }
        watcher.watch(enabled ? members : [])
    }

    func suspend() {
        watcherEnabled = false
        watcher.stopAll()
        selfWrites.removeAll()
        lastLiveFrames.removeAll()
        acceptedMinimums.removeAll()
        framesCache.removeAll()
    }

    /// A watched member moved or was resized.
    private func geometryChanged(_ windowID: CGWindowID) {
        guard watcherEnabled, AppFeature.windowLayout.isAvailable, AXIsProcessTrusted() else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=feature-unavailable")
            return
        }
        guard let element = watcher.element(for: windowID), let pid = watcher.pid(for: windowID) else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=owning-app-gone")
            watcher.watch(watcher.watchedWindowIDs.subtracting([windowID]))
            return
        }
        guard !SnapAX.isMinimized(element) else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=minimized")
            return
        }
        // A read that times out is never "this member is gone": it skips this
        // one notification and the member stays watched.
        guard let newFrame = SnapAX.frame(of: element) else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=frame-read-timed-out")
            return
        }
        guard !isSelfWriteEcho(windowID: windowID, liveFrame: newFrame) else {
            SnapLog.event("link.echo", "windowID=\(windowID) frame=\(SnapLog.rect(newFrame))")
            return
        }
        guard let group = groups.values.first(where: { grp in grp.members.contains { $0.windowID == windowID } }),
              let member = group.members.first(where: { $0.windowID == windowID })
        else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=not-a-group-member")
            return
        }
        // Measured from where this member last actually was — never from its
        // zone, which a linked resize legitimately leaves behind. Falls back
        // to the zone only for a member that has not been observed since it
        // joined, where the two are the same thing anyway.
        let reference = lastLiveFrames[windowID]?.frame ?? member.frame
        let motion = SnapMemberMotion.classify(lastLiveFrame: reference, newFrame: newFrame)
        framesCache.removeAll()
        observe(newFrame, for: windowID)
        SnapLog.event("link.notify",
                      "windowID=\(windowID) app=\(SnapLinkedResizeWatcher.label(for: pid)) "
                          + "zone=\(SnapLog.rect(member.frame)) was=\(SnapLog.rect(reference)) "
                          + "live=\(SnapLog.rect(newFrame)) kind=\(motion)")

        switch motion {
        case .unchanged:
            return
        case .move:
            // Spec §1's last row. A plain move that carried the member off its
            // own zone is a title-bar drag-away: restore the pre-snap size
            // under the cursor and leave the group. A move never adjusts a
            // neighbour — that is what squeezed one to 140pt when a move was
            // misread as a resize.
            guard restoreOnDragEnabled,
                  SnapRestoreOnDragSupport.shouldRestore(member: member, newFrame: newFrame,
                                                         gap: WindowLayoutGaps.windowGap)
            else {
                SnapLog.event("link.no-adjust", "windowID=\(windowID) reason=plain-move")
                return
            }
            restoreOnDragAway(windowID: windowID, member: member, newFrame: newFrame)
            return
        case .resize:
            onLayoutReshaped?("a group member was resized by hand")
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayID == group.screenID }) else {
            SnapLog.event("link.skip", "windowID=\(windowID) reason=no-screen-for-group")
            return
        }
        let zones = theoreticalZones(for: group, on: screen)
        // Same reasoning as free space: a neighbour whose read missed is
        // better represented by where it last actually was than by being left
        // out of the computation entirely.
        var live = resolvedFrames(for: group, on: screen).frames
        live[windowID] = newFrame

        let adjustments = SnapLinkedResizeSupport.adjustments(
            resizedWindowID: windowID,
            oldFrame: reference,
            newFrame: newFrame,
            group: group,
            theoreticalZones: zones,
            gap: WindowLayoutGaps.windowGap,
            currentFrames: live,
            minimumSize: { self.acceptedMinimums[$0] ?? Self.minimumSizeGuess })
        guard !adjustments.isEmpty else {
            SnapLog.event("link.no-adjust", "windowID=\(windowID) reason=moved-edge-faces-open-screen")
            return
        }
        SnapLog.event("link.adjust", "windowID=\(windowID) count=\(adjustments.count)")
        apply(adjustments, resizedWindowID: windowID, oldFrame: reference, newFrame: newFrame,
              group: group, theoreticalZones: zones)
    }

    private var restoreOnDragEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.windowSnapRestoreSizeOnDrag)
    }

    private func restoreOnDragAway(windowID: CGWindowID, member: SnapGroupMember, newFrame: CGRect) {
        guard let restoreSize = member.restoreSize else { return }
        let restored = SnapRestoreOnDragSupport.restoredFrame(currentFrame: newFrame,
                                                              restoreSize: restoreSize,
                                                              cursor: NSEvent.mouseLocation)
        SnapLog.event("restore.drag-away",
                      "windowID=\(windowID) from=\(SnapLog.rect(newFrame)) to=\(SnapLog.rect(restored)) "
                          + "preSnapSize=\(SnapLog.size(restoreSize))")
        write(restored, to: windowID)
        remove(windowID, reason: "dragged away from its zone")
    }

    /// Writes every adjustment, then — only if a neighbour came back smaller
    /// than asked, i.e. it hit its own minimum size — runs one corrective pass
    /// that pulls the resized window's edge back so the two end up flush
    /// rather than overlapping (spec §6: "the divider stops at the minimum").
    ///
    /// Deliberately never updates a member's stored zone: a linked resize is
    /// not a placement. Writing the live result back was exactly the bug that
    /// made a resize drag work for one step and then stop.
    /// Writes every adjustment, then confirms — after a short settle — whether
    /// any neighbour's app actually refused the size it was given, and only
    /// then puts that neighbour back flush against its own screen edges and
    /// pulls the resized window's edge over to meet it (spec §6, "the divider
    /// stops at the minimum").
    ///
    /// The settle is not optional. Accessibility applies a frame change
    /// asynchronously, so the read-back taken immediately after the write
    /// returns the *pre-write* frame — which made every write against an app
    /// with no minimum at all look like a clamp, and re-anchored the neighbour
    /// straight back to where it started. Confirming on a re-read is what
    /// tells a real minimum from a value that had simply not landed yet.
    ///
    /// Deliberately never updates a member's stored zone: a linked resize is
    /// not a placement.
    private func apply(_ adjustments: [SnapLinkedResizeSupport.Adjustment],
                       resizedWindowID: CGWindowID,
                       oldFrame: CGRect,
                       newFrame: CGRect,
                       group: SnapGroup,
                       theoreticalZones: [CGWindowID: CGRect]) {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.linkedResizeBudget
        var requested: [CGWindowID: CGRect] = [:]
        for adjustment in adjustments {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                SnapLog.event("link.budget", "stopped early, remaining members retry on the next notification")
                break
            }
            write(adjustment.frame, to: adjustment.windowID)
            if adjustment.windowID != resizedWindowID { requested[adjustment.windowID] = adjustment.frame }
        }
        guard !requested.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clampSettleDelay) { [weak self] in
            self?.confirmClamps(requested: requested,
                                resizedWindowID: resizedWindowID,
                                oldFrame: oldFrame,
                                newFrame: newFrame,
                                group: group,
                                theoreticalZones: theoreticalZones)
        }
    }

    /// How long to wait before believing a read-back. Long enough for an
    /// ordinary Accessibility write to have landed, short enough to stay
    /// invisible inside a seam drag.
    private static let clampSettleDelay: TimeInterval = 0.05

    private func confirmClamps(requested: [CGWindowID: CGRect],
                               resizedWindowID: CGWindowID,
                               oldFrame: CGRect,
                               newFrame: CGRect,
                               group: SnapGroup,
                               theoreticalZones: [CGWindowID: CGRect]) {
        var clamped: [CGWindowID: CGSize] = [:]
        var live: [CGWindowID: CGRect] = [:]
        for (windowID, requestedFrame) in requested {
            guard let member = group.members.first(where: { $0.windowID == windowID }),
                  let element = watcher.element(for: windowID),
                  let settled = SnapAX.frame(of: element)
            else { continue }
            live[windowID] = settled
            observe(settled, for: windowID)
            guard SnapGroupSupport.isMinimumSizeClamp(requested: requestedFrame.size,
                                                      accepted: settled.size)
            else { continue }
            // Confirmed only now: an app's minimum is remembered so the next
            // step of the same drag clamps up front instead of rediscovering
            // it and rewriting the neighbour on every notification.
            clamped[windowID] = settled.size
            acceptedMinimums[windowID] = settled.size
            // Re-anchor: an app that refuses a size generally keeps the origin
            // it was given, which leaves the member hanging off the screen edge
            // its zone is anchored to. Only the anchored edges are moved; the
            // shared edge keeps the size the app accepted.
            let reanchored = SnapGroupSupport.reanchoredFrame(action: member.action,
                                                              zone: member.frame,
                                                              acceptedSize: settled.size)
            SnapLog.event("link.clamped",
                          "windowID=\(windowID) action=\(member.action) "
                              + "requested=\(SnapLog.rect(requestedFrame)) settled=\(SnapLog.rect(settled)) "
                              + "reanchored=\(SnapLog.rect(reanchored))")
            guard reanchored != settled else { continue }
            live[windowID] = write(reanchored, to: windowID) ?? reanchored
        }
        guard !clamped.isEmpty else { return }

        // Every clamped neighbour is back on its own edge, so the resized
        // window's own edge can be recomputed against real frames — which is
        // what leaves the seam a single line instead of a gap.
        live[resizedWindowID] = newFrame
        let corrected = SnapLinkedResizeSupport.adjustments(
            resizedWindowID: resizedWindowID,
            oldFrame: oldFrame,
            newFrame: newFrame,
            group: group,
            theoreticalZones: theoreticalZones,
            gap: WindowLayoutGaps.windowGap,
            currentFrames: live,
            minimumSize: { clamped[$0] ?? self.acceptedMinimums[$0] ?? Self.minimumSizeGuess })
        for adjustment in corrected where adjustment.windowID == resizedWindowID {
            SnapLog.event("link.pushback",
                          "windowID=\(resizedWindowID) to=\(SnapLog.rect(adjustment.frame)) "
                              + "reason=neighbour-at-its-minimum")
            write(adjustment.frame, to: resizedWindowID)
        }
    }

    private static func describe(_ group: SnapGroup) -> String {
        group.members.map { "\($0.windowID):\($0.action)" }.joined(separator: ",")
    }
}
