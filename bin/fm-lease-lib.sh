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
#     refresh). Lease commands in one home serialize through the portable
#     state/.fm-lease-command.lock before inspecting or changing any lease.
#   - Actors: exactly "main" and "branch". The current actor is
#     $FM_SUPERVISION_ACTOR when set, else "main". The branch's shell gets an
#     immutable FM_SUPERVISION_ACTOR=branch plus its active generation injected
#     deterministically by the Pi branch extension's bash-tool spawnHook, not
#     by agent memory. The hook retains a tagged branch tool wrapper shell for
#     the lifetime of the command. The lease layer recognizes that live wrapper
#     throughout its descendant process tree, binds it to BRANCH, and rejects a
#     conflicting or discarded actor environment. Any other value is refused
#     loudly - an unknown actor is a wiring bug, not a third role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or FM_LEASE_HOLDER_PID - see bin/fm-lease.sh), and
#     both actors live inside that one pi process, so a dead recorded pid
#     means the process died; the lease is cleared at the next claim, guard,
#     or sweep. A lease held by a live pid but an abandoned conversation is
#     cleared by the session-start sweep only when the pid proves dead;
#     otherwise only the owning actor process may release it; release checks
#     both the actor and that the recorded holder pid is an ancestor of the
#     command, so changing an environment actor cannot bypass the fence.
#   - Guard semantics (fm_lease_guard): a live lease held by the OTHER actor
#     refuses with exit FM_LEASE_REFUSE_EXIT. Otherwise an active Pi actor
#     claims the task through fm-lease.sh and retains it until its entrypoint
#     exits. A home that never runs the Pi branch has no live extension marker
#     and never sets FM_SUPERVISION_ACTOR, so the guard is a no-op there.
#   - Role partition (fm_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers - refuse the
#     branch actor outright, lease or no lease.
#   - "backlog" is a reserved claimable resource name. In this release it is
#     branch-side containment around the branch's own data/backlog.md writes,
#     not a whole-file mutex: MAIN's tasks-axi path does not claim or inspect
#     this lease. A branch claim therefore prevents overlapping branch work
#     but does not imply that MAIN is absent.
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
  local actor=${FM_SUPERVISION_ACTOR:-main} active_generation branch_generation
  local pid=${BASHPID:-$$} parent process_command hops=0
  case "$actor" in
    main|branch) ;;
    *)
      echo "error: unknown FM_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
  active_generation=$(cat "$STATE/.pi-branch-generation" 2>/dev/null || true)

  # Environment and writable files are not process provenance: a nested shell
  # can discard the former and delete the latter. The branch spawn hook keeps a
  # tagged wrapper alive while its command runs, so descendants (including an
  # exec replacement) remain BRANCH without trusting child-controlled state.
  while [ "$hops" -lt 32 ] && [ -n "$pid" ]; do
    process_command=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
    case "$process_command" in
      *"fm-branch-shell:$active_generation"*)
        if [ -n "$active_generation" ]; then
          if [ "$actor" != branch ] && [ -n "${FM_SUPERVISION_ACTOR+x}" ]; then
            echo "error: actor override refused - a branch tool process cannot impersonate main" >&2
            return 1
          fi
          printf '%s\n' branch
          return 0
        fi
        ;;
    esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$parent" in ''|*[!0-9]*|1) break ;; esac
    pid=$parent
    hops=$((hops + 1))
  done

  # FM_PI_BRANCH_GENERATION belongs to the whole Pi process, including MAIN.
  # Only the branch-only lease generation is additional branch provenance.
  branch_generation=${FM_LEASE_GENERATION:-}
  if [ -n "$branch_generation" ] && [ -n "$active_generation" ] \
    && [ "$branch_generation" = "$active_generation" ]; then
    if [ "$actor" != branch ]; then
      echo "error: actor override refused - the active branch generation cannot impersonate main" >&2
      return 1
    fi
    printf '%s\n' branch
    return 0
  fi
  printf '%s\n' "$actor"
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

FM_LEASE_GUARD_ACQUIRED=
FM_LEASE_GUARD_ACTOR=

fm_lease_pid_is_ancestor() {
  local target=$1 pid=${BASHPID:-$$} parent hops=0
  while [ "$hops" -lt 12 ]; do
    [ "$pid" = "$target" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$parent" in ''|*[!0-9]*|1) return 1 ;; esac
    pid=$parent
    hops=$((hops + 1))
  done
  return 1
}

fm_lease_pi_session_active() {
  local marker="$STATE/.pi-branch-extension-loaded" marker_pid marker_lock marker_generation lock_pid
  marker_pid=$(sed -n '1p' "$marker" 2>/dev/null || true)
  marker_lock=$(sed -n '2p' "$marker" 2>/dev/null || true)
  marker_generation=$(sed -n '3p' "$marker" 2>/dev/null || true)
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -d '[:space:]' || true)
  case "$marker_pid:$marker_lock:$lock_pid" in *[!0-9:]*) return 1 ;; esac
  [ -n "$marker_pid" ] && [ "$marker_lock" = "$lock_pid" ] || return 1
  [ -n "${FM_PI_BRANCH_GENERATION:-}" ] \
    && [ "$marker_generation" = "$FM_PI_BRANCH_GENERATION" ] || return 1
  fm_lease_pid_is_ancestor "$marker_pid" || return 1
  fm_lease_pid_is_ancestor "$lock_pid"
}

# fm_lease_guard <task> <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>. Passes silently
# otherwise. Call after the task id is resolved and before the first mutation.
fm_lease_guard() {
  local task=$1 action=$2 actor lease_script holder_pid
  fm_lease_valid_id "$task" || return 0
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  if [ -z "${FM_SUPERVISION_ACTOR+x}" ] && ! fm_lease_pi_session_active; then
    return 0
  fi
  if fm_lease_live "$task"; then
    if [ "$FM_LEASE_ACTOR" != "$actor" ]; then
      echo "error: $action refused - task '$task' is leased to the $FM_LEASE_ACTOR supervision actor (state/.lease-$task); retry after the owning actor releases it" >&2
      exit "$FM_LEASE_REFUSE_EXIT"
    fi
    return 0
  fi
  lease_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-lease.sh"
  holder_pid=${FM_LEASE_HOLDER_PID:-${BASHPID:-$$}}
  if ! FM_LEASE_HOLDER_PID="$holder_pid" "$lease_script" claim "$task" --actor "$actor"; then
    exit "$FM_LEASE_REFUSE_EXIT"
  fi
  FM_LEASE_GUARD_ACQUIRED=$task
  FM_LEASE_GUARD_ACTOR=$actor
}

fm_lease_guard_release() {
  local lease_script
  [ -n "$FM_LEASE_GUARD_ACQUIRED" ] || return 0
  lease_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-lease.sh"
  "$lease_script" release "$FM_LEASE_GUARD_ACQUIRED" --actor "$FM_LEASE_GUARD_ACTOR" || true
  FM_LEASE_GUARD_ACQUIRED=
  FM_LEASE_GUARD_ACTOR=
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
