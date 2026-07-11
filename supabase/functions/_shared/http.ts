// Stable, opaque request/response helpers. Error bodies are exactly
// {"error":"<code>"} — no schema names, SQL, stack traces, or existence
// oracles ever leave this boundary.

export type Json = Record<string, unknown>;

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

export function ok(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export function err(status: number, code: string): Response {
  return new Response(JSON.stringify({ error: code }), { status, headers: JSON_HEADERS });
}

// Typed, throwable error the envelope maps to an opaque response + audit outcome.
// `meta` is merged into the audit row (not the client response). `action`
// optionally overrides the audited action (manage_block logs block vs unblock).
export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    public readonly meta: Json = {},
    public readonly action?: string,
  ) {
    super(code);
  }
}

export function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("x-real-ip")?.trim() || "unknown";
}

export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization");
  if (!h) return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

// Body is untrusted input. Never throws — a malformed/empty body yields {}.
export async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    return b !== null && typeof b === "object" ? b as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
