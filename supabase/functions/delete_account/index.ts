// delete_account — App Store 5.1.1(v) + DPDP erasure. Two-step server flow:
// grace-mark now (this function), hard-purge later (Phase 2 pg_cron job).
// Input: { "confirm": true }. Identity from the verified JWT only — any id in
// the body is ignored, so a caller can only ever mark themselves.

import { serveFn } from "../_shared/envelope.ts";
import { AppError, readJson } from "../_shared/http.ts";

const GRACE_DAYS = 30;

serveFn(
  {
    fnName: "delete_account",
    action: "account_delete_request",
    limits: [
      { scope: "user", granularity: "day", limit: 3 },
      { scope: "ip", granularity: "hour", limit: 10 },
    ],
  },
  async ({ callerId, rawJwt, req, service }) => {
    const body = await readJson(req);
    if (body.confirm !== true) {
      throw new AppError(400, "not_confirmed");
    }
    const deviceId = typeof body.device_id === "string"
      ? body.device_id.slice(0, 128)
      : undefined;

    // Current grace state — idempotent while already pending.
    const { data: existing, error: readErr } = await service
      .from("users")
      .select("deletion_requested_at")
      .eq("id", callerId)
      .maybeSingle();
    if (readErr) throw readErr;

    let requestedAt: string | null =
      (existing?.deletion_requested_at as string | null) ?? null;

    if (requestedAt === null) {
      const nowIso = new Date().toISOString();
      const { data: upd, error: updErr } = await service
        .from("users")
        .update({ deletion_requested_at: nowIso })
        .eq("id", callerId)
        .is("deletion_requested_at", null) // guard against a concurrent double-mark
        .select("deletion_requested_at")
        .maybeSingle();
      if (updErr) throw updErr;
      requestedAt = (upd?.deletion_requested_at as string | null) ?? nowIso;

      // Invalidate all sessions/refresh tokens for this user (auth trust
      // boundary — not shortened). Uses the caller's own verified token, global
      // scope. Best-effort: the grace mark is the source of truth, so a
      // transient auth-API hiccup must not strand a confirmed deletion request.
      try {
        await service.auth.admin.signOut(rawJwt, "global");
      } catch (_) {
        // ponytail: session invalidation is best-effort in Phase 1 — the nightly
        //   purge job (Phase 2) re-verifies and revokes on hard-delete; add a
        //   retry/DLQ here if the admin API proves flaky under load.
        console.error("[delete_account] global sign-out failed");
      }
    }

    const purgeAfter = new Date(
      new Date(requestedAt).getTime() + GRACE_DAYS * 86_400_000,
    ).toISOString();

    return {
      status: 200,
      body: { status: "pending_deletion", purge_after: purgeAfter },
      meta: { outcome: "success", ...(deviceId ? { device_id: deviceId } : {}) },
    };
  },
);
