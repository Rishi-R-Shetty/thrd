// rsvp_event (Phase 2, Artifact B §4) — the ONLY write path to `tickets` for
// free events. Identity is the verified JWT sub; the body carries only the
// event id and the action. Capacity and waitlist placement are decided INSIDE
// one Postgres transaction (`rsvp_event_tx`, SELECT … FOR UPDATE on the event
// row) — a client-supplied count is never trusted, and two callers racing the
// last seat resolve to exactly one `going` + one `waitlist` (row lock).
//
// The transactional core lives in SQL (migration 0004) because the supabase-js
// PostgREST surface issues single statements — it cannot hold a row lock across
// the read-decide-write sequence. The function runs SECURITY INVOKER as
// service_role under the column-scoped grants in 0004 (D5), so the RPC is a
// transaction boundary, not a second authorization layer: authorization is the
// JWT check in the envelope, and `p_user_id` is the already-verified caller id.

import { serveFn } from "../_shared/envelope.ts";
import { AppError, readJson, UUID_RE } from "../_shared/http.ts";

const ACTIONS = new Set(["rsvp", "cancel"]);

// The RPC returns a discriminated result so the function maps to stable codes
// without any SQL/schema detail crossing the boundary.
interface TxResult {
  result: "ok" | "not_found" | "event_not_open" | "verification_required";
  status?: "going" | "waitlist" | "cancelled";
  rsvp_count?: number;
}

serveFn(
  {
    fnName: "rsvp_event",
    action: "rsvp", // default; the cancel path overrides to "rsvp_cancel"
    limits: [
      { scope: "user", granularity: "hour", limit: 30 },
      { scope: "ip", granularity: "hour", limit: 60 },
    ],
  },
  async ({ callerId, req, service }) => {
    const body = await readJson(req);
    const action = body.action;
    const eventId = body.event_id;

    if (typeof action !== "string" || !ACTIONS.has(action)) {
      throw new AppError(400, "invalid_action");
    }
    // rsvp → "rsvp", cancel → "rsvp_cancel" (audit action, Artifact B §4).
    const auditAction = action === "cancel" ? "rsvp_cancel" : "rsvp";

    // A malformed event id can't name a real row → treat as unknown → 404,
    // the same code a valid-but-nonexistent id returns (no existence oracle,
    // and there is no `invalid_event` code in the spec).
    if (typeof eventId !== "string" || !UUID_RE.test(eventId)) {
      throw new AppError(404, "not_found", {}, auditAction);
    }

    // All authorization the RPC performs is server-side: it re-reads the
    // event's status/starts_at/price/capacity under the row lock and the
    // caller's verification_status — none of it comes from the request body.
    const { data, error } = await service.rpc("rsvp_event_tx", {
      p_event_id: eventId,
      p_user_id: callerId, // verified JWT sub; never from the body
      p_action: action,
    });
    if (error) throw error; // → 500 internal (never leaks SQL/schema)

    const tx = data as TxResult;
    switch (tx.result) {
      case "ok":
        return {
          status: 200,
          body: { status: tx.status, rsvp_count: tx.rsvp_count },
          action: auditAction,
          meta: {
            outcome: "success",
            event_id: eventId,
            resulting_status: tx.status,
          },
        };
      case "not_found":
        // Drafts and unknown ids are indistinguishable here (no draft oracle).
        throw new AppError(404, "not_found", { event_id: eventId }, auditAction);
      case "event_not_open":
        // Past / cancelled / completed / paid (paid is Phase 3).
        throw new AppError(
          400,
          "event_not_open",
          { event_id: eventId },
          auditAction,
        );
      case "verification_required":
        // Tier-0 cap (threat-model Layer 3): unverified callers may RSVP only
        // to free events with capacity ≤ 20.
        throw new AppError(
          403,
          "verification_required",
          { event_id: eventId },
          auditAction,
        );
      default:
        // Unreachable unless the RPC contract drifts — fail closed, opaque 500.
        throw new AppError(500, "internal", { event_id: eventId }, auditAction);
    }
  },
);
