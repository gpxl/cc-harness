#!/usr/bin/env bash
# Validate the machine-readable acknowledgement for a bounded branch review.
set -u

usage() {
  printf '%s\n' "Usage: scripts/review-ack-check.sh '<ack note>' [--max-rounds 3]" >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

note=$1
shift
max_rounds=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-rounds)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      max_rounds=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$max_rounds" in ''|*[!0-9]*|0) usage; exit 2 ;; esac

field() {
  # Values are ordinary tokens except user_decision, which may be quoted user words.
  local key=$1 pattern
  pattern="(^|[[:space:]])${key}=\\\"([^\\\"]*)\\\""
  if [[ "$note" =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  pattern="(^|[[:space:]])${key}=([^[:space:]]+)"
  if [[ "$note" =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 0
}

rounds=$(field rounds)
verdict=$(field verdict)
open_blockers=$(field open_blockers)
user_decision=$(field user_decision)
classes=$(field classes)

fail() {
  printf 'REVIEW ACK: FAIL %s\n' "$1"
  exit 1
}

[ -n "$rounds" ] || fail 'missing rounds='
[ -n "$verdict" ] || fail 'missing verdict='
[ -n "$open_blockers" ] || fail 'missing open_blockers='
[ -n "$classes" ] || fail 'missing classes='
case "$rounds" in *[!0-9]*) fail 'invalid rounds=' ;; esac
case "$open_blockers" in *[!0-9]*) fail 'invalid open_blockers=' ;; esac

if [ "$rounds" -gt "$max_rounds" ] && [ -z "$user_decision" ]; then
  fail "rounds=$rounds exceeds max_rounds=$max_rounds"
fi
if [ "$verdict" = 'NO-GO' ] && [ -z "$user_decision" ]; then
  fail 'verdict=NO-GO without user_decision='
fi
if [ "$open_blockers" -gt 0 ] && [ -z "$user_decision" ]; then
  fail "open_blockers=$open_blockers without user_decision="
fi
if [ -n "$user_decision" ]; then
  printf 'REVIEW ACK: PASS rounds=%s verdict=%s open_blockers=%s classes=%s user_decision="%s"\n' \
    "$rounds" "$verdict" "$open_blockers" "$classes" "$user_decision"
else
  printf 'REVIEW ACK: PASS rounds=%s verdict=%s open_blockers=%s classes=%s\n' \
    "$rounds" "$verdict" "$open_blockers" "$classes"
fi
