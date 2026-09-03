// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The Snap Assist overlay (spec §4): a dark translucent surface — the same
/// material pair `SnapLayoutsPanelView`'s backplate uses — covering the free
/// zone a snap just left, with a grid of the other open windows to fill it.
/// Purely presentational: a card's click is reported straight back through
/// `state.onSelect` by `SnapAssistCardClickCatcher` (see its own doc comment
/// for why a real `NSView` handles this instead of a SwiftUI `Button`), and
/// `SnapAssistPanel` decides everything else (placement, dismissal, moving
/// on to the next free cell).
struct SnapAssistPanelView: View {
    @ObservedObject var state: SnapAssistPanelState
    @Environment(\.colorScheme) private var colorScheme

    /// A fixed column count, not an adaptive grid: `SnapAssistPanel.layout`
    /// already picked this exact number when it sized the panel's own
    /// frame with `SnapAssistSupport.columnCount`/`contentSize`, so the grid
    /// drawn here has to use the same number rather than re-deriving its
    /// own from the frame it happens to land in — otherwise the two can
    /// disagree (an adaptive grid fitting one more column than the panel
    /// was sized for reflows into a taller, clipped layout instead of the
    /// one the frame math already accounted for).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(SnapAssistPanel.itemSize.width), spacing: SnapAssistPanel.spacing),
             count: max(1, state.columns))
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: SnapAssistPanel.spacing) {
                    ForEach(state.items) { item in
                        SnapAssistCardView(item: item,
                                          preview: item.previewWindowID.flatMap { state.previews[$0] }) {
                            state.onSelect?(item)
                        }
                    }
                }
            }
            if !state.hint.isEmpty {
                Text(state.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PanelSurface.baseFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PanelSurface.border(for: colorScheme), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(colorScheme == .light ? 0.16 : 0.45), radius: 16, y: 4)
    }
}

/// One candidate window: its thumbnail (or, without Screen Recording, just
/// the app icon), the app icon again as a small badge, and the window title
/// underneath — the same "icon + title under the picture" shape the
/// Switcher and Dock Preview cards already use, kept intentionally simpler
/// since this card has one job.
private struct SnapAssistCardView: View {
    let item: SwitcherItem
    let preview: CGImage?
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PanelSurface.controlFill(for: colorScheme))
                if let preview {
                    Image(decorative: preview, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        .opacity(0.7)
                }
            }
            .frame(width: SnapAssistPanel.itemSize.width,
                   height: SnapAssistPanel.itemSize.height - 32)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovering ? Color.accentColor : PanelSurface.border(for: colorScheme),
                                 lineWidth: isHovering ? 1.6 : 0.8)
            )

            HStack(spacing: 4) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                Text(item.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: SnapAssistPanel.itemSize.width)
        }
        // The click catcher sits on top of the whole card, transparent, and
        // owns both the click and the hover highlight — see its doc comment
        // for why a plain SwiftUI `Button`/`.onHover` pair is not used here.
        .overlay(SnapAssistCardClickCatcher(onClick: onSelect, onHoverChange: { isHovering = $0 }))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.accessibilityTitle)
    }
}

/// Catches a card's click with a real `NSView`, not a SwiftUI `Button`.
///
/// `SnapAssistPanel` is deliberately a `.nonactivatingPanel` that never
/// activates Vorssaint or steals focus from the window that was just
/// snapped (spec §4's "must not steal focus more than necessary") — which
/// is exactly the situation where SwiftUI's own tap gesture is unreliable.
/// Real-Mac testing found a single physical click on a card's `Button`
/// closing the overlay without placing anything: the click was being
/// treated as "outside the panel" by `SnapAssistPanel`'s own dismiss
/// monitors before — or instead of — ever reaching the SwiftUI gesture
/// recognizer, which independently gates on the window being fully key,
/// something a momentarily-non-key non-activating panel cannot always
/// guarantee at the exact instant of a click. A plain `NSView` override of
/// `mouseDown`/`mouseUp` has no such gate: it processes exactly the event
/// pair AppKit delivers, and `acceptsFirstMouse` means it processes even
/// the very first click after the panel appears, instead of that click
/// being spent only bringing the window forward.
private struct SnapAssistCardClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        view.onClick = onClick
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: ClickCatcherView, context: Context) {
        nsView.onClick = onClick
        nsView.onHoverChange = onHoverChange
    }

    final class ClickCatcherView: NSView {
        var onClick: (() -> Void)?
        var onHoverChange: ((Bool) -> Void)?
        private var isPressed = false
        private var trackingArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

        override func mouseDown(with event: NSEvent) {
            isPressed = true
        }

        override func mouseDragged(with event: NSEvent) {
            // Dragging off the card before releasing cancels the click,
            // matching a normal button's behavior.
            isPressed = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            defer { isPressed = false }
            guard isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?()
        }
    }
}
