// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics

/// Where a placement came from. The distinction is load-bearing: only a
/// *user* placement may open a Snap Assist session (spec §4 — "NON ricompare
/// finché l'utente non aggancia di nuovo una finestra"), while a placement
/// Snap Assist itself performed may only ever advance the session it came
/// from. Conflating the two is what let an earlier version of this feature
/// re-open its own overlay in a loop.
enum SnapPlacementOrigin: Equatable {
    /// A drag to an edge, a Snap Layouts cell, a zoom-button flyout cell, a
    /// shortcut, a directional gesture — anything the person did directly.
    case user
    /// A card click inside the Snap Assist overlay.
    case snapAssist
}

/// What a drag is currently pointed at.
struct SnapDragState: Equatable {
    let windowID: CGWindowID
    /// False until `WindowEdgeSnapSupport.classify` has confirmed the window
    /// is actually following the pointer — a resize, or a click that never
    /// moved anything, never becomes a snap.
    var isMoving: Bool = false
    /// The zone a release right now would apply, or `nil` over open screen.
    var target: WindowLayoutAction? = nil
    /// Whether the top-edge Snap Layouts bar is currently open for this drag.
    var layoutsPanelOpen: Bool = false
}

/// A placement that just landed successfully.
struct SnapPlacement: Equatable {
    let windowID: CGWindowID
    let action: WindowLayoutAction
    let screenID: CGDirectDisplayID
}

/// The single explicit state of the snapping subsystem.
///
/// Idle → Dragging → Placed → Assisting → Idle. Nothing else in
/// `SnapController` keeps a parallel "is something open" flag: every panel is
/// shown or hidden as a consequence of the phase changing, so the two can
/// never disagree the way the old scattered booleans did.
enum SnapPhase: Equatable {
    case idle
    /// A window is being dragged; the edge preview and/or the Snap Layouts
    /// bar follow this phase's `target`.
    case dragging(SnapDragState)
    /// A placement just landed and the subsystem is deciding whether it
    /// leaves free space worth offering. Transient — always followed by
    /// `.assisting` or `.idle` within the same run-loop turn.
    case placed(SnapPlacement)
    /// The Snap Assist overlay is open for `session`'s current free cell.
    case assisting(SnapAssistSupport.SnapAssistSession)

    /// A short, stable name for a log line.
    var name: String {
        switch self {
        case .idle: return "idle"
        case .dragging: return "dragging"
        case .placed: return "placed"
        case .assisting: return "assisting"
        }
    }
}

/// Everything that can move the subsystem between phases. One case per real
/// cause, so a transition table can be written down (and tested) rather than
/// inferred from scattered `if` statements.
enum SnapEvent: Equatable {
    /// A left-button drag has been confirmed to be moving a real window.
    case dragBegan(windowID: CGWindowID)
    /// The zone a release would apply changed (including to `nil`).
    case dragTargetChanged(WindowLayoutAction?)
    /// The top-edge Snap Layouts bar opened or closed for this drag.
    case layoutsPanelChanged(Bool)
    /// The button came up, or tracking was abandoned.
    case dragEnded(reason: String)
    /// A placement wrote (or confirmed) a window into a zone.
    case placementLanded(SnapPlacement, origin: SnapPlacementOrigin)
    /// A session was opened for the free cells the placement left behind.
    case assistSessionOpened(SnapAssistSupport.SnapAssistSession)
    /// The overlay's current cell was filled.
    case assistCellPicked(WindowLayoutAction)
    /// Esc, a click outside, an app switch, the inactivity timeout, or the
    /// person reshaping the layout by hand.
    case assistDismissed(reason: String)
    /// Feature turned off, Accessibility revoked, screens reconfigured.
    case reset(reason: String)
}

/// One phase change, with the reason that caused it — exactly what
/// `SnapController` writes to the log, so a `log show` transcript reads as the
/// state machine's own history.
struct SnapTransition: Equatable {
    let from: SnapPhase
    let to: SnapPhase
    let reason: String

    var changed: Bool { from != to }
}

/// The pure state machine. No AppKit, no Accessibility, no timers: given a
/// phase and an event it says what the next phase is and why, and
/// `build.sh --test` exercises the whole table directly.
struct SnapStateMachine: Equatable {
    private(set) var phase: SnapPhase = .idle

    init(phase: SnapPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    mutating func apply(_ event: SnapEvent) -> SnapTransition {
        let from = phase
        let (next, reason) = Self.resolve(phase: from, event: event)
        phase = next
        return SnapTransition(from: from, to: next, reason: reason)
    }

    /// The transition table itself, as one pure function so it can be read —
    /// and tested — without instantiating anything.
    static func resolve(phase: SnapPhase, event: SnapEvent) -> (SnapPhase, String) {
        switch (phase, event) {
        case (_, .reset(let reason)):
            return (.idle, "reset: \(reason)")

        case (let from, .dragBegan(let windowID)):
            // A fresh drag always supersedes whatever was open: spec §9's
            // "doppia richiesta" — a second window dragged to an edge while
            // Snap Assist is showing closes the overlay, the drag wins.
            let note: String
            switch from {
            case .assisting: note = "drag supersedes an open Snap Assist session"
            case .placed: note = "drag supersedes a just-landed placement"
            default: note = "new drag"
            }
            return (.dragging(SnapDragState(windowID: windowID)), "\(note) windowID=\(windowID)")

        case (.dragging(var state), .dragTargetChanged(let action)):
            guard state.target != action else {
                return (.dragging(state), "target unchanged")
            }
            state.target = action
            return (.dragging(state), "target=\(action.map { "\($0)" } ?? "none")")

        case (.dragging(var state), .layoutsPanelChanged(let open)):
            guard state.layoutsPanelOpen != open else {
                return (.dragging(state), "layouts panel unchanged")
            }
            state.layoutsPanelOpen = open
            return (.dragging(state), "layouts panel \(open ? "open" : "closed")")

        case (.dragging, .dragEnded(let reason)):
            return (.idle, "drag ended: \(reason)")

        case (.assisting(let session), .placementLanded(let placement, .snapAssist)):
            // A pick only ever advances the session it was made from — the
            // advance itself is `.assistCellPicked`, applied right after by
            // the controller once the placement is known to have landed.
            return (.assisting(session),
                    "assist placement windowID=\(placement.windowID) action=\(placement.action)")

        case (_, .placementLanded(let placement, .snapAssist)):
            // A pick whose session was dismissed between the click and the
            // placement completing. It must never start a fresh session.
            return (.idle,
                    "assist placement outlived its session windowID=\(placement.windowID) action=\(placement.action)")

        case (_, .placementLanded(let placement, .user)):
            // Every successful user placement lands here, whether or not the
            // window physically moved — a placement that found the window
            // already exactly on its zone still has to run the group update
            // and the Snap Assist decision. Skipping that no-op case is what
            // made the overlay appear the first time and not the second.
            return (.placed(placement),
                    "placed windowID=\(placement.windowID) action=\(placement.action) "
                        + "screen=\(placement.screenID) origin=user")

        case (.placed, .assistSessionOpened(let session)):
            return (.assisting(session),
                    "session opened cells=\(session.freeCells.count) next=\(session.currentCell.map { "\($0)" } ?? "none")")

        case (.assisting(let session), .assistCellPicked(let cell)):
            let advanced = session.pick(cell)
            guard advanced != session else {
                return (.assisting(session), "pick \(cell) is not this session's current cell, ignored")
            }
            guard let next = advanced.currentCell else {
                return (.idle, "session finished, every free cell filled")
            }
            return (.assisting(advanced), "session advanced to \(next)")

        case (.assisting, .assistDismissed(let reason)):
            return (.idle, "session dismissed: \(reason)")

        // Everything else is a no-op: an event that does not apply to the
        // current phase never silently mutates it.
        case (let from, let event):
            return (from, "ignored \(Self.label(of: event)) in \(from.name)")
        }
    }

    private static func label(of event: SnapEvent) -> String {
        switch event {
        case .dragBegan: return "dragBegan"
        case .dragTargetChanged: return "dragTargetChanged"
        case .layoutsPanelChanged: return "layoutsPanelChanged"
        case .dragEnded: return "dragEnded"
        case .placementLanded: return "placementLanded"
        case .assistSessionOpened: return "assistSessionOpened"
        case .assistCellPicked: return "assistCellPicked"
        case .assistDismissed: return "assistDismissed"
        case .reset: return "reset"
        }
    }
}

/// The one place the two coordinate spaces this subsystem straddles are
/// converted between.
///
/// - **Quartz / Accessibility space**: origin at the *top-left* of the menu
///   bar screen, Y growing downward. `CGEvent.location`, `kCGWindowBounds`
///   and `kAXPositionAttribute` all use it.
/// - **AppKit space**: origin at the *bottom-left* of the menu bar screen, Y
///   growing upward. `NSScreen.frame`, `NSPanel.frame` and
///   `NSEvent.mouseLocation` all use it.
///
/// `menuBarTopY` is the `maxY` of whichever `NSScreen` owns the menu bar —
/// the single fixed point the two spaces agree on. Every conversion in the
/// snapping subsystem goes through here, so a sign error can only ever be
/// made (and fixed, and pinned by a test) once.
enum SnapCoordinates {
    static func appKitPoint(fromQuartz point: CGPoint, menuBarTopY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: menuBarTopY - point.y)
    }

    static func quartzPoint(fromAppKit point: CGPoint, menuBarTopY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: menuBarTopY - point.y)
    }

    static func appKitRect(fromQuartz rect: CGRect, menuBarTopY: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: menuBarTopY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func quartzRect(fromAppKit rect: CGRect, menuBarTopY: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: menuBarTopY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }
}
