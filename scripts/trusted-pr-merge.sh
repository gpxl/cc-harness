#!/usr/bin/env bash
# Merge a pull request only after host-side classification and a SHA-bound revalidation.
# This script intentionally lives in the trusted harness, not in a candidate checkout.
set -euo pipefail

# Resolved from this script's own location: every helper below must come from the TRUSTED
# harness, never from the candidate checkout, whose contents are the thing under review.
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
readonly script_dir

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
# The whole point of this wrapper is that it is not the code it is judging. Running it from inside
# the candidate would take both it and review-ack-check.sh from the branch under review, which
# could ship a permissive copy of the validator that decides whether it may merge.
case "$script_dir/" in
  "$checkout"/*) die "this wrapper lives inside the candidate checkout ($checkout); run the trusted copy instead" ;;
esac

# Containment is not enough on its own: ~/.claude/scripts is commonly a symlink into a working
# checkout of this very repository, so the wrapper and the acknowledgement checker can both come
# from the branch under review while sitting outside the directory passed as --checkout. Refuse
# when this script's own worktree is parked on the commit being judged.
script_head=$(git -C "$script_dir" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)
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
      title
      body
      author { login }
      authorAssociation
      labels(first: 100) { nodes { name } pageInfo { hasNextPage } }
      files(first: 100, after: $after) {
        nodes { path changeType }
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
  local renames=0
  local page_renames=0
  local previous_paths='[]'

  while :; do
    response=$(fetch_page "$after") || die 'GitHub metadata request failed'
    if ! jq -e '
      ((.errors? // []) | length == 0) and
      (.data.repository.pullRequest != null) and
      (.data.repository.pullRequest.id | type == "string") and
      (.data.repository.pullRequest.headRefOid | type == "string") and
      ((.data.repository.pullRequest.body // "") | type == "string") and
      ((.data.repository.pullRequest.title // "") | type == "string") and
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
    # RENAMED only. A COPIED file leaves its original in place, so nothing moved out of a covered
    # directory and there is no old side to classify; counting it here would hard-fail an ordinary
    # pull request whenever REST reports no previous_filename for the copy.
    page_renames=$(jq -r '[.data.repository.pullRequest.files.nodes[]? | select(.changeType == "RENAMED")] | length' <<<"$response") \
      || die 'could not read changed-file change types'
    case "$page_renames" in
      ''|*[!0-9]*) die 'GitHub returned an invalid change-type count' ;;
    esac
    renames=$((renames + page_renames))
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

  # The GraphQL files connection exposes the NEW path only — PullRequestChangedFile has no
  # previous-path field (schema introspection, 2026-09-16: additions, changeType, deletions, path,
  # viewerViewedState). So a rename that moves a check OUT of scripts/ or rules/ would present as
  # an ordinary path and escape the high-risk classification entirely. REST does carry
  # previous_filename, so the old paths are fetched there and classified alongside the new ones.
  if [ "$renames" -gt 0 ]; then
    previous_paths=$(gh api "repos/$owner/$repository/pulls/$pr_number/files" --paginate \
      --jq '[.[] | select(.previous_filename != null) | .previous_filename]' 2>/dev/null \
      | jq -cs 'add // []') || die 'could not fetch previous paths for a renamed file'
    if ! jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null <<<"$previous_paths"; then
      die 'GitHub returned invalid previous-path metadata'
    fi
    # Fail closed: fewer previous paths than renames means the old side of some rename is unknown,
    # and an unknown path cannot be classified as safe.
    if [ "$(jq -r 'length' <<<"$previous_paths")" -lt "$renames" ]; then
      die 'GitHub reported a rename whose previous path could not be resolved'
    fi
    all_paths=$(jq -cn --argjson existing "$all_paths" --argjson prev "$previous_paths" '$existing + $prev') \
      || die 'could not combine previous paths'
  fi

  jq -cn --argjson pr "$pr_json" --argjson paths "$all_paths" '$pr + {paths: $paths}'
}

# The surfaces whose change triggers a Stage 2 branch-completion review by risk class: the
# integrity of a check, or of the policy behind it, including the rules themselves
# (rules/branch-completion-review.md). Shared by the external-contributor hold below and by the
# review-acknowledgement requirement, so the two can never drift apart.
readonly HIGH_RISK_PATH_FILTER='
    def high_risk_path:
      . == "CLAUDE.md" or endswith("/CLAUDE.md") or
      . == "install.sh" or . == "uninstall.sh" or
      startswith("scripts/") or
      startswith("hooks/") or
      startswith("templates/") or
      startswith("codex/") or
      startswith(".github/") or
      test("(^|/)(repository|workflow)[-_]?settings(\\.|/|$)") or
      startswith(".claude/rules/") or
      startswith(".claude/agents/") or
      startswith("rules/") or
      startswith("agents/") or
      test("(^|/)\\.?(merge[-_]?gate|merge[-_]?policy|policy|gate)(\\..*)?$");'

# true when the pull request touches a review-triggering surface.
touches_review_trigger() {
  jq -r "$HIGH_RISK_PATH_FILTER"'
    if any(.paths[]?; high_risk_path) then "true" else "false" end
  '
}

# A pull request that changes a check, or the policy behind it, merges only with a machine-readable
# acknowledgement that the bounded review actually ran and what it concluded. Without this the
# merge rests on the orchestrator'"'"'s own report of its own review — measured 2026-09-16, when a PR
# that genuinely had a GO verdict merged with nothing confirming it.
review_ack_ok() {  # review_ack_ok <pr-json>
  local body ack
  body=$(jq -r '.body // ""' <<<"$1") || return 1
  # The acknowledgement is one line of the body, marked so it can be found without parsing prose.
  # Fenced regions are stripped first: a pull request that DOCUMENTS this format — the likeliest
  # kind of pull request to touch it — must not thereby satisfy it. The line must also be
  # unindented and unquoted, so an illustration or a quoted reply does not count, and the LAST
  # match wins so a template shown before the real acknowledgement does not shadow it.
  ack=$(printf '%s\n' "$body" | awk '
    # Tilde fences are ordinary Markdown, and a longer fence is closed only by one at least as
    # long, so a quad-backtick block wrapping a triple-backtick example stays fenced throughout.
    match($0, /^[[:space:]]*(`{3,}|~{3,})/) {
      marker = $0
      sub(/^[[:space:]]*/, "", marker)
      sub(/[^`~].*$/, "", marker)
      if (!fenced) { fenced = 1; open_marker = marker; next }
      if (substr(marker, 1, 1) == substr(open_marker, 1, 1) && length(marker) >= length(open_marker)) {
        fenced = 0; open_marker = ""
      }
      next
    }
    !fenced
  ' | sed -nE 's/^REVIEW ACK:[[:space:]]*//p' | tail -1)
  [ -n "$ack" ] || return 1
  # The TRUSTED checker, resolved from this script's directory. A candidate checkout could ship a
  # permissive copy of the validator it is being judged by.
  bash "$script_dir/review-ack-check.sh" "$ack" >/dev/null 2>&1
}

# What a squash merge publishes, measured on this repository (`gh api repos/gpxl/cc-harness`):
# squash_merge_commit_title=COMMIT_OR_PR_TITLE, squash_merge_commit_message=COMMIT_MESSAGES. So a
# MULTI-commit pull request's headline on the integration branch is the pull-request TITLE, which
# is in no tracked file and no commit message and which the gate's name-hygiene scan therefore has
# never seen; a single-commit one uses that commit's subject, which the gate does scan. The body
# stays on the pull-request page either way, which is public too. This check over-scans rather than
# under-scans on purpose: it runs on both, with the TRUSTED scanner and the trusted denylist, at
# both decision points, so a title edited during the candidate gate buys nothing.
enforce_name_hygiene() {  # enforce_name_hygiene <pr-json>
  local text_file out rc
  text_file=$(mktemp "${TMPDIR:-/tmp}/trusted-pr-merge-text.XXXXXX") || die 'could not create a scratch file'
  jq -r '((.title // "") + "\n" + (.body // ""))' <<<"$1" > "$text_file" || {
    rm -f "$text_file"
    die 'could not read the pull-request title and body'
  }
  # `set -e` is on: capture the scanner's real status without letting a non-zero one abort here,
  # because a denied name must produce a HOLD with a reason, not a bare exit 1.
  rc=0
  out=$(bash "$script_dir/name-hygiene.sh" --denylist "$script_dir/testdata/name-hashes.txt" \
    --text-file "$text_file" --label 'pull-request title and body' 2>&1) || rc=$?
  rm -f "$text_file"
  case "$rc" in
    0) return 0 ;;
    1)
      report_disposition HUMAN_HOLD denied-name-in-title-or-body
      printf '%s\n' "$out" >&2
      printf 'TRUSTED PR MERGE: a squash merge publishes this title verbatim; rewrite it before merging.\n' >&2
      exit "$HOLD_EXIT"
      ;;
    *)
      printf '%s\n' "$out" >&2
      die 'the name-hygiene scanner could not read the title and body'
      ;;
  esac
}

# Emits AGENT_AUTO or HUMAN_HOLD plus a stable reason. Unknown authors are deliberately
# not treated as external: absence or a new association enum must stop for a human.
classify_pr() {
  jq -r "$HIGH_RISK_PATH_FILTER"'
    def labels: [.labels.nodes[]?.name];
    def internal_association:
      .authorAssociation == "OWNER" or .authorAssociation == "MEMBER" or .authorAssociation == "COLLABORATOR";
    def known_external_association:
      .authorAssociation == "CONTRIBUTOR" or .authorAssociation == "FIRST_TIME_CONTRIBUTOR" or .authorAssociation == "FIRST_TIMER" or .authorAssociation == "NONE" or .authorAssociation == "MANNEQUIN";
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

# Applied at both decision points: a body edited during the gate must not buy a merge, and a
# path added during the gate must not escape the requirement.
enforce_review_ack() {  # enforce_review_ack <pr-json>
  local touches
  touches=$(touches_review_trigger <<<"$1") || die 'could not test changed paths for a review trigger'
  case "$touches" in
    true|false) ;;
    *) die 'invalid review-trigger test result' ;;
  esac
  [ "$touches" = true ] || return 0
  if ! review_ack_ok "$1"; then
    report_disposition HUMAN_HOLD missing-review-ack
    printf 'TRUSTED PR MERGE: this pull request changes a check or the policy behind it, so it merges\n' >&2
    printf 'only with a line in its body of the form:\n' >&2
    printf '  REVIEW ACK: rounds=<n> verdict=<GO|NO-GO> open_blockers=<n> user_decision="<words>" classes=<list>\n' >&2
    printf 'validated by scripts/review-ack-check.sh. See rules/branch-completion-review.md.\n' >&2
    exit "$HOLD_EXIT"
  fi
  printf 'TRUSTED PR MERGE: review acknowledgement accepted\n'
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
enforce_name_hygiene "$first_pr"
enforce_review_ack "$first_pr"

verified_head=$(jq -er '.headRefOid' <<<"$first_pr") || die 'could not read verified head SHA'
if [ -n "$script_head" ] && [ "$script_head" = "$verified_head" ]; then
  die "this wrapper's own worktree ($script_dir) is at the pull request's head $verified_head; run a copy that is not the branch under review"
fi
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
enforce_name_hygiene "$revalidated_pr"
enforce_review_ack "$revalidated_pr"

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
