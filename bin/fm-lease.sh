#!/usr/bin/env bash
# fm-lease.sh - claim, release, inspect, and sweep per-task supervision leases.
#
# The lease contract itself (file format, actors, staleness, guard semantics)
# is owned by bin/fm-lease-lib.sh; this is the command surface the two
# supervision actors use around the overlap set (steering, stopping, cleanup,
# backlog status, stuck-worker recovery). "backlog" is the reserved resource
# id for the whole-file guard around data/backlog.md writes.
#
# Usage:
#   fm-lease.sh claim <task> [--actor main|branch]
#       Take the lease for the calling actor. Idempotent for the holder (the
#       claim refreshes its own lease). Refuses with exit 6 while the other
#       actor holds a live lease. A stale lease (dead pid, or a torn record)
#       is cleared and re-claimed.
#   fm-lease.sh release <task> [--actor main|branch]
#       Drop the named actor's lease. Releasing a lease the actor does not
#       hold is a silent no-op, so a retry after a partial failure is safe.
#       Passing the OTHER actor's name is the explicit wedged-lease override
#       the guard's refusal message points at; it prints what it removed.
#   fm-lease.sh check <task>
#       Print "<actor> <pid> <epoch> <live|stale>" for a held lease, or
#       nothing (exit 1) when the task is unleased.
#   fm-lease.sh sweep
#       Remove every provably stale lease in this home. Run at session start
#       (a lease held by a dead actor is cleared at session start); safe to
#       run any time - a live lease is never touched.
#
# The default actor is $FM_SUPERVISION_ACTOR (else main); --actor overrides
# it. Exit codes: 0 ok, 1 check-miss, 2 usage, 6 refused (other actor holds).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

mkdir -p "$STATE"

usage() {
  echo "usage: fm-lease.sh claim|release <task> [--actor main|branch] | check <task> | sweep" >&2
  exit 2
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  claim|release)
    TASK=${1:-}
    shift 2>/dev/null || true
    fm_lease_valid_id "$TASK" || usage
    ACTOR=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --actor)
          ACTOR=${2:-}
          shift 2 || usage
          ;;
        *) usage ;;
      esac
    done
    if [ -z "$ACTOR" ]; then
      ACTOR=$(fm_lease_actor) || exit 2
    fi
    case "$ACTOR" in main|branch) ;; *) usage ;; esac
    ;;
  check)
    TASK=${1:-}
    [ "$#" -le 1 ] || usage
    fm_lease_valid_id "$TASK" || usage
    ;;
  sweep)
    [ "$#" -eq 0 ] || usage
    ;;
  *) usage ;;
esac

case "$CMD" in
  claim)
    LEASE=$(fm_lease_path "$TASK")
    if fm_lease_live "$TASK" && [ "$FM_LEASE_ACTOR" != "$ACTOR" ]; then
      echo "error: claim refused - task '$TASK' is leased to the $FM_LEASE_ACTOR supervision actor (state/.lease-$TASK)" >&2
      exit "$FM_LEASE_REFUSE_EXIT"
    fi
    # The lease outlives this CLI call, so its liveness pid must be the
    # long-lived supervising process: FM_LEASE_HOLDER_PID when the caller
    # provides one (the Pi branch extension passes its own process pid), else
    # the session-lock holder (state/.lock is the harness pid), else this
    # shell as a last resort so a bare test fixture still gets a live lease.
    HOLDER_PID=${FM_LEASE_HOLDER_PID:-}
    case "$HOLDER_PID" in *[!0-9]*) HOLDER_PID= ;; esac
    if [ -z "$HOLDER_PID" ]; then
      HOLDER_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -cd '0-9' || true)
    fi
    [ -n "$HOLDER_PID" ] || HOLDER_PID=$$
    TMP=$(mktemp "$STATE/.fm-lease-tmp.XXXXXX")
    printf '%s\t%s\t%s\n' "$ACTOR" "$HOLDER_PID" "$(date +%s)" > "$TMP"
    if [ -e "$LEASE" ]; then
      # Same-actor refresh, or a stale/torn record: replace atomically.
      mv -f -- "$TMP" "$LEASE"
    elif ! ln -- "$TMP" "$LEASE" 2>/dev/null; then
      # Lost the create race to the sibling actor; re-check who won.
      rm -f -- "$TMP"
      if fm_lease_live "$TASK" && [ "$FM_LEASE_ACTOR" != "$ACTOR" ]; then
        echo "error: claim refused - task '$TASK' was just leased to the $FM_LEASE_ACTOR supervision actor" >&2
        exit "$FM_LEASE_REFUSE_EXIT"
      fi
      TMP=$(mktemp "$STATE/.fm-lease-tmp.XXXXXX")
      printf '%s\t%s\t%s\n' "$ACTOR" "$HOLDER_PID" "$(date +%s)" > "$TMP"
      mv -f -- "$TMP" "$LEASE"
    else
      rm -f -- "$TMP"
    fi
    ;;
  release)
    if fm_lease_read "$TASK"; then
      if [ "$FM_LEASE_ACTOR" = "$ACTOR" ] || [ -z "$FM_LEASE_ACTOR" ]; then
        CALLER=$(fm_lease_actor 2>/dev/null || echo main)
        rm -f -- "$(fm_lease_path "$TASK")"
        if [ -n "$FM_LEASE_ACTOR" ] && [ "$FM_LEASE_ACTOR" != "$CALLER" ]; then
          echo "released the $FM_LEASE_ACTOR actor's lease on '$TASK' (explicit override)"
        fi
      fi
    fi
    ;;
  check)
    fm_lease_read "$TASK" || exit 1
    if fm_lease_live "$TASK"; then LIVENESS=live; else LIVENESS=stale; fi
    printf '%s %s %s %s\n' "${FM_LEASE_ACTOR:-unreadable}" "${FM_LEASE_PID:-0}" "${FM_LEASE_EPOCH:-0}" "$LIVENESS"
    ;;
  sweep)
    for LEASE in "$STATE"/.lease-*; do
      [ -e "$LEASE" ] || continue
      case "$LEASE" in *.lock) continue ;; esac
      TASK=${LEASE##*/.lease-}
      fm_lease_valid_id "$TASK" || continue
      fm_lease_clear_stale "$TASK"
    done
    ;;
esac
