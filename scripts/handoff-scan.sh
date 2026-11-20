#!/usr/bin/env bash
# Audit a client delivery for anything that is ours to keep (rules/client-handoff.md).
#
# Scans, for one delivery repository:
#   - every file at the tip of every ref (all branches, tags, remote-tracking refs, PR heads;
#     with --history, every blob ever reachable instead), with zip containers (.fig, .docx, .pptx, .zip) unpacked, a .fig's fig-kiwi canvas
#     decompressed (zstd or deflate chunks), PNG text chunks inflated, and every other binary
#     reduced to its printable strings;
#   - every ref name, commit message, tag message, and commit author/committer identity;
#   - on GitHub: the description, every PR and issue title, body, comment, review and review
#     comment, the edit history (userContentEdits) of each, and every release note.
# The text goes through two scanners: scripts/name-hygiene.sh (the shared tokenizer and hashed
# denylist, minus the owning client's own name) and the harness-term patterns below.
#
# Usage:
#   handoff-scan.sh <path-to-clone | OWNER/REPO> [--repo OWNER/REPO] [--client <Pseudonym>]
#                   [--allow-domain <domain>]... [--terms <file>] [--history] [--no-github] [--quiet]
#                   [--denylist <file>]   (default: scripts/testdata/name-hashes.txt beside this script)
#   handoff-scan.sh --text-file <path> [--label <what>] [--repo OWNER/REPO | --dir <clone>]
#                   [--client <P>] [--allow-domain <d>]... [--terms <f>]
#   handoff-scan.sh --is-client (--repo OWNER/REPO | --dir <path>)
#   handoff-scan.sh --install-hook <path-to-clone>
#
# --repo/--client/--allow-domain/--terms default from the private registry line for the repo
# (HANDOFF_REGISTRY, default ~/.claude/private/client-deliverables.conf):
#   OWNER/REPO  client=<Pseudonym>  allow-domain=<d>[,<d>]  terms=<file of extra regexes>
# --is-client exits 0 when the repo has a registry line, 1 when not, 2 when it cannot decide: a
# missing registry beside a private directory, or a clone whose own Agent Config says
# `deliverable` = `client` but is not registered. It is the ONE predicate the commit agent and
# scripts/trusted-pr-merge.sh share, and the registry is its only source of truth.
# --install-hook writes a pre-push hook into the clone's .git/hooks (never shipped: .git is not
# content) that runs the local half of this scan before every push.
#
# Exit: 0 clean · 1 a hit was found (each one named) · 2 setup error or an incomplete scan.
# An incomplete scan is never 0: a truncated GitHub page or an unreadable object cannot report
# clean (rules/verification-integrity.md).
set -uo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
harness_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
registry=${HANDOFF_REGISTRY:-$HOME/.claude/private/client-deliverables.conf}

die() { printf 'HANDOFF SCAN: ERROR: %s\n' "$*" >&2; exit 2; }

target=''
repo=''
client=''
terms=''
allow_domains=''
github=true
history=false
quiet=false
text_file=''
text_label='text input'
mode=scan
is_client_dir=''
hook_target=''
client_set=false
denylist="$script_dir/testdata/name-hashes.txt"
terms_set=false

while [ $# -gt 0 ]; do
  case $1 in
    --repo) repo=${2:-}; [ -n "$repo" ] || die '--repo needs OWNER/REPO'; shift 2 ;;
    --client) client=${2:-}; client_set=true; shift 2 || die '--client needs a value' ;;
    --allow-domain) allow_domains="$allow_domains ${2:-}"; shift 2 || die '--allow-domain needs a value' ;;
    --terms) terms=${2:-}; terms_set=true; shift 2 || die '--terms needs a file' ;;
    --no-github) github=false; shift ;;
    --denylist) denylist=${2:-}; shift 2 || die '--denylist needs a file' ;;
    --history) history=true; shift ;;
    --quiet) quiet=true; shift ;;
    --text-file) mode=text; text_file=${2:-}; shift 2 || die '--text-file needs a path' ;;
    --label) text_label=${2:-}; shift 2 || die '--label needs a value' ;;
    --is-client) mode=is-client; shift ;;
    --dir) is_client_dir=${2:-}; shift 2 || die '--dir needs a path' ;;
    --install-hook) mode=install-hook; hook_target=${2:-}; shift 2 || die '--install-hook needs a path' ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$target" ] || die "unexpected argument: $1"; target=$1; shift ;;
  esac
done

# --- the registry: private, host-side, one line per client delivery repo ---------------------
registry_line() {  # registry_line OWNER/REPO -> the matching line on stdout, exit 1 if none
  [ -f "$registry" ] || return 1
  awk -v want="$1" '
    /^[[:space:]]*(#|$)/ { next }
    { if (tolower($1) == tolower(want)) { print; found = 1; exit } }
    END { exit found ? 0 : 1 }
  ' "$registry"
}

registry_field() {  # registry_field <line> <key>
  printf '%s\n' "$1" | tr ' \t' '\n\n' | sed -n "s/^$2=//p" | tail -1
}

origin_repo() {  # origin_repo <dir> -> OWNER/REPO from the origin remote, if it is on GitHub
  local url
  # Any form: https (with or without user@), scp-style with an SSH host alias, ssh://, a trailing
  # slash. The registry keys on OWNER/REPO, so the last two path segments are what matter; a
  # missed form would read a client repository as "not client", which fails open.
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  printf '%s\n' "$url" | sed -E 's#/+$##; s#\.git$##; s#^[^:/]+:([^/])#/\1#' \
    | awk -F/ 'NF >= 2 && $(NF-1) != "" && $NF != "" { print $(NF-1) "/" $NF; ok = 1 } END { exit ok ? 0 : 1 }'
}

agent_config_says_client() {  # the repo's OWN Agent Config: `| deliverable | client |`
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  local f
  for f in "$top/CLAUDE.md" "$top/CLAUDE.local.md"; do
    [ -f "$f" ] || continue
    grep -Eiq '^\|[[:space:]]*`?deliverable`?[[:space:]]*\|[[:space:]]*`?client`?[[:space:]]*\|' "$f" && return 0
  done
  return 1
}

if [ "$mode" = is-client ]; then
  # A registry that should exist and does not is "cannot see", never "not a client": a machine
  # with a private directory keeps its registry there. Only a host with no private directory at
  # all (a fresh clone of the harness) reads a missing registry as an empty one.
  if [ ! -f "$registry" ] && [ -d "$(dirname -- "$registry")" ]; then
    die "client registry missing: $registry (create it, empty if there are no client repositories)"
  fi
  if [ -n "$repo" ]; then
    registry_line "$repo" >/dev/null && exit 0
    exit 1
  fi
  [ -n "$is_client_dir" ] || die '--is-client needs --repo OWNER/REPO or --dir <path>'
  [ -d "$is_client_dir" ] || die "not a directory: $is_client_dir"
  git -C "$is_client_dir" rev-parse --git-dir >/dev/null 2>&1 || exit 1
  r=$(origin_repo "$is_client_dir" || true)
  if [ -n "$r" ] && registry_line "$r" >/dev/null; then exit 0; fi
  # The registry is the one source of truth, because the merge wrapper can only ask it. A repo
  # that calls itself a client deliverable but is not registered would get ledger-only acks from
  # the commit agent and a body-ack demand from the wrapper: refuse until it is registered.
  if agent_config_says_client "$is_client_dir"; then
    die "$is_client_dir says \`deliverable: client\` but ${r:-its origin} is not in the client registry $registry; add its line (rules/client-handoff.md)"
  fi
  exit 1
fi

if [ "$mode" = install-hook ]; then
  [ -n "$hook_target" ] && [ -d "$hook_target" ] || die "not a directory: $hook_target"
  hooks_dir=$(git -C "$hook_target" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || die "not a git repository: $hook_target"
  hook="$hooks_dir/pre-push"
  marker='# handoff-scan pre-push guard'
  if [ -e "$hook" ] && ! grep -Fq "$marker" "$hook"; then
    die "$hook exists and is not this guard; merge it by hand rather than overwrite it"
  fi
  # The stable symlinked copy, not a worktree that will be reaped after its PR merges.
  # HANDOFF_SCAN_HOOK_SCANNER pins another copy (the selftest pins the copy under test).
  scanner="$script_dir/handoff-scan.sh"
  [ -f "$HOME/.claude/scripts/handoff-scan.sh" ] && scanner="$HOME/.claude/scripts/handoff-scan.sh"
  [ -z "${HANDOFF_SCAN_HOOK_SCANNER:-}" ] || scanner=$HANDOFF_SCAN_HOOK_SCANNER
  mkdir -p "$hooks_dir" || die "cannot create $hooks_dir"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
$marker (installed by handoff-scan.sh --install-hook; see rules/client-handoff.md)
# Every object about to leave this clone is already in its local history, so the local half of
# the scan over ALL history (every reachable blob, not only tips: a file added and removed inside
# one push still ships) covers the push. Exit non-zero blocks the push.
exec bash "$scanner" "\$(git rev-parse --show-toplevel)" --no-github --history
EOF
  chmod +x "$hook" || die "cannot make $hook executable"
  printf 'HANDOFF SCAN: pre-push guard installed at %s\n' "$hook"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || die 'python3 is required'
[ -f "$script_dir/name-hygiene.sh" ] || die "name-hygiene.sh not found beside this script"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/handoff-scan.XXXXXX") || die 'cannot create a scratch directory'
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

git_dir=''
if [ "$mode" = scan ]; then
  [ -n "$target" ] || die 'name a clone path or OWNER/REPO to scan'
  if [ -d "$target" ]; then
    git_dir=$(git -C "$target" rev-parse --path-format=absolute --git-dir 2>/dev/null) || die "not a git repository: $target"
    [ -n "$repo" ] || repo=$(origin_repo "$target" || true)
  else
    case "$target" in
      */*) repo=${repo:-$target} ;;
      *) die "not a directory and not OWNER/REPO: $target" ;;
    esac
    command -v gh >/dev/null 2>&1 || die 'gh is required to clone OWNER/REPO'
    # A mirror carries every ref GitHub serves, refs/pull/* included: a closed PR's head stays
    # readable by every collaborator long after its branch is deleted.
    gh repo clone "$target" "$workdir/mirror.git" -- --mirror --quiet >/dev/null 2>&1 || die "could not clone $target"
    git_dir="$workdir/mirror.git"
  fi
fi

# --dir in text mode: the registry defaults of the repository that clone pushes to.
if [ "$mode" = text ] && [ -z "$repo" ] && [ -n "$is_client_dir" ]; then
  [ -d "$is_client_dir" ] || die "not a directory: $is_client_dir"
  repo=$(origin_repo "$is_client_dir" || true)
fi
if [ -n "$repo" ] && line=$(registry_line "$repo"); then
  [ "$client_set" = true ] || client=$(registry_field "$line" client)
  [ "$terms_set" = true ] || terms=$(registry_field "$line" terms)
  allow_domains="$allow_domains $(registry_field "$line" allow-domain | tr ',' ' ')"
fi
case "$terms" in "~/"*) terms="$HOME/${terms#\~/}" ;; esac
[ -z "$terms" ] || [ -f "$terms" ] || die "terms file not found: $terms"

if [ "$mode" = text ]; then
  [ -f "$text_file" ] || die "text input not found: $text_file (cannot report clean without it)"
fi
if [ "$mode" = scan ] && [ "$github" = true ]; then
  [ -n "$repo" ] || die 'no GitHub repository known for this clone; pass --repo OWNER/REPO or --no-github'
  command -v gh >/dev/null 2>&1 || die 'gh is required for the GitHub half (or pass --no-github)'
  # PR heads of a plain clone are not local refs; fetch them into a side repository.
  if [ ! -d "$workdir/mirror.git" ]; then
    git init --quiet --bare "$workdir/pulls.git" || die 'cannot create a scratch repository'
    git -C "$workdir/pulls.git" fetch --quiet "https://github.com/$repo.git" '+refs/pull/*/head:refs/pull/*/head' \
      >/dev/null 2>&1 || die "could not fetch pull-request heads of $repo"
  fi
fi

corpus="$workdir/corpus"
mkdir -p "$corpus" || die 'cannot create the corpus directory'

rc=0
python3 - "$mode" "$git_dir" "$workdir" "$corpus" "$repo" "$github" "$text_file" "$text_label" \
  "$terms" "$allow_domains" "$harness_root" "$quiet" "$history" <<'PY' || rc=$?
import json, os, re, subprocess, sys, zipfile, zlib, io, struct

(mode, git_dir, workdir, corpus, repo, github, text_file, text_label,
 terms_path, allow_domains, harness_root, quiet, history) = sys.argv[1:14]
github = github == "true"
history = history == "true"
quiet = quiet == "true"

def fail_incomplete(msg):
    print(f"HANDOFF SCAN: INCOMPLETE ({msg}) — cannot report clean", file=sys.stderr)
    sys.exit(2)

# ---- the harness-term patterns ---------------------------------------------------------------
# (category, regex, flags). Every one names something that is ours to keep (rules/client-handoff.md
# § Keep): our tooling and its vocabulary, review/gate stamps, agent attribution, personal paths,
# commercial terms, and site secrets. Client-specific terms come from the registry's terms file.
I = re.IGNORECASE
PATTERNS = [
    ("harness", r"\bcc-harness\b", I),
    ("harness", r"\bcodex\b", I),
    ("harness", r"\bmodel[- _]routing\b", I),
    ("harness", r"\bgpt-\d", I),
    ("harness", r"\bharness_[a-z]+\b", I),
    ("harness", r"^Work class:", re.M),
    ("harness", r"\bsub-?agents?\b", I),
    ("harness", r"\b(code-quality|test-writer|pr-monitor) agent\b|\bagents/(code-quality|test-writer|pr-monitor|commit|release|verification)\.md\b", I),
    ("harness", r"\bthe harness\b", I),
    ("tracker", r"\.beads\b|\bbeads (workspace|tracker|issues?|ids?)\b", I),
    ("tracker", r"\bbd (create|close|show|update|ready|prime|list|remember|dep|search|memories|human)\b", 0),
    ("stamp", r"\bREVIEW ACK\b", I),
    ("stamp", r"\b(verdict|reviewer|classes|open_blockers|user_decision|rounds)=\S", 0),
    ("stamp", r"\b(VERIFY|CODE QUALITY|COMMIT) RESULT:", 0),
    ("stamp", r"\bREVIEWER: vendor=", 0),
    ("stamp", r"\bmutation[- ](checked|tested|tests?|controls?)\b", I),
    ("stamp", r"\bsha=[0-9a-f]{7,40} tree=", 0),
    ("stamp", r"\bnegative control\b", I),
    ("attribution", r"generated with \[?claude code", I),
    ("attribution", r"\bco-authored-by:.*(claude|anthropic|codex|openai|chatgpt|noreply@)", I),
    ("attribution", r"noreply@anthropic\.com", I),
    ("personal", r"/Users/[A-Za-z0-9._-]+/", 0),
    ("personal", r"/home/[A-Za-z0-9._-]+/", 0),
    ("personal", r"\b[A-Za-z]:\\Users\\", 0),
    ("personal", r"~/\.claude\b|~/projects/|/private/tmp/claude-|\bscratchpad\b", I),
    ("personal", r"\.claude/(rules|agents|projects|private|plans|scripts|hooks|worktrees)\b", 0),
    ("personal", r"\buser decision\b", I),
    ("commercial", r"\binvoic(e|es|ed|ing)\b|\bbillable\b|\bretainer\b|\brate card\b|\bupsell\b", I),
    ("commercial", r"\b(hourly|day|daily) rates?\b|\bstatement of work\b|\bhours (billed|logged)\b|\bour (fees?|margin)\b", I),
    ("commercial", r"\bSOW\b", 0),
    ("commercial", r"\$\s?\d[\d,]*(\.\d\d)?\s?(/|per\s)\s?(h|hr|hour|day)\b", I),
    ("secret", r"\bphc_[A-Za-z0-9]{20,}", 0),
    ("secret", r"\bGTM-[A-Z0-9]{4,}\b", 0),
    ("secret", r"\bUA-\d{4,}-\d+\b", 0),
    ("secret", r"\bAKIA[0-9A-Z]{16}\b", 0),
    ("secret", r"\bgh[pousr]_[A-Za-z0-9]{30,}", 0),
    ("secret", r"\bsk-(ant-)?[A-Za-z0-9_-]{20,}", 0),
    ("secret", r"\bxox[abpr]-[A-Za-z0-9-]{10,}", 0),
    ("secret", r"-----BEGIN [A-Z ]*PRIVATE KEY-----", 0),
]

# Our own rule and script file names are vocabulary too; read them from the TRUSTED harness so a
# new rule is covered the day it lands.
for sub, ext in (("rules", ".md"), ("scripts", ".sh")):
    d = os.path.join(harness_root, sub)
    if os.path.isdir(d):
        for name in sorted(os.listdir(d)):
            stem = name[: -len(ext)] if name.endswith(ext) else None
            if not stem or "-" not in stem or stem.endswith("-selftest"):
                continue
            # A script is named bare or with .sh; a rule only as a file name, since a hyphenated
            # rule stem can be ordinary prose.
            suffix = r"(\.sh)?\b" if sub == "scripts" else r"\.md\b"
            PATTERNS.append(("harness", r"\b" + re.escape(stem) + suffix, I))

if terms_path:
    with open(terms_path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            try:
                re.compile(line)
            except re.error as exc:
                print(f"HANDOFF SCAN: ERROR: bad regex in {terms_path}: {line!r}: {exc}", file=sys.stderr)
                sys.exit(2)
            PATTERNS.append(("client-terms", line, I))

COMPILED = [(cat, re.compile(rx, fl)) for cat, rx, fl in PATTERNS]

# Lowercase domains only: an address written by a person has one, and the mixed-case runs that
# binary noise produces (strings of an image) do not.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]{2,}@((?:[a-z0-9-]+\.)+[a-z]{2,})\b")
FILE_EXT_TLD = {"png", "jpg", "jpeg", "svg", "webp", "gif", "pdf", "json", "js", "mjs", "cjs", "css",
                "md", "py", "txt", "html", "ts", "woff", "woff2", "ttf", "otf", "mp4", "webm", "fig"}
# Documentation placeholders (RFC 2606 names and the common "name@company.com") identify no one.
ALLOWED = {"example.com", "example.org", "example.net", "company.com", "yourcompany.com", "domain.com",
           "users.noreply.github.com", "noreply.github.com"}
ALLOWED.update(d.strip().lower() for d in allow_domains.split() if d.strip())

def domain_allowed(domain):
    domain = domain.lower()
    if domain.endswith(".invalid") or domain.endswith(".test") or domain.endswith(".example"):
        return True
    return any(domain == a or domain.endswith("." + a) for a in ALLOWED)

hits = []
seen_hits = set()

def scan_text(text, label):
    for lineno, line in enumerate(text.splitlines(), 1):
        for cat, rx in COMPILED:
            for m in rx.finditer(line):
                key = (label, lineno, cat, m.group(0))
                if key not in seen_hits:
                    seen_hits.add(key)
                    hits.append(key)
        for m in EMAIL.finditer(line):
            domain = m.group(1)
            if domain.rsplit(".", 1)[-1].lower() in FILE_EXT_TLD or domain_allowed(domain):
                continue
            key = (label, lineno, "email", m.group(0))
            if key not in seen_hits:
                seen_hits.add(key)
                hits.append(key)

# ---- the corpus: every piece of text, also handed to name-hygiene.sh --text-dir --------------
counts = {}
def bump(k, n=1):
    counts[k] = counts.get(k, 0) + n

used = set()
def emit(label, text):
    """Scan one piece of text and write it to the corpus under a readable relative path."""
    scan_text(text, label)
    rel = re.sub(r"[^A-Za-z0-9._@!/+=-]", "_", label).strip("/") or "unnamed"
    rel = "/".join(p if p not in ("", ".", "..") else "_" for p in rel.split("/"))
    base, n = rel, 1
    while rel in used:
        n += 1
        rel = f"{base}~{n}"
    used.add(rel)
    path = os.path.join(corpus, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)

PRINTABLE = re.compile(rb"[\x20-\x7e\t]{4,}")
def strings_of(data):
    return "\n".join(m.group(0).decode("ascii") for m in PRINTABLE.finditer(data))

def zstd_decompress(data):
    p = subprocess.run(["zstd", "-d", "-c", "-q"], input=data, capture_output=True)
    if p.returncode != 0:
        raise ValueError("zstd failed: " + p.stderr.decode(errors="replace").strip())
    return p.stdout

def fig_kiwi_chunks(data):
    """fig-kiwi: 8-byte magic, uint32 version, then [uint32 LE length][payload] chunks, each
    zstd (magic 28 b5 2f fd) or raw-deflate compressed."""
    off = 12
    out = []
    while off + 4 <= len(data):
        (n,) = struct.unpack_from("<I", data, off)
        off += 4
        chunk = data[off: off + n]
        off += n
        if len(chunk) != n:
            raise ValueError("truncated fig-kiwi chunk")
        if chunk[:4] == b"\x28\xb5\x2f\xfd":
            out.append(zstd_decompress(chunk))
        else:
            try:
                out.append(zlib.decompress(chunk, -15))
            except zlib.error as exc:
                raise ValueError(f"fig-kiwi chunk is neither zstd nor deflate: {exc}")
    return out

def png_text(data):
    """tEXt, zTXt and iTXt chunks: where render tools write the source file's absolute path."""
    texts = []
    off = 8
    while off + 8 <= len(data):
        n, ctype = struct.unpack_from(">I4s", data, off)
        body = data[off + 8: off + 8 + n]
        off += 12 + n
        try:
            if ctype == b"tEXt":
                texts.append(body.replace(b"\0", b": ").decode("latin-1"))
            elif ctype == b"zTXt":
                key, _, rest = body.partition(b"\0")
                texts.append(key.decode("latin-1") + ": " + zlib.decompress(rest[1:]).decode("latin-1"))
            elif ctype == b"iTXt":
                key, _, rest = body.partition(b"\0")
                flag, rest = rest[0], rest[2:]
                _lang, _, rest = rest.partition(b"\0")
                _tkey, _, txt = rest.partition(b"\0")
                if flag:
                    txt = zlib.decompress(txt)
                texts.append(key.decode("latin-1") + ": " + txt.decode("utf-8", "replace"))
        except (zlib.error, IndexError) as exc:
            raise ValueError(f"unreadable {ctype!r} chunk: {exc}")
        if ctype == b"IEND":
            break
    return "\n".join(texts)

def scan_bytes(data, label, depth=0):
    if depth > 4:
        fail_incomplete(f"containers nested too deep at {label}")
    if data[:4] == b"PK\x03\x04":
        bump("containers unpacked")
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    emit(f"{label}!{info.filename}#name", info.filename)
                    scan_bytes(zf.read(info), f"{label}!{info.filename}", depth + 1)
        except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
            fail_incomplete(f"cannot unpack {label}: {exc}")
        return
    if data[:8] == b"fig-kiwi":
        bump("fig-kiwi canvases decoded")
        try:
            chunks = fig_kiwi_chunks(data)
        except ValueError as exc:
            fail_incomplete(f"cannot decode {label}: {exc}")
        for i, chunk in enumerate(chunks):
            emit(f"{label}#chunk{i}.strings", strings_of(chunk))
        return
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        try:
            emit(f"{label}#png-text", png_text(data))
        except ValueError as exc:
            fail_incomplete(f"cannot decode {label}: {exc}")
    try:
        text = data.decode("utf-8")
        if "\0" in text:
            raise UnicodeDecodeError("utf-8", b"", 0, 1, "NUL byte")
        emit(label, text)
        bump("text objects")
    except UnicodeDecodeError:
        emit(f"{label}#strings", strings_of(data))
        bump("binary objects reduced to strings")

def git(gd, *args, binary=False):
    p = subprocess.run(["git", "--git-dir", gd, *args], capture_output=True)
    if p.returncode != 0:
        fail_incomplete(f"git {' '.join(args[:2])}: {p.stderr.decode(errors='replace').strip()}")
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")

seen_blobs = set()
seen_commits = set()

def scan_git(gd, origin):
    refs = git(gd, "for-each-ref", "--format=%(refname)").split()
    emit(f"{origin}/refs", "\n".join(refs))
    bump("refs", len(refs))
    if not refs:
        return
    pending = []
    if history:
        # Every object reachable from every ref. A file deleted on main is still one checkout away
        # for the client, so a FIRST delivery (or one whose history was never audited) runs this.
        for line in git(gd, "rev-list", "--objects", "--all").splitlines():
            sha, _, path = line.partition(" ")
            if path and sha not in seen_blobs:
                pending.append((sha, path))
    else:
        # The tip of every ref: what a checkout of any branch, tag or PR head shows.
        for ref in refs:
            short = re.sub(r"^refs/(heads/|remotes/|tags/)?", "", ref)
            out = git(gd, "ls-tree", "-r", "-z", "--full-tree", ref + "^{tree}", binary=True)
            for entry in out.split(b"\0"):
                if not entry:
                    continue
                meta, _, path = entry.partition(b"\t")
                parts = meta.split()
                if len(parts) == 3 and parts[1] == b"blob":
                    pending.append((parts[2].decode(), f"{short}:{path.decode('utf-8', 'replace')}"))
    if pending:
        p = subprocess.run(["git", "--git-dir", gd, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                           input="\n".join(s for s, _ in pending).encode(), capture_output=True)
        if p.returncode != 0:
            fail_incomplete("git cat-file --batch-check failed")
        types = dict(l.split(" ", 1) for l in p.stdout.decode().splitlines() if " " in l)
        for sha, path in pending:
            if sha in seen_blobs:
                continue
            if types.get(sha) in ("tree", "tag"):
                continue  # an annotated tag's message is scanned with the other tag messages
            if types.get(sha) != "blob":
                fail_incomplete(f"unexpected object type for {path} ({sha[:9]}): {types.get(sha)}")
            seen_blobs.add(sha)
            emit(f"{origin}/path/{path}@{sha[:7]}#name", path)
            scan_bytes(git(gd, "cat-file", "blob", sha, binary=True), f"{origin}/blob/{path}@{sha[:7]}")
            bump("blobs")
    log = git(gd, "log", "--all", "--format=%H%x1f%an <%ae>%x1f%cn <%ce>%x1f%B%x1e")
    for record in log.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, author, committer, message = (record.split("\x1f", 3) + ["", "", ""])[:4]
        if sha in seen_commits:
            continue
        seen_commits.add(sha)
        bump("commit messages")
        emit(f"{origin}/commit/{sha[:9]}", message)
        ident = f"author: {author}\ncommitter: {committer}"
        for vendor in re.finditer(r"claude|anthropic|codex|openai|chatgpt|copilot", ident, I):
            key = (f"{origin}/commit/{sha[:9]}#identity", 1, "attribution", vendor.group(0))
            if key not in seen_hits:
                seen_hits.add(key); hits.append(key)
    tags = git(gd, "for-each-ref", "refs/tags", "--format=%(refname)%x1f%(contents)%x1e")
    for record in tags.split("\x1e"):
        record = record.strip("\n")
        if record:
            name, _, contents = record.partition("\x1f")
            emit(f"{origin}/tag/{name}", contents)
            bump("tag messages")

# ---- GitHub text and its edit history --------------------------------------------------------
def gh_graphql(query, **variables):
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        if v is None:
            continue
        args += ["-F" if isinstance(v, int) else "-f", f"{k}={v}"]
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        fail_incomplete(f"gh api graphql: {p.stderr.strip()[:300]}")
    data = json.loads(p.stdout)
    if data.get("errors"):
        fail_incomplete(f"GitHub GraphQL errors: {json.dumps(data['errors'])[:300]}")
    return data["data"]

# Split so no single query exceeds GitHub's 500,000-node ceiling: one listing query, then one
# detail query per pull request or issue. Any connection with another page fails the scan closed.
EDITS = "userContentEdits(first: 50) { pageInfo { hasNextPage } nodes { diff deletedAt } }"
LIST_Q = """query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) {
  %s(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { number title %s body %s } } } }"""
PR_LIST_Q = LIST_Q % ("pullRequests", "headRefName baseRefName", EDITS)
ISSUE_LIST_Q = LIST_Q % ("issues", "", EDITS)
COMMENTS = f"comments(first: 100) {{ pageInfo {{ hasNextPage }} nodes {{ body {EDITS} }} }}"
PR_DETAIL_Q = f"""query($owner: String!, $name: String!, $number: Int!) {{ repository(owner: $owner, name: $name) {{
  pullRequest(number: $number) {{ {COMMENTS}
    reviews(first: 50) {{ pageInfo {{ hasNextPage }} nodes {{ body {EDITS}
      comments(first: 50) {{ pageInfo {{ hasNextPage }} nodes {{ body {EDITS} }} }} }} }} }} }} }}"""
ISSUE_DETAIL_Q = f"""query($owner: String!, $name: String!, $number: Int!) {{ repository(owner: $owner, name: $name) {{
  issue(number: $number) {{ {COMMENTS} }} }} }}"""
REPO_Q = """query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  description homepageUrl repositoryTopics(first: 100) { nodes { topic { name } } }
  releases(first: 100) { pageInfo { hasNextPage } nodes { name tagName description } } } }"""

def require_complete(conn, where):
    if conn and conn.get("pageInfo", {}).get("hasNextPage"):
        fail_incomplete(f"more than one page of {where}; nested pagination is not implemented")

def emit_edits(node, label):
    edits = node.get("userContentEdits") or {}
    require_complete(edits, f"edit history at {label}")
    for i, e in enumerate(edits.get("nodes") or []):
        bump("edit-history revisions")
        if e.get("diff") is not None:
            emit(f"{label}#edit{i}", e["diff"])

def emit_comments(node, label):
    comments = node.get("comments") or {}
    require_complete(comments, f"comments on {label}")
    for i, c in enumerate(comments.get("nodes") or []):
        bump("comments")
        emit(f"{label}/comment{i}", c.get("body") or "")
        emit_edits(c, f"{label}/comment{i}")

def listing(query, owner, name, key):
    after = None
    while True:
        conn = gh_graphql(query, owner=owner, name=name, after=after)["repository"][key]
        yield from conn["nodes"]
        if not conn["pageInfo"]["hasNextPage"]:
            return
        after = conn["pageInfo"]["endCursor"]

def scan_github():
    owner, name = repo.split("/", 1)
    r = gh_graphql(REPO_Q, owner=owner, name=name)["repository"]
    if r is None:
        fail_incomplete(f"repository {repo} not visible")
    topics = " ".join(t["topic"]["name"] for t in r["repositoryTopics"]["nodes"])
    emit("github/repository", f"{r.get('description') or ''}\n{r.get('homepageUrl') or ''}\n{topics}")
    require_complete(r["releases"], "releases")
    for rel in r["releases"]["nodes"]:
        bump("releases")
        emit(f"github/release/{rel['tagName']}", f"{rel.get('name') or ''}\n{rel.get('description') or ''}")
    for pr in listing(PR_LIST_Q, owner, name, "pullRequests"):
        bump("pull requests")
        label = f"github/pr-{pr['number']}"
        emit(f"{label}/title", f"{pr['title']}\n{pr['headRefName']}\n{pr['baseRefName']}")
        emit(f"{label}/body", pr.get("body") or "")
        emit_edits(pr, f"{label}/body")
        detail = gh_graphql(PR_DETAIL_Q, owner=owner, name=name, number=pr["number"])["repository"]["pullRequest"]
        emit_comments(detail, label)
        require_complete(detail["reviews"], f"reviews on {label}")
        for i, rv in enumerate(detail["reviews"]["nodes"]):
            bump("reviews")
            emit(f"{label}/review{i}", rv.get("body") or "")
            emit_edits(rv, f"{label}/review{i}")
            require_complete(rv["comments"], f"review comments on {label}")
            for j, c in enumerate(rv["comments"]["nodes"]):
                bump("review comments")
                emit(f"{label}/review{i}-comment{j}", c.get("body") or "")
                emit_edits(c, f"{label}/review{i}-comment{j}")
    for issue in listing(ISSUE_LIST_Q, owner, name, "issues"):
        bump("issues")
        label = f"github/issue-{issue['number']}"
        emit(f"{label}/title", issue["title"])
        emit(f"{label}/body", issue.get("body") or "")
        emit_edits(issue, f"{label}/body")
        detail = gh_graphql(ISSUE_DETAIL_Q, owner=owner, name=name, number=issue["number"])["repository"]["issue"]
        emit_comments(detail, label)

# ---- run -------------------------------------------------------------------------------------
if mode == "text":
    with open(text_file, "rb") as fh:
        data = fh.read()
    try:
        emit(text_label, data.decode("utf-8"))
    except UnicodeDecodeError as exc:
        print(f"HANDOFF SCAN: ERROR: cannot read {text_file} as text: {exc}", file=sys.stderr)
        sys.exit(2)
    bump("text inputs")
else:
    scan_git(git_dir, "git")
    pulls = os.path.join(workdir, "pulls.git")
    if os.path.isdir(pulls):
        scan_git(pulls, "git-pulls")
    if github:
        scan_github()
    else:
        counts["GitHub (skipped: --no-github)"] = 0

with open(os.path.join(workdir, "counts.json"), "w") as fh:
    json.dump(counts, fh)

summary = ", ".join(f"{v} {k}" if v or "skipped" not in k else k for k, v in counts.items())
if hits:
    print("HANDOFF SCAN: FAIL")
    for label, lineno, cat, text in hits:
        shown = text if len(text) <= 120 else text[:117] + "..."
        print(f"  {label}:{lineno}: [{cat}] '{shown}'")
    print("")
    print("  Each hit is ours to keep (rules/client-handoff.md § What ships and what stays). Fix the source and, for text")
    print("  already on GitHub, delete the edit-history revision too: an edited body is still readable.")
    print(f"  Scanned: {summary}")
    sys.exit(1)
if not quiet:
    print(f"HANDOFF SCAN: terms PASS ({summary})")
sys.exit(0)
PY

case "$rc" in
  0|1) ;;
  *) exit 2 ;;
esac

# The same corpus through the shared tokenizer and hashed denylist, so another client's name is
# caught however it is cased or compounded — never a second, drifting copy of that logic.
nh_args=(--text-dir "$corpus" --denylist "$denylist")
[ -z "$client" ] || nh_args+=(--exclude-pseudonym "$client")
[ "$quiet" = false ] || nh_args+=(--quiet)
nh_rc=0
bash "$script_dir/name-hygiene.sh" "${nh_args[@]}" || nh_rc=$?
case "$nh_rc" in
  0) ;;
  1) rc=1 ;;
  *) printf 'HANDOFF SCAN: ERROR: the name scan could not run (exit %s)\n' "$nh_rc" >&2; exit 2 ;;
esac

if [ "$rc" -eq 0 ]; then
  [ "$quiet" = true ] || printf 'HANDOFF SCAN: PASS%s\n' "${client:+ (own name allowed: $client)}"
else
  printf 'HANDOFF SCAN: FAIL\n'
fi
exit "$rc"
