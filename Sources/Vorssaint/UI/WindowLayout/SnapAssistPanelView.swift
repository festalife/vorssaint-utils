// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Root content view of the Snap Assist overlay (spec §4): a dark
/// translucent rounded surface holding a grid of window-picker buttons and
/// a hint label underneath. Pure AppKit, no SwiftUI.
///
/// Two earlier versions of this panel drew the grid in SwiftUI — first a
/// plain `Button` per card, then (once that proved unreliable) a hand-rolled
/// `NSView` hit test computed from the same grid geometry. Both passed a
/// synthetic-coordinate test harness, but Marco's own trackpad clicks on a
/// real Mac still selected nothing even after the panel became a fully
/// activating, key window (`SnapAssistPanel`'s own doc comment has the
/// detail). A genuine `NSButton`'s click handling is unambiguous and long
/// since battle-tested — this view builds the grid directly with one,
/// arranged in row `NSStackView`s inside a scroll view, so there is no
/// SwiftUI gesture recognizer or hosting-view hit-test bridge left in the
/// path a click has to survive at all.
final class SnapAssistContentView: NSView {
    private let backgroundView = NSView()
    private let scrollView = NSScrollView()
    private let grid = NSStackView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var buttons: [SnapAssistCardButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpBackground()
        setUpLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func setUpBackground() {
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        backgroundView.layer?.cornerRadius = 16
        backgroundView.layer?.borderWidth = 0.8
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setUpLayout() {
        let padding = SnapAssistPanel.padding
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = SnapAssistPanel.spacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = grid
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            grid.topAnchor.constraint(equalTo: clip.topAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
        ])

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -10),

            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    /// Rebuilds the grid for a fresh `show()`. `columns` is
    /// `SnapAssistPanel.layout`'s own count — the same one the panel's
    /// frame was sized for — so row-wrapping here can never disagree with
    /// how much width the window actually has.
    func configure(items: [SwitcherItem], columns: Int, hint: String, onSelect: @escaping (SwitcherItem) -> Void) {
        for row in grid.arrangedSubviews {
            grid.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        buttons = []
        hintLabel.stringValue = hint
        hintLabel.isHidden = hint.isEmpty

        var currentRow: NSStackView?
        for (index, item) in items.enumerated() {
            if index % max(1, columns) == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = SnapAssistPanel.spacing
                grid.addArrangedSubview(row)
                currentRow = row
            }
            let button = SnapAssistCardButton(item: item)
            button.onSelect = { onSelect(item) }
            currentRow?.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    /// A thumbnail landed for one of the offered windows.
    func updatePreview(_ image: CGImage, for windowID: CGWindowID) {
        for button in buttons where button.windowID == windowID {
            button.setPreview(image)
        }
    }
}

/// Top-left origin for the grid's scroll view, matching every other
/// coordinate space in this feature (spec §4's cards fill top row first).
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// One candidate window, as a genuine `NSButton`: a real `AXButton` with a
/// real `AXPress` action, clickable anywhere within its bounds — thumbnail,
/// margins and title label alike, matching how a person actually aims a
/// click at a card rather than just its icon.
final class SnapAssistCardButton: NSButton {
    let windowID: CGWindowID
    var onSelect: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private let appIcon: NSImage?
    /// The `NSEvent.eventNumber` of the physical click `triggerSelect`
    /// already fired `onSelect` for — de-duplication between the two
    /// independent paths that can now trigger a pick for the very same
    /// click: NSButton's own mouseDown/mouseUp tracking loop
    /// (`handleClick`, via `target`/`action`) and
    /// `KeyableSnapAssistPanel.sendEvent`'s own direct hit-test on
    /// `leftMouseUp` (added because a real-Mac report found clicks that
    /// visibly reached this window still not picking a card — belt and
    /// braces, not a replacement for fixing why the first path can miss).
    /// `nil` means no click has been handled yet.
    private var lastHandledEventNumber: Int?

    init(item: SwitcherItem) {
        self.windowID = item.windowID ?? 0
        self.appIcon = item.appIcon
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: SnapAssistPanel.itemSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: SnapAssistPanel.itemSize.height).isActive = true

        title = item.displayTitle
        image = appIcon
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyUpOrDown
        bezelStyle = .regularSquare
        isBordered = false
        font = .systemFont(ofSize: 10.5)
        lineBreakMode = .byTruncatingTail
        setButtonType(.momentaryChange)
        target = self
        action = #selector(handleClick)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0.8
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        toolTip = item.accessibilityTitle
        setAccessibilityLabel(item.accessibilityTitle)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// A thumbnail landed — shown in place of the plain app icon, scaled to
    /// roughly fill the button above its title, the same "picture, then
    /// label" shape the Switcher and Dock Preview cards use.
    func setPreview(_ cgImage: CGImage) {
        let size = NSSize(width: SnapAssistPanel.itemSize.width - 8,
                          height: SnapAssistPanel.itemSize.height - 40)
        image = NSImage(cgImage: cgImage, size: size)
        imageScaling = .scaleProportionallyUpOrDown
    }

    // A non-activating, momentarily-not-key panel was the earlier failure
    // mode; this panel is now genuinely activating (`SnapAssistPanel.show`),
    // but the override costs nothing and keeps the very first click after
    // the panel appears from ever being spent only bringing it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        SnapLog.event("assist.card-down",
                      "windowID=\(self.windowID) at=\(SnapLog.point(event.locationInWindow)) bounds=\(SnapLog.rect(self.bounds))")
        super.mouseDown(with: event)
    }

    /// Fires `onSelect` for `eventNumber`, the first time only — `source`
    /// is just for the log line, so a real-Mac report can tell whether a
    /// pick happened through NSButton's own tracking loop or through the
    /// panel's direct hit-test fallback (see that type's own doc comment).
    func triggerSelect(eventNumber: Int, source: String) {
        guard lastHandledEventNumber != eventNumber else {
            SnapLog.event("assist.card-press-duplicate", "windowID=\(self.windowID) source=\(source)")
            return
        }
        lastHandledEventNumber = eventNumber
        SnapLog.event("assist.card-press", "windowID=\(self.windowID) source=\(source)")
        onSelect?()
    }

    @objc private func handleClick() {
        triggerSelect(eventNumber: NSApp.currentEvent?.eventNumber ?? -1, source: "NSButton action")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.6
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 0.8
    }
}
