#!/usr/bin/env bash
# Hermetic selftest for trusted-pr-merge.sh; it never contacts GitHub or merges a PR.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wrapper="$script_dir/trusted-pr-merge.sh"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/trusted-pr-merge-selftest.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT

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
  *)
    printf 'unknown TEST_SCENARIO: %s\n' "$TEST_SCENARIO" >&2
    exit 92
    ;;
esac

printf '{"data":{"repository":{"pullRequest":{"id":"PR_node_id","headRefOid":"%s","author":{"login":"%s"},"authorAssociation":"%s","labels":{"nodes":%s,"pageInfo":{"hasNextPage":false}},"files":{"nodes":[{"path":"%s"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' \
  "$head" "$author_login" "$association" "$labels" "$path"
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
  TEST_TMP="$tmpdir" TEST_SCENARIO="$scenario" TEST_LOCAL_HEAD="$local_head" PATH="$tmpdir/bin:$PATH" \
    bash "$wrapper" --repo octo/example --pr 42 --checkout "$tmpdir/candidate" --gate gate "$@" \
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

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'TRUSTED PR MERGE SELFTEST: PASS'
  exit 0
fi
printf '%s\n' 'TRUSTED PR MERGE SELFTEST: FAIL' >&2
exit 1
