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
# skip-worktree also hides a worker's own edit to those files, so `git add -A`
# plus `git commit` would drop it without an error. The install therefore also
# writes a pre-commit guard that refuses any commit made while a skip-worktree
# instruction file no longer holds the overlay body. The guard lives in this
# worktree's own git dir and is selected through per-worktree `core.hooksPath`,
# so the primary checkout's hooks are never touched.
# fm_remove_crew_worktree_instructions undoes all of it: skip-worktree bits,
# the committed file contents, and the guard. bin/fm-spawn.sh calls it before
# it refreshes a pooled worktree, so a slot returned with the overlay still on
# it self-heals instead of wedging the next `git reset --hard`.
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
FM_CREW_HOOKS_DIRNAME='fm-crew-hooks'
FM_CREW_INSTRUCTION_FILES='AGENTS.md CLAUDE.md'

fm_crew_overlay_body() {
  cat <<'EOF'
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
Editing an overlaid file without that restore does not fail silently: a pre-commit guard refuses the commit and names the same restore commands.

If `.fm-agents-md-edit` exists, in-progress `AGENTS.md` edits were saved there before this overlay was installed.
If `.fm-claude-md-edit` exists, the same is true for `CLAUDE.md`.
EOF
}

fm_crew_write_overlay_body() {  # <dest>
  fm_crew_overlay_body > "$1"
}

# The blob hash of the overlay body as `git hash-object --no-filters` would
# report it for a file holding exactly that body.
fm_crew_overlay_blob_hash() {  # <worktree>
  local wt=$1 hash
  hash=$(fm_crew_overlay_body | git -C "$wt" hash-object --stdin) || return 1
  [ -n "$hash" ] || return 1
  printf '%s\n' "$hash"
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

fm_crew_save_instruction_wip() {  # <worktree> <rel> <dest>
  local wt=$1 rel=$2 dest=$3
  [ -f "$wt/$rel" ] || return 0
  fm_file_is_crew_overlay "$wt/$rel" && return 0
  fm_crew_file_differs_from_head "$wt" "$rel" || return 0
  cp "$wt/$rel" "$wt/$dest" || {
    echo "error: could not save in-progress $rel to $dest before installing crew instructions" >&2
    return 1
  }
  fm_crew_exclude_path "$wt" "$dest"
  echo "warning: saved in-progress $rel to $dest before installing crew instructions" >&2
}

fm_crew_is_skip_worktree() {  # <worktree> <rel>
  local wt=$1 rel=$2 state
  state=$(git -C "$wt" ls-files -v -- "$rel" 2>/dev/null | awk '{print substr($1,1,1)}')
  [ "$state" = S ]
}

fm_crew_skip_worktree() {  # <worktree> <rel>
  local wt=$1 rel=$2
  git -C "$wt" update-index --skip-worktree -- "$rel" || {
    echo "error: could not hide $rel from git status after installing crew instructions" >&2
    return 1
  }
  fm_crew_is_skip_worktree "$wt" "$rel" || {
    echo "error: $rel is not skip-worktree after crew overlay" >&2
    return 1
  }
}

fm_crew_commit_guard_dir() {  # <worktree>
  local git_dir
  git_dir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] || return 1
  printf '%s\n' "$git_dir/$FM_CREW_HOOKS_DIRNAME"
}

fm_crew_write_commit_guard() {  # <dest> <overlay-blob-hash>
  local dest=$1 hash=$2
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# Installed by bin/fm-crew-worktree-instructions-lib.sh for this worktree only.
# The crew overlay hides AGENTS.md and CLAUDE.md with skip-worktree, so a
# worker's edit to either file is dropped from every commit without an error.
# This guard turns that silent omission into a refused commit.
set -u
overlay='$hash'
guard_status=0
for rel in $FM_CREW_INSTRUCTION_FILES; do
  [ -f "\$rel" ] || continue
  state=\$(git ls-files -v -- "\$rel" 2>/dev/null | awk '{print substr(\$1,1,1)}')
  [ "\$state" = S ] || continue
  actual=\$(git hash-object --no-filters -- "\$rel" 2>/dev/null) || actual=
  [ "\$actual" = "\$overlay" ] && continue
  {
    echo "error: \$rel is the crew overlay, hidden from git with skip-worktree, and it has been edited."
    echo "error: this commit would silently omit every change to \$rel."
    echo "error: restore the committed file, then re-apply the intended source edits:"
    echo "error:   git update-index --no-skip-worktree -- \$rel && git checkout HEAD -- \$rel"
  } >&2
  guard_status=1
done
exit "\$guard_status"
EOF
}

# Select the guard through this worktree's own core.hooksPath. Per-worktree git
# config needs extensions.worktreeConfig, which is a shared-config setting whose
# one documented hazard is core.bare / core.worktree living in the shared file.
fm_crew_install_commit_guard() {  # <worktree>
  local wt=$1 dir hash tmp
  dir=$(fm_crew_commit_guard_dir "$wt") || {
    echo "error: could not resolve the git dir of $wt to install the crew commit guard" >&2
    return 1
  }
  hash=$(fm_crew_overlay_blob_hash "$wt") || {
    echo "error: could not hash the crew overlay body for the commit guard in $wt" >&2
    return 1
  }
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
  if ! fm_crew_write_commit_guard "$tmp" "$hash" || ! chmod +x "$tmp" || ! mv "$tmp" "$dir/pre-commit"; then
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

# Undo the overlay: clear the skip-worktree bits, restore the committed
# instruction files, and drop the commit guard.
# A worktree that never carried the overlay is a no-op, so a pooled slot can
# call this unconditionally before it refreshes its base.
fm_remove_crew_worktree_instructions() {  # <worktree>
  local wt=${1:-} rel failed=0
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0
  for rel in $FM_CREW_INSTRUCTION_FILES; do
    fm_crew_is_skip_worktree "$wt" "$rel" || continue
    if ! git -C "$wt" update-index --no-skip-worktree -- "$rel"; then
      echo "error: could not clear the skip-worktree bit on $rel in $wt" >&2
      failed=1
      continue
    fi
    if ! git -C "$wt" checkout HEAD -- "$rel"; then
      echo "error: could not restore the committed $rel in $wt" >&2
      failed=1
    fi
  done
  fm_crew_remove_commit_guard "$wt" || failed=1
  [ "$failed" -eq 0 ]
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
