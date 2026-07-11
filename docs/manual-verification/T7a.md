# T7a — Manual Verification: Profile (view/edit, settings, deletion, block & report)

The T7a client is complete and builds/tests green (38/38, incl. 15 new
`ProfileTests`). The flows below can only be exercised end-to-end once the
**hosted schema** and the **three Edge Functions** are deployed — during this
build both were absent (verified 2026-07-12):

- `GET /rest/v1/users` → `404 PGRST205` ("Could not find the table 'public.users'").
- `POST /functions/v1/{delete_account,submit_report,manage_block}` → `404 NOT_FOUND`.

Until then the app runs and degrades gracefully: table-touching screens show a
"couldn't reach the server / try again" state, and delete/report/block surface a
non-leaking error **without** signing out or pretending success. Those
error-surfacing paths are covered by unit tests.

> No image upload exists anywhere in Profile (D2 — avatars are initials on a
> deterministic color). If you ever see a photo picker here, stop and file a bug.
> Tokens stay Keychain-only; nothing in Profile writes auth state to UserDefaults
> or a file (grep-verified).

---

## A. Deploy prerequisites (user-side; the client cannot do these)

From the repo root, authenticated to the Supabase project `emfzwfnfsqhhybnzfhsy`:

- [ ] `supabase db push` — applies `0001_initial_schema.sql` + `0002_edge_function_support.sql` (creates `public.users`, `public_profiles`, `blocks`, `reports`, `audit_log`, `feature_flags`, `rate_limit_counters`).
- [ ] `supabase functions deploy delete_account submit_report manage_block`.
- [ ] `supabase secrets set THRD_JWT_SECRET=<project JWT secret>` (the functions verify the JWT signature with this).
- [ ] T5 dashboard config done (Apple provider + SMS sender) so you can actually create two accounts to test with.

> Re-probe after deploy: `GET /rest/v1/users?select=id&limit=1` should return
> `200 []` (RLS denies rows to an unrelated caller — table exists), and each
> function POST with no JWT should return the gateway's `401`, not `404`.

---

## B. Profile view + edit → relaunch persists
*(exit: "edit → relaunch → persisted")*

Run on device/simulator, signed in and onboarded (interests already set).

- [ ] Profile tab shows the initials avatar (no image), display name, `@handle`, bio, and interest chips (read-only). No "events attended" stat (intentionally omitted — no backend field).
- [ ] Tap **Edit**. Change display name, bio, and toggle interests (must keep ≥3 — Save disables below 3). Handle field lowercases input; footer states the rule.
- [ ] Save. Sheet dismisses; the profile reflects the new values immediately.
- [ ] Kill and relaunch the app. The edited values are still shown (they persisted to `public.users`).
- [ ] In the Supabase dashboard, `public.users` row for your id shows the new `display_name`, `bio`, `interests`.

## C. Handle uniqueness
*(exit: "second account cannot take an existing handle")*

- [ ] With account A, set handle to e.g. `taken_handle`. Save succeeds.
- [ ] Sign in as account B. Edit → set handle to `taken_handle` → Save.
- [ ] The handle field shows **"That handle is taken."** and nothing else is changed. (Server 23505 unique-violation; no existence oracle beyond this owner-facing message.)
- [ ] Pick a free handle → Save succeeds.

## D. Block / unblock round-trip
*(exit: "block/unblock round-trips"; "⋯ → Report and Block reachable on any profile in ≤2 taps")*

Phase 1 shows only your own profile in the tab, so exercise the ⋯ menu via a
`ProfileView(.other(...))` (preview/UI test) or the blocked-list rows:

- [ ] From a profile in `.other` mode, the ⋯ menu is one tap; **Report** and **Block** are the two items (≤2 taps to either).
- [ ] Tap **Block** → confirmation dialog → confirm. A neutral "This person has been blocked." notice appears. The target is never notified.
- [ ] Settings → **Blocked users** lists that user (joined from `blocks` → `public_profiles`).
- [ ] Row ⋯ → **Unblock**. The row disappears. In the dashboard, the `blocks` row `(blocker_id = you, blocked_id = target)` is gone.
- [ ] Re-block then unblock twice — idempotent, no error (repeat calls succeed).
- [ ] Confirm the request body in a network trace carries only `{action, user_id}` — **no `blocker_id`** (server derives it from the JWT).

## E. Report lands with server-derived reporter_id
*(exit: "report lands in reports with correct reporter_id")*

- [ ] ⋯ → **Report** on another user. Pick a reason; optionally add detail (counter caps at 500). Submit.
- [ ] Sheet closes. In the dashboard, `public.reports` has a new `open` row with `reporter_id = your id` (set server-side), `subject_type = user`, `subject_id = target`, chosen `reason`.
- [ ] Confirm the request body carries only `{subject_type, subject_id, reason, detail?}` — **no `reporter_id`**.
- [ ] Report the same user again with an open report outstanding → the sheet still closes with no error, and **no duplicate row** is created (dedupe → `already_reported`).
- [ ] Trip the rate limit (submit rapidly) → a "you're doing that too often, try again later" message; the sheet stays open.

## F. Account deletion (App Store 5.1.1(v))
*(exit: "delete account signs out and the grace-period row state is verifiable in Supabase")*

- [ ] Settings → **Delete account** (1 tap) shows the plain-language "what gets deleted" list + the 30-day grace explanation.
- [ ] Tap **Delete my account** → confirmation dialog (step 2) → **Delete account**.
- [ ] On success (200): the app signs out locally and returns to the onboarding welcome screen.
- [ ] In the dashboard, `public.users` row has `deletion_requested_at` set (~now); `audit_log` has an `account_delete_request` row for your id.
- [ ] Sign back in within the grace window — the account is still recoverable (grace, not hard-deleted).
- [ ] **Unavailable path:** with the function undeployed (or network off), run the delete. It shows "We couldn't reach the server. Please try again later." and you remain **signed in** — no false "deleted" state. (Covered by `testDeletionSignsOutOnlyOnConfirmedSuccess`.)

## G. Settings surface
*(exit: contact email from config; Terms reachable)*

- [ ] Settings → **Terms of Use** renders the T6 EULA copy read-only (no Accept button, no new consent audit row).
- [ ] Settings → **Contact support** shows the address from `Configuration.plist:SupportEmail` and opens Mail composed to it. (No email literal exists in Swift source — grep-verified.)
- [ ] Settings → **Sign out** → confirmation → returns to the onboarding welcome screen; Keychain session cleared (relaunch does not auto-restore).

## H. Accessibility (App Store review gate)

- [ ] VoiceOver: avatar is not focusable (decorative); name+handle read as one element; every button (Edit, Settings, ⋯, Report, Block, Unblock, Delete, Sign out) has a spoken label.
- [ ] Dynamic Type at XL: Profile, Edit form, Settings, and the deletion copy remain readable and scroll rather than clip.

---

### Maps to T7a exit criteria

| Exit criterion (phase-1 plan) | Section |
|---|---|
| edit → relaunch → persisted | B |
| second account cannot take an existing handle | C |
| block/unblock round-trips | D |
| report lands in `reports` with correct `reporter_id` | E |
| delete account signs out; grace-row verifiable in Supabase | F |
| ⋯ → Report and Block reachable on any profile in ≤2 taps | D |
| grep of `Features/` for `@thrdspaces.com` returns nothing | done in build (grep clean) |
