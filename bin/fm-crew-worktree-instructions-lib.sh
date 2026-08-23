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
# The committed files stay in git; the overlay is skip-worktree so it does
# not look like uncommitted work.
# The overlay keeps `.agents/skills/firstmate-coding-guidelines/SKILL.md`
# reachable and tells the worker how to restore AGENTS.md when the task is
# to edit it.
# A secondmate home, a primary checkout, and a non-firstmate project are
# left untouched.
# Spawn refuses when the overlay cannot be installed or still presents
# firstmate identity afterwards.
# Session start refuses in the same linked firstmate worktree so a worker
# that still reaches for it cannot build a ghost home.
# Sourced by bin/fm-spawn.sh and bin/fm-session-start.sh.
# No side effects on source. set -u / set -e safe.

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-primary-scope-lib.sh"

FM_CREW_OVERLAY_MARKER='<!-- firstmate-crew-worktree-instructions -->'
FM_FIRSTMATE_IDENTITY_LINE='You are the first mate.'
FM_CREW_GUIDELINES_REL='.agents/skills/firstmate-coding-guidelines/SKILL.md'
FM_CREW_AGENTS_WIP='.fm-agents-md-edit'
FM_CREW_CLAUDE_WIP='.fm-claude-md-edit'

fm_crew_write_overlay_body() {  # <dest>
  cat > "$1" <<'EOF'
<!-- firstmate-crew-worktree-instructions -->

# Role

You are a crewmate: an autonomous worker agent managed by firstmate.
You are not the first mate.
Spawn replaced this worktree's harness-loaded project instructions before launch so you cannot adopt the firstmate role from them.

Do not run `bin/fm-session-start.sh`, `bin/fm-spawn.sh`, `bin/fm-brief.sh`, `tasks-axi add`, or any other fleet-management command.
You have no fleet.
Do not address anyone as captain.
Do not open an interactive question dialog.
The only channel that reaches the supervisor is the status file named in your launch brief.

# Editing this repository

The committed `AGENTS.md` is firstmate's own operating contract.
It is source you may edit when the task requires it, not your job description.
Load `.agents/skills/firstmate-coding-guidelines/SKILL.md` before editing firstmate's shared tracked material.

Git still has the committed files.
This working copy is a spawn-time overlay.

If this task requires editing `AGENTS.md` itself, restore the committed file first with `git update-index --no-skip-worktree AGENTS.md` and then `git checkout HEAD -- AGENTS.md`.
You remain a crewmate after that restore.

If `.fm-agents-md-edit` exists, in-progress `AGENTS.md` edits were saved there before this overlay was installed.
If `.fm-claude-md-edit` exists, the same is true for `CLAUDE.md`.
EOF
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

fm_crew_exclude_path() {  # <worktree> <rel>
  local wt=$1 rel=$2 excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$excl" ] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF "$rel" "$excl" 2>/dev/null || printf '%s\n' "$rel" >> "$excl"
}

fm_crew_save_instruction_wip() {  # <worktree> <rel> <dest>
  local wt=$1 rel=$2 dest=$3
  [ -f "$wt/$rel" ] || return 0
  fm_file_is_crew_overlay "$wt/$rel" && return 0
  if git -C "$wt" diff --quiet HEAD -- "$rel" 2>/dev/null; then
    return 0
  fi
  cp "$wt/$rel" "$wt/$dest" || {
    echo "error: could not save in-progress $rel to $dest before installing crew instructions" >&2
    return 1
  }
  fm_crew_exclude_path "$wt" "$dest"
  echo "warning: saved in-progress $rel to $dest before installing crew instructions" >&2
}

fm_crew_skip_worktree() {  # <worktree> <rel>
  local wt=$1 rel=$2 state
  git -C "$wt" update-index --skip-worktree -- "$rel" || {
    echo "error: could not hide $rel from git status after installing crew instructions" >&2
    return 1
  }
  state=$(git -C "$wt" ls-files -v -- "$rel" 2>/dev/null | awk '{print substr($1,1,1)}')
  [ "$state" = S ] || {
    echo "error: $rel is not skip-worktree after crew overlay (git ls-files -v reported '${state:-none}')" >&2
    return 1
  }
}

fm_crew_install_overlay_file() {  # <worktree> <rel>
  local wt=$1 rel=$2 tmp
  tmp=$(mktemp "$wt/.fm-crew-overlay.XXXXXX") || {
    echo "error: could not create a temp file for the crew overlay in $wt" >&2
    return 1
  }
  fm_crew_write_overlay_body "$tmp" || {
    rm -f "$tmp"
    echo "error: could not write crew overlay for $rel" >&2
    return 1
  }
  mv "$tmp" "$wt/$rel" || {
    rm -f "$tmp"
    echo "error: could not install crew overlay at $rel" >&2
    return 1
  }
  fm_crew_skip_worktree "$wt" "$rel" || return 1
  fm_file_is_crew_overlay "$wt/$rel" || {
    echo "error: crew overlay at $rel is missing its marker after install" >&2
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
  fm_crew_save_instruction_wip "$wt" AGENTS.md "$FM_CREW_AGENTS_WIP" || return 1
  if [ -f "$wt/CLAUDE.md" ]; then
    fm_crew_save_instruction_wip "$wt" CLAUDE.md "$FM_CREW_CLAUDE_WIP" || return 1
  fi
  fm_crew_install_overlay_file "$wt" AGENTS.md || return 1
  if [ -f "$wt/CLAUDE.md" ] || [ -e "$wt/CLAUDE.md" ]; then
    fm_crew_install_overlay_file "$wt" CLAUDE.md || return 1
  fi
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
