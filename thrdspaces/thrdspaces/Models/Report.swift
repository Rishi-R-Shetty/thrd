//
//  Report.swift
//  ThrdSpaces — Models
//
//  Mirrors `public.reports` (migration 0001) byte-for-byte via snake_case
//  CodingKeys. Decodable only — reports have ZERO client grants; the only
//  write path is the `submit_report` Edge Function (service_role,
//  BYPASSRLS). This type exists for host-side review surfaces, not client
//  inserts.
//

import Foundation

enum ReportSubject: String, Decodable, CaseIterable {
    case user, event, community, message
}

enum ReportReason: String, Decodable, CaseIterable {
    case safety, harassment, spam, other
}

enum ReportStatus: String, Decodable, CaseIterable {
    case open, reviewed, actioned
}

struct Report: Identifiable, Decodable, Equatable {
    let id: UUID
    let reporterId: UUID
    let subjectType: ReportSubject
    let subjectId: UUID
    let reason: ReportReason
    let detail: String?
    let status: ReportStatus
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case reporterId = "reporter_id"
        case subjectType = "subject_type"
        case subjectId = "subject_id"
        case reason
        case detail
        case status
        case createdAt = "created_at"
    }
}
