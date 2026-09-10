#!/usr/bin/env bash
# Refuse private names on a public surface.
#
# Scans tracked file contents and commit messages for tokens whose lowercase SHA-256 appears in
# the denylist, and FAILs naming the token, file and line. The denylist holds hashes only, so it
# is safe to publish; the real->pseudonym table lives outside the repo
# (rules/public-surface-hygiene.md says where).
#
# Usage: scripts/name-hygiene.sh [--root <dir>] [--denylist <file>] [--no-history] [--quiet]
# Exit: 0 clean · 1 a denied token was found · 2 setup error (no denylist, not a git repo).
#
# A missing denylist is exit 2, never 0: an instrument that cannot see must not report "clean"
# (rules/verification-integrity.md).
set -uo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
denylist=''
scan_history=true
quiet=false

while [ $# -gt 0 ]; do
  case $1 in
    --root) root=${2:-}; shift 2 || exit 2 ;;
    --denylist) denylist=${2:-}; shift 2 || exit 2 ;;
    --no-history) scan_history=false; shift ;;
    --quiet) quiet=true; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'NAME HYGIENE: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$denylist" ] || denylist="$root/scripts/testdata/name-hashes.txt"

if [ ! -f "$denylist" ]; then
  printf 'NAME HYGIENE: FAIL (denylist not found at %s — cannot report clean without one)\n' "$denylist" >&2
  exit 2
fi
if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'NAME HYGIENE: FAIL (%s is not a git repository)\n' "$root" >&2
  exit 2
fi

history_arg=--history
[ "$scan_history" = true ] || history_arg=--no-history
quiet_arg=--loud
[ "$quiet" = false ] || quiet_arg=--quiet

python3 - "$root" "$denylist" "$history_arg" "$quiet_arg" <<'PY'
import hashlib, os, re, subprocess, sys

root, denylist_path, history_arg, quiet_arg = sys.argv[1:5]
scan_history = history_arg == "--history"
quiet = quiet_arg == "--quiet"

denied = {}
with open(denylist_path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        digest, _, comment = line.partition("#")
        digest = digest.strip().lower()
        if len(digest) == 64 and all(c in "0123456789abcdef" for c in digest):
            denied[digest] = comment.strip()

if not denied:
    print(f"NAME HYGIENE: FAIL (denylist {denylist_path} holds no hashes)", file=sys.stderr)
    sys.exit(2)

# Hyphenated compounds are one token AND their parts, because hashing cannot match substrings.
TOKEN = re.compile(r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*")

def variants(token):
    """Every contiguous hyphen-run of the token, lowercased.

    A denied name may be multi-part ("foo-bar") and may sit inside a longer compound
    ("prefix-foo-bar-suffix"), so whole-token and single-part checks both miss it. Hashing
    cannot match substrings, so the runs are enumerated here instead.
    """
    low = token.lower()
    yield low
    if "-" not in low:
        return
    parts = [p for p in low.split("-") if p]
    if len(parts) > 12:  # pathological chain: fall back to the parts alone
        yield from parts
        return
    for start in range(len(parts)):
        for end in range(start + 1, len(parts) + 1):
            run = "-".join(parts[start:end])
            if run != low:
                yield run

seen = set()

def scan(text, where, hits):
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in TOKEN.finditer(line):
            for variant in variants(match.group(0)):
                digest = hashlib.sha256(variant.encode("utf-8")).hexdigest()
                if digest in denied:
                    hit = (where, lineno, match.group(0), denied[digest])
                    if hit not in seen:
                        seen.add(hit)
                        hits.append(hit)

def git(*args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)

hits = []
# Tracked AND untracked-but-not-ignored: a fresh leak lands in a new file, which is untracked
# right up until the commit agent stages it. Same set `git add -A` would take.
listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
if listed.returncode != 0:
    print(f"NAME HYGIENE: FAIL (git ls-files: {listed.stderr.strip()})", file=sys.stderr)
    sys.exit(2)

skip = {os.path.relpath(denylist_path, root)}
scanned = 0
for rel in dict.fromkeys(listed.stdout.split("\0")):
    if not rel or rel in skip:
        continue
    path = os.path.join(root, rel)
    if not os.path.isfile(path) or os.path.getsize(path) > 4 * 1024 * 1024:
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (UnicodeDecodeError, OSError):
        continue  # binary or unreadable: nothing to read a name out of
    scanned += 1
    scan(text, rel, hits)

if scan_history:
    log = git("log", "--all", "--format=%H%x1f%s%n%b%x1e")
    if log.returncode == 0:
        for record in log.stdout.split("\x1e"):
            record = record.strip()
            if not record:
                continue
            sha, _, message = record.partition("\x1f")
            scan(message, f"commit {sha[:9]}", hits)

if hits:
    print("NAME HYGIENE: FAIL")
    for where, lineno, token, pseudonym in hits:
        label = f" — use {pseudonym}" if pseudonym else ""
        print(f"  {where}:{lineno}: denied token '{token}'{label}")
    print("")
    print("  Substitute the pseudonym from your private mapping; see rules/public-surface-hygiene.md.")
    sys.exit(1)

if not quiet:
    scope = "tracked files and commit messages" if scan_history else "tracked files"
    print(f"NAME HYGIENE: PASS ({scanned} {scope}, {len(denied)} denied hashes)")
sys.exit(0)
PY
