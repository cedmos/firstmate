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
# In-progress instruction edits found at (re)launch move into git's own stash
# rather than a private sidecar. The stash is a stack, so a second relaunch
# adds an entry instead of destroying the first; refs/stash is shared ref space
# that outlives this disposable worktree; and `git stash list` plus
# `git stash pop` are recovery commands a worker already knows.
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
FM_CREW_STASH_LABEL='fm-crew: in-progress instruction edits saved before the crew overlay'

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

If `git stash list` shows an `fm-crew:` entry, in-progress instruction edits were saved there before this overlay was installed.
Recover them with `git stash pop`.

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

# Clear the hiding bits before the work-in-progress scan, because `git stash`
# saves nothing for a file git has been told to report as unchanged, so a
# relaunch into such a worktree would otherwise overwrite an edit it believed it
# had saved.
fm_crew_unhide_instruction_files() {  # <worktree>
  local wt=$1 rel failed=0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_is_hidden_from_git "$wt" "$rel" || continue
    fm_crew_unhide_file "$wt" "$rel" || failed=1
  done
  [ "$failed" -eq 0 ]
}

# Move a worker's in-progress instruction edits into git's own stash before the
# overlay replaces them, restoring the committed files in the same step.
# A private sidecar file would be overwritten by the next relaunch and lost with
# no error. The stash is a stack, so a second relaunch pushes a second entry and
# the first survives; refs/stash is shared ref space, so the entry outlives this
# disposable worktree; and recovery is `git stash list` plus `git stash pop`.
# The pathspec keeps unrelated working-tree changes untouched.
fm_crew_stash_instruction_wip() {  # <worktree>
  local wt=$1 rel paths=
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_instruction_has_wip "$wt" "$rel" || continue
    paths="${paths:+$paths }$rel"
  done
  [ -n "$paths" ] || return 0
  # shellcheck disable=SC2086
  git -C "$wt" stash push --quiet -m "$FM_CREW_STASH_LABEL" -- $paths || {
    echo "error: could not stash in-progress $paths before installing crew instructions; refusing to overwrite uncommitted work" >&2
    return 1
  }
  echo "warning: saved in-progress $paths to the git stash before installing crew instructions; recover with 'git stash list' then 'git stash pop'" >&2
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
# bit is cleared first so the restore can land, and its sidecar is folded back
# into the git stash rather than deleted, because it may be the only copy of an
# edit that mechanism hid.
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

# Fold any sidecar the superseded mechanism left into the git stash, then remove
# it. Deleting it outright could destroy the only copy of an edit that mechanism
# hid from git, and leaving it hands one worker's work to the next occupant of a
# pooled slot.
fm_crew_rescue_legacy_sidecars() {  # <worktree>
  local wt=$1 rel dest failed=0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    case $rel in
      AGENTS.md) dest=$FM_CREW_AGENTS_WIP ;;
      *) dest=$FM_CREW_CLAUDE_WIP ;;
    esac
    [ -f "$wt/$dest" ] || continue
    if cp "$wt/$dest" "$wt/$rel" &&
      git -C "$wt" stash push --quiet -m "$FM_CREW_STASH_LABEL" -- "$rel"; then
      echo "warning: recovered $dest into the git stash; run 'git stash list' then 'git stash pop' to restore those $rel edits" >&2
    else
      echo "error: could not recover the saved $dest in $wt into the git stash" >&2
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
fm_install_crew_worktree_instructions() {  # <worktree>
  local wt=${1:-} guidelines
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
  fm_crew_unhide_instruction_files "$wt" || return 1
  fm_crew_rescue_legacy_sidecars "$wt" || return 1
  fm_crew_stash_instruction_wip "$wt" || return 1
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
