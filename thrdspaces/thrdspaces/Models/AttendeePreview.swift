//
//  AttendeePreview.swift
//  ThrdSpaces — Models
//
//  DTO for the `public.attendee_previews` view (migration 0003, T12) — event
//  social proof under the attendee-list-privacy guard. Columns are byte-exact to
//  the view's projection: FIRST NAME + avatar only, no handle, no user id (D10:
//  canonical shapes live in Models/). The view already excludes non-`going`
//  tickets, unpublished events, and deletion-grace accounts; 0005 (T18) adds
//  blocked-pair exclusion. There is deliberately no user id here — an attendee is
//  identified only by a first name, so nothing links a preview back to a profile.
//
//  Decodable only — the client never writes attendee previews.
//

import Foundation

struct AttendeePreview: Decodable, Equatable {
    let eventId: UUID
    let firstName: String
    /// Present in the wire shape but NOT loaded as an image this phase (D2: no
    /// image path until the CSAM pipeline lands). Attendee avatars render as
    /// initials; this stays here to mirror the view column byte-for-byte.
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case firstName = "first_name"
        case avatarUrl = "avatar_url"
    }
}
