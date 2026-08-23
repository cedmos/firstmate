#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's brief-content gate.
#
# A brief truncated to zero bytes used to satisfy the existence check and launch
# an agent that had nothing to read: the worker sat at an idle prompt while the
# task recorded as spawned, so the fleet view showed dispatched work that was
# never started. These tests drive the real spawn path and prove all three
# outcomes through its exit status and messages: an empty brief is refused, a
# missing brief is still refused under its OWN distinct message, and an ordinary
# brief still launches a worker.
#
# The two refusal cases are reached before any tmux/treehouse side effect, so
# they create no windows or worktrees. The launch case needs the full fixture
# (fake terminal, real git origin and pooled worktree) because proving "still
# launches" honestly means reaching `spawned <id>`, not just clearing the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-empty-brief)
export FM_BACKEND=tmux

# Fake terminal for the launch case: enough tmux surface for fm-spawn to create
# and address an endpoint, plus a no-op treehouse so no real pool is allocated.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_home <name> -> "<home>|<project>|<fakebin>": a firstmate home plus a plain
# project checkout. Enough for the cases that refuse before the worktree is
# touched. It still builds the fake terminal, so that a REGRESSION of the gate
# under test cannot reach the real treehouse pool and strand a worktree lease on
# a fixture repo the temp-root cleanup then deletes. The test must stay hermetic
# in the failing direction too, not only when it passes.
make_home() {
  local name=$1 case_dir home project fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$project"
  printf '%s\n' "$home|$project|$fakebin"
}

# make_launchable_case <name> <id> -> "<home>|<project>|<pool>|<fakebin>": the
# full fixture a real launch needs - a bare origin the pooled worktree can be
# refreshed from, and a fake terminal to launch into.
make_launchable_case() {
  local name=$1 id=$2 case_dir home project origin pool fakebin head
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$head"

  printf '%s\n' "$home|$project|$pool|$fakebin"
}

# Clear ambient firstmate overrides so each case owns its environment.
run_spawn() {  # <home> <project> <id> [extra spawn args...]
  local home=$1 project=$2 id=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$project" "$@" 2>&1
}

# The defect itself: a brief that exists but holds nothing must not launch an
# agent. The refusal must also happen before any task record is written, so a
# zero-byte brief can never leave a task looking dispatched.
test_empty_brief_refuses_the_spawn() {
  local rec home project fakebin id out status
  id='empty-brief-refused-e1'
  rec=$(make_home empty-brief)
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  mkdir -p "$home/data/$id"
  : > "$home/data/$id/brief.md"
  [ ! -s "$home/data/$id/brief.md" ] || fail "fixture did not produce a zero-byte brief"

  out=$(TMUX="fake,1,0" FM_FAKE_PANE_PATH="$project" PATH="$fakebin:$PATH" \
    run_spawn "$home" "$project" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched an agent against a zero-byte brief"
  assert_contains "$out" "the brief at $home/data/$id/brief.md is empty" \
    "refusal did not name the empty brief"
  assert_not_contains "$out" 'spawned ' "spawn reported a launch despite an empty brief"
  assert_absent "$home/state/$id.meta" "an empty-brief spawn still recorded a task endpoint"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed refusal: %s\n' "$(printf '%s\n' "$out" | grep -F 'is empty' | head -n 1)"
  fi
  pass "a zero-byte brief refuses the spawn before any task endpoint exists"
}

# Empty and missing are different faults with different fixes, so they must not
# collapse into one message: an operator who reads "no brief" goes looking for a
# file that is in fact sitting right there.
test_missing_brief_keeps_its_own_message() {
  local rec home project fakebin empty_out missing_out empty_id missing_id status
  empty_id='empty-brief-distinct-e2'
  missing_id='missing-brief-distinct-e3'
  rec=$(make_home distinct-messages)
  IFS='|' read -r home project fakebin <<EOF
$rec
EOF
  mkdir -p "$home/data/$empty_id"
  : > "$home/data/$empty_id/brief.md"

  missing_out=$(TMUX="fake,1,0" FM_FAKE_PANE_PATH="$project" PATH="$fakebin:$PATH" \
    run_spawn "$home" "$project" "$missing_id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded with no brief at all"
  assert_absent "$home/data/$missing_id/brief.md" "fixture unexpectedly created the missing brief"
  assert_contains "$missing_out" "error: no brief at $home/data/$missing_id/brief.md" \
    "a missing brief lost its own refusal message"
  assert_not_contains "$missing_out" 'is empty' \
    "a missing brief was reported as an empty one"

  empty_out=$(TMUX="fake,1,0" FM_FAKE_PANE_PATH="$project" PATH="$fakebin:$PATH" \
    run_spawn "$home" "$project" "$empty_id" --mode no-mistakes --yolo off)
  assert_not_contains "$empty_out" 'error: no brief at' \
    "an empty brief was reported as a missing one"
  pass "empty and missing briefs refuse under separate, non-interchangeable messages"
}

# The gate must not cost a legitimate dispatch: an ordinary brief still reaches a
# real launch. Asserted through `spawned <id>` and the recorded task endpoint,
# not by re-checking the guard's own condition.
test_normal_brief_still_launches() {
  local rec home project pool fakebin id out status
  id='normal-brief-launches-e4'
  rec=$(make_launchable_case normal-brief "$id")
  IFS='|' read -r home project pool fakebin <<EOF
$rec
EOF
  printf 'Real instructions for %s.\n' "$id" > "$home/data/$id/brief.md"
  [ -s "$home/data/$id/brief.md" ] || fail "fixture did not produce a non-empty brief"

  out=$(TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pool" PATH="$fakebin:$PATH" \
    run_spawn "$home" "$project" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an ordinary brief should still launch"
  assert_contains "$out" "spawned $id" "spawn did not report a launch for a valid brief"
  assert_present "$home/state/$id.meta" "a launched task recorded no endpoint"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed launch: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an ordinary brief still launches a worker through the same gate"
}

test_empty_brief_refuses_the_spawn
test_missing_brief_keeps_its_own_message
test_normal_brief_still_launches
