// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Pure geometry for spec §6 (linked resize of snapped neighbours) — the
/// "Precisazione" Marco added on 03/09: Windows needs no special divider
/// handle. Dragging the ordinary resize edge of any Snap Group member moves
/// the neighbour that shares that edge too, so the shared border stays a
/// single line instead of opening a gap or producing an overlap. No AppKit:
/// `WindowLayoutService` is the only caller that ever reads or writes an
/// actual window; everything here is exercised directly by
/// `build.sh --test`.
enum SnapLinkedResizeSupport {
    /// One window whose frame must change because of a linked resize: a
    /// neighbour following the moved edge, or — only when a neighbour could
    /// not follow all the way because of its own minimum size — the resized
    /// window itself, pulled back so the two frames end up flush instead of
    /// overlapping.
    struct Adjustment: Equatable {
        let windowID: CGWindowID
        let frame: CGRect
    }

    /// How far apart two readings of the same edge can be and still count
    /// as unchanged — guards against float noise between two Accessibility
    /// reads of a frame nobody actually moved.
    private static let edgeChangeTolerance: CGFloat = 0.5

    /// Which side of a zone a neighbouring zone shares a real border with.
    /// Named by the coordinate of the zone the neighbour sits against, not
    /// by screen direction, so the same four cases read the same regardless
    /// of which axis direction happens to be "up" in the caller's
    /// coordinate system.
    private enum TouchingEdge: Equatable {
        /// The neighbour sits against the zone's near edge on the X axis
        /// (`neighbourZone.maxX` ≈ `zone.minX`) — to the left of the zone.
        case minX
        /// The neighbour sits against the zone's far edge on the X axis
        /// (`neighbourZone.minX` ≈ `zone.maxX`) — to the right of the zone.
        case maxX
        /// The neighbour sits against the zone's near edge on the Y axis.
        case minY
        /// The neighbour sits against the zone's far edge on the Y axis.
        case maxY
    }

    /// Every edge of `zone` that `neighbourZone` shares a real border with —
    /// the same tolerance and shared-length rule
    /// `SnapGroupSupport.freeSpace` applies inline for its own touching
    /// test: the two zones must overlap along the perpendicular axis by
    /// more than a corner touch (`edgeOverlapMinimum`), and the candidate
    /// edges must sit within `edgeTolerance(gap:)` of each other (a gapped
    /// placement shaves half of `gap` off each side of a shared edge, so
    /// two genuinely adjacent zones sit up to a full `gap` apart, not
    /// flush).
    private static func touchingEdges(of zone: CGRect, neighbourZone: CGRect, gap: CGFloat) -> Set<TouchingEdge> {
        let edgeOverlapMinimum: CGFloat = 1
        let tolerance = max(2, gap + 2)
        var edges: Set<TouchingEdge> = []

        let verticalOverlap = min(zone.maxY, neighbourZone.maxY) - max(zone.minY, neighbourZone.minY)
        if verticalOverlap > edgeOverlapMinimum {
            if abs(neighbourZone.maxX - zone.minX) <= tolerance {
                edges.insert(.minX)
            } else if abs(neighbourZone.minX - zone.maxX) <= tolerance {
                edges.insert(.maxX)
            }
        }

        let horizontalOverlap = min(zone.maxX, neighbourZone.maxX) - max(zone.minX, neighbourZone.minX)
        if horizontalOverlap > edgeOverlapMinimum {
            if abs(neighbourZone.maxY - zone.minY) <= tolerance {
                edges.insert(.minY)
            } else if abs(neighbourZone.minY - zone.maxY) <= tolerance {
                edges.insert(.maxY)
            }
        }
        return edges
    }

    /// `resizedWindowID`, a member of `group`, moved from `oldFrame` to
    /// `newFrame` (an Accessibility resize or move notification just
    /// reported this). Returns every other member's new frame that keeps a
    /// shared edge flush, plus — only if a neighbour's minimum size stops
    /// it short — a corrected frame for `resizedWindowID` itself so the two
    /// frames end up flush rather than overlapping.
    ///
    /// Empty when nothing needs to change: `oldFrame == newFrame`, the
    /// frame only moved (`size` unchanged — spec §6 links a resize, never a
    /// plain drag, and the existing overlap-based prune already handles a
    /// window dragged out of the group), or the edge that did move touches
    /// no neighbour.
    ///
    /// `group` supplies every member's *zone* (`SnapGroupMember.frame`),
    /// used only to decide adjacency — by the same tolerance and shared-edge
    /// rule `SnapGroupSupport.freeSpace` applies inline for its own touching
    /// test (kept as a private copy here, `touchingEdges` below, rather than
    /// a shared call, since `SnapGroupSupport` evolves independently and a
    /// shared helper would only ever be a source of rebase conflicts between
    /// the two — the two tests are meant to keep agreeing by staying
    /// identical in behavior, not by sharing code) — never to size
    /// anything, so the two features can never disagree about which windows
    /// are neighbours. `currentFrames` supplies every member's
    /// *live* frame, which is what actually gets resized; the resized
    /// window's own live frame is `newFrame`, not whatever `currentFrames`
    /// might also hold for it. A member missing from `currentFrames`
    /// (closed, minimized, or Accessibility just could not read it this
    /// tick) is skipped rather than guessed at. `minimumSize` is asked once
    /// per neighbour for the smallest size that neighbour will accept —
    /// Accessibility has no way to query a window's minimum size up front,
    /// so callers typically pass a conservative guess on the first pass and
    /// the size Accessibility actually accepted on a corrective second pass.
    static func adjustments(resizedWindowID: CGWindowID,
                            oldFrame: CGRect,
                            newFrame: CGRect,
                            group: SnapGroup,
                            gap: CGFloat,
                            currentFrames: [CGWindowID: CGRect],
                            minimumSize: (CGWindowID) -> CGSize) -> [Adjustment] {
        guard oldFrame != newFrame,
              oldFrame.size != newFrame.size,
              let resizedZone = group.members.first(where: { $0.windowID == resizedWindowID })?.frame
        else { return [] }

        var result: [Adjustment] = []
        var resizedFrame = newFrame

        // At most one of the two horizontal edges moves in a single drag
        // (dragging a corner moves one X edge and one Y edge, never both X
        // edges at once), so `minX` is checked first and `maxX` only when
        // `minX` did not move.
        if abs(newFrame.minX - oldFrame.minX) > edgeChangeTolerance {
            resizedFrame = applyAxisAdjustments(edge: .minX,
                                                resizedWindowID: resizedWindowID,
                                                resizedZone: resizedZone,
                                                resizedFrame: resizedFrame,
                                                group: group,
                                                gap: gap,
                                                currentFrames: currentFrames,
                                                minimumSize: minimumSize,
                                                result: &result)
        } else if abs(newFrame.maxX - oldFrame.maxX) > edgeChangeTolerance {
            resizedFrame = applyAxisAdjustments(edge: .maxX,
                                                resizedWindowID: resizedWindowID,
                                                resizedZone: resizedZone,
                                                resizedFrame: resizedFrame,
                                                group: group,
                                                gap: gap,
                                                currentFrames: currentFrames,
                                                minimumSize: minimumSize,
                                                result: &result)
        }

        if abs(newFrame.minY - oldFrame.minY) > edgeChangeTolerance {
            resizedFrame = applyAxisAdjustments(edge: .minY,
                                                resizedWindowID: resizedWindowID,
                                                resizedZone: resizedZone,
                                                resizedFrame: resizedFrame,
                                                group: group,
                                                gap: gap,
                                                currentFrames: currentFrames,
                                                minimumSize: minimumSize,
                                                result: &result)
        } else if abs(newFrame.maxY - oldFrame.maxY) > edgeChangeTolerance {
            resizedFrame = applyAxisAdjustments(edge: .maxY,
                                                resizedWindowID: resizedWindowID,
                                                resizedZone: resizedZone,
                                                resizedFrame: resizedFrame,
                                                group: group,
                                                gap: gap,
                                                currentFrames: currentFrames,
                                                minimumSize: minimumSize,
                                                result: &result)
        }

        // Nothing actually touched a neighbour: the moved edge(s) faced open
        // screen, not another member of the group.
        guard !result.isEmpty else { return [] }
        if resizedFrame != newFrame {
            result.append(Adjustment(windowID: resizedWindowID, frame: resizedFrame))
        }
        return result
    }

    /// Finds every neighbour that shares `edge` with `resizedZone`, follows
    /// each one's matching edge to `resizedFrame`'s current position on
    /// that edge — clamped so neither that neighbour nor the resized window
    /// itself goes below its own minimum size — appends an `Adjustment` for
    /// every neighbour whose frame actually changes, and returns
    /// `resizedFrame`, itself pulled back on `edge` when a neighbour's
    /// minimum stopped the shared edge short of where it was headed.
    private static func applyAxisAdjustments(edge: TouchingEdge,
                                              resizedWindowID: CGWindowID,
                                              resizedZone: CGRect,
                                              resizedFrame: CGRect,
                                              group: SnapGroup,
                                              gap: CGFloat,
                                              currentFrames: [CGWindowID: CGRect],
                                              minimumSize: (CGWindowID) -> CGSize,
                                              result: inout [Adjustment]) -> CGRect {
        let neighbours = group.members
            .filter { $0.windowID != resizedWindowID }
            .filter { touchingEdges(of: resizedZone, neighbourZone: $0.frame, gap: gap).contains(edge) }
        guard !neighbours.isEmpty else { return resizedFrame }

        var clamped: CGFloat = coordinate(of: resizedFrame, edge: edge)
        var neighbourFrames: [(windowID: CGWindowID, current: CGRect)] = []

        for member in neighbours {
            guard let current = currentFrames[member.windowID] else { continue }
            neighbourFrames.append((member.windowID, current))
            let minSize = minimumSize(member.windowID)
            switch edge {
            case .minX:
                // The neighbour sits to the left: its right edge follows
                // `clamped - gap`, bounded by its own fixed left edge plus
                // its minimum width.
                clamped = max(clamped, current.minX + minSize.width + gap)
            case .maxX:
                clamped = min(clamped, current.maxX - minSize.width - gap)
            case .minY:
                clamped = max(clamped, current.minY + minSize.height + gap)
            case .maxY:
                clamped = min(clamped, current.maxY - minSize.height - gap)
            }
        }
        guard !neighbourFrames.isEmpty else { return resizedFrame }

        // The resized window must not be pushed below its own minimum size
        // either, on the rare chance a neighbour's minimum would otherwise
        // demand that.
        let ownMinSize = minimumSize(resizedWindowID)
        switch edge {
        case .minX: clamped = min(clamped, resizedFrame.maxX - ownMinSize.width)
        case .maxX: clamped = max(clamped, resizedFrame.minX + ownMinSize.width)
        case .minY: clamped = min(clamped, resizedFrame.maxY - ownMinSize.height)
        case .maxY: clamped = max(clamped, resizedFrame.minY + ownMinSize.height)
        }

        for (windowID, current) in neighbourFrames {
            let followed = followingFrame(current: current, edge: edge, clamped: clamped, gap: gap)
            if followed != current {
                result.append(Adjustment(windowID: windowID, frame: followed))
            }
        }

        return adjustedFrame(resizedFrame, edge: edge, clamped: clamped)
    }

    private static func coordinate(of frame: CGRect, edge: TouchingEdge) -> CGFloat {
        switch edge {
        case .minX: return frame.minX
        case .maxX: return frame.maxX
        case .minY: return frame.minY
        case .maxY: return frame.maxY
        }
    }

    /// `resizedFrame` with its `edge` coordinate replaced by `clamped`,
    /// keeping the opposite edge on that axis fixed.
    private static func adjustedFrame(_ resizedFrame: CGRect,
                                      edge: TouchingEdge,
                                      clamped: CGFloat) -> CGRect {
        var frame = resizedFrame
        switch edge {
        case .minX:
            frame.size.width = resizedFrame.maxX - clamped
            frame.origin.x = clamped
        case .maxX:
            frame.size.width = clamped - resizedFrame.minX
        case .minY:
            frame.size.height = resizedFrame.maxY - clamped
            frame.origin.y = clamped
        case .maxY:
            frame.size.height = clamped - resizedFrame.minY
        }
        return frame
    }

    /// A neighbour's `current` frame with its edge touching `edge` moved to
    /// stay flush with `clamped` (the resized window's — possibly
    /// itself-clamped — matching edge), keeping the neighbour's own far
    /// edge fixed.
    private static func followingFrame(current: CGRect,
                                       edge: TouchingEdge,
                                       clamped: CGFloat,
                                       gap: CGFloat) -> CGRect {
        var frame = current
        switch edge {
        case .minX:
            // Neighbour is to the left; its right edge follows.
            frame.size.width = max(0, (clamped - gap) - current.minX)
        case .maxX:
            // Neighbour is to the right; its left edge follows.
            let newMinX = clamped + gap
            frame.size.width = max(0, current.maxX - newMinX)
            frame.origin.x = newMinX
        case .minY:
            frame.size.height = max(0, (clamped - gap) - current.minY)
        case .maxY:
            let newMinY = clamped + gap
            frame.size.height = max(0, current.maxY - newMinY)
            frame.origin.y = newMinY
        }
        return frame
    }
}
