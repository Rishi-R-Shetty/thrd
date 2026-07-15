#!/usr/bin/env bash
# ============================================================================
# Thrd Spaces — rsvp_event Edge Function behaviour/hostile tests (Phase 2, T16)
# Covers Artifact B §4. Companion to edge_function_tests.sh (T7b).
#
# Prerequisites (identical serve recipe to the T7b suite):
#   1. supabase start                       # migrations 0001–0004 applied
#   2. printf 'THRD_JWT_SECRET=%s\n' \
#        "$(supabase status -o env | sed -n 's/^JWT_SECRET=//p' | tr -d '\"')" \
#        > /tmp/thrd_edge.env
#      supabase functions serve --no-verify-jwt --env-file /tmp/thrd_edge.env
#   3. ./supabase/tests/rsvp_event_tests.sh
#
# Each logical user sends a distinct X-Forwarded-For so the 60/IP/hr window
# never cross-contaminates across users mid-suite (the 30/user/hr window is the
# one under test). Exits non-zero on the first failed assertion. Leaves only
# local-dev DB state (wiped by `supabase db reset`).
# ============================================================================
set -uo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_thrd}"
FUNCTIONS_URL="${FUNCTIONS_URL:-http://127.0.0.1:54321/functions/v1}"
URL="$FUNCTIONS_URL/rsvp_event"

env_val() { supabase status -o env | sed -n "s/^$1=//p" | tr -d '"'; }
ANON="$(env_val ANON_KEY)"
JWT_SECRET="$(env_val JWT_SECRET)"

# users
A=a0000000-0000-0000-0000-0000000000a1   # verified
B=a0000000-0000-0000-0000-0000000000b2   # verified
U=a0000000-0000-0000-0000-0000000000c3   # UNVERIFIED (tier-0)
R=a0000000-0000-0000-0000-0000000000d4   # verified, rate-limit sweep
X=a0000000-0000-0000-0000-0000000000e5   # race
Y=a0000000-0000-0000-0000-0000000000f6   # race
S=a0000000-0000-0000-0000-000000000051   # host
# events
EV_CAP1=e0000000-0000-0000-0000-0000000000c1    # free, published, capacity 1, future
EV_CAP2=e0000000-0000-0000-0000-0000000000c2    # free, published, capacity 2, future
EV_BIG=e0000000-0000-0000-0000-0000000000b1     # free, published, capacity 100 (>20)
EV_PAID=e0000000-0000-0000-0000-0000000000a1    # price>0, published, future
EV_DRAFT=e0000000-0000-0000-0000-0000000000d1   # draft
EV_PAST=e0000000-0000-0000-0000-0000000000f1    # free, published, STARTED
EV_RACE=e0000000-0000-0000-0000-0000000000e1    # free, published, capacity 1, future
UNKNOWN=e0000000-0000-0000-0000-000000000099    # no such event
SP=50000000-0000-0000-0000-000000000001         # venue

psql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q "$@"; }

mint_jwt() {
  JWT_SECRET="$JWT_SECRET" python3 - "$1" <<'PY'
import sys, os, json, hmac, hashlib, base64, time
b64=lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
secret=os.environ["JWT_SECRET"].encode()
h=b64(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
p=b64(json.dumps({"sub":sys.argv[1],"role":"authenticated","aud":"authenticated",
                  "exp":int(time.time())+3600},separators=(',',':')).encode())
si=h+b'.'+p
print((si+b'.'+b64(hmac.new(secret,si,hashlib.sha256).digest())).decode())
PY
}

PASS=0; FAIL=0
_call() {  # $1 url ; rest curl args -> sets HTTP + BODY
  local url="$1"; shift
  BODY="$(curl -s -w $'\n%{http_code}' -X POST "$url" "$@")"
  HTTP="${BODY##*$'\n'}"; BODY="${BODY%$'\n'*}"
}
check() {  # $1 label  $2 expected-code  $3 expected-substr(optional)
  if [[ "$HTTP" == "$2" ]] && { [[ -z "${3:-}" ]] || [[ "$BODY" == *"$3"* ]]; }; then
    printf '  PASS  %-46s [%s] %s\n' "$1" "$HTTP" "$BODY"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-46s got [%s] %s (want [%s] ~%s)\n' "$1" "$HTTP" "$BODY" "$2" "${3:-*}"; FAIL=$((FAIL+1))
  fi
}
assert_eq() {  # $1 label  $2 actual  $3 expected
  if [[ "$2" == "$3" ]]; then printf '  PASS  %-46s %s\n' "$1" "$2"; PASS=$((PASS+1));
  else printf '  FAIL  %-46s got %s want %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

echo "### seeding fixtures (users, venue, events) + clearing prior rsvp state"
psql -c "
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
 ('$A','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_a@test.local',now(),now()),
 ('$B','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_b@test.local',now(),now()),
 ('$U','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_u@test.local',now(),now()),
 ('$R','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_r@test.local',now(),now()),
 ('$X','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_x@test.local',now(),now()),
 ('$Y','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_y@test.local',now(),now()),
 ('$S','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rsvp_s@test.local',now(),now())
 on conflict (id) do nothing;
insert into public.users (id, handle, display_name, verification_status) values
 ('$A','rsvp_a','RSVP A','phone'),('$B','rsvp_b','RSVP B','phone'),
 ('$U','rsvp_u','RSVP U','none'),('$R','rsvp_r','RSVP R','phone'),
 ('$X','rsvp_x','RSVP X','phone'),('$Y','rsvp_y','RSVP Y','phone'),
 ('$S','rsvp_s','RSVP S','phone')
 on conflict (id) do update set verification_status = excluded.verification_status;
insert into public.spaces (id, name, category, location, address) values
 ('$SP','RSVP Venue','cafe', extensions.st_point(77.5946,12.9716)::extensions.geography,'Bengaluru')
 on conflict (id) do nothing;
insert into public.events (id, host_id, space_id, title, starts_at, ends_at, status, capacity, price) values
 ('$EV_CAP1','$S','$SP','Free cap1', now()+interval '1 day', now()+interval '1 day 2 h','published',1,0),
 ('$EV_CAP2','$S','$SP','Free cap2', now()+interval '1 day', now()+interval '1 day 2 h','published',2,0),
 ('$EV_BIG', '$S','$SP','Free big',  now()+interval '1 day', now()+interval '1 day 2 h','published',100,0),
 ('$EV_PAID','$S','$SP','Paid',      now()+interval '1 day', now()+interval '1 day 2 h','published',10,500),
 ('$EV_DRAFT','$S','$SP','Draft',    now()+interval '1 day', now()+interval '1 day 2 h','draft',10,0),
 ('$EV_PAST','$S','$SP','Past',      now()-interval '2 h',   now()-interval '1 h',      'published',10,0),
 ('$EV_RACE','$S','$SP','Race cap1', now()+interval '1 day', now()+interval '1 day 2 h','published',1,0)
 on conflict (id) do update set status = excluded.status, capacity = excluded.capacity,
   price = excluded.price, starts_at = excluded.starts_at, ends_at = excluded.ends_at;
-- clean slate for a re-run inside the same hour
delete from public.tickets where user_id in ('$A','$B','$U','$R','$X','$Y');
update public.events set rsvp_count = 0 where id in
 ('$EV_CAP1','$EV_CAP2','$EV_BIG','$EV_PAID','$EV_DRAFT','$EV_PAST','$EV_RACE');
delete from public.rate_limit_counters where bucket_key like 'rsvp_event:%';
update public.feature_flags set enabled = true where key = 'fn:rsvp_event';
" >/dev/null

TA="$(mint_jwt "$A")"; TB="$(mint_jwt "$B")"; TU="$(mint_jwt "$U")"
TR="$(mint_jwt "$R")"; TX="$(mint_jwt "$X")"; TY="$(mint_jwt "$Y")"
CT=(-H "content-type: application/json")
AN=(-H "apikey: $ANON")
hdr() { echo "-H"; echo "Authorization: Bearer $1"; echo "-H"; echo "x-forwarded-for: $2"; }
HA=(); while read -r l; do HA+=("$l"); done < <(hdr "$TA" 10.0.0.1)
HB=(); while read -r l; do HB+=("$l"); done < <(hdr "$TB" 10.0.0.2)
HU=(); while read -r l; do HU+=("$l"); done < <(hdr "$TU" 10.0.0.3)
HX=(); while read -r l; do HX+=("$l"); done < <(hdr "$TX" 10.0.0.5)
HY=(); while read -r l; do HY+=("$l"); done < <(hdr "$TY" 10.0.0.6)

echo "### 1 — unauthenticated (anon apikey, no bearer) → 401"
_call "$URL" "${AN[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "unauthenticated" 401 '"error":"unauthorized"'

echo "### 2 — RSVP to a free published event → going + count increments"
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "A rsvp cap2" 200 '"status":"going"'
check "  rsvp_count=1" 200 '"rsvp_count":1'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "A rsvp again (idempotent going)" 200 '"status":"going"'
check "  rsvp_count still 1" 200 '"rsvp_count":1'

echo "### 3 — fill to capacity → next RSVP waitlists; cancel promotes waitlist head"
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP1\",\"action\":\"rsvp\"}"
check "A rsvp cap1 → going" 200 '"status":"going"'
_call "$URL" "${AN[@]}" "${HB[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP1\",\"action\":\"rsvp\"}"
check "B rsvp cap1 → waitlist" 200 '"status":"waitlist"'
check "  rsvp_count still 1 (waitlist not counted)" 200 '"rsvp_count":1'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP1\",\"action\":\"cancel\"}"
check "A cancel cap1 → cancelled" 200 '"status":"cancelled"'
check "  rsvp_count stable at 1 (B promoted)" 200 '"rsvp_count":1'
BST="$(psql -A -t -c "select status from public.tickets where event_id='$EV_CAP1' and user_id='$B';")"
assert_eq "B promoted to going in DB" "$BST" "going"

echo "### 4 — tier-0 cap: unverified caller"
_call "$URL" "${AN[@]}" "${HU[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_BIG\",\"action\":\"rsvp\"}"
check "U rsvp cap100 (>20) → 403" 403 '"error":"verification_required"'
_call "$URL" "${AN[@]}" "${HU[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "U rsvp cap2 (≤20) → going allowed" 200 '"status":"going"'

echo "### 5 — draft / unknown / paid / past"
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_DRAFT\",\"action\":\"rsvp\"}"
check "draft → 404 (no draft oracle)" 404 '"error":"not_found"'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$UNKNOWN\",\"action\":\"rsvp\"}"
check "unknown id → 404" 404 '"error":"not_found"'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_PAID\",\"action\":\"rsvp\"}"
check "paid event → 400 event_not_open" 400 '"error":"event_not_open"'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_PAST\",\"action\":\"rsvp\"}"
check "past event → 400 event_not_open" 400 '"error":"event_not_open"'
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"maybe\"}"
check "bad action → 400 invalid_action" 400 '"error":"invalid_action"'

echo "### 6 — kill switch: disable fn:rsvp_event → 503, then re-enable"
psql -c "update public.feature_flags set enabled=false where key='fn:rsvp_event';" >/dev/null
_call "$URL" "${AN[@]}" "${HA[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "rsvp_event killed → 503" 503 '"error":"unavailable"'
psql -c "update public.feature_flags set enabled=true where key='fn:rsvp_event';" >/dev/null

echo "### 7 — rate limit: 30/user/hr → 31st call by fresh user R → 429"
HR=(); while read -r l; do HR+=("$l"); done < <(hdr "$TR" 10.0.0.4)
for i in $(seq 1 30); do
  _call "$URL" "${AN[@]}" "${HR[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
  [[ "$HTTP" == 200 ]] || { echo "  FAIL  R call #$i unexpectedly [$HTTP] $BODY"; FAIL=$((FAIL+1)); break; }
done
_call "$URL" "${AN[@]}" "${HR[@]}" "${CT[@]}" -d "{\"event_id\":\"$EV_CAP2\",\"action\":\"rsvp\"}"
check "R call #31 (over 30/user/hr)" 429 '"error":"rate_limited"'

echo "### 8 — CONCURRENCY: two callers race the last seat → exactly one going, one waitlist"
# Both RSVPs are fired in parallel; the FOR UPDATE lock in rsvp_event_tx
# serializes them, so the outcome is deterministic regardless of who wins.
curl -s -X POST "$URL" "${AN[@]}" "${HX[@]}" "${CT[@]}" \
  -d "{\"event_id\":\"$EV_RACE\",\"action\":\"rsvp\"}" >/tmp/race_x.out &
curl -s -X POST "$URL" "${AN[@]}" "${HY[@]}" "${CT[@]}" \
  -d "{\"event_id\":\"$EV_RACE\",\"action\":\"rsvp\"}" >/tmp/race_y.out &
wait
echo "  X → $(cat /tmp/race_x.out)"
echo "  Y → $(cat /tmp/race_y.out)"
GOING="$(psql -A -t -c "select count(*) from public.tickets where event_id='$EV_RACE' and status='going';")"
WAIT="$(psql -A -t -c "select count(*) from public.tickets where event_id='$EV_RACE' and status='waitlist';")"
CNT="$(psql -A -t -c "select rsvp_count from public.events where id='$EV_RACE';")"
assert_eq "exactly one going" "$GOING" "1"
assert_eq "exactly one waitlist" "$WAIT" "1"
assert_eq "rsvp_count = 1 (no double-count)" "$CNT" "1"

echo
echo "### audit trail (action + outcome + resulting_status per invocation)"
psql -c "select action, metadata->>'outcome' outcome, metadata->>'resulting_status' resulting_status, count(*)
         from public.audit_log
         where user_id in ('$A','$B','$U','$X','$Y')
         group by 1,2,3 order by 1,2,3;"

echo
echo "==================  PASS=$PASS  FAIL=$FAIL  =================="
[[ "$FAIL" == 0 ]] || exit 1
