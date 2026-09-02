#!/usr/bin/env bash
# Merge a pull request only after host-side classification and a SHA-bound revalidation.
# This script intentionally lives in the trusted harness, not in a candidate checkout.
set -euo pipefail

readonly HOLD_EXIT=20
readonly HEAD_CHANGED_EXIT=21
readonly CHECKOUT_HEAD_MISMATCH_EXIT=22

usage() {
  cat <<'EOF'
Usage:
  trusted-pr-merge.sh --repo OWNER/REPO --pr NUMBER --checkout DIR --gate RELATIVE_PATH [--merge] [-- GATE_ARGS...]

Fetches GitHub PR metadata and changed paths before executing the candidate gate.
It holds explicit human/hold labels, unknown author metadata, and external contributors
that change high-risk workflow, repository-settings, or merge-policy surfaces.

By default the wrapper is a validated dry run. Pass --merge to issue a squash merge.
The merge uses GraphQL expectedHeadOid, bound to the head SHA revalidated after the gate.
EOF
}

die() {
  printf 'TRUSTED PR MERGE: ERROR: %s\n' "$*" >&2
  exit 2
}

require_value() {
  [ "$#" -eq 2 ] && [ -n "$2" ] || die "missing value for $1"
}

repo=''
pr_number=''
checkout=''
gate=''
perform_merge=false
declare -a gate_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      require_value "$1" "${2:-}"
      repo=$2
      shift 2
      ;;
    --pr)
      require_value "$1" "${2:-}"
      pr_number=$2
      shift 2
      ;;
    --checkout)
      require_value "$1" "${2:-}"
      checkout=$2
      shift 2
      ;;
    --gate)
      require_value "$1" "${2:-}"
      gate=$2
      shift 2
      ;;
    --merge)
      perform_merge=true
      shift
      ;;
    --)
      shift
      gate_args=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$repo" in
  */*)
    [ -n "${repo%%/*}" ] && [ -n "${repo#*/}" ] || die '--repo must be OWNER/REPO'
    ;;
  *) die '--repo must be OWNER/REPO' ;;
esac
case "$pr_number" in
  ''|*[!0-9]*) die '--pr must be a positive integer' ;;
esac
[ "$pr_number" -gt 0 ] || die '--pr must be a positive integer'
[ -n "$checkout" ] || die '--checkout is required'
[ -n "$gate" ] || die '--gate is required'
[ -d "$checkout" ] || die "candidate checkout is not a directory: $checkout"
checkout=$(cd -- "$checkout" && pwd -P) || die "could not resolve candidate checkout: $checkout"
case "$gate" in
  /*|..|../*|*/../*|*/..) die '--gate must be a candidate-relative path without ..' ;;
esac

command -v gh >/dev/null 2>&1 || die 'gh is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v git >/dev/null 2>&1 || die 'git is required'

owner=${repo%%/*}
repository=${repo#*/}

metadata_query='query($owner: String!, $repository: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repository) {
    pullRequest(number: $number) {
      id
      headRefOid
      author { login }
      authorAssociation
      labels(first: 100) { nodes { name } pageInfo { hasNextPage } }
      files(first: 100, after: $after) {
        nodes { path }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'

fetch_page() {
  if [ -n "$1" ]; then
    gh api graphql \
      -f query="$metadata_query" \
      -f owner="$owner" \
      -f repository="$repository" \
      -F number="$pr_number" \
      -f after="$1"
  else
    gh api graphql \
      -f query="$metadata_query" \
      -f owner="$owner" \
      -f repository="$repository" \
      -F number="$pr_number"
  fi
}

# Prints a compact object containing the full, paginated changed-file list. The first
# metadata fetch is complete before this function returns, so no candidate code has run.
load_pr() {
  local after=''
  local response
  local pr_json=''
  local page_paths='[]'
  local all_paths='[]'
  local has_next='false'

  while :; do
    response=$(fetch_page "$after") || die 'GitHub metadata request failed'
    if ! jq -e '
      ((.errors? // []) | length == 0) and
      (.data.repository.pullRequest != null) and
      (.data.repository.pullRequest.id | type == "string") and
      (.data.repository.pullRequest.headRefOid | type == "string") and
      (.data.repository.pullRequest.files.pageInfo.hasNextPage | type == "boolean")
    ' >/dev/null <<<"$response"; then
      die 'GitHub returned incomplete or invalid pull-request metadata'
    fi

    if [ -z "$pr_json" ]; then
      pr_json=$(jq -ce '.data.repository.pullRequest | del(.files)' <<<"$response") || die 'could not parse pull-request metadata'
      if ! jq -e '.data.repository.pullRequest.labels.pageInfo.hasNextPage == false' >/dev/null <<<"$response"; then
        die 'GitHub returned too many labels to classify safely'
      fi
    fi
    page_paths=$(jq -ce '[.data.repository.pullRequest.files.nodes[]?.path]' <<<"$response") || die 'could not parse changed paths'
    if ! jq -e 'all(.data.repository.pullRequest.files.nodes[]?.path; type == "string")' >/dev/null <<<"$response"; then
      die 'GitHub returned a changed path with invalid metadata'
    fi
    all_paths=$(jq -cn --argjson existing "$all_paths" --argjson page "$page_paths" '$existing + $page') || die 'could not combine changed paths'
    has_next=$(jq -r '.data.repository.pullRequest.files.pageInfo.hasNextPage' <<<"$response") || die 'could not read changed-path pagination'
    case "$has_next" in
      true|false) ;;
      *) die 'GitHub returned invalid changed-path pagination' ;;
    esac
    if [ "$has_next" = false ]; then
      break
    fi
    after=$(jq -er '.data.repository.pullRequest.files.pageInfo.endCursor | strings | select(length > 0)' <<<"$response") || die 'GitHub returned an invalid changed-path cursor'
  done

  jq -cn --argjson pr "$pr_json" --argjson paths "$all_paths" '$pr + {paths: $paths}'
}

# Emits AGENT_AUTO or HUMAN_HOLD plus a stable reason. Unknown authors are deliberately
# not treated as external: absence or a new association enum must stop for a human.
classify_pr() {
  jq -r '
    def labels: [.labels.nodes[]?.name];
    def internal_association:
      .authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR";
    def known_external_association:
      .authorAssociation == "CONTRIBUTOR" or .authorAssociation == "FIRST_TIME_CONTRIBUTOR" or .authorAssociation == "FIRST_TIMER" or .authorAssociation == "NONE" or .authorAssociation == "MANNEQUIN";
    def high_risk_path:
      . == "CLAUDE.md" or
      startswith(".github/") or
      test("(^|/)(repository|workflow)[-_]?settings(\\.|/|$)") or
      startswith(".claude/rules/") or
      startswith(".claude/agents/") or
      startswith("rules/") or
      startswith("agents/") or
      test("(^|/)\\.?(merge[-_]?gate|merge[-_]?policy|policy|gate)(\\..*)?$");
    if (labels | index("human/hold")) then
      "HUMAN_HOLD human-hold-label"
    elif ((.author.login? // "") | length == 0) or ((internal_association or known_external_association) | not) then
      "HUMAN_HOLD unknown-author-metadata"
    elif (known_external_association and any(.paths[]?; high_risk_path)) then
      "HUMAN_HOLD external-high-risk-path"
    else
      "AGENT_AUTO ordinary-pr"
    end
  '
}

report_disposition() {
  local disposition=$1
  local reason=$2
  printf 'DISPOSITION: %s reason=%s\n' "$disposition" "$reason"
}

first_pr=$(load_pr)
first_classification=$(classify_pr <<<"$first_pr") || die 'could not classify pull request'
read -r first_disposition first_reason <<<"$first_classification"
case "$first_disposition" in
  HUMAN_HOLD)
    report_disposition "$first_disposition" "$first_reason"
    exit "$HOLD_EXIT"
    ;;
  AGENT_AUTO) report_disposition "$first_disposition" "$first_reason" ;;
  *) die 'invalid pull-request classification' ;;
esac

verified_head=$(jq -er '.headRefOid' <<<"$first_pr") || die 'could not read verified head SHA'
checkout_head=$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}') || die 'could not read candidate checkout HEAD'
if [ "$checkout_head" != "$verified_head" ]; then
  printf 'TRUSTED PR MERGE: ERROR: candidate checkout HEAD does not match PR head: %s != %s\n' "$checkout_head" "$verified_head" >&2
  exit "$CHECKOUT_HEAD_MISMATCH_EXIT"
fi
gate_path="$checkout/$gate"
[ -f "$gate_path" ] && [ -x "$gate_path" ] || die "candidate gate is not an executable file: $gate"

printf 'TRUSTED PR MERGE: running candidate gate at verified-head=%s\n' "$verified_head"
if [ "${#gate_args[@]}" -gt 0 ]; then
  (cd "$checkout" && "$gate_path" "${gate_args[@]}")
else
  (cd "$checkout" && "$gate_path")
fi
printf 'TRUSTED PR MERGE: candidate gate passed\n'

# Re-fetch all decision inputs immediately after the untrusted gate and before dry-run
# reporting or mutation. A changed label/path disposition is dominant over a prior allow.
revalidated_pr=$(load_pr)
revalidated_classification=$(classify_pr <<<"$revalidated_pr") || die 'could not reclassify pull request'
read -r revalidated_disposition revalidated_reason <<<"$revalidated_classification"
case "$revalidated_disposition" in
  HUMAN_HOLD)
    report_disposition "$revalidated_disposition" "$revalidated_reason"
    exit "$HOLD_EXIT"
    ;;
  AGENT_AUTO) : ;;
  *) die 'invalid revalidated pull-request classification' ;;
esac

revalidated_head=$(jq -er '.headRefOid' <<<"$revalidated_pr") || die 'could not read revalidated head SHA'
if [ "$verified_head" != "$revalidated_head" ]; then
  printf 'TRUSTED PR MERGE: ERROR: head changed after gate: %s -> %s\n' "$verified_head" "$revalidated_head" >&2
  exit "$HEAD_CHANGED_EXIT"
fi

if [ "$perform_merge" = false ]; then
  printf 'TRUSTED PR MERGE: DRY_RUN verified-head=%s\n' "$verified_head"
  exit 0
fi

pull_request_id=$(jq -er '.id' <<<"$revalidated_pr") || die 'could not read pull-request node id'
merge_query='mutation($pullRequestId: ID!, $expectedHeadOid: GitObjectID!) {
  mergePullRequest(input: {
    pullRequestId: $pullRequestId
    mergeMethod: SQUASH
    expectedHeadOid: $expectedHeadOid
  }) {
    pullRequest { merged mergeCommit { oid } }
  }
}'
merge_response=$(gh api graphql \
  -f query="$merge_query" \
  -f pullRequestId="$pull_request_id" \
  -f expectedHeadOid="$verified_head") || die 'GitHub merge request failed'
if ! jq -e '((.errors? // []) | length == 0) and (.data.mergePullRequest.pullRequest.merged == true)' >/dev/null <<<"$merge_response"; then
  die 'GitHub did not confirm a SHA-bound merge'
fi
printf 'TRUSTED PR MERGE: MERGED verified-head=%s\n' "$verified_head"
