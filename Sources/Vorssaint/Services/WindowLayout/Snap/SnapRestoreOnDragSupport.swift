// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Pure geometry for spec §1's last row: dragging a snapped Snap Group
/// member away by its title bar restores it to the size it had before it
/// was ever snapped, staying under the cursor the way Windows' own
/// drag-away restore does. No AppKit: `WindowLayoutService` is the only
/// caller, from the same Accessibility move notification that already
/// tells `SnapLinkedResizeSupport` a plain move (as opposed to a resize)
/// happened — everything here is exercised directly by `build.sh --test`.
enum SnapRestoreOnDragSupport {
    /// Whether `member` — read with its live `newFrame` right after a
    /// confirmed plain move (the caller has already used
    /// `SnapLinkedResizeSupport.moveSizeTolerance` to rule out a resize) —
    /// should restore to its pre-snap size: it has one recorded at all, and
    /// it has genuinely left its zone (`SnapGroupSupport.stillAnchored`
    /// failing is exactly "a title-bar drag moved it", per that function's
    /// own doc comment). A resize along the snapped edge never reaches
    /// here restore-eligible, since it stays anchored by definition.
    static func shouldRestore(member: SnapGroupMember, newFrame: CGRect, gap: CGFloat) -> Bool {
        guard member.restoreSize != nil else { return false }
        return !SnapGroupSupport.stillAnchored(member: member, currentFrame: newFrame, gap: gap)
    }

    /// The frame to write when restoring: `restoreSize`, positioned so the
    /// point at `cursor`'s fractional position within `currentFrame` lands
    /// at the same fractional position within the restored frame — the
    /// window stays "under the cursor" rather than snapping back centered
    /// on wherever its old zone was. `cursor` is clamped to `currentFrame`
    /// first, so a cursor read that arrived a frame late (already past the
    /// window's edge) never throws the restored position far off screen.
    static func restoredFrame(currentFrame: CGRect, restoreSize: CGSize, cursor: CGPoint) -> CGRect {
        guard currentFrame.width > 0, currentFrame.height > 0 else {
            return CGRect(origin: currentFrame.origin, size: restoreSize)
        }
        let clampedX = min(max(cursor.x, currentFrame.minX), currentFrame.maxX)
        let clampedY = min(max(cursor.y, currentFrame.minY), currentFrame.maxY)
        let fractionX = (clampedX - currentFrame.minX) / currentFrame.width
        let fractionY = (clampedY - currentFrame.minY) / currentFrame.height
        let originX = clampedX - fractionX * restoreSize.width
        let originY = clampedY - fractionY * restoreSize.height
        return CGRect(origin: CGPoint(x: originX, y: originY), size: restoreSize)
    }
}
