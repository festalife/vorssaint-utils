// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The Snap Assist overlay (spec §4): a dark translucent surface — the same
/// material pair `SnapLayoutsPanelView`'s backplate uses — covering the free
/// zone a snap just left, with a grid of the other open windows to fill it.
/// Purely presentational, including the cards: a click is never handled
/// here. `SnapAssistHostingView` (`SnapAssistPanel.swift`) hit-tests the
/// click itself against the same grid geometry this view is laid out with
/// (`SnapAssistSupport.cellFrames`) and calls `state.onSelect` directly —
/// see its own doc comment for why a SwiftUI `Button` or an embedded
/// `NSViewRepresentable` card catcher both proved unreliable on a real Mac.
/// This view only draws the grid and reflects hover state via `.onHover`,
/// which — unlike a click — does not depend on the window being key.
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
                                          preview: item.previewWindowID.flatMap { state.previews[$0] })
                    }
                }
            }
            if !state.hint.isEmpty {
                Text(state.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(SnapAssistPanel.padding)
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
/// since this card has one job. Purely visual — see `SnapAssistPanelView`'s
/// doc comment for where the click itself is actually handled.
private struct SnapAssistCardView: View {
    let item: SwitcherItem
    let preview: CGImage?
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
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.accessibilityTitle)
    }
}
