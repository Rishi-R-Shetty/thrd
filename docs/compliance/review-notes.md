# App Review Notes — Thrd Spaces

Working draft of the Review Notes submitted in App Store Connect. Structured to
answer a reviewer's questions before they ask (see `app-store-plan.md` §6). This
file evolves per submission; sections are added as the features they describe
ship.

---

## REAL-WORLD SAFETY (Guideline 1.4.1)

Thrd Spaces connects people for real-world, in-person gatherings, so the app
ships physical-safety features the reviewer can exercise directly:

**First-meeting safety sheet.**
Before a user's *first* RSVP, a non-dismissable sheet appears with three safety
asks — meet in a public space, tell a friend where you're going, and share your
live location with a trusted contact. The user must tick an acknowledgement
before the RSVP proceeds (the Continue button is disabled until then; the sheet
cannot be swiped away or dismissed by tapping outside). The first-time trigger is
derived from the user's own tickets on the server, not local device state, so a
reinstall does not bypass it.
- *To exercise:* on a fresh demo account, open any event → tap RSVP → the sheet
  appears and blocks the RSVP until acknowledged.

**Panic button.**
On an event's detail screen, during the window from 2 hours before to 2 hours
after the event's start time, a prominent red "Emergency help" button appears.
One tap dials the local emergency number and opens a pre-filled text message to
the user's emergency contact containing a link to the venue's location.
- *To exercise:* open an event whose start time is within ±2 hours of now → the
  panic button is visible below the attendee list. (Outside that window it is
  intentionally hidden.)

**Emergency contact — stored only on the device.**
The emergency contact (name + phone) is set in Settings → Safety → Emergency
contact, or from the first-meeting sheet. It is stored **only** in the device
Keychain (device-only, unlock-required accessibility). It is never uploaded to
our servers, never synced across devices, and never included in any network
request — it is used purely on-device to address the panic-flow text message.

**Blocked-user invisibility.**
Blocked users are invisible in attendee lists, community members, feeds, and
host profiles — enforced server-side, so a blocked user cannot be surfaced by any
client path.

**Age assurance.**
No under-18 accounts at launch; hosts of paid events complete third-party KYC.

---

*Other Review-Notes sections (UGC, payments, location, account deletion, age
assurance) are templated in `app-store-plan.md` §6 and folded in at submission.*
