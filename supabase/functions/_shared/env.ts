// Fail-fast access to the secrets the edge envelope needs. Secrets come from
// the Edge Function runtime env ONLY — never hardcoded, never returned to a
// client, never logged. The error names the missing var, never its value.

export function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (v === undefined || v.length === 0) {
    throw new Error(`missing_env:${name}`);
  }
  return v;
}

// Auto-injected by the Supabase Edge runtime.
export const supabaseUrl = (): string => requireEnv("SUPABASE_URL");
export const serviceRoleKey = (): string => requireEnv("SUPABASE_SERVICE_ROLE_KEY");

// The project JWT secret used to verify caller tokens. Provided to the runtime
// via `--env-file` locally and `supabase secrets set THRD_JWT_SECRET=…` in
// deployed environments. It is NOT auto-injected, and the runtime refuses any
// var name starting with SUPABASE_ from an env file — hence the THRD_ prefix.
export const jwtSecret = (): string => requireEnv("THRD_JWT_SECRET");
