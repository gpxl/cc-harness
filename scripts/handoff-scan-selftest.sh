#!/usr/bin/env bash
# Hermetic selftest for handoff-scan.sh. Builds throwaway delivery repos in $TMPDIR, plants one
# leak per surface, and requires the scan to go red on each and green on the clean control. It
# never contacts GitHub (--no-github throughout) and never reads a real delivery.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/handoff-scan.sh"
completed=0
workdir=''
trap 'status=$?; [ "$completed" = 1 ] || status=1; [ -z "$workdir" ] || rm -rf "$workdir"; exit "$status"' EXIT HUP INT TERM

failures=0
pass() { printf '%s: PASS\n' "$1"; }
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

workdir=$(mktemp -d "${TMPDIR:-/tmp}/handoff-scan-selftest.XXXXXX") || exit 1
export HANDOFF_REGISTRY="$workdir/registry.conf"   # hermetic: never the real private registry
export HANDOFF_SCAN_HOOK_SCANNER="$tool"           # the installed hook runs the copy under test
: > "$HANDOFF_REGISTRY"

# A private denylist the test can predict: one "other client" and one "owning client".
denylist="$workdir/name-hashes.txt"
{
  printf '%s  # OtherClient (client name)\n' "$(printf 'zzotherclient' | shasum -a 256 | awk '{print $1}')"
  printf '%s  # OwnClient (client name)\n' "$(printf 'zzownclient' | shasum -a 256 | awk '{print $1}')"
} > "$denylist"

run() {  # run <name> <want-rc> <needle-or-empty> <args...>
  local name=$1 want=$2 needle=$3; shift 3
  local out rc
  out=$(bash "$tool" --denylist "$denylist" "$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail "$name" "rc=$rc (want $want) output=$out"
  elif [ -n "$needle" ] && ! printf '%s' "$out" | grep -Fq -- "$needle"; then
    fail "$name" "missing '$needle' in: $out"
  else
    pass "$name"
  fi
}

make_repo() {
  local dir=$1
  mkdir -p "$dir" && git -C "$dir" init --quiet -b main 2>/dev/null || return 1
  git -C "$dir" config user.email selftest@example.invalid
  git -C "$dir" config user.name 'Selftest'
  printf '%s\n' '# Design kit' 'Built for zzownclient. Contact support@example.com.' > "$dir/README.md"
  git -C "$dir" add -A >/dev/null 2>&1 && git -C "$dir" commit --quiet -m 'Add the design kit' >/dev/null 2>&1
}

commit_file() {  # commit_file <repo> <path> <message> < content
  mkdir -p "$(dirname "$1/$2")" && cat > "$1/$2" && git -C "$1" add -A >/dev/null 2>&1 &&
    git -C "$1" commit --quiet -m "$3" >/dev/null 2>&1
}

# --- the clean control: a green that the planted rows below must turn red -------------------
clean="$workdir/clean"
make_repo "$clean" || { printf 'HANDOFF SCAN SELFTEST: FAIL (could not build fixture)\n'; completed=1; exit 1; }
run 'clean delivery passes (own client name allowed)' 0 'HANDOFF SCAN: PASS' "$clean" --no-github --client OwnClient
run 'own client name without --client is denied' 1 "denied token 'zzownclient'" "$clean" --no-github

# --- one planted leak per surface ------------------------------------------------------------
plant() {  # plant <name> -> a fresh copy of the clean repo at $workdir/<name>
  rm -rf "${workdir:?}/$1" && git clone --quiet "$clean" "$workdir/$1" 2>/dev/null &&
    git -C "$workdir/$1" config user.email selftest@example.invalid && git -C "$workdir/$1" config user.name 'Selftest'
}

plant stamp_on_side_branch
git -C "$workdir/stamp_on_side_branch" checkout --quiet -b feat/other
printf '%s\n' 'Notes.' "$(printf 'REVIEW %s: rounds=1 verdict=GO' 'ACK')" |
  commit_file "$workdir/stamp_on_side_branch" notes.md 'Add notes'
git -C "$workdir/stamp_on_side_branch" checkout --quiet main
run 'review stamp on a non-default branch is found' 1 'feat/other:notes.md' \
  "$workdir/stamp_on_side_branch" --no-github --client OwnClient

plant stamp_in_message
printf 'x\n' | commit_file "$workdir/stamp_in_message" x.txt "$(printf 'Fix layout\n\nmutation-%s against the comps' 'checked')"
run 'stamp in a commit message is found' 1 "[stamp] 'mutation-checked'" "$workdir/stamp_in_message" --no-github --client OwnClient

plant vendor_trailer
printf 'y\n' | commit_file "$workdir/vendor_trailer" y.txt "$(printf 'Fix spacing\n\nCo-Authored-By: %s <noreply@%s.com>' 'Claude' 'anthropic')"
run 'vendor attribution trailer is found' 1 '[attribution]' "$workdir/vendor_trailer" --no-github --client OwnClient

plant other_client
printf 'Also used on zzOtherClient-site.\n' | commit_file "$workdir/other_client" docs/usage.md 'Add usage'
run "another client's name is denied (hashed, any case, in a compound)" 1 "denied token 'zzOtherClient-site'" \
  "$workdir/other_client" --no-github --client OwnClient

plant tracker_and_harness
printf '%s\n' 'Run bd close when done.' 'Delegated via codex.' | commit_file "$workdir/tracker_and_harness" HOWTO.md 'Add how-to'
run 'tracker command is found' 1 "[tracker] 'bd close'" "$workdir/tracker_and_harness" --no-github --client OwnClient
run 'harness vocabulary is found' 1 "[harness] 'codex'" "$workdir/tracker_and_harness" --no-github --client OwnClient

plant rule_name
printf 'See verification-integrity.md for why.\n' | commit_file "$workdir/rule_name" WHY.md 'Add why'
run 'one of our rule file names is found' 1 "verification-integrity.md" "$workdir/rule_name" --no-github --client OwnClient

plant personal
printf '%s\n' 'Export from /Users/someone/projects/kit.' 'Mail ops@realdomain.io for access.' |
  commit_file "$workdir/personal" docs/export.md 'Add export notes'
run 'personal path is found' 1 "[personal] '/Users/someone/'" "$workdir/personal" --no-github --client OwnClient
run 'non-allowed email domain is found' 1 "[email] 'ops@realdomain.io'" "$workdir/personal" --no-github --client OwnClient
run 'an allowed client domain passes the email check' 1 '' "$workdir/personal" --no-github --client OwnClient --allow-domain realdomain.io
out=$(bash "$tool" --denylist "$denylist" "$workdir/personal" --no-github --client OwnClient --allow-domain realdomain.io 2>&1)
case "$out" in *'[email]'*) fail 'allow-domain suppresses only that domain' "$out" ;; *) pass 'allow-domain suppresses only that domain' ;; esac

plant commercial_and_secret
printf '%s\n' 'Our day rate is in the invoice.' "Tag manager: $(printf 'GTM-%s' 'ABC1234')" |
  commit_file "$workdir/commercial_and_secret" ops.md 'Add ops'
run 'commercial terms are found' 1 "[commercial] 'day rate'" "$workdir/commercial_and_secret" --no-github --client OwnClient
run 'a tag manager id is found' 1 "[secret] 'GTM-ABC1234'" "$workdir/commercial_and_secret" --no-github --client OwnClient

# Binary bundles: a .fig (zip -> canvas.fig fig-kiwi, one zstd chunk and one deflate chunk) and
# a PNG whose zTXt chunk carries a render tool's source path.
plant binaries
python3 - "$workdir/binaries" <<'PY' || fail 'build binary fixtures' 'python helper failed'
import io, os, struct, subprocess, sys, zipfile, zlib
root = sys.argv[1]
def zstd(b):
    return subprocess.run(["zstd", "-q", "-c"], input=b, capture_output=True, check=True).stdout
schema = zstd(b"\x00schema\x00" + b"cc-" + b"harness generated this canvas\x00")
deflater = zlib.compressobj(9, zlib.DEFLATED, -15)
data = deflater.compress(b"\x01node\x00Frame 1\x00") + deflater.flush()
canvas = b"fig-kiwi" + struct.pack("<I", 15)
for chunk in (schema, data):
    canvas += struct.pack("<I", len(chunk)) + chunk
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("canvas.fig", canvas)
    zf.writestr("meta.json", '{"file_name":"kit"}')
os.makedirs(os.path.join(root, "figma"), exist_ok=True)
open(os.path.join(root, "figma", "kit.fig"), "wb").write(buf.getvalue())
def chunk(t, body):
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
png += chunk(b"zTXt", b"Source\x00\x00" + zlib.compress(b"/home/renderer/scene.blend"))
png += chunk(b"IDAT", zlib.compress(b"\x00\x00")) + chunk(b"IEND", b"")
open(os.path.join(root, "art.png"), "wb").write(png)
PY
git -C "$workdir/binaries" add -A >/dev/null 2>&1 && git -C "$workdir/binaries" commit --quiet -m 'Add art' >/dev/null 2>&1
run 'harness text inside a zstd fig-kiwi chunk of a .fig is found' 1 'kit.fig@' "$workdir/binaries" --no-github --client OwnClient
run 'the fig hit names the decoded chunk' 1 "canvas.fig#chunk0.strings:" "$workdir/binaries" --no-github --client OwnClient
run 'a path in a compressed PNG text chunk is found' 1 "art.png@" "$workdir/binaries" --no-github --client OwnClient

# Fail closed: a .fig whose chunk is truncated cannot be reported clean.
plant broken_fig
python3 - "$workdir/broken_fig" <<'PY'
import io, os, struct, sys, zipfile
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("canvas.fig", b"fig-kiwi" + struct.pack("<I", 15) + struct.pack("<I", 999) + b"short")
open(os.path.join(sys.argv[1], "broken.fig"), "wb").write(buf.getvalue())
PY
git -C "$workdir/broken_fig" add -A >/dev/null 2>&1 && git -C "$workdir/broken_fig" commit --quiet -m 'Add a fig' >/dev/null 2>&1
run 'an undecodable .fig is INCOMPLETE, not clean' 2 'INCOMPLETE' "$workdir/broken_fig" --no-github --client OwnClient

# History: a leak deleted on main is invisible at the tips and found with --history.
plant deleted_leak
printf 'see the scratchpad\n' | commit_file "$workdir/deleted_leak" tmp.md 'Add tmp'
git -C "$workdir/deleted_leak" rm --quiet tmp.md && git -C "$workdir/deleted_leak" commit --quiet -m 'Remove tmp' >/dev/null 2>&1
run 'tips-only scan does not see a deleted file' 0 '' "$workdir/deleted_leak" --no-github --client OwnClient
run '--history finds the deleted file' 1 "[personal] 'scratchpad'" "$workdir/deleted_leak" --no-github --history --client OwnClient

# --- text mode: a PR body checked before it is written -------------------------------------
printf '%s\n' '## What' 'Adds the deck builder.' > "$workdir/body-clean.md"
printf '%s\n' '## What' 'Adds the deck builder.' "$(printf 'REVIEW %s: rounds=1 verdict=GO open_blockers=0 classes=3 reviewer=anthropic' 'ACK')" > "$workdir/body-stamp.md"
run 'a clean PR body passes text mode' 0 'HANDOFF SCAN: PASS' --text-file "$workdir/body-clean.md" --client OwnClient
run 'a stamped PR body fails text mode' 1 "pull-request body:3: [stamp]" --text-file "$workdir/body-stamp.md" --label 'pull-request body' --client OwnClient
run 'a missing text input is an error, not clean' 2 '' --text-file "$workdir/nope.md"

# --- the registry and the shared predicate -------------------------------------------------
printf '%s\n' '# owner/repo client=… allow-domain=…' 'octo/kit client=OwnClient allow-domain=realdomain.io' > "$HANDOFF_REGISTRY"
run 'registered repo is a client deliverable' 0 '' --is-client --repo octo/kit
run 'registry match ignores case' 0 '' --is-client --repo Octo/Kit
run 'unregistered repo is not' 1 '' --is-client --repo octo/other
git -C "$workdir/personal" remote set-url origin https://github.com/octo/kit.git
run 'a clone whose origin is registered is a client deliverable' 0 '' --is-client --dir "$workdir/personal"
run 'the registry supplies client and allow-domain defaults' 0 '' "$workdir/clean" --no-github --repo octo/kit
printf '%s\n' 'Built for zzownclient.' > "$workdir/body-own.md"
run 'text mode takes registry defaults from a clone via --dir' 0 'own name allowed: OwnClient' --text-file "$workdir/body-own.md" --dir "$workdir/personal"
run 'text mode without --dir denies the own name' 1 "denied token 'zzownclient'" --text-file "$workdir/body-own.md"
out=$(bash "$tool" --denylist "$denylist" "$workdir/personal" --no-github 2>&1)
case "$out" in *'[email]'*) fail 'registry allow-domain applies to a registered clone' "$out" ;; *) pass 'registry allow-domain applies to a registered clone' ;; esac
make_repo "$workdir/configured" || exit 1
printf '%s\n' '## Agent Config' '' '| Key | Value |' '|-----|-------|' '| deliverable | client |' > "$workdir/configured/CLAUDE.md"
run "an unregistered repo whose Agent Config says client must be registered" 2 'not in the client registry' --is-client --dir "$workdir/configured"
run 'an ordinary repo is not' 1 '' --is-client --dir "$clean"

# --- the pre-push guard: a negative control on the guard itself ----------------------------
guarded="$workdir/guarded"
git init --quiet --bare "$workdir/remote.git"
git clone --quiet "$workdir/remote.git" "$guarded" 2>/dev/null
git -C "$guarded" config user.email selftest@example.invalid && git -C "$guarded" config user.name 'Selftest'
printf 'kit\n' | commit_file "$guarded" README.md 'Add kit'
run 'install the pre-push guard' 0 'pre-push guard installed' --install-hook "$guarded"
if git -C "$guarded" push --quiet origin main >/dev/null 2>&1; then pass 'a clean push goes through'; else fail 'a clean push goes through' 'push refused'; fi
printf '%s\n' "$(printf 'VERIFY %s: PASS sha=abc1234 tree=def5678' 'RESULT')" | commit_file "$guarded" STATUS.md 'Add status'
if git -C "$guarded" push --quiet origin main >/dev/null 2>&1; then
  fail 'a stamped push is blocked' 'push went through'
else
  pass 'a stamped push is blocked'
fi
printf '#!/bin/sh\nexit 0\n' > "$workdir/foreign-hook"
cp "$workdir/foreign-hook" "$(git -C "$clean" rev-parse --path-format=absolute --git-path hooks)/pre-push"
run 'a foreign pre-push hook is never overwritten' 2 'is not this guard' --install-hook "$clean"

# --- review round 0 fixes ----------------------------------------------------------------------
# An annotated tag is a tag OBJECT in `rev-list --objects --all`: it must not read as INCOMPLETE.
plant tagged
git -C "$workdir/tagged" tag -a v1 -m 'First release' >/dev/null 2>&1
run 'an annotated tag does not break --history' 0 'HANDOFF SCAN: PASS' "$workdir/tagged" --no-github --history --client OwnClient

# Every remote form resolves to OWNER/REPO, so a client clone never reads as "not client".
for url in git@github-work:octo/kit.git https://someone@github.com/octo/kit https://github.com/octo/kit/ ssh://git@github.com/octo/kit.git; do
  plant remote_form
  git -C "$workdir/remote_form" remote set-url origin "$url"
  run "remote form $url is recognised" 0 '' --is-client --dir "$workdir/remote_form"
done

# A fork as origin and the client as upstream is still a client clone.
plant forked
git -C "$workdir/forked" remote set-url origin https://github.com/someone/kit-fork.git
git -C "$workdir/forked" remote add upstream git@github.com:octo/kit.git
run 'a client remote not named origin is found' 0 '' --is-client --dir "$workdir/forked"
git -C "$workdir/forked" remote remove upstream
run 'a fork alone is not a client clone' 1 '' --is-client --dir "$workdir/forked"

# A missing registry where the private directory exists cannot see, so it is not "not client".
mkdir -p "$workdir/private"
HANDOFF_REGISTRY="$workdir/private/none.conf" run 'a missing registry beside a private dir is an error' 2 'client registry missing' --is-client --repo octo/kit
HANDOFF_REGISTRY="$workdir/no-such-dir/none.conf" run 'no private dir at all reads as not client' 1 '' --is-client --repo octo/kit

# A `~/` terms path in the registry resolves against HOME.
mkdir -p "$workdir/home"
printf '%s\n' 'zzinternalterm' > "$workdir/home/kit.terms"
printf '%s\n' 'octo/kit client=OwnClient terms=~/kit.terms' > "$workdir/private/terms.conf"
printf '%s\n' 'Mentions zzinternalterm.' > "$workdir/body-term.md"
HOME="$workdir/home" HANDOFF_REGISTRY="$workdir/private/terms.conf" run 'a ~/ terms path is read' 1 "[client-terms] 'zzinternalterm'" --text-file "$workdir/body-term.md" --repo octo/kit

# An unreadable PNG text chunk or an undecodable fig-kiwi chunk cannot report clean.
plant bad_binaries
python3 - "$workdir/bad_binaries" <<'PY2' || fail 'build bad binary fixtures' 'python helper failed'
import io, os, struct, sys, zipfile, zlib
root = sys.argv[1]
def chunk(t, body):
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
png += chunk(b"zTXt", b"Source\x00\x00" + b"not deflate at all") + chunk(b"IEND", b"")
open(os.path.join(root, "bad.png"), "wb").write(png)
PY2
git -C "$workdir/bad_binaries" add -A >/dev/null 2>&1 && git -C "$workdir/bad_binaries" commit --quiet -m 'Add art' >/dev/null 2>&1
run 'an unreadable PNG text chunk is INCOMPLETE' 2 'INCOMPLETE' "$workdir/bad_binaries" --no-github --client OwnClient
plant bad_fig
python3 - "$workdir/bad_fig" <<'PY2' || fail 'build bad fig fixture' 'python helper failed'
import io, os, struct, sys, zipfile
garbage = b"\x07\x07neither zstd nor deflate\xff\xff"
canvas = b"fig-kiwi" + struct.pack("<I", 15) + struct.pack("<I", len(garbage)) + garbage
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("canvas.fig", canvas)
open(os.path.join(sys.argv[1], "kit.fig"), "wb").write(buf.getvalue())
PY2
git -C "$workdir/bad_fig" add -A >/dev/null 2>&1 && git -C "$workdir/bad_fig" commit --quiet -m 'Add kit' >/dev/null 2>&1
run 'an undecodable fig-kiwi chunk is INCOMPLETE' 2 'INCOMPLETE' "$workdir/bad_fig" --no-github --client OwnClient

# The guard scans the whole push: a stamp added and removed inside one push still ships.
guarded2="$workdir/guarded2"
git init --quiet --bare "$workdir/remote2.git"
git clone --quiet "$workdir/remote2.git" "$guarded2" 2>/dev/null
git -C "$guarded2" config user.email selftest@example.invalid && git -C "$guarded2" config user.name 'Selftest'
printf 'kit\n' | commit_file "$guarded2" README.md 'Add kit'
run 'install the guard on a second clone' 0 'pre-push guard installed' --install-hook "$guarded2"
printf '%s\n' "$(printf 'VERIFY %s: PASS sha=abc1234 tree=def5678' 'RESULT')" | commit_file "$guarded2" STATUS.md 'Add status'
git -C "$guarded2" rm --quiet STATUS.md && git -C "$guarded2" commit --quiet -m 'Remove status' >/dev/null 2>&1
if git -C "$guarded2" push --quiet origin main >/dev/null 2>&1; then
  fail 'a stamp added and removed inside one push is blocked' 'push went through'
else
  pass 'a stamp added and removed inside one push is blocked'
fi

if [ "$failures" -eq 0 ]; then
  printf 'HANDOFF SCAN SELFTEST: PASS\n'
  completed=1; exit 0
fi
printf 'HANDOFF SCAN SELFTEST: FAIL (%s)\n' "$failures" >&2
completed=1; exit 1
