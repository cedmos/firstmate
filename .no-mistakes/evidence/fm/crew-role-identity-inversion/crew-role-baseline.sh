#!/usr/bin/env bash
# Same spawn, run against the BASE commit (before the fix), to show the
# role inversion this change removes.
set -u

ROOT=${1:?worktree root}
SHA=${2:?base sha}
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-base.XXXXXX")
PROJECT="$DEMO/firstmate"; ORIGIN="$DEMO/origin.git"; POOL="$DEMO/pool"
FMHOME="$DEMO/home"; FAKEBIN="$DEMO/fakebin"

run() { printf '\n$ %s\n' "$*"; eval "$@"; }

git clone --quiet --no-hardlinks --branch fm/crew-role-identity-inversion "$ROOT" "$PROJECT"
git -C "$PROJECT" checkout -q -B main "$SHA"
git -C "$PROJECT" config user.name 'fm demo'
git -C "$PROJECT" config user.email 'fm-demo@example.invalid'
git clone --quiet --bare "$PROJECT" "$ORIGIN"
git -C "$PROJECT" remote set-url origin "file://$ORIGIN"
git -C "$PROJECT" worktree add --quiet --detach "$POOL" HEAD

mkdir -p "$FAKEBIN" "$FMHOME/data/base-crew-role-z9" "$FMHOME/projects" "$FMHOME/state" "$FMHOME/config"
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

printf '%s\n' 'BASE COMMIT (f170ced) - before the fix'
FM_HOME="$FMHOME" FM_DATA_OVERRIDE="$FMHOME/data" \
  "$PROJECT/bin/fm-brief.sh" base-crew-role-z9 firstmate --scout >/dev/null 2>&1
run "sed -n '1,3p' '$FMHOME/data/base-crew-role-z9/brief.md'"

fm_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$FMHOME" \
    FM_STATE_OVERRIDE="$FMHOME/state" FM_DATA_OVERRIDE="$FMHOME/data" \
    FM_PROJECTS_OVERRIDE="$FMHOME/projects" FM_CONFIG_OVERRIDE="$FMHOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$FAKEBIN:$PATH" \
    "$PROJECT/bin/fm-spawn.sh" "$1" "$PROJECT" --scout 2>&1
}
run "fm_spawn base-crew-role-z9 | tail -1"

printf '\n-- what the harness auto-loads in that crew worktree after spawn --\n'
run "sed -n '1,6p' '$POOL/AGENTS.md'"

printf '\n-- and session start still runs there, so a crewmate can take the helm --\n'
run "cd '$POOL' && FM_HOME='$FMHOME' FM_ROOT_OVERRIDE='$POOL' FM_STATE_OVERRIDE='$FMHOME/state' FM_DATA_OVERRIDE='$FMHOME/data' FM_CONFIG_OVERRIDE='$FMHOME/config' timeout 120 '$PROJECT/bin/fm-session-start.sh' 2>&1 | head -5; echo '...'"

git -C "$PROJECT" worktree remove --force "$POOL" >/dev/null 2>&1
rm -rf "$DEMO"
