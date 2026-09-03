// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Pure geometry and ordering for Snap Assist (spec §4): once a window is
/// placed into a partial zone, which of the *other* zones in that same
/// layout are still free, which window to offer for each, and how to lay
/// out their thumbnails. No AppKit — `WindowLayoutService` is the only
/// caller that touches Accessibility or a panel, so every decision below is
/// exercised directly by `build.sh --test`.
enum SnapAssistSupport {
    /// Below this size per axis, spec §9's rule for an oversized minimum
    /// window applies just as much here: a free zone this small is not
    /// worth covering with an overlay at all — nobody can usefully read a
    /// thumbnail grid or land a click in it. Matches
    /// `SnapGroupSupport.minimumSpace`, the same threshold free space
    /// itself already falls back under.
    static let minimumOfferableSpace: CGFloat = 200

    /// Whether `freeRect` is worth opening Snap Assist over at all.
    static func isOfferable(freeRect: CGRect) -> Bool {
        freeRect.width >= minimumOfferableSpace && freeRect.height >= minimumOfferableSpace
    }

    /// Whether a candidate window belongs on `screenFrame` at all — a
    /// window on another display, or one that does not currently overlap
    /// this screen, is never worth offering: picking it would place it into
    /// a zone it cannot usefully reach, or one the person cannot even see
    /// right now.
    ///
    /// `windowFrame` is window-server/Accessibility global space (top-left
    /// origin, Y growing downward — `kCGWindowBounds`/`kAXPositionAttribute`
    /// both use it); `screenFrame` is AppKit space (bottom-left origin, Y
    /// growing upward — `NSScreen.frame`). `menuBarScreenTopY` (the `maxY`
    /// of whichever screen owns the menu bar) is the single fixed point
    /// both spaces agree on, the same conversion
    /// `WindowLayoutService.appKitFrame(fromAX:)` already performs for
    /// every placement; duplicated here in pure `CGRect` terms so the
    /// exact numbers a real Mac reports can be pinned down by a test
    /// without any AppKit or Accessibility involved.
    static func candidateOnScreen(windowFrame: CGRect, menuBarScreenTopY: CGFloat, screenFrame: CGRect) -> Bool {
        let windowAppKitFrame = CGRect(x: windowFrame.origin.x,
                                       y: menuBarScreenTopY - windowFrame.origin.y - windowFrame.height,
                                       width: windowFrame.width,
                                       height: windowFrame.height)
        return screenFrame.intersects(windowAppKitFrame)
    }

    /// The other zones in the same layout `action` belongs to — what
    /// Windows leaves for Snap Assist to offer (spec §4/§5's examples):
    /// a half's other half, a third's other two thirds *as two separate
    /// cells* (not the combined two-thirds zone), a two-thirds' remaining
    /// third, a quarter's other three quarters, a sixth's other five
    /// sixths. An action with no siblings (`.maximize`, `.center`, a
    /// display crossing, `.restore`…) returns an empty list, since none of
    /// those leave a sibling zone behind at all.
    static func siblingZones(of action: WindowLayoutAction) -> [WindowLayoutAction] {
        switch action {
        case .leftHalf: return [.rightHalf]
        case .rightHalf: return [.leftHalf]
        case .topHalf: return [.bottomHalf]
        case .bottomHalf: return [.topHalf]
        case .leftThird: return [.centerThird, .rightThird]
        case .centerThird: return [.leftThird, .rightThird]
        case .rightThird: return [.leftThird, .centerThird]
        case .leftTwoThirds: return [.rightThird]
        case .rightTwoThirds: return [.leftThird]
        case .topLeft: return [.topRight, .bottomLeft, .bottomRight]
        case .topRight: return [.topLeft, .bottomLeft, .bottomRight]
        case .bottomLeft: return [.topLeft, .topRight, .bottomRight]
        case .bottomRight: return [.topLeft, .topRight, .bottomLeft]
        case .topLeftSixth:
            return [.topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
        case .topCenterSixth:
            return [.topLeftSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
        case .topRightSixth:
            return [.topLeftSixth, .topCenterSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
        case .bottomLeftSixth:
            return [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomCenterSixth, .bottomRightSixth]
        case .bottomCenterSixth:
            return [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomRightSixth]
        case .bottomRightSixth:
            return [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth]
        case .maximize, .marginMaximize, .fullScreen, .center,
                .previousDisplay, .nextDisplay, .restore:
            return []
        }
    }

    /// Which of `cells` (in their given order, which is `siblingZones`'
    /// reading order) still has no member — the one cell Snap Assist offers
    /// right now. Windows compiles free cells one at a time, never all at
    /// once (spec §4 point 2): re-deriving this from the *current* group
    /// membership on every call, rather than tracking a separate queue,
    /// means a Snap Assist pick — which itself joins the group — advances
    /// to the next cell for free, and a window snapped by hand into one of
    /// the remaining cells is picked up the same way.
    static func nextFreeCell(in cells: [WindowLayoutAction],
                             occupied: Set<WindowLayoutAction>) -> WindowLayoutAction? {
        cells.first { !occupied.contains($0) }
    }

    /// The other open windows worth offering for a cell, most recently used
    /// first: `mru` (already ordered) with `excluded` — the window that was
    /// just placed, plus every window already in the group — filtered out.
    /// A user must never be offered the window they just snapped, or one
    /// that is already part of the group (spec §4's "never twice").
    static func candidates(mru: [CGWindowID], excluding excluded: Set<CGWindowID>) -> [CGWindowID] {
        mru.filter { !excluded.contains($0) }
    }

    /// How many columns a grid of `count` thumbnails should use to fit
    /// `boundsWidth` at roughly `itemWidth` each with `spacing` between,
    /// capped at `maxColumns` and never more than `count` itself (an empty
    /// last row looks like a mistake, not a choice).
    static func columnCount(count: Int,
                            boundsWidth: CGFloat,
                            itemWidth: CGFloat,
                            spacing: CGFloat,
                            maxColumns: Int) -> Int {
        guard count > 0, itemWidth > 0, maxColumns > 0 else { return 1 }
        let fitting = Int((boundsWidth + spacing) / (itemWidth + spacing))
        return max(1, min(maxColumns, min(count, fitting)))
    }

    /// The frame of each of `count` cells laid out row-major (left to right,
    /// then top to bottom) in `columns` columns, each `itemSize`, separated
    /// by `spacing` and inset from `bounds` by `padding` — origin top-left,
    /// matching how the panel draws its grid, independent of any particular
    /// UI framework's own layout pass.
    static func cellFrames(count: Int,
                           columns: Int,
                           itemSize: CGSize,
                           spacing: CGFloat,
                           padding: CGFloat) -> [CGRect] {
        guard count > 0, columns > 0 else { return [] }
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let x = padding + CGFloat(column) * (itemSize.width + spacing)
            let y = padding + CGFloat(row) * (itemSize.height + spacing)
            return CGRect(x: x, y: y, width: itemSize.width, height: itemSize.height)
        }
    }

    /// The overall content size for `count` items laid out with
    /// `cellFrames`' exact geometry — the panel's minimum size before it is
    /// clamped to the free zone it has to fit inside.
    static func contentSize(count: Int,
                            columns: Int,
                            itemSize: CGSize,
                            spacing: CGFloat,
                            padding: CGFloat) -> CGSize {
        guard count > 0, columns > 0 else { return .zero }
        let rows = Int((count + columns - 1) / columns)
        let width = padding * 2 + CGFloat(columns) * itemSize.width + CGFloat(max(0, columns - 1)) * spacing
        let height = padding * 2 + CGFloat(rows) * itemSize.height + CGFloat(max(0, rows - 1)) * spacing
        return CGSize(width: width, height: height)
    }
}
