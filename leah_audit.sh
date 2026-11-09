#!/usr/bin/env bash
# leah_audit.sh v3 - READ-ONLY Phase 1 audit for Project LEAH (laptop or Pi).
#
# GUARANTEES
#   * Never modifies the LEAH repo, the backup, Git branches/refs/index, system
#     configuration, firewall or services. Never installs, commits, pushes or fetches.
#   * Writes ONLY into one NEW directory:  ~/leah_audit_<host>_<timestamp>/
#     (refuses to run if it already exists; every file inside is created exclusively).
#   * Active tests are opt-in: --probe (runs llama binaries) and --remote (network).
#   * Output is passed through a redaction filter; secrets are never printed.
#
# USAGE
#   bash leah_audit.sh [options]
#     --repo DIR        LEAH repository (default ~/Leah)
#     --backup DIR      backup copy to audit with the same rules (default ~/Backups/Leah)
#     --hash-models     SHA256 the model files (slow on a Pi)
#     --expect-sha HEX  known-good model SHA256 to compare against (with --hash-models)
#     --remote          ACTIVE (network): ask the 'origin' remote for main's current hash via
#                       `git ls-remote` (read-only; does NOT fetch or write .git). It disables
#                       credential helpers, so private remotes will simply fail. Note that git
#                       may still run a core.sshCommand configured in the repository.
#     --probe           ACTIVE: execute llama binaries (--version, ldd) and run ONE
#                       tiny generation. Uses CPU and memory. Off by default.
#     -h, --help
#
# FILES AND LOCATIONS READ
#   /etc/os-release, /proc/cpuinfo, `uname`, `lscpu`, `free`, `df`, `vcgencmd` (temperature)
#   versions of python3/gcc/g++/cmake/make/git (runs `<tool> --version`)
#   every file under --repo and --backup (to hash/classify; secrets are never printed)
#   Git metadata via plain read-only git commands: rev-parse, config --get, ls-files (-s -d -o -i),
#     ls-tree, rev-list, log -1, branch, remote -v, describe, check-ignore, submodule status.
#     `git status`, `diff`, `fetch`, `pull`, `checkout`, `gc` are NEVER run (status/diff can execute
#     repository-configured filter programs and refresh the index). Git is started with
#     core.fsmonitor disabled and GIT_OPTIONAL_LOCKS=0. Git does not promise zero writes for every
#     command; leah_selftest.sh fingerprints repo contents + .git before/after to check this.
#   assistant*.py in the repo (keyword matches only, never whole lines)
#   current user's crontab (`crontab -l`; only LEAH-related schedule + program name shown)
#   process list (`ps`; only pid, user, name, exe path of LEAH-related processes)
#   `ss -tuln` (listening sockets), `systemctl list-unit-files` (names only)
#   /etc/ssh/sshd_config and sshd_config.d/*.conf (only 3 setting names, global section)
#   `ufw status` (readable only as root), permissions of data/ and .env files
#
# FILES AND LOCATIONS WRITTEN (all inside the new report directory)
#   report.txt, manifest_repo.tsv, manifest_backup.tsv (if a backup exists),
#   cached_origin_main_tree.bin (only if a cached origin/main exists), probe_output.txt (--probe)
#   (report.txt and probe_output.txt are redacted; manifests/trees contain relative file names only)
#
# TEST HOOK: LEAH_AUDIT_SSHD_CONFIG=<file> makes the SSH section read that file (used by selftest).
#
# REQUIRES: bash, python3 (3.5+), git (optional), standard Linux tools. No root needed.

set -u
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

REPO="$HOME/Leah"; BACKUP="$HOME/Backups/Leah"
PROBE=0; HASHM=0; REMOTE=0; EXPECT_SHA=""

while [ $# -gt 0 ]; do
    case "$1" in
        --probe) PROBE=1 ;;
        --hash-models) HASHM=1 ;;
        --remote) REMOTE=1 ;;
        --repo) REPO="${2:-}"; shift ;;
        --backup) BACKUP="${2:-}"; shift ;;
        --expect-sha) EXPECT_SHA="${2:-}"; shift ;;
        -h|--help) sed -n '/^# leah_audit.sh/,/^set -u/{/^set -u/!p}' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (use --help)"; exit 2 ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || { echo "python3 is required."; exit 1; }
[ -d "$REPO" ] || { echo "Repo folder not found: $REPO"; exit 1; }
HOST="$(hostname)"; TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/leah_audit_${HOST}_${TS}"
mkdir "$OUT" || { echo "Cannot create $OUT (already exists?). Nothing was changed."; exit 1; }
REPORT="$OUT/report.txt"

HOME_ESC="$(printf '%s' "$HOME" | sed -e 's/[][\.*^$#/|&]/\\&/g')"
redact() {   # defence-in-depth filter applied to the whole report
    LC_ALL=C tr -d '\001-\010\013-\037\177' | sed -E \
      -e "s#${HOME_ESC}#~#g" \
      -e 's#(://)[^/@[:space:]]+@#\1***REDACTED***@#g' \
      -e 's#([?&](access_token|token|key|password|passwd|secret|api_key|apikey)=)[^&[:space:]]+#\1***REDACTED***#Ig' \
      -e 's#(authorization:[[:space:]]*).*#\1***REDACTED***#I' \
      -e 's#(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}#\1***REDACTED***#Ig' \
      -e 's#-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*#-----BEGIN PRIVATE KEY----- ***REDACTED***#' \
      -e 's#AKIA[0-9A-Z]{16}#***REDACTED-AWS-KEY***#g' \
      -e 's#gh[pousr]_[A-Za-z0-9]{20,}#***REDACTED-GITHUB-TOKEN***#g' \
      -e 's#github_pat_[A-Za-z0-9_]{20,}#***REDACTED-GITHUB-TOKEN***#g' \
      -e 's#xox[abprs]-[A-Za-z0-9-]{10,}#***REDACTED-SLACK-TOKEN***#g' \
      -e 's#sk-[A-Za-z0-9_-]{20,}#***REDACTED-API-KEY***#g' \
      -e 's#((password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+#\1***REDACTED***#Ig'
}
section() { printf '\n===== %s =====\n' "$1"; }
g() { git -c core.fsmonitor=false "$@"; }   # every git call goes through here

read -r -d '' PYTOOL <<'PYEOF'
import hashlib, io, os, re, stat, subprocess, sys, time

MODEL_EXT = (".gguf", ".onnx", ".pt", ".pth", ".safetensors", ".ggml")
BIN_EXT = (".so", ".a", ".dll", ".exe", ".dylib")
BUILD_SKIP_EXT = (".o", ".obj", ".d")
BIG = 50 * 1024 * 1024
LFS_HEADER = b"version https://git-lfs.github.com/spec/v1"
EXCLUDE_NAMES = {
    ".git": "git metadata",
    "__pycache__": "python bytecode cache",
    "CMakeFiles": "cmake generated files",
    ".pytest_cache": "test cache",
    ".mypy_cache": "type-check cache",
    ".tox": "tox environments",
    "node_modules": "dependency cache",
    ".cache": "cache directory",
    ".npm": "dependency cache",
    ".pip": "dependency cache",
    "site-packages": "installed python packages",
    "venv": "python virtual environment",
    ".venv": "python virtual environment",
    "virtualenv": "python virtual environment",
}
BUILD_NAMES = ("build", "dist")          # exact names only; "build-backup" or "mybuild" are NOT build dirs
# Never run `git status`/`diff`: they can execute repository-configured filter or fsmonitor
# programs. Only plain read commands are used, with fsmonitor disabled as a precaution.
GIT_BASE = ["git", "-c", "core.fsmonitor=false"]
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
_after_first_chunk = None                 # test hook used only by leah_selftest.sh; never set here


class Changed(Exception):
    pass


def esc(text):
    """Reversible, injective escaping: no tabs/newlines/control chars survive."""
    out = []
    for ch in text:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif o < 32 or o == 127:
            out.append("\\x%02x" % o)
        else:
            out.append(ch)
    return "".join(out)


def dec(raw):
    return raw.decode("utf-8", "surrogateescape")


def new_blob(alg, size):
    return hashlib.new(alg, b"blob %d\0" % size)


def blob_id(alg, data):
    h = new_blob(alg, len(data))
    h.update(data)
    return h.hexdigest()


def git(root, *args):
    try:
        return subprocess.check_output(GIT_BASE + ["-C", root] + list(args), env=GIT_ENV,
                                       stderr=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None


def split_z(data):
    return [e for e in data.split(b"\0") if e] if data else []


def git_info(root):
    info = {"repo": False, "fmt": "-", "alg": "sha1", "head": "-", "branch": "-", "dirty": "-",
            "index": {}, "submodules": {}, "deleted": set(), "untracked": set(),
            "ignored": set(), "nested": [], "lfs": False, "problems": []}
    top = git(root, "rev-parse", "--show-toplevel")
    prefix = git(root, "rev-parse", "--show-prefix")
    if top is None or prefix is None:
        return info
    if os.path.realpath(dec(top).strip()) != os.path.realpath(root) or prefix.strip():
        info["problems"].append("folder is inside a larger git work tree; git state not used")
        return info
    info["repo"] = True
    fmt = git(root, "rev-parse", "--show-object-format")
    if fmt is None:
        fmt = git(root, "config", "--get", "extensions.objectformat")
    info["fmt"] = dec(fmt).strip() if fmt and fmt.strip() else "sha1"
    if info["fmt"] == "sha256":
        info["alg"] = "sha256"
    head = git(root, "rev-parse", "HEAD")
    info["head"] = dec(head).strip() if head else "-"
    br = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    info["branch"] = dec(br).strip() if br else "-"
    ga = os.path.join(root, ".gitattributes")
    try:
        if stat.S_ISREG(os.lstat(ga).st_mode):
            with io.open(ga, "r", encoding="utf-8", errors="replace") as handle:
                info["lfs"] = "filter=lfs" in handle.read()
    except OSError:
        pass
    idx = git(root, "ls-files", "-s", "-z")
    for entry in split_z(idx):
        meta, _, path = entry.partition(b"\t")
        fields = meta.split()
        if len(fields) != 3:
            info["problems"].append("unparseable index entry")
            continue
        mode, sha, stage = dec(fields[0]), dec(fields[1]), dec(fields[2])
        p = esc(dec(path))
        if stage != "0":
            info["problems"].append("merge-conflict index entry: " + p)
            continue
        if mode == "160000":
            info["submodules"][p] = sha
        info["index"][p] = sha
    for key, args in (("deleted", ("ls-files", "-d", "-z")),
                      ("untracked", ("ls-files", "-o", "--exclude-standard", "-z")),
                      ("ignored", ("ls-files", "-o", "-i", "--exclude-standard", "-z"))):
        for raw in split_z(git(root, *args)):
            p = esc(dec(raw))
            if p.endswith("/"):
                info["nested"].append(p)
            else:
                info[key].add(p)
    return info


def excluded_reason(full, name):
    if name in EXCLUDE_NAMES:
        return EXCLUDE_NAMES[name]
    if os.path.exists(os.path.join(full, "pyvenv.cfg")):
        return "python virtual environment (pyvenv.cfg)"
    return None


def is_build_dir(full, name):
    return (name in BUILD_NAMES or name.startswith("cmake-build-")
            or os.path.exists(os.path.join(full, "CMakeCache.txt")))


def hash_regular(full, st, want_blob, alg):
    """Hash a regular file WITHOUT following symlinks and detect changes while reading."""
    fd = os.open(full, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        st1 = os.fstat(handle.fileno())
        if (not stat.S_ISREG(st1.st_mode) or st1.st_ino != st.st_ino or st1.st_dev != st.st_dev):
            raise Changed("replaced-during-hashing")
        sha = hashlib.sha256()
        blob = new_blob(alg, st1.st_size) if want_blob else None
        total, first, hooked = 0, b"", False
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            if not first:
                first = chunk[:64]
            total += len(chunk)
            sha.update(chunk)
            if blob is not None:
                blob.update(chunk)
            if _after_first_chunk is not None and not hooked:
                hooked = True
                _after_first_chunk(full)
        st2 = os.fstat(handle.fileno())
    if (total != st1.st_size or st2.st_size != st1.st_size
            or st2.st_mtime_ns != st1.st_mtime_ns):
        raise Changed("changed-during-hashing")
    return sha.hexdigest(), (blob.hexdigest() if blob is not None else None), first


def mk_note(flags):
    return ";".join(sorted(flags)) if flags else "-"


def cmd_manifest(root, out, hash_models, label):
    root = os.path.abspath(root)
    info = git_info(root)
    alg = info["alg"]
    rows = []
    rootdev = os.lstat(root).st_dev
    counts = {}

    def symlink_row(full, erel):
        target = os.readlink(full)
        tb = os.fsencode(target)
        resolved = os.path.normpath(target if os.path.isabs(target)
                                    else os.path.join(os.path.dirname(full), target))
        flags = []
        if os.path.isabs(target):
            flags.append("absolute")
        if not (resolved == root or resolved.startswith(root + os.sep)):
            flags.append("outside-root(lexical)")
        return ("symlink", erel, str(len(tb)), "-", blob_id(alg, tb), "-",
                "flags=%s|target=%s" % (",".join(flags) or "none", esc(target)))

    def file_row(full):
        rel = os.path.relpath(full, root)
        erel = esc(rel)
        try:
            st = os.lstat(full)
        except OSError as e:
            return ("unreadable", erel, "-", "-", "-", "-", "lstat errno=%s" % e.errno)
        if stat.S_ISLNK(st.st_mode):
            try:
                return symlink_row(full, erel)
            except OSError as e:
                return ("unreadable", erel, "-", "-", "-", "-", "readlink errno=%s" % e.errno)
        if not stat.S_ISREG(st.st_mode):
            kinds = ((stat.S_ISFIFO, "fifo"), (stat.S_ISSOCK, "socket"),
                     (stat.S_ISCHR, "chardev"), (stat.S_ISBLK, "blockdev"))
            name = "other"
            for test, label_ in kinds:
                if test(st.st_mode):
                    name = label_
            return ("special", erel, "-", "-", "-", "-", "type=" + name)
        size = st.st_size
        lname = os.path.basename(full).lower()
        is_model = lname.endswith(MODEL_EXT)
        flags = []
        if st.st_mode & stat.S_IXUSR:
            flags.append("exec")
        if is_model and not hash_models:
            flags.append("hash-not-requested")
            return ("model", erel, str(size), "NOT-COMPUTED", "NOT-COMPUTED", "-", mk_note(flags))
        if size > BIG and not is_model:
            flags.append("size-limit-50MB")
            kind = "binary" if (lname.endswith(BIN_EXT) or st.st_mode & 0o111) else "source"
            return (kind, erel, str(size), "NOT-COMPUTED", "NOT-COMPUTED", "-", mk_note(flags))
        try:
            sha, blob, first = hash_regular(full, st, not is_model, alg)
        except Changed as e:
            return ("unreadable", erel, str(size), "-", "-", "-", str(e))
        except OSError as e:
            return ("unreadable", erel, str(size), "-", "-", "-", "open errno=%s" % e.errno)
        if is_model:
            return ("model", erel, str(size), sha, "NOT-COMPUTED", "-", mk_note(flags))
        kind = "binary" if (first[:4] == b"\x7fELF" or lname.endswith(BIN_EXT)) else "source"
        if kind == "source" and size <= 1024 and first[:len(LFS_HEADER)] == LFS_HEADER:
            flags.append("lfs-pointer")
        return (kind, erel, str(size), sha, blob, "-", mk_note(flags))

    def inventory_build(full, rel):
        found, other = 0, 0
        for dp, dn, fn in os.walk(full, followlinks=False):
            dn[:] = sorted(d for d in dn if d != "CMakeFiles" and not os.path.islink(os.path.join(dp, d)))
            for f in sorted(fn):
                p = os.path.join(dp, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    other += 1
                    continue
                lname = f.lower()
                if (stat.S_ISREG(st.st_mode) and not lname.endswith(BUILD_SKIP_EXT)
                        and (st.st_mode & 0o111 or lname.endswith(BIN_EXT))):
                    row = file_row(p)
                    rows.append(("binary",) + row[1:] if row[0] in ("source", "binary") else row)
                    found += 1
                else:
                    other += 1
        rows.append(("excluded", esc(rel) + "/", "-", "-", "-", "-",
                     "reason=generated build directory; %d binaries inventoried, "
                     "%d other generated files not listed" % (found, other)))

    def onerror(err):
        fn = getattr(err, "filename", None)
        rel = os.path.relpath(fn, root) if fn else "?"
        rows.append(("unreadable", esc(rel), "-", "-", "-", "-", "directory-not-listable errno=%s" % err.errno))

    for dp, dn, fn in os.walk(root, topdown=True, onerror=onerror, followlinks=False):
        keep = []
        for d in sorted(dn):
            full = os.path.join(dp, d)
            rel = os.path.relpath(full, root)
            erel = esc(rel)
            try:
                st = os.lstat(full)
            except OSError as e:
                rows.append(("unreadable", erel, "-", "-", "-", "-", "lstat errno=%s" % e.errno))
                continue
            if stat.S_ISLNK(st.st_mode):
                rows.append(file_row(full))
                continue
            if st.st_dev != rootdev:
                rows.append(("excluded", erel + "/", "-", "-", "-", "-",
                             "reason=different filesystem (mount point), not traversed"))
                continue
            if erel in info["submodules"]:
                rows.append(("submodule", erel, "-", "-", info["submodules"][erel], "tracked-clean",
                             "gitlink; working tree not traversed"))
                continue
            reason = excluded_reason(full, d)
            if reason:
                rows.append(("excluded", erel + "/", "-", "-", "-", "-", "reason=" + reason))
                continue
            if is_build_dir(full, d):
                inventory_build(full, rel)
                continue
            keep.append(d)
        dn[:] = keep
        for f in sorted(fn):
            rows.append(file_row(os.path.join(dp, f)))

    present = set(r[1] for r in rows)
    final = []
    for r in rows:
        kind, p, size, sha, blob, state, note = r
        if kind in ("source", "binary", "model", "symlink"):
            if not info["repo"]:
                state = "n/a"
            elif p in info["index"]:
                if info["fmt"] not in ("sha1", "sha256") or blob in ("NOT-COMPUTED", "-"):
                    state = "tracked-unchecked"
                else:
                    state = "tracked-clean" if blob == info["index"][p] else "tracked-modified"
            elif p in info["untracked"]:
                state = "untracked"
            elif p in info["ignored"]:
                state = "ignored"
            elif any(p.startswith(n) for n in info["nested"]):
                state = "untracked-nested-repo"
            else:
                state = "unknown"
        final.append((kind, p, size, sha, blob, state, note))
    for p in sorted(info["deleted"]):
        if p not in present:
            final.append(("missing", p, "-", "-", info["index"].get(p, "-"), "missing",
                          "tracked-in-index-but-absent-locally"))
    final.sort(key=lambda r: (r[1], r[0]))

    if info["repo"]:
        modified = sum(1 for r in final if r[5] == "tracked-modified")
        missing = sum(1 for r in final if r[0] == "missing")
        info["dirty"] = str(modified + missing + len(info["untracked"]) + len(info["nested"]))

    with io.open(out, "x", encoding="utf-8", newline="\n") as handle:
        header = [("leah-manifest", "3"), ("label", label),
                  ("root_name", esc(os.path.basename(root))),
                  ("created", time.strftime("%Y-%m-%dT%H:%M:%S%z")),
                  ("hash_models", "1" if hash_models else "0"),
                  ("git_repo", "1" if info["repo"] else "0"),
                  ("git_object_format", info["fmt"]), ("blob_algorithm", alg),
                  ("git_head", info["head"]),
                  ("git_branch", esc(info["branch"])), ("git_dirty_entries", info["dirty"]),
                  ("lfs_gitattributes", "1" if info["lfs"] else "0"),
                  ("modes_recorded", "1")]
        for k, v in header:
            handle.write("#%s\t%s\n" % (k, v))
        for r in final:
            handle.write("\t".join(r) + "\n")
        handle.write("#end\t%d\n" % len(final))

    for r in final:
        counts[r[0]] = counts.get(r[0], 0) + 1
    states = {}
    for r in final:
        if r[5] not in ("-",):
            states[r[5]] = states.get(r[5], 0) + 1
    print("manifest: %d records -> %s" % (len(final), os.path.basename(out)))
    print("  by kind : " + ", ".join("%s=%d" % kv for kv in sorted(counts.items())))
    if info["repo"]:
        print("  git     : object format=%s, branch=%s, HEAD=%s, uncommitted entries=%s (counted by this tool, not git status)"
              % (info["fmt"], esc(info["branch"]), info["head"][:12], info["dirty"]))
        print("  git state: " + ", ".join("%s=%d" % kv for kv in sorted(states.items())))
        if info["fmt"] != "sha1":
            print("  WARNING: object format is %s; GitHub blob comparison is NOT supported." % info["fmt"])
    else:
        print("  not a git repository (or inside a larger one): no git state available")
    for p in info["problems"]:
        print("  note    : " + p)
    lfs = [r[1] for r in final if "lfs-pointer" in r[6].split(";")]
    print("  lfs pointer files: %d (gitattributes uses lfs: %s)" % (len(lfs), "yes" if info["lfs"] else "no"))
    excl = [r for r in final if r[0] == "excluded"]
    print("  excluded directories (reason shown, nothing omitted silently):")
    for r in excl[:30]:
        print("    %s  %s" % (r[1], r[6]))
    if len(excl) > 30:
        print("    ... %d more" % (len(excl) - 30))
    for title, wanted in (("modified (differs from git index)", "tracked-modified"),
                          ("untracked", "untracked"), ("tracked but missing locally", "missing")):
        names = [r[1] for r in final if r[5] == wanted]
        if names:
            print("  %s: %d" % (title, len(names)))
            for n in names[:20]:
                print("    " + n)
            if len(names) > 20:
                print("    ... %d more" % (len(names) - 20))
    bad = [r for r in final if r[0] == "unreadable"]
    if bad:
        print("  UNREADABLE entries: %d" % len(bad))
        for r in bad[:20]:
            print("    %s  (%s)" % (r[1], r[6]))


SECRET_PATTERNS = [
    ("private-key-block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("aws-access-key-id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}")),
    ("slack-token", re.compile(r"xox[abprs]-[A-Za-z0-9-]{10,}")),
    ("api-key-like (sk-)", re.compile(r"sk-[A-Za-z0-9_-]{20,}")),
    ("authorization-header", re.compile(r"authorization\s*[:=]\s*[\"']?(bearer|basic|token)\s+\S{8,}", re.I)),
    ("url-embedded-credentials", re.compile(r"://[^/\s:@]+:[^/\s@]{3,}@")),
    ("credential-assignment", re.compile(
        r"(api[_-]?key|secret|passwd|password|token)\w*\s*[:=]\s*[\"'][^\"']{6,}[\"']", re.I)),
]


def read_nofollow(path, limit):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        return handle.read(limit + 1)


def cmd_secrets(root):
    root = os.path.abspath(root)
    rootdev = os.lstat(root).st_dev
    findings, envfiles = [], []
    scanned = skipped_bin = skipped_big = skipped_err = skipped_models = 0
    skipped_dirs = 0
    for dp, dn, fn in os.walk(root, followlinks=False):
        keep = []
        for d in sorted(dn):
            full = os.path.join(dp, d)
            try:
                st = os.lstat(full)
            except OSError:
                skipped_err += 1
                continue
            if (stat.S_ISLNK(st.st_mode) or st.st_dev != rootdev or excluded_reason(full, d)
                    or is_build_dir(full, d)):
                skipped_dirs += 1
                continue
            keep.append(d)
        dn[:] = keep
        for f in sorted(fn):
            full = os.path.join(dp, f)
            erel = esc(os.path.relpath(full, root))
            try:
                st = os.lstat(full)
                if not stat.S_ISREG(st.st_mode):
                    continue
                if f.startswith(".env"):
                    envfiles.append("%s  mode=%s" % (erel, oct(st.st_mode & 0o777)))
                if f.lower().endswith(MODEL_EXT):
                    skipped_models += 1
                    continue
                if st.st_size > 1024 * 1024:
                    skipped_big += 1
                    continue
                data = read_nofollow(full, 1024 * 1024)
            except OSError:
                skipped_err += 1
                continue
            if len(data) > 1024 * 1024:
                skipped_big += 1
                continue
            if b"\0" in data[:4096]:
                skipped_bin += 1
                continue
            scanned += 1
            for num, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                line = line[:2000]
                for category, rx in SECRET_PATTERNS:
                    if rx.search(line):
                        findings.append((category, erel, num))
    print("NOTE: scanning is HEURISTIC. It cannot guarantee that every secret is found and may")
    print("      report false positives. Only category, file and line are shown, never the value.")
    print("  files scanned: %d | skipped: binary=%d, over-1MB=%d, model=%d, unreadable=%d, "
          "excluded/generated dirs=%d" % (scanned, skipped_bin, skipped_big, skipped_models,
                                         skipped_err, skipped_dirs))
    totals = {}
    for c, _, _ in findings:
        totals[c] = totals.get(c, 0) + 1
    print("  findings: %d  %s" % (len(findings), ", ".join("%s (%d)" % kv for kv in sorted(totals.items()))))
    for c, p, n in findings[:100]:
        print("    [%s] %s:%d" % (c, p, n))
    if len(findings) > 100:
        print("    ... %d more" % (len(findings) - 100))
    print("  .env-style files present (contents not shown): %d" % len(envfiles))
    for e in envfiles:
        print("    " + e)


def main():
    cmd = sys.argv[1]
    if cmd == "manifest":
        cmd_manifest(sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5])
    elif cmd == "secrets":
        cmd_secrets(sys.argv[2])


if __name__ == "__main__":
    main()
PYEOF
true

{
echo "LEAH audit v3   host=$HOST   time=$TS"
echo "repo=$REPO   backup=$BACKUP"
echo "options: probe=$PROBE hash_models=$HASHM remote=$REMOTE"
echo "READ-ONLY run. Report is passed through a redaction filter. Active tests: probe=$PROBE remote=$REMOTE."

section "HOST"
grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null
uname -srm
lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)|Architecture'
grep -m1 -E '^(Model|Hardware)' /proc/cpuinfo 2>/dev/null
free -m 2>/dev/null | sed -n '1,2p'
df -h "$REPO" 2>/dev/null | tail -1
echo "running as root: $([ "$(id -u)" = "0" ] && echo YES || echo no)"
command -v vcgencmd >/dev/null 2>&1 && vcgencmd measure_temp

section "TOOLCHAIN"
for t in python3 gcc g++ cmake make git; do
    printf '%s: ' "$t"
    if command -v "$t" >/dev/null 2>&1; then "$t" --version 2>&1 | head -1; else echo missing; fi
done

section "REPO FOLDER TOP LEVEL (names, modes, sizes)"
find -H "$REPO" -xdev -maxdepth 1 -mindepth 1 -printf '  %M %9s  %f\n' 2>/dev/null | sort -k3

section "GIT STATE (local, read-only)"
if g -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Branch      : $(g -C "$REPO" rev-parse --abbrev-ref HEAD 2>&1)"
    echo "HEAD        : $(g -C "$REPO" rev-parse HEAD 2>&1)"
    FMT="$(g -C "$REPO" rev-parse --show-object-format 2>/dev/null || g -C "$REPO" config --get extensions.objectformat 2>/dev/null || echo sha1)"
    echo "Object format: $FMT"
    [ "$FMT" != "sha1" ] && echo "  WARNING: SHA-256 repositories are unsupported for GitHub blob comparison (hashes are SHA-1)."
    echo "Remotes (credentials in URLs are redacted):"
    g -C "$REPO" remote -v 2>&1 | sed -E 's#(://)[^/@[:space:]]+@#\1***REDACTED***@#g' | sed 's/^/  /'
    echo "Local branches:"; g -C "$REPO" branch 2>&1 | sed 's/^/  /'
    echo "Commit count: $(g -C "$REPO" rev-list --count HEAD 2>/dev/null)"
    echo "Last 10 commits:"; g -C "$REPO" log --oneline -10 2>&1 | sed 's/^/  /'
else
    echo "NOT a git repository (or git unavailable)."
fi

section "GITHUB REFERENCE (read-only; freshness explained)"
if g -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CACHED="$(g -C "$REPO" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)"
    GITDIR="$(g -C "$REPO" rev-parse --git-dir 2>/dev/null)"
    case "$GITDIR" in /*) ;; *) GITDIR="$REPO/$GITDIR" ;; esac
    if [ -n "$CACHED" ]; then
        echo "CACHED reference origin/main = $CACHED"
        echo "  commit date : $(g -C "$REPO" log -1 --format=%cI "$CACHED" 2>/dev/null)"
        if [ -e "$GITDIR/FETCH_HEAD" ]; then echo "  last fetch  : $(stat -c %y "$GITDIR/FETCH_HEAD" 2>/dev/null)"; else echo "  last fetch  : no FETCH_HEAD found (never fetched, or unknown)"; fi
        echo "  This is a LOCAL COPY of GitHub's state as of the last fetch. It may be STALE."
        echo "  ahead/behind HEAD vs cached origin/main: $(g -C "$REPO" rev-list --left-right --count HEAD...origin/main 2>&1)"
        TREEFILE="$OUT/cached_origin_main_tree.bin"
        if g -C "$REPO" ls-tree -r -z origin/main > "$TREEFILE" 2>/dev/null; then
            echo "  cached tree saved (NUL-separated) for leah_compare.py: $(basename "$TREEFILE")"
        fi
    else
        echo "No cached origin/main reference exists locally (never fetched, or different branch name)."
        echo "No GitHub comparison is possible without approval to fetch or a freshly retrieved tree."
    fi
    if [ "$REMOTE" = "1" ]; then
        echo "FRESH (retrieved now with git ls-remote, ACTIVE network check, 20 s limit):"
        FRESH="$(timeout 20 git -c core.fsmonitor=false -c credential.helper= -C "$REPO" ls-remote origin refs/heads/main 2>&1 | head -3)"
        echo "$FRESH" | sed 's/^/  /'
        FRESHSHA="$(echo "$FRESH" | awk 'NF==2 && length($1)>=40 {print $1; exit}')"
        if [ -n "$FRESHSHA" ] && [ -n "$CACHED" ]; then
            [ "$FRESHSHA" = "$CACHED" ] && echo "  RESULT: cached origin/main MATCHES GitHub's current main." \
                                         || echo "  RESULT: cached origin/main is STALE (differs from GitHub's current main)."
        fi
    else
        echo "Fresh remote check not requested (use --remote). Nothing was fetched."
    fi
else
    echo "Not a git repository."
fi

section "SUBMODULES (handled separately)"
if [ -f "$REPO/.gitmodules" ]; then echo ".gitmodules present."; else echo "no .gitmodules"; fi
g -C "$REPO" submodule status 2>&1 | sed 's/^/  /' | head -20
echo "  (prefix: ' ' matches recorded commit, '+' differs, '-' not initialised, 'U' conflict)"

section "GIT LFS"
if [ ! -L "$REPO/.gitattributes" ] && grep -qs 'filter=lfs' "$REPO/.gitattributes" 2>/dev/null; then
    echo "  .gitattributes uses Git LFS. LFS files appear in GitHub trees as small pointer files;"
    echo "  a local file with real content will show a different hash than the pointer. That is"
    echo "  an LFS limitation, not necessarily a real difference."
else
    echo "  .gitattributes does not reference Git LFS."
fi

section "FILES TRACKED BY GIT THAT SHOULD PROBABLY NOT BE (names only)"
g -C "$REPO" ls-files -z 2>/dev/null | tr '\0' '\n' \
  | grep -Ei '(^|/)\.env|\.(gguf|onnx|pt|pth|wav|mp3|ogg|db|sqlite3?|log|pem|key)$|^(data|models|voices|backups)/' \
  | grep -Ev '\.gitkeep$' | sed 's/^/  /'
echo "  (end of list)"
echo ".gitignore coverage check (read-only 'git check-ignore'):"
for f in .env .env.local x.pem x.key m.gguf m.onnx data/x.json x.sqlite; do
    if g -C "$REPO" check-ignore -q "$f" 2>/dev/null; then echo "  ignored      $f"; else echo "  NOT ignored  $f"; fi
done

section "MANIFEST: repository (generated build dirs, venvs, caches excluded with reasons)"
python3 -c "$PYTOOL" manifest "$REPO" "$OUT/manifest_repo.tsv" "$HASHM" repo

section "MANIFEST: backup (same rules as the repository manifest)"
if [ -d "$BACKUP" ]; then
    python3 -c "$PYTOOL" manifest "$BACKUP" "$OUT/manifest_backup.tsv" "$HASHM" backup
else
    echo "No backup folder at $BACKUP"
fi

section "SECRET-LIKE CONTENT IN REPO (category + file + line only)"
python3 -c "$PYTOOL" secrets "$REPO"

section "ENTRY POINTS AND ASSISTANT SETTINGS (keyword matches only, not full lines)"
find -H "$REPO" -xdev -maxdepth 2 -type f \( -name '*.py' -o -name '*.sh' \) -not -path '*/.git/*' -not -path '*/build/*' | sort | sed 's/^/  /'
for A in "$REPO"/assistant*.py; do
    [ -f "$A" ] || continue
    if [ -L "$A" ]; then echo "--- $(basename "$A"): symlink, not followed"; continue; fi
    echo "--- $(basename "$A")"
    echo "  lines: $(wc -l < "$A")   sha256: $(sha256sum "$A" | cut -d' ' -f1)"
    grep -m1 -oE 'LEAH\.OS v[0-9][0-9.]*|VERSION *= *"[^"]+"' "$A" | sed 's/^/  version hint: /'
    if python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$A" 2>/dev/null
    then echo "  syntax: OK on this python3 (parsed only, not executed)"; else echo "  syntax: FAILS on this python3"; fi
    echo "  setting keywords (line:match):"
    grep -noE '(-c +[0-9]+|-t +[0-9]+|-n +[0-9]+|--ctx-size[ =]+[0-9]+|--temp[ =]+[0-9.]+|timeout *= *[0-9]+|n_predict *= *[0-9]+|max_tokens *= *[0-9]+|shell=True|os\.system|0\.0\.0\.0|subprocess\.[a-z_]+|llama-cli|llama-server|[A-Za-z0-9_.-]+\.gguf)' "$A" | sed 's/^/    /' | head -40
done

section "LLAMA.CPP SOURCE TREES"
find -H "$REPO" -xdev -maxdepth 5 -name CMakeLists.txt -type f -not -path '*/build/*' 2>/dev/null | while read -r cm; do
    d="$(dirname "$cm")"
    if [ -d "$d/common" ] && { [ -d "$d/ggml" ] || [ -f "$d/ggml.c" ]; }; then
        echo "Source tree: ${d#$REPO/}"
        if [ -e "$d/.git" ]; then
            echo "  describe: $(g -C "$d" describe --tags --always 2>/dev/null)   commit: $(g -C "$d" rev-parse --short HEAD 2>/dev/null)"
            echo "  tracked files MISSING from disk (completeness signal): $(g -C "$d" ls-files -d -z 2>/dev/null | tr -cd '\0' | wc -c)"
            echo "  untracked files: $(g -C "$d" ls-files -o --exclude-standard -z 2>/dev/null | tr -cd '\0' | wc -c)   (modified files are not checked: that needs git status, which can run filters)"
        else
            echo "  (no .git inside; revision cannot be confirmed)"
        fi
        for k in common ggml src examples include; do [ -e "$d/$k" ] && echo "  has $k" || echo "  MISSING $k"; done
        echo "  regex patch line(s):"
        grep -n 'GRAMMAR_RANGE_LITERAL_ESCAPE_RE' "$d/common/json-schema-to-grammar.cpp" 2>/dev/null | head -3 | sed 's/^/    /'
    fi
done

section "LLAMA BINARIES (inventory only; not executed unless --probe)"
BINS="$(find -H "$REPO" -xdev -maxdepth 8 -type f \( -name llama-cli -o -name llama-server -o -name llama-bench \) 2>/dev/null | sort)"
[ -z "$BINS" ] && echo "  none found"
while read -r b; do
    [ -n "$b" ] || continue
    echo "--- ${b#$REPO/}"
    stat -c '  mode=%A size=%s bytes' "$b"
    file "$b" 2>/dev/null | sed 's/^[^:]*: /  type: /'
    command -v readelf >/dev/null 2>&1 && readelf -h "$b" 2>/dev/null | grep -E 'Class|Machine' | sed 's/^ */  /'
    [ -x "$b" ] || echo "  NOT executable"
done <<< "$BINS"

section "MODEL FILES (from the manifests; hashes only with --hash-models)"
for pair in "repo:$OUT/manifest_repo.tsv" "backup:$OUT/manifest_backup.tsv"; do
    lbl="${pair%%:*}"; mf="${pair#*:}"
    [ -f "$mf" ] || continue
    awk -F'\t' '$1=="model"{print $3"\t"$4"\t"$2}' "$mf" | while IFS=$'\t' read -r sz sha pth; do
        echo "  [$lbl] $sz bytes  $pth"
        if [ "$sha" = "NOT-COMPUTED" ]; then
            echo "    sha256: not computed (use --hash-models)"
        else
            echo "    sha256: $sha"
            if [ -n "$EXPECT_SHA" ]; then
                [ "$sha" = "$EXPECT_SHA" ] && echo "    MATCHES expected hash" || echo "    DIFFERS from expected hash"
            fi
        fi
    done
done

section "SECURITY POSTURE (read-only)"
echo "Listening sockets (no process names):"; (ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null) | sed 's/^/  /'
echo "LEAH/llama-related processes (pid, user, name, executable path; arguments are never shown):"
ps -eo pid=,user=,comm=,args= 2>/dev/null | while read -r pid user comm rest; do
    case "$rest" in *leah_audit*) continue ;; esac
    case "$rest" in *[Ll][Ee][Aa][Hh]*|*llama*|*assistant.py*) ;; *) continue ;; esac
    [ "$pid" = "$$" ] && continue
    printf '  pid=%s user=%s name=%s exe=%s\n' "$pid" "$user" "$comm" "$(readlink "/proc/$pid/exe" 2>/dev/null || echo unavailable)"
done
echo "Scheduled jobs (user crontab; arguments hidden):"
CT="$(crontab -l 2>/dev/null)"
if [ -z "$CT" ]; then
    echo "  no user crontab entries (or crontab unavailable)"
else
    printf '%s\n' "$CT" | awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {next}
        { total++; low=tolower($0); related=(low ~ /leah|llama|assistant\.py/)
          if ($1 ~ /^@/) { sched=$1; cmd=$2 } else { sched=$1" "$2" "$3" "$4" "$5; cmd=$6 }
          n=split(cmd, parts, "/"); base=parts[n]
          if (related) { lr++; printf "  LEAH-related job: schedule=[%s] program=%s (arguments hidden)\n", sched, base } }
        END { printf "  total entries: %d, LEAH-related: %d (other commands are not shown)\n", total, lr+0 }'
fi
echo "systemd unit names mentioning leah:"; systemctl list-unit-files 2>/dev/null | grep -i leah | awk '{print "  "$1" "$2}'
echo "SSH daemon (3 setting names only; global section; effective values need 'sshd -T' as root):"
SSHD="${LEAH_AUDIT_SSHD_CONFIG:-/etc/ssh/sshd_config}"
for f in "$SSHD" "$SSHD".d/*.conf; do
    [ -r "$f" ] || continue
    awk -v src="$(basename "$f")" '
        { k=tolower($1) }
        k=="match" { exit }
        k=="passwordauthentication" || k=="permitrootlogin" || k=="pubkeyauthentication" { printf "  [%s] %s = %s\n", src, $1, $2 }' "$f"
done
echo "Permissions of data/ and .env files (no owner names, no contents):"
stat -c '  %A %n' "$REPO/data" "$REPO"/.env* 2>/dev/null
echo "Firewall (readable only as root; no changes made):"
(timeout 5 ufw status 2>&1 | head -2) | sed 's/^/  /'

if [ "$PROBE" = "1" ]; then
    section "PROBE (ACTIVE TEST: executes llama binaries; consumes CPU and memory)"
    while read -r b; do
        [ -n "$b" ] && [ -x "$b" ] || continue
        echo "--- ${b#$REPO/}"
        ldd "$b" 2>&1 | grep -i 'not found' | sed 's/^/  MISSING LIB: /'
        timeout 10 "$b" --version 2>&1 | head -3 | sed 's/^/  --version: /'
    done <<< "$BINS"
    BIN="$(echo "$BINS" | grep 'build/bin/llama-cli' | head -1)"
    [ -z "$BIN" ] && BIN="$(echo "$BINS" | grep 'llama-cli' | head -1)"
    MODEL="$(find "$REPO/models" -maxdepth 1 -type f -name '*.gguf' 2>/dev/null | head -1)"
    if [ -z "$BIN" ] || [ -z "$MODEL" ]; then
        echo "  Generation test skipped (binary found: $([ -n "$BIN" ] && echo yes || echo no), model found: $([ -n "$MODEL" ] && echo yes || echo no))"
    else
        echo "  binary: ${BIN#$REPO/}"; echo "  model : ${MODEL#$REPO/}"
        T0="$(date +%s.%N)"
        timeout 180 "$BIN" -m "$MODEL" -p "Hello" -n 16 -c 256 -t 2 < /dev/null 2>&1 | redact > "$OUT/probe_output.txt"
        RC=${PIPESTATUS[0]}
        T1="$(date +%s.%N)"
        echo "  exit status: $RC   (0 = success, 124 = timed out, other = failure)"
        echo "  elapsed seconds: $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f", b-a}')"
        echo "  key lines:"
        grep -iE 'error|what\(\)|terminate|regex|load time|eval time|tokens per second' "$OUT/probe_output.txt" | head -12 | cut -c1-160 | sed 's/^/    /'
        echo "  output saved: probe_output.txt"
    fi
fi

section "END"
echo "Report folder: ${OUT#$HOME/}   (inside your home directory)"
} 2>&1 | redact | tee "$REPORT"
