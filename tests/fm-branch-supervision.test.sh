#!/usr/bin/env bash
# Tests for the Pi supervision branch's fleet-record layer
# (docs/pi-supervision-branch.md): the byte-stable branch prompt generator
# (bin/fm-branch-prompt.sh), the append-only outcome store
# (bin/fm-branch-outcome.sh), the per-task lease contract (bin/fm-lease.sh,
# bin/fm-lease-lib.sh), the lease and role-partition guards wired into the
# mutating entrypoints, and the proof that a home which never runs the branch
# is untouched by all of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-supervision)

# --- byte-stable branch prompt ------------------------------------------------

test_branch_prompt_is_byte_stable_and_above_cache_floor() {
  local home_a home_b out_a out_b out_c size
  home_a="$TMP_ROOT/prompt-home-a"
  home_b="$TMP_ROOT/prompt-home-b"
  mkdir -p "$home_a/state" "$home_b/state"
  # Give the two homes deliberately different fleet state and clock context:
  # a byte-stable prompt must not absorb any of it.
  printf 'signal: task-1 done\n' > "$home_a/state/task-1.status"
  printf 'window=x\nharness=pi\n' > "$home_a/state/task-1.meta"

  out_a=$(cd "$TMP_ROOT" && FM_HOME="$home_a" TZ=UTC "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home A"
  out_b=$(cd / && FM_HOME="$home_b" TZ=Australia/Eucla "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home B"
  sleep 1
  out_c=$("$ROOT/bin/fm-branch-prompt.sh") || fail "branch prompt generator failed on re-run"

  [ "$out_a" = "$out_b" ] || fail "branch prompt differs across homes/cwd/timezone: prefix stability broken"
  [ "$out_a" = "$out_c" ] || fail "branch prompt differs across runs at different times: prefix stability broken"

  # Below the provider's 1024-token caching minimum a branch prompt gets no
  # cache reuse at all (measured in the feasibility evidence), so hold a
  # comfortable byte floor.
  size=${#out_a}
  [ "$size" -ge 5000 ] || fail "branch prompt is only $size bytes - below the provider caching minimum"
  case "$out_a" in
    "You are the SUPERVISION BRANCH"*) ;;
    *) fail "branch prompt lost its role preamble" ;;
  esac
  case "$out_a" in
    *"stuck-crewmate-recovery"*) ;;
    *) fail "branch prompt lost the inlined recovery playbook" ;;
  esac
  pass "branch prompt is byte-stable across homes, cwd, timezone, and time, above the cache floor"
}

# --- append-only outcome store ------------------------------------------------

test_outcome_store_is_append_only_with_cursor_reads() {
  local home store snapshot seq1 seq2 unread replay
  home="$TMP_ROOT/store-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  seq1=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker healthy, "quoted" text kept' --wake 'signal: working') \
    || fail "first append failed"
  [ "$seq1" = 1 ] || fail "first outcome seq was $seq1, not 1"
  seq2=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'PR https://example.com/pr/2 checks green') \
    || fail "second append failed"
  [ "$seq2" = 2 ] || fail "second outcome seq was $seq2, not 2"

  # The store is the owned durable contract: every line stays valid JSON.
  python3 - "$store" <<'PY' || fail "outcome store holds invalid JSON"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row["seq"] for row in rows] == [1, 2], rows
assert rows[0]["verdict"] == "routine" and rows[1]["verdict"] == "captain", rows
assert rows[0]["summary"] == 'worker healthy, "quoted" text kept', rows[0]
PY

  # mark-read moves only the cursor sidecar; the log bytes never change.
  snapshot=$(cat "$store")
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "mark-read failed"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "unread failed"
  case "$unread" in
    '{"seq":2,'*) ;;
    *) fail "unread did not return exactly the records above the cursor: $unread" ;;
  esac
  [ "$(cat "$store")" = "$snapshot" ] || fail "mark-read rewrote the append-only store"

  # startup-replay surfaces the unread remainder once, then goes silent, and
  # later appends land strictly after the earlier bytes (append-only merge).
  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "startup-replay failed"
  assert_contains "$replay" "BRANCH OUTCOMES" "replay lost its section header"
  assert_contains "$replay" "https://example.com/pr/2" "replay lost the unread outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay)" ] \
    || fail "startup-replay re-presented already-read outcomes"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict routine --summary 'later outcome' >/dev/null || fail "third append failed"
  case "$(cat "$store")" in
    "$snapshot"*) ;;
    *) fail "a later append disturbed earlier store bytes" ;;
  esac
  pass "outcome store is append-only with cursor-based unread reads and one-shot startup replay"
}

# --- lease contract -----------------------------------------------------------

test_lease_exclusivity_release_stale_and_sweep() {
  local home out status
  home="$TMP_ROOT/lease-home"
  mkdir -p "$home/state"

  # Claim, exclusivity, same-actor refresh.
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch \
    || fail "branch claim failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1) || fail "check missed a held lease"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "check misreported the lease: $out" ;;
  esac
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not the lease refusal 6"
  assert_contains "$out" "leased to the branch supervision actor" "refusal did not name the holder"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 \
    || fail "same-actor refresh was refused"

  for round in $(seq 1 12); do
    task="race-$round"
    (FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim "$task" --actor main \
      >"$home/main-$round.out" 2>&1; echo $? >"$home/main-$round.status") &
    main_pid=$!
    (FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim "$task" --actor branch \
      >"$home/branch-$round.out" 2>&1; echo $? >"$home/branch-$round.status") &
    branch_pid=$!
    wait "$main_pid" "$branch_pid"
    main_status=$(cat "$home/main-$round.status")
    branch_status=$(cat "$home/branch-$round.status")
    case "$main_status:$branch_status" in
      0:6|6:0) ;;
      *) fail "concurrent claims did not produce one winner for $task: main=$main_status branch=$branch_status" ;;
    esac
    out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check "$task") || fail "concurrent winner left no lease for $task"
    case "$main_status:$out" in
      0:"main "*) ;;
      6:"branch "*) ;;
      *) fail "lease holder disagreed with the concurrent winner for $task: $out" ;;
    esac
  done

  # Release by holder name; release of an unheld lease stays a silent no-op.
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "release failed"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1 >/dev/null && fail "released lease still reported"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "idempotent release failed"

  # A lease held by a dead process is stale: claimable by the other actor and
  # removed by the sweep, while a live lease survives the sweep.
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-dead \
    || fail "stale lease blocked a live claim"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-dead)
  case "$out" in "main $$ "*) ;; *) fail "stale lease was not taken over: $out" ;; esac
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead2"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-dead2" ] || fail "sweep left a provably stale lease"
  [ -e "$home/state/.lease-task-dead" ] || fail "sweep removed a live lease"

  # The reserved backlog resource claims like any task.
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog --actor branch \
    || fail "backlog lease claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog 2>&1)
  [ $? -eq 6 ] || fail "backlog lease did not enforce exclusivity"
  pass "lease exclusivity, same-actor refresh, release, staleness, and sweep hold"
}

# --- guards in the mutating entrypoints ---------------------------------------

test_mutating_scripts_refuse_the_other_actors_lease() {
  local home root out status
  home="$TMP_ROOT/guard-home"
  root="$TMP_ROOT/guard-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor branch \
    || fail "fixture lease claim failed"

  # fm-control: refused while the branch holds the lease; the ordinary no-task
  # error (a different failure) proves pass-through once the lease is gone.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-control exited $status, not 6: $out"
  assert_contains "$out" "leased to the branch supervision actor" "fm-control refusal lost the holder"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-unheld interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "unleased fm-control still hit the lease refusal"
  assert_contains "$out" "no task 'task-unheld'" "unleased fm-control lost its ordinary error"

  # fm-teardown: same refusal shape before any teardown work.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-held 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-teardown exited $status, not 6: $out"
  assert_contains "$out" "teardown (fm-teardown) refused" "fm-teardown refusal lost its action label"

  # The same lease refuses the BRANCH actor when MAIN holds it - the guard is
  # symmetric, not a branch-only fence.
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" release task-held --actor branch
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor main \
    || fail "main fixture claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch actor bypassed main's lease: $status: $out"
  assert_contains "$out" "leased to the main supervision actor" "symmetric refusal lost the holder"
  pass "fm-control and fm-teardown refuse the other actor's live lease and pass through otherwise"
}

test_main_owned_actions_refuse_the_branch_actor() {
  local home root out status
  home="$TMP_ROOT/partition-home"
  root="$TMP_ROOT/partition-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-pr-merge.sh" task-x https://github.com/o/r/pull/1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-pr-merge exited $status, not 6: $out"
  assert_contains "$out" "the supervision branch never performs this action" "pr-merge refusal lost the partition wording"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-merge-local exited $status, not 6: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-new --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-spawn exited $status, not 6: $out"
  assert_contains "$out" "new-task spawn (fm-spawn) refused" "spawn refusal lost its action label"

  # The same calls as MAIN fail on their ORDINARY validation instead - the
  # partition guard never fires for the main actor.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "main fm-merge-local hit the partition refusal"
  assert_contains "$out" "no meta for task task-x" "main fm-merge-local lost its ordinary error"
  pass "PR merge, local landing, and new-task spawn refuse the branch actor and spare main"
}

test_home_without_branch_is_untouched() {
  local home out status
  home="$TMP_ROOT/untouched-home"
  mkdir -p "$home/state"

  # No lease files, no actor variable: the guard layer must be invisible - the
  # scripts fail (or succeed) exactly on their pre-existing logic, and nothing
  # branch-related appears in state/.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-any interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "no-branch home hit a lease refusal in fm-control"
  assert_contains "$out" "no task 'task-any'" "no-branch fm-control lost its ordinary error"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-pr-merge.sh" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no-branch fm-pr-merge usage error changed: $status: $out"
  [ -z "$(find "$home/state" -name '.lease-*' -o -name 'branch-outcomes*' -o -name '.branch-*' 2>/dev/null)" ] \
    || fail "guard layer created branch state in a home that never ran the branch"

  # The guard helpers themselves: silent pass with no lease and no actor.
  out=$(STATE="$home/state" bash -c '. "$1"; fm_lease_guard task-any "probe"; fm_lease_forbid_branch "probe"; echo silent-pass' _ "$ROOT/bin/fm-lease-lib.sh" 2>&1)
  [ "$out" = "silent-pass" ] || fail "guard helpers were not silent in a no-branch home: $out"
  pass "a home that never runs the branch sees no lease files, no refusals, and no new state"
}

test_branch_prompt_is_byte_stable_and_above_cache_floor
test_outcome_store_is_append_only_with_cursor_reads
test_lease_exclusivity_release_stale_and_sweep
test_mutating_scripts_refuse_the_other_actors_lease
test_main_owned_actions_refuse_the_branch_actor
test_home_without_branch_is_untouched
