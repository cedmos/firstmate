#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUTBOX="$ROOT/bin/fm-completion-outbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-flowy-completion)

# Every case drives the real executable. The endpoint is a PATH stub, so no test
# ever reaches a network, and the URL and key are obvious fixtures.
FIXTURE_URL='https://flowy.invalid/hook'

make_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$FIXTURE_URL" > "$home/config/grok-flowy-webhook"
  printf '200' > "$home/http-code"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/security" <<'SH'
#!/usr/bin/env bash
printf 'keychain: %s\n' "$1" >> "$FLOWY_TEST_CALLS"
printf 'fixture-bearer-key\n'
SH
  # The endpoint and the Bearer header arrive as a -K - config on stdin, and the
  # JSON body as a --data-binary @file, so the stub recovers both the way real
  # curl would. args: is recorded verbatim because it is exactly what a local ps
  # would see, which is what the no-secret-in-argv case asserts against.
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
code=$(cat "$FLOWY_TEST_CODE")
config=$(cat)
body=
for arg in "$@"; do
  case "$arg" in
    @*) body=$(cat "${arg#@}" 2>/dev/null || true) ;;
  esac
done
# A per-task override lets ONE drain pass answer differently per record, which
# is how an older record gets held back while a newer one is accepted.
for override in "$FLOWY_TEST_CODE"-*; do
  [ -f "$override" ] || continue
  case "$body" in
    *"\"task\":\"${override##*/http-code-}\""*) code=$(cat "$override") ;;
  esac
done
{
  printf 'args: %s\n' "$*"
  printf 'config: %s\n' "$(printf '%s' "$config" | tr '\n' ' ')"
  printf 'body: %s\n' "$body"
} >> "$FLOWY_TEST_CALLS"
if [ "$code" = FAIL ]; then
  printf 'curl: (7) failed to connect\n' >&2
  exit 7
fi
if [ "$code" = HANG ]; then
  sleep 60
  exit 7
fi
printf '%s' "$code"
SH
  chmod +x "$fakebin/security" "$fakebin/curl"
  printf '%s\n' "$home"
}

http_code() { printf '%s' "$2" > "$1/http-code"; }

http_code_for() { printf '%s' "$3" > "$1/http-code-$2"; }

clear_http_code_for() { rm -f "$1/http-code-$2"; }

calls() { cat "$1/curl.calls" 2>/dev/null || true; }

call_count() { grep -c '^args: ' "$1/curl.calls" 2>/dev/null || true; }

keychain_count() { grep -c '^keychain: ' "$1/curl.calls" 2>/dev/null || true; }

status_line() { printf '%s\n' "$3" > "$1/state/$2.status"; }

sole_receipt() {
  local home=$1 found
  found=$(find "$home/state/flowy-outbox/delivered" -name '*.md' 2>/dev/null | LC_ALL=C sort)
  printf '%s\n' "$found"
}

pending_count() {
  find "$1/state/flowy-outbox/pending" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# env -u proves the endpoint no longer depends on FLOWY_WEBHOOK_URL even when an
# ambient value exists.
outbox() {
  local home=$1 rc=0
  shift
  env -u FLOWY_WEBHOOK_URL \
    PATH="$home/fakebin:$PATH" \
    FLOWY_TEST_CODE="$home/http-code" \
    FLOWY_TEST_CALLS="$home/curl.calls" \
    FM_HOME="$home" "$OUTBOX" "$@" >>"$home/out.log" 2>>"$home/err.log" || rc=$?
  printf '%s' "$rc"
}

test_delivers_from_url_file_and_keychain_with_no_env_var() {
  local home rc
  home=$(make_home url-file)
  status_line "$home" demo 'done: shipped the thing'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "delivery from the URL file failed"
  assert_contains "$(calls "$home")" "$FIXTURE_URL" "outbox did not POST to the URL file's endpoint"
  assert_contains "$(calls "$home")" "Authorization: Bearer" "outbox sent no Bearer authorization"
  assert_contains "$(calls "$home")" "Content-Type: application/json" "outbox did not POST JSON"
  assert_contains "$(calls "$home")" '"result":"done: shipped the thing"' "payload omitted the result"
  assert_contains "$(cat "$(sole_receipt "$home")")" "status: demo: done: shipped the thing" \
    "no delivered receipt after a 2xx"
  assert_grep 'status: demo: done: shipped the thing' "$home/state/flowy-last.md" \
    "display snapshot did not record the delivered result"
  assert_grep 'pending: (none)' "$home/state/flowy-last.md" \
    "display snapshot omitted the required pending: line"
  pass "outbox delivers from the URL file and Keychain with no environment variable"
}

test_the_bearer_key_never_reaches_the_process_table() {
  local home rc argv
  home=$(make_home no-argv-secret)
  status_line "$home" demo 'done: credentials stay off argv'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "delivery failed"

  # args: is what `ps -ww -axo args` would show for the POST.
  argv=$(grep '^args: ' "$home/curl.calls" 2>/dev/null || true)
  [ -n "$argv" ] || fail "the stub recorded no curl invocation to inspect"
  case "$argv" in
    *fixture-bearer-key*) fail "the Bearer key reached curl argv, where any local ps can read it" ;;
  esac
  case "$argv" in
    *"$FIXTURE_URL"*) fail "the endpoint url reached curl argv instead of the stdin config" ;;
  esac

  # Both still actually reach curl, just through stdin.
  assert_contains "$(calls "$home")" "Authorization: Bearer fixture-bearer-key" \
    "the Bearer authorization never reached curl at all"
  assert_contains "$(calls "$home")" "$FIXTURE_URL" "the endpoint url never reached curl at all"

  [ -z "$(grep -rl 'fixture-bearer-key' "$home/state" 2>/dev/null || true)" ] || \
    fail "the Bearer key was written somewhere under state"
  [ -z "$(find "$home/state/flowy-outbox" -name '.payload.*' 2>/dev/null)" ] || \
    fail "the staged payload file outlived the drain"
  pass "the Bearer key and endpoint reach curl through stdin, never the process table"
}

test_failed_post_retries_to_success_after_a_restart() {
  local home rc record
  home=$(make_home retry)
  http_code "$home" 503
  status_line "$home" demo 'done: benchmark report ready'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 1 "$rc" "a failed POST reported success"
  assert_absent "$home/state/flowy-last.md" "a failed POST still wrote the display snapshot"
  [ "$(pending_count "$home")" = 1 ] || fail "a failed POST left no pending record to retry"
  [ -z "$(sole_receipt "$home")" ] || fail "a failed POST wrote a delivered receipt"

  # The record is the only thing carried across the restart: this drain runs in a
  # new process with no status signal and no memory of the first attempt.
  record=$(find "$home/state/flowy-outbox/pending" -type f ! -name '.*')
  assert_grep 'result=done: benchmark report ready' "$record" "pending record lost the result"
  assert_grep 'artifact=' "$record" "pending record lost the artifact path"

  http_code "$home" 200
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "the retry drain did not deliver"
  [ "$(pending_count "$home")" = 0 ] || fail "a delivered result stayed pending"
  assert_grep 'status: demo: done: benchmark report ready' "$home/state/flowy-last.md" \
    "the retry did not refresh the display snapshot"
  pass "a failed POST is retried to success by a later drain after a restart"
}

test_two_results_never_overwrite_each_other() {
  local home rc alpha_receipt alpha_bytes
  home=$(make_home two-results)
  status_line "$home" alpha 'done: alpha shipped'
  status_line "$home" beta 'done: beta shipped'

  rc=$(outbox "$home" --status "$home/state/alpha.status")
  expect_code 0 "$rc" "alpha did not deliver"
  alpha_receipt=$(sole_receipt "$home")
  alpha_bytes=$(cat "$alpha_receipt")
  assert_contains "$alpha_bytes" "status: alpha: done: alpha shipped" "alpha receipt is wrong"

  # Beta fails while alpha is already delivered: alpha's evidence must not move.
  http_code "$home" 503
  rc=$(outbox "$home" --status "$home/state/beta.status")
  expect_code 1 "$rc" "beta's failed POST reported success"
  [ "$(cat "$alpha_receipt")" = "$alpha_bytes" ] || fail "beta's attempt rewrote alpha's receipt"
  assert_grep 'status: alpha: done: alpha shipped' "$home/state/flowy-last.md" \
    "beta's failed attempt replaced alpha in the display snapshot"

  http_code "$home" 200
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "beta's retry did not deliver"
  [ "$(cat "$alpha_receipt")" = "$alpha_bytes" ] || fail "beta's delivery rewrote alpha's receipt"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || fail "two results did not leave two receipts"
  assert_contains "$(calls "$home")" '"task":"alpha"' "alpha was never sent"
  assert_contains "$(calls "$home")" '"task":"beta"' "beta was never sent"
  assert_grep 'pending: (none)' "$home/state/flowy-last.md" "delivered tasks stayed in pending:"
  pass "two completed tasks both deliver and neither result overwrites the other"
}

test_second_result_for_one_task_gets_its_own_record() {
  local home rc
  home=$(make_home same-task)
  status_line "$home" demo 'blocked: needs a credential'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "the blocked result did not deliver"

  status_line "$home" demo 'done: credential landed, shipped'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "the later result did not deliver"

  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || \
    fail "a second result for one task overwrote the first receipt"
  assert_contains "$(calls "$home")" '"result":"blocked: needs a credential"' "the blocked result was never sent"
  assert_contains "$(calls "$home")" '"result":"done: credential landed, shipped"' "the final result was never sent"
  pass "a second distinct result for one task gets its own record and receipt"
}

test_re_recording_one_result_does_not_resend_it() {
  local home rc before
  home=$(make_home idempotent)
  status_line "$home" demo 'done: shipped once'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "the first delivery failed"
  before=$(call_count "$home")
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "re-recording a delivered result failed"
  [ "$(call_count "$home")" = "$before" ] || fail "an already-delivered result was POSTed again"
  pass "re-recording an already-delivered result never resends it"
}

test_receipt_is_written_only_after_a_2xx() {
  local home rc code
  home=$(make_home only-2xx)
  status_line "$home" demo 'done: needs a real 2xx'
  for code in 500 404 302 FAIL; do
    http_code "$home" "$code"
    rc=$(outbox "$home" --status "$home/state/demo.status")
    expect_code 1 "$rc" "HTTP $code was reported as delivered"
    [ -z "$(sole_receipt "$home")" ] || fail "HTTP $code wrote a delivered receipt"
    assert_absent "$home/state/flowy-last.md" "HTTP $code wrote the display snapshot"
    [ "$(pending_count "$home")" = 1 ] || fail "HTTP $code did not keep the result pending"
  done
  http_code "$home" 201
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "HTTP 201 was not accepted as delivered"
  assert_contains "$(cat "$(sole_receipt "$home")")" "delivered: HTTP 201" \
    "the receipt did not record the 2xx that authorized it"
  pass "a delivered receipt exists only after a 2xx"
}

test_missing_webhook_config_keeps_the_result_pending() {
  local home rc
  home=$(make_home no-config)
  rm -f "$home/config/grok-flowy-webhook"
  status_line "$home" demo 'done: nowhere to send yet'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 1 "$rc" "a missing endpoint reported success"
  [ "$(pending_count "$home")" = 1 ] || fail "a missing endpoint discarded the result"
  assert_absent "$home/state/flowy-last.md" "a missing endpoint still wrote the display snapshot"
  assert_contains "$(cat "$home/err.log")" "missing Flowy webhook URL" "no actionable diagnostic"
  pass "an unreachable configuration keeps the result pending instead of losing it"
}

test_empty_drain_is_a_silent_no_op() {
  local home rc
  home=$(make_home empty-drain)
  rm -f "$home/config/grok-flowy-webhook"
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "an empty drain failed"
  [ -z "$(calls "$home")" ] || fail "an empty drain contacted the endpoint"
  assert_absent "$home/state/flowy-last.md" "an empty drain wrote the display snapshot"
  pass "an empty drain is a silent no-op that needs no configuration"
}

test_dry_run_writes_nothing() {
  local home rc
  home=$(make_home dry-run)
  status_line "$home" demo 'done: not really'
  rc=$(outbox "$home" --status "$home/state/demo.status" --dry-run)
  expect_code 0 "$rc" "the dry run failed"
  [ -z "$(calls "$home")" ] || fail "the dry run contacted the endpoint"
  assert_absent "$home/state/flowy-last.md" "the dry run overwrote the display snapshot"
  assert_absent "$home/state/flowy-outbox/pending" "the dry run recorded a pending result"
  pass "a dry run reports without writing a record, a receipt, or the snapshot"
}

test_non_result_status_is_a_no_op() {
  local home rc
  home=$(make_home non-result)
  status_line "$home" demo 'working: still on it'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "a non-result status failed"
  [ -z "$(calls "$home")" ] || fail "a non-result status was sent to Flowy"
  assert_absent "$home/state/flowy-last.md" "a non-result status wrote a receipt"
  pass "outbox ignores non-result status lines"
}

test_record_only_mode_performs_no_network_io() {
  local home rc calls_before keychain_before
  home=$(make_home record-only)
  status_line "$home" alpha 'done: alpha shipped'
  rc=$(outbox "$home" --status "$home/state/alpha.status")
  expect_code 0 "$rc" "alpha did not deliver"

  calls_before=$(call_count "$home")
  keychain_before=$(keychain_count "$home")
  status_line "$home" beta 'done: beta shipped'
  rc=$(outbox "$home" --status "$home/state/beta.status" --no-drain)
  expect_code 0 "$rc" "record-only mode reported a failure for a recorded result"
  [ "$(call_count "$home")" = "$calls_before" ] || fail "record-only mode contacted the endpoint"
  [ "$(keychain_count "$home")" = "$keychain_before" ] || fail "record-only mode read the Keychain"
  [ "$(pending_count "$home")" = 1 ] || fail "record-only mode left no durable record"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 1 ] || fail "record-only mode wrote a receipt"
  assert_grep 'pending: beta' "$home/state/flowy-last.md" \
    "record-only mode did not refresh the snapshot's pending line"

  # Recording never depends on the endpoint being configured at all.
  rm -f "$home/config/grok-flowy-webhook"
  status_line "$home" gamma 'done: gamma shipped'
  rc=$(outbox "$home" --status "$home/state/gamma.status" --no-drain)
  expect_code 0 "$rc" "record-only mode failed without an endpoint configuration"
  [ "$(pending_count "$home")" = 2 ] || fail "record-only mode dropped a result with no endpoint"

  rc=$(outbox "$home" --drain --no-drain)
  expect_code 2 "$rc" "--drain --no-drain was accepted as a usable run"
  pass "record-only mode records durably with no network, Keychain, or endpoint access"
}

test_snapshot_names_the_newest_delivered_result() {
  local home rc
  home=$(make_home newest)
  status_line "$home" zeta 'done: zeta shipped'
  rc=$(outbox "$home" --status "$home/state/zeta.status" --no-drain)
  expect_code 0 "$rc" "recording zeta failed"
  # Back to back on purpose: both records land in the same wall-clock second, so
  # nothing but the monotonic ordinal can tell which result is the newer one.
  status_line "$home" alpha 'done: alpha shipped'
  rc=$(outbox "$home" --status "$home/state/alpha.status" --no-drain)
  expect_code 0 "$rc" "recording alpha failed"
  [ "$(pending_count "$home")" = 2 ] || fail "two recorded results did not leave two pending records"

  # alpha is the newer result but collates first, so a collation-ordered drain
  # would finish on zeta and hand the snapshot the older of the two.
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "the drain did not deliver both records"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || fail "one drain did not deliver both records"
  assert_grep 'status: alpha: done: alpha shipped' "$home/state/flowy-last.md" \
    "the snapshot named an older delivered result than the newest one"
  pass "one drain of several records leaves the newest delivered result in the snapshot"
}

test_a_held_back_record_never_drags_the_snapshot_backwards() {
  local home rc
  home=$(make_home snapshot-monotonic)
  status_line "$home" zeta 'done: zeta shipped'
  rc=$(outbox "$home" --status "$home/state/zeta.status" --no-drain)
  expect_code 0 "$rc" "recording zeta failed"
  status_line "$home" alpha 'done: alpha shipped'
  rc=$(outbox "$home" --status "$home/state/alpha.status" --no-drain)
  expect_code 0 "$rc" "recording alpha failed"

  # One pass, mixed outcomes. zeta is the OLDER record and is rejected per-record
  # with a 503, which is record-specific, so the pass keeps going and alpha - the
  # newer result - is accepted.
  http_code "$home" 200
  http_code_for "$home" zeta 503
  rc=$(outbox "$home" --drain)
  expect_code 1 "$rc" "a pass that left a record pending reported a clean drain"
  assert_grep 'status: alpha: done: alpha shipped' "$home/state/flowy-last.md" \
    "the newer delivered result never reached the snapshot"
  assert_grep 'pending: zeta' "$home/state/flowy-last.md" \
    "the held-back record is missing from the pending line"

  # The next pass retires zeta. It is genuinely the older result, so the display
  # must keep naming alpha and only zeta's pending entry may move.
  clear_http_code_for "$home" zeta
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "the retry did not deliver the held-back record"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || fail "both results did not leave receipts"
  assert_grep 'status: alpha: done: alpha shipped' "$home/state/flowy-last.md" \
    "delivering the older held-back record dragged the snapshot back to it"
  assert_grep 'pending: (none)' "$home/state/flowy-last.md" "a drained outbox still reported pending work"
  pass "delivering a held-back older record never drags the snapshot backwards"
}

test_snapshot_pending_line_tracks_undelivered_results() {
  local home rc
  home=$(make_home pending-line)
  status_line "$home" alpha 'done: alpha shipped'
  rc=$(outbox "$home" --status "$home/state/alpha.status")
  expect_code 0 "$rc" "alpha did not deliver"
  assert_grep 'pending: (none)' "$home/state/flowy-last.md" "a drained outbox did not report (none)"

  http_code "$home" 503
  status_line "$home" beta 'done: beta shipped'
  rc=$(outbox "$home" --status "$home/state/beta.status")
  expect_code 1 "$rc" "beta's failed POST reported success"
  assert_grep 'pending: beta' "$home/state/flowy-last.md" \
    "the snapshot claimed nothing was pending while beta sat undelivered in the outbox"
  # A pass that delivered nothing may move pending: and nothing else.
  assert_grep 'status: alpha: done: alpha shipped' "$home/state/flowy-last.md" \
    "a failed POST moved the snapshot's status line"
  assert_grep 'files: ' "$home/state/flowy-last.md" "a failed POST dropped the snapshot's files line"
  assert_grep 'HEARTBEAT:' "$home/state/flowy-last.md" "a failed POST dropped the snapshot's heartbeat line"

  http_code "$home" 200
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "beta's retry did not deliver"
  assert_grep 'pending: (none)' "$home/state/flowy-last.md" "a drained outbox still reported pending work"
  pass "the snapshot's pending line tracks undelivered results without gaining delivery authority"
}

test_a_dead_endpoint_costs_one_attempt_per_drain() {
  local home rc task before
  home=$(make_home dead-endpoint)
  for task in alpha beta gamma; do
    status_line "$home" "$task" "done: $task shipped"
    rc=$(outbox "$home" --status "$home/state/$task.status" --no-drain)
    expect_code 0 "$rc" "recording $task failed"
  done
  [ "$(pending_count "$home")" = 3 ] || fail "three results did not leave three pending records"

  # A per-record HTTP code is record-specific, so the pass keeps going.
  http_code "$home" 503
  before=$(call_count "$home")
  rc=$(outbox "$home" --drain)
  expect_code 1 "$rc" "a wholly undelivered drain reported success"
  [ "$((  $(call_count "$home") - before ))" = 3 ] || fail "a 503 stopped the drain before the last record"

  # A transport failure is endpoint-wide, so one attempt settles the whole pass.
  http_code "$home" FAIL
  before=$(call_count "$home")
  rc=$(outbox "$home" --drain)
  expect_code 1 "$rc" "a dead endpoint reported a successful drain"
  [ "$((  $(call_count "$home") - before ))" = 1 ] || \
    fail "a dead endpoint was retried per record instead of once per drain"
  [ "$(pending_count "$home")" = 3 ] || fail "a dead endpoint retired or dropped a pending record"
  [ -z "$(sole_receipt "$home")" ] || fail "a dead endpoint wrote a delivered receipt"

  http_code "$home" 200
  rc=$(outbox "$home" --drain)
  expect_code 0 "$rc" "the recovered endpoint did not deliver every record"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 3 ] || fail "the recovered drain lost a record"
  [ "$(pending_count "$home")" = 0 ] || fail "a delivered result stayed pending"
  pass "a dead endpoint costs one attempt per drain and retires nothing differently"
}

test_same_result_text_from_a_new_event_is_delivered_again() {
  local home rc before
  home=$(make_home repeat-event)
  status_line "$home" demo 'blocked: waiting on captain decision'
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "the first blocked result did not deliver"
  before=$(call_count "$home")

  # Re-observing the very same bytes is still a no-op: the de-duplication the
  # watcher relies on has not been traded away.
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "re-observing an unchanged status failed"
  [ "$(call_count "$home")" = "$before" ] || fail "an unchanged status was POSTed a second time"

  # The captain resolves it, work resumes, and the task blocks again on the
  # identical templated line. That is a new event, not a re-observation.
  printf 'working: resumed after the decision\nblocked: waiting on captain decision\n' \
    > "$home/state/demo.status"
  rc=$(outbox "$home" --status "$home/state/demo.status")
  expect_code 0 "$rc" "the second block did not deliver"
  [ "$(call_count "$home")" -gt "$before" ] || \
    fail "a new event carrying identical result text was never sent"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || \
    fail "the repeated result did not get its own receipt"
  pass "identical result text from a genuinely new event is recorded and delivered again"
}

# Every watcher case drives the real bin/fm-watch.sh. The two drain ceilings are
# shortened so a hung endpoint does not make the suite wait out the production
# defaults; a later assignment in "$@" overrides either of them. They stay well
# above the time a stubbed drain needs to fork, source its libraries, take the
# lock and POST, because a ceiling that cuts off a HEALTHY stubbed drain would
# fail the delivery cases under concurrent suite load rather than bound anything.
start_watcher() {  # <home> [extra env assignments...]
  local home=$1
  shift
  env -u FLOWY_WEBHOOK_URL PATH="$home/fakebin:$PATH" \
    FLOWY_TEST_CODE="$home/http-code" FLOWY_TEST_CALLS="$home/curl.calls" \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FLOWY_EXIT_DRAIN_SECONDS=6 FM_FLOWY_DRAIN_SECONDS=6 "$@" \
    "$ROOT/bin/fm-watch.sh" >>"$home/watch.out" 2>>"$home/watch.err" &
}

# Wait for a watcher to end on its own, as it does after a wake.
await_watcher_exit() {  # <pid> <deciseconds> <message>
  local pid=$1 limit=$2 i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "$3"
  fi
  wait "$pid" 2>/dev/null || true
}

await_call_count_above() {  # <home> <count> <deciseconds>
  local home=$1 floor=$2 limit=$3 i=0 seen
  while [ "$i" -lt "$limit" ]; do
    seen=$(call_count "$home")
    [ -n "$seen" ] || seen=0
    [ "$seen" -le "$floor" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# state/flowy-outbox/.drain.lock is the outbox's own one-drain-at-a-time lock,
# taken for the whole pass and released at the end of it. Its absence is the
# observable "no drain is running for this home right now".
await_drain_lock_clear() {  # <home> <deciseconds>
  local lock="$1/state/flowy-outbox/.drain.lock" limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The signal path detaches its drain on purpose, so it routinely outlives the
# watcher process that started it. A test that reads a call count or starts a
# NEW generation before that child is done would otherwise attribute one
# generation's POST to another, or make the next generation's drain fail on the
# lock rather than on the response the case is actually exercising. Settled
# means the POST has landed AND the drain that made it has released the lock.
await_detached_drain_settled() {  # <home> <floor> <deciseconds>
  local home=$1 floor=$2 limit=$3
  await_call_count_above "$home" "$floor" "$limit" || return 1
  await_drain_lock_clear "$home" "$limit"
}

# The acceptance path the incident actually needed: the watcher advances its seen
# markers after one attempt, so the retry can only come from a later pass.
test_watcher_retries_a_failed_delivery_on_a_later_pass() {
  local home pid i=0 receipt after_first
  home=$(make_home watcher)
  http_code "$home" 503
  status_line "$home" demo 'done: watcher result'

  # First generation: the signal path records, the wake fires, and the drain it
  # detached makes a REAL POST that the endpoint rejects with 503. That child is
  # built to outlive the watcher, so settle it before reading any count.
  start_watcher "$home"
  pid=$!
  await_watcher_exit "$pid" 200 "watcher did not surface the terminal result"
  await_detached_drain_settled "$home" 0 300 || \
    fail "the first watcher generation never attempted a delivery, so nothing failed to retry"
  after_first=$(call_count "$home")
  [ "$(pending_count "$home")" = 1 ] || fail "the watcher's failed delivery left nothing to retry"
  [ -z "$(sole_receipt "$home")" ] || fail "the watcher wrote a receipt without a 2xx"

  # Second generation: the status signal is already seen, so nothing records and
  # nothing detaches. The only POST that can raise the count past the settled
  # floor above is the per-pass drain retrying on its own - and it fails against
  # 503 exactly as the first did.
  start_watcher "$home"
  pid=$!
  await_call_count_above "$home" "$after_first" 200 || \
    fail "a later watcher pass never retried the failed delivery"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(pending_count "$home")" = 1 ] || fail "a failed per-pass drain discarded the result"
  [ -z "$(sole_receipt "$home")" ] || fail "a failed per-pass drain wrote a receipt without a 2xx"
  await_drain_lock_clear "$home" 300 || \
    fail "the second generation's drain never released the outbox lock"

  # Third generation: the endpoint recovers and the per-pass drain delivers.
  http_code "$home" 200
  start_watcher "$home"
  pid=$!
  while [ "$i" -lt 200 ]; do
    receipt=$(sole_receipt "$home")
    [ -z "$receipt" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -n "$receipt" ] || fail "a later watcher pass never retried the failed delivery to success"
  assert_contains "$(cat "$receipt")" "status: demo: done: watcher result" \
    "the retried delivery recorded the wrong result"
  [ "$(pending_count "$home")" = 0 ] || fail "the retried result stayed pending"
  pass "a later watcher pass retries a failed delivery to success"
}

test_watcher_delivers_the_result_it_recorded_without_a_second_generation() {
  local home pid receipt
  home=$(make_home detached-prompt)
  status_line "$home" demo 'done: prompt result'

  start_watcher "$home"
  pid=$!
  await_watcher_exit "$pid" 200 "watcher did not surface the terminal result"

  # No second generation ever runs, so only the drain the recording pass detached
  # can deliver this. It outlives the watcher by design, and it retires the record
  # after writing the receipt, so settle it before reading either.
  await_detached_drain_settled "$home" 0 300 || \
    fail "the detached drain never reached the endpoint"
  receipt=$(sole_receipt "$home")
  [ -n "$receipt" ] || fail "the detached drain never delivered the recorded result"
  assert_contains "$(cat "$receipt")" "status: demo: done: prompt result" \
    "the detached drain delivered the wrong result"
  [ "$(pending_count "$home")" = 0 ] || fail "a delivered result stayed pending"
  pass "a result recorded on a watcher pass is delivered without a second generation"
}

test_a_hung_endpoint_never_delays_the_watcher_exit() {
  local home pid started elapsed baseline rc i
  home=$(make_home detached-bound)
  status_line "$home" demo 'done: hung result'

  # Baseline: the same wake with a healthy endpoint, which is the promptness the
  # hung run must match. A synchronous drain would make the hung run far slower.
  baseline=$(make_home detached-baseline)
  status_line "$baseline" demo 'done: baseline result'
  started=$SECONDS
  start_watcher "$baseline"
  pid=$!
  await_watcher_exit "$pid" 300 "the baseline watcher did not surface its result"
  baseline=$((SECONDS - started))

  http_code "$home" HANG
  started=$SECONDS
  start_watcher "$home" FM_FLOWY_EXIT_DRAIN_SECONDS=8
  pid=$!
  # The stub hangs 60s and the detached bound is 8s. If the drain were in the
  # poll body or the EXIT trap, the wake would be held for one of those.
  await_watcher_exit "$pid" 300 "a hung endpoint held the watcher process"
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt $((baseline + 5)) ] || \
    fail "a hung endpoint delayed the watcher exit by ${elapsed}s against a ${baseline}s baseline"

  [ "$(pending_count "$home")" = 1 ] || fail "a hung endpoint lost the recorded result"
  [ -z "$(sole_receipt "$home")" ] || fail "a hung endpoint wrote a receipt without a 2xx"
  assert_absent "$home/state/flowy-last.md" "a hung endpoint wrote the display snapshot"

  # The bound tears the hung child down, by its TERM handler or by the KILL
  # backstop behind it. Either way the lock must come back - released cleanly or
  # taken over from a dead owner - so a later drain can still deliver. A
  # permanently wedged lock never satisfies this, it just runs out the window.
  http_code "$home" 200
  i=0
  rc=1
  while [ "$i" -lt 250 ]; do
    rc=$(outbox "$home" --drain)
    [ "$rc" != 0 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  expect_code 0 "$rc" "a torn-down detached drain wedged the outbox lock against the next drain"
  [ "$(pending_count "$home")" = 0 ] || fail "the later drain did not deliver the pending result"
  pass "a hung endpoint never delays the watcher exit and never wedges the next drain"
}

test_a_hung_endpoint_cannot_stall_the_poll_loop() {
  local home rc pid started elapsed i
  home=$(make_home pass-drain-bound)
  status_line "$home" queued 'done: queued before the outage'
  rc=$(outbox "$home" --status "$home/state/queued.status" --no-drain)
  expect_code 0 "$rc" "recording the queued result failed"

  # The per-pass drain now has a record to send and the endpoint hangs 60s per
  # POST. Its ceiling is what lets the signal scan below it still run this pass.
  http_code "$home" HANG
  status_line "$home" demo 'done: new result during the outage'

  started=$SECONDS
  start_watcher "$home"
  pid=$!
  await_watcher_exit "$pid" 400 "a hung per-pass drain stalled the watcher's poll loop"
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 30 ] || \
    fail "the per-pass drain took ${elapsed}s, so its wall-clock ceiling did not bind"

  [ -n "$(calls "$home")" ] || fail "the per-pass drain never reached the endpoint at all"
  [ "$(pending_count "$home")" = 2 ] || fail "a ceiling-cut drain retired or dropped a record"
  [ -z "$(sole_receipt "$home")" ] || fail "a ceiling-cut drain wrote a receipt without a 2xx"

  http_code "$home" 200
  i=0
  rc=1
  while [ "$i" -lt 250 ]; do
    rc=$(outbox "$home" --drain)
    [ "$rc" != 0 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  expect_code 0 "$rc" "the records left pending by the ceiling were not delivered later"
  [ "$(sole_receipt "$home" | wc -l | tr -d ' ')" = 2 ] || fail "the later drain lost a record"
  pass "a hung endpoint cannot stall the poll loop past the per-pass drain's ceiling"
}

# FM_POLL is a documented knob that takes fractional seconds, and this repo's own
# suite runs watchers at FM_POLL=0.2. With no ceiling configured the watcher
# derives one from POLL, so a fractional poll must still leave the per-pass drain
# enough room to POST rather than tearing it down before it reaches the endpoint.
test_a_fractional_poll_still_drains_pending_records() {
  local home rc pid receipt= i=0
  home=$(make_home fractional-poll)
  status_line "$home" queued 'done: fractional poll result'
  rc=$(outbox "$home" --status "$home/state/queued.status" --no-drain)
  expect_code 0 "$rc" "recording the queued result failed"
  [ "$(pending_count "$home")" = 1 ] || fail "nothing was left pending for the drain to deliver"

  # With the status file gone the watcher observes no terminal signal, so nothing
  # records and nothing detaches a drain. The per-pass drain is then the only
  # thing that can deliver this record.
  rm -f "$home/state/queued.status"

  start_watcher "$home" FM_POLL=0.2 FM_FLOWY_DRAIN_SECONDS=
  pid=$!
  while [ "$i" -lt 300 ]; do
    receipt=$(sole_receipt "$home")
    [ -z "$receipt" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ -n "$receipt" ] || fail "a fractional FM_POLL left the per-pass drain unable to deliver"
  assert_contains "$(cat "$receipt")" "status: queued: done: fractional poll result" \
    "the per-pass drain delivered the wrong result"
  [ "$(pending_count "$home")" = 0 ] || fail "the delivered result stayed pending"
  pass "a fractional FM_POLL still leaves the per-pass drain a usable ceiling"
}

test_delivers_from_url_file_and_keychain_with_no_env_var
test_the_bearer_key_never_reaches_the_process_table
test_failed_post_retries_to_success_after_a_restart
test_two_results_never_overwrite_each_other
test_second_result_for_one_task_gets_its_own_record
test_re_recording_one_result_does_not_resend_it
test_receipt_is_written_only_after_a_2xx
test_missing_webhook_config_keeps_the_result_pending
test_empty_drain_is_a_silent_no_op
test_dry_run_writes_nothing
test_non_result_status_is_a_no_op
test_record_only_mode_performs_no_network_io
test_snapshot_names_the_newest_delivered_result
test_a_held_back_record_never_drags_the_snapshot_backwards
test_snapshot_pending_line_tracks_undelivered_results
test_a_dead_endpoint_costs_one_attempt_per_drain
test_same_result_text_from_a_new_event_is_delivered_again
test_watcher_retries_a_failed_delivery_on_a_later_pass
test_watcher_delivers_the_result_it_recorded_without_a_second_generation
test_a_hung_endpoint_never_delays_the_watcher_exit
test_a_hung_endpoint_cannot_stall_the_poll_loop
test_a_fractional_poll_still_drains_pending_records
