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
# real consumers, and the two properties the mechanism exists to hold are
# asserted directly: a branch move onto a commit carrying a different AGENTS.md
# stays escapable by the worker with the remedy git itself names, and a second
# relaunch preserves the first relaunch's saved edits instead of destroying
# them. Saved edits are also proven to belong to the task that saved them: the
# next occupant of a pooled slot cannot be handed or restore the previous task's
# edits, and recovery with nothing of its own refuses loudly naming the refs it
# searched. Alongside those, a commit that would record the overlay over
# firstmate's own file is refused, an edit made on top of the overlay is never
# dropped silently, the cleanliness filter separates launch scaffolding from real
# uncommitted work, a pooled worktree can be reset onto a moved default branch
# with the overlay still installed, a worktree left behind by the superseded
# skip-worktree mechanism is healed without losing either its sidelined edit or a
# live one on the same path, the worker-facing status reports an overlay only
# when one is really installed, and the brief-mandated bin/fm-ensure-agents-md.sh
# stays a no-op success in an overlaid worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-crew-worktree-instructions-lib.sh
. "$ROOT/bin/fm-crew-worktree-instructions-lib.sh"
# For fm_task_id_creation_valid, so the awkward-ref-name case is pinned to an id
# firstmate itself accepts rather than one invented by this test.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
ENSURE_AGENTS_MD="$ROOT/bin/fm-ensure-agents-md.sh"
CREW_INSTRUCTIONS="$ROOT/bin/fm-crew-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-worktree-instructions)
fm_git_identity fmtest fmtest@example.invalid

IDENTITY_LINE='You are the first mate.'
OVERLAY_MARKER='<!-- firstmate-crew-worktree-instructions -->'
GUIDELINES_REL='.agents/skills/firstmate-coding-guidelines/SKILL.md'
# Accepted by fm_task_id_creation_valid, refused by git as a ref component: it
# both contains `..` and ends in `.lock`.
AWKWARD_TASK_ID='probe..v2.lock'

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

# The overlay must never be hidden behind skip-worktree or assume-unchanged:
# those bits make git report a clean worktree over a divergent file, which
# wedges every branch move while `git stash` saves nothing.
assert_visible_to_git() {  # <worktree> <rel> <msg>
  local wt=$1 rel=$2 msg=$3 state
  state=$(git -C "$wt" ls-files -v -- "$rel" | awk '{print substr($1,1,1)}')
  case $state in
    S | [a-z]) fail "$msg ($rel ls-files -v='$state')" ;;
  esac
  return 0
}

assert_status_contains() {  # <worktree> <expected-line> <msg>
  local wt=$1 expected=$2 msg=$3 status
  status=$(git -C "$wt" status --porcelain)
  case $status in
    *"$expected"*) return 0 ;;
  esac
  fail "$msg (git status --porcelain was '$status')"
}

stash_count() {  # <worktree>
  git -C "$1" stash list | grep -c . || true
}

wip_ref_count() {  # <worktree> <owner>
  fm_crew_list_wip_refs "$1" "$2" | grep -c . || true
}

saved_agents_md() {  # <worktree> <owner> <n>
  git -C "$1" show "$(wip_ref "$1" "$2" "$3"):AGENTS.md" 2>&1
}

# The <n>th entry's ref for <owner>, derived the way the library derives it
# rather than spelled out, so a namespace change stays a single-place change.
wip_ref() {  # <worktree> <owner> <n>
  printf '%s/%s\n' "$(fm_crew_wip_ref_base "$1" "$2")" "$3"
}

# The restore command a report advertised for <rel>, taken from the report the
# way a worker reads it, so running it proves the advice actually works.
advertised_restore() {  # <report> <rel>
  local report=$1 rel=$2 line
  while IFS= read -r line; do
    case $line in
      *"$rel: git checkout "*) printf '%s\n' "${line#*"$rel": }"; return 0 ;;
      *"restore it with: git checkout "*"-- $rel"*) printf '%s\n' "${line#*restore it with: }"; return 0 ;;
    esac
  done <<EOF
$report
EOF
  return 1
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

overlaid_worktree() {  # <repo> <worktree> [task-id]
  local repo=$1 wt=$2 id=${3:-overlay-task-t1}
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_install_crew_worktree_instructions "$wt" "$id" || fail "overlay install failed for $wt"
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
  assert_visible_to_git "$wt" AGENTS.md "AGENTS.md overlay was hidden from git"
  assert_visible_to_git "$wt" CLAUDE.md "CLAUDE.md overlay was hidden from git"
  if fm_file_is_crew_overlay "$wt/CLAUDE.md"; then
    fail "CLAUDE.md was overlaid with the crew body instead of the canonical @AGENTS.md pointer"
  fi
  assert_status_contains "$wt" " M AGENTS.md" \
    "the overlay must be an ordinary visible modification, not a hidden one"
  [ -z "$(git -C "$wt" status --porcelain | fm_crew_filter_overlay_status "$wt")" ] \
    || fail "overlay left work a cleanliness check reads as unlanded: $(git -C "$wt" status --porcelain)"
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
  fm_install_crew_worktree_instructions "$wt" 'wip-task-w1' || fail "initial overlay failed"
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'worker edit to the real job description' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'wip-task-w1' 2>/dev/null \
    || fail "overlay after dirty AGENTS.md failed"
  expect_code 1 "$(wip_ref_count "$wt" 'wip-task-w1')" \
    "the in-progress AGENTS.md edit was not saved under the task's own ref"
  assert_contains "$(saved_agents_md "$wt" 'wip-task-w1' 1)" 'worker edit to the real job description' \
    "the saved entry omitted the worker's AGENTS.md edit"
  expect_code 0 "$(stash_count "$wt")" "the save reached for the shared stash stack instead of its own ref"
  assert_corpus_is_crew "$wt" "after saving dirty AGENTS.md"
  pass "in-progress AGENTS.md edits go to the task's own ref, then the overlay is reinstalled"
}

# The redesign's core claim: relaunching twice must not destroy the first
# relaunch's saved edits. A private sidecar was cp-overwritten with no error; a
# fresh per-task ref per save leaves both entries independently addressable.
test_two_relaunches_keep_both_saved_edits() {
  local repo wt
  repo="$TMP_ROOT/relaunch-repo"
  wt="$TMP_ROOT/relaunch-wt"
  overlaid_worktree "$repo" "$wt" 'relaunch-task-r1'
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'EDIT E1 from the first incarnation' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'relaunch-task-r1' 2>/dev/null \
    || fail "first relaunch overlay failed"
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'EDIT E2 from the second incarnation' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'relaunch-task-r1' 2>/dev/null \
    || fail "second relaunch overlay failed"
  expect_code 2 "$(wip_ref_count "$wt" 'relaunch-task-r1')" \
    "two relaunches did not leave two recoverable entries"
  assert_contains "$(saved_agents_md "$wt" 'relaunch-task-r1' 1)" 'EDIT E1 from the first incarnation' \
    "the second relaunch destroyed the first relaunch's saved edit"
  assert_contains "$(saved_agents_md "$wt" 'relaunch-task-r1' 2)" 'EDIT E2 from the second incarnation' \
    "the second relaunch did not save its own edit"
  assert_not_contains "$(saved_agents_md "$wt" 'relaunch-task-r1' 2)" 'EDIT E1 from the first incarnation' \
    "the two saved entries are not independent of each other"
  assert_corpus_is_crew "$wt" "after two relaunches"
  pass "a second relaunch preserves the first relaunch's saved instruction edits"
}

# The carrier's whole point: an entry belongs to the task that saved it. A
# pooled slot's next occupant must not be handed, offered, or able to restore
# the previous task's instruction edits, and must be told so rather than
# silently getting nothing.
test_saved_edits_stay_with_the_task_that_saved_them() {
  local repo wt out status
  repo="$TMP_ROOT/owner-repo"
  wt="$TMP_ROOT/owner-wt"
  overlaid_worktree "$repo" "$wt" 'task-alpha-a1'
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'EDIT OWNED BY TASK ALPHA' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'task-alpha-a1' 2>/dev/null \
    || fail "task alpha's relaunch overlay failed"
  assert_contains "$(saved_agents_md "$wt" 'task-alpha-a1' 1)" 'EDIT OWNED BY TASK ALPHA' \
    "task alpha's edit was not saved under its own ref"
  # The slot is returned to the pool and a later crew takes it.
  fm_remove_crew_worktree_instructions "$wt" || fail "pooled removal failed"
  fm_install_crew_worktree_instructions "$wt" 'task-beta-b2' || fail "the next occupant's overlay failed"
  assert_not_contains "$(cat "$wt/AGENTS.md")" 'EDIT OWNED BY TASK ALPHA' \
    "the next occupant was handed the previous task's instruction edits"
  out=$("$CREW_INSTRUCTIONS" recover "$wt" 2>&1); status=$?
  expect_code 1 "$status" "the next occupant must not be able to restore another task's edits: $out"
  assert_contains "$out" 'task-beta-b2' "the refusal did not name the task it looked for"
  assert_contains "$out" "$(fm_crew_wip_ref_base "$wt" 'task-beta-b2')" \
    "the refusal did not name the ref namespace it searched"
  assert_not_contains "$(cat "$wt/AGENTS.md")" 'EDIT OWNED BY TASK ALPHA' \
    "the refused recovery still applied the previous task's edits"
  assert_contains "$(saved_agents_md "$wt" 'task-alpha-a1' 1)" 'EDIT OWNED BY TASK ALPHA' \
    "the next occupant destroyed the previous task's saved edit"
  pass "saved instruction edits stay with their own task and the next occupant is refused loudly"
}

test_recover_restores_this_task_s_own_saved_edit() {
  local repo wt out status advertised
  repo="$TMP_ROOT/recover-repo"
  wt="$TMP_ROOT/recover-wt"
  overlaid_worktree "$repo" "$wt" 'recover-task-c3'
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'THE EDIT THE WORKER WANTS BACK' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'recover-task-c3' 2>/dev/null || fail "relaunch overlay failed"
  out=$("$CREW_INSTRUCTIONS" saved "$wt" 2>&1); status=$?
  expect_code 0 "$status" "saved must list this task's own entries: $out"
  assert_contains "$out" "$(wip_ref "$wt" 'recover-task-c3' 1)" \
    "saved did not name the entry this task owns"
  advertised=$(advertised_restore "$out" AGENTS.md)
  [ -n "$advertised" ] || fail "saved advertised no restore command for AGENTS.md: $out"
  out=$("$CREW_INSTRUCTIONS" recover "$wt" 2>&1); status=$?
  expect_code 0 "$status" "recovering this task's own saved edit must succeed: $out"
  assert_contains "$(cat "$wt/AGENTS.md")" 'THE EDIT THE WORKER WANTS BACK' \
    "recover did not restore the saved edit into the working tree"
  assert_status_contains "$wt" " M AGENTS.md" "the recovered edit was left staged rather than uncommitted"
  # The advertised command must land the worker in the same state recover does.
  # `git checkout <ref> -- <path>` alone writes the index too, so following the
  # advice would otherwise leave the edit staged and the next plain commit would
  # land work-in-progress the worker never chose to commit.
  git -C "$wt" checkout HEAD -- AGENTS.md || fail "could not reset the fixture between the two paths"
  ( cd "$wt" && eval "$advertised" ) || fail "the advertised restore command failed: $advertised"
  assert_contains "$(cat "$wt/AGENTS.md")" 'THE EDIT THE WORKER WANTS BACK' \
    "the advertised restore command did not restore the saved edit"
  assert_status_contains "$wt" " M AGENTS.md" \
    "the advertised restore command left the edit staged, unlike recover itself"
  pass "recover and the command it advertises both restore the edit as an ordinary uncommitted change"
}

# A worker who staged one version and then edited further holds two distinct
# versions of their own work. The save restores the committed file, which
# rewrites the index as well as the file, so recording only what is on disk
# dropped the staged version with no error and still reported success.
test_a_staged_and_a_working_tree_version_both_survive_a_relaunch() {
  local repo wt staged_ref worktree_ref out status
  repo="$TMP_ROOT/staged-repo"
  wt="$TMP_ROOT/staged-wt"
  overlaid_worktree "$repo" "$wt" 'staged-task-s9'
  git -C "$wt" checkout HEAD -- AGENTS.md
  # S and W must genuinely diverge, not nest: a worker who stages one version
  # and then rewrites rather than appends holds work that exists in the staged
  # version and nowhere else, which is exactly what a worktree-only save drops.
  printf '%s\n' 'VERSION S the worker staged' >> "$wt/AGENTS.md"
  git -C "$wt" add AGENTS.md || fail "could not stage version S"
  # Rewrite the file only, so the index keeps S while the worktree moves to W.
  git -C "$wt" show HEAD:AGENTS.md > "$wt/AGENTS.md" \
    || fail "could not rewrite the working tree without touching the index"
  printf '%s\n' 'VERSION W the worker edited afterwards' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'staged-task-s9' 2>/dev/null \
    || fail "relaunch over a staged plus a working-tree version failed"
  expect_code 2 "$(wip_ref_count "$wt" 'staged-task-s9')" \
    "the staged version and the working-tree version did not both survive as entries"
  staged_ref=$(wip_ref "$wt" 'staged-task-s9' 1)
  worktree_ref=$(wip_ref "$wt" 'staged-task-s9' 2)
  assert_contains "$(git -C "$wt" show "$staged_ref:AGENTS.md")" 'VERSION S the worker staged' \
    "the staged version was dropped"
  assert_not_contains "$(git -C "$wt" show "$staged_ref:AGENTS.md")" 'VERSION W the worker edited afterwards' \
    "the staged entry holds the working-tree version instead of the staged one"
  assert_contains "$(git -C "$wt" show "$worktree_ref:AGENTS.md")" 'VERSION W the worker edited afterwards' \
    "the working-tree version was dropped"
  assert_not_contains "$(git -C "$wt" show "$worktree_ref:AGENTS.md")" 'VERSION S the worker staged' \
    "the fixture did not diverge the two versions, so nothing here would be lost either way"
  [ -z "$(git -C "$wt" diff --cached --name-only)" ] \
    || fail "the save left the staged version in the index: $(git -C "$wt" diff --cached --name-only)"
  out=$("$CREW_INSTRUCTIONS" saved "$wt" 2>&1); status=$?
  expect_code 0 "$status" "saved must list both entries: $out"
  assert_contains "$out" "$staged_ref" "saved omitted the staged entry"
  assert_contains "$out" "$worktree_ref" "saved omitted the working-tree entry"
  assert_contains "$out" 'staged instruction edits' "saved did not name the staged entry as staged"
  assert_contains "$out" 'working-tree instruction edits' \
    "saved did not name the working-tree entry as the working-tree one"
  # Both must be independently restorable through the commands saved prints.
  ( cd "$wt" && eval "$(fm_crew_restore_command "$staged_ref" AGENTS.md)" ) \
    || fail "the staged entry's advertised restore command failed"
  assert_contains "$(cat "$wt/AGENTS.md")" 'VERSION S the worker staged' \
    "the staged entry did not restore the version that was staged"
  assert_not_contains "$(cat "$wt/AGENTS.md")" 'VERSION W the worker edited afterwards' \
    "restoring the staged entry produced the working-tree version"
  ( cd "$wt" && eval "$(fm_crew_restore_command "$worktree_ref" AGENTS.md)" ) \
    || fail "the working-tree entry's advertised restore command failed"
  assert_contains "$(cat "$wt/AGENTS.md")" 'VERSION W the worker edited afterwards' \
    "the working-tree entry did not restore the version that was on disk"
  pass "a staged version and a working-tree version both survive a relaunch as separate entries"
}

# A task id firstmate itself issues must never block a launch. git's ref grammar
# rejects a component containing `..` or ending in `.lock`, and the task-id
# charset accepts both, so the namespace has to fold them out rather than let
# check-ref-format refuse and abort the spawn.
test_a_task_id_git_refuses_as_a_ref_component_still_launches() {
  local repo wt out status refs newest
  repo="$TMP_ROOT/refname-repo"
  wt="$TMP_ROOT/refname-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_task_id_creation_valid "$AWKWARD_TASK_ID" \
    || fail "the fixture id is not one firstmate itself accepts, so this case proves nothing"
  if git -C "$wt" check-ref-format "refs/fm-crew/$AWKWARD_TASK_ID/instruction-wip/1" 2>/dev/null; then
    fail "the fixture id is already a legal ref component, so this case proves nothing"
  fi
  printf '%s\n' 'AN EDIT UNDER AN AWKWARD TASK ID' >> "$wt/AGENTS.md"
  out=$(fm_install_crew_worktree_instructions "$wt" "$AWKWARD_TASK_ID" 2>&1); status=$?
  expect_code 0 "$status" "a task id firstmate accepts must not block the spawn: $out"
  refs=$(fm_crew_list_wip_refs "$wt" "$AWKWARD_TASK_ID")
  newest=$(printf '%s\n' "$refs" | tail -n 1)
  [ -n "$newest" ] || fail "the awkward task id yielded no saved-edit entry"
  assert_contains "$(git -C "$wt" show "$newest:AGENTS.md")" 'AN EDIT UNDER AN AWKWARD TASK ID' \
    "the edit was not saved under the awkward task id"
  assert_corpus_is_crew "$wt" "after installing under an awkward task id"
  pass "a task id git refuses as a ref component still launches and still saves its edits"
}

# A conflicted index carries three stages for the path and no merged version, so
# there is nothing single to record and no restore that would not collapse the
# conflict. Taking every stage recorded the MERGE BASE as the worker's staged
# edit and invented junk paths named after the other two hashes, then reported
# success. This is reachable by the route the redesign exists to unblock: remove
# the overlay, rebase onto origin/main after an AGENTS.md change, hit a conflict.
test_a_conflicted_instruction_file_refuses_the_save() {
  local repo wt out status
  repo="$TMP_ROOT/conflict-repo"
  wt="$TMP_ROOT/conflict-wt"
  overlaid_worktree "$repo" "$wt" 'conflict-task-x1'
  fm_remove_crew_worktree_instructions "$wt" || fail "overlay removal failed"
  git -C "$wt" checkout -q -b conflict-side
  printf '%s\n' "$IDENTITY_LINE" 'OURS DIVERGED HERE' > "$wt/AGENTS.md"
  git -C "$wt" commit -qam 'ours'
  printf '%s\n' "$IDENTITY_LINE" 'THEIRS DIVERGED HERE' > "$repo/AGENTS.md"
  git -C "$repo" commit -qam 'theirs'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  git -C "$wt" merge origin/main -m merge >/dev/null 2>&1 \
    && fail "the fixture did not produce a real merge conflict"
  [ -n "$(git -C "$wt" ls-files -u -- AGENTS.md)" ] \
    || fail "the fixture left no unmerged index stages, so this case proves nothing"
  out=$(fm_crew_save_instruction_wip "$wt" 'conflict-task-x1' 2>&1); status=$?
  expect_code 1 "$status" "a conflicted instruction file must refuse the save, not record a stage: $out"
  assert_contains "$out" 'AGENTS.md' "the refusal did not name the conflicted path"
  assert_contains "$out" 'unresolved merge conflicts' "the refusal did not say why it refused"
  expect_code 0 "$(wip_ref_count "$wt" 'conflict-task-x1')" \
    "the refused save still recorded an entry"
  # The conflict must survive the refusal rather than being collapsed away.
  [ -n "$(git -C "$wt" ls-files -u -- AGENTS.md)" ] \
    || fail "the refused save collapsed the worker's conflict"
  assert_contains "$(cat "$wt/AGENTS.md")" 'OURS DIVERGED HERE' \
    "the refused save overwrote the conflicted working tree"
  out=$(fm_install_crew_worktree_instructions "$wt" 'conflict-task-x1' 2>&1); status=$?
  expect_code 1 "$status" "installing over a conflicted instruction file must refuse: $out"
  pass "a conflicted instruction file refuses the save instead of recording a merge stage"
}

# The readable part of the namespace has to be folded to satisfy git's ref
# grammar, and folding is lossy: `probe..v2.lock` and `probe.v2` both fold to
# `probe.v2`, so a pooled slot used by one and later the other let the second
# list and restore the first's entries. Both ids pass fm_task_id_creation_valid.
test_two_task_ids_that_fold_alike_keep_separate_namespaces() {
  local repo wt out status folded plain
  repo="$TMP_ROOT/collide-repo"
  wt="$TMP_ROOT/collide-wt"
  folded='probe..v2.lock'
  plain='probe.v2'
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  fm_task_id_creation_valid "$folded" \
    || fail "the folded fixture id is not one firstmate itself accepts"
  fm_task_id_creation_valid "$plain" \
    || fail "the plain fixture id is not one firstmate itself accepts"
  [ "$(fm_crew_wip_ref_base "$wt" "$folded")" != "$(fm_crew_wip_ref_base "$wt" "$plain")" ] \
    || fail "two distinct task ids share one namespace: $(fm_crew_wip_ref_base "$wt" "$folded")"
  printf '%s\n' 'EDIT OWNED BY THE FOLDED ID' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" "$folded" 2>/dev/null \
    || fail "install under the folded id failed"
  expect_code 1 "$(wip_ref_count "$wt" "$folded")" "the folded id saved no entry"
  expect_code 0 "$(wip_ref_count "$wt" "$plain")" \
    "the other id can see entries it never created"
  # The pooled slot is reused by the id that folds onto the same readable slug.
  fm_remove_crew_worktree_instructions "$wt" || fail "pooled removal failed"
  fm_install_crew_worktree_instructions "$wt" "$plain" || fail "install under the plain id failed"
  out=$("$CREW_INSTRUCTIONS" recover "$wt" 2>&1); status=$?
  expect_code 1 "$status" "the second id must not recover the first id's edits: $out"
  assert_not_contains "$(cat "$wt/AGENTS.md")" 'EDIT OWNED BY THE FOLDED ID' \
    "the second id received the first id's instruction edits"
  assert_contains "$(saved_agents_md "$wt" "$folded" 1)" 'EDIT OWNED BY THE FOLDED ID' \
    "the first id's saved edit was destroyed by the second"
  pass "two task ids that fold to one slug still keep separate saved-edit namespaces"
}

# `git add -A` stages the overlay like any other modification, and the
# pre-commit guard only unstages at commit time, so the index can hold the
# overlay blob while the worker edits the file on disk. Launch scaffolding is
# not a version of the worker's work and must not be reported back as one.
test_a_staged_overlay_is_not_reported_as_a_worker_edit() {
  local repo wt out status
  repo="$TMP_ROOT/staged-overlay-repo"
  wt="$TMP_ROOT/staged-overlay-wt"
  overlaid_worktree "$repo" "$wt" 'staged-overlay-task-o2'
  git -C "$wt" add -A || fail "could not stage the overlay the way a crew would"
  [ "$(git -C "$wt" ls-files -s -- AGENTS.md | awk '$3 == "0" {print $2}')" \
    = "$(fm_crew_overlay_blob_hash "$wt" AGENTS.md)" ] \
    || fail "the fixture did not leave the overlay blob staged, so this case proves nothing"
  git -C "$wt" checkout HEAD -- AGENTS.md
  git -C "$wt" reset -q HEAD -- AGENTS.md
  git -C "$wt" update-index --cacheinfo \
    "100644,$(fm_crew_overlay_blob_hash "$wt" AGENTS.md),AGENTS.md" \
    || fail "could not restore the staged-overlay fixture state"
  printf '%s\n' 'THE ONLY REAL WORKER EDIT' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'staged-overlay-task-o2' 2>/dev/null \
    || fail "relaunch over a staged overlay failed"
  expect_code 1 "$(wip_ref_count "$wt" 'staged-overlay-task-o2')" \
    "the staged overlay was recorded as a second version of the worker's work"
  assert_contains "$(saved_agents_md "$wt" 'staged-overlay-task-o2' 1)" 'THE ONLY REAL WORKER EDIT' \
    "the worker's real edit was not the entry that was saved"
  out=$("$CREW_INSTRUCTIONS" saved "$wt" 2>&1); status=$?
  expect_code 0 "$status" "saved must list the worker's real entry: $out"
  assert_not_contains "$out" 'staged instruction edits' \
    "saved offered the launch overlay as one of the worker's staged edits"
  pass "a staged overlay is not reported back as a version of the worker's own edits"
}

# The temporary index must never appear in the working tree: freshen refuses on
# any porcelain output, so a leftover would permanently block the pooled slot.
test_saving_leaves_no_untracked_artifact_in_the_worktree() {
  local repo wt
  repo="$TMP_ROOT/tmpindex-repo"
  wt="$TMP_ROOT/tmpindex-wt"
  overlaid_worktree "$repo" "$wt" 'tmpindex-task-t4'
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'AN EDIT THAT FORCES A SAVE' >> "$wt/AGENTS.md"
  fm_install_crew_worktree_instructions "$wt" 'tmpindex-task-t4' 2>/dev/null \
    || fail "relaunch failed"
  assert_not_contains "$(git -C "$wt" status --porcelain)" 'fm-crew-wip-index' \
    "the save left its temporary index visible in the worktree"
  [ -z "$(git -C "$wt" status --porcelain | fm_crew_filter_overlay_status "$wt")" ] \
    || fail "the save left work a cleanliness check reads as unlanded: $(git -C "$wt" status --porcelain)"
  pass "saving an instruction edit leaves no untracked artifact in the worktree"
}

# The readable slug cannot always be repaired into a legal component, so the
# namespace falls back to one derived from the owner's content. It must stay
# legal and stay the same base every time it is derived for that owner.
test_an_unrepairable_owner_still_yields_a_stable_legal_namespace() {
  local repo wt base again
  repo="$TMP_ROOT/digest-repo"
  wt="$TMP_ROOT/digest-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  base=$(fm_crew_wip_ref_base "$wt" '...') || fail "an unrepairable owner yielded no namespace at all"
  git -C "$wt" check-ref-format "$base/1" 2>/dev/null \
    || fail "the fallback namespace is still not a legal ref name: $base"
  again=$(fm_crew_wip_ref_base "$wt" '...') || fail "the fallback namespace could not be re-derived"
  [ "$base" = "$again" ] \
    || fail "the fallback namespace is not stable for one owner ($base vs $again)"
  [ "$base" != "$(fm_crew_wip_ref_base "$wt" '..')" ] \
    || fail "two different owners collapsed onto one fallback namespace"
  pass "an owner git refuses outright still yields a stable legal ref namespace"
}

test_recover_refuses_loudly_when_this_task_saved_nothing() {
  local repo wt out status
  repo="$TMP_ROOT/norecover-repo"
  wt="$TMP_ROOT/norecover-wt"
  overlaid_worktree "$repo" "$wt" 'empty-task-e4'
  out=$("$CREW_INSTRUCTIONS" recover "$wt" 2>&1); status=$?
  expect_code 1 "$status" "recovery with nothing saved must refuse rather than do nothing: $out"
  assert_contains "$out" "$(fm_crew_wip_ref_base "$wt" 'empty-task-e4')" \
    "the refusal did not name what it looked for"
  out=$("$CREW_INSTRUCTIONS" saved "$wt" 2>&1); status=$?
  expect_code 1 "$status" "listing with nothing saved must refuse rather than print an empty list: $out"
  pass "recovery refuses loudly, naming the refs it searched, when this task saved nothing"
}

# The other core claim: a branch move onto a commit carrying a different
# AGENTS.md must leave the worker an escape that actually works. Under the
# superseded hiding mechanism `git stash` saved nothing and the loop never
# terminated.
test_branch_move_is_escapable_by_the_worker() {
  local repo wt out status
  repo="$TMP_ROOT/wedge-repo"
  wt="$TMP_ROOT/wedge-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'move AGENTS.md on main'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  out=$(git -C "$wt" merge origin/main -m merge 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "fixture did not reproduce a refused branch move: $out"
  assert_contains "$out" "AGENTS.md" "the refusal did not name the overlaid file"
  # The remedy git itself names must now do something.
  git -C "$wt" stash push --quiet -- AGENTS.md || fail "git stash could not save the overlay"
  expect_code 1 "$(stash_count "$wt")" "git stash saved nothing, so git's own advice is still a dead end"
  out=$(git -C "$wt" merge origin/main -m merge 2>&1); status=$?
  expect_code 0 "$status" "the branch move still fails after taking git's own advice: $out"
  assert_contains "$(cat "$wt/AGENTS.md")" 'Main moved on.' "the worktree did not move onto the new base"
  pass "a refused branch move is escapable with the remedy git itself names"
}

# The CLAUDE.md overlay is the canonical `@AGENTS.md` pointer, which is byte for
# byte what this repository commits, so "does this file hold the overlay
# content" is true for CLAUDE.md in every firstmate worktree. Reporting state on
# that alone told a worker an overlay was installed when none was, including
# right after a successful removal.
test_crew_instructions_status_tracks_a_real_overlay() {
  local repo wt out status
  repo="$TMP_ROOT/status-repo"
  wt="$TMP_ROOT/status-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  [ "$(git -C "$wt" hash-object -- "$wt/CLAUDE.md")" = "$(fm_crew_overlay_blob_hash "$wt" CLAUDE.md)" ] \
    || fail "fixture no longer commits a CLAUDE.md identical to the overlay pointer, so this case is untested"
  out=$("$CREW_INSTRUCTIONS" status "$wt" 2>&1); status=$?
  expect_code 0 "$status" "status on a worktree with no overlay must succeed: $out"
  assert_contains "$out" "overlay: not installed" \
    "status reported an overlay in a worktree that has none"
  out=$("$CREW_INSTRUCTIONS" remove "$wt" 2>&1); status=$?
  expect_code 0 "$status" "removal with nothing installed must succeed: $out"
  assert_contains "$out" "nothing to restore" "removal claimed it restored files it never touched"
  fm_install_crew_worktree_instructions "$wt" 'status-task-s7' || fail "overlay install failed"
  out=$("$CREW_INSTRUCTIONS" status "$wt" 2>&1)
  assert_contains "$out" "overlay: installed" "status did not report a genuinely installed overlay"
  out=$("$CREW_INSTRUCTIONS" remove "$wt" 2>&1); status=$?
  expect_code 0 "$status" "removal of an installed overlay failed: $out"
  assert_contains "$out" "removed the crew instruction overlay" \
    "removal did not report restoring the committed files"
  out=$("$CREW_INSTRUCTIONS" status "$wt" 2>&1)
  assert_contains "$out" "overlay: not installed" \
    "status still reported an overlay after a successful removal"
  pass "status reports an overlay only when one is really installed"
}

test_crew_instructions_cli_clears_a_branch_move() {
  local repo wt out status
  repo="$TMP_ROOT/cli-repo"
  wt="$TMP_ROOT/cli-wt"
  overlaid_worktree "$repo" "$wt"
  out=$("$CREW_INSTRUCTIONS" status "$wt" 2>&1); status=$?
  expect_code 0 "$status" "status must report an installed overlay: $out"
  assert_contains "$out" "installed" "status did not report the overlay as installed"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'move AGENTS.md on main'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  git -C "$wt" merge origin/main -m merge >/dev/null 2>&1 \
    && fail "fixture did not reproduce a refused branch move"
  out=$("$CREW_INSTRUCTIONS" remove "$wt" 2>&1); status=$?
  expect_code 0 "$status" "the worker-runnable removal failed: $out"
  assert_contains "$out" "still a crewmate" "removal did not restate the crewmate role"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "removal left the worktree dirty: $(git -C "$wt" status --porcelain)"
  out=$(git -C "$wt" merge origin/main -m merge 2>&1); status=$?
  expect_code 0 "$status" "the branch move still fails after the worker-runnable removal: $out"
  pass "bin/fm-crew-instructions.sh gives the worker a one-command escape"
}

# The overlay must not read as unlanded work to bin/fm-teardown.sh, and a real
# uncommitted edit must still read as exactly that. The superseded mechanism
# hid both cases equally, blinding the unlanded-work test.
test_cleanliness_filter_separates_scaffolding_from_real_work() {
  local repo wt
  repo="$TMP_ROOT/filter-repo"
  wt="$TMP_ROOT/filter-wt"
  overlaid_worktree "$repo" "$wt"
  [ -z "$(git -C "$wt" status --porcelain | fm_crew_filter_overlay_status "$wt")" ] \
    || fail "the untouched overlay reads as unlanded work"
  printf '%s\n' 'a real uncommitted worker edit' >> "$wt/AGENTS.md"
  assert_contains "$(git -C "$wt" status --porcelain | fm_crew_filter_overlay_status "$wt")" 'AGENTS.md' \
    "a real uncommitted AGENTS.md edit was filtered away as scaffolding"
  pass "the cleanliness filter hides only the byte-exact overlay, never a real edit"
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

# Under the superseded hiding mechanism an edit made on top of the overlay was
# dropped from every commit without an error, which is why a guard had to refuse
# it. A visible overlay needs no such rescue: the edit is ordinary content, and
# what git records is exactly what the worker sees on disk.
test_an_edit_on_top_of_the_overlay_is_never_dropped_silently() {
  local repo wt out status recorded
  repo="$TMP_ROOT/guard-fail-repo"
  wt="$TMP_ROOT/guard-fail-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' 'a crewmate edit that must not vanish' >> "$wt/AGENTS.md"
  printf '%s\n' '#!/bin/sh' 'echo spawn v2' > "$wt/bin/fm-spawn.sh"
  assert_status_contains "$wt" " M AGENTS.md" "the edit on top of the overlay is invisible to git"
  out=$(commit_all "$wt" 'crew commit touching the overlaid AGENTS.md'); status=$?
  recorded=$(git -C "$wt" show HEAD:AGENTS.md 2>/dev/null || true)
  if [ "$status" -eq 0 ]; then
    assert_contains "$recorded" 'a crewmate edit that must not vanish' \
      "the commit succeeded but silently dropped the AGENTS.md edit"
  else
    assert_contains "$out" "AGENTS.md" "the refusal did not name the file it refused over"
    assert_contains "$out" "carrying the crew overlay" \
      "the refusal did not explain that the overlay would be committed"
  fi
  pass "an edit on top of the overlay is either recorded or loudly refused, never dropped"
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

# `git add -A` stages the overlay because it is a visible modification. Keeping
# it out of the commit is what lets an ordinary crew commit stay ordinary, so
# the overlay must never reach the committed file and the worker's own staged
# work must still land.
test_commit_keeps_the_overlay_out_of_the_commit() {
  local repo wt out status
  repo="$TMP_ROOT/guard-overlay-repo"
  wt="$TMP_ROOT/guard-overlay-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' 'real crew work' > "$wt/NOTES.md"
  out=$(commit_all "$wt" 'ordinary crew commit while the overlay is installed'); status=$?
  expect_code 0 "$status" "an ordinary crew commit must not be blocked by the overlay: $out"
  assert_contains "$(git -C "$wt" show HEAD:AGENTS.md)" "$IDENTITY_LINE" \
    "the commit replaced the committed AGENTS.md with the crew overlay"
  assert_contains "$(git -C "$wt" show --name-only --format= HEAD)" 'NOTES.md' \
    "the commit dropped the worker's own staged work"
  assert_not_contains "$(git -C "$wt" show --name-only --format= HEAD)" 'AGENTS.md' \
    "the commit recorded the crew overlay"
  assert_corpus_is_crew "$wt" "after an ordinary crew commit"
  pass "an ordinary crew commit lands the worker's work and leaves the overlay uncommitted"
}

# A worktree left behind by the superseded mechanism still carries its hiding
# bit and possibly a sidecar holding the only copy of an edit it hid. Healing it
# must not silently discard that edit, and must not hand it to the next occupant.
test_a_worktree_left_by_the_superseded_mechanism_is_healed() {
  local repo wt
  repo="$TMP_ROOT/legacy-repo"
  wt="$TMP_ROOT/legacy-wt"
  overlaid_worktree "$repo" "$wt" 'legacy-task-l5'
  git -C "$wt" update-index --skip-worktree -- AGENTS.md \
    || fail "could not stage the superseded hidden state"
  printf '%s\n' 'work the superseded mechanism sidelined' > "$wt/.fm-agents-md-edit"
  fm_remove_crew_worktree_instructions "$wt" 2>/dev/null || fail "healing removal failed"
  assert_visible_to_git "$wt" AGENTS.md "healing left AGENTS.md hidden from git"
  assert_absent "$wt/.fm-agents-md-edit" "healing kept the previous task's sidecar for the next worker"
  expect_code 1 "$(wip_ref_count "$wt" 'legacy-task-l5')" \
    "healing discarded the sidecar instead of recovering it into this task's saved edits"
  assert_contains "$(saved_agents_md "$wt" 'legacy-task-l5' 1)" 'work the superseded mechanism sidelined' \
    "the recovered entry does not hold the sidelined edit"
  assert_contains "$(cat "$wt/AGENTS.md")" "$IDENTITY_LINE" \
    "healing did not restore the committed AGENTS.md"
  pass "a worktree left by the superseded mechanism is healed without losing its sidelined edit"
}

# A legacy slot carries no owner marker, so the rescue records the entry under a
# derived owner and the next install replaces that marker with the real task id.
# Withholding the previous occupant's work from the new task is correct; the
# recovery instruction printed for it must still work for whoever runs it, or
# the edit is reachable only by scrolling spawn output for a ref name.
test_a_rescued_legacy_sidecar_stays_recoverable_after_the_slot_is_reused() {
  local repo wt out status advertised
  repo="$TMP_ROOT/legacy-reuse-repo"
  wt="$TMP_ROOT/legacy-reuse-wt"
  make_firstmate_repo "$repo"
  make_linked_worktree "$repo" "$wt"
  printf '%s\n' 'SIDELINED EDIT FROM THE PREVIOUS OCCUPANT' > "$wt/.fm-agents-md-edit"
  out=$(fm_remove_crew_worktree_instructions "$wt" 2>&1) || fail "healing removal failed: $out"
  advertised=$(advertised_restore "$out" AGENTS.md) \
    || fail "the rescue advertised no restore command for AGENTS.md: $out"
  # The pooled slot is taken by a different task, which rewrites the owner.
  fm_install_crew_worktree_instructions "$wt" 'legacy-reuse-task-n8' \
    || fail "the next occupant's install failed"
  out=$("$CREW_INSTRUCTIONS" saved "$wt" 2>&1); status=$?
  expect_code 1 "$status" "the next occupant must not own the previous occupant's sidecar: $out"
  assert_not_contains "$(cat "$wt/AGENTS.md")" 'SIDELINED EDIT FROM THE PREVIOUS OCCUPANT' \
    "the next occupant was handed the previous occupant's sidelined edit"
  ( cd "$wt" && eval "$advertised" ) \
    || fail "the advertised restore command failed: $advertised"
  assert_contains "$(cat "$wt/AGENTS.md")" 'SIDELINED EDIT FROM THE PREVIOUS OCCUPANT' \
    "the advertised restore command did not recover the sidelined edit"
  assert_status_contains "$wt" " M AGENTS.md" \
    "the advertised restore command left the recovered edit staged"
  pass "a rescued legacy sidecar stays recoverable by the advertised command after the slot is reused"
}

# The sidecar rescue used to `cp` the sidecar over the instruction file with no
# check on what that file held, so a worker's own live uncommitted edit was
# overwritten and lost with exit 0 - the exact "an edit disappears with no
# error" mode this redesign exists to remove. Both edits must survive as
# separately recoverable entries, and neither may overwrite the other.
test_a_live_edit_and_a_legacy_sidecar_both_survive_healing() {
  local repo wt entries
  repo="$TMP_ROOT/legacy-live-repo"
  wt="$TMP_ROOT/legacy-live-wt"
  overlaid_worktree "$repo" "$wt" 'legacy-live-task-l6'
  git -C "$wt" checkout HEAD -- AGENTS.md
  printf '%s\n' 'LIVE EDIT E2 the worker is making right now' >> "$wt/AGENTS.md"
  printf '%s\n' 'SIDECAR EDIT E1 the superseded mechanism hid' > "$wt/.fm-agents-md-edit"
  fm_install_crew_worktree_instructions "$wt" 'legacy-live-task-l6' 2>/dev/null \
    || fail "relaunch over a live edit plus a legacy sidecar failed"
  entries=$(wip_ref_count "$wt" 'legacy-live-task-l6')
  expect_code 2 "$entries" "the live edit and the sidecar did not both survive as separate entries"
  assert_contains "$(saved_agents_md "$wt" 'legacy-live-task-l6' 1)" 'LIVE EDIT E2 the worker is making right now' \
    "the worker's live AGENTS.md edit was destroyed by the sidecar rescue"
  assert_contains "$(saved_agents_md "$wt" 'legacy-live-task-l6' 2)" 'SIDECAR EDIT E1 the superseded mechanism hid' \
    "the sidecar's edit was not recovered"
  assert_not_contains "$(saved_agents_md "$wt" 'legacy-live-task-l6' 1)" 'SIDECAR EDIT E1 the superseded mechanism hid' \
    "the sidecar overwrote the live edit instead of being saved beside it"
  assert_absent "$wt/.fm-agents-md-edit" "the rescued sidecar was left for the next worker"
  assert_corpus_is_crew "$wt" "after healing a worktree that also held a live edit"
  pass "a live instruction edit and a legacy sidecar both survive healing as separate entries"
}

test_removal_lets_a_pooled_worktree_reset_onto_a_new_base() {
  local repo wt out status
  repo="$TMP_ROOT/reuse-repo"
  wt="$TMP_ROOT/reuse-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'move AGENTS.md on main'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  fm_remove_crew_worktree_instructions "$wt" || fail "overlay removal failed"
  assert_visible_to_git "$wt" AGENTS.md "removal left AGENTS.md hidden from git"
  assert_visible_to_git "$wt" CLAUDE.md "removal left CLAUDE.md hidden from git"
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

# A pooled slot must be resettable even while the overlay is still installed,
# because a task can end without anyone removing it.
test_an_installed_overlay_does_not_wedge_a_pooled_reset() {
  local repo wt out status
  repo="$TMP_ROOT/reset-repo"
  wt="$TMP_ROOT/reset-wt"
  overlaid_worktree "$repo" "$wt"
  printf '%s\n' "$IDENTITY_LINE" 'The user is the captain.' 'Main moved on.' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm 'move AGENTS.md on main'
  git -C "$repo" push -q origin main
  git -C "$wt" fetch -q origin
  out=$(git -C "$wt" reset --hard origin/main 2>&1); status=$?
  expect_code 0 "$status" "an installed overlay must not wedge a pooled reset: $out"
  assert_contains "$(cat "$wt/AGENTS.md")" 'Main moved on.' "the reset worktree is not on the new base"
  pass "an installed overlay does not wedge a pooled reset onto a new base"
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
  [ -z "$(git -C "$SPAWN_POOL" status --porcelain | fm_crew_filter_overlay_status "$SPAWN_POOL")" ] \
    || fail "spawn left work a cleanliness check reads as unlanded: $(git -C "$SPAWN_POOL" status --porcelain)"
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
  [ -z "$(git -C "$SPAWN_POOL" status --porcelain | fm_crew_filter_overlay_status "$SPAWN_POOL")" ] \
    || fail "the reused pool holds work a cleanliness check reads as unlanded: $(git -C "$SPAWN_POOL" status --porcelain)"
  pass "a pooled worktree the previous crew overlaid still refreshes and spawns"
}

# The anti-inversion fence must not read as an order to skip this repo's own
# tests, which are exactly what invoke the fleet scripts it names.
test_fleet_command_fence_carves_out_the_test_suite() {
  local body
  body=$(fm_crew_overlay_body)
  assert_contains "$body" 'fleet-management command' "the overlay dropped the fleet-command fence"
  assert_contains "$body" "except through this repository's own test suite" \
    "the overlay's fleet-command fence has no test-suite carve-out"
  pass "the overlay's fleet-command fence carves out this repository's own test suite"
}

test_overlay_inverts_autoload_corpus
test_overlay_is_idempotent
test_dirty_agents_md_is_saved_then_overlaid
test_two_relaunches_keep_both_saved_edits
test_saved_edits_stay_with_the_task_that_saved_them
test_recover_restores_this_task_s_own_saved_edit
test_recover_refuses_loudly_when_this_task_saved_nothing
test_a_staged_and_a_working_tree_version_both_survive_a_relaunch
test_a_task_id_git_refuses_as_a_ref_component_still_launches
test_an_unrepairable_owner_still_yields_a_stable_legal_namespace
test_two_task_ids_that_fold_alike_keep_separate_namespaces
test_a_conflicted_instruction_file_refuses_the_save
test_a_staged_overlay_is_not_reported_as_a_worker_edit
test_saving_leaves_no_untracked_artifact_in_the_worktree
test_branch_move_is_escapable_by_the_worker
test_crew_instructions_status_tracks_a_real_overlay
test_crew_instructions_cli_clears_a_branch_move
test_cleanliness_filter_separates_scaffolding_from_real_work
test_fleet_command_fence_carves_out_the_test_suite
test_ordinary_project_is_untouched
test_secondmate_home_is_untouched
test_primary_checkout_is_refused
test_unknown_agents_md_is_refused
test_missing_guidelines_is_refused
test_session_start_forbidden_predicate
test_session_start_refuses_linked_worktree
test_identity_line_matches_shipped_agents_md
test_an_edit_on_top_of_the_overlay_is_never_dropped_silently
test_commit_guard_allows_an_untouched_overlay
test_restored_agents_md_commits_the_edit
test_ensure_agents_md_stays_a_no_op_after_overlay
test_commit_keeps_the_overlay_out_of_the_commit
test_a_worktree_left_by_the_superseded_mechanism_is_healed
test_a_live_edit_and_a_legacy_sidecar_both_survive_healing
test_a_rescued_legacy_sidecar_stays_recoverable_after_the_slot_is_reused
test_removal_lets_a_pooled_worktree_reset_onto_a_new_base
test_an_installed_overlay_does_not_wedge_a_pooled_reset
test_spawn_overlays_firstmate_shaped_pool
test_spawn_reuses_a_pool_the_previous_crew_overlaid
