#!/usr/bin/env bash
# Behavior tests for crew worktree instruction overlay.
#
# When a crew or scout lands in a firstmate-repo worktree, harnesses auto-load
# AGENTS.md and CLAUDE.md as project instructions. Those files are the firstmate
# job description, which outranks the launch brief and inverts the worker's
# role. These tests prove the inversion is gone at the auto-load corpus, not
# that a warning string exists: after overlay, the files a harness would load
# no longer contain the firstmate identity line, while git HEAD still does.
# The overlay's live-fire consequences are exercised through real git and the
# real consumers: a commit that would silently drop an edit to a skip-worktree
# instruction file is refused, so is one that would commit the overlay itself
# or leave a saved sidecar behind, a pooled worktree returned with the overlay
# still installed can be refreshed onto a moved default branch instead of
# wedging, and the brief-mandated bin/fm-ensure-agents-md.sh stays a no-op
# success in an overlaid worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-crew-worktree-instructions-lib.sh
. "$ROOT/bin/fm-crew-worktree-instructions-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
ENSURE_AGENTS_MD="$ROOT/bin/fm-ensure-agents-md.sh"
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

assert_not_skip_worktree() {  # <worktree> <rel> <msg>
  local wt=$1 rel=$2 msg=$3 state
  state=$(git -C "$wt" ls-files -v -- "$rel" | awk '{print substr($1,1,1)}')
  [ "$state" = S ] && fail "$msg ($rel is still skip-worktree)"
  return 0
}

commit_all() {  # <worktree> <message>
  local wt=$1 msg=$2
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" commit -am "$msg" 2>&1
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

overlaid_worktree() {  # <repo> <worktree>
  local repo=$1 wt=$2
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_install_crew_worktree_instructions "$wt" || fail "overlay install failed for $wt"
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
  if fm_file_is_crew_overlay "$wt/CLAUDE.md"; then
    fail "CLAUDE.md was overlaid with the crew body instead of the canonical @AGENTS.md pointer"
  fi
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

test_identity_line_matches_shipped_agents_md() {
  local shipped
  shipped="$TMP_ROOT/shipped-AGENTS.md"
  if fm_file_is_crew_overlay "$ROOT/AGENTS.md"; then
    git -C "$ROOT" show HEAD:AGENTS.md > "$shipped" \
      || fail "could not read the committed AGENTS.md of this checkout"
  else
    cp "$ROOT/AGENTS.md" "$shipped" || fail "could not read this checkout's AGENTS.md"
  fi
  fm_file_presents_firstmate_identity "$shipped" \
    || fail "the identity predicate no longer recognizes this checkout's own AGENTS.md, so every firstmate-repo crew and scout spawn would refuse"
  pass "the shipped AGENTS.md still satisfies the identity predicate the overlay gates on"
}

test_commit_guard_refuses_a_mutated_overlay_file() {
  local repo wt head_before out status
  repo="$TMP_ROOT/guard-fail-repo"
  wt="$TMP_ROOT/guard-fail-wt"
  overlaid_worktree "$repo" "$wt"
  head_before=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' 'a crewmate edit that must not vanish' >> "$wt/AGENTS.md"
  printf '%s\n' '#!/bin/sh' 'echo spawn v2' > "$wt/bin/fm-spawn.sh"
  out=$(commit_all "$wt" 'crew commit that would drop the AGENTS.md edit'); status=$?
  [ "$status" -ne 0 ] \
    || fail "commit succeeded even though it omitted the AGENTS.md edit: $out"
  assert_contains "$out" "AGENTS.md" "guard refusal did not name the file"
  assert_contains "$out" "would silently omit" \
    "guard refusal did not say the commit would omit the edit"
  assert_contains "$out" "git update-index --no-skip-worktree -- AGENTS.md && git checkout HEAD -- AGENTS.md" \
    "guard refusal did not name the restore commands"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "refused commit still moved HEAD"
  pass "a commit that would drop an edit to the overlaid AGENTS.md fails loudly"
}

test_commit_guard_allows_an_untouched_overlay() {
  local repo wt head_before out status
  repo="$TMP_ROOT/guard-pass-repo"
  wt="$TMP_ROOT/guard-pass-wt"
  overlaid_worktree "$repo" "$wt"
  head_before=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' 'ordinary crew work' > "$wt/NOTES.md"
  out=$(commit_all "$wt" 'ordinary crew commit'); status=$?
  expect_code 0 "$status" "an ordinary crew commit must not be blocked by the overlay: $out"
  [ "$(git -C "$wt" rev-parse HEAD)" != "$head_before" ] \
    || fail "the ordinary crew commit did not move HEAD"
  assert_contains "$(git -C "$wt" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "the crew commit committed the overlay over the firstmate job"
  assert_corpus_is_crew "$wt" "after an ordinary crew commit"
  pass "an ordinary crew commit succeeds while the overlay is untouched"
}

test_restored_agents_md_commits_the_edit() {
  local repo wt out status
  repo="$TMP_ROOT/guard-restore-repo"
  wt="$TMP_ROOT/guard-restore-wt"
  overlaid_worktree "$repo" "$wt"
  git -C "$wt" update-index --no-skip-worktree -- AGENTS.md \
    || fail "documented restore could not clear skip-worktree"
  git -C "$wt" checkout HEAD -- AGENTS.md || fail "documented restore could not check out AGENTS.md"
  printf '%s\n' 'A crewmate edited the real job description.' >> "$wt/AGENTS.md"
  out=$(commit_all "$wt" 'edit the committed AGENTS.md'); status=$?
  expect_code 0 "$status" "a commit after the documented restore must succeed: $out"
  assert_contains "$(git -C "$wt" show HEAD:AGENTS.md)" 'A crewmate edited the real job description.' \
    "the commit omitted the restored AGENTS.md edit"
  pass "after the documented restore the AGENTS.md edit lands in the commit"
}

test_ensure_agents_md_stays_a_no_op_after_overlay() {
  local repo wt agents_before claude_before out status
  repo="$TMP_ROOT/ensure-repo"
  wt="$TMP_ROOT/ensure-wt"
  overlaid_worktree "$repo" "$wt"
  agents_before=$(git -C "$wt" hash-object -- "$wt/AGENTS.md")
  claude_before=$(git -C "$wt" hash-object -- "$wt/CLAUDE.md")
  out=$("$ENSURE_AGENTS_MD" "$wt" 2>&1); status=$?
  expect_code 0 "$status" "the brief-mandated project-memory step must succeed in an overlaid worktree: $out"
  assert_not_contains "$out" "conflict" "fm-ensure-agents-md.sh reported a conflict in an overlaid worktree"
  [ "$(git -C "$wt" hash-object -- "$wt/AGENTS.md")" = "$agents_before" ] \
    || fail "fm-ensure-agents-md.sh rewrote the overlaid AGENTS.md"
  [ "$(git -C "$wt" hash-object -- "$wt/CLAUDE.md")" = "$claude_before" ] \
    || fail "fm-ensure-agents-md.sh rewrote the overlaid CLAUDE.md"
  assert_corpus_is_crew "$wt" "after the project-memory step"
  pass "fm-ensure-agents-md.sh is a no-op success in an overlaid firstmate worktree"
}

test_commit_guard_refuses_committing_the_overlay() {
  local repo wt head_before out status
  repo="$TMP_ROOT/guard-overlay-repo"
  wt="$TMP_ROOT/guard-overlay-wt"
  overlaid_worktree "$repo" "$wt"
  head_before=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-index --no-skip-worktree -- AGENTS.md \
    || fail "could not clear skip-worktree for the half-restore case"
  out=$(commit_all "$wt" 'commit the crew overlay over the committed job'); status=$?
  [ "$status" -ne 0 ] \
    || fail "commit succeeded and replaced the committed AGENTS.md with the crew overlay: $out"
  assert_contains "$out" "carrying the crew overlay" \
    "guard refusal did not say the overlay would be committed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "refused commit still moved HEAD"
  assert_contains "$(git -C "$wt" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "the committed AGENTS.md was replaced by the crew overlay"
  pass "a commit that would record the crew overlay over the committed file fails loudly"
}

test_commit_guard_refuses_while_a_saved_sidecar_survives() {
  local repo wt head_before out status
  repo="$TMP_ROOT/guard-sidecar-repo"
  wt="$TMP_ROOT/guard-sidecar-wt"
  overlaid_worktree "$repo" "$wt"
  git -C "$wt" update-index --no-skip-worktree -- AGENTS.md \
    || fail "documented restore could not clear skip-worktree"
  git -C "$wt" checkout HEAD -- AGENTS.md || fail "documented restore could not check out AGENTS.md"
  printf '%s\n' 'restored-file work the relaunch must not sideline' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 2>/dev/null \
    || fail "relaunch overlay reinstall failed"
  assert_present "$wt/.fm-agents-md-edit" "relaunch did not save the restored AGENTS.md work"
  head_before=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' 'ordinary crew work' > "$wt/NOTES.md"
  out=$(commit_all "$wt" 'crew commit while the sidecar still holds work'); status=$?
  [ "$status" -ne 0 ] \
    || fail "commit succeeded while the saved AGENTS.md work was still sidelined: $out"
  assert_contains "$out" ".fm-agents-md-edit" "guard refusal did not name the sidecar"
  assert_contains "$out" "this commit would omit them" \
    "guard refusal did not say the sidelined work would be omitted"
  assert_contains "$out" "cp .fm-agents-md-edit AGENTS.md" \
    "guard refusal did not name how to restore from the sidecar"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "refused commit still moved HEAD"
  pass "a commit made while a relaunch sidelined instruction-file work fails loudly"
}

test_removal_drops_saved_sidecars() {
  local repo wt
  repo="$TMP_ROOT/sidecar-reuse-repo"
  wt="$TMP_ROOT/sidecar-reuse-wt"
  overlaid_worktree "$repo" "$wt"
  git -C "$wt" update-index --no-skip-worktree -- AGENTS.md
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'work belonging to the previous task' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 2>/dev/null || fail "overlay reinstall failed"
  assert_present "$wt/.fm-agents-md-edit" "fixture did not produce a saved sidecar"
  fm_remove_crew_worktree_instructions "$wt" || fail "overlay removal failed"
  assert_absent "$wt/.fm-agents-md-edit" "overlay removal kept the previous task's saved AGENTS.md edits"
  assert_absent "$wt/.fm-claude-md-edit" "overlay removal kept a saved CLAUDE.md sidecar"
  fm_install_crew_worktree_instructions "$wt" || fail "overlay reinstall after removal failed"
  assert_absent "$wt/.fm-agents-md-edit" "a previous task's sidecar reappeared for the next worker"
  pass "saved instruction sidecars do not survive overlay removal into the next task"
}

test_removal_unwedges_a_pooled_reset() {
  local repo wt out status
  repo="$TMP_ROOT/reuse-repo"
  wt="$TMP_ROOT/reuse-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'move AGENTS.md on main'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  if git -C "$wt" reset --hard origin/main >/dev/null 2>&1; then
    fail "fixture did not reproduce the wedged reset of a pooled worktree"
  fi
  fm_remove_crew_worktree_instructions "$wt" || fail "overlay removal failed"
  assert_not_skip_worktree "$wt" AGENTS.md "removal left AGENTS.md skip-worktree"
  assert_not_skip_worktree "$wt" CLAUDE.md "removal left CLAUDE.md skip-worktree"
  assert_contains "$(cat "$wt/AGENTS.md")" "$IDENTITY_LINE" \
    "removal did not restore the committed AGENTS.md"
  out=$(git -C "$wt" reset --hard origin/main 2>&1); status=$?
  expect_code 0 "$status" "reset onto a new AGENTS.md blob must succeed after removal: $out"
  assert_contains "$(cat "$wt/AGENTS.md")" 'Main moved on.' \
    "the reset worktree is not on the new base"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "removal left the worktree dirty: $(git -C "$wt" status --porcelain)"
  pass "removal clears the overlay so a pooled worktree can be reset onto a new base"
}

make_spawn_case() {  # <case-dir>
  local case_dir=$1 origin
  SPAWN_HOME="$case_dir/home"
  SPAWN_PROJECT="$case_dir/project"
  SPAWN_POOL="$case_dir/pool"
  origin="$case_dir/origin.git"
  SPAWN_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$SPAWN_HOME/data" "$SPAWN_HOME/projects" "$SPAWN_HOME/state" "$SPAWN_HOME/config"
  printf 'codex\n' > "$SPAWN_HOME/config/crew-harness"
  touch "$SPAWN_HOME/state/.last-watcher-beat"
  make_firstmate_repo "$SPAWN_PROJECT"
  git clone --quiet --bare "$SPAWN_PROJECT" "$origin"
  git -C "$SPAWN_PROJECT" remote add origin "file://$origin"
  git -C "$SPAWN_PROJECT" worktree add --quiet --detach "$SPAWN_POOL" HEAD
}

spawn_into_pool() {  # <id>
  local id=$1
  mkdir -p "$SPAWN_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$SPAWN_HOME/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$SPAWN_POOL" \
    PATH="$SPAWN_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$SPAWN_PROJECT" --scout 2>&1
}

test_spawn_overlays_firstmate_shaped_pool() {
  local id out status
  id='crew-role-overlay-s1'
  make_spawn_case "$TMP_ROOT/spawn-case"
  out=$(spawn_into_pool "$id"); status=$?
  expect_code 0 "$status" "spawn of a firstmate-shaped pool should succeed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_corpus_is_crew "$SPAWN_POOL" "spawned firstmate-repo worktree"
  assert_contains "$(git -C "$SPAWN_POOL" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "spawn overlay replaced the committed firstmate job"
  [ -z "$(git -C "$SPAWN_POOL" status --porcelain)" ] \
    || fail "spawn overlay left the pool dirty: $(git -C "$SPAWN_POOL" status --porcelain)"
  pass "spawn overlays a firstmate-repo crew worktree before launch"
}

test_spawn_reuses_a_pool_the_previous_crew_overlaid() {
  local out status
  make_spawn_case "$TMP_ROOT/reuse-spawn-case"
  out=$(spawn_into_pool 'crew-role-reuse-a1'); status=$?
  expect_code 0 "$status" "first spawn into the pool should succeed: $out"
  assert_corpus_is_crew "$SPAWN_POOL" "first spawn"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$SPAWN_PROJECT/AGENTS.md"
  git -C "$SPAWN_PROJECT" add AGENTS.md
  git -C "$SPAWN_PROJECT" commit -qm 'move AGENTS.md on main'
  git -C "$SPAWN_PROJECT" push -q origin main
  out=$(spawn_into_pool 'crew-role-reuse-b2'); status=$?
  expect_code 0 "$status" "spawn into a pool the previous crew overlaid should succeed: $out"
  assert_corpus_is_crew "$SPAWN_POOL" "second spawn"
  assert_contains "$(git -C "$SPAWN_POOL" show HEAD:AGENTS.md)" 'Main moved on.' \
    "the reused pool was not refreshed onto the new default branch"
  [ -z "$(git -C "$SPAWN_POOL" status --porcelain)" ] \
    || fail "reused pool is dirty: $(git -C "$SPAWN_POOL" status --porcelain)"
  pass "a pooled worktree the previous crew overlaid still refreshes and spawns"
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
test_identity_line_matches_shipped_agents_md
test_commit_guard_refuses_a_mutated_overlay_file
test_commit_guard_allows_an_untouched_overlay
test_restored_agents_md_commits_the_edit
test_ensure_agents_md_stays_a_no_op_after_overlay
test_commit_guard_refuses_committing_the_overlay
test_commit_guard_refuses_while_a_saved_sidecar_survives
test_removal_drops_saved_sidecars
test_removal_unwedges_a_pooled_reset
test_spawn_overlays_firstmate_shaped_pool
test_spawn_reuses_a_pool_the_previous_crew_overlaid
