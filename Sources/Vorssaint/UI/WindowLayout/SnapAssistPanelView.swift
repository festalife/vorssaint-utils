// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The Snap Assist overlay (spec §4): a dark translucent surface — the same
/// material pair `SnapLayoutsPanelView`'s backplate uses — covering the free
/// zone a snap just left, with a grid of the other open windows to fill it.
/// Purely presentational: a card's `Button` reports the pick straight back
/// through `state.onSelect`, and `SnapAssistPanel` decides everything else
/// (placement, dismissal, moving on to the next free cell).
struct SnapAssistPanelView: View {
    @ObservedObject var state: SnapAssistPanelState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: SnapAssistPanel.itemSize.width),
                                       spacing: SnapAssistPanel.spacing)],
                    spacing: SnapAssistPanel.spacing
                ) {
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
        Button(action: onSelect) {
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
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.accessibilityTitle)
    }
}
