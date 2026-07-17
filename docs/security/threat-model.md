# Thrd Spaces — Security Architecture & Threat Model

**Scope:** iOS client (Swift/SwiftUI) + Supabase backend + Edge Functions + third-party integrations (payments, ID verification, push).
**Version:** v1.0 · **Owner:** to be assigned before Phase 1.

---

## 1. Threat model — what we are actually defending against

Ranked by severity, not by likelihood. A social platform that facilitates real-world meetups has an unusual top-of-stack: physical-safety incidents are more costly than data breaches.

### Tier 1 — Physical-world harm
- **Predator targeting minors or vulnerable users at events.** An adult host runs a "book club" designed to isolate a specific person.
- **Stalking via location data.** Attacker uses attendee lists + event locations to build a target's movement pattern.
- **Fake event / lure attack.** Attacker creates a plausible community, gains trust, uses first meeting to commit assault or robbery.
- **Doxxing.** Attacker cross-references profile fields (interests + neighborhood + attended events) to identify and target a user.

### Tier 2 — Account & data compromise
- **Account takeover via Sign in with Apple relay abuse, session token theft, or phone-OTP interception.**
- **Mass account creation for spam, scam events, or scalping tickets.**
- **PII exfiltration** — attendee lists, DM history, verified-identity data.
- **Payment fraud** — stolen cards used to buy tickets, then chargeback.

### Tier 3 — Content & platform integrity
- **CSAM upload** (photo fields on profile, event covers, chat images). Legally catastrophic if not caught.
- **Coordinated harassment via chat and community boards.**
- **Illegal-activity coordination** (drug sales, unlicensed gambling, extremist recruitment).
- **Recommendation gaming** — hosts inflating attendance to game the ranking algorithm.

### Tier 4 — Infrastructure
- **Supabase service-role key leak** — game over if it lands in the iOS bundle or a public repo.
- **RLS bypass** via unauthenticated Postgres role or misconfigured policy.
- **DDoS / cost-amplification attacks** on Edge Functions, storage bandwidth, or realtime channels.
- **Third-party supply chain** — a compromised SPM package shipping in the app.

### Tier 5 — Regulatory
- **India DPDP Act 2023 non-compliance** — most likely regulatory exposure given the launch region. Requires explicit consent, purpose limitation, breach notification (72h), and honoring erasure requests.
- **Payment regulation** — RBI rules on card storage (never store PAN), tokenization mandates.
- **App Store policy violations** (inadequate reporting/blocking, missing age gate) → app removal.

---

## 2. Defense-in-depth architecture

### Layer 1 — iOS client hardening

- **Keychain, never UserDefaults.** All auth tokens, refresh tokens, and verification receipts live in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **No secrets in the app bundle.** No Supabase service-role key, no third-party API keys with write access. Only the anon/public Supabase key ships in the binary; all privileged actions go through Edge Functions.
- **App Transport Security enforced.** No `NSAllowsArbitraryLoads`. Consider certificate pinning for the Supabase domain in Phase 3.
- **Jailbreak/tamper detection** — light touch (check for common jailbreak paths, block payment flow if detected). Do not brick the app; log and degrade gracefully.
- **Screen recording / screenshot blur** on sensitive views (ID verification, DMs with unverified users).
- **Deep link validation.** Every `thrdspaces://` link is verified against an allowlist and never triggers a state-changing action without a confirmation screen.
- **Rate limiting on the client** for expensive operations (RSVP, message send, report submit) — belt-and-suspenders with server-side limits.

### Layer 2 — Authentication

- **Sign in with Apple as primary.** Uses Apple's private-relay email; we never see the real address unless the user later verifies phone or email separately.
- **Phone OTP as fallback.** Rate-limited: max 3 OTP requests per phone per hour, 10 per IP per hour. Use Supabase Auth's built-in throttling; add a custom Edge Function guard if it proves insufficient.
- **Session tokens:** short-lived access token (1h), rotating refresh token (30d). Refresh rotation with reuse detection — if a refresh token is used twice, invalidate the whole session family.
- **Device binding.** Store a device fingerprint (not a hardware ID; a generated UUID in Keychain) tied to the session. Show "new device" notification and require re-auth for sensitive actions when it changes.
- **Sign in with Apple relay attack mitigation.** Verify `iss`, `aud`, `nonce` on the identity token server-side in an Edge Function; never trust the client's word for the identity claim.

### Layer 3 — Identity verification tiers

Three tiers, each unlocking specific capabilities:

| Tier | Verified | Unlocks |
|---|---|---|
| 0 — None | Just signed up | Browse, RSVP to free public events under capacity 20 |
| 1 — Phone | SMS OTP passed | Host, RSVP to any event, send DMs to users who accept them |
| 2 — Identity | KYC via third-party (Onfido/HyperVerge in India) | Verified badge, host paid events, host events at partner venues, receive payouts |

Verification data (ID scans) is **never stored by us** — it lives with the KYC provider; we store only the pass/fail result and a hash of the reference. Blast-radius reduction.

### Layer 4 — Row Level Security (Supabase Postgres)

RLS is the single most important control in this system. Every table gets policies; no table is ever left with RLS disabled, even during development. Rules:

- **Default deny.** Every table starts with `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` and zero policies, then adds explicit `SELECT`/`INSERT`/`UPDATE`/`DELETE` policies per role.
- **Never use the `service_role` key from the iOS client.** It bypasses RLS. It only exists in Edge Functions.
- **Test every policy with a "hostile user" test.** For each table, write a test that authenticates as user A and asserts user A cannot read/write user B's rows.
- **PostGIS location queries are coarsened.** Public queries snap to a geohash grid (~500m precision), not exact coordinates. Only the venue itself and confirmed attendees get exact coordinates, and only within 2 hours of event start.

Reference policies to write:

```sql
-- Users can only read their own full profile
CREATE POLICY "users_read_own" ON users FOR SELECT
  USING (auth.uid() = id);

-- Public profile view (limited columns) via a view, not the base table
CREATE VIEW public_profiles AS
  SELECT id, handle, display_name, avatar_url, interests
  FROM users
  WHERE profile_visibility = 'public';

-- Only hosts of an event can see the full attendee list
CREATE POLICY "attendee_list_hosts_only" ON tickets FOR SELECT
  USING (
    user_id = auth.uid()  -- your own ticket
    OR EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = tickets.event_id
      AND e.host_id = auth.uid()
    )
  );

-- Messages only visible to channel members
CREATE POLICY "messages_channel_members" ON messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM channel_members cm
      WHERE cm.channel_id = messages.channel_id
      AND cm.user_id = auth.uid()
    )
  );
```

### Layer 5 — Edge Functions for privileged operations

Anything that requires business-logic authorization (not just row ownership) goes through an Edge Function. Examples:

- Creating a paid event → verify the host is tier-2 verified, verify the venue accepts paid events, create the Stripe/Razorpay product atomically.
- Ticket purchase → validate capacity server-side (never trust the client's count), create ticket + payment intent in a transaction.
- Report submission → rate-limit per reporter, deduplicate against existing reports, enqueue for moderation.
- Ban action → propagate across users, tickets, community memberships, message channels in one transaction.

Every Edge Function:
- Verifies the JWT server-side (do not trust `auth.uid()` claims from the client).
- Logs the invoking user ID, action, and outcome to an audit table.
- Has a rate limit (per-user and per-IP).
- Has a kill switch (feature flag) that can be flipped without a deploy.

### Layer 6 — Content moderation

- **CSAM detection** on every image upload. Use PhotoDNA or Cloudflare's CSAM Scanning Tool at the storage-write path via a Storage Trigger → Edge Function. Positive hits: block upload, quarantine account, file NCMEC report (legally required in many jurisdictions).
- **First-line content classification.** Perspective API or open-source alternative for chat/community posts. Threshold-triggered soft warnings (auto-hide + report queue) rather than hard blocks — false positives are costly.
- **Report queue** with SLA: Tier-1 reports (physical safety, minors, CSAM) → 4h response. Tier-2 (harassment, spam) → 24h. Tier-3 (policy) → 72h.
- **Shadow-ban / soft-ban** as an alternative to hard bans — reduces ban-evasion signal.
- **Community moderators** (Phase 3) get scoped permissions: can remove posts from their community, cannot see PII of members beyond public profile.

### Layer 7 — Real-world safety features

These are product features, not just security controls — they're what make the app different:

- **First-meeting safety sheet.** Before your first event with a new host or in a new community, a bottom sheet appears: "Meet in a public space. Tell a friend where you're going. Share your live location with a trusted contact." Non-dismissable checkbox on first-time flow.
- **Live location sharing to trusted contacts** — deep-link into Apple's built-in Find My or ETA sharing, don't build our own.
- **Panic button on event detail** during the 2-hour window of an event — one-tap to the local emergency number and to your emergency contact with your location.
- **Age gate.** No under-18 accounts at launch. Age verification via KYC for tier-2. Auto-flag any account whose behavior suggests underage use (device settings, self-reported age mismatch, community reports).
- **Attendee list privacy.** Names and avatars only, no last names, no linked social handles. Reveal-on-approval friend requests instead of open discoverability.
- **Location minimization.** Home geohash stored at ~2km precision. Exact location only sent while actively browsing the map, never persisted server-side.
- **Blocked users are truly invisible.** Not just hidden from feeds — invisible from attendee lists, community members, chat previews. Reduces stalking vector.

### Layer 8 — Payments (ticketing)

- **Never touch card data.** Use Stripe Elements or Razorpay Checkout in a web view / native SDK that returns only a token. PCI SAQ-A scope only.
- **Server-side price verification.** Client sends `event_id`, server looks up price. Client-supplied price is ignored.
- **Refund and chargeback flow** built from day one — chargeback abuse (buy ticket, attend, chargeback) is a known vector.
- **Payout to hosts requires tier-2 verification + bank account + tax details.** Never payout to a tier-1 or unverified host.
- **Ticket QR codes** are signed JWTs with short TTL (valid only during event window), tied to `ticket_id + event_id + user_id`. Verified at check-in by the host's app.

### Layer 9 — Logging, monitoring, incident response

- **Audit log table** for security-relevant events: login, verification pass/fail, ban action, report submission, admin action. Immutable (insert-only, no update/delete policy).
- **Anomaly alerts:** spike in failed OTPs, new-device logins to old accounts, mass event creation, rapid RSVP-then-cancel patterns.
- **Runbook for compromised account:** invalidate all sessions, force password reset (or Sign in with Apple re-consent), notify user via out-of-band channel, freeze payouts.
- **Runbook for security incident:** who to call, what to preserve, DPDP breach notification timeline (72h to Data Protection Board of India), user notification template.
- **Data retention limits.** Chat messages: 2 years unless in an active moderation case. Location breadcrumbs: never persisted. Audit logs: 7 years. Deleted account data: purged within 30 days except where retention is legally required.

### Layer 10 — Regulatory compliance (India-first, extensible)

- **DPDP Act 2023 requirements:**
  - Explicit, granular consent at onboarding (interests, location, notifications, marketing — each separately).
  - Data Fiduciary registration (once user count triggers threshold).
  - Consent Manager integration when the ecosystem stabilizes.
  - User-facing consent dashboard in settings.
  - Erasure request flow: user requests → confirmed via out-of-band → 30-day purge with audit trail.
  - Breach notification: 72h to DPB, prompt notification to affected users.
- **Grievance officer** designated with public contact (required by law).
- **Age verification** for minors (currently prohibited by app rules; policy enforced by KYC).
- **App Store & Play Store policies:** in-app reporting on all content types, block within 24h of report validation, transparent T&C, clear age rating.

---

## 3. Secure-by-default coding rules for Opus/Sonnet subagents

Add these to `CLAUDE.md` so every generated file follows them:

1. Never write a Postgres table without an RLS policy. If unsure how to scope, escalate via Loop 5.
2. Never write iOS code that reads a secret from a plist, JSON file, or hardcoded string. Secrets come from Keychain or from server responses only.
3. Never trust a client-supplied field for authorization (`user_id`, `role`, `price`, `capacity_available`). The server derives these.
4. Never call the Supabase client with the `service_role` key from an iOS view or view-model. That key exists only in Edge Functions.
5. Never `SELECT *` from a table with PII. List columns explicitly so a schema change can't accidentally leak new columns.
6. Every user-provided string that goes into an SQL query uses parameterized queries. No string concatenation.
7. Every image upload path calls the CSAM-scan Edge Function before the image becomes queryable.
8. Every mutation that affects another user (invite, block, add-to-community) goes through an Edge Function, not direct table access.
9. Every new Edge Function includes: JWT verification, rate limit, audit log write, error handling that does not leak schema.
10. Every push notification body is sanitized — no message content in the notification for DMs (just "New message"), because notification content is visible on the lock screen.

---

## 4. Fable-produced deliverables (add to the July 12 window)

Add these three artifacts to the priority list. Estimated 3–4 hours of Fable time total. They belong before the schema (item 3), because the schema depends on them.

**Artifact A — RLS Policy Specification** (`docs/security/rls-policies.sql`)
Every table, every policy, every role. Includes the hostile-user test cases as pgTAP or plain SQL assertions.

**Artifact B — Edge Function Inventory** (`docs/security/edge-functions.md`)
Every privileged operation, its inputs, authorization rule, rate limit, audit log entry, and error responses. Fable is well-suited to this because it requires reasoning across all use cases at once.

**Artifact C — Threat Model & Incident Runbooks** (`docs/security/threat-model.md`, `docs/security/runbooks/*.md`)
Expanded version of Section 1 above, with STRIDE analysis per entity and runbooks for the top 10 incidents (account compromise, CSAM report, missing minor, host impersonation, DDoS, service-role leak, mass registration, chargeback wave, DPDP request, App Store takedown).

---

## 5. What ships in the MVP vs later

**Phase 1 (must-have):**
Sign in with Apple + phone OTP, RLS on all tables, Keychain for tokens, no secrets in bundle, basic report flow, age gate.

**Phase 2:**
Coarsened location queries, blocked-user invisibility, first-meeting safety sheet, panic button.

**Phase 3:**
CSAM scanning, moderation queue, community moderator scopes, KYC for paid hosting, refund flow.

**Phase 4:**
ML-assisted content classification, anomaly detection, recommendation-gaming defenses, certificate pinning, jailbreak degradation.

**Post-MVP:**
Full SOC 2 posture, bug bounty program, third-party pen test, DPDP Consent Manager integration.

---

## 6. What we are consciously not doing

Explicit non-goals prevent scope creep and false confidence.

- **We are not building our own ID verification.** Use a KYC provider.
- **We are not building our own payment processing.** Use Stripe or Razorpay.
- **We are not scanning DMs for content by default.** Reported DMs are reviewed; unreported DMs are private. Trade-off: some abuse goes undetected. Alternative would violate user trust and likely DPDP.
- **We are not doing behavioral biometrics or continuous authentication in v1.** Overkill for the threat model.
- **We are not going to try to prevent screenshots of public content.** iOS makes this impossible without breaking accessibility.
- **We are not building a decentralized or E2E-encrypted chat in v1.** Moderation requires server-side visibility for reported messages. If we go E2E later, the moderation model needs a full redesign.
