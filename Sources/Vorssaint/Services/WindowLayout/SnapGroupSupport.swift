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

    /// How far two zone edges can differ and still count as touching.
    /// `WindowLayoutGeometry.rect` already shaves half of `gap` off every
    /// edge a placement shares with a neighbour (`windowGapped`), so two
    /// genuinely adjacent zones sit up to a full `gap` apart, not flush —
    /// the tolerance has to cover that, plus a couple of points for
    /// independent `.integral` rounding on each side.
    private static func edgeTolerance(gap: CGFloat) -> CGFloat {
        max(2, gap + 2)
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

    /// Whether a member is still parked where it was placed, closely enough
    /// to keep counting as occupying that zone. A user who drags a snapped
    /// window away — rather than merely resizing it along its snapped edge —
    /// has opted back out, and free space computed for a neighbour must stop
    /// treating that window as blocking anything.
    static func stillOverlapsZone(memberZone: CGRect, currentFrame: CGRect) -> Bool {
        guard currentFrame.width > 0, currentFrame.height > 0 else { return false }
        let intersection = memberZone.intersection(currentFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let overlapArea = intersection.width * intersection.height
        let currentArea = currentFrame.width * currentFrame.height
        return overlapArea / currentArea >= 0.5
    }

    /// The group with every member dropped that Accessibility could no
    /// longer locate a live frame for (`currentFrames` has no entry — the
    /// window closed, or is minimized and so was skipped while reading
    /// frames) or that has drifted off its own zone (`stillOverlapsZone`
    /// fails — the user dragged it away). Called before every free-space
    /// computation and every membership update, so a stale member is never
    /// more than one placement or one drag sample away from being forgotten.
    static func pruned(group: SnapGroup, currentFrames: [CGWindowID: CGRect]) -> SnapGroup {
        var result = group
        result.members = group.members.filter { member in
            guard let current = currentFrames[member.windowID] else { return false }
            return stillOverlapsZone(memberZone: member.frame, currentFrame: current)
        }
        return result
    }

    /// The group after one more placement: `windowID` is removed from its
    /// old slot (if any) first, every other member is pruned by the same
    /// rules `pruned(group:currentFrames:)` applies, and `windowID` rejoins
    /// with its new zone only when `action` is one that joins a group at
    /// all — maximizing, restoring, going full screen, centering or crossing
    /// to another display all simply drop the window instead.
    static func updated(group: SnapGroup,
                        windowID: CGWindowID,
                        action: WindowLayoutAction,
                        appliedFrame: CGRect,
                        currentFrames: [CGWindowID: CGRect]) -> SnapGroup {
        var result = pruned(group: group, currentFrames: currentFrames)
        result.members.removeAll { $0.windowID == windowID }
        if joinsGroup(action) {
            result.members.append(SnapGroupMember(windowID: windowID, action: action, frame: appliedFrame))
        }
        return result
    }

    /// The zone actually available for `action`: `theoreticalZone` shrunk by
    /// the *current* frame — not the frame that was originally applied — of
    /// every group member whose own zone neighbours it horizontally or
    /// vertically. A member whose zone sits to the left or right shrinks the
    /// requested zone's near horizontal edge; one above or below shrinks its
    /// near vertical edge; a corner zone can be shrunk on both axes at once
    /// by two different neighbours. A member whose zone does not touch
    /// `theoreticalZone` at all is ignored, and one that has drifted off its
    /// own zone (`stillOverlapsZone`) is dropped before any of this runs.
    ///
    /// Falls back to `theoreticalZone` unchanged whenever `action` does not
    /// join a group, the group (after pruning) is empty, or the shrunk
    /// result would leave less than `minimumSpace` on either axis — a sliver
    /// nobody could usefully drop a window into (spec §9).
    static func freeSpace(for action: WindowLayoutAction,
                          theoreticalZone: CGRect,
                          group: SnapGroup,
                          gap: CGFloat,
                          currentFrames: [CGWindowID: CGRect]) -> CGRect {
        guard joinsGroup(action) else { return theoreticalZone }
        let members = pruned(group: group, currentFrames: currentFrames).members
        guard !members.isEmpty else { return theoreticalZone }

        var minX = theoreticalZone.minX
        var maxX = theoreticalZone.maxX
        var minY = theoreticalZone.minY
        var maxY = theoreticalZone.maxY
        let tolerance = edgeTolerance(gap: gap)

        for member in members {
            guard let current = currentFrames[member.windowID] else { continue }
            let zone = member.frame

            // A horizontal neighbour (left/right of the requested zone)
            // shares its full vertical extent; two zones that only meet at a
            // corner have essentially no shared Y range and are skipped.
            let verticalOverlap = min(zone.maxY, theoreticalZone.maxY) - max(zone.minY, theoreticalZone.minY)
            if verticalOverlap > edgeOverlapMinimum {
                if abs(zone.maxX - theoreticalZone.minX) <= tolerance {
                    minX = max(minX, current.maxX + gap)
                } else if abs(zone.minX - theoreticalZone.maxX) <= tolerance {
                    maxX = min(maxX, current.minX - gap)
                }
            }

            // A vertical neighbour (above/below) shares its full horizontal
            // extent by the same reasoning.
            let horizontalOverlap = min(zone.maxX, theoreticalZone.maxX) - max(zone.minX, theoreticalZone.minX)
            if horizontalOverlap > edgeOverlapMinimum {
                if abs(zone.maxY - theoreticalZone.minY) <= tolerance {
                    minY = max(minY, current.maxY + gap)
                } else if abs(zone.minY - theoreticalZone.maxY) <= tolerance {
                    maxY = min(maxY, current.minY - gap)
                }
            }
        }

        let result = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        guard result.width >= minimumSpace, result.height >= minimumSpace else { return theoreticalZone }
        return result
    }
}
