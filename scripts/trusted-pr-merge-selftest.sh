#!/usr/bin/env bash
# Hermetic selftest for trusted-pr-merge.sh; it never contacts GitHub or merges a PR.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wrapper="$script_dir/trusted-pr-merge.sh"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/trusted-pr-merge-selftest.XXXXXX") || exit 1
# A completion sentinel, not `$?`: on bash 3.2 (the system shell here) a script killed by
# set -e/set -u runs its EXIT trap with $? ALREADY RESET TO 0, so capturing the status in the
# trap is inert — measured. Only positive evidence that the suite reached its own verdict can
# distinguish a real pass from an abort. cch-85b; rules/verification-integrity.md.
completed=0
trap 'st=$?; rm -rf "$tmpdir"; [ "$completed" = 1 ] || st=1; exit $st' EXIT

failures=0

fail() {
  printf 'TRUSTED PR MERGE SELFTEST: FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  [ "$1" = "$2" ] || { fail "expected [$1], got [$2]"; return 1; }
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "missing [$2]"; return 1 ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "unexpected [$2]"; return 1 ;;
    *) ;;
  esac
}

assert_file_absent() {
  [ ! -e "$1" ] || { fail "unexpected file [$1]"; return 1; }
}

assert_file_present() {
  [ -e "$1" ] || { fail "missing file [$1]"; return 1; }
}

mkdir -p "$tmpdir/bin" "$tmpdir/candidate"

cat > "$tmpdir/candidate/gate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$TEST_TMP/gate-ran"
EOF
chmod +x "$tmpdir/candidate/gate"

cat > "$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >> "$TEST_TMP/gh-argv"
arguments=" $* "
if [[ "$arguments" == */pulls/*/files* ]]; then
  # The REST files endpoint, answered from RECORDED payload pages. The wrapper's own --jq filter is
  # applied here, once per page, exactly as `gh --paginate --jq` does — so the filter expression and
  # the page slurp on the wrapper's side are under test, not stubbed out.
  [ "${TEST_REST_FAIL:-0}" = 1 ] && exit 1
  filter=''
  previous_arg=''
  for argument in "$@"; do
    [ "$previous_arg" = --jq ] && filter=$argument
    previous_arg=$argument
  done
  [ -n "$filter" ] || { printf 'gh stub: no --jq filter given\n' >&2; exit 91; }
  for page in ${TEST_REST_PAGES:-}; do
    jq -c "$filter" "$page" || exit 90
  done
  exit 0
fi
if [[ "$arguments" == *mergePullRequest* ]]; then
  : > "$TEST_TMP/merge-called"
  printf '%s\n' '{"data":{"mergePullRequest":{"pullRequest":{"merged":true,"mergeCommit":{"oid":"merge-sha"}}}}}'
  exit 0
fi

count_file="$TEST_TMP/metadata-count"
count=0
[ -f "$count_file" ] && count=$(<"$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"

head='head-sha-1'
labels='[]'
author_login='external-user'
association='CONTRIBUTOR'
path='src/ordinary.sh'
body=''
title='fix(example): an ordinary title'
change_type='MODIFIED'

valid_ack='REVIEW ACK: rounds=2 verdict=GO open_blockers=0 classes=3'

case "${TEST_SCENARIO:?}" in
  external_high_risk)
    path='.github/workflows/release.yml'
    ;;
  external_repository_settings)
    path='.github/repository-settings.yml'
    ;;
  external_merge_policy)
    path='.merge-policy.yml'
    ;;
  ordinary_unlabelled)
    ;;
  later_human_hold)
    if [ "$count" -ge 2 ]; then labels='[{"name":"human/hold"}]'; fi
    ;;
  changed_head)
    if [ "$count" -ge 2 ]; then head='head-sha-2'; fi
    ;;
  stale_checkout)
    ;;
  unknown_author)
    author_login=''
    association=''
    ;;
  internal_rules_no_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    ;;
  internal_rules_with_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '%s\n\n%s\n' 'Body text above the acknowledgement.' "$valid_ack")
    ;;
  internal_rules_bad_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body='REVIEW ACK: rounds=2 verdict=GO open_blockers=0'
    ;;
  internal_claude_md_with_ack)
    association='OWNER'; author_login='owner-user'; path='CLAUDE.md'
    body="$valid_ack"
    ;;
  internal_ordinary_no_ack)
    association='OWNER'; author_login='owner-user'
    ;;
  internal_script_no_ack)
    association='OWNER'; author_login='owner-user'; path='scripts/review-ack-check.sh'
    ;;
  internal_hook_no_ack)
    association='OWNER'; author_login='owner-user'; path='hooks/selftest.sh'
    ;;
  internal_global_claude_md_no_ack)
    association='OWNER'; author_login='owner-user'; path='global/CLAUDE.md'
    ;;
  internal_installer_no_ack)
    association='OWNER'; author_login='owner-user'; path='install.sh'
    ;;
  external_script)
    path='scripts/verify.sh'
    ;;
  internal_tilde_fenced_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '%s\n' 'Documenting the format:' '~~~' "$valid_ack" '~~~' 'No review was run.')
    ;;
  internal_nested_fence_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '%s\n' 'Showing the fence itself:' '````' '```' "$valid_ack" '```' '````')
    ;;
  internal_template_no_ack)
    association='OWNER'; author_login='owner-user'; path='templates/review-fix-round.md'
    ;;
  internal_codex_role_no_ack)
    association='OWNER'; author_login='owner-user'; path='codex/agents/harness_reviewer.toml'
    ;;
  internal_fenced_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '%s\n' 'Documenting the format:' '```' "$valid_ack" '```' 'No review was run.')
    ;;
  internal_quoted_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '> %s\n' "$valid_ack")
    ;;
  internal_template_then_ack)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    body=$(printf '%s\n' 'REVIEW ACK: rounds=<n> verdict=<GO|NO-GO> open_blockers=<n> classes=<list>' '' "$valid_ack")
    ;;
  rename_out_of_scripts)
    association='OWNER'; author_login='owner-user'
    path='docs/reference/moved-helper.sh'; change_type='RENAMED'
    ;;
  rename_within_ordinary)
    association='OWNER'; author_login='owner-user'
    path='src/new-name.txt'; change_type='RENAMED'
    ;;
  denied_name_in_title)
    association='OWNER'; author_login='owner-user'
    title='fix(zzdeniedname): tighten the loop'
    ;;
  denied_name_in_body)
    association='OWNER'; author_login='owner-user'
    body='Raised while working on zzdeniedname last week.'
    ;;
  clean_title_and_body)
    association='OWNER'; author_login='owner-user'
    ;;
  ack_removed_after_gate)
    association='OWNER'; author_login='owner-user'; path='rules/some-rule.md'
    if [ "$count" -lt 2 ]; then body="$valid_ack"; fi
    ;;
  *)
    printf 'unknown TEST_SCENARIO: %s\n' "$TEST_SCENARIO" >&2
    exit 92
    ;;
esac

body_json=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
title_json=$(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
printf '{"data":{"repository":{"pullRequest":{"id":"PR_node_id","headRefOid":"%s","title":%s,"body":%s,"author":{"login":"%s"},"authorAssociation":"%s","labels":{"nodes":%s,"pageInfo":{"hasNextPage":false}},"files":{"nodes":[{"path":"%s","changeType":"%s"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' \
  "$head" "$title_json" "$body_json" "$author_login" "$association" "$labels" "$path" "$change_type"
EOF
chmod +x "$tmpdir/bin/gh"

cat > "$tmpdir/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 5 ] && [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = --verify ] && [ "$5" = 'HEAD^{commit}' ]; then
  printf '%s\n' "${TEST_LOCAL_HEAD:?}"
  exit 0
fi
printf 'unexpected git invocation: %s\n' "$*" >&2
exit 93
EOF
chmod +x "$tmpdir/bin/git"

run_wrapper() {
  local scenario=$1
  shift
  rm -f "$tmpdir/gate-ran" "$tmpdir/merge-called" "$tmpdir/metadata-count" "$tmpdir/gh-argv"
  local local_head='head-sha-1'
  if [ "$scenario" = stale_checkout ]; then local_head='local-stale-sha'; fi
  set +e
  TEST_TMP="$tmpdir" TEST_SCENARIO="$scenario" TEST_LOCAL_HEAD="$local_head" \
    TEST_REST_PAGES="${TEST_REST_PAGES:-}" TEST_REST_FAIL="${TEST_REST_FAIL:-0}" PATH="$tmpdir/bin:$PATH" \
    bash "${WRAPPER_UNDER_TEST:-$wrapper}" --repo octo/example --pr 42 --checkout "$tmpdir/candidate" --gate gate "$@" \
    > "$tmpdir/stdout" 2> "$tmpdir/stderr"
  run_status=$?
  set -e
  run_stdout=$(<"$tmpdir/stdout")
  run_stderr=$(<"$tmpdir/stderr")
  if [ "${DEBUG_TRUSTED_PR_MERGE_SELFTEST:-}" = 1 ]; then
    printf '%s\n' "--- $scenario status=$run_status stderr ---" >&2
    printf '%s\n' "$run_stderr" >&2
  fi
}

run_wrapper external_high_risk
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=external-high-risk-path' || true
assert_file_absent "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true
assert_eq 1 "$(<"$tmpdir/metadata-count")" || true

run_wrapper external_repository_settings
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=external-high-risk-path' || true
assert_file_absent "$tmpdir/gate-ran" || true

run_wrapper external_merge_policy
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=external-high-risk-path' || true
assert_file_absent "$tmpdir/gate-ran" || true

run_wrapper ordinary_unlabelled
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: AGENT_AUTO reason=ordinary-pr' || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: DRY_RUN verified-head=head-sha-1' || true
assert_file_present "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true
assert_eq 2 "$(<"$tmpdir/metadata-count")" || true
assert_not_contains "$(<"$tmpdir/gh-argv")" 'after=' || true

run_wrapper stale_checkout
assert_eq 22 "$run_status" || true
assert_contains "$run_stderr" 'candidate checkout HEAD does not match PR head: local-stale-sha != head-sha-1' || true
assert_file_absent "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true
assert_eq 1 "$(<"$tmpdir/metadata-count")" || true

run_wrapper later_human_hold
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=human-hold-label' || true
assert_file_present "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true

run_wrapper changed_head
assert_eq 21 "$run_status" || true
assert_contains "$run_stderr" 'head changed after gate: head-sha-1 -> head-sha-2' || true
assert_file_present "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true

run_wrapper ordinary_unlabelled --merge
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: MERGED verified-head=head-sha-1' || true
assert_file_present "$tmpdir/merge-called" || true
assert_contains "$(<"$tmpdir/gh-argv")" 'expectedHeadOid=head-sha-1' || true
assert_contains "$(<"$tmpdir/gh-argv")" 'mergePullRequest' || true

run_wrapper unknown_author
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=unknown-author-metadata' || true
assert_file_absent "$tmpdir/gate-ran" || true


# --- the review acknowledgement (cch-fb5.3) -----------------------------------------------------
# A pull request that changes a check, or the policy behind it, must carry a machine-readable
# acknowledgement that the bounded review ran. The hold lands BEFORE the candidate gate executes,
# so an unreviewed policy change never gets to run its own code.
run_wrapper internal_rules_no_ack
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
assert_contains "$run_stderr" 'REVIEW ACK: rounds=' || true
assert_file_absent "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true

run_wrapper internal_rules_bad_ack
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
assert_file_absent "$tmpdir/gate-ran" || true

run_wrapper internal_rules_with_ack
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: review acknowledgement accepted' || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: DRY_RUN verified-head=head-sha-1' || true
assert_file_present "$tmpdir/gate-ran" || true

run_wrapper internal_claude_md_with_ack
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: review acknowledgement accepted' || true

# A pull request that touches no review-triggering surface is untouched by the requirement.
run_wrapper internal_ordinary_no_ack
assert_eq 0 "$run_status" || true
assert_not_contains "$run_stdout" 'review acknowledgement accepted' || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: DRY_RUN verified-head=head-sha-1' || true

# The acknowledgement is revalidated after the gate: a body edited mid-run must not buy a merge.
run_wrapper ack_removed_after_gate --merge
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
assert_file_present "$tmpdir/gate-ran" || true
assert_file_absent "$tmpdir/merge-called" || true


# The gate must cover the CHECKS, not only the policy that describes them: a pull request that
# guts the acknowledgement checker or removes a selftest from the gate list is exactly the change
# least able to vouch for itself.
for scenario in internal_script_no_ack internal_hook_no_ack internal_global_claude_md_no_ack internal_installer_no_ack; do
  run_wrapper "$scenario"
  assert_eq 20 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
  assert_file_absent "$tmpdir/gate-ran" || true
done

# The same widening must reach the pre-existing external-contributor hold, which shares the filter.
run_wrapper external_script
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=external-high-risk-path' || true
assert_file_absent "$tmpdir/gate-ran" || true

# An acknowledgement that is being ILLUSTRATED is not one that was made.
run_wrapper internal_fenced_ack
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true

run_wrapper internal_quoted_ack
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true

# A template shown above the real acknowledgement must not shadow it.
run_wrapper internal_template_then_ack
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'TRUSTED PR MERGE: review acknowledgement accepted' || true


# Markdown has more than one fence. Each of these is how a human would document the format.
for scenario in internal_tilde_fenced_ack internal_nested_fence_ack; do
  run_wrapper "$scenario"
  assert_eq 20 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
done

# Policy is carried by more than rules/: the fix-round template is routed to by the review rule,
# and the generated Codex roles define the reviewer itself.
for scenario in internal_template_no_ack internal_codex_role_no_ack; do
  run_wrapper "$scenario"
  assert_eq 20 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
done

# The wrapper must refuse to be the candidate it is judging.
rm -f "$tmpdir/gate-ran"
set +e
TEST_TMP="$tmpdir" TEST_SCENARIO=internal_rules_with_ack TEST_LOCAL_HEAD='head-sha-1' PATH="$tmpdir/bin:$PATH" \
  bash "$wrapper" --repo octo/example --pr 42 --checkout "$(dirname -- "$wrapper")/.." --gate gate \
  > "$tmpdir/stdout" 2> "$tmpdir/stderr"
inside_status=$?
set -e
assert_eq 2 "$inside_status" || true
assert_contains "$(<"$tmpdir/stderr")" 'lives inside the candidate checkout' || true
assert_file_absent "$tmpdir/gate-ran" || true

# --- cch-nq9: a rename OUT of a covered directory is high risk, and GraphQL cannot see it -------
# GraphQL's PullRequestChangedFile exposes the new path only (schema introspection 2026-09-16:
# additions, changeType, deletions, path, viewerViewedState), so the wrapper resolves the old side
# from REST. The rows below answer that REST call from recorded payloads and let the wrapper's own
# --jq filter run over them. A check deleted by moving it to docs/ must still demand an ack.
rest_pages="$script_dir/testdata/pr-files-rename-page1.json $script_dir/testdata/pr-files-rename-page2.json"

TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-page1.json" run_wrapper rename_out_of_scripts
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
unset TEST_REST_PAGES

# Two pages: the wrapper slurps every page, so a rename on the SECOND one is classified too.
TEST_REST_PAGES="$rest_pages" run_wrapper rename_out_of_scripts
assert_eq 20 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=missing-review-ack' || true
unset TEST_REST_PAGES

# A rename whose old side is ordinary stays ordinary: the previous path is classified, not assumed.
TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-ordinary.json" run_wrapper rename_within_ordinary
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: AGENT_AUTO reason=ordinary-pr' || true
unset TEST_REST_PAGES

# Fail closed: a rename whose previous path GitHub does not report cannot be classified as safe.
TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-nopath.json" run_wrapper rename_out_of_scripts
assert_eq 2 "$run_status" || true
assert_contains "$run_stderr" 'previous path could not be resolved' || true
assert_file_absent "$tmpdir/gate-ran" || true
unset TEST_REST_PAGES

# Fail closed again: a REST call that errors is not "no renames".
TEST_REST_FAIL=1 TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-page1.json" run_wrapper rename_out_of_scripts
assert_eq 2 "$run_status" || true
assert_contains "$run_stderr" 'could not fetch previous paths' || true
unset TEST_REST_FAIL TEST_REST_PAGES

# A pull request with no rename never calls REST at all.
run_wrapper internal_ordinary_no_ack
assert_eq 0 "$run_status" || true
assert_not_contains "$(<"$tmpdir/gh-argv")" '/files' || true

# Negative control: without the previous-path lookup the same rename merges as an ordinary PR.
mutant_dir="$tmpdir/mutant-scripts"
mkdir -p "$mutant_dir/testdata"
cp "$wrapper" "$mutant_dir/trusted-pr-merge.sh"
cp "$script_dir/review-ack-check.sh" "$script_dir/name-hygiene.sh" "$mutant_dir/"
cp "$script_dir/testdata/name-hashes.txt" "$mutant_dir/testdata/"
perl -0pi -e 's/if \[ "\$renames" -gt 0 \]; then/if false; then/' "$mutant_dir/trusted-pr-merge.sh"
if cmp -s "$mutant_dir/trusted-pr-merge.sh" "$wrapper"; then
  fail 'rename lookup mutation did not apply'
else
  TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-page1.json" \
    WRAPPER_UNDER_TEST="$mutant_dir/trusted-pr-merge.sh" run_wrapper rename_out_of_scripts
  assert_eq 0 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: AGENT_AUTO reason=ordinary-pr' || true
  unset TEST_REST_PAGES WRAPPER_UNDER_TEST
fi

# Negative control on the FILTER itself: the recorded payload names the field, so a wrong field
# name in the wrapper's --jq must red rather than silently yield no previous paths.
cp "$wrapper" "$mutant_dir/filter-mutant.sh"
perl -0pi -e 's/\.previous_filename/.not_a_real_field/g' "$mutant_dir/filter-mutant.sh"
if cmp -s "$mutant_dir/filter-mutant.sh" "$wrapper"; then
  fail 'previous-path filter mutation did not apply'
else
  TEST_REST_PAGES="$script_dir/testdata/pr-files-rename-page1.json" \
    WRAPPER_UNDER_TEST="$mutant_dir/filter-mutant.sh" run_wrapper rename_out_of_scripts
  assert_eq 2 "$run_status" || true
  assert_contains "$run_stderr" 'previous path could not be resolved' || true
  unset TEST_REST_PAGES WRAPPER_UNDER_TEST
fi

# --- cch-31f: a denied name in the title or body is held before the squash publishes it ---------
# The wrapper resolves its helpers and its denylist from its OWN directory, so the control gets a
# trusted copy with a denylist it can predict; nothing here reaches the real private names.
trusted_dir="$tmpdir/trusted-scripts"
mkdir -p "$trusted_dir/testdata"
cp "$wrapper" "$trusted_dir/trusted-pr-merge.sh"
cp "$script_dir/review-ack-check.sh" "$script_dir/name-hygiene.sh" "$trusted_dir/"
printf '%s  # ClearName\n' "$(printf 'zzdeniedname' | shasum -a 256 | awk '{print $1}')" \
  > "$trusted_dir/testdata/name-hashes.txt"

for scenario in denied_name_in_title denied_name_in_body; do
  WRAPPER_UNDER_TEST="$trusted_dir/trusted-pr-merge.sh" run_wrapper "$scenario" --merge
  assert_eq 20 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: HUMAN_HOLD reason=denied-name-in-title-or-body' || true
  assert_contains "$run_stderr" "denied token 'zzdeniedname'" || true
  assert_file_absent "$tmpdir/merge-called" || true
done
unset WRAPPER_UNDER_TEST

# Positive control: the same trusted copy merges a clean title and body, so the rows above fail for
# the denied token and not because the copy is broken.
WRAPPER_UNDER_TEST="$trusted_dir/trusted-pr-merge.sh" run_wrapper clean_title_and_body
assert_eq 0 "$run_status" || true
assert_contains "$run_stdout" 'DISPOSITION: AGENT_AUTO reason=ordinary-pr' || true
unset WRAPPER_UNDER_TEST

# Negative control: without the scan, the denied title merges.
cp "$trusted_dir/trusted-pr-merge.sh" "$trusted_dir/mutant.sh"
perl -0pi -e 's/^enforce_name_hygiene "\$first_pr"\n//m; s/^enforce_name_hygiene "\$revalidated_pr"\n//m' \
  "$trusted_dir/mutant.sh"
if cmp -s "$trusted_dir/mutant.sh" "$trusted_dir/trusted-pr-merge.sh"; then
  fail 'name-hygiene mutation did not apply'
else
  WRAPPER_UNDER_TEST="$trusted_dir/mutant.sh" run_wrapper denied_name_in_title
  assert_eq 0 "$run_status" || true
  assert_contains "$run_stdout" 'DISPOSITION: AGENT_AUTO reason=ordinary-pr' || true
  unset WRAPPER_UNDER_TEST
fi

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'TRUSTED PR MERGE SELFTEST: PASS'
  completed=1; completed=1; exit 0
fi
printf '%s\n' 'TRUSTED PR MERGE SELFTEST: FAIL' >&2
completed=1; completed=1; exit 1
