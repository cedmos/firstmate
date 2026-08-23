#!/usr/bin/env bash
# Reproduction script for the crew-instruction-overlay redesign.
#
# Drives the SHIPPED library and the SHIPPED worker CLI against real git in a
# disposable scratch repository, and prints exactly what a crew worker sitting
# in a firstmate-repo task worktree would see on their terminal.
#
# usage: reproduce-worker-experience.sh <firstmate-repo-root>
set -u

ROOT=${1:?usage: reproduce-worker-experience.sh <firstmate-repo-root>}
ROOT=$(cd "$ROOT" && pwd -P)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-crew-worktree-instructions-lib.sh"
CREW_CLI="$ROOT/bin/fm-crew-instructions.sh"

PROBE=$(mktemp -d "${TMPDIR:-/tmp}/crew-overlay-evidence.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT

say() { printf '\n=== %s\n' "$1"; }
worker() { printf '\n$ %s\n' "$*"; }

# ---------------------------------------------------------------------------
# A firstmate-shaped upstream, its real AGENTS.md / CLAUDE.md / coding
# guidelines copied out of the checkout under test, plus a linked task worktree
# of the kind fm-spawn.sh hands a crew.
# ---------------------------------------------------------------------------
REPO="$PROBE/firstmate"
WT="$PROBE/task-worktree"
mkdir -p "$REPO/bin" "$REPO/.agents/skills/firstmate-coding-guidelines"
git init -q -b main "$REPO"
git -C "$REPO" config user.email crew@example.invalid
git -C "$REPO" config user.name 'crew worker'
cp "$ROOT/AGENTS.md" "$REPO/AGENTS.md"
cp "$ROOT/CLAUDE.md" "$REPO/CLAUDE.md"
cp "$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md" \
  "$REPO/.agents/skills/firstmate-coding-guidelines/SKILL.md"
cp "$ROOT/bin/fm-session-start.sh" "$ROOT/bin/fm-spawn.sh" "$REPO/bin/"
git -C "$REPO" add -A
git -C "$REPO" commit -qm 'firstmate checkout'
git -C "$REPO" worktree add --quiet --detach "$WT"
git -C "$WT" checkout -q -b fm/task-alpha

printf '%s\n' "git $(git --version | awk '{print $3}')"

# ===========================================================================
say 'SPAWN: the overlay is installed as a VISIBLE modification'
# ===========================================================================
fm_install_crew_worktree_instructions "$WT" 'task-alpha' >/dev/null || exit 1

worker 'head -8 AGENTS.md    # what the harness auto-loads as my role'
head -8 "$WT/AGENTS.md" | sed 's/^/  /'

worker 'grep -n "except through this repository" AGENTS.md   # fleet fence carve-out'
grep -n 'except through this repository' "$WT/AGENTS.md" | sed 's/^/  /'

worker 'git status --porcelain      # the overlay is not hidden from me'
git -C "$WT" status --porcelain | sed 's/^/  /'

worker 'git ls-files -v AGENTS.md CLAUDE.md   # no skip-worktree / assume-unchanged bit'
git -C "$WT" ls-files -v -- AGENTS.md CLAUDE.md | sed 's/^/  /'

worker 'git log -1 --format=%H:%s HEAD:AGENTS.md is untouched -- committed job description:'
git -C "$WT" show HEAD:AGENTS.md | grep -m1 -F 'You are the first mate.' | sed 's/^/  /'

# ===========================================================================
say 'DAY OF WORK: git add -A + commit lands my work, not the overlay'
# ===========================================================================
printf 'crew work\n' > "$WT/feature.txt"
worker 'git add -A && git commit -m "feat: crew work"'
git -C "$WT" add -A
git -C "$WT" commit -qm 'feat: crew work' 2>&1 | sed 's/^/  /'
worker 'git show --stat --format= HEAD    # the overlay stayed out of the commit'
git -C "$WT" show --stat --format= HEAD | sed 's/^/  /'
worker 'git status --porcelain    # ...and is still installed and still visible'
git -C "$WT" status --porcelain | sed 's/^/  /'

# ===========================================================================
say 'THE OLD WEDGE: main moves AGENTS.md, I rebase, git refuses'
# ===========================================================================
git -C "$REPO" checkout -q main
printf '\n<!-- upstream edit -->\n' >> "$REPO/AGENTS.md"
git -C "$REPO" commit -qam 'docs: upstream AGENTS.md change'
git -C "$WT" fetch -q "$REPO" main 2>/dev/null || true

worker 'git rebase main'
git -C "$WT" rebase main 2>&1 | head -6 | sed 's/^/  /'

MOVED=$(git -C "$REPO" rev-parse main)
worker "git checkout $MOVED    # the same branch move, phrased the way the old bug report quoted it"
git -C "$WT" checkout "$MOVED" 2>&1 | head -6 | sed 's/^/  /'

worker 'git status --porcelain    # the refusal is EXPLAINED: I can see the modification'
git -C "$WT" status --porcelain | sed 's/^/  /'

worker 'git stash push -- AGENTS.md CLAUDE.md   # the remedy git names actually saves something'
git -C "$WT" stash push -- AGENTS.md CLAUDE.md 2>&1 | sed 's/^/  /'
worker 'git stash list'
git -C "$WT" stash list | sed 's/^/  /'
git -C "$WT" stash pop -q 2>/dev/null || true

# ===========================================================================
say 'THE ESCAPE: the worker clears it in one step and the rebase goes through'
# ===========================================================================
worker 'bin/fm-crew-instructions.sh status'
"$CREW_CLI" status "$WT" 2>&1 | sed 's/^/  /'

worker 'bin/fm-crew-instructions.sh remove'
"$CREW_CLI" remove "$WT" 2>&1 | sed 's/^/  /'

worker 'git status --porcelain    # clean'
printf '  [%s]\n' "$(git -C "$WT" status --porcelain | tr -d '\n')"

worker 'git rebase main'
git -C "$WT" rebase main 2>&1 | head -3 | sed 's/^/  /'
worker 'git log --oneline -2   # my commit rebased onto the moved main'
git -C "$WT" log --oneline -2 | sed 's/^/  /'

worker 'bin/fm-crew-instructions.sh status    # honest after removal'
"$CREW_CLI" status "$WT" 2>&1 | sed 's/^/  /'

# ===========================================================================
say 'RELAUNCH x2: neither in-progress instruction edit is destroyed'
# ===========================================================================
printf 'FIRST IN-PROGRESS EDIT\n' >> "$WT/AGENTS.md"
worker 'relaunch #1 (spawn reinstalls the overlay over my uncommitted AGENTS.md edit)'
fm_install_crew_worktree_instructions "$WT" 'task-alpha' 2>&1 | sed 's/^/  /'

git -C "$WT" checkout -q HEAD -- AGENTS.md
printf 'SECOND IN-PROGRESS EDIT\n' >> "$WT/AGENTS.md"
worker 'relaunch #2'
fm_install_crew_worktree_instructions "$WT" 'task-alpha' 2>&1 | sed 's/^/  /'

worker 'bin/fm-crew-instructions.sh saved   # BOTH relaunches are still here'
"$CREW_CLI" saved "$WT" 2>&1 | sed 's/^/  /'

worker 'bin/fm-crew-instructions.sh recover'
"$CREW_CLI" recover "$WT" 2>&1 | sed 's/^/  /'
worker 'tail -1 AGENTS.md   # the newest saved edit is back on disk'
tail -1 "$WT/AGENTS.md" | sed 's/^/  /'

FIRST_REF=$(fm_crew_list_wip_refs "$WT" 'task-alpha' | head -1)
worker "git show $FIRST_REF:AGENTS.md | tail -1   # relaunch #1's edit, not overwritten"
git -C "$WT" show "$FIRST_REF:AGENTS.md" | tail -1 | sed 's/^/  /'

# ===========================================================================
say "OWNERSHIP: the pool's next occupant is refused, not handed my edits"
# ===========================================================================
git -C "$WT" checkout -q HEAD -- AGENTS.md CLAUDE.md
fm_install_crew_worktree_instructions "$WT" 'task-beta' >/dev/null || true
worker 'bin/fm-crew-instructions.sh recover   # run as task-beta, the slot reused'
beta_out=$("$CREW_CLI" recover "$WT" 2>&1)
beta_rc=$?
printf '%s\n' "$beta_out" | sed 's/^/  /'
printf '  (exit %s)\n' "$beta_rc"

# ===========================================================================
say 'TEARDOWN: scaffolding reads clean, a real edit still refuses'
# ===========================================================================
git -C "$WT" checkout -q HEAD -- AGENTS.md CLAUDE.md
fm_install_crew_worktree_instructions "$WT" 'task-beta' >/dev/null || true
worker 'git status --porcelain | fm_crew_filter_overlay_status   # what fm-teardown.sh reads, only the overlay present'
printf '  [%s]\n' "$(git -C "$WT" status --porcelain | fm_crew_filter_overlay_status "$WT" | tr -d '\n')"
printf 'A REAL UNCOMMITTED EDIT\n' >> "$WT/AGENTS.md"
worker 'git status --porcelain | fm_crew_filter_overlay_status   # with a genuine worker edit on top'
git -C "$WT" status --porcelain | fm_crew_filter_overlay_status "$WT" | sed 's/^/  /'
printf '\n'
