#!/usr/bin/env bash
# End-to-end demo of the crew role-identity fix, driven through the real
# bin/fm-spawn.sh, bin/fm-brief.sh and bin/fm-session-start.sh against a real
# clone of the firstmate repo. Only tmux/treehouse are faked, because this
# machine has no live pane to launch into.
set -u

ROOT=${1:?worktree root}
SHA=${2:?target sha}
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-demo.XXXXXX")
PROJECT="$DEMO/firstmate"
ORIGIN="$DEMO/origin.git"
POOL="$DEMO/pool"
FMHOME="$DEMO/home"
FAKEBIN="$DEMO/fakebin"

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; eval "$@"; }

# --- fixture: a real firstmate checkout, its origin, and a pooled worktree ----
git clone --quiet --no-hardlinks --branch fm/crew-role-identity-inversion "$ROOT" "$PROJECT"
git -C "$PROJECT" checkout -q -B main "$SHA"
git -C "$PROJECT" config user.name 'fm demo'
git -C "$PROJECT" config user.email 'fm-demo@example.invalid'
git clone --quiet --bare "$PROJECT" "$ORIGIN"
git -C "$PROJECT" remote set-url origin "file://$ORIGIN"
git -C "$PROJECT" worktree add --quiet --detach "$POOL" HEAD

mkdir -p "$FAKEBIN" "$FMHOME/data" "$FMHOME/projects" "$FMHOME/state" "$FMHOME/config"
printf 'codex\n' > "$FMHOME/config/crew-harness"
touch "$FMHOME/state/.last-watcher-beat"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"

fm_spawn() {  # <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$FMHOME" \
    FM_STATE_OVERRIDE="$FMHOME/state" FM_DATA_OVERRIDE="$FMHOME/data" \
    FM_PROJECTS_OVERRIDE="$FMHOME/projects" FM_CONFIG_OVERRIDE="$FMHOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL" \
    FM_GATE_REFUSE_BYPASS=1 \
    PATH="$FAKEBIN:$PATH" "$PROJECT/bin/fm-spawn.sh" "$1" "$PROJECT" --scout 2>&1
}
# Same documented test-harness escape hatch tests/lib.sh uses: this demo drives
# only its own temp-sandbox fleet, never the real one.

step "1. The brief firstmate hands a crewmate now fences the role itself"
FM_HOME="$FMHOME" FM_DATA_OVERRIDE="$FMHOME/data" \
  "$PROJECT/bin/fm-brief.sh" demo-crew-role-a1 firstmate --scout >/dev/null 2>&1
run "sed -n '1,7p' '$FMHOME/data/demo-crew-role-a1/brief.md'"

step "2. BEFORE the fix's overlay: what a harness auto-loads in the crew worktree"
run "sed -n '1,8p' '$POOL/AGENTS.md'"
run "cat '$POOL/CLAUDE.md'"
printf '\n-> the worker is told it IS the first mate; that outranks its launch brief.\n'

step "3. Spawn the scout into that pooled firstmate worktree"
run "fm_spawn demo-crew-role-a1 | tail -3"

step "4. AFTER: the same auto-load corpus a harness would read"
run "cat '$POOL/AGENTS.md'"
run "cat '$POOL/CLAUDE.md'"

step "5. The committed job description is untouched, and git sees no dirt"
run "git -C '$POOL' show HEAD:AGENTS.md | sed -n '1,2p'"
run "git -C '$POOL' status --porcelain --untracked-files=no; echo '(clean)'"

step "6. A crewmate that still reaches for session start is refused"
run "cd '$POOL' && FM_HOME='$FMHOME' FM_ROOT_OVERRIDE='$POOL' FM_STATE_OVERRIDE='$FMHOME/state' FM_DATA_OVERRIDE='$FMHOME/data' FM_CONFIG_OVERRIDE='$FMHOME/config' '$PROJECT/bin/fm-session-start.sh'; echo \"exit=\$?\""

step "7. The next task reuses the same overlaid slot: self-heal, refresh, re-overlay"
git -C "$PROJECT" commit -q --allow-empty -m 'main moved on while the slot was overlaid'
git -C "$PROJECT" push -q origin main
FM_HOME="$FMHOME" FM_DATA_OVERRIDE="$FMHOME/data" \
  "$PROJECT/bin/fm-brief.sh" demo-crew-role-b2 firstmate --scout >/dev/null 2>&1
run "fm_spawn demo-crew-role-b2 | tail -2"
run "git -C '$POOL' log --oneline -1 origin/main"
run "git -C '$POOL' log --oneline -1 HEAD"
run "sed -n '1,6p' '$POOL/AGENTS.md'"
run "git -C '$POOL' status --porcelain --untracked-files=no; echo '(clean)'"

step "8. Editing the overlaid AGENTS.md cannot vanish from a commit"
printf 'A crewmate edit to the real job description.\n' >> "$POOL/AGENTS.md"
run "git -C '$POOL' add -A && git -C '$POOL' commit -m 'crew edit' 2>&1; echo \"exit=\$?\""

step "9. The restore the overlay documents makes the same edit land"
run "git -C '$POOL' update-index --no-skip-worktree -- AGENTS.md"
run "git -C '$POOL' checkout HEAD -- AGENTS.md"
printf 'A crewmate edit to the real job description.\n' >> "$POOL/AGENTS.md"
run "git -C '$POOL' commit -qam 'crew edit to firstmate AGENTS.md' 2>&1; echo \"exit=\$?\""
run "git -C '$POOL' show --stat --oneline HEAD | head -3"

printf '\n'
git -C "$PROJECT" worktree remove --force "$POOL" >/dev/null 2>&1
rm -rf "$DEMO"
