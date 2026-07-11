// Server-side verification of Supabase auth JWTs. The signature is verified
// with the project JWT secret using the platform Web Crypto HMAC primitive
// (constant-time) BEFORE any claim is parsed or trusted. Identity for
// authorization is derived only from a token that passes this function.
//
// ponytail: symmetric HS256 verification — matches the local/legacy Supabase
//   signing scheme (auth JWTs are HS256 over the shared JWT secret). Upgrade to
//   asymmetric JWKS verification if/when the project adopts rotating signing
//   keys (auth.signing_keys) — swap importKey + verify for a JWKS fetch/cache.

import { UUID_RE } from "./http.ts";

export interface VerifiedClaims {
  sub: string;
}

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function verifyJwt(
  token: string,
  secret: string,
): Promise<VerifiedClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [headerB64, payloadB64, sigB64] = parts;

  // 1. Signature must verify before anything else is read from the token.
  let sig: Uint8Array;
  try {
    sig = b64urlToBytes(sigB64);
  } catch {
    return null;
  }
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
  } catch {
    return null;
  }
  const signed = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const valid = await crypto.subtle.verify("HMAC", key, sig, signed);
  if (!valid) return null;

  // 2. Parse header + payload only now that the signature is trusted.
  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlToBytes(headerB64)));
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(payloadB64)));
  } catch {
    return null;
  }

  // 3. Reject anything but HS256 (blocks an alg:"none" downgrade).
  if (header.alg !== "HS256") return null;

  // 4. Temporal + role + subject checks on the now-trusted claims.
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp === "number" && payload.exp <= now) return null;
  if (typeof payload.nbf === "number" && payload.nbf > now) return null;
  if (payload.role !== "authenticated") return null;

  const sub = payload.sub;
  if (typeof sub !== "string" || !UUID_RE.test(sub)) return null;

  return { sub };
}
