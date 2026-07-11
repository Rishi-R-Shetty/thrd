#!/usr/bin/env bash
# ============================================================================
# Thrd Spaces — Edge Function hostile/behaviour tests (Phase 1, task T7b)
# Covers Artifact B: delete_account · submit_report · manage_block.
#
# Prerequisites (local stack):
#   1. supabase start                       # stack up, migrations 0001+0002 applied
#   2. Serve the functions WITHOUT the gateway JWT check so each function owns
#      its own `unauthorized` response, and inject the JWT secret the verifier
#      needs (the runtime refuses SUPABASE_-prefixed names from an env file):
#
#        printf 'THRD_JWT_SECRET=%s\n' \
#          "$(supabase status -o env | sed -n 's/^JWT_SECRET=//p' | tr -d '\"')" \
#          > /tmp/thrd_edge.env
#        supabase functions serve --no-verify-jwt --env-file /tmp/thrd_edge.env
#
#      (Deployed environments instead set `verify_jwt = false` per function in
#       config.toml and `supabase secrets set THRD_JWT_SECRET=…`.)
#   3. ./supabase/tests/edge_function_tests.sh
#
# Exits non-zero on the first failed assertion. Leaves no committed state
# (fixtures live only in the local dev DB and are wiped by `supabase db reset`).
# ============================================================================
set -uo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_thrd}"
FUNCTIONS_URL="${FUNCTIONS_URL:-http://127.0.0.1:54321/functions/v1}"

env_val() { supabase status -o env | sed -n "s/^$1=//p" | tr -d '"'; }
ANON="$(env_val ANON_KEY)"
JWT_SECRET="$(env_val JWT_SECRET)"

A=11111111-1111-1111-1111-111111111111
B=22222222-2222-2222-2222-222222222222
C=33333333-3333-3333-3333-333333333333   # fresh id for the rate-limit sweep

psql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q "$@"; }

mint_jwt() {  # $1 = sub ; prints an HS256 token signed with the project secret
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
# assert_code EXPECTED METHOD-DESC BODY-FILE  (reads http code + body from globals)
_call() {  # $1 method-url args… -> sets HTTP + BODY
  local url="$1"; shift
  BODY="$(curl -s -w $'\n%{http_code}' -X POST "$url" "$@")"
  HTTP="${BODY##*$'\n'}"; BODY="${BODY%$'\n'*}"
}
check() {  # $1 label  $2 expected-code  $3 expected-substr(optional)
  if [[ "$HTTP" == "$2" ]] && { [[ -z "${3:-}" ]] || [[ "$BODY" == *"$3"* ]]; }; then
    printf '  PASS  %-52s [%s] %s\n' "$1" "$HTTP" "$BODY"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-52s got [%s] %s (want [%s] ~%s)\n' "$1" "$HTTP" "$BODY" "$2" "${3:-*}"; FAIL=$((FAIL+1))
  fi
}

echo "### seeding fixtures (users A, B) + clearing prior state"
psql -c "
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
 ('$A','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@test.local',now(),now()),
 ('$B','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@test.local',now(),now())
 on conflict (id) do nothing;
insert into public.users (id, handle, display_name) values
 ('$A','edge_user_a','Edge User A'),('$B','edge_user_b','Edge User B')
 on conflict (id) do nothing;
update public.users set deletion_requested_at=null where id in ('$A','$B');
delete from public.reports where reporter_id in ('$A','$B','$C');
delete from public.blocks  where blocker_id  in ('$A','$B','$C');
delete from public.rate_limit_counters where bucket_key like '%'||'$C'||'%';
update public.feature_flags set enabled=true where key like 'fn:%';
" >/dev/null

TA="$(mint_jwt "$A")"; TB="$(mint_jwt "$B")"; TC="$(mint_jwt "$C")"
CT=(-H "content-type: application/json")
AN=(-H "apikey: $ANON")
AUTH_A=(-H "Authorization: Bearer $TA")
AUTH_C=(-H "Authorization: Bearer $TC")

echo "### 2a — unauthenticated (anon apikey, no bearer) → 401 unauthorized"
for fn in delete_account submit_report manage_block; do
  _call "$FUNCTIONS_URL/$fn" "${AN[@]}" "${CT[@]}" -d '{}'
  check "$fn unauthenticated" 401 '"error":"unauthorized"'
done
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" -H "Authorization: Bearer ${TA%??}XY" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"$B\"}"
check "tampered-signature token" 401 '"error":"unauthorized"'

echo "### 2b — A calls delete_account naming B in body → only A is marked"
_call "$FUNCTIONS_URL/delete_account" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"confirm\":true,\"user_id\":\"$B\",\"device_id\":\"dev-A\"}"
check "delete_account A (body names B)" 200 '"status":"pending_deletion"'
MARKED="$(psql -A -t -c "select (deletion_requested_at is not null) from public.users where id='$A';")"
BNULL="$(psql -A -t -c "select (deletion_requested_at is null) from public.users where id='$B';")"
[[ "$MARKED" == t && "$BNULL" == t ]] && { echo "  PASS  only A marked, B untouched"; PASS=$((PASS+1)); } \
                                       || { echo "  FAIL  A=$MARKED Bnull=$BNULL"; FAIL=$((FAIL+1)); }
_call "$FUNCTIONS_URL/delete_account" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d '{"confirm":false}'
check "delete_account confirm!=true" 400 '"error":"not_confirmed"'

echo "### 2c — duplicate report deduped; exactly one row"
_call "$FUNCTIONS_URL/submit_report" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"subject_type\":\"user\",\"subject_id\":\"$B\",\"reason\":\"harassment\",\"detail\":\"first\"}"
check "report #1" 200 '"status":"submitted"'
_call "$FUNCTIONS_URL/submit_report" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"subject_type\":\"user\",\"subject_id\":\"$B\",\"reason\":\"harassment\",\"detail\":\"second\"}"
check "report #2 (dup)" 200 '"status":"already_reported"'
N="$(psql -A -t -c "select count(*) from public.reports where reporter_id='$A' and subject_id='$B';")"
[[ "$N" == 1 ]] && { echo "  PASS  exactly one report row"; PASS=$((PASS+1)); } || { echo "  FAIL  rows=$N"; FAIL=$((FAIL+1)); }
RID="$(psql -A -t -c "select reporter_id from public.reports where subject_id='$B' limit 1;")"
[[ "$RID" == "$A" ]] && { echo "  PASS  reporter_id derived from JWT ($A)"; PASS=$((PASS+1)); } || { echo "  FAIL  reporter_id=$RID"; FAIL=$((FAIL+1)); }

echo "### submit_report validation"
_call "$FUNCTIONS_URL/submit_report" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"subject_type\":\"user\",\"subject_id\":\"$B\",\"reason\":\"nope\"}"
check "invalid reason" 400 '"error":"invalid_reason"'
_call "$FUNCTIONS_URL/submit_report" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"subject_type\":\"user\",\"subject_id\":\"$A\",\"reason\":\"spam\"}"
check "self report" 400 '"error":"invalid_subject"'
_call "$FUNCTIONS_URL/submit_report" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"subject_type\":\"user\",\"subject_id\":\"99999999-9999-9999-9999-999999999999\",\"reason\":\"spam\"}"
check "unknown subject" 404 '"error":"not_found"'

echo "### manage_block behaviour"
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"$B\"}"
check "block A->B" 200 '"status":"ok"'
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"$B\"}"
check "block A->B (idempotent)" 200 '"status":"ok"'
NB="$(psql -A -t -c "select count(*) from public.blocks where blocker_id='$A' and blocked_id='$B';")"
[[ "$NB" == 1 ]] && { echo "  PASS  exactly one block row"; PASS=$((PASS+1)); } || { echo "  FAIL  block rows=$NB"; FAIL=$((FAIL+1)); }
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"$A\"}"
check "self-block" 400 '"error":"invalid_target"'
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"mute\",\"user_id\":\"$B\"}"
check "bad action" 400 '"error":"invalid_action"'
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"99999999-9999-9999-9999-999999999999\"}"
check "nonexistent target" 404 '"error":"not_found"'
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"unblock\",\"user_id\":\"$B\"}"
check "unblock A->B" 200 '"status":"ok"'
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"unblock\",\"user_id\":\"$B\"}"
check "unblock again (idempotent)" 200 '"status":"ok"'

echo "### 2d — rate limit: delete_account is 3/user/day; 4th call by fresh user C → 429"
for i in 1 2 3; do _call "$FUNCTIONS_URL/delete_account" "${AN[@]}" "${AUTH_C[@]}" "${CT[@]}" -d '{"confirm":true}'; check "delete C #$i" 200 '"status":"pending_deletion"'; done
_call "$FUNCTIONS_URL/delete_account" "${AN[@]}" "${AUTH_C[@]}" "${CT[@]}" -d '{"confirm":true}'
check "delete C #4 (over limit)" 429 '"error":"rate_limited"'

echo "### 2e — kill switch: disable fn:manage_block → 503 unavailable, then re-enable"
psql -c "update public.feature_flags set enabled=false where key='fn:manage_block';" >/dev/null
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"block\",\"user_id\":\"$B\"}"
check "manage_block killed" 503 '"error":"unavailable"'
psql -c "update public.feature_flags set enabled=true where key='fn:manage_block';" >/dev/null
_call "$FUNCTIONS_URL/manage_block" "${AN[@]}" "${AUTH_A[@]}" "${CT[@]}" -d "{\"action\":\"unblock\",\"user_id\":\"$B\"}"
check "manage_block re-enabled" 200 '"status":"ok"'

echo
echo "### audit trail (one row per invocation, server-side user_id + outcome)"
psql -c "select action, metadata->>'outcome' as outcome, count(*)
         from public.audit_log where user_id in ('$A','$C') group by 1,2 order by 1,2;"

echo
echo "==================  PASS=$PASS  FAIL=$FAIL  =================="
[[ "$FAIL" == 0 ]] || exit 1
