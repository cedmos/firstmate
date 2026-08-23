#!/usr/bin/env bash
# fm-lease-lib.sh - the per-task supervision lease contract (one owner).
#
# WHY. On the Pi supervision branch (docs/pi-supervision-branch.md), two LLM
# actors share one firstmate home inside one pi process: MAIN (the captain's
# chat) and BRANCH (the persistent supervision conversation). Most records have
# exactly one natural owner, but the overlap set - steering or stopping a
# worker, post-landing cleanup, backlog status for a task, stuck-worker
# recovery - could otherwise be mutated by both actors at once. The lease is
# the merge-conflict analog: a small per-task file saying which actor is
# changing that task right now, and the mutating entrypoints refuse the other
# actor while it exists.
#
# CONTRACT.
#   - Lease file: $STATE/.lease-<task>, one line "<actor>\t<pid>\t<epoch>".
#     Written atomically (temp + ln for claim, temp + mv for a same-actor
#     refresh). Lease commands in one home serialize through the advisory
#     state/.fm-lease.lock before inspecting or changing any lease.
#   - Actors: exactly "main" and "branch". The current actor is
#     $FM_SUPERVISION_ACTOR when set, else "main". The branch's shell gets
#     FM_SUPERVISION_ACTOR=branch injected deterministically by the Pi branch
#     extension's bash tool, not by agent memory. Any other value is refused
#     loudly - an unknown actor is a wiring bug, not a third role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or FM_LEASE_HOLDER_PID - see bin/fm-lease.sh), and
#     both actors live inside that one pi process, so a dead recorded pid
#     means the process died; the lease is cleared at the next claim, guard,
#     or sweep. A lease held by a live pid but an abandoned conversation is
#     cleared by the session-start sweep only when the pid proves dead;
#     otherwise the loud release override in the refusal message is the
#     recovery path.
#   - Guard semantics (fm_lease_guard): no lease, a same-actor lease, or a
#     provably stale lease passes; a live lease held by the OTHER actor
#     refuses with exit FM_LEASE_REFUSE_EXIT. Stale records are removed by a
#     claim or session-start sweep. A home that never runs the Pi branch never
#     has lease files and never sets FM_SUPERVISION_ACTOR, so the
#     guard is a no-op there - non-Pi behavior is unchanged by construction.
#   - Role partition (fm_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers - refuse the
#     branch actor outright, lease or no lease.
#   - "backlog" is a reserved claimable resource name: the whole-file guard
#     around data/backlog.md writes, claimed the same way a task is.
#
# Sourced by bin/fm-send.sh, bin/fm-control.sh, bin/fm-teardown.sh,
# bin/fm-pr-merge.sh, bin/fm-merge-local.sh, bin/fm-spawn.sh, and
# bin/fm-lease.sh. Callers must have $STATE resolved before calling. No side
# effects on source. set -u / set -e safe.

# Distinct from usage errors (2), the gate refusal (3), and fm-send's
# unconfirmed submit (3): recognizable as "the other supervision actor holds
# this task right now - retry after the lease clears".
FM_LEASE_REFUSE_EXIT=6

# fm_lease_actor: print the current actor after validating it. Returns 1 (with
# stderr) for an unknown FM_SUPERVISION_ACTOR value.
fm_lease_actor() {
  local actor=${FM_SUPERVISION_ACTOR:-main}
  case "$actor" in
    main|branch) printf '%s\n' "$actor" ;;
    *)
      echo "error: unknown FM_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
}

# fm_lease_valid_id <id>: 0 iff the task/resource id is safe to embed in a
# state filename.
fm_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_lease_path() {
  printf '%s/.lease-%s\n' "$STATE" "$1"
}

# fm_lease_read <task>: read the lease into FM_LEASE_ACTOR/FM_LEASE_PID/
# FM_LEASE_EPOCH. Returns 1 when no lease file exists. A malformed lease
# (unreadable actor or pid) reads as actor "" so callers treat it as stale
# rather than blocking forever on a torn record.
fm_lease_read() {
  local file line
  file=$(fm_lease_path "$1")
  FM_LEASE_ACTOR=
  FM_LEASE_PID=
  FM_LEASE_EPOCH=
  [ -e "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || line=
  FM_LEASE_ACTOR=$(printf '%s' "$line" | cut -f1)
  FM_LEASE_PID=$(printf '%s' "$line" | cut -f2)
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-lease.sh check).
  FM_LEASE_EPOCH=$(printf '%s' "$line" | cut -f3)
  case "$FM_LEASE_ACTOR" in
    main|branch) ;;
    *) FM_LEASE_ACTOR= ;;
  esac
  case "$FM_LEASE_PID" in
    '' | *[!0-9]*) FM_LEASE_PID= ;;
  esac
  return 0
}

# fm_lease_live <task>: 0 iff a well-formed lease exists and its recorded pid
# is alive.
fm_lease_live() {
  fm_lease_read "$1" || return 1
  [ -n "$FM_LEASE_ACTOR" ] || return 1
  [ -n "$FM_LEASE_PID" ] || return 1
  kill -0 "$FM_LEASE_PID" 2>/dev/null
}

# fm_lease_clear_stale <task>: remove the lease file when it exists but is not
# live. Silent; never touches a live lease.
fm_lease_clear_stale() {
  local file
  file=$(fm_lease_path "$1")
  [ -e "$file" ] || return 0
  fm_lease_live "$1" && return 0
  rm -f -- "$file"
}

# fm_lease_guard <task> <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>. Passes silently
# otherwise. Call after the task id is resolved and before the first mutation.
fm_lease_guard() {
  local task=$1 action=$2 actor
  fm_lease_valid_id "$task" || return 0
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  fm_lease_live "$task" || return 0
  [ "$FM_LEASE_ACTOR" != "$actor" ] || return 0
  echo "error: $action refused - task '$task' is leased to the $FM_LEASE_ACTOR supervision actor (state/.lease-$task); retry after it releases, or clear a wedged lease with bin/fm-lease.sh release $task --actor $FM_LEASE_ACTOR" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
}

# fm_lease_forbid_branch <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT)
# when the current actor is the supervision branch. Guards the main-owned role
# partition; a home with no branch never sets the actor and always passes.
fm_lease_forbid_branch() {
  local action=$1 actor
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  [ "$actor" = branch ] || return 0
  echo "error: $action refused - the supervision branch never performs this action; report the outcome and leave it to main (role partition: docs/pi-supervision-branch.md)" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
}
