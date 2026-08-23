#!/usr/bin/env bash
# Worker-runnable control for the crew instruction overlay in this worktree.
# bin/fm-crew-worktree-instructions-lib.sh installs the overlay at spawn so a
# firstmate-repo crew or scout cannot load firstmate's own job description as
# its role. The overlay is a visible working-tree modification, so a branch move
# refuses while it is in place, exactly as it would for any uncommitted change.
# This script is how the worker clears it without needing firstmate: `remove`
# restores the committed instruction files and drops the commit guard.
# It never discards a worker's own edits. Only a file still holding the overlay
# byte for byte is restored, and any in-progress edit the install stashed stays
# in `git stash list`.
# Firstmate itself does not need this: bin/fm-spawn.sh calls the same library
# function when it refreshes a pooled worktree.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-crew-worktree-instructions-lib.sh
. "$SCRIPT_DIR/fm-crew-worktree-instructions-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-crew-instructions.sh <command> [worktree]

Commands:
  status   Report whether the crew overlay is installed in this worktree.
  remove   Restore the committed AGENTS.md and CLAUDE.md and drop the commit
           guard, so branch-moving git commands stop refusing.

[worktree] defaults to the current working directory's worktree root.

Removing the overlay does not end your crewmate role: your launch brief still
governs, and you must not run fleet-management commands.
Edits saved at launch stay in the git stash; see `git stash list`.
EOF
}

resolve_worktree() {  # <arg>
  local arg=${1:-} root
  if [ -n "$arg" ]; then
    (CDPATH='' cd -- "$arg" && pwd -P) || return 1
    return 0
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  (CDPATH='' cd -- "$root" && pwd -P) || return 1
}

CMD=${1:-}
case $CMD in
  -h | --help | help | '')
    usage
    exit 0
    ;;
  status | remove) ;;
  *)
    echo "error: unknown command '$CMD'" >&2
    usage >&2
    exit 2
    ;;
esac

WT=$(resolve_worktree "${2:-}") || {
  echo "error: could not resolve a worktree for '${2:-$PWD}'" >&2
  exit 1
}

installed=0
for rel in $FM_CREW_INSTRUCTION_FILES; do
  fm_crew_file_is_installed_overlay "$WT" "$rel" && installed=1
done

if [ "$CMD" = status ]; then
  if [ "$installed" -eq 1 ]; then
    echo "crew instruction overlay: installed in $WT"
    echo "run 'bin/fm-crew-instructions.sh remove' to restore the committed files."
  else
    echo "crew instruction overlay: not installed in $WT"
  fi
  exit 0
fi

fm_remove_crew_worktree_instructions "$WT" || {
  echo "error: could not remove the crew instruction overlay from $WT" >&2
  exit 1
}
if [ "$installed" -eq 1 ]; then
  echo "removed the crew instruction overlay from $WT; the committed AGENTS.md and CLAUDE.md are restored."
else
  echo "no crew instruction overlay was installed in $WT; nothing to restore."
fi
echo "you are still a crewmate: your launch brief governs, and you have no fleet."
