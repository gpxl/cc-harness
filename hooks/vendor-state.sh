#!/usr/bin/env bash
# SessionStart hook (matcher: startup|resume|clear|compact — /clear and compaction drop the
# earlier context, so the line is re-injected). States the vendor switch up front, so the model
# never spends a turn on `bash ~/.claude/hooks/vendors.sh` or on a Codex readiness check.
#
# Prints one JSON line only when a routing vendor (hooks/model-routing-table.sh) is disabled.
# Silent when every vendor is enabled, and silent when the evidence is missing: an unreadable
# table, an absent resolver, or a vendor that no readable config file names. vendors.sh fails
# closed on that last case (unnamed = disabled), which is right for routing, but this hook is a
# claim about configuration: asserting "disabled by config" with no config line behind it would
# be unknown reported as known (rules/verification-integrity.md). For a context nudge the safe
# failure is silence; the always-loaded core still says how to check the switch by hand.
set -euo pipefail
trap 'exit 0' ERR

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
data_file="$root/model-routing-table.sh"
if [ ! -r "$data_file" ] || [ ! -r "$root/vendors.sh" ]; then
  exit 0
fi
. "$root/vendors.sh" || exit 0
. "$data_file" || exit 0
model_routing_table_valid || exit 0
command -v vendor_source >/dev/null 2>&1 || exit 0

# Positive evidence for every routing vendor: each must be named by a readable config file.
for vendor in "${MODEL_ROUTING_VENDORS[@]}"; do
  [ "$vendor" = anthropic ] && continue
  [ "$(vendor_source "$vendor")" = '(not configured)' ] && exit 0
done

disabled=$(model_routing_disabled_vendors) || exit 0
[ "$disabled" = none ] && exit 0
primary=$(model_routing_primary_vendor_index) || exit 0

if [ "${MODEL_ROUTING_VENDORS[$primary]}" = anthropic ]; then
  route='the Claude column of the equivalence table'
else
  route="${MODEL_ROUTING_VENDORS[$primary]} via ${MODEL_ROUTING_VENDOR_ROUTES[$primary]}"
fi
context="VENDOR SWITCH: $disabled disabled by config (bash ~/.claude/hooks/vendors.sh to inspect). Route to $route silently: no readiness check, no unavailability remark."

case "$context" in
  *\"*|*\\*|*"$MODEL_ROUTING_NEWLINE"*) exit 0 ;;
esac
printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"$context\"}}"
