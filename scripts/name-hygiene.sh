#!/usr/bin/env bash
# Refuse private names on a public surface.
#
# Scans tracked file contents and commit messages for tokens whose lowercase SHA-256 appears in
# the denylist, and FAILs naming the token, file and line. The denylist holds hashes only, so it
# is safe to publish; the real->pseudonym table lives outside the repo
# (rules/public-surface-hygiene.md says where).
#
# Usage: scripts/name-hygiene.sh [--root <dir>] [--denylist <file>] [--range <git-range>] [--no-history] [--quiet]
#        scripts/name-hygiene.sh --text-file <path> [--label <what it is>] [--denylist <file>]
#
# --text-file scans one arbitrary text input instead of the repository: a pull-request title and
# body, for example, which are published verbatim by a squash merge but live in no file and no
# commit message until it is too late to take them back.
# Exit: 0 clean · 1 a denied token was found · 2 setup error (no denylist, not a git repo).
#
# A missing denylist is exit 2, never 0: an instrument that cannot see must not report "clean"
# (rules/verification-integrity.md).
set -uo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
denylist=''
scan_history=true
history_range=''
quiet=false
text_file=''
text_label='text input'

while [ $# -gt 0 ]; do
  case $1 in
    --root) root=${2:-}; shift 2 || exit 2 ;;
    --denylist) denylist=${2:-}; shift 2 || exit 2 ;;
    --range) history_range=${2:-}; shift 2 || exit 2 ;;
    --no-history) scan_history=false; shift ;;
    --text-file) text_file=${2:-}; shift 2 || exit 2 ;;
    --label) text_label=${2:-}; shift 2 || exit 2 ;;
    --quiet) quiet=true; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf 'NAME HYGIENE: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$denylist" ] || denylist="$root/scripts/testdata/name-hashes.txt"

if [ ! -f "$denylist" ]; then
  printf 'NAME HYGIENE: FAIL (denylist not found at %s — cannot report clean without one)\n' "$denylist" >&2
  exit 2
fi
if [ -n "$text_file" ] && [ ! -f "$text_file" ]; then
  printf 'NAME HYGIENE: FAIL (text input not found at %s — cannot report clean without it)\n' "$text_file" >&2
  exit 2
fi
if [ -z "$text_file" ] && ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'NAME HYGIENE: FAIL (%s is not a git repository)\n' "$root" >&2
  exit 2
fi

history_arg=--history
if [ -n "$history_range" ]; then
  history_arg=--range
elif [ "$scan_history" = false ]; then
  history_arg=--no-history
fi
quiet_arg=--loud
[ "$quiet" = false ] || quiet_arg=--quiet

python3 - "$root" "$denylist" "$history_arg" "$quiet_arg" "$history_range" "$text_file" "$text_label" <<'PY'
import hashlib, os, re, subprocess, sys

root, denylist_path, history_arg, quiet_arg, history_range, text_file, text_label = sys.argv[1:8]
scan_history = history_arg == "--history"
scan_range = history_arg == "--range"
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
# Ticket-shaped: a short alphabetic namespace, a hyphen, then a suffix that contains at least
# one digit. The digit is what keeps ordinary hyphenated words ("audio-app") out.
TICKET = re.compile(r"^([a-z]{2,10})-(?=[a-z0-9]{1,8}$)(?=[a-z]*\d)[a-z0-9]+$")

def variants(token):
    """Every contiguous hyphen-run of the token, lowercased.

    A denied name may be multi-part ("foo-bar") and may sit inside a longer compound
    ("prefix-foo-bar-suffix"), so whole-token and single-part checks both miss it. Hashing
    cannot match substrings, so the runs are enumerated here instead.
    """
    low = token.lower()
    yield low
    # A ticket id is private in its NAMESPACE, not its number: denying ABC-2823 alone lets
    # ABC-9999 through. Emit a number-erased form so one hash covers the whole namespace, while
    # the bare prefix on its own (an ordinary English word, often) stays un-denied.
    ticket = TICKET.match(low)
    if ticket:
        yield f"{ticket.group(1)}-#"
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

def scan(text, where, hits, first_line=1, marker=None):
    for lineno, line in enumerate(text.splitlines(), first_line):
        for match in TOKEN.finditer(line):
            for variant in variants(match.group(0)):
                digest = hashlib.sha256(variant.encode("utf-8")).hexdigest()
                if digest in denied:
                    location = marker if marker is not None else lineno
                    hit = (where, location, match.group(0), denied[digest])
                    if hit not in seen:
                        seen.add(hit)
                        hits.append(hit)

def scan_file(path, rel, hits):
    """Stream text without dropping a token split at a chunk boundary."""
    chunk_size = 64 * 1024
    trailing_token = re.compile(r"[A-Za-z0-9-]+$")
    first_line = 1
    tail = ""
    with open(path, encoding="utf-8") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            text = tail + chunk
            trailing = trailing_token.search(text)
            if trailing:
                body, tail = text[:trailing.start()], text[trailing.start():]
            else:
                body, tail = text, ""
            scan(body, rel, hits, first_line)
            first_line += body.count("\n")
    scan(tail, rel, hits, first_line)

def git(*args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)

hits = []

def report(hits):
    print("NAME HYGIENE: FAIL")
    for where, lineno, token, pseudonym in hits:
        label = f" — use {pseudonym}" if pseudonym else ""
        print(f"  {where}:{lineno}: denied token '{token}'{label}")
    print("")
    print("  Substitute the pseudonym from your private mapping; see rules/public-surface-hygiene.md.")

# One text input, scanned with the same tokenizer and the same hashes as a file. No git call at
# all: the caller holds text that is not in the repository yet, which is the whole point.
if text_file:
    try:
        with open(text_file, encoding="utf-8") as fh:
            scan(fh.read(), text_label, hits)
    except (UnicodeDecodeError, OSError) as exc:
        print(f"NAME HYGIENE: FAIL (cannot scan {text_file}: {exc})", file=sys.stderr)
        sys.exit(2)
    if hits:
        report(hits)
        sys.exit(1)
    if not quiet:
        print(f"NAME HYGIENE: PASS ({text_label}, {len(denied)} denied hashes)")
    sys.exit(0)

# Tracked AND untracked-but-not-ignored: a fresh leak lands in a new file, which is untracked
# right up until the commit agent stages it. Same set `git add -A` would take.
listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
if listed.returncode != 0:
    print(f"NAME HYGIENE: FAIL (git ls-files: {listed.stderr.strip()})", file=sys.stderr)
    sys.exit(2)

scanned = 0
messages_scanned = 0
deleted = 0
for rel in dict.fromkeys(listed.stdout.split("\0")):
    if not rel:
        continue
    # Account for every candidate path, including a tracked file removed in the working tree.
    # `git add -A` will publish that removal, so it is not a gap in content coverage.
    scanned += 1
    scan(rel, rel, hits, marker="path")
    path = os.path.join(root, rel)
    if not os.path.lexists(path):
        deleted += 1
        continue
    if not os.path.isfile(path):
        print(f"NAME HYGIENE: FAIL (cannot scan contents of {rel})", file=sys.stderr)
        sys.exit(2)
    try:
        scan_file(path, rel, hits)
    except (UnicodeDecodeError, OSError) as exc:
        print(f"NAME HYGIENE: FAIL (cannot scan {rel}: {exc})", file=sys.stderr)
        sys.exit(2)

if scan_history or scan_range:
    log_args = ["log"]
    if scan_range:
        log_args.append(history_range)
    else:
        log_args.append("--all")
    log_args.append("--format=%H%x1f%s%n%b%x1e")
    log = git(*log_args)
    if log.returncode != 0:
        print(f"NAME HYGIENE: FAIL (git log: {log.stderr.strip()})", file=sys.stderr)
        sys.exit(2)
    for record in log.stdout.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        sha, _, message = record.partition("\x1f")
        messages_scanned += 1
        scan(message, f"commit {sha[:9]}", hits)

if hits:
    report(hits)
    sys.exit(1)

if not quiet:
    # The message count is reported separately, and 0 is said out loud: an empty range prints the
    # same scope text as a scanned one, and "I read nothing" must not look like "I read them and
    # they were clean" (rules/verification-integrity.md).
    if scan_range:
        scope = f"tracked files and {messages_scanned} commit messages in {history_range}"
    elif scan_history:
        scope = f"tracked files and {messages_scanned} commit messages"
    else:
        scope = "tracked files"
    deleted_label = f", {deleted} deleted and skipped" if deleted else ""
    print(f"NAME HYGIENE: PASS ({scanned} {scope}{deleted_label}, {len(denied)} denied hashes)")
sys.exit(0)
PY
