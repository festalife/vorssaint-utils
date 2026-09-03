// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// A preset of layout zones shown together as one mini-diagram card in the
/// Snap Layouts panel, e.g. "left half / right half" or "four quarters".
/// `zones` is in drawing order — row-major, left to right then top to
/// bottom — so it lines up directly with the grid `columns` describes.
struct SnapLayoutPreset: Identifiable, Equatable {
    let id: String
    let zones: [WindowLayoutAction]
    let columns: Int
}

/// Sizing shared by the hit-test math here and the SwiftUI card that draws
/// the same grid, so a cell drawn on screen and the cell a release resolves
/// to can never drift apart.
struct SnapLayoutsPanelLayout: Equatable {
    let cardSize: CGSize
    let spacing: CGFloat
    let padding: CGFloat
}

/// Pure geometry for the Snap Layouts panel: which presets to offer for a
/// given screen, how big the panel is, and which zone a point over it maps
/// to. No AppKit, so it is exercised directly by `build.sh --test`.
enum SnapLayoutPresets {
    static let halves = SnapLayoutPreset(id: "halves", zones: [.leftHalf, .rightHalf], columns: 2)
    static let thirdsEven = SnapLayoutPreset(id: "thirdsEven",
                                             zones: [.leftThird, .centerThird, .rightThird],
                                             columns: 3)
    static let thirdsWideLeft = SnapLayoutPreset(id: "thirdsWideLeft",
                                                 zones: [.leftTwoThirds, .rightThird],
                                                 columns: 2)
    static let thirdsWideRight = SnapLayoutPreset(id: "thirdsWideRight",
                                                  zones: [.leftThird, .rightTwoThirds],
                                                  columns: 2)
    static let quarters = SnapLayoutPreset(id: "quarters",
                                           zones: [.topLeft, .topRight, .bottomLeft, .bottomRight],
                                           columns: 2)

    static let defaultLayout = SnapLayoutsPanelLayout(cardSize: CGSize(width: 96, height: 60),
                                                       spacing: 10,
                                                       padding: 14)

    /// Below this width a third-based card would draw cells too thin to
    /// aim at with a dragged window; below the quarters width a 2x2 grid
    /// has the same problem on top of needing spare height too. Windows
    /// hides layouts the same way under a certain resolution.
    private static let thirdsMinWidth: CGFloat = 700
    private static let quartersMinWidth: CGFloat = 900
    private static let quartersMinHeight: CGFloat = 500

    /// Which preset cards to show for a screen's visible frame, in the
    /// order Windows 11 shows them: halves, then thirds, then quarters.
    static func availablePresets(for visibleFrame: CGRect) -> [SnapLayoutPreset] {
        var presets: [SnapLayoutPreset] = [halves]
        if visibleFrame.width >= thirdsMinWidth {
            presets.append(contentsOf: [thirdsEven, thirdsWideLeft, thirdsWideRight])
        }
        if visibleFrame.width >= quartersMinWidth, visibleFrame.height >= quartersMinHeight {
            presets.append(quarters)
        }
        return presets
    }

    /// The panel's overall size for a row of cards laid out with `layout`.
    static func panelSize(for presets: [SnapLayoutPreset],
                          layout: SnapLayoutsPanelLayout = defaultLayout) -> CGSize {
        guard !presets.isEmpty else { return .zero }
        let width = layout.padding * 2
            + CGFloat(presets.count) * layout.cardSize.width
            + CGFloat(max(0, presets.count - 1)) * layout.spacing
        let height = layout.padding * 2 + layout.cardSize.height
        return CGSize(width: width, height: height)
    }

    /// Each preset's card frame within a panel occupying `panelFrame`, in
    /// the same coordinate space as `panelFrame` itself (AppKit points,
    /// origin bottom-left, as the panel's own `NSPanel.frame` already is).
    static func cardFrames(for presets: [SnapLayoutPreset],
                           panelFrame: CGRect,
                           layout: SnapLayoutsPanelLayout = defaultLayout) -> [(preset: SnapLayoutPreset, frame: CGRect)] {
        var x = panelFrame.minX + layout.padding
        let y = panelFrame.minY + layout.padding
        return presets.map { preset in
            let frame = CGRect(x: x, y: y, width: layout.cardSize.width, height: layout.cardSize.height)
            x += layout.cardSize.width + layout.spacing
            return (preset, frame)
        }
    }

    /// Which action releasing at `point` would apply, given the panel
    /// currently showing `presets` at `panelFrame` — nil outside every
    /// card. `point` is in the same coordinate space as `panelFrame`.
    static func zone(at point: CGPoint,
                     presets: [SnapLayoutPreset],
                     panelFrame: CGRect,
                     layout: SnapLayoutsPanelLayout = defaultLayout) -> WindowLayoutAction? {
        for (preset, frame) in cardFrames(for: presets, panelFrame: panelFrame, layout: layout) {
            guard frame.contains(point) else { continue }
            return zone(at: point, in: preset, cardFrame: frame)
        }
        return nil
    }

    /// Hit-tests a single card's grid. Row 0 is the top row (`zones`' own
    /// order), so the row index counts down from the card's `maxY` even
    /// though AppKit rects grow upward from `minY`.
    static func zone(at point: CGPoint,
                     in preset: SnapLayoutPreset,
                     cardFrame: CGRect) -> WindowLayoutAction? {
        guard cardFrame.contains(point), preset.columns > 0, !preset.zones.isEmpty else { return nil }
        let rows = Int(ceil(Double(preset.zones.count) / Double(preset.columns)))
        guard rows > 0 else { return nil }
        let cellWidth = cardFrame.width / CGFloat(preset.columns)
        let cellHeight = cardFrame.height / CGFloat(rows)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let column = min(preset.columns - 1, max(0, Int((point.x - cardFrame.minX) / cellWidth)))
        let row = min(rows - 1, max(0, Int((cardFrame.maxY - point.y) / cellHeight)))
        let index = row * preset.columns + column
        guard preset.zones.indices.contains(index) else { return nil }
        return preset.zones[index]
    }
}
