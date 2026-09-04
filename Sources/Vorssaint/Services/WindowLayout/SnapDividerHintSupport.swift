// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Pure geometry for spec §6/§12's visual divider: the thin bar Windows
/// shows when the pointer rests on the seam between two snapped windows,
/// hinting that dragging from there resizes both (Phase 5's linked resize
/// already does the actual work; this only ever decides where to draw the
/// hint). No AppKit: `WindowLayoutService` is the only caller, from the
/// same live frames `SnapLinkedResizeSupport` and `SnapGroupSupport.freeSpace`
/// already read via Accessibility, so every decision below is exercised
/// directly by `build.sh --test`.
enum SnapDividerHintSupport {
    /// The bar to draw: `frame` in AppKit space, `isVertical` true for a
    /// left/right seam (a vertical bar) and false for a top/bottom seam (a
    /// horizontal bar).
    struct DividerHint: Equatable {
        let frame: CGRect
        let isVertical: Bool
    }

    /// The shortest edge overlap that counts as a real shared border rather
    /// than two frames only touching at a corner point — matches
    /// `SnapGroupSupport`'s own `edgeOverlapMinimum` so the two can never
    /// disagree about what counts as "sharing an edge."
    private static let edgeOverlapMinimum: CGFloat = 1

    /// The seam nearest `point`, if any live frame pair in `members` shares
    /// one within `tolerance` of it and `point` itself is within
    /// `tolerance` of the seam's own line — the first pair found wins,
    /// which only matters for a degenerate overlapping-frame case no real
    /// Snap Group produces. `members` are live frames (AppKit space), not
    /// theoretical zones: the visible seam a person actually sees is
    /// between the real, possibly-resized rectangles on screen, exactly
    /// the same distinction `SnapGroupSupport.freeSpace`'s own doc comment
    /// draws between a zone and a current frame.
    static func dividerHint(at point: CGPoint,
                            members: [(windowID: CGWindowID, frame: CGRect)],
                            tolerance: CGFloat = 6,
                            barThickness: CGFloat = 3) -> DividerHint? {
        guard members.count >= 2 else { return nil }
        for i in members.indices {
            for j in members.indices where j > i {
                if let hint = verticalHint(point: point, a: members[i].frame, b: members[j].frame,
                                           tolerance: tolerance, barThickness: barThickness) {
                    return hint
                }
                if let hint = horizontalHint(point: point, a: members[i].frame, b: members[j].frame,
                                             tolerance: tolerance, barThickness: barThickness) {
                    return hint
                }
            }
        }
        return nil
    }

    /// A left/right seam between `a` and `b` — whichever of the two sits to
    /// the left proposes its `maxX`, the other its `minX`; if those two
    /// values are within `tolerance` of each other, they share a real
    /// vertical seam near their average X, and `point` counts as "on it"
    /// when it is horizontally within `tolerance` and vertically inside
    /// the pair's shared Y range.
    private static func verticalHint(point: CGPoint, a: CGRect, b: CGRect,
                                     tolerance: CGFloat, barThickness: CGFloat) -> DividerHint? {
        let overlapMinY = max(a.minY, b.minY)
        let overlapMaxY = min(a.maxY, b.maxY)
        guard overlapMaxY - overlapMinY > edgeOverlapMinimum else { return nil }
        let (leftEdge, rightEdge) = a.maxX <= b.maxX ? (a.maxX, b.minX) : (b.maxX, a.minX)
        guard abs(leftEdge - rightEdge) <= tolerance else { return nil }
        let seamX = (leftEdge + rightEdge) / 2
        guard abs(point.x - seamX) <= tolerance, point.y >= overlapMinY, point.y <= overlapMaxY else { return nil }
        let frame = CGRect(x: seamX - barThickness / 2, y: overlapMinY,
                           width: barThickness, height: overlapMaxY - overlapMinY)
        return DividerHint(frame: frame, isVertical: true)
    }

    /// The top/bottom counterpart of `verticalHint`, by the same reasoning
    /// with the axes swapped.
    private static func horizontalHint(point: CGPoint, a: CGRect, b: CGRect,
                                       tolerance: CGFloat, barThickness: CGFloat) -> DividerHint? {
        let overlapMinX = max(a.minX, b.minX)
        let overlapMaxX = min(a.maxX, b.maxX)
        guard overlapMaxX - overlapMinX > edgeOverlapMinimum else { return nil }
        let (bottomEdge, topEdge) = a.maxY <= b.maxY ? (a.maxY, b.minY) : (b.maxY, a.minY)
        guard abs(bottomEdge - topEdge) <= tolerance else { return nil }
        let seamY = (bottomEdge + topEdge) / 2
        guard abs(point.y - seamY) <= tolerance, point.x >= overlapMinX, point.x <= overlapMaxX else { return nil }
        let frame = CGRect(x: overlapMinX, y: seamY - barThickness / 2,
                           width: overlapMaxX - overlapMinX, height: barThickness)
        return DividerHint(frame: frame, isVertical: false)
    }
}
