// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// One window that belongs to a `SnapGroup`: which zone it was placed into,
/// and the frame that placement actually wrote. `frame` is deliberately the
/// frame *at the moment it joined the group*, not a live reading — it is the
/// fixed reference used to decide whether another zone is this member's
/// neighbour. The window's live frame, which may since have been resized by
/// hand, is looked up separately (`currentFrames`) whenever free space is
/// computed, which is the whole point of Phase 2 (spec §5).
struct SnapGroupMember: Equatable {
    let windowID: CGWindowID
    var action: WindowLayoutAction
    var frame: CGRect
    /// The window's size the moment before it first joined this group (spec
    /// §1's last row: dragging a snapped member away by its title bar
    /// restores this). Carried forward unchanged across every re-snap to a
    /// new zone while the window stays in the group — see `updated(...)` —
    /// so a window snapped left, then re-snapped to a corner, still
    /// restores to the size it had before the *first* of those snaps, not
    /// the corner's own size. `nil` only for a member built by hand (tests)
    /// without one; every member `WindowLayoutService` actually creates has
    /// one, since `updateSnapGroup` always supplies the pre-placement frame.
    var restoreSize: CGSize? = nil
    /// Spec §7: a minimized member is never dropped from its group — it is
    /// marked instead, so it can be put back in its own zone once
    /// un-minimized (which, on macOS, restores the exact frame it had
    /// before minimizing on its own — see `pruned(...)`'s own doc comment).
    var isMinimized: Bool = false
}

/// The windows currently snapped together on one screen. Vorssaint keeps one
/// group per screen, in memory only, for the life of the app session — there
/// is no persistence across a relaunch, matching how Windows itself forgets
/// Snap Groups once the session ends.
struct SnapGroup: Equatable {
    var screenID: CGDirectDisplayID
    var members: [SnapGroupMember] = []
}

/// Pure geometry and membership rules for Snap Groups (spec §5, §9). No
/// AppKit: reading a window's live frame is `WindowLayoutService`'s job, done
/// through Accessibility right before calling in here, so every decision
/// below is exercised directly by `build.sh --test`.
enum SnapGroupSupport {
    /// Below this size per axis the "real free space" left by a resized
    /// neighbour is no longer worth snapping into — a sliver a few pixels
    /// wide helps nobody. The theoretical (unshrunk) zone is used instead,
    /// same bailout spec §9 describes for an oversized minimum window size.
    static let minimumSpace: CGFloat = 200

    /// How far two *zone* edges — never a current frame, see the note on
    /// `freeSpace` below — can differ and still count as touching.
    /// `WindowLayoutGeometry.rect` already shaves half of `gap` off every
    /// edge a placement shares with a neighbour (`windowGapped`), so two
    /// genuinely adjacent zones sit up to a full `gap` apart, not flush —
    /// the tolerance has to cover that, plus a few points for independent
    /// `.integral` rounding on each side and for the visible frame itself
    /// legitimately reading a point or two different between when a
    /// neighbour's zone was recorded and when this zone is being requested
    /// (a transient Dock reveal, for instance). Matches `stillAnchored`'s
    /// own tolerance below so the two never disagree about what counts as
    /// "the same edge."
    private static func edgeTolerance(gap: CGFloat) -> CGFloat {
        max(3, gap + 3)
    }

    /// The shortest edge overlap that counts as two zones sharing a real
    /// border rather than only touching at a single corner point — without
    /// this, diagonal neighbours (e.g. top-left and bottom-right of a
    /// quarters layout) would wrongly be treated as touching.
    private static let edgeOverlapMinimum: CGFloat = 1

    /// Whether placing a window with `action` makes it a Snap Group member.
    /// A partial on-screen zone joins (halves, thirds, sixths, corners); an
    /// action that claims the whole screen, recenters, restores a previous
    /// size, or moves the window to another display does not — there is no
    /// remaining neighbour relationship to track once the window no longer
    /// occupies a sub-rectangle of this screen.
    static func joinsGroup(_ action: WindowLayoutAction) -> Bool {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
                .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                .topLeftSixth, .topCenterSixth, .topRightSixth,
                .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                .topLeft, .topRight, .bottomLeft, .bottomRight:
            return true
        case .maximize, .marginMaximize, .fullScreen, .center,
                .previousDisplay, .nextDisplay, .restore:
            return false
        }
    }

    /// The sides of a zone a placement actually anchored to the screen
    /// itself, as opposed to the "free" side (or sides, for a center third)
    /// left facing a neighbour or the screen's own interior. A half is
    /// anchored on three sides (the two screen edges it spans plus the
    /// screen edge it is flush against); a corner or corner sixth on two
    /// (the two screen edges it touches); a center third only top and
    /// bottom, since neither of its vertical sides ever touches a screen
    /// edge. Never consulted for an action `joinsGroup` already excludes.
    private enum ScreenEdge {
        case minX, maxX, minY, maxY
    }

    private static func anchoredEdges(for action: WindowLayoutAction) -> Set<ScreenEdge> {
        switch action {
        case .leftHalf, .leftThird, .leftTwoThirds:
            return [.minX, .minY, .maxY]
        case .rightHalf, .rightThird, .rightTwoThirds:
            return [.maxX, .minY, .maxY]
        case .centerThird:
            return [.minY, .maxY]
        case .topHalf:
            return [.minX, .maxX, .maxY]
        case .bottomHalf:
            return [.minX, .maxX, .minY]
        case .topLeft, .topLeftSixth:
            return [.minX, .maxY]
        case .topRight, .topRightSixth:
            return [.maxX, .maxY]
        case .bottomLeft, .bottomLeftSixth:
            return [.minX, .minY]
        case .bottomRight, .bottomRightSixth:
            return [.maxX, .minY]
        case .topCenterSixth:
            return [.maxY]
        case .bottomCenterSixth:
            return [.minY]
        case .maximize, .marginMaximize, .fullScreen, .center,
                .previousDisplay, .nextDisplay, .restore:
            return []
        }
    }

    /// How far an anchored edge can drift and still count as flush: a few
    /// points absorb independent `.integral` rounding on the zone and the
    /// live read, and `gap` on top of that absorbs Window Layout's own
    /// configured window/screen gap, so a resize that keeps a member snug
    /// against its configured gap is never mistaken for a move just because
    /// the exact pixel position differs by that much.
    private static func anchorTolerance(gap: CGFloat) -> CGFloat {
        3 + max(0, gap)
    }

    /// Whether a member is still anchored where it was placed — the rule
    /// Windows itself uses for keeping a Snap Group member: resizing it
    /// along the edge or edges it shares with the screen never un-snaps it
    /// (tracking exactly that resize is this feature's whole purpose), but
    /// moving the window — a title-bar drag, even one that leaves most of
    /// the window still over its old zone — does. Checked edge by edge
    /// rather than by overlap area: an overlap test kept a *moved* window
    /// in the group as long as enough of it still covered its old zone
    /// (wrong — a drag has to un-snap it), and evicted a *resized* window
    /// that grew enough to shrink its own overlap fraction (wrong — growing
    /// along the snapped edge is the one thing this feature exists to let
    /// happen). A drift on any one anchored edge is enough to leave: it
    /// takes only one edge parting from the screen boundary the zone was
    /// defined against to mean the window is no longer snapped there.
    static func stillAnchored(member: SnapGroupMember, currentFrame: CGRect, gap: CGFloat = 0) -> Bool {
        guard currentFrame.width > 0, currentFrame.height > 0 else { return false }
        let edges = anchoredEdges(for: member.action)
        guard !edges.isEmpty else { return false }
        let zone = member.frame
        let tolerance = anchorTolerance(gap: gap)
        return edges.allSatisfy { edge in
            let drift: CGFloat
            switch edge {
            case .minX: drift = abs(currentFrame.minX - zone.minX)
            case .maxX: drift = abs(currentFrame.maxX - zone.maxX)
            case .minY: drift = abs(currentFrame.minY - zone.minY)
            case .maxY: drift = abs(currentFrame.maxY - zone.maxY)
            }
            return drift <= tolerance
        }
    }

    /// The group with every member dropped that is *confirmed* gone —
    /// `WindowLayoutService` puts a windowID in `gone` only when the window
    /// no longer appears in `CGWindowList` at all — or that has drifted off
    /// its own zone (`stillAnchored` fails — the user moved it, or, spec
    /// §7's carve-out, `SnapRestoreOnDragSupport` already handled it as a
    /// drag-away). A member in `minimized` is never dropped either way: it
    /// is marked `isMinimized` instead and kept exactly where it is, since
    /// minimizing never actually moves a window's frame — un-minimizing it
    /// (macOS restoring that same frame on its own) reads back
    /// `stillAnchored` again on the very next round and simply clears the
    /// mark, with no extra re-placement needed for the common case; spec
    /// §8's screen-change handling covers the rest (a display gone or
    /// resized while a member was minimized).
    ///
    /// A member simply missing from `currentFrames` without being in either
    /// `gone` or `minimized` is *kept*, mark unchanged: an Accessibility
    /// read that timed out or came back empty this one round is not proof
    /// of anything — real apps (Chrome, Finder, an Electron app) routinely
    /// answer slower than an in-process Cocoa window does, especially while
    /// occupied doing something else, and evicting on the first slow read
    /// was the bug behind a member vanishing moments after joining. A
    /// kept-but-frame-missing member simply contributes nothing to
    /// `freeSpace` this round; it tries again next time this group is
    /// consulted. Called before every free-space computation and every
    /// membership update, so a truly stale member is never more than one
    /// placement or one drag sample away from being forgotten.
    static func pruned(group: SnapGroup,
                       currentFrames: [CGWindowID: CGRect],
                       gone: Set<CGWindowID> = [],
                       minimized: Set<CGWindowID> = [],
                       gap: CGFloat = 0) -> SnapGroup {
        var result = group
        result.members = group.members.compactMap { member -> SnapGroupMember? in
            guard !gone.contains(member.windowID) else { return nil }
            if minimized.contains(member.windowID) {
                var minimizedMember = member
                minimizedMember.isMinimized = true
                return minimizedMember
            }
            guard let current = currentFrames[member.windowID] else { return member }
            guard stillAnchored(member: member, currentFrame: current, gap: gap) else { return nil }
            var visibleMember = member
            visibleMember.isMinimized = false
            return visibleMember
        }
        return result
    }

    /// The group after one more placement: `windowID` is removed from its
    /// old slot (if any) first, every other member is pruned by the same
    /// rules `pruned(group:currentFrames:gone:minimized:gap:)` applies, and
    /// `windowID` rejoins with its new zone only when `action` is one that
    /// joins a group at all — maximizing, restoring, going full screen,
    /// centering or crossing to another display all simply drop the window
    /// instead.
    /// `preSnapSize` is the window's own size the instant before *this*
    /// placement — `WindowLayoutService` always has it (the AX frame it
    /// read right before calling `setFrame`) and always passes it. Ignored
    /// unless `windowID` is newly joining the group with no `restoreSize`
    /// of its own yet: a member already in the group keeps the
    /// `restoreSize` it joined with across every further re-snap, per
    /// `SnapGroupMember.restoreSize`'s own doc comment.
    static func updated(group: SnapGroup,
                        windowID: CGWindowID,
                        action: WindowLayoutAction,
                        appliedFrame: CGRect,
                        preSnapSize: CGSize,
                        currentFrames: [CGWindowID: CGRect],
                        gone: Set<CGWindowID> = [],
                        minimized: Set<CGWindowID> = [],
                        gap: CGFloat = 0) -> SnapGroup {
        let existingRestoreSize = group.members.first { $0.windowID == windowID }?.restoreSize
        var result = pruned(group: group, currentFrames: currentFrames, gone: gone, minimized: minimized, gap: gap)
        result.members.removeAll { $0.windowID == windowID }
        if joinsGroup(action) {
            let restoreSize = existingRestoreSize ?? preSnapSize
            result.members.append(SnapGroupMember(windowID: windowID, action: action,
                                                  frame: appliedFrame, restoreSize: restoreSize))
        }
        return result
    }

    /// The zone actually available for `action`: each edge `theoreticalZone`
    /// shares with a group member's zone is replaced outright by that
    /// member's *current* frame — not the frame that was originally applied,
    /// and not merely shrunk toward it — so a neighbour that grew shrinks
    /// the requested zone, and one that *shrunk* lets it extend into the
    /// space that opened up, exactly to the neighbour's real edge either
    /// way (spec §5: free space is not one-directional). A member whose
    /// zone sits to the left or right replaces the requested zone's near
    /// horizontal edge; one above or below replaces its near vertical edge;
    /// a corner zone can have both axes replaced at once by two different
    /// neighbours. Two neighbours sharing the same side (e.g. two sixths
    /// stacked against the same third) each propose an edge and the more
    /// restrictive of the two wins, so the result never overlaps either
    /// one. A member whose zone does not touch `theoreticalZone` at all is
    /// ignored — that edge keeps its theoretical position — and one that
    /// has drifted off its own zone (`stillAnchored`) is dropped before any
    /// of this runs.
    ///
    /// Falls back to `theoreticalZone` unchanged whenever `action` does not
    /// join a group, the group (after pruning) is empty, or the result
    /// would leave less than `minimumSpace` on either axis — a sliver
    /// nobody could usefully drop a window into (spec §9). That same
    /// fallback is what keeps a replaced edge honest without needing the
    /// screen's own visible frame here: an edge proposed by a neighbour
    /// that has moved off-screen or inverted the rectangle collapses the
    /// result below the minimum and is discarded wholesale.
    ///
    /// **Two different rectangles per neighbour, on purpose, never
    /// conflated:** `neighbourZone` (`member.frame`) — fixed at the moment
    /// the neighbour joined the group — decides *whether* it neighbours
    /// `theoreticalZone` at all, by comparing zone edges to zone edges.
    /// `currentFrame` (`currentFrames[member.windowID]`) supplies *where*
    /// the shared edge actually is right now, once that neighbour
    /// relationship is established. Deciding adjacency from `currentFrame`
    /// instead would be wrong in exactly the case this function exists for:
    /// the moment a neighbour resizes, its current edge moves away from
    /// `theoreticalZone` by design, so a current-frame-based adjacency test
    /// would call it "no longer touching" and silently stop adjusting —
    /// worse the more the neighbour has resized, i.e. worst exactly when
    /// this feature matters most.
    static func freeSpace(for action: WindowLayoutAction,
                          theoreticalZone: CGRect,
                          group: SnapGroup,
                          gap: CGFloat,
                          currentFrames: [CGWindowID: CGRect]) -> CGRect {
        guard joinsGroup(action) else { return theoreticalZone }
        let members = pruned(group: group, currentFrames: currentFrames, gap: gap).members
        guard !members.isEmpty else { return theoreticalZone }

        let tolerance = edgeTolerance(gap: gap)
        // Every neighbour that touches a given side proposes a value for
        // that side's edge; an empty list means no neighbour touches it, so
        // that edge keeps its theoretical position untouched.
        var minXCandidates: [CGFloat] = []
        var maxXCandidates: [CGFloat] = []
        var minYCandidates: [CGFloat] = []
        var maxYCandidates: [CGFloat] = []

        for member in members {
            guard let currentFrame = currentFrames[member.windowID] else { continue }
            let neighbourZone = member.frame

            // A horizontal neighbour (left/right of the requested zone)
            // shares its full vertical extent; two zones that only meet at a
            // corner have essentially no shared Y range and are skipped.
            // Every comparison against `theoreticalZone` here reads from
            // `neighbourZone`, never `currentFrame` — see the doc comment
            // above for why that distinction is load-bearing.
            let verticalOverlap = min(neighbourZone.maxY, theoreticalZone.maxY)
                - max(neighbourZone.minY, theoreticalZone.minY)
            if verticalOverlap > edgeOverlapMinimum {
                if abs(neighbourZone.maxX - theoreticalZone.minX) <= tolerance {
                    minXCandidates.append(currentFrame.maxX + gap)
                } else if abs(neighbourZone.minX - theoreticalZone.maxX) <= tolerance {
                    maxXCandidates.append(currentFrame.minX - gap)
                }
            }

            // A vertical neighbour (above/below) shares its full horizontal
            // extent by the same reasoning.
            let horizontalOverlap = min(neighbourZone.maxX, theoreticalZone.maxX)
                - max(neighbourZone.minX, theoreticalZone.minX)
            if horizontalOverlap > edgeOverlapMinimum {
                if abs(neighbourZone.maxY - theoreticalZone.minY) <= tolerance {
                    minYCandidates.append(currentFrame.maxY + gap)
                } else if abs(neighbourZone.minY - theoreticalZone.maxY) <= tolerance {
                    maxYCandidates.append(currentFrame.minY - gap)
                }
            }
        }

        // Combining multiple same-side neighbours by the most restrictive
        // candidate (max for a near edge, min for a far edge) is what keeps
        // the result clear of every one of them, not just the last one
        // considered.
        let minX = minXCandidates.max() ?? theoreticalZone.minX
        let maxX = maxXCandidates.min() ?? theoreticalZone.maxX
        let minY = minYCandidates.max() ?? theoreticalZone.minY
        let maxY = maxYCandidates.min() ?? theoreticalZone.maxY

        let result = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        guard result.width >= minimumSpace, result.height >= minimumSpace else { return theoreticalZone }
        return result
    }

    /// Where a member has to sit when its app refuses to shrink to the size a
    /// linked resize asked for (spec §6, "the divider stops at the minimum").
    ///
    /// Accessibility cannot be asked a window's minimum size, so the only way
    /// to find it is to write a smaller frame and read back what was accepted
    /// — and an app that clamps the *size* generally keeps the *origin* it was
    /// given, which leaves the member wider than requested and sticking out
    /// past the screen edge its zone was anchored to. On screen that reads as
    /// a snapped window drifting away from the edge toward the centre partway
    /// through a seam drag, which is what a real capture found.
    ///
    /// The answer is not to guess: a member's anchored edges are a fixed
    /// property of the zone it was placed into (`anchoredEdges`), so the
    /// accepted size is simply put back flush against them. A right-anchored
    /// member keeps its right edge on the screen edge and grows leftward; a
    /// left-anchored one keeps its left edge and grows rightward. An axis the
    /// zone anchors on neither side (a center third's horizontal axis) keeps
    /// the zone's own near edge, since there is no screen edge to be flush
    /// with.
    static func reanchoredFrame(action: WindowLayoutAction,
                                zone: CGRect,
                                acceptedSize: CGSize) -> CGRect {
        let edges = anchoredEdges(for: action)
        let x: CGFloat
        if edges.contains(.minX) {
            x = zone.minX
        } else if edges.contains(.maxX) {
            x = zone.maxX - acceptedSize.width
        } else {
            x = zone.minX
        }
        let y: CGFloat
        if edges.contains(.minY) {
            y = zone.minY
        } else if edges.contains(.maxY) {
            y = zone.maxY - acceptedSize.height
        } else {
            y = zone.minY
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: acceptedSize)
    }

    /// Spec §8: a resolution change or a display reconnecting recalculates
    /// every member's zone "in proportion" and re-places the group. Every
    /// `WindowLayoutAction` a member can join a group with is already
    /// resolution-independent — a fraction of the screen's visible frame,
    /// computed by `WindowLayoutGeometry.rect` — so "in proportion" falls
    /// out for free by simply re-deriving each member's rect from its own
    /// unchanged `action` against `newVisibleFrame`; nothing here needs its
    /// own pixel-proportional math. Returns each member's new theoretical
    /// rect in the group's own member order; the caller writes it to the
    /// real window and, on success, updates that member's stored `frame` to
    /// match — this function only computes, it never touches a live
    /// member or a window.
    static func relocatedZones(for group: SnapGroup,
                               newVisibleFrame: CGRect,
                               windowGap: CGFloat,
                               screenGap: CGFloat = 0) -> [(windowID: CGWindowID, frame: CGRect)] {
        group.members.map { member in
            let rect = WindowLayoutGeometry.rect(for: member.action,
                                                 current: newVisibleFrame,
                                                 visibleFrame: newVisibleFrame,
                                                 windowGap: windowGap,
                                                 screenGap: screenGap)
            return (member.windowID, rect.integral)
        }
    }
}
