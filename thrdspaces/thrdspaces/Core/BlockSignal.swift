//
//  BlockSignal.swift
//  ThrdSpaces — Core
//
//  App-level block-invalidation signal. After ANY successful block the server
//  (migration 0005_block_invisibility) already excludes the blocked user
//  bidirectionally from public_profiles / attendee_previews / nearby_events, so a
//  re-fetch returns no blocked-user rows. This notification tells the surfaces
//  that hold already-fetched rows (Discover map + list, an open attendee strip)
//  to re-fetch on next appearance (or immediately if visible) so a blocked
//  person can't linger from a pre-block fetch.
//
//  Deliberately narrow: a single NotificationCenter notification, not a general
//  cross-screen sync store. A shared observable state store is the noted
//  Phase 3/4 upgrade if live cross-screen sync is wanted beyond block safety.
//

import Foundation

extension Notification.Name {
    /// Posted after a successful block, on whichever `NotificationCenter` the
    /// blocker uses (production: `.default`). Carries no payload — the blocked id
    /// is never broadcast; observers simply re-fetch through the RLS-scoped
    /// repository, which the server has already filtered.
    static let thrdUserBlocked = Notification.Name("thrd.userBlocked")
}

/// The one place that names and posts the block-invalidation signal, so blockers
/// and observers can't drift on the string. The `center` parameter is a test
/// seam; production call sites use the `.default` default.
enum BlockSignal {
    static func userBlocked(on center: NotificationCenter = .default) {
        center.post(name: .thrdUserBlocked, object: nil)
    }
}
