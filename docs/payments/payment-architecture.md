# Payment & Ticketing Architecture — Decision Doc

**Status:** DRAFT for user decision · **Date:** 2026-07-18 · **Owner:** orchestrator (Fable-priority #4)
**Feeds:** Phase 3 Wave B task **T34** (paid ticketing + KYC gate + refund flow), which is **held** pending this decision + the paid-dependency sign-off.
**Sources:** `docs/compliance/app-store-plan.md` §3.1.1 / §3.2 / §6 · `docs/security/threat-model.md` Layer 8 (payments) + Tier-5 (RBI/DPDP) · PRD §4 Phase 3 ("paid ticketing via StoreKit 2 / payment link, regulatory-dependent") · launch region Bengaluru + Mumbai (India).

---

## 1. The decision in one paragraph

**Recommendation: Razorpay as the external payment processor for paid event tickets, with StoreKit 2 (IAP) reserved strictly for any future in-app digital goods.** Event tickets to real-world, in-person events are a **physical service**, which Apple Guideline 3.1.1 explicitly permits to use an external processor (no IAP, no 15–30% Apple cut). Among external processors, Razorpay fits the India-first launch best: native INR settlement, UPI/RuPay/netbanking coverage that Indian attendees actually use, RBI-compliant tokenization and a route to payouts for hosts (RazorpayX / Route). Stripe is the fallback / international-expansion path. IAP is **not** an option for tickets and would in fact risk rejection if misapplied. This keeps us in **PCI SAQ-A** scope (we never touch card data) and lets the ticketing economics work.

---

## 2. The Guideline 3.1.1 boundary (why tickets are NOT IAP)

Apple's rule (app-store-plan §3.1.1), restated:

- **Digital content/services consumed inside the app → must use IAP** (Apple takes 15–30%).
- **Physical goods or services delivered outside the app → may use an external processor** (Stripe/Razorpay), no Apple cut.

**A ticket to a real-world, in-person event is a physical service.** It is consumed at a cafe/park/venue, not on the phone. This is the same category as Airbnb stays, ClassPass classes, and event tickets on Eventbrite — all external-payment. So paid tickets go through Razorpay/Stripe, and this is what makes the ticketing economics viable (a ₹300 book-club ticket keeps ~₹291 after processor fees instead of ~₹210–255 after an Apple cut).

**The lines we must NOT cross (each would force IAP, per §3.1.1 "boundary cases"):**

| Flow | Classification | Processor |
|---|---|---|
| Paid ticket to an in-person event | Physical service | **External (Razorpay)** ✅ |
| "Premium membership" for the app (unlimited RSVPs, etc.) | Digital service, in-app | **IAP** ❌ (avoid at launch) |
| "Boost my community in discovery" | Digital service, in-app | **IAP** ❌ (avoid at launch) |
| Digital gifts between users | Digital good | **IAP** ❌ (avoid at launch) |
| Tips to a host for a specific in-person event | Ambiguous — Apple has flagged similar | **Avoid at launch** (§3.1.1) |

**Rule of thumb (app-store-plan §3.1.1):** *if it's paid and it happens on your phone → IAP; if it's paid and it happens at a cafe → external.* Launch ships **only** the "happens at a cafe" case. No IAP-eligible flows at launch (matches the Review-Notes line already drafted in app-store-plan §6: "No in-app subscriptions, digital goods, or IAP-eligible content at launch").

**Anti-steering nuance (post-2022/2025 rulings):** Apple has been forced to allow apps to link out to external purchase flows in more regions, but relying on that is fragile. Our flow doesn't need it — a physical-service ticket can take payment inline via the processor SDK without an IAP or an external-link workaround. Keep the purchase UI free of language that "steers away from IAP" (there is no IAP to steer from), and keep a one-line Review-Notes explanation so a reviewer doesn't misread a paid ticket as digital content (§6 already covers this).

---

## 3. Processor comparison (external options)

| Criterion | **Razorpay** (rec.) | **Stripe** (fallback) | **StoreKit/IAP** (rejected for tickets) |
|---|---|---|---|
| Allowed for in-person tickets by Apple 3.1.1 | ✅ | ✅ | ❌ (physical service ≠ IAP; also forfeits ~30%) |
| India settlement (INR) | ✅ native | ⚠️ Stripe India exists but historically invite-gated / less mature for domestic payouts | n/a |
| UPI / RuPay / netbanking (what Indian users pay with) | ✅ first-class | ⚠️ partial | n/a |
| RBI card tokenization mandate (no PAN storage) | ✅ built-in | ✅ | n/a |
| Host payouts (marketplace/split) | ✅ RazorpayX / Route | ✅ Connect (mature, but India payouts weaker) | n/a |
| iOS SDK + PrivacyManifest | ✅ (verify `.xcprivacy` — app-store-plan §3 flags Razorpay manifest as "verify") | ✅ (manifest verified) | ✅ |
| PCI scope | SAQ-A (SDK returns a token) | SAQ-A | n/a |
| Chargeback/refund tooling | ✅ | ✅ (best-in-class) | n/a |
| International expansion later | ⚠️ India-centric | ✅ global | n/a |

**Why Razorpay over Stripe for launch:** both satisfy Apple. The tie-breaker is the launch region — Bengaluru + Mumbai attendees pay by UPI far more than by card, domestic INR settlement and host payouts are smoother on Razorpay, and RBI tokenization is native. **Choose Stripe instead if** near-term plans include non-India cities (Stripe's global coverage + Connect payouts win there). This is a reversible processor choice behind our own `purchase_ticket` Edge Function boundary (§5), so switching later is a contained change, not a rewrite.

---

## 4. Non-negotiable security constraints (threat-model Layer 8) — apply regardless of processor

1. **Never touch card data.** Use the processor's SDK/checkout that returns only a token. **PCI SAQ-A** scope only. No PAN in our DB, logs, or Edge Functions.
2. **Server-side price verification.** Client sends `event_id` (+ occurrence id for a series, per D-recurrence); the server looks up `events.price`. **Client-supplied price is ignored** (threat-model rule 3; audit discipline — same as capacity in `rsvp_event`).
3. **Capacity + payment intent in one transaction.** Validate capacity server-side (never trust client counts), create ticket + payment intent atomically — mirrors the `rsvp_event_tx` `FOR UPDATE` pattern already shipped.
4. **Payout only to tier-2 (KYC-verified) hosts** with bank + tax details. Never pay out to a tier-1 or unverified host. KYC via a third-party (Onfido / HyperVerge in India) — we store only pass/fail + a reference hash, never the ID scans (threat-model Layer 3).
5. **Refund + chargeback flow from day one.** Chargeback abuse (buy → attend → chargeback) is a known vector; build the refund path and a chargeback-handling webhook at launch, not later.
6. **Signed QR tickets** (already specced for T31): short-TTL JWT tied to `ticket_id+event_id+user_id`, valid only in the event window — a *paid* ticket is still checked in through the same signed-QR path.
7. **RBI/DPDP (Tier-5):** card tokenization mandate honored by the processor; no PAN storage; payment metadata retention within the DPDP purge rules (a purged user's payment references re-keyed like other audit rows — extends the D12 erasure work).

---

## 5. Where this lands in the schema + Edge Functions (T34 preview — not built yet)

Behind our own boundary so the processor is swappable:

- **`purchase_ticket` Edge Function** (Artifact B stub → full spec in T34): envelope as usual; server looks up price from `events`, checks capacity in a transaction, creates the processor payment intent, records `tickets.type='paid'` with the processor reference; returns the client secret/token for the SDK to complete. **Price/capacity never trusted from the client.**
- **`refund_ticket` Edge Function**: host- or policy-initiated; reverses via the processor; updates ticket status; audited.
- **Processor webhook receiver** (payment succeeded / failed / disputed): idempotent, signature-verified (the processor's webhook secret in a `THRD_` env var), reconciles ticket state; handles chargebacks.
- **Migration:** payment/payout columns (processor refs, payout status), a `host_payout_account` gated on tier-2 KYC, column-scoped `service_role` grants (D5). `tickets.qr_code_token` (currently a bare stub — see the Phase-2 audit F4) gets its issuance here.
- **KYC:** a verification-workflow surface writing `users.verification_status='id_verified'` + a reference hash only.

All of this is **T34 scope in Phase 3 Wave B**, which stays **held** until: (a) you confirm the processor (Razorpay vs Stripe), and (b) the paid dependency + real-world account setup (processor merchant account, KYC provider contract) are in place — you flagged both as external logistics.

---

## 6. What I need from you to unblock T34

1. **Processor choice:** Razorpay (recommended, India-first) or Stripe (if international is near-term). *This is a paid-dependency + tech-stack decision → your sign-off per CLAUDE.md decision authority.*
2. **KYC provider:** Onfido or HyperVerge (both India-capable) — also a paid dependency.
3. **Account setup** (external logistics, your side): processor merchant account + API keys (kept as `THRD_` secrets, never in the repo), KYC provider contract.

Until then, Phase 3 Wave A (T22–T31) proceeds without any payment dependency — the PRD exit criterion (recurring event, RSVP, check-in) is all free-tier and needs none of this.

---

## 7. Open decisions to log once you choose

- **D-payments-1:** external processor = Razorpay|Stripe (paid dependency, user sign-off).
- **D-payments-2:** KYC provider = Onfido|HyperVerge (paid dependency).
- **D-payments-3:** launch monetization surface = paid tickets only; no IAP-eligible flows (premium/boosts/gifts/tips) at launch (§3.1.1 boundary discipline).
