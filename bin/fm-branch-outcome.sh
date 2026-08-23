#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"wake_seq":N,"epoch":N,"task":"...",
#     "wake":"...","verdict":"routine"|"captain","summary":"..."}. Existing lines are never
#     rewritten, reordered, or deleted by any subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq already
#     delivered into main's context (via the branch's append-only merge note,
#     or via the session-start replay). Records above the cursor are "unread":
#     the branch wrote them durably but main never saw them - the crash window
#     between the store write and the merge append.
#   - Delivery receipts live under $STATE/branch-outcomes-delivered/ until all
#     preceding outcome sequences are delivered; the cursor advances only over
#     that contiguous prefix.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the merge note is appended to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--wake-seq <n>] [--result-record]
#     Append one outcome record; prints the assigned seq. A positive wake-seq
#     is idempotent and returns the existing record instead of appending again.
#     --result-record prints status<TAB>record for the branch adapter.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after the records were appended
#     into main's context.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print unread records under a labeled header
#     without advancing the cursor.
#   fm-branch-outcome.sh startup-replay-ack --through <seq>
#     Advance the replay cursor only after the caller delivered replay output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
DELIVERED_DIR="$STATE/branch-outcomes-delivered"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--wake-seq <n>] [--result-record] | unread | mark-read --through <seq> | mark-delivered --seq <seq> | list [--recent <n>] | startup-replay | startup-replay-ack --through <seq>" >&2
  exit 2
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

last_seq() {
  local value
  value=$(tail -n 1 "$STORE" 2>/dev/null | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p')
  printf '%s\n' "${value:-0}"
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    [ ! -f "$DELIVERED_DIR/$seq" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
  for tmp in "$DELIVERED_DIR"/*; do
    [ -f "$tmp" ] || continue
    case "${tmp##*/}" in ''|*[!0-9]*) continue ;; esac
    [ "${tmp##*/}" -gt "$through" ] || rm -f -- "$tmp"
  done
}

advance_delivered_cursor() {
  local next last
  next=$(( $(read_cursor) + 1 ))
  last=$(last_seq)
  while [ "$next" -le "$last" ] && [ -f "$DELIVERED_DIR/$next" ]; do
    advance_cursor "$next"
    next=$((next + 1))
  done
}

acknowledge_through() { # <seq>
  advance_cursor "$1"
  advance_delivered_cursor
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    WAKE_SEQ=0
    RESULT_RECORD=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --wake-seq) WAKE_SEQ=${2:-}; shift 2 || usage ;;
        --result-record) RESULT_RECORD=1; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$WAKE_SEQ" in ''|*[!0-9]*) usage ;; esac
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    EXISTING_LINE=
    if [ "$WAKE_SEQ" -gt 0 ] && [ -s "$STORE" ]; then
      EXISTING_LINE=$(grep -m 1 '"wake_seq":'"$WAKE_SEQ"',' "$STORE" 2>/dev/null || true)
    fi
    if [ -n "$EXISTING_LINE" ]; then
      SEQ=$(record_seq "$EXISTING_LINE")
      CURSOR_VALUE=$(read_cursor)
      STATUS=existing-unread
      if [ "$SEQ" -le "$CURSOR_VALUE" ] || [ -f "$DELIVERED_DIR/$SEQ" ]; then
        STATUS=existing-delivered
      fi
      fm_lock_release "$LOCK"
      if [ "$RESULT_RECORD" -eq 1 ]; then
        printf '%s\t%s\n' "$STATUS" "$EXISTING_LINE"
      else
        printf '%s\n' "$SEQ"
      fi
      exit 0
    fi
    SEQ=$(( $(last_seq) + 1 ))
    LINE=$(printf '{"seq":%s,"wake_seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s"}' \
      "$SEQ" "$WAKE_SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")")
    printf '%s\n' "$LINE" >> "$STORE"
    fm_lock_release "$LOCK"
    if [ "$RESULT_RECORD" -eq 1 ]; then
      printf 'new\t%s\n' "$LINE"
    else
      printf '%s\n' "$SEQ"
    fi
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    acknowledge_through "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  mark-delivered)
    [ "${1:-}" = --seq ] || usage
    DELIVERED=${2:-}
    case "$DELIVERED" in ''|*[!0-9]*|0) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    CURSOR_VALUE=$(read_cursor)
    if [ "$DELIVERED" -gt "$CURSOR_VALUE" ]; then
      mkdir -p "$DELIVERED_DIR"
      : > "$DELIVERED_DIR/$DELIVERED"
      advance_delivered_cursor
    fi
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
      printf '%s\n' "$UNREAD"
    fi
    fm_lock_release "$LOCK"
    ;;
  startup-replay-ack)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    acknowledge_through "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
