#!/usr/bin/env bash
# Validate the machine-readable acknowledgement for a bounded branch review.
set -u

usage() {
  printf '%s\n' "Usage: scripts/review-ack-check.sh '<ack note>' [--max-rounds 3]" >&2
}

review_ack_field() {
  # Values are ordinary tokens except user_decision, which may be quoted user words.
  local note=$1 key=$2 pattern
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

review_ack_field_count() {
  local note=$1 key=$2 rest pattern count=0 matched before
  rest=$note
  pattern="(^|[[:space:]])${key}=(\"[^\"]*\"|[^[:space:]]+)"
  while [[ "$rest" =~ $pattern ]]; do
    matched=${BASH_REMATCH[0]}
    count=$((count + 1))
    before=${rest%%"$matched"*}
    rest=${rest:$(( ${#before} + ${#matched} ))}
  done
  printf '%s' "$count"
}

# Other measurement scripts source these parsing helpers so field syntax has one definition.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

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

rounds=$(review_ack_field "$note" rounds)
verdict=$(review_ack_field "$note" verdict)
open_blockers=$(review_ack_field "$note" open_blockers)
user_decision=$(review_ack_field "$note" user_decision)
classes=$(review_ack_field "$note" classes)

fail() {
  printf 'REVIEW ACK: FAIL %s\n' "$1"
  exit 1
}

for required_field in rounds verdict open_blockers classes; do
  [ "$(review_ack_field_count "$note" "$required_field")" -le 1 ] || fail "duplicate $required_field="
done

[ -n "$rounds" ] || fail 'missing rounds='
[ -n "$verdict" ] || fail 'missing verdict='
[ -n "$open_blockers" ] || fail 'missing open_blockers='
[ -n "$classes" ] || fail 'missing classes='
case "$rounds" in *[!0-9]*) fail 'invalid rounds=' ;; esac
case "$open_blockers" in *[!0-9]*) fail 'invalid open_blockers=' ;; esac
case "$verdict" in GO|NO-GO) ;; *) fail 'invalid verdict=' ;; esac

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
