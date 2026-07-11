// manage_block (D4) — the only write path to `blocks`. Blocking affects another
// user, so it runs here per threat-model rule 8. blocker_id is the verified JWT
// sub; `user_id` in the body is the target only. Success shape is identical
// whether or not state changed — the block state is never leaked back, and the
// target can never detect the block through this API's responses.

import { serveFn } from "../_shared/envelope.ts";
import { AppError, readJson, UUID_RE } from "../_shared/http.ts";

const ACTIONS = new Set(["block", "unblock"]);

serveFn(
  {
    fnName: "manage_block",
    action: "block", // default; overridden to "unblock" per invocation below
    limits: [
      { scope: "user", granularity: "hour", limit: 20, suffix: "h" },
      { scope: "user", granularity: "day", limit: 100, suffix: "d" },
      { scope: "ip", granularity: "hour", limit: 30 },
    ],
  },
  async ({ callerId, req, service }) => {
    const body = await readJson(req);
    const action = body.action;
    const targetId = body.user_id;

    if (typeof action !== "string" || !ACTIONS.has(action)) {
      throw new AppError(400, "invalid_action");
    }
    if (typeof targetId !== "string" || !UUID_RE.test(targetId)) {
      throw new AppError(400, "invalid_target", {}, action);
    }
    // Self-block rejected.
    if (targetId === callerId) {
      throw new AppError(400, "invalid_target", { target: targetId }, action);
    }

    // Target must exist. A missing target user → 404 (this reveals only user
    // existence, already discoverable via public_profiles — not block state).
    const { data: target, error: tErr } = await service
      .from("users")
      .select("id")
      .eq("id", targetId)
      .maybeSingle();
    if (tErr) throw tErr;
    if (target === null) {
      throw new AppError(404, "not_found", { target: targetId }, action);
    }

    if (action === "block") {
      // Idempotent: re-blocking is a no-op (ON CONFLICT DO NOTHING).
      const { error } = await service
        .from("blocks")
        .upsert(
          { blocker_id: callerId, blocked_id: targetId },
          { onConflict: "blocker_id,blocked_id", ignoreDuplicates: true },
        );
      if (error) throw error;
    } else {
      // Idempotent: deleting an absent row affects 0 rows and still succeeds.
      const { error } = await service
        .from("blocks")
        .delete()
        .eq("blocker_id", callerId)
        .eq("blocked_id", targetId);
      if (error) throw error;
    }

    // Identical success shape regardless of prior state (no leak).
    return {
      status: 200,
      body: { status: "ok" },
      action,
      meta: { outcome: "success", target: targetId },
    };
  },
);
