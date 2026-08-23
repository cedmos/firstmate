#!/usr/bin/env bash
# Worker-runnable control for the crew instruction overlay in this worktree.
# bin/fm-crew-worktree-instructions-lib.sh installs the overlay at spawn so a
# firstmate-repo crew or scout cannot load firstmate's own job description as
# its role. The overlay is a visible working-tree modification, so a branch move
# refuses while it is in place, exactly as it would for any uncommitted change.
# This script is how the worker clears it without needing firstmate: `remove`
# restores the committed instruction files and drops the commit guard.
# It never discards a worker's own edits. Only a file still holding the overlay
# byte for byte is restored, and any in-progress edit the install saved stays
# reachable through `saved` and `recover`, including a version that was staged
# rather than only on disk, which is saved as its own separate entry.
# Those two commands read only the refs under this worktree's own task, whose id
# the install recorded in the worktree's git dir. They never fall back to
# another task's entry, and refuse loudly naming the ref namespace they searched
# when this task saved nothing.
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
  saved    List the in-progress instruction edits saved for this worktree's own
           task, with the command that restores each one. A version that was
           staged when it was saved is listed as its own entry, separate from
           the version that was on disk.
  recover  Restore the newest of this task's saved instruction edits into the
           working tree.

[worktree] defaults to the current working directory's worktree root.

Removing the overlay does not end your crewmate role: your launch brief still
governs, and you must not run fleet-management commands.
`saved` and `recover` only ever offer entries saved for this worktree's own
task, and refuse when it saved none rather than reaching for another task's.
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
  status | remove | saved | recover) ;;
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

# Resolve OWNER and REFS for this worktree's own task, or refuse loudly naming
# exactly what was looked for. Falling back to another task's saved edits is the
# cross-contamination this carrier exists to prevent, so absence is an error.
require_owned_entries() {
  local marker base
  marker=$(fm_crew_owner_marker_path "$WT" 2>/dev/null) || marker=
  OWNER=$(fm_crew_read_owner "$WT") || {
    echo "error: $WT records no owning task, so it has no saved instruction edits to restore." >&2
    echo "looked for the owner marker at ${marker:-<unresolvable git dir>}." >&2
    echo "only the task that saved an entry may restore it, so this refuses rather than guessing." >&2
    exit 1
  }
  base=$(fm_crew_wip_ref_base "$WT" "$OWNER") || {
    echo "error: the recorded owning task '$OWNER' does not yield a legal ref name in $WT." >&2
    exit 1
  }
  REFS=$(fm_crew_list_wip_refs "$WT" "$OWNER")
  [ -n "$REFS" ] || {
    echo "error: task '$OWNER' has no saved instruction edits in $WT." >&2
    echo "looked for refs under $base/." >&2
    echo "entries another task saved are deliberately not offered here." >&2
    exit 1
  }
}

report_entry() {  # <ref>
  local ref=$1 rel subject
  subject=$(git -C "$WT" log -1 --format='%s' "$ref" 2>/dev/null || true)
  printf '  %s\n' "$ref"
  [ -z "$subject" ] || printf '    %s\n' "$subject"
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_ref_holds_edit "$WT" "$ref" "$rel" || continue
    printf '    %s: %s\n' "$rel" "$(fm_crew_restore_command "$ref" "$rel")"
  done
}

case $CMD in
  saved)
    require_owned_entries
    echo "saved instruction edits for task '$OWNER' in $WT:"
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      report_entry "$ref"
    done <<EOF
$REFS
EOF
    exit 0
    ;;
  recover)
    require_owned_entries
    NEWEST=$(printf '%s\n' "$REFS" | tail -n 1)
    # Saving first means recovery cannot destroy an edit either: whatever the
    # working tree already holds becomes its own entry before it is replaced.
    fm_crew_save_instruction_wip "$WT" "$OWNER" || {
      echo "error: could not save the working tree's own instruction edits before recovering $NEWEST" >&2
      exit 1
    }
    RESTORED=
    for rel in $FM_CREW_INSTRUCTION_FILES; do
      fm_crew_ref_holds_edit "$WT" "$NEWEST" "$rel" || continue
      git -C "$WT" checkout "$NEWEST" -- "$rel" || {
        echo "error: could not restore $rel from $NEWEST in $WT" >&2
        exit 1
      }
      git -C "$WT" reset -q HEAD -- "$rel" || {
        echo "error: could not leave the restored $rel unstaged in $WT" >&2
        exit 1
      }
      RESTORED="${RESTORED:+$RESTORED }$rel"
    done
    [ -n "$RESTORED" ] || {
      echo "error: $NEWEST holds no instruction edits to restore in $WT." >&2
      exit 1
    }
    echo "restored $RESTORED from $NEWEST as an uncommitted modification in $WT."
    echo "the entry is kept, not consumed; restore it again with:"
    for rel in $RESTORED; do
      printf '  %s\n' "$(fm_crew_restore_command "$NEWEST" "$rel")"
    done
    echo "run 'bin/fm-crew-instructions.sh saved' to see this task's other entries."
    exit 0
    ;;
esac

installed=0
for rel in $FM_CREW_INSTRUCTION_FILES; do
  fm_crew_file_is_overlay_modification "$WT" "$rel" && installed=1
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
