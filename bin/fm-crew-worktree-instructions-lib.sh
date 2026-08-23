#!/usr/bin/env bash
# Shared install of crewmate project instructions for a firstmate-repo
# ship or scout worktree.
# Harnesses auto-load AGENTS.md and CLAUDE.md from the worktree as project
# instructions that outrank the launch brief. When the project is firstmate
# itself, those files are the firstmate job description, so a crew or scout
# adopts the firstmate role and tries to run session start, scaffold a brief,
# and spawn a worker for its own task.
# This library replaces the auto-loaded files in a linked ordinary task
# worktree with a crew overlay so the harness cannot load the firstmate
# job as that worker's instructions.
# Only AGENTS.md carries the crew body. CLAUDE.md is overlaid with the exact
# canonical `@AGENTS.md` pointer that bin/fm-ensure-agents-md.sh owns, and the
# crew body carries that script's canonical `## Maintaining this file` heading,
# so the brief-mandated `fm-ensure-agents-md.sh .` stays a no-op success in an
# overlaid worktree instead of reporting a two-real-files conflict.
# The overlay keeps `.agents/skills/firstmate-coding-guidelines/SKILL.md`
# reachable and tells the worker how to restore AGENTS.md when the task is
# to edit it.
#
# The overlay is an ordinary visible working-tree modification, and is
# deliberately NOT hidden with `git update-index --skip-worktree` or
# `--assume-unchanged`. Both bits make git report the worktree as clean while
# the file on disk differs from the index, and that lie costs more than it
# buys: every branch-moving operation refuses ("your local changes to the
# following files would be overwritten"), while `git stash` saves nothing and a
# commit records nothing, so the remedies git names are dead ends and the
# worker has no escape. The same lie hides a worker's genuine uncommitted
# instruction edit from bin/fm-teardown.sh's unlanded-work test.
# Telling git the truth costs one visible ` M AGENTS.md` line and buys back
# every standard remedy: `git stash`, `git checkout HEAD --`, and
# `git reset --hard` all work, so git's own advice terminates.
# Consumers that must not read the overlay as unlanded work filter it with
# fm_crew_filter_overlay_status, which drops the modification only while the
# file holds the overlay byte for byte, so a real edit stays visible as the
# uncommitted work it is.
#
# In-progress instruction edits found at (re)launch are saved as commit objects
# under refs/fm-crew/<task-id>-<digest>/instruction-wip/<n>, one ref per save.
# The digest of the exact task id keeps that mapping injective, because the
# readable part has to be folded to satisfy git's ref grammar and two task ids
# can fold together.
# The shared refs/stash stack is deliberately not the carrier: a stash entry
# carries no owner identity, `git stash pop` is position-based, and refs/stash is
# shared across every worktree of this repository including the primary checkout,
# so a pooled slot's next occupant could pop a previous task's instruction edits
# onto its own branch. A ref name carries the owning task id, is addressed by
# name rather than by stack position, cannot be consumed by another task, and
# lives in the common git dir, so it outlives this disposable worktree.
# The owning task id is recorded in the worktree's own git dir, so
# bin/fm-crew-instructions.sh restores only what this worktree's task saved and
# refuses loudly, naming the ref namespace it looked in, when there is nothing.
# A staged version and a working-tree version of the same file are two distinct
# versions of the worker's work, so each becomes its own entry: the restore that
# follows the save rewrites the index as well as the file, and recording only
# what is on disk would drop the staged one with no error.
# An instruction file with unmerged index stages has no single version to record
# and no restore that would not silently collapse the conflict, so the save
# refuses it loudly rather than guessing which stage the worker meant.
#
# The install also writes a pre-commit guard refusing a commit that would land
# the overlay over firstmate's own committed file. The guard lives in this
# worktree's own git dir and is selected through per-worktree `core.hooksPath`,
# so the primary checkout's hooks are never touched.
# fm_remove_crew_worktree_instructions undoes all of it, and bin/fm-crew-instructions.sh
# makes it reachable by the worker, so a worker who wants a clean tree for a
# branch move has a one-command escape. It also heals a worktree still carrying
# the superseded skip-worktree bits or sidecars.
# bin/fm-spawn.sh calls it before
# it refreshes a pooled worktree, so a slot returned with the overlay still on
# it self-heals instead of wedging the next `git reset --hard`.
# A secondmate home, a primary checkout, and a non-firstmate project are
# left untouched.
# Spawn refuses when the overlay cannot be installed or still presents
# firstmate identity afterwards.
# Session start refuses in the same linked firstmate worktree so a worker
# that still reaches for it cannot build a ghost home.
# Sourced by bin/fm-spawn.sh, bin/fm-session-start.sh, bin/fm-teardown.sh, and
# bin/fm-crew-instructions.sh.
# No side effects on source. set -u / set -e safe.

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-primary-scope-lib.sh"

FM_CREW_OVERLAY_MARKER='<!-- firstmate-crew-worktree-instructions -->'
FM_FIRSTMATE_IDENTITY_LINE='You are the first mate.'
FM_CREW_GUIDELINES_REL='.agents/skills/firstmate-coding-guidelines/SKILL.md'
# Sidecar paths the superseded save-to-a-private-file mechanism wrote. Kept so a
# worktree left behind by it is healed rather than handed to the next occupant.
FM_CREW_AGENTS_WIP='.fm-agents-md-edit'
FM_CREW_CLAUDE_WIP='.fm-claude-md-edit'
FM_CREW_HOOKS_DIRNAME='fm-crew-hooks'
FM_CREW_INSTRUCTION_FILES='AGENTS.md CLAUDE.md'
# Saved in-progress instruction edits live at
# refs/fm-crew/<task-id>/instruction-wip/<n>. The second component is the owning
# task, so an entry is addressed by owner and sequence rather than by position
# in a stack every worktree of this repository shares.
FM_CREW_WIP_REF_NAMESPACE='refs/fm-crew'
FM_CREW_WIP_REF_LEAF='instruction-wip'
# Names the task those refs belong to. It lives in this worktree's own git dir,
# so the next occupant of a pooled slot overwrites it at install instead of
# inheriting the previous task's identity.
FM_CREW_OWNER_MARKER_NAME='fm-crew-instruction-owner'

fm_crew_overlay_body() {
  cat <<'EOF'
<!-- firstmate-crew-worktree-instructions -->

# Role

You are a crewmate: an autonomous worker agent managed by firstmate.
You are not the first mate.
Spawn replaced this worktree's harness-loaded project instructions before launch so you cannot adopt the firstmate role from them.

Do not run `bin/fm-session-start.sh`, `bin/fm-spawn.sh`, `bin/fm-brief.sh`, `tasks-axi add`, or any other fleet-management command, except through this repository's own test suite.
You have no fleet.
Do not address anyone as captain.
Do not open an interactive question dialog.
The only channel that reaches the supervisor is the status file named in your launch brief.

# Editing this repository

The committed `AGENTS.md` is firstmate's own operating contract.
It is source you may edit when the task requires it, not your job description.
Load `.agents/skills/firstmate-coding-guidelines/SKILL.md` before editing firstmate's shared tracked material.

Git still has the committed files.
This working copy is a spawn-time overlay, and git reports it as an ordinary modification to `AGENTS.md` and `CLAUDE.md`.

If this task requires editing `AGENTS.md` itself, restore the committed file first with `git checkout HEAD -- AGENTS.md`, then edit it.
You remain a crewmate after that restore.
Committing this overlay over firstmate's own committed file is refused by a pre-commit guard.

If `git rebase`, `git merge`, `git checkout`, or `git cherry-pick` refuses because your local changes to `AGENTS.md` or `CLAUDE.md` would be overwritten, this overlay is what it means.
Every remedy git names works here: `git stash`, or `git checkout HEAD -- AGENTS.md CLAUDE.md`.
`bin/fm-crew-instructions.sh remove` does both files and the guard in one step.

In-progress edits to these files found when this overlay was installed were saved as commits under this task's own `refs/fm-crew/<task-id>/instruction-wip/` refs, never on the shared `git stash` stack.
A version you had staged and a version you had only on disk are saved as separate entries, so neither is lost to the other.
Run `bin/fm-crew-instructions.sh saved` to list the entries this worktree's task owns, and `bin/fm-crew-instructions.sh recover` to restore the newest one.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

# The canonical CLAUDE.md pointer bin/fm-ensure-agents-md.sh owns. The overlay
# writes it verbatim so that script still classifies the worktree as canonical.
fm_crew_claude_pointer_body() {
  cat <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

fm_crew_overlay_content() {  # <rel>
  case $1 in
    CLAUDE.md) fm_crew_claude_pointer_body ;;
    *) fm_crew_overlay_body ;;
  esac
}

# The blob hash of <rel>'s overlay content as `git hash-object --no-filters`
# would report it for a file holding exactly that content.
fm_crew_overlay_blob_hash() {  # <worktree> <rel>
  local wt=$1 rel=$2 hash
  hash=$(fm_crew_overlay_content "$rel" | git -C "$wt" hash-object --stdin) || return 1
  [ -n "$hash" ] || return 1
  printf '%s\n' "$hash"
}

fm_crew_file_is_installed_overlay() {  # <worktree> <rel>
  local wt=$1 rel=$2 expected disk
  [ -f "$wt/$rel" ] || return 1
  expected=$(fm_crew_overlay_blob_hash "$wt" "$rel") || return 1
  disk=$(git -C "$wt" hash-object --no-filters -- "$wt/$rel" 2>/dev/null) || return 1
  [ "$expected" = "$disk" ]
}

# Return 0 only when <rel> holds the overlay AND that content differs from the
# committed blob, so the overlay is a real installed modification.
# Content equality alone cannot answer "is the overlay installed here": the
# CLAUDE.md overlay is the canonical `@AGENTS.md` pointer, which is byte for byte
# what this repository commits, so fm_crew_file_is_installed_overlay is true for
# CLAUDE.md in every firstmate worktree whether an overlay was installed or not.
# Reporting state to a worker goes through this predicate instead.
fm_crew_file_is_overlay_modification() {  # <worktree> <rel>
  local wt=$1 rel=$2
  fm_crew_file_is_installed_overlay "$wt" "$rel" || return 1
  fm_crew_file_differs_from_head "$wt" "$rel"
}

fm_checkout_is_firstmate_shaped() {  # <root>
  local root=$1
  [ -n "$root" ] && [ -d "$root" ] || return 1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -f "$root/bin/fm-session-start.sh" ] || return 1
  [ -f "$root/bin/fm-spawn.sh" ] || return 1
}

fm_checkout_is_linked_worktree() {  # <root>
  local root=$1 git_dir git_common_dir
  git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" != "$git_common_dir" ]
}

# Return 0 when session start must refuse: a linked ordinary worktree of a
# firstmate-shaped checkout, never a primary or a secondmate home.
fm_crew_session_start_is_forbidden() {  # <root>
  local root=$1
  fm_checkout_is_firstmate_shaped "$root" || return 1
  fm_root_is_secondmate_home "$root" && return 1
  fm_checkout_is_linked_worktree "$root"
}

fm_file_presents_firstmate_identity() {  # <file>
  local file=$1
  [ -f "$file" ] || return 1
  grep -Fqx "$FM_FIRSTMATE_IDENTITY_LINE" "$file"
}

fm_file_is_crew_overlay() {  # <file>
  local file=$1
  [ -f "$file" ] || return 1
  grep -Fqx "$FM_CREW_OVERLAY_MARKER" "$file"
}

# Return 0 when the working copy of <rel> differs from the committed blob.
# Compares hashes rather than asking `git diff`, because skip-worktree makes
# git report a modified instruction file as unchanged.
fm_crew_file_differs_from_head() {  # <worktree> <rel>
  local wt=$1 rel=$2 head_hash disk_hash
  head_hash=$(git -C "$wt" rev-parse --verify --quiet "HEAD:$rel" 2>/dev/null) || return 1
  disk_hash=$(git -C "$wt" hash-object --no-filters -- "$wt/$rel" 2>/dev/null) || return 1
  [ -n "$head_hash" ] && [ -n "$disk_hash" ] || return 1
  [ "$head_hash" != "$disk_hash" ]
}

fm_crew_is_instruction_file() {  # <rel>
  local rel=$1 known
  for known in $FM_CREW_INSTRUCTION_FILES; do
    [ "$rel" = "$known" ] && return 0
  done
  return 1
}

# Return 0 when <rel> holds work the overlay would otherwise destroy: it exists,
# it is not already the installed overlay, and it differs from the committed blob.
fm_crew_instruction_has_wip() {  # <worktree> <rel>
  local wt=$1 rel=$2
  [ -f "$wt/$rel" ] || return 1
  fm_crew_file_is_installed_overlay "$wt" "$rel" && return 1
  fm_crew_file_differs_from_head "$wt" "$rel"
}

# Clear any hiding bit the superseded mechanism left on <rel>.
# The two flags must be separate invocations: git applies only the last of them
# per call, so a combined `--no-skip-worktree --no-assume-unchanged` silently
# leaves the skip-worktree bit set, and the restore that follows then fails with
# "pathspec did not match any file(s) known to git".
fm_crew_unhide_file() {  # <worktree> <rel>
  local wt=$1 rel=$2
  git -C "$wt" update-index --no-skip-worktree -- "$rel" &&
    git -C "$wt" update-index --no-assume-unchanged -- "$rel" && return 0
  echo "error: could not clear the stale hidden-file bit on $rel in $wt" >&2
  return 1
}

# Clear the hiding bits before the work-in-progress scan, because a file git has
# been told to report as unchanged reads as identical to the index, so a relaunch
# into such a worktree would otherwise overwrite an edit it believed it had saved.
fm_crew_unhide_instruction_files() {  # <worktree>
  local wt=$1 rel failed=0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_is_hidden_from_git "$wt" "$rel" || continue
    fm_crew_unhide_file "$wt" "$rel" || failed=1
  done
  [ "$failed" -eq 0 ]
}

# --- per-task saved instruction edits ---------------------------------------

# This worktree's own private git dir. Everything this library writes that is
# not the overlay itself lives here rather than in the working tree, because a
# stray file in the working tree is indistinguishable from unlanded work to
# bin/fm-spawn.sh's clean check and bin/fm-teardown.sh's refusal.
fm_crew_private_dir() {  # <worktree>
  local git_dir
  git_dir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] || return 1
  printf '%s\n' "$git_dir"
}

fm_crew_owner_marker_path() {  # <worktree>
  local git_dir
  git_dir=$(fm_crew_private_dir "$1") || return 1
  printf '%s\n' "$git_dir/$FM_CREW_OWNER_MARKER_NAME"
}

fm_crew_read_owner() {  # <worktree>
  local marker owner
  marker=$(fm_crew_owner_marker_path "$1") || return 1
  [ -f "$marker" ] || return 1
  IFS= read -r owner < "$marker" || return 1
  [ -n "$owner" ] || return 1
  printf '%s\n' "$owner"
}

fm_crew_record_owner() {  # <worktree> <owner>
  local marker
  marker=$(fm_crew_owner_marker_path "$1") || return 1
  printf '%s\n' "$2" > "$marker"
}

# The task that owns this worktree's saved instruction edits. An explicit id from
# the caller wins and is recorded for the worker-facing CLI to read back.
# A worktree that was never told one falls back to an identity derived from its
# own git dir: still unambiguous, still never shared with another task.
fm_crew_resolve_owner() {  # <worktree> [task-id]
  local wt=$1 explicit=${2:-} owner git_dir
  if [ -n "$explicit" ]; then
    fm_crew_record_owner "$wt" "$explicit" || return 1
    printf '%s\n' "$explicit"
    return 0
  fi
  if owner=$(fm_crew_read_owner "$wt"); then
    printf '%s\n' "$owner"
    return 0
  fi
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] || return 1
  owner="unowned-$(basename "$git_dir")"
  fm_crew_record_owner "$wt" "$owner" || return 1
  printf '%s\n' "$owner"
}

# A short digest of the EXACT owner string, distinguishing owners that the
# readable slug below cannot.
fm_crew_owner_digest() {  # <worktree> <owner>
  local wt=$1 owner=$2 hash
  hash=$(printf '%s' "$owner" | git -C "$wt" hash-object --stdin) || return 1
  [ -n "$hash" ] || return 1
  printf '%s\n' "${hash:0:12}"
}

# The ref namespace <owner>'s saved instruction edits live under.
# The owner is folded into a single legal ref path component, and git itself
# rules on the result rather than this function guessing at git's ref grammar.
# Mapping out-of-charset bytes is not enough on its own: a task id firstmate
# accepts may still contain `..` or end in `.lock`, which git's ref grammar
# rejects, and a refused ref name would abort the spawn over a name firstmate
# itself issued.
# Folding those sequences out is lossy, though, and a lossy name would let two
# task ids share one namespace, which is exactly the cross-task recovery this
# carrier exists to prevent: `probe..v2.lock` and `probe.v2` both fold to
# `probe.v2`. The component therefore always carries a digest of the exact owner
# alongside the readable slug, so the mapping stays injective while the ref name
# still names its task. An owner whose slug git refuses outright is addressed by
# the digest alone.
fm_crew_wip_ref_base() {  # <worktree> <owner>
  local wt=$1 owner=$2 slug digest base
  [ -n "$owner" ] || return 1
  digest=$(fm_crew_owner_digest "$wt" "$owner") || return 1
  slug=${owner//[^A-Za-z0-9._-]/-}
  while [ "$slug" != "${slug//../.}" ]; do
    slug=${slug//../.}
  done
  while [ "$slug" != "${slug%.lock}" ]; do
    slug=${slug%.lock}
  done
  slug=${slug#.}
  slug=${slug%.}
  if [ -n "$slug" ]; then
    base="$FM_CREW_WIP_REF_NAMESPACE/$slug-$digest/$FM_CREW_WIP_REF_LEAF"
    if git -C "$wt" check-ref-format "$base/1" 2>/dev/null; then
      printf '%s\n' "$base"
      return 0
    fi
  fi
  base="$FM_CREW_WIP_REF_NAMESPACE/owner-$digest/$FM_CREW_WIP_REF_LEAF"
  git -C "$wt" check-ref-format "$base/1" 2>/dev/null || return 1
  printf '%s\n' "$base"
}

# Every entry <owner> saved, oldest first. Sorted on the numeric sequence rather
# than lexically, so entry 10 does not sort between 1 and 2.
fm_crew_list_wip_refs() {  # <worktree> <owner>
  local wt=$1 owner=$2 base
  base=$(fm_crew_wip_ref_base "$wt" "$owner") || return 1
  git -C "$wt" for-each-ref --format='%(refname)' "$base/*" 2>/dev/null | sort -t/ -k5,5n
}

fm_crew_next_wip_ref() {  # <worktree> <owner>
  local wt=$1 owner=$2 base n=1
  base=$(fm_crew_wip_ref_base "$wt" "$owner") || return 1
  while git -C "$wt" rev-parse --verify --quiet "$base/$n" >/dev/null 2>&1; do
    n=$((n + 1))
  done
  printf '%s\n' "$base/$n"
}

# Return 0 when <ref> actually carries an edit to <rel> rather than the committed
# content it was recorded against.
fm_crew_ref_holds_edit() {  # <worktree> <ref> <rel>
  local wt=$1 ref=$2 rel=$3 saved base
  saved=$(git -C "$wt" rev-parse --verify --quiet "$ref:$rel" 2>/dev/null) || return 1
  [ -n "$saved" ] || return 1
  base=$(git -C "$wt" rev-parse --verify --quiet "$ref^:$rel" 2>/dev/null) || base=
  [ "$saved" != "$base" ]
}

# The command that restores <rel> from <ref> the way recovery itself leaves it.
# `git checkout <commit> -- <path>` writes the index as well as the working
# tree, so on its own it would leave the recovered edit staged and the next
# plain `git commit` would land work-in-progress the worker never chose to
# commit. The index reset is part of the advertised command for that reason.
fm_crew_restore_command() {  # <ref> <rel>
  printf 'git checkout %s -- %s && git reset -q HEAD -- %s\n' "$1" "$2" "$2"
}

# Record <rel>=<blob> pairs as a commit whose tree is HEAD's with exactly those
# paths replaced, and point a fresh per-task ref at it. Prints the ref.
# `git stash create` is the obvious way to make such a commit and is the wrong
# one here: it takes no pathspec, so it would fold every unrelated working-tree
# change into the saved commit and then collide with those same changes on the
# way back out. Building the tree in a temporary index carries the instruction
# files and nothing else.
# Nothing in the working tree is read except through git hash-object upstream of
# this call, so saving one copy of a file can never overwrite another.
fm_crew_store_wip_entry() {  # <worktree> <owner> <subject> <rel>=<blob>...
  local wt=$1 owner=$2 subject=$3 ref head git_dir index tree commit pair rel blob
  shift 3
  [ "$#" -gt 0 ] || return 0
  wt=$(CDPATH='' cd -- "$wt" && pwd -P) || return 1
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD) || head=
  [ -n "$head" ] || {
    echo "error: $wt has no HEAD commit to record in-progress instruction edits against" >&2
    return 1
  }
  ref=$(fm_crew_next_wip_ref "$wt" "$owner") || {
    echo "error: task '$owner' does not yield a legal ref name for saved instruction edits in $wt" >&2
    return 1
  }
  git_dir=$(fm_crew_private_dir "$wt") || {
    echo "error: could not resolve the git dir of $wt to save instruction edits" >&2
    return 1
  }
  index=$(mktemp "$git_dir/.fm-crew-wip-index.XXXXXX") || {
    echo "error: could not create a temporary index for the saved instruction edits in $wt" >&2
    return 1
  }
  rm -f "$index"
  if ! GIT_INDEX_FILE=$index git -C "$wt" read-tree "$head"; then
    rm -f "$index"
    echo "error: could not read $wt's HEAD tree while saving instruction edits" >&2
    return 1
  fi
  for pair in "$@"; do
    rel=${pair%%=*}
    blob=${pair#*=}
    if ! GIT_INDEX_FILE=$index git -C "$wt" update-index --add --cacheinfo "100644,$blob,$rel"; then
      rm -f "$index"
      echo "error: could not record the in-progress $rel in $wt" >&2
      return 1
    fi
  done
  tree=$(GIT_INDEX_FILE=$index git -C "$wt" write-tree) || tree=
  rm -f "$index"
  [ -n "$tree" ] || {
    echo "error: could not write a tree for the saved instruction edits in $wt" >&2
    return 1
  }
  commit=$(
    GIT_AUTHOR_NAME=firstmate GIT_AUTHOR_EMAIL=firstmate@invalid \
      GIT_COMMITTER_NAME=firstmate GIT_COMMITTER_EMAIL=firstmate@invalid \
      git -C "$wt" commit-tree "$tree" -p "$head" -m "$subject"
  ) || commit=
  [ -n "$commit" ] || {
    echo "error: could not commit the saved instruction edits in $wt" >&2
    return 1
  }
  git -C "$wt" update-ref "$ref" "$commit" || {
    echo "error: could not point $ref at the saved instruction edits in $wt" >&2
    return 1
  }
  printf '%s\n' "$ref"
}

# The blob the index holds for <rel>, and only that.
# Stage 0 is the merged state; during an unresolved conflict git instead lists
# stages 1, 2 and 3, and taking all of them would yield three hashes where a
# caller expects one.
fm_crew_staged_blob() {  # <worktree> <rel>
  local wt=$1 rel=$2
  git -C "$wt" ls-files -s -- "$rel" 2>/dev/null | awk '$3 == "0" {print $2}'
}

# True while the index carries unmerged stages for <rel>.
fm_crew_instruction_is_unmerged() {  # <worktree> <rel>
  local wt=$1 rel=$2
  [ -n "$(git -C "$wt" ls-files -u -- "$rel" 2>/dev/null)" ]
}

# Save a worker's in-progress instruction edits before the overlay replaces
# them, restoring the committed files in the same step.
# A private sidecar was overwritten by the next relaunch and lost with no error,
# and the shared stash stack hands one task's entry to the next occupant of a
# pooled slot; a fresh ref under this task's own namespace does neither.
# The index is saved separately from the working tree. A worker who staged one
# version and then edited further holds two distinct versions of their own work,
# and the restore below rewrites the index as well as the file, so recording
# only what is on disk would drop the staged one with no error - the exact
# failure this carrier exists to remove. Each version becomes its own entry,
# named in its subject, so the two stay tellable apart on the way back out.
fm_crew_save_instruction_wip() {  # <worktree> <owner>
  local wt=$1 owner=$2 rel head_blob disk_blob staged_blob overlay_blob
  local disk_paths='' staged_paths='' ref
  local -a disk_pairs=() staged_pairs=()
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    [ -f "$wt/$rel" ] || continue
    if fm_crew_instruction_is_unmerged "$wt" "$rel"; then
      echo "error: $rel in $wt has unresolved merge conflicts in the index" >&2
      echo "refusing to save or restore it: an unmerged path has no single version to record, and the restore that follows would drop the conflict without saying so." >&2
      echo "finish the merge or rebase, or take the committed file with 'git checkout HEAD -- $rel', then run this again." >&2
      return 1
    fi
    head_blob=$(git -C "$wt" rev-parse --verify --quiet "HEAD:$rel" 2>/dev/null) || head_blob=
    disk_blob=$(git -C "$wt" hash-object --no-filters -- "$wt/$rel" 2>/dev/null) || disk_blob=
    overlay_blob=$(fm_crew_overlay_blob_hash "$wt" "$rel" 2>/dev/null) || overlay_blob=
    if fm_crew_instruction_has_wip "$wt" "$rel"; then
      disk_blob=$(git -C "$wt" hash-object -w --no-filters -- "$wt/$rel") || disk_blob=
      [ -n "$disk_blob" ] || {
        echo "error: could not record the in-progress $rel in $wt; refusing to overwrite uncommitted work" >&2
        return 1
      }
      disk_paths="${disk_paths:+$disk_paths }$rel"
      disk_pairs+=("$rel=$disk_blob")
    fi
    # The overlay is launch scaffolding, not the worker's work, and `git add -A`
    # stages it like any other modification, so a staged overlay must not be
    # reported back as a version of the worker's own edits.
    staged_blob=$(fm_crew_staged_blob "$wt" "$rel")
    if [ -n "$staged_blob" ] && [ "$staged_blob" != "$head_blob" ] &&
      [ "$staged_blob" != "$disk_blob" ] && [ "$staged_blob" != "$overlay_blob" ]; then
      staged_paths="${staged_paths:+$staged_paths }$rel"
      staged_pairs+=("$rel=$staged_blob")
    fi
  done
  if [ "${#staged_pairs[@]}" -gt 0 ]; then
    ref=$(fm_crew_store_wip_entry "$wt" "$owner" \
      "staged instruction edits saved for $owner before the crew overlay" "${staged_pairs[@]}") || {
      echo "error: could not save the staged $staged_paths in $wt; refusing to overwrite uncommitted work" >&2
      return 1
    }
    fm_crew_report_saved_entry "$wt" "$ref" "staged $staged_paths" || return 1
  fi
  if [ "${#disk_pairs[@]}" -gt 0 ]; then
    ref=$(fm_crew_store_wip_entry "$wt" "$owner" \
      "working-tree instruction edits saved for $owner before the crew overlay" "${disk_pairs[@]}") || {
      echo "error: could not save in-progress $disk_paths in $wt; refusing to overwrite uncommitted work" >&2
      return 1
    }
    fm_crew_report_saved_entry "$wt" "$ref" "in-progress $disk_paths" || return 1
  fi
  for rel in $disk_paths; do
    git -C "$wt" checkout HEAD -- "$rel" || {
      echo "error: could not restore the committed $rel in $wt after saving its edits" >&2
      return 1
    }
  done
  for rel in $staged_paths; do
    case " $disk_paths " in
      *" $rel "*) continue ;;
    esac
    git -C "$wt" reset -q HEAD -- "$rel" || {
      echo "error: could not reset the staged $rel in $wt after saving it" >&2
      return 1
    }
  done
}

# Announce a saved entry with a command that works for whoever reads it.
# `bin/fm-crew-instructions.sh recover` only reaches entries owned by the task
# the worktree currently records, and a pooled slot's owner marker is rewritten
# by the next install, so the ref-addressed command is the one that still works
# after that happens.
fm_crew_report_saved_entry() {  # <worktree> <ref> <what>
  local wt=$1 ref=$2 what=$3 rel restore=''
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_ref_holds_edit "$wt" "$ref" "$rel" || continue
    restore="${restore:+$restore; }$(fm_crew_restore_command "$ref" "$rel")"
  done
  echo "warning: saved $what to $ref; restore it with: $restore" >&2
}

# Print <worktree>'s porcelain status lines with the crew overlay's own
# modification removed, so a cleanliness check reads launch scaffolding as clean
# while every real edit stays visible. Reads porcelain lines on stdin.
# The match is content-exact and worktree-only: an instruction file that no
# longer holds the overlay byte for byte, or one staged for commit, is reported
# as the uncommitted work it is.
fm_crew_filter_overlay_status() {  # <worktree>
  local wt=$1 line rel
  while IFS= read -r line; do
    rel=${line#" M "}
    if [ "$rel" != "$line" ] && fm_crew_is_instruction_file "$rel" &&
      fm_crew_file_is_installed_overlay "$wt" "$rel"; then
      continue
    fi
    printf '%s\n' "$line"
  done
}

# True while <rel> still carries a bit from the superseded hiding mechanism.
# `git ls-files -v` reports skip-worktree as `S` and assume-unchanged as a
# lowercase tag; either one makes git report a clean worktree over a divergent
# file, so removal clears both.
fm_crew_is_hidden_from_git() {  # <worktree> <rel>
  local wt=$1 rel=$2 state
  state=$(git -C "$wt" ls-files -v -- "$rel" 2>/dev/null | awk '{print substr($1,1,1)}')
  case $state in
    S | [a-z]) return 0 ;;
  esac
  return 1
}

fm_crew_commit_guard_dir() {  # <worktree>
  local git_dir
  git_dir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] || return 1
  printf '%s\n' "$git_dir/$FM_CREW_HOOKS_DIRNAME"
}

fm_crew_write_commit_guard() {  # <dest> <agents-blob-hash> <claude-blob-hash>
  local dest=$1 agents_hash=$2 claude_hash=$3
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# Installed by bin/fm-crew-worktree-instructions-lib.sh for this worktree only.
# The crew overlay is an ordinary visible modification of AGENTS.md and
# CLAUDE.md, so \`git add -A\` and \`git commit -a\` stage it like any other
# change. It is launch scaffolding, never source, so this guard keeps it out of
# the commit instead of refusing one: an instruction file staged with exactly
# the overlay content is unstaged, and everything else the worker staged still
# commits. Unstaging works on both the \`git add\` and the \`commit -a\` paths.
# A staged instruction file that carries the overlay marker but is NOT the
# overlay byte for byte is scaffolding mixed into source. Neither dropping nor
# keeping it is safe to decide here, so that one is refused loudly.
set -u
marker='$FM_CREW_OVERLAY_MARKER'
guard_status=0

refuse() {
  printf 'error: %s\n' "\$@" >&2
  guard_status=1
}

for rel in $FM_CREW_INSTRUCTION_FILES; do
  case "\$rel" in
    AGENTS.md) overlay='$agents_hash' ;;
    *) overlay='$claude_hash' ;;
  esac
  [ -f "\$rel" ] || continue
  head_hash=\$(git rev-parse --verify --quiet "HEAD:\$rel" 2>/dev/null || true)
  staged_hash=\$(git ls-files -s -- "\$rel" 2>/dev/null | awk '{print \$2}')
  [ -n "\$staged_hash" ] && [ "\$staged_hash" != "\$head_hash" ] || continue
  if [ "\$staged_hash" = "\$overlay" ]; then
    if git reset -q HEAD -- "\$rel"; then
      printf 'note: kept the crew overlay out of this commit (%s is launch scaffolding, not source).\n' "\$rel" >&2
    else
      refuse "\$rel is staged carrying the crew overlay and it could not be unstaged." \\
        "committing it would replace firstmate's own committed file with this worktree's scaffolding." \\
        "unstage it yourself, or drop the overlay entirely:" \\
        "  git reset -q HEAD -- \$rel" \\
        "  bin/fm-crew-instructions.sh remove"
    fi
    continue
  fi
  git cat-file blob "\$staged_hash" 2>/dev/null | grep -Fqx "\$marker" || continue
  refuse "\$rel is staged carrying the crew overlay marker mixed into edited content." \\
    "the crew overlay is this worktree's launch scaffolding, never source to commit," \\
    "and this staged file is neither the overlay nor a clean edit of the committed file." \\
    "restore the committed file and re-apply only the intended source edits:" \\
    "  git checkout HEAD -- \$rel" \\
    "or drop the overlay from this worktree entirely:" \\
    "  bin/fm-crew-instructions.sh remove"
done
exit "\$guard_status"
EOF
}

# Select the guard through this worktree's own core.hooksPath. Per-worktree git
# config needs extensions.worktreeConfig, which is a shared-config setting whose
# one documented hazard is core.bare / core.worktree living in the shared file.
fm_crew_install_commit_guard() {  # <worktree>
  local wt=$1 dir agents_hash claude_hash tmp
  dir=$(fm_crew_commit_guard_dir "$wt") || {
    echo "error: could not resolve the git dir of $wt to install the crew commit guard" >&2
    return 1
  }
  if ! agents_hash=$(fm_crew_overlay_blob_hash "$wt" AGENTS.md) ||
    ! claude_hash=$(fm_crew_overlay_blob_hash "$wt" CLAUDE.md); then
    echo "error: could not hash the crew overlay content for the commit guard in $wt" >&2
    return 1
  fi
  if [ "$(git -C "$wt" config --get core.bare 2>/dev/null || true)" = true ] ||
     [ -n "$(git -C "$wt" config --get core.worktree 2>/dev/null || true)" ]; then
    echo "error: refusing to enable per-worktree git config for $wt because core.bare or core.worktree lives in the shared config" >&2
    return 1
  fi
  mkdir -p "$dir" || {
    echo "error: could not create the crew commit guard directory $dir" >&2
    return 1
  }
  tmp="$dir/pre-commit.new"
  if ! fm_crew_write_commit_guard "$tmp" "$agents_hash" "$claude_hash" ||
    ! chmod +x "$tmp" || ! mv "$tmp" "$dir/pre-commit"; then
    rm -f "$tmp"
    echo "error: could not write the crew commit guard at $dir/pre-commit" >&2
    return 1
  fi
  git -C "$wt" config extensions.worktreeConfig true || {
    echo "error: could not enable per-worktree git config for $wt; the crew commit guard would not run" >&2
    return 1
  }
  git -C "$wt" config --worktree core.hooksPath "$dir" || {
    echo "error: could not point $wt at the crew commit guard hooks path" >&2
    return 1
  }
  [ "$(git -C "$wt" config --get core.hooksPath 2>/dev/null || true)" = "$dir" ] || {
    echo "error: the crew commit guard is not the active hooks path in $wt" >&2
    return 1
  }
  [ -x "$dir/pre-commit" ] || {
    echo "error: the crew commit guard at $dir/pre-commit is not executable" >&2
    return 1
  }
}

fm_crew_remove_commit_guard() {  # <worktree>
  local wt=$1 dir
  dir=$(fm_crew_commit_guard_dir "$wt") || return 0
  if [ "$(git -C "$wt" config --get core.hooksPath 2>/dev/null || true)" = "$dir" ]; then
    git -C "$wt" config --worktree --unset core.hooksPath 2>/dev/null || true
  fi
  rm -f "$dir/pre-commit" "$dir/pre-commit.new"
  rmdir "$dir" 2>/dev/null || true
  if [ "$(git -C "$wt" config --get core.hooksPath 2>/dev/null || true)" = "$dir" ]; then
    echo "error: could not clear the crew commit guard hooks path in $wt" >&2
    return 1
  fi
  [ ! -e "$dir/pre-commit" ] || {
    echo "error: could not remove the crew commit guard at $dir/pre-commit" >&2
    return 1
  }
}

# Undo the overlay: restore the committed instruction files and drop the commit
# guard. A worktree that never carried the overlay is a no-op, so a pooled slot
# can call this unconditionally before it refreshes its base, and a worker can
# run it through bin/fm-crew-instructions.sh to clear a branch move.
# Only an instruction file still holding the overlay byte for byte is restored,
# so a worker's own uncommitted edit is never discarded here.
# A worktree left behind by the superseded mechanism is healed too: its hiding
# bit is cleared first so the restore can land, and its sidecar is folded into
# this worktree's own saved instruction edits rather than deleted, because it may
# be the only copy of an edit that mechanism hid.
fm_remove_crew_worktree_instructions() {  # <worktree>
  local wt=${1:-} rel failed=0
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    if fm_crew_is_hidden_from_git "$wt" "$rel"; then
      fm_crew_unhide_file "$wt" "$rel" || {
        failed=1
        continue
      }
    fi
    fm_crew_file_is_installed_overlay "$wt" "$rel" || continue
    git -C "$wt" checkout HEAD -- "$rel" || {
      echo "error: could not restore the committed $rel in $wt" >&2
      failed=1
    }
  done
  fm_crew_rescue_legacy_sidecars "$wt" || failed=1
  fm_crew_remove_commit_guard "$wt" || failed=1
  [ "$failed" -eq 0 ]
}

# Fold any sidecar the superseded mechanism left into this worktree's own saved
# instruction edits, then remove it. Deleting it outright could destroy the only
# copy of an edit that mechanism hid from git, and leaving it hands one worker's
# work to the next occupant of a pooled slot.
# The sidecar is hashed straight into git and recorded as its own entry, so the
# instruction file on disk is never written here. A worker's live uncommitted
# edit to the same path is therefore a separate, separately recoverable entry
# instead of being overwritten by the sidecar on its way out.
# A legacy slot carries no owner marker, so this rescue records the entry under
# a derived owner that the next install then replaces with the real task id.
# Withholding a previous occupant's work from the new task is the point, so the
# entry stays where it is and the announcement names the ref instead of the CLI,
# which would look under the new owner and correctly find nothing.
fm_crew_rescue_legacy_sidecars() {  # <worktree>
  local wt=$1 rel dest blob ref owner='' failed=0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    case $rel in
      AGENTS.md) dest=$FM_CREW_AGENTS_WIP ;;
      *) dest=$FM_CREW_CLAUDE_WIP ;;
    esac
    [ -f "$wt/$dest" ] || continue
    if [ -z "$owner" ] && ! owner=$(fm_crew_resolve_owner "$wt"); then
      echo "error: could not determine which task owns $wt's saved instruction edits; refusing to fold $dest away" >&2
      return 1
    fi
    blob=$(git -C "$wt" hash-object -w --no-filters -- "$wt/$dest") || blob=
    if [ -n "$blob" ] && ref=$(fm_crew_store_wip_entry "$wt" "$owner" \
      "$rel edits recovered for $owner from the superseded $dest sidecar" "$rel=$blob"); then
      echo "warning: recovered $dest into $ref; restore it with: $(fm_crew_restore_command "$ref" "$rel")" >&2
    else
      echo "error: could not recover the saved $dest in $wt into this task's saved instruction edits" >&2
      failed=1
      continue
    fi
    rm -f "$wt/$dest" || {
      echo "error: could not remove the recovered sidecar $dest in $wt" >&2
      failed=1
    }
  done
  [ "$failed" -eq 0 ]
}

fm_crew_install_overlay_file() {  # <worktree> <rel>
  local wt=$1 rel=$2 tmp
  tmp=$(mktemp "$wt/.fm-crew-overlay.XXXXXX") || {
    echo "error: could not create a temp file for the crew overlay in $wt" >&2
    return 1
  }
  fm_crew_overlay_content "$rel" > "$tmp" || {
    rm -f "$tmp"
    echo "error: could not write crew overlay for $rel" >&2
    return 1
  }
  mv "$tmp" "$wt/$rel" || {
    rm -f "$tmp"
    echo "error: could not install crew overlay at $rel" >&2
    return 1
  }
  fm_crew_file_is_installed_overlay "$wt" "$rel" || {
    echo "error: crew overlay at $rel does not hold its expected content after install" >&2
    return 1
  }
  if fm_file_presents_firstmate_identity "$wt/$rel"; then
    echo "error: crew overlay at $rel still presents firstmate identity" >&2
    return 1
  fi
}

# Install the crew overlay into a linked firstmate-shaped ship/scout worktree.
# No-op for a non-firstmate project or a secondmate home.
# Refuses a primary checkout and any firstmate-shaped worktree whose AGENTS.md
# is neither the firstmate identity nor an already-installed overlay.
# <task-id> is the owner recorded for anything this install has to save, so the
# worker-facing CLI restores only what this task saved.
fm_install_crew_worktree_instructions() {  # <worktree> [task-id]
  local wt=${1:-} task_id=${2:-} guidelines owner
  [ -n "$wt" ] && [ -d "$wt" ] || {
    echo "error: crew worktree instructions need a directory" >&2
    return 1
  }
  wt=$(CDPATH='' cd -- "$wt" && pwd -P) || {
    echo "error: crew worktree instructions directory cannot be resolved: $1" >&2
    return 1
  }
  fm_root_is_secondmate_home "$wt" && return 0
  fm_checkout_is_firstmate_shaped "$wt" || return 0
  if ! fm_checkout_is_linked_worktree "$wt"; then
    echo "error: refusing to overlay crew instructions onto a primary checkout ($wt)" >&2
    return 1
  fi
  guidelines="$wt/$FM_CREW_GUIDELINES_REL"
  [ -f "$guidelines" ] || {
    echo "error: firstmate-coding-guidelines is missing at $guidelines; refusing to overlay crew instructions that would point at it" >&2
    return 1
  }
  if ! fm_file_presents_firstmate_identity "$wt/AGENTS.md" && ! fm_file_is_crew_overlay "$wt/AGENTS.md"; then
    echo "error: firstmate-shaped worktree AGENTS.md has neither firstmate identity nor the crew overlay; refusing to launch with an unknown instruction file" >&2
    return 1
  fi
  owner=$(fm_crew_resolve_owner "$wt" "$task_id") || {
    echo "error: could not record which task owns the crew instruction overlay in $wt" >&2
    return 1
  }
  fm_crew_unhide_instruction_files "$wt" || return 1
  fm_crew_save_instruction_wip "$wt" "$owner" || return 1
  fm_crew_rescue_legacy_sidecars "$wt" || return 1
  fm_crew_install_overlay_file "$wt" AGENTS.md || return 1
  if [ -f "$wt/CLAUDE.md" ]; then
    fm_crew_install_overlay_file "$wt" CLAUDE.md || return 1
  fi
  fm_crew_install_commit_guard "$wt" || return 1
  if fm_file_presents_firstmate_identity "$wt/AGENTS.md" || \
     { [ -f "$wt/CLAUDE.md" ] && fm_file_presents_firstmate_identity "$wt/CLAUDE.md"; }; then
    echo "error: auto-loaded instruction files still present firstmate identity after crew overlay" >&2
    return 1
  fi
  grep -F "$FM_CREW_GUIDELINES_REL" "$wt/AGENTS.md" >/dev/null || {
    echo "error: crew overlay does not point at $FM_CREW_GUIDELINES_REL" >&2
    return 1
  }
}
