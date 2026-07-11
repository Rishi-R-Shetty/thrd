// submit_report — the Guideline 1.2 reporting path. Client access to `reports`
// is fully denied by RLS; this Edge Function (service_role) is the only write.
// reporter_id is the verified JWT sub — never carried in the body.

import { serveFn } from "../_shared/envelope.ts";
import { AppError, readJson, UUID_RE } from "../_shared/http.ts";

const SUBJECT_TYPES = new Set(["user", "event", "community", "message"]);
const REASONS = new Set(["safety", "harassment", "spam", "other"]);

// Map a subject_type to the table whose row must exist. `message` has no table
// in Phase 1, so message reports cannot be validated.
// ponytail: message-subject validation returns not_found until the messages
//   table lands (Phase 3 messaging) — Phase 1 UI only reports subject_type=user.
function subjectTable(type: string): string | null {
  switch (type) {
    case "user":
      return "users";
    case "event":
      return "events";
    case "community":
      return "communities";
    default:
      return null;
  }
}

serveFn(
  {
    fnName: "submit_report",
    action: "report_submit",
    limits: [
      { scope: "user", granularity: "hour", limit: 10, suffix: "h" },
      { scope: "user", granularity: "day", limit: 30, suffix: "d" },
      { scope: "ip", granularity: "hour", limit: 20 },
    ],
  },
  async ({ callerId, req, service }) => {
    const body = await readJson(req);
    const subjectType = body.subject_type;
    const subjectId = body.subject_id;
    const reason = body.reason;

    if (
      typeof subjectType !== "string" || !SUBJECT_TYPES.has(subjectType) ||
      typeof subjectId !== "string" || !UUID_RE.test(subjectId)
    ) {
      throw new AppError(400, "invalid_subject");
    }
    if (typeof reason !== "string" || !REASONS.has(reason)) {
      throw new AppError(400, "invalid_reason", {
        subject_type: subjectType,
        subject_id: subjectId,
      });
    }
    // Self-reports rejected (only a `user` subject can be the caller).
    if (subjectType === "user" && subjectId === callerId) {
      throw new AppError(400, "invalid_subject");
    }

    // detail: optional, ≤500. Clamp defensively (the DB CHECK also enforces 500).
    // ponytail: over-length detail is clamped, not rejected — the report sheet
    //   caps input at 500 and the spec defines no `invalid_detail` code; revisit
    //   if a dedicated validation code is added.
    let detail: string | null = null;
    if (body.detail != null) {
      if (typeof body.detail !== "string") {
        throw new AppError(400, "invalid_subject", {
          subject_type: subjectType,
          subject_id: subjectId,
        });
      }
      detail = body.detail.slice(0, 500);
    }

    // Subject must exist as a row of its type. Generic not_found — never reveal
    // "exists but hidden from you".
    const table = subjectTable(subjectType);
    let exists = false;
    if (table !== null) {
      const { data, error } = await service
        .from(table)
        .select("id")
        .eq("id", subjectId)
        .maybeSingle();
      if (error) throw error;
      exists = data !== null;
    }
    if (!exists) {
      throw new AppError(404, "not_found", {
        subject_type: subjectType,
        subject_id: subjectId,
        reason,
      });
    }

    // Dedupe: an existing OPEN report by this reporter on this subject returns
    // already_reported with no new row (report-spam vector).
    const { data: dupe, error: dupeErr } = await service
      .from("reports")
      .select("id")
      .eq("reporter_id", callerId)
      .eq("subject_type", subjectType)
      .eq("subject_id", subjectId)
      .eq("status", "open")
      .limit(1)
      .maybeSingle();
    if (dupeErr) throw dupeErr;
    if (dupe) {
      return {
        status: 200,
        body: { status: "already_reported" },
        meta: {
          outcome: "already_reported",
          subject_type: subjectType,
          subject_id: subjectId,
          reason,
        },
      };
    }

    const { error: insErr } = await service.from("reports").insert({
      reporter_id: callerId, // server-derived; body never supplies it
      subject_type: subjectType,
      subject_id: subjectId,
      reason,
      detail,
    });
    if (insErr) throw insErr;

    // Tier-1 safety reports get a distinct audit flag for the 4h-SLA queue.
    // ponytail: Phase 1 marks tier1 in audit metadata only — no email/queue
    //   integration yet (Phase 3 moderation queue wires the alert to the
    //   monitored support address).
    const tier1 = reason === "safety";

    return {
      status: 200,
      body: { status: "submitted" },
      meta: {
        outcome: "success",
        subject_type: subjectType,
        subject_id: subjectId,
        reason,
        ...(tier1 ? { tier1: true } : {}),
      },
    };
  },
);
