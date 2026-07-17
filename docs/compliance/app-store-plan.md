# Thrd Spaces — Apple App Store Compliance & Submission Plan

**Version:** v1.0 · **Target submission:** end of Phase 4 · **Guideline references:** App Review Guidelines as of July 2026 (updated Feb 6, 2026 for random/anonymous chat).

This document maps every App Store requirement onto our build plan. Sections marked **CRITICAL** are guidelines that will get us rejected outright if missed. Sections marked **REGIONAL** apply only to specific markets. Everything else is standard hygiene.

---

## 1. The five guidelines that will make or break us

Ranked by probability-of-rejection for this app category, based on Apple's published data and the specific risks Thrd Spaces carries.

### CRITICAL — Guideline 1.2: User-Generated Content
Apple's biggest single rejection driver for social apps. A UGC/social-networking app **must** include, verifiable inside the build:

1. A method to **filter objectionable material** before it's posted.
2. A **reporting mechanism** on every piece of user-generated content, with documented timely response.
3. The ability to **block abusive users** from the service.
4. **Published contact information** so users can reach us (email is fine, must be monitored).
5. **Terms of Use / EULA** the user agrees to, which prohibits the objectionable content categories.

Feb 2026 update: random/anonymous chat is explicitly under 1.2. Our chat is identity-tied — this is fine. But **DMs to strangers before mutual acceptance** would be treated as random chat by reviewers, so we default to accept-first-DM flow.

**Our compliance:** report, block, and EULA-accept are Phase 1 features. CSAM scan pipeline (from the security architecture) is the filter. Contact email published in the app's About/Help screen and in App Store Connect.

### CRITICAL — Guideline 1.4.1: Physical Harm
Reviewers are trained to flag apps where the app itself could facilitate real-world harm. Meetup apps are on this list. Rejections here are hard to recover from because they can lead to a full app takedown.

**Our compliance:** the physical-safety features in the security architecture (first-meeting safety sheet, panic button, blocked-user invisibility, no under-18 accounts at launch) are all Phase 2 features. They must be built, not just planned, before submission. Include a short section in Review Notes describing them so the reviewer can find them.

### CRITICAL — Guideline 4.8: Sign in with Apple
If we use any third-party login (Google, Facebook, etc.) as the primary account mechanism, we **must** also offer an equivalent alternative that: limits collection to name and email, allows the user to keep their email private, and doesn't collect app interactions for ads without consent. Sign in with Apple satisfies this exactly.

**Our compliance:** Sign in with Apple is our primary. Phone OTP is a fallback. We are compliant. Note: if we ever add "Sign in with Google," SwA must remain equally prominent and equally functional.

### CRITICAL — Guideline 5.1.1(v): Account Deletion
Any app that lets users create an account must let them **delete it in-app**. Not "email us to delete." Not "delete via website." Directly in the app. Deletion must remove the account and associated personal data (per our privacy policy), not just deactivate.

**Our compliance:** account-delete flow is a Phase 1 feature in the Profile → Settings tree. Deletion triggers a server-side purge job (30-day grace, then hard-delete of PII; keep audit-log references keyed by an anonymized user hash for legal retention). Must include a confirmation step and clear language about what gets deleted.

### CRITICAL — Guideline 2.1: App Completeness
Apple's own published data: **40% of unresolved review issues are here.** Crashes, placeholder content, features that require login the reviewer can't perform, features that depend on a backend that's down, TestFlight-style flows.

**Our compliance:** at submission time we must provide:
- A **demo account** with tier-2 verification pre-completed so the reviewer can access every feature including host-only ones.
- Seeded data in the reviewer's region: at least 5 nearby spaces, 3 upcoming events, 1 community they can join.
- **Backend uptime guarantee** during review window — Supabase project can't be paused or throttled.
- Review Notes explaining anything non-obvious (see Section 6).

---

## 2. Guideline-by-guideline plan for the rest

### Guideline 1.1: Objectionable Content
Zero tolerance for hate speech, glorified violence, defamatory content targeting protected groups. Our EULA must explicitly prohibit these; our moderation queue must action them.

Covered by the moderation plan in the security architecture. No additional work.

### Guideline 1.1.6: False Information / Fake Location
Prohibits fake location trackers and prank-call apps. We're not doing these. Worth noting only because location-permission review can flag apps if the location UI looks like it might be misused.

### Guideline 1.3: Kids Category
We are **not** listing in the Kids category. We are age-gating to 18+ at launch (per the security architecture). This means:
- App age rating in App Store Connect: **17+** (matches the meetup risk profile).
- No under-18 accounts. Enforced via KYC at tier-2 and via Declared Age Range API where available.

### Guideline 2.3.1: Accurate Metadata
The App Store listing must match what the app actually does. If we say "communities for book clubs, run clubs, and creative meetups," the reviewer must be able to find these on launch day.

**Our compliance:** the seeded data plan above. Screenshots must show real UI, not concept art. No "coming soon" features in screenshots.

### Guideline 2.5.13: Health/Safety Claims
We are not making medical or wellness claims. If we ever add "wellness sessions" as a community category — which the PRD mentions — the community descriptions must not claim therapeutic benefits.

### Guideline 3.1.1: In-App Purchase vs External Payment (important distinction)
This is where many social/event apps get tripped up. The rule:

- **Digital content or services consumed inside the app** → must use Apple In-App Purchase (IAP), and Apple takes 15–30%.
- **Physical goods or services delivered outside the app** → can use external payment (Stripe, Razorpay), no Apple cut.

**Event tickets to real-world in-person events are physical services.** They are explicitly permitted to use external payment processors. This is what unlocks our economics — a paid book-club ticket goes through Stripe/Razorpay, not IAP.

**Boundary cases to avoid:**
- If we ever add a "Premium membership" for the app itself (e.g. unlimited RSVPs, boost your community in discovery) → **that's IAP**, no exceptions.
- Selling "boosts" for community discovery → IAP.
- Digital gifts between users → IAP.
- Tips to hosts for a specific in-person event → likely external payment, but ambiguous; Apple has flagged similar flows before. Avoid at launch.

Rule of thumb for Phase 3: if it's paid and it happens on your phone, IAP. If it's paid and it happens at a cafe, external.

### Guideline 3.2: Business Model Clarity
Whatever monetization we choose (ticketing revenue share, host tools, etc.) must be transparent to users before they pay.

### Guideline 4.0: Design
Native iOS look and feel. SwiftUI gets us most of the way. Apple Human Interface Guidelines compliance. Dynamic Type support. VoiceOver labels. Dark mode. iPad support (Guideline 2.4.1 — iPhone apps should run on iPad whenever possible).

**Our compliance:** every UI task in the phase plans must include accessibility acceptance criteria (in the Opus builder prompt v2's non-negotiables). iPad support is a Phase 3 deliverable if we can spare the time, otherwise Phase 5 post-launch.

### Guideline 4.5.4: Push Notifications
Push must not be used for advertising, promotions, or direct marketing without explicit user opt-in beyond just accepting notifications. Notifications must not include the content of DMs on the lock screen (see the security architecture's rule 10).

**Our compliance:** notification categories are itemized (event reminders, RSVPs, community announcements, DM alerts). User can opt each in/out. No promotional pushes at launch. DM notifications show "New message from [handle]" only, not the message body.

### Guideline 5.1.1: Privacy — Data Collection & Storage
Comprehensive privacy policy required, linked in-app and in App Store Connect. Must accurately describe:
- What data we collect
- Why we collect it
- Who we share it with
- How long we retain it
- How users can access, correct, delete their data

**Our compliance:** the DPDP-aligned privacy policy from the security architecture covers this. Must be hosted on a stable URL before submission. Add a link in Profile → Settings.

### Guideline 5.1.2: Data Use and Sharing
- Cannot use data collected for one purpose (functionality) for another (advertising) without explicit consent.
- Third-party SDKs count. Every SDK that collects data must appear in the App Privacy Labels.

**Our compliance:** minimal SDK footprint. Supabase Swift SDK, Sign in with Apple, Apple MapKit, StoreKit 2 for potential IAP, Stripe/Razorpay SDK for external payments. Each has a known data-collection profile documented in privacy manifests.

### Guideline 5.1.5: Location Services
- Only use location for features that clearly benefit the user.
- Purpose strings in Info.plist must be truthful and specific.
- Request the minimum precision necessary.

**Our compliance:**
- `NSLocationWhenInUseUsageDescription`: "Thrd Spaces uses your location to show cafes, events, and communities near you."
- No background location. If we ever need it (unlikely), we need a very strong justification.
- Coarse precision (reduced-accuracy mode) for the map browse experience; precise only for turn-by-turn to a specific venue if we add that.
- The Location permission prompt appears after a value-first explanation screen (already in the onboarding flow).

### Guideline 5.6: Developer Code of Conduct
Manipulating reviews, review-bombing competitors, misleading users — all app-killing offenses. Ethical operating baseline; not a build-time concern.

---

## 3. Privacy Manifests (required, enforced strictly)

Since Spring 2024 and now strictly enforced. Every third-party SDK we bundle must include a privacy manifest declaring what data it collects and what "required reason APIs" it uses. Missing or mismatched manifests are a common rejection.

**Our SDK inventory and manifest status to verify:**
| SDK | Manifest status | Notes |
|---|---|---|
| Supabase Swift SDK | Verify at Phase 2 start | Community-maintained; check for `PrivacyInfo.xcprivacy` |
| Stripe iOS SDK | Verified | Well-maintained |
| Razorpay iOS SDK | Verify | Less consistent than Stripe historically |
| Sentry / crash reporter (if added) | Verified | |
| Any push service beyond APNs | Verify | |

**Our own privacy manifest** (`PrivacyInfo.xcprivacy` in the app target) must declare our use of any "required reason APIs" — the list includes UserDefaults, FileTimestamp, SystemBootTime, DiskSpace, ActiveKeyboards. Almost every app uses UserDefaults; declare the reason (e.g. `CA92.1` — access to store user preferences).

---

## 4. Age assurance & regional compliance

### Declared Age Range API (iOS 26+)
Apple's API returns a user's age category (under 13, 13–16, 16–18, 18+) without exposing exact birthdate. **Required in some regions, optional but useful elsewhere.**

**Where it's required:**
- **Australia, Brazil, Singapore:** App Store auto-blocks under-18s from downloading 17+ apps (which we are). We don't need to build extra flow for these; Apple handles it.
- **Louisiana (from July 1, 2026):** new Apple Accounts share age category with our app via the API.
- **Utah (from May 6, 2026):** same, plus stricter parental-consent rules for social features.
- **Texas (SB2420, effective Jan 1, 2026, currently contested in court):** similar requirements, but implementation is legally uncertain.

**Our implementation plan:**
- Integrate Declared Age Range API in Phase 1 (auth/onboarding).
- On app launch, call the API. If it returns under-18 in any region, block account creation with a friendly explainer.
- For regions where the API is not returned or the user opts not to share, fall back to our KYC-based verification (tier-2 only for hosting).
- Do not persist age data long-term. Query at decision points; use ephemerally.

### PermissionKit (Significant Change API)
Required when making "significant changes" to an app in regulated regions — parents must consent for children. We are 18+ only, so significant-change parental consent doesn't apply to us. Still worth being aware of if we ever expand.

### iOS 26 SDK requirement
**Since April 28, 2026, all new submissions must be built with the iOS 26 SDK.** Deployment target can be lower (e.g. iOS 17), but the SDK version at build time must be 26.

**Our compliance:** use Xcode 16.x or later. Set minimum deployment target to iOS 17.0 or iOS 18.0 (weighing SwiftUI feature availability against user coverage).

---

## 5. App Store Connect metadata plan

Metadata mistakes cause slow, avoidable rejections. Prepare this before Phase 4.

**App name:** "Thrd Spaces" (30 char limit — fits)
**Subtitle:** Short, benefit-oriented, keyword-relevant. Example: "Communities and events near you" (34 chars).
**Category:** Primary = Social Networking. Secondary = Lifestyle.
**Age rating:** 17+ (matches meetup risk profile, gives room for user-generated content, doesn't lock us into Kids Category constraints).
**Screenshots:** 6.5" iPhone screenshots minimum; 6.9" strongly recommended for iPhone 15/16 Pro Max. iPad optional if we ship iPad support. Show real UI, real content, no placeholder text.
**App Previews (video):** Optional but strongly recommended for social apps. Max 30 seconds each.
**Description:** Lead with the third-place concept. Emphasize community and offline connection. Do not exceed 4000 chars; the first 3 lines are what most users see.
**Keywords:** 100 chars total, comma-separated. Focus: `community, meetup, events, cafes, book club, run club, third place, nearby, social, hangout`.
**Support URL:** required, must resolve to a live page with actual support content. `support.thrdspaces.com` or a Notion/Linear public page works.
**Marketing URL:** optional but useful.
**Privacy Policy URL:** required, must resolve to the actual policy.
**App Privacy section:** must declare every data type collected and its purpose. Common mistake: forgetting to declare a data type that a bundled SDK collects. See Section 3.

---

## 6. Review Notes template

Reviewers work fast. Write Review Notes that answer their questions before they ask.

```
DEMO ACCOUNT
- Sign in with Apple: use the account [reviewer-specific credentials in App Store Connect]
- OR use the demo flow: on the Welcome screen, tap "For App Review" (hidden button, tap logo 5 times).
  This bypasses onboarding with a pre-verified Tier 2 account.

REGION FOR TESTING
- Simulate location: Bengaluru, India (12.9716, 77.5946). Seeded events and communities are available in this area.
- If reviewing from outside this region, the app will still function but with fewer nearby results.

USER-GENERATED CONTENT (Guideline 1.2)
- Report: tap ⋯ on any user profile, event, community, or message → Report.
- Block: profile screen → Block.
- Terms: Settings → Terms of Use (also shown at signup).
- Contact: support@thrdspaces.com (monitored during EU/US business hours).
- Moderation SLA: safety reports actioned within 4 hours; other reports within 24 hours.

REAL-WORLD SAFETY (Guideline 1.4.1)
- First-time attendees see a safety sheet before their first event.
- Panic button available on event detail during the 2h window around start time.
- Blocked users are invisible in attendee lists and community members.

PAYMENTS (Guideline 3.1)
- Paid event tickets use external payment processor (Stripe) for tickets to real-world in-person events, which is permitted for physical services.
- No in-app subscriptions, digital goods, or IAP-eligible content at launch.

LOCATION (Guideline 5.1.5)
- Location used only to show nearby spaces/events.
- No background location.
- Coarse precision by default; user can opt into precise from Settings.

ACCOUNT DELETION (Guideline 5.1.1)
- Settings → Account → Delete Account. Two-step confirmation. 30-day grace, then hard delete.

AGE ASSURANCE
- Declared Age Range API integrated. Under-18s blocked from account creation.
- All hosts of paid events go through third-party KYC (identity verification).

ANYTHING ELSE
- If any feature seems inaccessible, please contact us at ios-review@thrdspaces.com — we respond within 4 hours during weekdays.
```

---

## 7. Pre-submission checklist (72h before submission)

Run through this every time. Save to `docs/compliance/pre-submit-checklist.md` and check off each item.

**Build & metadata**
- [ ] Built with iOS 26+ SDK, Xcode current stable
- [ ] Version and build number incremented
- [ ] App name, subtitle, category, age rating correct in App Store Connect
- [ ] 6.5" and 6.9" screenshots uploaded, showing real UI
- [ ] Optional App Preview video uploaded (30s max)
- [ ] Description matches actual app; no unbuilt features mentioned
- [ ] Keywords under 100 chars
- [ ] Support URL, marketing URL, privacy policy URL all resolve

**Functionality (Guideline 2.1)**
- [ ] Fresh install on physical iPhone (latest OS) — no crashes on onboarding
- [ ] Sign in with Apple works end-to-end
- [ ] Phone OTP flow works with a real (non-Apple-review) number
- [ ] All 5 tabs render with seeded data
- [ ] Every screen has a functional back / dismiss action
- [ ] Every button that says "Coming soon" has been removed or gated
- [ ] Backend (Supabase) is on a paid tier, not paused, with capacity headroom

**UGC & moderation (Guideline 1.2)**
- [ ] Report action visible on every user profile, event, community, message
- [ ] Block action visible on every user profile
- [ ] Terms of Use accessible from Settings AND shown at signup
- [ ] Contact email displayed in Settings → About
- [ ] Moderation queue is staffed / has an assigned owner

**Privacy (Guideline 5.1)**
- [ ] Privacy policy URL live and accurate
- [ ] App Privacy labels in App Store Connect match what SDKs actually collect
- [ ] Privacy manifests present for all bundled SDKs
- [ ] Our own `PrivacyInfo.xcprivacy` declares required-reason API usage
- [ ] Location usage description in Info.plist is specific and truthful
- [ ] Notification permission prompt has clear explainer before the system dialog

**Safety (Guideline 1.4.1)**
- [ ] First-meeting safety sheet appears for new attendees
- [ ] Panic button present on event detail during event window
- [ ] Under-18 accounts blocked
- [ ] Declared Age Range API integrated (verify with a test account in a regulated region)

**Payments (Guideline 3.1)**
- [ ] External payment flow (Stripe/Razorpay) tested end-to-end with a test card
- [ ] Refund flow tested
- [ ] No accidental IAP triggers on any digital-content-like flow

**Account (Guideline 5.1.1)**
- [ ] Account deletion works from Settings in 2 taps + confirmation
- [ ] Deletion triggers server purge job (verify in Supabase logs)
- [ ] "Data we retain after deletion" language matches privacy policy

**Review Notes (Guideline 2.3.1)**
- [ ] Demo account credentials provided in App Store Connect
- [ ] Review Notes cover UGC, safety, payments, location, deletion, age assurance
- [ ] Contact email for reviewer questions is monitored
- [ ] Backend uptime committed for the review window (~7 days)

---

## 8. Common rejection patterns for our category (and how we dodge them)

Based on published App Review data and community reporting:

**"Your app allows users to interact but does not appear to have a mechanism to report objectionable content."**
Fix: report is on every interactive surface. Show it prominently in Review Notes.

**"Your app appears to use location services in a way that is not directly related to its primary purpose."**
Fix: location purpose string is specific. Location is only requested at the Discover screen, not on launch.

**"Your app allows users to create accounts but does not appear to include a way for users to initiate deletion of their account from within the app."**
Fix: prominent Delete Account in Settings, not buried.

**"Your app appears to include features that use in-app purchase but does not appear to include the required IAP mechanism."**
Fix: if the flow could be misread as digital content, add a clarifying line in Review Notes explaining it's a real-world service.

**"We were unable to review your app as it crashed on launch."**
Fix: physical-device test on the latest iOS, cold launch, three times before submission.

**"Your app metadata references features that are not available in the app."**
Fix: strict rule — nothing in screenshots/description that isn't shippable in this build.

**"Your app collects data but does not include a link to your privacy policy in the App Store Connect metadata."**
Fix: privacy policy URL live and linked before submission.

---

## 9. Post-launch compliance workflow

Rejection risk doesn't end at launch — updates can be rejected too. Establish these as recurring tasks:

- **Every guideline update (Apple posts them at developer.apple.com/news):** review within 7 days, note anything affecting our features.
- **Monthly moderation SLA audit:** verify report response times, tune classifiers.
- **Quarterly privacy label audit:** re-check that our declared data collection matches actual behavior after any dependency update.
- **Before every submission:** re-run Section 7 checklist.
- **When Apple announces regional age-assurance expansion:** check whether it affects markets we operate in.
- **When Apple changes payment rules (they did in May 2025, November 2025):** re-verify our external-payment flow is still compliant.

---

## 10. What lives where

- This document: `docs/compliance/app-store-plan.md`
- Pre-submission checklist: `docs/compliance/pre-submit-checklist.md`
- Review Notes template (evolves per submission): `docs/compliance/review-notes.md`
- Privacy policy: hosted at `privacy.thrdspaces.com`, tracked in `docs/compliance/privacy-policy.md`
- Terms of Use: hosted at `terms.thrdspaces.com`, tracked in `docs/compliance/terms.md`
- Guideline change log: `docs/compliance/guideline-changes.md` — every Apple update we've reviewed and its impact assessment.
