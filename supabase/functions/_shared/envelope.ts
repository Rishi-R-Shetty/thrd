// The common Edge Function envelope required by every privileged function
// (Artifact B / threat-model Layer 5). Order is fixed and non-negotiable:
//
//   1. kill switch (feature_flags)   → 503 unavailable
//   2. JWT verify (identity source)  → 401 unauthorized
//   3. rate limit (per-user + IP)    → 429 rate_limited
//   4. validate + effect (handler)   → handler-defined
//   5. audit  (EVERY invocation, success or failure, one row)
//
// Identity used for authorization comes ONLY from the verified JWT sub. Request
// bodies never carry an identity. All DB access is via the service client
// (PostgREST method calls — parameterized, no SQL strings). The service-role
// key comes from env and never appears in a response or an audit row.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import {
  AppError,
  bearerToken,
  clientIp,
  err,
  Json,
  ok,
} from "./http.ts";
import { verifyJwt } from "./jwt.ts";
import { jwtSecret, serviceRoleKey, supabaseUrl } from "./env.ts";

type ServiceClient = ReturnType<typeof createClient>;

export interface RateRule {
  scope: "user" | "ip";
  granularity: "hour" | "day";
  limit: number;
  suffix?: string; // disambiguates multiple windows on the same scope
}

export interface FnConfig {
  fnName: string; // feature-flag key + rate-limit namespace
  action: string; // default audit_log.action value
  limits: RateRule[];
}

export interface Ctx {
  callerId: string; // verified JWT sub — the ONLY authorization identity
  rawJwt: string; // the verified token, for admin API calls (e.g. global sign-out)
  ip: string;
  req: Request;
  service: ServiceClient;
}

export interface HandlerResult {
  status: number;
  body: Json;
  meta?: Json; // merged into the audit row; `outcome` inside it overrides "success"
  action?: string; // overrides FnConfig.action for this invocation's audit
}

export type Handler = (ctx: Ctx) => Promise<HandlerResult>;

async function killSwitchEnabled(
  service: ServiceClient,
  fnName: string,
): Promise<boolean> {
  const { data, error } = await service
    .from("feature_flags")
    .select("enabled")
    .eq("key", `fn:${fnName}`)
    .maybeSingle();
  if (error) throw error; // DB unreachable → surfaces as 500 internal
  if (data === null) return true; // no explicit flag → operate; disabling is opt-in
  return data.enabled === true;
}

async function withinRateLimits(
  service: ServiceClient,
  config: FnConfig,
  callerId: string,
  ip: string,
): Promise<boolean> {
  const checks = config.limits.map((r) => ({
    key: `${config.fnName}:${r.scope}:${r.scope === "user" ? callerId : ip}` +
      (r.suffix ? `:${r.suffix}` : ""),
    granularity: r.granularity,
    limit: r.limit,
  }));
  const { data, error } = await service.rpc("consume_rate_limit", {
    p_checks: checks,
  });
  if (error) throw error;
  return data === true;
}

export function serveFn(config: FnConfig, handler: Handler): void {
  Deno.serve(async (req) => {
    // One service client per request. Service-role key from env only.
    const service = createClient(supabaseUrl(), serviceRoleKey(), {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    let callerId: string | null = null;
    let outcome = "internal";
    let auditAction = config.action;
    let extraMeta: Json = {};

    try {
      // 1. Kill switch first.
      if (!(await killSwitchEnabled(service, config.fnName))) {
        outcome = "unavailable";
        return err(503, "unavailable");
      }

      // 2. JWT verify. Identity comes ONLY from the verified token.
      const token = bearerToken(req);
      const claims = token ? await verifyJwt(token, jwtSecret()) : null;
      if (!claims) {
        outcome = "unauthorized";
        return err(401, "unauthorized");
      }
      callerId = claims.sub;
      const ip = clientIp(req);

      // 3. Rate limit (per-user and per-IP) before any effect.
      if (!(await withinRateLimits(service, config, callerId, ip))) {
        outcome = "rate_limited";
        return err(429, "rate_limited");
      }

      // 4. Validate + effect. Identity is fixed above; the handler never
      //    re-derives it from the body.
      const result = await handler({
        callerId,
        rawJwt: token!,
        ip,
        req,
        service,
      });

      auditAction = result.action ?? config.action;
      if (result.meta) {
        const { outcome: metaOutcome, ...rest } = result.meta;
        outcome = (metaOutcome as string) ?? "success";
        extraMeta = rest;
      } else {
        outcome = "success";
      }
      return ok(result.status, result.body);
    } catch (e) {
      if (e instanceof AppError) {
        outcome = e.code;
        extraMeta = e.meta;
        auditAction = e.action ?? config.action;
        return err(e.status, e.code);
      }
      // Never leak internals to the client. Log message only (no stack, no
      // secret) for server-side debugging.
      outcome = "internal";
      console.error(`[${config.fnName}]`, e instanceof Error ? e.message : "unknown");
      return err(500, "internal");
    } finally {
      // 5. Audit only IDENTIFIED invocations — one row, success or failure.
      //    Unauthenticated (401) and pre-auth kill-switch (503) rejections have
      //    no callerId; DB-writing them would let an anonymous caller (anyone
      //    holding the public anon key that passes the gateway) grow audit_log
      //    without bound — Tier-4 cost amplification (amended Artifact B item 5).
      //    Those are console-logged only. Audit failures never change the
      //    response the caller already received.
      if (callerId !== null) {
        try {
          await service.from("audit_log").insert({
            user_id: callerId,
            action: auditAction,
            metadata: { outcome, ...extraMeta },
          });
        } catch (_) {
          console.error(`[${config.fnName}] audit write failed`);
        }
      } else {
        console.error(
          `[${config.fnName}] unidentified invocation outcome=${outcome} ip=${clientIp(req)}`,
        );
      }
    }
  });
}
