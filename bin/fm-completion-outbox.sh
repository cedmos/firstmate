#!/usr/bin/env bash
# Durably deliver a captain-visible crew result to Flowy.
#
# Usage:
#   fm-completion-outbox.sh --status STATUS_FILE [--no-drain] [--dry-run]
#   fm-completion-outbox.sh --drain [--dry-run]
#
# Delivery is a two-stage durable outbox, never one best-effort POST.
#
# RECORD (--status). Only the final non-empty status line is considered, and
# only done:, failed:, blocked:, and needs-decision: are results; anything else
# is a silent no-op. A result becomes an immutable record at
# state/flowy-outbox/pending/<task>.<digest> BEFORE any network call, where
# <digest> covers the result line together with the status file's wake
# signature. Re-observing an unchanged status file is therefore a no-op, while
# the same result text written again as a genuinely new event gets its own
# record, as does a second distinct result for the same task, so no result can
# overwrite another. --status then drains unless --no-drain is given.
#
# RECORD ONLY (--status --no-drain). Records exactly as above and returns
# without any network call, Keychain read, or endpoint-configuration read, so a
# caller on a latency-sensitive path can never be stalled by an unreachable
# Flowy. Some later --drain is the sole owner of delivering what it recorded.
#
# CALLERS. bin/fm-watch.sh uses --no-drain on its signal path, because that path
# runs immediately before the wake and must never wait on the network. Its
# per-pass --drain is the sole AUTHORITATIVE delivery owner. Because a wake ends
# the watcher process, a result recorded on the signal path would otherwise wait
# for the next watcher generation to deliver it, so the watcher also runs one
# --drain from its EXIT path after the wake is already durable. That exit drain
# is a promptness optimization only, and it carries a hard total wall-clock
# bound of FM_FLOWY_EXIT_DRAIN_SECONDS (default 5), well under the watcher's
# 15-second poll: without the bound a blackholed endpoint would keep the exiting
# watcher alive and delay re-arming, which is exactly the stall the record-only
# signal path removes, moved one step later. Hitting the bound is a normal, safe
# outcome - the record simply stays pending for the next per-pass drain.
#
# DRAIN (--drain, and implicitly after --status). Pending records are drained
# oldest first by the monotonic ordinal each record carries, never by filename
# collation, and POSTed as JSON to the URL in config/grok-flowy-webhook,
# authenticated with the Keychain Bearer key for service firstmate-flowy-webhook.
# No environment variable configures the endpoint. A record retires ONLY on
# HTTP 2xx, at which point its per-record receipt is written to
# state/flowy-outbox/delivered/<task>.<digest>.md. Any other outcome - a non-2xx
# code, a transport failure, a missing URL file, an unavailable key - leaves the
# record pending, so the next drain retries it and delivery state survives a
# restart. A receipt therefore never exists without a 2xx. A transport failure
# is endpoint-wide rather than record-specific, so the first one ends the pass
# and every remaining record simply stays pending for the next drain; a
# per-record HTTP code such as 503 keeps the pass going.
#
# state/flowy-last.md is an aggregate DISPLAY snapshot and is never delivery
# authority. Only a 2xx creates it or moves its files: and status: lines, which
# then describe the NEWEST result that actually reached Flowy. Its pending: line
# lists the task ids whose results are still undelivered, or (none), and is
# refreshed in an existing snapshot whenever the pending set changes, including
# on a record-only run and on a pass that delivered nothing; every other line is
# carried forward unchanged, so pending: is the one line that moves without a
# 2xx.
#
# --dry-run reports what it would record and send and writes nothing at all: no
# record, no receipt, no aggregate snapshot, and no network or Keychain call.
#
# Exit 2 on usage. A draining run exits 0 when nothing is left pending and 1
# when a record is still pending or the run could not complete. A --no-drain run
# exits 0 whenever the result is durably recorded, and 1 only when recording
# itself failed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# The portable lock helpers are the repo's one owner of dead-owner takeover, so
# a drain killed mid-POST cannot wedge every later delivery behind its lock.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# The repo's shared millisecond clock, used for the record ordinal below.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

OUTBOX="$STATE/flowy-outbox"
PENDING_DIR="$OUTBOX/pending"
DELIVERED_DIR="$OUTBOX/delivered"
ORDINAL_FILE="$OUTBOX/.ordinal"
DRAIN_LOCK="$OUTBOX/.drain.lock"
SNAPSHOT="$STATE/flowy-last.md"
WEBHOOK_FILE="$CONFIG/grok-flowy-webhook"
KEYCHAIN_SERVICE=firstmate-flowy-webhook
KEYCHAIN_ACCOUNT=flowy
HTTP_TIMEOUT=${FM_FLOWY_HTTP_TIMEOUT:-20}

usage() {
  echo "usage: fm-completion-outbox.sh --status STATUS_FILE [--no-drain] [--dry-run]" >&2
  echo "       fm-completion-outbox.sh --drain [--dry-run]" >&2
  exit 2
}

# The header comment above is this script's full contract, so --help prints it
# rather than a second copy that could drift from it.
help() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit 0
}

note() { echo "fm-completion-outbox: $*" >&2; }

status_file=
mode=
dry_run=0
no_drain=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status)
      [ "$#" -ge 2 ] || usage
      [ -z "$mode" ] || usage
      mode=status
      status_file=$2
      shift 2
      ;;
    --drain)
      [ -z "$mode" ] || usage
      mode=drain
      shift
      ;;
    --no-drain)
      no_drain=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help) help ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || usage
# --no-drain narrows --status to its record stage; it cannot narrow a run whose
# only stage is the drain.
[ "$mode" = status ] || [ "$no_drain" -eq 0 ] || usage

digest_of() {  # <text>
  local sum
  if command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$1" | shasum -a 256) || return 1
  else
    sum=$(printf '%s' "$1" | sha256sum) || return 1
  fi
  printf '%s' "${sum%% *}" | cut -c1-12
}

# A record field may contain '=' or a tab, so each is read by stripping its own
# key prefix rather than by splitting the line.
record_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# Prefer a durable deliverable the captain can open over the status log itself,
# and keep the path home-relative so no fixture or private absolute path is
# published to Flowy.
artifact_for() {  # <task> <status-file>
  if [ -f "$FM_HOME/data/$1/report.md" ]; then
    printf 'data/%s/report.md' "$1"
  else
    printf '%s' "${2#"$FM_HOME"/}"
  fi
}

# A strictly increasing stamp for record creation order, kept separate from the
# whole-second recorded= field so the payload's meaning does not change.
# fm_timing_now_ms is the repo's shared millisecond clock, but it degrades to
# whole seconds on a shell without EPOCHREALTIME (macOS system bash 3.2, which
# `env bash` still resolves to here), and two records written in one second
# would then tie and fall back to path collation - exactly the ordering bug the
# drain order exists to close. Carrying the previous value forward as a floor
# makes the stamp monotonic however coarse the clock is, and also survives a
# clock that steps backwards.
next_ordinal() {
  local now last tmp
  now=$(fm_timing_now_ms) || now=0
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  last=$(cat "$ORDINAL_FILE" 2>/dev/null || printf '0')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$now" -gt "$last" ] || now=$((last + 1))
  if tmp=$(umask 077; mktemp "$OUTBOX/.ordinal.XXXXXX"); then
    printf '%s\n' "$now" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$ORDINAL_FILE"
  fi
  printf '%s' "$now"
}

# Oldest recorded result first. A plain glob is collation-ordered, which would
# let the drain finish on an older record and hand the display snapshot a result
# that is not the newest one delivered. A record written before this field
# existed sorts first, which is where an older result belongs.
pending_records() {
  local record ordinal tab
  tab=$(printf '\t')
  for record in "$PENDING_DIR"/*; do
    [ -f "$record" ] || continue
    ordinal=$(record_field "$record" ordinal)
    case "$ordinal" in ''|*[!0-9]*) ordinal=0 ;; esac
    printf '%s%s%s\n' "$ordinal" "$tab" "$record"
  done | LC_ALL=C sort -t"$tab" -k1,1n -k2,2 | cut -d"$tab" -f2-
}

pending_task_ids() {
  local record ids="" task
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    task=$(record_field "$record" task)
    [ -n "$task" ] || continue
    case " $ids " in *" $task "*) continue ;; esac
    ids="$ids $task"
  done <<EOF
$(pending_records)
EOF
  if [ -z "$ids" ]; then
    printf '(none)'
  else
    printf '%s' "${ids# }" | tr ' ' ','
  fi
}

record_result() {  # <status-file>
  local file=$1 result task digest record artifact tmp signature ordinal
  [ -f "$file" ] && [ ! -L "$file" ] || {
    note "status file is unavailable or unsafe: $file"
    return 1
  }
  case "$file" in
    "$STATE"/*.status) ;;
    *)
      note "status file is outside state: $file"
      return 1
      ;;
  esac

  result=$(awk 'NF { line=$0 } END { print line }' "$file")
  case "$result" in
    done:*|failed:*|blocked:*|needs-decision:*) ;;
    *) return 0 ;;
  esac

  task=$(basename "$file" .status)
  # The digest covers the watcher's own wake signature for this status file as
  # well as the result line, so re-observing unchanged bytes still de-duplicates
  # while a genuinely new event that happens to carry identical text - the same
  # templated blocked: line raised a second time - is recorded and delivered
  # again instead of being suppressed forever.
  signature=$(fm_wake_signal_sig "$file") || signature=
  digest=$(digest_of "$signature|$result") || {
    note "cannot digest the result for $task"
    return 1
  }
  record="$PENDING_DIR/$task.$digest"
  artifact=$(artifact_for "$task" "$file")

  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY RUN: would record %s result for %s (%s)\n' "${result%%:*}" "$task" "$artifact" >&2
    return 0
  fi

  mkdir -p "$PENDING_DIR" "$DELIVERED_DIR"
  # Immutable: an existing record or an existing receipt for this exact result
  # is already the durable truth, and rewriting either would reopen the
  # overwrite hole this outbox exists to close.
  if [ -e "$record" ] || [ -e "$DELIVERED_DIR/$task.$digest.md" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$PENDING_DIR/.record.XXXXXX") || {
    note "cannot create a pending record for $task"
    return 1
  }
  ordinal=$(next_ordinal)
  {
    printf 'task=%s\n' "$task"
    printf 'digest=%s\n' "$digest"
    printf 'recorded=%s\n' "$(date +%s)"
    printf 'ordinal=%s\n' "$ordinal"
    printf 'artifact=%s\n' "$artifact"
    printf 'status=%s\n' "$file"
    printf 'result=%s\n' "$result"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$record"
  # The pending set just grew, so the snapshot's pending: line would otherwise
  # keep claiming this result is already delivered.
  refresh_snapshot_pending || true
}

webhook_url() {
  local url
  [ -r "$WEBHOOK_FILE" ] || {
    note "missing Flowy webhook URL at $WEBHOOK_FILE"
    return 1
  }
  url=$(tr -d '\r\n' < "$WEBHOOK_FILE")
  case "$url" in
    https://*|http://*) printf '%s' "$url" ;;
    *)
      note "Flowy webhook URL is invalid"
      return 1
      ;;
  esac
}

# Never printed, never written to state, never recorded in a receipt.
webhook_key() {
  local key
  key=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)
  # The account-qualified entry is the documented one; the same service without
  # an account is the older entry and is read only when that is absent.
  [ -n "$key" ] || key=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  [ -n "$key" ] || {
    note "Flowy webhook key is unavailable"
    return 1
  }
  printf '%s' "$key"
}

# Set by deliver_record on success so the aggregate snapshot describes the last
# result that actually reached Flowy, never one that merely reached disk. The
# drain walks its records oldest first, so the last one set here is the newest.
DELIVERED_TASK=
DELIVERED_RESULT=
DELIVERED_ARTIFACT=

# Set by deliver_record when the endpoint gave no HTTP response at all. That is
# an endpoint-wide condition, not a property of the record being sent, so the
# drain stops attempting further records for this pass.
TRANSPORT_FAILED=0

deliver_record() {  # <record> <url> <key>
  local record=$1 url=$2 key=$3 base task digest result artifact recorded payload code receipt tmp
  base=$(basename "$record")
  task=$(record_field "$record" task)
  digest=$(record_field "$record" digest)
  result=$(record_field "$record" result)
  artifact=$(record_field "$record" artifact)
  recorded=$(record_field "$record" recorded)
  if [ -z "$task" ] || [ -z "$result" ]; then
    note "pending record is unreadable and was left in place: $record"
    return 1
  fi
  receipt="$DELIVERED_DIR/$base.md"
  # A crash between writing the receipt and retiring the record must not re-POST
  # an already-delivered result.
  if [ -f "$receipt" ]; then
    rm -f "$record"
    DELIVERED_TASK=$task
    DELIVERED_RESULT=$result
    DELIVERED_ARTIFACT=$artifact
    return 0
  fi

  payload=$(jq -cn \
    --arg source flowy-completion-outbox \
    --arg event result \
    --arg task "$task" \
    --arg digest "$digest" \
    --arg result "$result" \
    --arg artifact "$artifact" \
    --arg recorded "$recorded" \
    '{source:$source,event:$event,task:$task,digest:$digest,result:$result,artifact:$artifact,recorded:$recorded}') || {
    note "cannot build the payload for $task"
    return 1
  }

  code=$(printf '%s' "$payload" | curl --silent --show-error --max-time "$HTTP_TIMEOUT" \
    --output /dev/null --write-out '%{http_code}' \
    --request POST "$url" \
    --header "Authorization: Bearer $key" \
    --header 'Content-Type: application/json' \
    --data-binary @-) || code=
  case "$code" in
    2??) ;;
    *)
      [ -n "$code" ] || TRANSPORT_FAILED=1
      note "Flowy webhook returned ${code:-no response} for $task; result stays pending"
      return 1
      ;;
  esac

  tmp=$(umask 077; mktemp "$DELIVERED_DIR/.receipt.XXXXXX") || {
    note "delivered $task but cannot write its receipt"
    return 1
  }
  {
    printf 'FM->Flowy\n'
    printf 'files: %s\n' "$artifact"
    printf 'status: %s: %s\n' "$task" "$result"
    printf 'delivered: HTTP %s\n' "$code"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$receipt"
  rm -f "$record"
  DELIVERED_TASK=$task
  DELIVERED_RESULT=$result
  DELIVERED_ARTIFACT=$artifact
}

write_snapshot() {  # <task> <result> <artifact>
  local task=$1 result=$2 artifact=$3 tmp
  tmp=$(umask 077; mktemp "$STATE/.flowy-last.XXXXXX") || {
    note "cannot refresh the display snapshot"
    return 1
  }
  {
    printf 'FM->Flowy\n'
    # Heartbeat state is the Flowy ACK gate's fact, not this script's. The line
    # is carried through unchanged from the snapshot's existing shape.
    printf 'HEARTBEAT: OFF (Captain ACK)\n'
    printf 'files: %s\n' "$artifact"
    printf 'status: %s: %s\n' "$task" "$result"
    printf 'pending: %s\n' "$(pending_task_ids)"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SNAPSHOT"
}

# Move ONLY the pending: line of an existing snapshot, carrying every other line
# forward unchanged. A snapshot that does not exist yet is left alone: creating
# one here would give the display a files:/status: pair no 2xx ever authorized.
refresh_snapshot_pending() {
  local tmp ids
  [ -f "$SNAPSHOT" ] || return 0
  ids=$(pending_task_ids)
  tmp=$(umask 077; mktemp "$STATE/.flowy-last.XXXXXX") || {
    note "cannot refresh the display snapshot's pending line"
    return 1
  }
  awk -v ids="$ids" '
    /^pending: / { print "pending: " ids; seen = 1; next }
    { print }
    END { if (!seen) print "pending: " ids }
  ' "$SNAPSHOT" > "$tmp" || {
    rm -f "$tmp"
    note "cannot refresh the display snapshot's pending line"
    return 1
  }
  chmod 600 "$tmp"
  mv -f "$tmp" "$SNAPSHOT"
}

drain() {
  local records record url key delivered=0 remaining=0 rc=0

  records=$(pending_records)
  [ -n "$records" ] || return 0

  if [ "$dry_run" -eq 1 ]; then
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      printf 'DRY RUN: would POST %s\n' "$(basename "$record")" >&2
    done <<EOF
$records
EOF
    return 0
  fi

  # One drain at a time, so two passes cannot both POST the same record.
  if ! fm_lock_try_acquire "$DRAIN_LOCK"; then
    note "another drain holds the outbox lock; results stay pending"
    return 1
  fi
  trap 'fm_lock_release "$DRAIN_LOCK"' EXIT

  # Re-read under the lock so this pass sees every record written since the
  # cheap pre-lock check, including one a concurrent recorder just landed.
  records=$(pending_records)

  url=$(webhook_url) || rc=1
  if [ "$rc" -eq 0 ]; then
    key=$(webhook_key) || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$DRAIN_LOCK"
    trap - EXIT
    return 1
  fi

  TRANSPORT_FAILED=0
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    [ -f "$record" ] || continue
    # The endpoint already proved unreachable this pass, so every further POST
    # would only buy another full timeout. Count the record as still pending and
    # leave it untouched for the next drain.
    if [ "$TRANSPORT_FAILED" -eq 1 ]; then
      remaining=$((remaining + 1))
      continue
    fi
    if deliver_record "$record" "$url" "$key"; then
      delivered=$((delivered + 1))
    else
      remaining=$((remaining + 1))
    fi
  done <<EOF
$records
EOF

  if [ "$TRANSPORT_FAILED" -eq 1 ] && [ "$remaining" -gt 1 ]; then
    note "the Flowy endpoint did not respond, so $remaining results stay pending for the next drain"
  fi

  if [ "$delivered" -gt 0 ]; then
    write_snapshot "$DELIVERED_TASK" "$DELIVERED_RESULT" "$DELIVERED_ARTIFACT" || rc=1
  else
    refresh_snapshot_pending || rc=1
  fi
  [ "$remaining" -eq 0 ] || rc=1

  fm_lock_release "$DRAIN_LOCK"
  trap - EXIT
  return "$rc"
}

rc=0
if [ "$mode" = status ]; then
  record_result "$status_file" || rc=1
fi
if [ "$no_drain" -eq 0 ]; then
  drain || rc=1
fi
exit "$rc"
