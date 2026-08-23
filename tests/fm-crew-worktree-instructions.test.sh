#!/usr/bin/env bash
# Behavior tests for crew worktree instruction overlay.
#
# When a crew or scout lands in a firstmate-repo worktree, harnesses auto-load
# AGENTS.md and CLAUDE.md as project instructions. Those files are the firstmate
# job description, which outranks the launch brief and inverts the worker's
# role. These tests prove the inversion is gone at the auto-load corpus, not
# that a warning string exists: after overlay, the files a harness would load
# no longer contain the firstmate identity line, while git HEAD still does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-crew-worktree-instructions-lib.sh
. "$ROOT/bin/fm-crew-worktree-instructions-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-worktree-instructions)
fm_git_identity fmtest fmtest@example.invalid

IDENTITY_LINE='You are the first mate.'
OVERLAY_MARKER='<!-- firstmate-crew-worktree-instructions -->'
GUIDELINES_REL='.agents/skills/firstmate-coding-guidelines/SKILL.md'

autoload_corpus() {  # <worktree>
  local wt=$1
  cat "$wt/AGENTS.md"
  [ -f "$wt/CLAUDE.md" ] && cat "$wt/CLAUDE.md"
}

assert_corpus_is_crew() {  # <worktree> <msg>
  local wt=$1 msg=$2 corpus
  corpus=$(autoload_corpus "$wt")
  assert_not_contains "$corpus" "$IDENTITY_LINE" "$msg: auto-loaded files still present firstmate identity"
  assert_contains "$corpus" "You are a crewmate" "$msg: auto-loaded files missing crew identity"
  assert_contains "$corpus" "$GUIDELINES_REL" "$msg: auto-loaded files missing coding-guidelines pointer"
  assert_contains "$corpus" "$OVERLAY_MARKER" "$msg: auto-loaded files missing overlay marker"
}

assert_skip_worktree() {  # <worktree> <rel> <msg>
  local wt=$1 rel=$2 msg=$3 state
  state=$(git -C "$wt" ls-files -v -- "$rel" | awk '{print substr($1,1,1)}')
  [ "$state" = S ] || fail "$msg ($rel ls-files -v='$state')"
}

make_firstmate_repo() {  # <dir>
  local repo=$1
  mkdir -p "$repo/bin" "$repo/.agents/skills/firstmate-coding-guidelines"
  git init -q -b main "$repo"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' > "$repo/AGENTS.md"
  printf '%s\n' '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' '@AGENTS.md' > "$repo/CLAUDE.md"
  printf '%s\n' '#!/bin/sh' 'echo session-start' > "$repo/bin/fm-session-start.sh"
  printf '%s\n' '#!/bin/sh' 'echo spawn' > "$repo/bin/fm-spawn.sh"
  chmod +x "$repo/bin/fm-session-start.sh" "$repo/bin/fm-spawn.sh"
  printf '%s\n' '# firstmate-coding-guidelines fixture' > "$repo/$GUIDELINES_REL"
  git -C "$repo" add AGENTS.md CLAUDE.md bin .agents
  git -C "$repo" commit -qm 'firstmate-shaped fixture'
}

make_linked_worktree() {  # <repo> <worktree>
  local repo=$1 worktree=$2
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet --detach "$worktree"
}

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

test_overlay_inverts_autoload_corpus() {
  local repo wt corpus_before out
  repo="$TMP_ROOT/invert-repo"
  wt="$TMP_ROOT/invert-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  corpus_before=$(autoload_corpus "$wt")
  assert_contains "$corpus_before" "$IDENTITY_LINE" \
    "fixture failed to present firstmate identity before overlay"
  out=$(fm_install_crew_worktree_instructions "$wt" 2>&1) || fail "overlay install failed: $out"
  assert_corpus_is_crew "$wt" "after overlay"
  assert_contains "$(git -C "$wt" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "committed AGENTS.md lost firstmate identity"
  assert_present "$wt/$GUIDELINES_REL" "coding guidelines skill disappeared from the worktree"
  assert_skip_worktree "$wt" AGENTS.md "AGENTS.md overlay was not hidden from git"
  assert_skip_worktree "$wt" CLAUDE.md "CLAUDE.md overlay was not hidden from git"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "overlay left the worktree dirty: $(git -C "$wt" status --porcelain)"
  pass "overlay removes firstmate identity from the auto-load corpus and keeps the committed job"
}

test_overlay_is_idempotent() {
  local repo wt
  repo="$TMP_ROOT/idem-repo"
  wt="$TMP_ROOT/idem-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_install_crew_worktree_instructions "$wt" || fail "first overlay install failed"
  fm_install_crew_worktree_instructions "$wt" || fail "second overlay install failed"
  assert_corpus_is_crew "$wt" "idempotent overlay"
  pass "overlay install is idempotent"
}

test_dirty_agents_md_is_saved_then_overlaid() {
  local repo wt
  repo="$TMP_ROOT/wip-repo"
  wt="$TMP_ROOT/wip-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_install_crew_worktree_instructions "$wt" || fail "initial overlay failed"
  git -C "$wt" update-index --no-skip-worktree -- AGENTS.md
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'worker edit to the real job description' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" || fail "overlay after dirty AGENTS.md failed"
  assert_present "$wt/.fm-agents-md-edit" "dirty AGENTS.md was not saved before overlay"
  assert_grep "worker edit to the real job description" "$wt/.fm-agents-md-edit" \
    "saved WIP omitted the worker's AGENTS.md edit"
  assert_corpus_is_crew "$wt" "after saving dirty AGENTS.md"
  pass "in-progress AGENTS.md edits are saved, then the overlay is reinstalled"
}

test_ordinary_project_is_untouched() {
  local repo wt before after
  repo="$TMP_ROOT/ordinary-repo"
  wt="$TMP_ROOT/ordinary-wt"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  printf '%s\n' 'You are a helpful project assistant.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm ordinary
  make_linked_worktree "$repo" "$wt"
  before=$(cat "$wt/AGENTS.md")
  fm_install_crew_worktree_instructions "$wt" || fail "ordinary project overlay should be a no-op"
  after=$(cat "$wt/AGENTS.md")
  [ "$before" = "$after" ] || fail "ordinary project AGENTS.md was rewritten"
  pass "non-firstmate project worktrees are left unchanged"
}

test_secondmate_home_is_untouched() {
  local home before after
  home="$TMP_ROOT/secondmate-home"
  make_firstmate_repo "$home"
  printf '%s\n' 'mate-1' > "$home/.fm-secondmate-home"
  before=$(cat "$home/AGENTS.md")
  fm_install_crew_worktree_instructions "$home" || fail "secondmate overlay should be a no-op"
  after=$(cat "$home/AGENTS.md")
  [ "$before" = "$after" ] || fail "secondmate home AGENTS.md was rewritten"
  assert_contains "$after" "$IDENTITY_LINE" "secondmate home lost firstmate identity"
  pass "secondmate homes keep the firstmate job description"
}

test_primary_checkout_is_refused() {
  local repo out status
  repo="$TMP_ROOT/primary-repo"
  make_firstmate_repo "$repo"
  out=$(fm_install_crew_worktree_instructions "$repo" 2>&1); status=$?
  expect_code 1 "$status" "overlay onto a primary checkout must refuse"
  assert_contains "$out" "primary checkout" "primary refusal did not name the primary checkout"
  assert_contains "$(cat "$repo/AGENTS.md")" "$IDENTITY_LINE" \
    "refused primary overlay still rewrote AGENTS.md"
  pass "overlay refuses a primary checkout and leaves it unchanged"
}

test_unknown_agents_md_is_refused() {
  local repo wt out status
  repo="$TMP_ROOT/unknown-repo"
  wt="$TMP_ROOT/unknown-wt"
  make_firstmate_repo "$repo"
  printf '%s\n' 'unexpected instructions' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'unknown agents'
  make_linked_worktree "$repo" "$wt"
  out=$(fm_install_crew_worktree_instructions "$wt" 2>&1); status=$?
  expect_code 1 "$status" "unknown AGENTS.md must refuse rather than overlay"
  assert_contains "$out" "neither firstmate identity nor the crew overlay" \
    "unknown-AGENTS.md refusal did not name the unexpected file"
  assert_contains "$(cat "$wt/AGENTS.md")" "unexpected instructions" \
    "unknown AGENTS.md was rewritten"
  pass "a firstmate-shaped worktree with unknown AGENTS.md refuses loudly"
}

test_missing_guidelines_is_refused() {
  local repo wt out status
  repo="$TMP_ROOT/noguide-repo"
  wt="$TMP_ROOT/noguide-wt"
  make_firstmate_repo "$repo"
  rm -f "$repo/$GUIDELINES_REL"
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'drop guidelines'
  make_linked_worktree "$repo" "$wt"
  out=$(fm_install_crew_worktree_instructions "$wt" 2>&1); status=$?
  expect_code 1 "$status" "missing coding guidelines must refuse the overlay"
  assert_contains "$out" "firstmate-coding-guidelines is missing" \
    "missing-guidelines refusal did not name the skill"
  assert_contains "$(cat "$wt/AGENTS.md")" "$IDENTITY_LINE" \
    "refused overlay still rewrote AGENTS.md"
  pass "overlay refuses when coding guidelines would be unreachable"
}

test_session_start_forbidden_predicate() {
  local repo wt home
  repo="$TMP_ROOT/ss-pred-repo"
  wt="$TMP_ROOT/ss-pred-wt"
  home="$TMP_ROOT/ss-pred-plain"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  make_firstmate_repo "$home"
  fm_crew_session_start_is_forbidden "$wt" \
    || fail "linked firstmate worktree should forbid session start"
  if fm_crew_session_start_is_forbidden "$home"; then
    fail "plain firstmate checkout should still allow session start"
  fi
  pass "session-start predicate forbids only linked firstmate worktrees"
}

test_session_start_refuses_linked_worktree() {
  local repo wt home out status
  repo="$TMP_ROOT/ss-repo"
  wt="$TMP_ROOT/ss-wt"
  home="$TMP_ROOT/ss-home"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(
    FM_HOME="$home" FM_ROOT_OVERRIDE="$wt" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$SESSION_START" 2>&1
  ); status=$?
  expect_code 2 "$status" "session start in a crew worktree must exit 2"
  assert_contains "$out" "crewmate worktree of firstmate" \
    "session-start refusal did not name the crewmate case"
  assert_absent "$home/state/.lock" "session start wrote a lock in a crew worktree"
  pass "session start refuses a linked firstmate worktree with no digest and no lock"
}

test_spawn_overlays_firstmate_shaped_pool() {
  local case_dir home project origin pool fakebin id out status
  id='crew-role-overlay-s1'
  case_dir="$TMP_ROOT/spawn-case"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  make_firstmate_repo "$project"
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pool" \
      PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --scout 2>&1
  ); status=$?
  expect_code 0 "$status" "spawn of a firstmate-shaped pool should succeed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_corpus_is_crew "$pool" "spawned firstmate-repo worktree"
  assert_contains "$(git -C "$pool" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "spawn overlay replaced the committed firstmate job"
  [ -z "$(git -C "$pool" status --porcelain)" ] \
    || fail "spawn overlay left the pool dirty: $(git -C "$pool" status --porcelain)"
  pass "spawn overlays a firstmate-repo crew worktree before launch"
}

test_overlay_inverts_autoload_corpus
test_overlay_is_idempotent
test_dirty_agents_md_is_saved_then_overlaid
test_ordinary_project_is_untouched
test_secondmate_home_is_untouched
test_primary_checkout_is_refused
test_unknown_agents_md_is_refused
test_missing_guidelines_is_refused
test_session_start_forbidden_predicate
test_session_start_refuses_linked_worktree
test_spawn_overlays_firstmate_shaped_pool
