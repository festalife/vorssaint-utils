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
    /// Phase 4 (spec §4's automatic-fill option): how a successful
    /// partial-zone placement should react to the free space it leaves
    /// behind. `.ask` is today's overlay; `.auto` fills the first free cell
    /// immediately, no overlay, using the same candidate ordering the
    /// overlay would have offered first; `.off` does nothing, matching the
    /// feature disabled entirely.
    enum Mode: String {
        case ask
        case auto
        case off

        /// `windowSnapAssistMode`'s raw value, falling back to the legacy
        /// `windowSnapAssistEnabled` bool when the new key has never been
        /// written — the migration path for anyone who already has an
        /// opinion recorded under the old key. A person who turned Snap
        /// Assist off keeps seeing it off; everyone else (including nobody
        /// having touched either key) keeps seeing today's overlay.
        static func resolved(storedRawValue: String?, legacyEnabled: Bool) -> Mode {
            if let storedRawValue, let mode = Mode(rawValue: storedRawValue) {
                return mode
            }
            return legacyEnabled ? .ask : .off
        }
    }

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

    /// A Snap Assist session (spec §4): which cells of ONE layout family, on
    /// ONE screen, are still open for picking. Started by exactly one
    /// user-initiated placement and never re-derived from ambient Snap
    /// Group state afterward, unlike an earlier version of this feature —
    /// re-deriving "which cell is next" from live group membership on every
    /// placement could loop: drag a window right, then drag a second one
    /// left by hand, and the overlay asking for "the left side" could keep
    /// reappearing if a group member's tracked membership ever drifted out
    /// of step with where the window actually was. A session, which only
    /// ever changes through `pick`, cannot drift — its own list of free
    /// cells is the single source of truth for as long as it is open.
    ///
    /// There is no `end` operation: an ended session simply *is* `nil`.
    /// `WindowLayoutService` stores `SnapAssistSession?` and clears it on
    /// Esc, a click outside, an app switch, the inactivity timeout (all via
    /// `SnapAssistPanel.onDismiss`), or a fresh `start` superseding it.
    struct SnapAssistSession: Equatable {
        let screenID: CGDirectDisplayID
        /// The layout's other cells not yet picked, in reading order. The
        /// one the user just placed into, and every sibling some window
        /// already covered when the session `start`ed, are never in here.
        private(set) var freeCells: [WindowLayoutAction]

        /// The cell Snap Assist is currently offering, or `nil` once every
        /// free cell has been picked.
        var currentCell: WindowLayoutAction? { freeCells.first }
        var isFinished: Bool { freeCells.isEmpty }

        /// Begins a session for a user-initiated placement of `action` on
        /// `screenID`. `occupiedCells` are `action`'s sibling cells
        /// (`siblingZones(of:)`) that some window — a Snap Group member or
        /// not — already covers `occupiedCoverageThreshold` or more of
        /// (`cellIsOccupied`); those are never offered, matching Windows: a cell someone already
        /// parked a window in on purpose is not up for grabs. Returns `nil`
        /// when `action` has no siblings at all, or when every sibling is
        /// already occupied — there is nothing to open a session over
        /// (halves, both halves filled: no overlay).
        static func start(from action: WindowLayoutAction,
                          screenID: CGDirectDisplayID,
                          occupiedCells: Set<WindowLayoutAction>) -> SnapAssistSession? {
            let free = siblingZones(of: action).filter { !occupiedCells.contains($0) }
            guard !free.isEmpty else { return nil }
            return SnapAssistSession(screenID: screenID, freeCells: free)
        }

        /// The session after `cell` is filled, by a Snap Assist pick or by
        /// the person snapping a window into it by hand. `cell` is taken as
        /// a parameter, not assumed to be `currentCell`, so a caller that
        /// picks something unrelated to this session (a placement on a
        /// different cell entirely) leaves the session unchanged rather
        /// than silently advancing the wrong one.
        func pick(_ cell: WindowLayoutAction) -> SnapAssistSession {
            guard cell == currentCell else { return self }
            var copy = self
            copy.freeCells.removeFirst()
            return copy
        }
    }

    /// How much of a cell's own area some window has to cover before
    /// `cellIsOccupied` counts it as "parked there on purpose" rather than
    /// merely passing through it. On-device testing (real desktop: Chrome,
    /// WhatsApp, System Settings, a terminal, all in their ordinary,
    /// never-snapped positions) found a much lower bar — half the cell's
    /// area — false-positive constantly: a Chrome window sized 620×652
    /// sitting where its owner last left it happened to cover 51% of a
    /// 756×949 right-half cell purely by coincidence, which was enough to
    /// mark the cell occupied and cancel the session before it opened,
    /// with nothing on screen a person would call "already there" the way
    /// a genuinely snapped sibling is. A window this app itself places into
    /// a cell fills essentially all of it (minus the window/screen gap);
    /// this threshold is set well above what an incidentally overlapping,
    /// never-tiled window is likely to reach by chance, while still well
    /// below what a real occupant covers.
    static let occupiedCoverageThreshold: CGFloat = 0.9

    /// Whether some window in `frames` (AppKit space, matching `cellFrame`)
    /// already covers `occupiedCoverageThreshold` or more of `cellFrame` —
    /// a session's own occupancy test at `start`. Any window counts,
    /// whether or not it is a Snap Group member: unlike phase 2's
    /// neighbour-adjacency test (which only ever needs to reason about
    /// group members shrinking each other's free space), a fresh session
    /// has to catch a window the person put there by hand outside any
    /// group too — just not one that merely happens to overlap it.
    static func cellIsOccupied(cellFrame: CGRect, by frames: [CGRect]) -> Bool {
        let cellArea = cellFrame.width * cellFrame.height
        guard cellArea > 0 else { return false }
        return frames.contains { frame in
            let overlap = cellFrame.intersection(frame)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            return (overlap.width * overlap.height) / cellArea >= occupiedCoverageThreshold
        }
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
