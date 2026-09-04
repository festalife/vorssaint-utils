// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import os.log

/// The one logging channel for the whole snapping subsystem.
///
/// Everything goes to a single subsystem/category pair, at `.default` level,
/// so one command tells the whole story of what just happened:
///
/// ```sh
/// log show --last 5m --predicate 'category == "snap"'
/// ```
///
/// `.default` and not `.info`/`.debug` on purpose: those two levels are
/// memory-only by default, so they survive `log stream` but are gone by the
/// time anyone runs `log show` — which is exactly when a report like "the
/// overlay just did not appear and nothing said why" arrives. `.default` is
/// persisted to disk with no flags on either side.
///
/// Every line starts with a short, greppable event name from a fixed
/// vocabulary (`SnapController`'s own doc comment lists it), followed by
/// `key=value` details. One line per state transition and one per early
/// return, always including the reason and the numbers the decision was made
/// from — never a bare "something went wrong".
enum SnapLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vorssaint.utils",
                               category: "snap")

    /// One log line. `detail` is `@autoclosure` only to keep string building
    /// off the hot path when a caller assembles something expensive; the
    /// line itself is always emitted, since a snap event that is not logged
    /// is precisely the failure mode this channel exists to end.
    static func event(_ name: String, _ detail: @autoclosure () -> String = "") {
        let detail = detail()
        let line = detail.isEmpty ? name : "\(name) \(detail)"
        logger.log(level: .default, "\(line, privacy: .public)")
    }

    /// `CGRect` in a form that stays readable in a log line — `String(describing:)`
    /// on a `CGRect` is verbose and wraps badly in `log show` output.
    static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    static func point(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    static func size(_ size: CGSize?) -> String {
        guard let size else { return "nil" }
        return "\(Int(size.width))x\(Int(size.height))"
    }
}
