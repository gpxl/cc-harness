#!/usr/bin/env bash
# Selftest for scripts/verify.sh — the gate's entry point must itself be falsifiable.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
verify=$root/scripts/verify.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cc-harness-verify-selftest.XXXXXX") || exit 1
# The mutant lives beside the real script, not under $tmp: a copy elsewhere resolves its own $root
# to that directory, so every relative selftest path goes missing and the mutant exits 1 for a
# reason that has nothing to do with the guard under test.
mutant=$root/scripts/.verify-mutant.sh
trap 'rm -rf "$tmp"; rm -f "$mutant"' EXIT HUP INT TERM
failures=0

# Row 7 runs a mutant of verify.sh whose guard is supposed to BLOCK. A mutant that only warned
# would go on to run the whole gate list, which includes THIS script, whose copy would build its own
# mutant — unbounded. The marker makes such a nested run exit immediately. It exits 1, not 0, so a
# marker left set in the ambient environment fails the gate loudly instead of quietly skipping it.
if [ -n "${CC_HARNESS_VERIFY_SELFTEST_NESTED:-}" ]; then
  printf '%s\n' 'VERIFY SELFTEST RESULT: FAIL (nested run — CC_HARNESS_VERIFY_SELFTEST_NESTED is set)'
  exit 1
fi

pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

# 1. Zero resolved selftests must FAIL, never PASS(0).
out=$(CC_HARNESS_SELFTESTS=" " CC_HARNESS_VERIFY_LOG_DIR="$tmp/l1" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'no selftests resolved'; then
  pass 'empty list fails'
else
  fail 'empty list fails' "rc=$rc out=$out"
fi

# 2. The reported per-test exit code is the real one (negative control: exit 3 must print "exit 3").
mkdir -p "$tmp/fake"
printf '#!/usr/bin/env bash\nexit 3\n' > "$tmp/fake/exit3-selftest.sh"
out=$(CC_HARNESS_SELFTESTS="$tmp/fake/exit3-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l2" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'exit3-selftest: FAIL (exit 3)'; then
  pass 'real exit code reported'
else
  fail 'real exit code reported' "rc=$rc out=$out"
fi

# 3. Positive control: one passing selftest → PASS (1 selftests), exit 0.
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/fake/ok-selftest.sh"
out=$(CC_HARNESS_SELFTESTS="$tmp/fake/ok-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l3" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq 'CC-HARNESS VERIFY: PASS (1 selftests)'; then
  pass 'single passing selftest passes'
else
  fail 'single passing selftest passes' "rc=$rc out=$out"
fi

# 4. A missing selftest file is a FAIL, not a skip.
out=$(CC_HARNESS_SELFTESTS="scripts/does-not-exist-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l4" bash "$verify" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -Fq 'does-not-exist-selftest: FAIL'; then
  pass 'missing selftest fails'
else
  fail 'missing selftest fails' "rc=$rc out=$out"
fi

# 5. verify.sh's default list equals the list under CLAUDE.md "### The gate" — no silent drift.
# Parsed structurally, from the section's BULLETS only. The old parse read every backticked
# `*.sh` between "### The gate" and a "Merge only" line that is mid-paragraph, so it never
# terminated (correct only while The gate is the last section) and it counted prose mentions —
# rewording `bash scripts/verify.sh` to a bare path would have false-reddened the gate (cch-x1q
# items G and H).
# Fail-closed by construction: a spelling this misses (a ~~~ fence, a setext heading, a bolded
# path, an unclosed fence) yields a list that DIFFERS from verify.sh's, so the comparison below
# reds. None of them can drop an entry and still compare equal, which is the only failure that
# would matter.
gate_list() {  # gate_list <claude-md> -> one selftest path per line, from the section's bullets
  awk '
    /^```/          { fenced = !fenced; next }
    fenced          { next }
    /^### The gate/ { inside = 1; next }
    inside && /^#+[[:space:]]/ { exit }
    inside && /^[[:space:]]*[-*][[:space:]]+`[^`]+\.sh`[[:space:]]*$/ {
      line = $0
      sub(/^[^`]*`/, "", line)
      sub(/`.*$/, "", line)
      print line
    }
  ' "$1"
}

listed=$(gate_list "$root/CLAUDE.md" | sort)
defaults=$(bash "$verify" --list | sort)
if [ -n "$listed" ] && [ "$listed" = "$defaults" ]; then
  pass 'default list matches CLAUDE.md gate list'
else
  fail 'default list matches CLAUDE.md gate list' "CLAUDE.md: $(printf '%s' "$listed" | tr '\n' ' ') | verify.sh: $(printf '%s' "$defaults" | tr '\n' ' ')"
fi

# 6. The parse reads the section's bullets and nothing else: prose mentions, a fenced block whose
# contents look like headings, a bullet carrying trailing prose, and a later section's bullets are
# all invisible to it; ordinary Markdown bullet spellings are not.
cat > "$tmp/claude-fixture.md" <<'FIXTURE'
### The gate

Prose that names scripts/prose-only-selftest.sh and `scripts/also-prose-selftest.sh` inline.

```bash
# scripts/fenced-selftest.sh — a comment whose line starts with a hash
```

- `hooks/selftest.sh`
*  `scripts/star-selftest.sh`
  - `scripts/indented-selftest.sh`
- `install.sh` is described here rather than listed
- `scripts/verify-selftest.sh`

Merge only when every listed selftest reports PASS at the PR's HEAD.

### A later section

- `scripts/not-the-gate-selftest.sh`
FIXTURE
parsed=$(gate_list "$tmp/claude-fixture.md")
if [ "$parsed" = "$(printf '%s\n' 'hooks/selftest.sh' 'scripts/star-selftest.sh' \
  'scripts/indented-selftest.sh' 'scripts/verify-selftest.sh')" ]; then
  pass 'gate-list parse reads bullets only, and stops at the next section'
else
  fail 'gate-list parse reads bullets only, and stops at the next section' "parsed=$(printf '%s' "$parsed" | tr '\n' ' ')"
fi

# 7. The gate's length is pinned to a literal, so a selftest dropped from the default list fails the
# gate instead of shrinking a green. Negative control: a copy with its FIRST entry removed must FAIL
# before it runs anything. Both counts are derived, never written down — a hardcoded 17 here would
# red this row on the next correct addition, pointing at the wrong file.
# --list is handled before verify.sh reads CC_HARNESS_SELFTESTS, so it always prints the default
# list; no override pin is needed here (the one on the run below is what matters).
expected_count=$(bash "$verify" --list | wc -l | tr -d ' ')
sed 's/^default_tests="[^ ]* /default_tests="/' "$verify" > "$mutant"
if cmp -s "$mutant" "$verify"; then
  fail 'dropping a selftest from the default list fails the gate' 'the mutation did not apply'
elif [ "$(bash "$mutant" --list | wc -l | tr -d ' ')" -ne "$((expected_count - 1))" ]; then
  fail 'dropping a selftest from the default list fails the gate' 'the mutation did not drop exactly one entry'
else
  # The override is pinned empty, not inherited: an ambient CC_HARNESS_SELFTESTS would skip the
  # guard this row is named after and fail it for an unrelated reason.
  out=$(CC_HARNESS_SELFTESTS= CC_HARNESS_VERIFY_SELFTEST_NESTED=1 CC_HARNESS_VERIFY_LOG_DIR="$tmp/l7" \
    bash "$mutant" 2>&1); rc=$?
  # The guard must BLOCK, not merely warn: a mutant that printed the message and carried on would
  # have run the shortened list, so require that no per-test result line was emitted at all.
  ran=$(printf '%s\n' "$out" | grep -cE '^[A-Za-z0-9_.-]+: (PASS|FAIL)' || true)
  if [ "$rc" -eq 1 ] && [ "$ran" -eq 0 ] && printf '%s' "$out" \
    | grep -Fq "the default gate list holds $((expected_count - 1)) selftests, expected $expected_count"; then
    pass 'dropping a selftest from the default list fails the gate'
  else
    fail 'dropping a selftest from the default list fails the gate' "rc=$rc ran=$ran out=$out"
  fi
fi

# 8. Selftests actually run concurrently, and each name is attributed its OWN exit status — not
# the first-launched PID's. Three fake selftests each sleep 1s and exit with distinct codes.
# Negative control (not run, to stay read-only about the real script): swapping
# `wait "${pids[idx]}"` for `wait "${pids[1]}"` would make conc-b/conc-c both report conc-a's
# exit 0; running `wait` immediately after each launch (serializing them) would still pass every
# PASS/FAIL assertion below while missing the elapsed-time bound — which is why both an identity
# check and a timing check are required together.
mkdir -p "$tmp/concurrent"
printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$tmp/concurrent/conc-a-selftest.sh"
printf '#!/usr/bin/env bash\nsleep 1\nexit 4\n' > "$tmp/concurrent/conc-b-selftest.sh"
printf '#!/usr/bin/env bash\nsleep 1\nexit 7\n' > "$tmp/concurrent/conc-c-selftest.sh"
start=$(date +%s)
out=$(CC_HARNESS_SELFTESTS="$tmp/concurrent/conc-a-selftest.sh $tmp/concurrent/conc-b-selftest.sh $tmp/concurrent/conc-c-selftest.sh" \
  CC_HARNESS_VERIFY_LOG_DIR="$tmp/l8" bash "$verify" 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
# Sequential would take >=3s; concurrent finishes in ~1s. 2s is a wide, non-flaky cutoff between them.
if [ "$rc" -eq 1 ] && [ "$elapsed" -le 2 ] \
  && printf '%s' "$out" | grep -Fq 'conc-a-selftest: PASS' \
  && printf '%s' "$out" | grep -Fq 'conc-b-selftest: FAIL (exit 4)' \
  && printf '%s' "$out" | grep -Fq 'conc-c-selftest: FAIL (exit 7)'; then
  pass 'concurrent selftests report their own exit status and overlap in wall time'
else
  fail 'concurrent selftests report their own exit status and overlap in wall time' "rc=$rc elapsed=${elapsed}s out=$out"
fi

# 9. Cancellation must not leak: a selftest that itself backgrounds a child must not outlive a
# TERM'd gate. Reproduces a real bug found in Stage 2 round 1 review: `kill "$pid"` (the round-0
# fix) signals only the gate's direct `bash "$path"` child, not anything that child backgrounds —
# confirmed by hand with a real `sleep 30 &` grandchild that survived a TERM'd gate under the
# round-0 code. `kill -TERM -- "-$pid"` (negated pid, signals the whole process GROUP, which
# `set -m` gives each backgrounded job even in this non-interactive script) is what actually fixes
# it, confirmed the same way.
mkdir -p "$tmp/cancel"
grandchild_marker="$tmp/cancel/grandchild.pid"
rm -f "$grandchild_marker"
cat > "$tmp/cancel/leaky-selftest.sh" <<LEAKY
#!/usr/bin/env bash
sleep 30 &
echo \$! > "$grandchild_marker"
sleep 30
LEAKY
chmod +x "$tmp/cancel/leaky-selftest.sh"
CC_HARNESS_SELFTESTS="$tmp/cancel/leaky-selftest.sh" CC_HARNESS_VERIFY_LOG_DIR="$tmp/l9" \
  bash "$verify" >"$tmp/l9.out" 2>&1 &
gate_pid=$!
sleep 1
grandchild_pid=$(cat "$grandchild_marker" 2>/dev/null || true)
if [ -z "$grandchild_pid" ]; then
  fail 'cancellation kills a selftest and everything it backgrounds' 'grandchild never started — cannot exercise the guard'
  kill -9 "$gate_pid" 2>/dev/null
else
  kill -TERM "$gate_pid" 2>/dev/null
  sleep 1
  if kill -0 "$grandchild_pid" 2>/dev/null; then
    fail 'cancellation kills a selftest and everything it backgrounds' "grandchild pid $grandchild_pid still alive after the gate was TERM'd"
    kill -9 "$grandchild_pid" 2>/dev/null
  else
    pass 'cancellation kills a selftest and everything it backgrounds'
  fi
fi
wait "$gate_pid" 2>/dev/null

if [ "$failures" -eq 0 ]; then
  printf '%s\n' 'VERIFY SELFTEST RESULT: PASS'
  exit 0
fi
printf '%s\n' 'VERIFY SELFTEST RESULT: FAIL'
exit 1
