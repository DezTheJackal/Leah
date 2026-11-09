#!/usr/bin/env bash
# leah_selftest.sh v3 - synthetic test suite for leah_audit.sh and leah_compare.py.
#
# ISOLATION: everything happens inside ONE temporary folder created with mktemp under /tmp
# (leah_selftest.XXXXXX). HOME is pointed into that folder for every audit run, so your real
# ~/Leah, backups, laptop, Pi and GitHub repository are never read or changed. The suite does
# not use the network (the --remote test talks to a bare repository inside the temp folder)
# and never executes real LEAH binaries (the --probe test runs a fake script it creates).
# The only privileged-looking actions are: chmod 755 on its own temp folder, and - only when
# run as root - chown of a few test files to the 'nobody' user plus `setpriv` to run the
# audit as that user for the unreadable-file test. Nothing outside the temp folder is touched.
# Cleanup: the temp folder is deleted when all tests pass (path guarded); it is kept when any
# test fails, or when you pass --keep.
#
# Usage:  bash leah_selftest.sh [--keep]     (keep leah_audit.sh and leah_compare.py beside it)
# Needs:  bash, python3 (3.5+), git, find, sort -z, sha256sum. setpriv is optional.
set -u
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg"; exit 2 ;;
    esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$HERE/leah_audit.sh"; COMPARE="$HERE/leah_compare.py"
if [ ! -f "$AUDIT" ] || [ ! -f "$COMPARE" ]; then
    echo "Put leah_selftest.sh next to leah_audit.sh and leah_compare.py"; exit 1
fi
REALGIT="$(command -v git)" || { echo "git is required"; exit 1; }
BASE="$(mktemp -d /tmp/leah_selftest.XXXXXX)" || exit 1
chmod 755 "$BASE"
cd "$BASE" || exit 1
PASS=0; FAIL=0; SKIP=0; RC=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1  [$2]"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -Eq -- "$2" "$1"; }
hasF()  { grep -Fq -- "$2" "$1"; }
hasnt() { ! grep -Fq -- "$2" "$1"; }
count_is() { [ "$(grep -Ec -- "$2" "$1")" = "$3" ]; }
rc_is() { [ "$RC" = "$1" ]; }
section() { echo; echo "== $1"; }

cleanup_temp() {   # strictly confined to the folder this run created
    [ "$(dirname "$BASE")" = "/tmp" ] || { echo "refusing to clean unexpected path: $BASE"; return 1; }
    case "$BASE" in /tmp/leah_selftest.??????) ;; *) echo "refusing to clean unexpected path: $BASE"; return 1 ;; esac
    [ -d "$BASE" ] || return 0
    chmod -R u+rwx "$BASE" 2>/dev/null
    rm -rf -- "$BASE"
}

# ------------------------------------------------------------------ helpers (embedded Python)
cat > "$BASE/snap.py" <<'PYSNAP'
import hashlib, os, stat, sys
mode = sys.argv[1]            # "full" (hash contents) or "meta" (metadata only, the OLD behaviour)
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    name = os.fsdecode(raw).encode("unicode_escape").decode("ascii")
    try:
        st = os.lstat(raw)
    except OSError as e:
        print("UNSTATABLE\terrno=%d\t%s" % (e.errno, name))
        continue
    m = st.st_mode
    if stat.S_ISREG(m): kind = "file"
    elif stat.S_ISDIR(m): kind = "dir"
    elif stat.S_ISLNK(m): kind = "symlink"
    elif stat.S_ISFIFO(m): kind = "fifo"
    elif stat.S_ISSOCK(m): kind = "socket"
    elif stat.S_ISCHR(m): kind = "chardev"
    elif stat.S_ISBLK(m): kind = "blockdev"
    else: kind = "other"
    fields = [kind, "%04o" % (m & 0o7777), "%d:%d" % (st.st_uid, st.st_gid),
              str(st.st_size if kind == "file" else 0), str(st.st_mtime_ns)]
    extra = "-"
    if kind == "symlink":
        try:
            extra = "->" + os.fsdecode(os.readlink(raw)).encode("unicode_escape").decode("ascii")
        except OSError as e:
            extra = "READLINK-FAILED errno=%d" % e.errno
    elif kind == "file" and mode == "full":
        try:
            fd = os.open(raw, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            h = hashlib.sha256()
            with os.fdopen(fd, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    h.update(chunk)
            extra = h.hexdigest()
        except OSError as e:
            extra = "UNREADABLE errno=%d" % e.errno
    elif kind in ("chardev", "blockdev"):
        extra = "rdev=%d" % st.st_rdev
    print("\t".join(fields + [extra, name]))
PYSNAP

snap_to() {   # snap_to DIR MODE OUTFILE : null-delimited traversal, symlinks never followed
    # Errors from find (for example an unlistable directory) are NOT dropped: they are appended
    # to the snapshot as FIND-ERROR lines so an unreadable area can never be silently omitted.
    # SNAP_RUNAS (optional) is a command prefix, e.g. "setpriv ...", used to run the hasher as another user.
    {
        if [ -n "${SNAP_EXCL:-}" ]; then find "$1" -mindepth 1 -name "$SNAP_EXCL" -prune -o -mindepth 1 -print0
        else find "$1" -print0; fi
    } 2> "$BASE/.find.err" | LC_ALL=C sort -z | ${SNAP_RUNAS:-} python3 -B "$BASE/snap.py" "$2" > "$3"
    sed 's/^/FIND-ERROR\t/' "$BASE/.find.err" >> "$3"
}
snap()  { snap_to "$1" full "$BASE/.snap.tmp"; sha256sum < "$BASE/.snap.tmp" | cut -d' ' -f1; }
snapm() { snap_to "$1" meta "$BASE/.snapm.tmp"; sha256sum < "$BASE/.snapm.tmp" | cut -d' ' -f1; }
differs() { [ "$1" != "$2" ]; }
same()    { [ "$1" = "$2" ]; }

cat > "$BASE/build_env.py" <<'PYBUILD'
import os, socket, subprocess, sys
BASE = sys.argv[1]

def sh(cwd, *a):
    subprocess.check_call(list(a), cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def w(base, rel, text="", mode=None):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(text if isinstance(text, bytes) else text.encode())
    if mode:
        os.chmod(p, mode)

def init(repo):
    sh(repo, "git", "init", "-q", ".")
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")

def commit_all(repo, msg):
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", msg)

def build(home, variant):
    repo = os.path.join(home, "Leah")
    os.makedirs(repo)
    w(repo, "same.txt", "identical content\n")
    w(repo, "my file.txt", "spaces in name\n")
    w(repo, "diff.txt", "alpha\n" if variant == "A" else "beta\n")
    w(repo, "edited.txt", "v1\n")
    w(repo, "gone.txt", "will vanish\n")
    w(repo, "models/m_same_size.gguf", b"A" * 10 if variant == "A" else b"B" * 10)
    w(repo, "models/m_diff_size.gguf", b"A" * 10 if variant == "A" else b"B" * 12)
    w(repo, "big.bin", "version https://git-lfs.github.com/spec/v1\noid sha256:" + "ab" * 32 + "\nsize 123\n")
    w(repo, ".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n*.evil filter=evil\n")
    w(repo, ".gitignore", "data/*\n*.log\nmodels/*\n")
    w(repo, "assistant.py", 'import subprocess\nVERSION="4.1"\nn_predict = 96\ntimeout = 240\n'
      'subprocess.call(["curl","-H","Authorization: Bearer SECRETBEARERTOKEN123"], shell=True)\n# -n 96 -t 2\n')
    w(repo, "tab\there.txt", "tab in filename\n")
    w(repo, "x.evil", "evil v1\n")
    w(repo, "run.sh", "#!/bin/sh\n", 0o755)
    w(repo, "ok.sh", "#!/bin/sh\n", 0o755)
    w(repo, "tool.sh", "#!/bin/sh\n", 0o644)
    w(repo, "plain.sh", "#!/bin/sh\n", 0o755)
    w(repo, "build-backup/keep.txt", "not a build dir\n")
    w(repo, "mybuild/keep.txt", "not a build dir either\n")
    if variant == "A":
        w(repo, "only_laptop.txt", "laptop only\n")
        w(repo, "new\nline.txt", "newline in filename\n")
        w(repo, "esc\x1b[31mred.txt", "terminal escape in filename\n")
        w(repo, "notes.py",
          'AWS = "AKIAIOSFODNN7EXAMPLE"\nGH = "ghp_' + "a1B2c3D4e5" * 3 + 'abcdef"\npassword = "hunter2hunter2"\n'
          'URL = "https://user:SuperSecretPw@example.com/x"\n-----BEGIN RSA PRIVATE KEY-----\n')
        w(repo, ".env", 'TOKEN="verysecretvalue"\n', 0o644)
    else:
        w(repo, "only_pi.txt", "pi only\n")
    os.symlink("same.txt", os.path.join(repo, "link_same"))
    os.symlink("same.txt" if variant == "A" else "diff.txt", os.path.join(repo, "link_diff"))
    if variant == "A":
        os.symlink("same.txt", os.path.join(repo, "link_vs_file"))
    else:
        w(repo, "link_vs_file", "regular on pi\n")
    os.symlink("/etc/hostname", os.path.join(repo, "link_abs"))
    os.symlink("/etc/hostname", os.path.join(repo, "assistant_link.py"))
    w(repo, "venv/pyvenv.cfg", "home = /usr/bin\n")
    w(repo, "venv/lib/x.py", "x=1\n")
    w(repo, "src/__pycache__/a.pyc", b"\0\0")
    w(repo, "node_modules/p/i.js", "1")
    w(repo, "build/bin/llama-cli", b"\x7fELF" + b"\0" * 60, 0o755)
    w(repo, "build/obj.o", b"\x7fELFobj")
    w(repo, "build/CMakeFiles/x.txt", "gen")
    w(repo, "llama-cli", b"\x7fELF" + b"\1" * 30, 0o755)
    os.makedirs(os.path.join(repo, "sub", "mod"))
    init(repo)
    sh(repo, "git", "add", "-A")
    sub = "1234567890abcdef1234567890abcdef12345678" if variant == "A" else "abcdef1234567890abcdef1234567890abcdef12"
    sh(repo, "git", "update-index", "--add", "--cacheinfo", "160000,%s,sub/mod" % sub)
    sh(repo, "git", "commit", "-qm", "first")
    sh(repo, "git", "update-ref", "refs/remotes/origin/main", "HEAD")
    sh(repo, "git", "remote", "add", "origin", "https://user:SuperSecretRemotePw@github.com/DezTheJackal/Leah.git")
    w(repo, "second.txt", "second commit\n")
    sh(repo, "git", "add", "second.txt")
    sh(repo, "git", "commit", "-qm", "second")
    # local changes made AFTER the commits
    os.chmod(os.path.join(repo, "tool.sh"), 0o755)      # executable locally, 100644 in git
    os.chmod(os.path.join(repo, "plain.sh"), 0o644)     # not executable locally, 100755 in git
    w(repo, "edited.txt", "v2 modified\n")
    os.remove(os.path.join(repo, "gone.txt"))
    w(repo, "scratch.txt", "untracked\n")
    w(repo, "data/chat.json", "private\n")
    w(repo, "run.log", "log\n")
    os.mkfifo(os.path.join(repo, "special_same"))
    if variant == "A":
        os.mkfifo(os.path.join(repo, "special_diff"))
    else:
        s = socket.socket(socket.AF_UNIX)
        s.bind(os.path.join(repo, "special_diff"))
        s.close()
    return repo

def evil_config(repo):
    """Repository-configured programs that a careless tool could trigger (git status would)."""
    w(BASE, "evil_fsmon.sh", '#!/bin/sh\ntouch "%s/marker_fsmonitor"\n' % BASE, 0o755)
    w(BASE, "evil_clean.sh", '#!/bin/sh\ntouch "%s/marker_filter"\ncat\n' % BASE, 0o755)
    sh(repo, "git", "config", "core.fsmonitor", os.path.join(BASE, "evil_fsmon.sh"))
    sh(repo, "git", "config", "filter.evil.clean", os.path.join(BASE, "evil_clean.sh"))
    w(repo, "x.evil", "evil v2\n")   # same size as v1, so git must run the clean filter to compare

for name, variant in (("laptop", "A"), ("pi", "B")):
    home = os.path.join(BASE, name + "_home")
    os.makedirs(home)
    repo = build(home, variant)
    if name == "laptop":
        import shutil
        shutil.copytree(repo, os.path.join(home, "Backups", "Leah"), symlinks=True, ignore=shutil.ignore_patterns("special_*"))
        w(os.path.join(home, "Backups", "Leah"), "backup_only.txt", "only in backup\n")
        evil_config(repo)

# repository containing a NESTED llama.cpp-like repo (not a submodule) and a fake llama-cli
ph = os.path.join(BASE, "probe_home")
outer = os.path.join(ph, "Leah")
os.makedirs(outer)
w(outer, "README.md", "outer repo\n")
w(outer, ".gitignore", "models/*\n")
w(outer, "models/tiny.gguf", b"GGUF" + b"\0" * 20)
nested = os.path.join(outer, "ai-engine", "llama-legacy")
w(nested, "CMakeLists.txt", "project(x)\n")
w(nested, "common/json-schema-to-grammar.cpp", 'std::regex GRAMMAR_RANGE_LITERAL_ESCAPE_RE("[]\\\\r\\\\n]");\n')
w(nested, "ggml/ggml.c", "int x;\n")
w(nested, "src/x.cpp", "int y;\n")
w(nested, "examples/main.cpp", "int z;\n")
w(nested, "include/llama.h", "int w;\n")
w(nested, ".gitignore", "build/\n")
init(nested)
commit_all(nested, "nested")
os.remove(os.path.join(nested, "src", "x.cpp"))                # a tracked file missing on disk
w(BASE, "evil_fsmon_nested.sh", '#!/bin/sh\ntouch "%s/marker_nested_fsmonitor"\n' % BASE, 0o755)
sh(nested, "git", "config", "core.fsmonitor", os.path.join(BASE, "evil_fsmon_nested.sh"))
w(nested, "build/bin/llama-cli",
  '#!/bin/sh\ntouch "%s/marker_probe"\necho "llama_print_timings: eval time = 1 ms / 1 runs"\nexit 0\n' % BASE, 0o755)
init(outer)
sh(outer, "git", "add", "README.md", ".gitignore")
sh(outer, "git", "commit", "-qm", "outer")

# repository with a LOCAL bare remote (for the --remote test, no network involved)
rh = os.path.join(BASE, "remote_home")
rr = os.path.join(rh, "Leah")
os.makedirs(rr)
w(rr, "a.txt", "one\n")
init(rr)
commit_all(rr, "one")
sh(BASE, "git", "init", "-q", "--bare", os.path.join(BASE, "bare.git"))
sh(rr, "git", "remote", "add", "origin", os.path.join(BASE, "bare.git"))
sh(rr, "git", "push", "-q", "origin", "HEAD:refs/heads/main")
sh(rr, "git", "update-ref", "refs/remotes/origin/main", "HEAD")

# repository for the unreadable-file test (permissions are applied by the shell)
uh = os.path.join(BASE, "unread_home")
ur = os.path.join(uh, "Leah")
os.makedirs(ur)
w(ur, "ok.txt", "readable\n")
w(ur, "secret.txt", "cannot be read\n")
w(ur, "locked/inner.txt", "inside\n")
init(ur)
commit_all(ur, "u")

# SHA-256 object-format repository (needs git >= 2.29)
r = os.path.join(BASE, "sha256_home", "Leah")
os.makedirs(r)
try:
    sh(r, "git", "init", "-q", "--object-format=sha256", ".")
    w(r, "a.txt", "x\n")
    sh(r, "git", "add", "-A")
    sh(r, "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x")
    print("sha256 repo created")
except Exception as e:
    print("sha256 repo NOT supported by this git")
PYBUILD

cat > "$BASE/unit.py" <<'PYUNIT'
import contextlib, importlib.util, io, os, sys
spec = importlib.util.spec_from_file_location("pytool", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
base = sys.argv[2]

def manifest(root, name):
    out = os.path.join(base, name)
    with contextlib.redirect_stdout(io.StringIO()):
        mod.cmd_manifest(root, out, False, "t")
    with open(out, encoding="utf-8") as handle:
        return dict((r[1], r) for r in (l.rstrip("\n").split("\t") for l in handle) if len(r) == 7)

# 1. file that changes while it is being hashed
root = os.path.join(base, "race_tree")
os.makedirs(root)
with open(os.path.join(root, "racy.txt"), "wb") as f: f.write(b"x" * 100)
with open(os.path.join(root, "calm.txt"), "wb") as f: f.write(b"y")
def hook(path):
    if path.endswith("racy.txt"):
        with open(path, "ab") as f: f.write(b"APPENDED")
mod._after_first_chunk = hook
rows = manifest(root, "race.tsv")
mod._after_first_chunk = None
print("RACE racy=%s/%s calm=%s" % (rows["racy.txt"][0], rows["racy.txt"][6], rows["calm.txt"][0]))

# 2. a directory on another filesystem (SIMULATED by faking st_dev; no real mount is created)
root2 = os.path.join(base, "mount_tree")
os.makedirs(os.path.join(root2, "fakemount"))
with open(os.path.join(root2, "fakemount", "inside.txt"), "w") as f: f.write("hidden")
with open(os.path.join(root2, "outside.txt"), "w") as f: f.write("seen")
real = os.lstat
def fake(path, *a, **k):
    st = real(path, *a, **k)
    if str(path).endswith("fakemount"):
        vals = list(st)
        vals[2] = st.st_dev + 1
        return os.stat_result(vals)
    return st
os.lstat = fake
rows2 = manifest(root2, "mount.tsv")
os.lstat = real
print("MOUNT excluded=%s note=%s inside_listed=%s outside=%s" % (
    "fakemount/" in rows2, rows2["fakemount/"][6][:40] if "fakemount/" in rows2 else "-",
    "fakemount/inside.txt" in rows2, "outside.txt" in rows2))

# 3. a symlink swapped in for a regular file between lstat and open is refused (O_NOFOLLOW)
import errno
root3 = os.path.join(base, "swap_tree")
os.makedirs(root3)
victim = os.path.join(root3, "victim.txt")
other = os.path.join(root3, "other_name.txt")
with open(victim, "w") as f: f.write("original")
st = os.lstat(victim)
os.link(victim, other)            # same inode under another name
os.remove(victim)
os.symlink(other, victim)         # symlink now sits where the regular file was; following it reaches the SAME inode
try:
    mod.hash_regular(victim, st, True, "sha1")
    print("SWAP followed-symlink")
except OSError as e:
    print("SWAP refused %s" % errno.errorcode.get(e.errno, e.errno))
except mod.Changed:
    print("SWAP refused-by-inode-check-only")
PYUNIT

cat > "$BASE/mkcx.py" <<'PYCX'
import hashlib, os, sys
base = sys.argv[1]
os.makedirs(base, exist_ok=True)
H = lambda c: c * 64
B = lambda c: c * 40
def blob(data, alg="sha1"):
    return hashlib.new(alg, b"blob %d\0" % len(data) + data).hexdigest()
HEAD = B("1")
HDR = [("leah-manifest", "3"), ("label", "x"), ("created", "t"), ("hash_models", "0"), ("git_repo", "1"),
       ("git_object_format", "sha1"), ("blob_algorithm", "sha1"), ("git_head", HEAD),
       ("git_dirty_entries", "0"), ("lfs_gitattributes", "0"), ("modes_recorded", "1")]
def header(**kw):
    d = dict(HDR); d.update(kw)
    out = [(k, d[k]) for k, _ in HDR if d[k] is not None]
    return out + [(k, v) for k, v in kw.items() if k not in dict(HDR)]
def write(name, rows, hdr=None, end="auto"):
    lines = ["#%s\t%s" % kv for kv in (hdr if hdr is not None else header())]
    lines += [r if isinstance(r, str) else "\t".join(r) for r in rows]
    if end == "auto": lines.append("#end\t%d" % len(rows))
    elif end is not None: lines.append("#end\t%s" % end)
    with open(os.path.join(base, name), "w") as f: f.write("\n".join(lines) + "\n")
R = lambda kind, path, size="-", sha="-", b="-", state="-", note="-": (kind, path, str(size), sha, b, state, note)
def F(path, content, state="tracked-clean", note="-", kind="source", sha=None, b=None):
    d = content if isinstance(content, bytes) else content.encode()
    return R(kind, path, len(d), sha or hashlib.sha256(d).hexdigest(), b or blob(d), state, note)
def L(path, target, state="tracked-clean", flags="none"):
    t = target.encode()
    return R("symlink", path, len(t), "-", blob(t), state, "flags=%s|target=%s" % (flags, target))
def M(path, size, sha="NOT-COMPUTED", state="ignored"):
    return R("model", path, size, sha, "NOT-COMPUTED", state, "hash-not-requested" if sha == "NOT-COMPUTED" else "-")
SUB = lambda path, commit: R("submodule", path, "-", "-", commit, "tracked-clean", "gitlink; working tree not traversed")
SP = lambda path, t: R("special", path, "-", "-", "-", "-", "type=" + t)
U = lambda path: R("unreadable", path, "-", "-", "-", "-", "open errno=13")
MS = lambda path: R("missing", path, "-", "-", B("9"), "missing", "tracked-in-index-but-absent-locally")
X = lambda path, reason: R("excluded", path, "-", "-", "-", "-", "reason=" + reason)

# C1: every comparison bucket exactly once (16 paths)
write("c1_a.tsv", [F("same.txt", "S"), F("diff.txt", "alpha"), F("only_a.txt", "oa"), M("m_same.gguf", 10), M("m_diff.gguf", 10),
    L("lnk_same", "same.txt"), L("lnk_diff", "same.txt"), SUB("sub_same", B("a")), SUB("sub_diff", B("a")),
    SP("fifo_same", "fifo"), SP("fifo_diff", "fifo"), F("file_vs_link", "x"), F("file_vs_sub", "y"), MS("gone.txt"), U("unr.txt")])
write("c1_b.tsv", [F("same.txt", "S"), F("diff.txt", "beta"), F("only_b.txt", "ob"), M("m_same.gguf", 10), M("m_diff.gguf", 12),
    L("lnk_same", "same.txt"), L("lnk_diff", "diff.txt"), SUB("sub_same", B("a")), SUB("sub_diff", B("b")),
    SP("fifo_same", "fifo"), SP("fifo_diff", "socket"), L("file_vs_link", "same.txt"), SUB("file_vs_sub", B("a")),
    F("gone.txt", "g"), F("unr.txt", "u")])
write("good.tsv", [F("good1.txt", "g1"), F("good2.txt", "g2"), F("file1", "f1"), F("dup.txt", "d")])

# C2: 24 bad records, each must produce exactly ONE error
bad = [
 R("source", "bad_upper.txt", 5, "A" * 64, B("a"), "tracked-clean"),
 R("source", "bad_len.txt", 5, "a" * 63, B("a"), "tracked-clean"),
 R("source", "bad_blob_len.txt", 5, H("a"), "b" * 64, "tracked-clean"),
 R("source", "bad_blob_hex.txt", 5, H("a"), "z" * 40, "tracked-clean"),
 R("source", "bad_size.txt", "12x", H("a"), B("a"), "tracked-clean"),
 R("symlink", "sl_notarget", 1, "-", blob(b"a"), "tracked-clean", "flags=none|target="),
 R("symlink", "sl_size", 99, "-", blob(b"a"), "tracked-clean", "flags=none|target=a"),
 R("symlink", "sl_blob", 1, "-", blob(b"zzz"), "tracked-clean", "flags=none|target=a"),
 R("symlink", "sl_flags", 1, "-", blob(b"a"), "tracked-clean", "flags=weird|target=a"),
 R("submodule", "sm_short", "-", "-", "abc", "tracked-clean", "gitlink"),
 R("submodule", "sm_size", 5, "-", B("c"), "tracked-clean", "gitlink"),
 R("model", "m_hash.gguf", 10, H("c"), "NOT-COMPUTED", "ignored", "-"),
 R("source", "trk_nc.txt", 5, H("d"), "NOT-COMPUTED", "tracked-clean", "-"),
 R("excluded", "nodir", "-", "-", "-", "-", "reason=x"),
 R("special", "sp_size", 5, "-", "-", "-", "type=fifo"),
 R("missing", "ms_state", "-", "-", "-", "tracked-clean", "x"),
 R("unreadable", "un_sha", 5, H("e"), "-", "-", "open errno=13"),
 R("mystery", "x_kind", 1),
 "source\tshort\trow",
 F("dup.txt", "d"), F("dup.txt", "d"),
 F("file1", "f1"), F("file1/child", "c"),
 X("venv/", "python virtual environment"), F("venv/x.py", "x"),
 F("/abs.txt", "a"), F("a/../b.txt", "b"),
 F("good1.txt", "g1"), F("good2.txt", "g2"),
]
write("c2_invalid.tsv", bad)
open(os.path.join(base, "c2_expected.txt"), "w").write("24\n")

# C3: incomplete manifests
rows = [F("a.txt", "a"), F("b.txt", "b")]
write("c3_noend.tsv", rows, end=None)
write("c3_badcount.tsv", rows, end="99")
full = "\n".join(["#%s\t%s" % kv for kv in header()] + ["\t".join(r) for r in rows] + ["#end\t2"]) + "\n"
open(os.path.join(base, "c3_trunc.tsv"), "w").write(full[:-38])
open(os.path.join(base, "c3_zero.tsv"), "w").close()
write("c3_headeronly.tsv", [])
write("c3_nomagic.tsv", rows, hdr=[(k, v) for k, v in HDR if k != "leah-manifest"])

# C9 / C10: header contradictions
write("c9_contra.tsv", [F("t.txt", "t"), M("m.gguf", 10, state="n/a")], hdr=header(git_repo="0", hash_models="1"))
write("c10_alg.tsv", [F("a.txt", "a", b=B("a")), F("b.txt", "b", b=blob(b"b", "sha256"))], hdr=header(blob_algorithm="sha256"))

# GitHub trees
def T(mode, typ, sha, path):
    return ("%s %s %s\t" % (mode, typ, sha)).encode() + (path if isinstance(path, bytes) else path.encode())
def tree(name, entries):
    open(os.path.join(base, name), "wb").write(b"\0".join(entries) + b"\0")
# C4: component-aware exclusion
write("c4_local.tsv", [F("keep.txt", "k"), X("build/", "generated build directory; 1 binaries inventoried, 3 other generated files not listed"),
                       F("build/bin/tool", b"ELF", kind="binary")])
tree("c4_tree.bin", [T("100644", "blob", blob(b"k"), "keep.txt"), T("100644", "blob", blob(b"ELF"), "build/bin/tool"),
                     T("100644", "blob", B("5"), "build/a.o"), T("100644", "blob", B("5"), "build-backup/b.txt"),
                     T("100644", "blob", B("5"), "mybuild/c.txt")])
# C5: mode/type validation
write("c5_local.tsv", [F("a.txt", "a"), F("run.sh", "r", note="exec"), L("link", "a.txt"), SUB("subm", B("c"))])
tree("c5_tree.bin", [T("100644", "blob", blob(b"a"), "a.txt"), T("100755", "blob", blob(b"r"), "run.sh"),
                     T("120000", "blob", blob(b"a.txt"), "link"), T("160000", "commit", B("c"), "subm"),
                     T("040000", "tree", B("7"), "somedir"),
                     T("100644", "commit", B("5"), "bad1"), T("160000", "blob", B("5"), "bad2"),
                     T("040000", "blob", B("5"), "bad3"), T("120000", "commit", B("5"), "bad4"),
                     T("100755", "tree", B("5"), "bad5"), T("777777", "blob", B("5"), "bad6")])
# C6: executable bit
write("c6_local.tsv", [F("run.sh", "r", note="exec"), F("tool.sh", "t", note="exec"), F("plain.sh", "p"), F("same.txt", "s")])
tree("c6_tree.bin", [T("100755", "blob", blob(b"r"), "run.sh"), T("100644", "blob", blob(b"t"), "tool.sh"),
                     T("100755", "blob", blob(b"p"), "plain.sh"), T("100644", "blob", blob(b"s"), "same.txt")])
write("c6_nomodes.tsv", [F("run.sh", "r"), F("tool.sh", "t")], hdr=[(k, v) for k, v in HDR if k != "modes_recorded"])
# C7: special files and accounting against GitHub
write("c7_local.tsv", [F("a.txt", "a"), SP("pipe", "fifo"), SP("sockfile", "socket"), F("untracked.txt", "u", state="untracked"),
                       F("ign.txt", "i", state="ignored"), MS("gone.txt"), U("unr.txt"), F("diff.txt", "local")])
tree("c7_tree.bin", [T("100644", "blob", blob(b"a"), "a.txt"), T("100644", "blob", B("8"), "gone.txt"),
                     T("100644", "blob", B("8"), "diff.txt"), T("100644", "blob", B("8"), "remote_only.txt"),
                     T("100644", "blob", B("8"), "sockfile")])
# C8: real tab / newline file names, quoted names, SHA-256 trees
write("c8_local.tsv", [F("tab\\there.txt", "t"), F("new\\nline.txt", "n")])
tree("c8_tree.bin", [T("100644", "blob", blob(b"t"), b"tab\there.txt"), T("100644", "blob", blob(b"n"), b"new\nline.txt")])
open(os.path.join(base, "c8_quoted.txt"), "wb").write(T("100644", "blob", blob(b"t"), '"quoted\\tname.txt"') + b"\n")
tree("c8_sha256.bin", [T("100644", "blob", "a" * 64, "x.txt")])
open(os.path.join(base, "c8_empty.bin"), "wb").close()
write("c8_oldv2.tsv", [], end=None)
open(os.path.join(base, "c8_oldv2.tsv"), "w").write("a.txt\t5\t%s\t%s\n" % (H("a"), B("c")))
# C11: same content hashed on both sides (verified identical) vs hash skipped
write("c11_a.tsv", [M("m1.gguf", 10, H("a")), M("m2.gguf", 10, H("b"))], hdr=header(hash_models="1"))
write("c11_c.tsv", [M("m1.gguf", 10, H("a")), M("m2.gguf", 10, H("c"))], hdr=header(hash_models="1"))
write("c11_b.tsv", [M("m1.gguf", 10), M("m2.gguf", 10)], hdr=header(hash_models="0"))
PYCX

# ------------------------------------------------------------------ test runner helpers
cmpr() { local n="$1"; shift; python3 -B "$COMPARE" "$@" > "$BASE/out_$n.txt" 2>&1; RC=$?; }
audit() {     # audit HOMEDIR NAME [options] -> run_NAME.txt, git_NAME.log, RC
    local h="$1" n="$2"; shift 2
    sleep 1    # report folders are named by the second; consecutive runs in one HOME must not collide
    HOME="$h" GIT_STUB_LOG="$BASE/git_$n.log" bash "$AUDIT" "$@" > "$BASE/run_$n.txt" 2>&1
    RC=$?
}
latest() { ls -d "$1"/leah_audit_*/ 2>/dev/null | grep -v 20260101 | tail -1; }

# ------------------------------------------------------------------ environment
section "ENVIRONMENT"
PYV="$(python3 --version 2>&1)"; GITV="$("$REALGIT" --version)"
OSV="$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
echo "  python : $PYV"; echo "  bash   : $BASH_VERSION"; echo "  git    : $GITV"; echo "  os     : ${OSV:-unknown} ($(uname -sr))"
echo "  user   : uid $(id -u)    awk: $(awk --version 2>&1 | head -1)"
echo "  NOTE: Python 3.5 and Raspberry Pi OS Buster are NOT runtime-tested here; see grammar checks below."

section "STATIC CHECKS (grammar only; not runtime tests of old Python or old bash)"
check "leah_audit.sh passes bash -n" bash -n "$AUDIT"
check "leah_selftest.sh passes bash -n" bash -n "$0"
python3 -B -c "
import ast,sys,re
a=open('$AUDIT').read(); py=a.split(\"<<'PYEOF'\n\",1)[1].split('\nPYEOF',1)[0]
c=open('$COMPARE').read()
for name,src in (('audit-embedded',py),('compare',c)):
    ast.parse(src, feature_version=(3,5))
    if re.search(r'\bf[\"\\']', src): sys.exit('f-string in '+name)
" > "$BASE/static.txt" 2>&1; RC=$?
check "embedded Python and leah_compare.py parse with Python 3.5 grammar and contain no f-strings (grammar-only)" rc_is 0

# ------------------------------------------------------------------ snapshot validation (Part 2)
section "SNAPSHOT FINGERPRINT SELF-VALIDATION (negative control and mutation detection)"
SC="$BASE/sc"
fresh() { rm -rf -- "$SC"; mkdir -p "$SC/d1"; printf 'AAAAAAAAAA' > "$SC/file.txt"; chmod 640 "$SC/file.txt"
          printf 'x' > "$SC/d1/x"; ln -s file.txt "$SC/link"; python3 -B -c "import os;os.utime('$SC/file.txt',ns=(1700000000*10**9,)*2)"; }
fresh; A1=$(snap "$SC"); A2=$(snap "$SC")
check "control: two snapshots of an untouched tree are identical" same "$A1" "$A2"
fresh; F1=$(snap "$SC"); M1=$(snapm "$SC")
python3 -B - <<EOF
import os
p="$SC/file.txt"
with open(p,"r+b") as f: f.write(b"BBBBBBBBBB")          # same length, different content
os.chmod(p,0o640)
os.utime(p, ns=(1700000000*10**9,)*2)                      # restore the modification time
EOF
F2=$(snap "$SC"); M2=$(snapm "$SC")
check "NEGATIVE CONTROL: same-size content change with restored mtime and mode IS detected by the content-aware snapshot" differs "$F1" "$F2"
check "NEGATIVE CONTROL: the old metadata-only snapshot misses exactly that change (proves the control is meaningful)" same "$M1" "$M2"
fresh; S1=$(snap "$SC"); printf 'n' > "$SC/new.txt"; S2=$(snap "$SC")
check "file creation detected" differs "$S1" "$S2"
rm -f "$SC/new.txt"; S3=$(snap "$SC"); rm -f "$SC/d1/x"; S4=$(snap "$SC")
check "file deletion detected" differs "$S3" "$S4"
fresh; S1=$(snap "$SC"); ln -sfn d1 "$SC/link"; S2=$(snap "$SC")
check "symlink target change detected (target not followed)" differs "$S1" "$S2"
fresh; S1=$(snap "$SC"); mkdir "$SC/newdir"; S2=$(snap "$SC")
check "directory creation detected" differs "$S1" "$S2"
rmdir "$SC/newdir"; rm -rf "$SC/d1"; S3=$(snap "$SC")
check "directory deletion detected" differs "$S2" "$S3"
fresh; S1=$(snap "$SC"); chmod 600 "$SC/file.txt"; python3 -B -c "import os;os.utime('$SC/file.txt',ns=(1700000000*10**9,)*2)"; S2=$(snap "$SC")
check "permission change detected (mtime restored)" differs "$S1" "$S2"
fresh; S1=$(snap "$SC"); chmod u+x "$SC/file.txt"; python3 -B -c "import os;os.utime('$SC/file.txt',ns=(1700000000*10**9,)*2)"; S2=$(snap "$SC")
check "executable-bit change detected (mtime restored)" differs "$S1" "$S2"
fresh; S1=$(snap "$SC"); rm "$SC/d1/x"; ln -s file.txt "$SC/d1/x"; S2=$(snap "$SC")
check "file-to-symlink type change detected" differs "$S1" "$S2"
fresh; ( cd "$SC" && "$REALGIT" init -q . ) ; S1=$(snap "$SC"); S1m=$(snapm "$SC")
python3 -B - <<EOF
import os
p="$SC/.git/description"
before=os.lstat(p); data=open(p,"rb").read()
with open(p,"r+b") as f: f.write(bytes([data[0]^1])+data[1:])   # flip one bit: same size
os.utime(p, ns=(before.st_atime_ns, before.st_mtime_ns))
EOF
S2=$(snap "$SC"); S2m=$(snapm "$SC")
check ".git internal same-size change with restored mtime detected" differs "$S1" "$S2"
check ".git internal change is invisible to metadata-only snapshots (control)" same "$S1m" "$S2m"
fresh; printf 'z' > "$SC/a b"; printf 'z' > "$SC/$(printf 'tab\there')"; printf 'z' > "$SC/$(printf 'nl\nname')"
snap_to "$SC" full "$BASE/names.txt"
check "snapshot handles spaces, tabs and newlines in file names (one line per entry)" count_is "$BASE/names.txt" 'a b|tab\\there|nl\\nname' 3

# ------------------------------------------------------------------ build synthetic world
section "BUILD SYNTHETIC ENVIRONMENT"
python3 -B "$BASE/build_env.py" "$BASE" > "$BASE/build.txt" 2>&1; RC=$?
check "synthetic laptop, Pi, backup, nested-repo, remote and unreadable repos built" rc_is 0
[ -e "$BASE/marker_fsmonitor" ] || [ -e "$BASE/marker_filter" ] && rm -f "$BASE/marker_fsmonitor" "$BASE/marker_filter"
mkdir -p "$BASE/stubs"
{ printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'sub=""; rest=""; skip=0' 'for a in "$@"; do' '  if [ -n "$sub" ]; then rest="$rest $a"; continue; fi' \
     '  if [ $skip = 1 ]; then skip=0; continue; fi' '  case "$a" in -c|-C) skip=1 ;; -*) ;; *) sub="$a" ;; esac' 'done' \
     'printf "%s%s\n" "$sub" "$rest" >> "${GIT_STUB_LOG:-/dev/null}"' "exec $REALGIT \"\$@\""; } > "$BASE/stubs/git"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'MAILTO=secret@example.com' '@reboot cd /x/Leah && ./run_leah.sh --api-key=CRONSECRET99' '*/5 * * * * /usr/bin/python3 /x/Leah/assistant.py --token=CRONSECRET99 ARGHIDDEN777' '0 3 * * * /usr/bin/backup.sh --password=OTHERSECRET'" > "$BASE/stubs/crontab"
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "+%Y%m%d-%H%M%S" ] && [ -n "${FIXED_TS:-}" ]; then echo "$FIXED_TS"; else exec /bin/date "$@"; fi' > "$BASE/stubs/date"
chmod +x "$BASE/stubs/git" "$BASE/stubs/crontab" "$BASE/stubs/date"
printf '%s\n' 'AllowUsers secretuser' 'ListenAddress 10.9.8.7' 'PasswordAuthentication no' 'PermitRootLogin prohibit-password' \
  'Match User secretuser' '    PasswordAuthentication yes' > "$BASE/sshd_config"
export PATH="$BASE/stubs:$PATH" LEAH_AUDIT_SSHD_CONFIG="$BASE/sshd_config"

# control: the evil repository settings really do fire when `git status` is run on a COPY
cp -a "$BASE/laptop_home/Leah" "$BASE/evil_copy"
( cd "$BASE/evil_copy" && "$REALGIT" status > /dev/null 2>&1 )
check "CONTROL: plain 'git status' on a throw-away copy DOES run the configured fsmonitor program" test -e "$BASE/marker_fsmonitor"
check "CONTROL: plain 'git status' on a throw-away copy DOES run the configured clean filter" test -e "$BASE/marker_filter"
rm -rf -- "$BASE/evil_copy" "$BASE/marker_fsmonitor" "$BASE/marker_filter"

python3 -B -c "import time; time.sleep(120)" leah_ARGSECRET_zz &
BG=$!
SNAP_EXCL='leah_audit_*'
HL1=$(snap "$BASE/laptop_home"); HP1=$(snap "$BASE/pi_home"); BK1=$(snap "$BASE/laptop_home/Backups"); PR1=$(snap "$BASE/probe_home")
unset SNAP_EXCL
EXPSHA=$(printf 'AAAAAAAAAA' | sha256sum | cut -d' ' -f1)

section "AUDIT RUNS"
SNAP_EXCL='leah_audit_*'
audit "$BASE/laptop_home" laptop --hash-models --expect-sha "$EXPSHA"; check "audit exits 0 (laptop, --hash-models)" rc_is 0
audit "$BASE/pi_home" pi;       check "audit exits 0 (pi)" rc_is 0
NOUNSHARE=""
if unshare -n true 2> /dev/null; then NOUNSHARE="unshare -n"; elif unshare -rn true 2> /dev/null; then NOUNSHARE="unshare -rn"; fi
if [ -n "$NOUNSHARE" ]; then
    sleep 1; HOME="$BASE/pi_home" $NOUNSHARE bash "$AUDIT" > "$BASE/run_nonet.txt" 2>&1; RC=$?
    check "audit completes with ALL networking removed ($NOUNSHARE): it needs no network and does not hang" rc_is 0
    check "... and still wrote a full report" hasF "$BASE/run_nonet.txt" 'Report folder'
else
    skip "audit completes with networking removed" "unshare -n unavailable or not permitted in this environment"
fi
audit "$BASE/sha256_home" sha;  check "audit exits 0 (SHA-256 repository)" rc_is 0
audit "$BASE/probe_home" noprobe; check "audit exits 0 (nested repo, no --probe)" rc_is 0
check "no fake llama-cli was executed without --probe" test ! -e "$BASE/marker_probe"
audit "$BASE/probe_home" probe --probe; check "audit exits 0 (nested repo, --probe)" rc_is 0
check "--probe DOES execute the fake llama-cli (opt-in works)" test -e "$BASE/marker_probe"
audit "$BASE/remote_home" remote1 --remote; check "audit exits 0 (--remote against a local bare repository)" rc_is 0
( cd "$BASE/remote_home/Leah" && OLD=$("$REALGIT" rev-parse HEAD) && printf 'two\n' > b.txt && "$REALGIT" add b.txt && "$REALGIT" commit -qm two \
  && "$REALGIT" push -q origin HEAD:refs/heads/main && "$REALGIT" update-ref refs/remotes/origin/main "$OLD" ) > /dev/null 2>&1
audit "$BASE/remote_home" remote2 --remote; check "audit exits 0 (--remote, remote has moved on)" rc_is 0
ln -s "$BASE/laptop_home/Leah" "$BASE/linkroot"; mkdir -p "$BASE/linkhome"
audit "$BASE/linkhome" linkroot --repo "$BASE/linkroot" --backup "$BASE/none"; check "audit exits 0 when --repo itself is a symlink" rc_is 0
FIXED_TS=20260101-000000 audit "$BASE/linkhome" fixed1 --repo "$BASE/pi_home/Leah" --backup "$BASE/none"; check "audit with a fixed report name exits 0 the first time" rc_is 0
FIXED_TS=20260101-000000 audit "$BASE/linkhome" fixed2 --repo "$BASE/pi_home/Leah" --backup "$BASE/none"
check "second run with the same report name refuses to overwrite (exit 1)" rc_is 1
kill $BG 2>/dev/null
HL2=$(snap "$BASE/laptop_home"); HP2=$(snap "$BASE/pi_home"); BK2=$(snap "$BASE/laptop_home/Backups"); PR2=$(snap "$BASE/probe_home")
unset SNAP_EXCL

L=$(latest "$BASE/laptop_home"); P=$(latest "$BASE/pi_home")

section "READ-ONLY GUARANTEES (content-aware fingerprints, .git included)"
check "laptop home incl. repo, .git and backup: byte-for-byte unchanged apart from the report folder" same "$HL1" "$HL2"
check "pi home incl. repo and .git unchanged apart from the report folder" same "$HP1" "$HP2"
check "backup folder (incl. its .git) unchanged" same "$BK1" "$BK2"
check "nested-repo home (nested .git, fake binary) unchanged apart from the report folder" same "$PR1" "$PR2"
check "report folder contains only the expected files" test -z "$(ls "$L" | grep -Evx 'report.txt|manifest_repo.tsv|manifest_backup.tsv|cached_origin_main_tree.bin|probe_output.txt')"
check "no repository-configured fsmonitor program was run" test ! -e "$BASE/marker_fsmonitor"
check "no repository-configured clean filter was run" test ! -e "$BASE/marker_filter"
check "no nested-repository fsmonitor program was run" test ! -e "$BASE/marker_nested_fsmonitor"
cat "$BASE"/git_laptop.log "$BASE"/git_pi.log "$BASE"/git_sha.log "$BASE"/git_noprobe.log "$BASE"/git_probe.log "$BASE"/git_linkroot.log > "$BASE/git_nonremote.log" 2>/dev/null
check "every git call in non-remote runs is on the read-only allow-list (no status/diff/fetch/pull/push/checkout/gc/commit)" test -z "$(grep -Evx '(rev-parse|rev-list|log|branch|describe|check-ignore|ls-tree)( .*)?|config --get .*|ls-files .*|remote -v|submodule status.*' "$BASE/git_nonremote.log")"
check "no ls-remote (network) call happened without --remote" count_is "$BASE/git_nonremote.log" '^ls-remote' 0
check "ls-remote happened exactly once per --remote run" count_is "$BASE/git_remote1.log" '^ls-remote' 1
R1=$(latest "$BASE/remote_home")
check "cached origin/main equal to the remote is reported as MATCHES" has "$BASE/run_remote1.txt" 'cached origin/main MATCHES'
check "cached origin/main behind the remote is reported as STALE" has "$BASE/run_remote2.txt" 'cached origin/main is STALE'
check "without --remote the report says nothing was fetched" hasF "$BASE/run_pi.txt" 'Nothing was fetched'
check "report explains that the cached reference may be stale" hasF "$BASE/run_laptop.txt" 'may be STALE'

section "REDACTION AND PRIVACY"
LEAK=0
for s in SuperSecretRemotePw ghp_a1B2c3D4e5 AKIAIOSFODNN7EXAMPLE hunter2hunter2 SuperSecretPw verysecretvalue CRONSECRET99 ARGHIDDEN777 OTHERSECRET ARGSECRET secretuser 10.9.8.7 SECRETBEARER "BEGIN RSA PRIVATE KEY" "$BASE/laptop_home" "$BASE/pi_home"; do
    c=$(grep -rF -- "$s" "$BASE"/laptop_home/leah_audit_*/ "$BASE"/pi_home/leah_audit_*/ "$BASE/run_laptop.txt" "$BASE/run_pi.txt" 2>/dev/null | wc -l)
    if [ "$c" != 0 ]; then LEAK=1; echo "    leaked: $s ($c)"; fi
done
check "no credential, key, token, process argument, sshd detail or home path appears in any output" [ "$LEAK" = 0 ]
check "secret scan reports category with file:line only" has "$L/report.txt" '\[aws-access-key-id\] notes.py:1'
check "git remote shown with credentials redacted" hasF "$L/report.txt" '***REDACTED***@github.com'
check "crontab: LEAH jobs listed by program name with arguments hidden" has "$L/report.txt" 'program=python3 \(arguments hidden\)'
check "ssh: only the three setting names are shown (global section only)" has "$L/report.txt" 'PasswordAuthentication = no'
check "ssh: Match-block override is not reported" hasnt "$L/report.txt" 'PasswordAuthentication = yes'
check "process list shows pid/user/name/exe without arguments" has "$L/report.txt" 'pid=[0-9]+ user=.* name=python3 exe='
check "terminal escape character in a file name is stripped from the report" test "$(LC_ALL=C grep -c "$(printf '\033')" "$L/report.txt")" = 0
check "symlinked assistant file is not followed" hasF "$L/report.txt" 'assistant_link.py: symlink, not followed'
check "audit works when --repo is a symlink (records found)" has "$(latest "$BASE/linkhome")/manifest_repo.tsv" '^source'
check "SHA-256 repository flagged as unsupported for GitHub comparison" hasF "$BASE/run_sha.txt" 'unsupported for GitHub blob comparison'
check "SHA-256 repository manifest declares blob_algorithm sha256" hasF "$(latest "$BASE/sha256_home")/manifest_repo.tsv" $'#blob_algorithm\tsha256'

section "MANIFEST RULES"
M="$L/manifest_repo.tsv"
check "symlink recorded with its target, not followed" has "$M" $'^symlink\tlink_diff\t'
check "filenames with tab/newline stored escaped on one line" "$BASH" -c "grep -qF 'tab\\there.txt' '$M' && grep -qF 'new\\nline.txt' '$M'"
check "venv, __pycache__, node_modules excluded WITH reasons" has "$M" $'^excluded\tvenv/\t.*reason=python virtual environment'
check "generated binary inventoried separately under the excluded build dir" has "$M" $'^binary\tbuild/bin/llama-cli\t'
check "build-backup/ and mybuild/ are NOT treated as build directories (files listed as source)" "$BASH" -c "grep -q $'^source\tbuild-backup/keep.txt\t' '$M' && grep -q $'^source\tmybuild/keep.txt\t' '$M'"
check "build/ itself is excluded with a reason and counts" has "$M" $'^excluded\tbuild/\t.*generated build directory; 1 binaries inventoried'
check "models listed with size; hash not computed by default" has "$P/manifest_repo.tsv" $'^model\tmodels/m_same_size.gguf\t10\tNOT-COMPUTED'
check "--hash-models computes model sha256" has "$M" $'^model\tmodels/m_same_size.gguf\t10\t[0-9a-f]{64}\tNOT-COMPUTED'
check "--expect-sha match reported" hasF "$BASE/run_laptop.txt" 'MATCHES expected hash'
check "submodule recorded separately" has "$M" $'^submodule\tsub/mod\t'
check "special files recorded as special (fifo)" has "$M" $'^special\tspecial_same\t.*type=fifo'
check "special files recorded as special (socket on the Pi)" has "$P/manifest_repo.tsv" $'^special\tspecial_diff\t.*type=socket'
check "executable files carry the exec flag" has "$M" $'^source\trun.sh\t.*\ttracked-clean\texec$'
check "non-executable files do not" has "$M" $'^source\tplain.sh\t.*\ttracked-clean\t-$'
check "LFS pointer file classified" has "$M" 'lfs-pointer'
check "nested repo files are classified separately" has "$(latest "$BASE/probe_home")/manifest_repo.tsv" $'untracked-nested-repo'
check "nested repo .git excluded as git metadata" has "$(latest "$BASE/probe_home")/manifest_repo.tsv" $'^excluded\tai-engine/llama-legacy/.git/'
check "nested repo: tracked-but-missing file reported without git status" has "$BASE/run_noprobe.txt" 'tracked files MISSING from disk \(completeness signal\): 1'
check "manifest ends with an #end marker whose count matches" "$BASH" -c "n=\$(grep -vc '^#' '$M'); tail -1 '$M' | grep -qx \"#end\$(printf '\\t')\$n\""
check "modified/untracked/missing git states distinguished in the manifest" "$BASH" -c "grep -q 'tracked-modified' '$M' && grep -q $'\tuntracked\t' '$M' && grep -q $'^missing\tgone.txt' '$M'"
check "probe: exit status recorded as 0 for the fake binary" has "$BASE/run_probe.txt" 'exit status: 0'

section "UNIT-LEVEL TESTS OF THE AUDIT PYTHON (race, mount point, symlink swap)"
sed -n "/<<'PYEOF'/,/^PYEOF/p" "$AUDIT" | sed '1d;$d' > "$BASE/pytool_extracted.py"
python3 -B "$BASE/unit.py" "$BASE/pytool_extracted.py" "$BASE" > "$BASE/unit.txt" 2>&1
check "file changing while it is hashed is reported unreadable(changed-during-hashing), other files fine" has "$BASE/unit.txt" '^RACE racy=unreadable/changed-during-hashing calm=source$'
check "different-filesystem directory excluded with a reason (SIMULATED via st_dev override, not a real mount)" has "$BASE/unit.txt" '^MOUNT excluded=True note=reason=different filesystem.*inside_listed=False outside=True$'
check "symlink swapped in at open time is refused by O_NOFOLLOW itself (same-inode target, so the inode check cannot mask a regression)" has "$BASE/unit.txt" '^SWAP refused ELOOP$'

section "UNREADABLE FILES (real permissions)"
UR="$BASE/unread_home/Leah"; DROP=""
if [ "$(id -u)" = 0 ]; then
    if command -v setpriv > /dev/null 2>&1 && setpriv --reuid=65534 --regid=65534 --clear-groups true 2> /dev/null; then
        chown -R 65534:65534 "$BASE/unread_home" && DROP="setpriv --reuid=65534 --regid=65534 --clear-groups"
    fi
fi
if [ "$(id -u)" != 0 ] || [ -n "$DROP" ]; then
    chmod 000 "$UR/secret.txt" "$UR/locked"
    U1=$(snap "$BASE/unread_home")
    HOME="$BASE/unread_home" $DROP env HOME="$BASE/unread_home" PATH="$PATH" bash "$AUDIT" --backup "$BASE/none" > "$BASE/run_unread.txt" 2>&1; RC=$?
    check "audit completes (exit 0) when files and a directory are unreadable" rc_is 0
    UM="$(latest "$BASE/unread_home")/manifest_repo.tsv"
    check "unreadable file recorded explicitly, not silently omitted" has "$UM" $'^unreadable\tsecret.txt\t.*open errno=13'
    check "unlistable directory recorded explicitly" has "$UM" $'^unreadable\tlocked\t.*directory-not-listable errno=13'
    check "report lists the UNREADABLE entries" hasF "$BASE/run_unread.txt" 'UNREADABLE entries: 2'
    chmod u+rwx "$UR/secret.txt" "$UR/locked" 2> /dev/null
    cmpr unread u1="$UM" u2="$UM"
    check "compare marks a manifest with unreadable records NOT TRUSTWORTHY (exit 3), each record counted once per manifest" "$BASH" -c "[ $RC = 3 ] && grep -Eq 'u1 +manifest problems=0, unreadable records=2' '$BASE/out_unread.txt' && grep -q 'VERDICT: NOT TRUSTWORTHY' '$BASE/out_unread.txt'"
    chmod 000 "$UR/secret.txt" "$UR/locked"
    SNAP_RUNAS="$DROP" snap_to "$BASE/unread_home" full "$BASE/snap_unread.txt"
    check "snapshot reports an unreadable file AND an unlistable directory explicitly (UNREADABLE + UNSTATABLE or FIND-ERROR), never silently" "$BASH" -c "grep -q 'UNREADABLE errno' '$BASE/snap_unread.txt' && grep -Eq '^(UNSTATABLE|FIND-ERROR)' '$BASE/snap_unread.txt'"
    chmod u+rwx "$UR/secret.txt" "$UR/locked" 2> /dev/null
else
    for t in "audit completes when files and a directory are unreadable" "unreadable file recorded explicitly" "unlistable directory recorded explicitly" \
             "report lists the UNREADABLE entries" "compare marks unreadable manifests NOT TRUSTWORTHY" "snapshot reports unreadable files explicitly"; do
        skip "$t" "running as root and setpriv/nobody unavailable, so permission denial cannot be produced"
    done
fi

# ------------------------------------------------------------------ comparator tests
section "COMPARATOR: real audit manifests (laptop vs Pi vs backup, cached GitHub tree)"
cmpr real laptop="$M" pi="$P/manifest_repo.tsv" backup="$L/manifest_backup.tsv" --github "$L/cached_origin_main_tree.bin" --github-source cached
cp "$BASE/out_real.txt" "$BASE/out_real_keep.txt"
check "compare exits 0 when all inputs are valid" rc_is 0
check "verdict says comparison complete" hasF "$BASE/out_real.txt" 'VERDICT: comparison complete'
check "special files compared and flagged for manual inspection, never identical" has "$BASE/out_real.txt" 'special_same: type=fifo on both sides; UNSUPPORTED'
check "different special types reported as different" has "$BASE/out_real.txt" 'special_diff: DIFFERENT special types \(type=fifo vs type=socket\)'
check "same-size skipped-hash models labelled UNVERIFIED" has "$BASE/out_real.txt" 'm_same_size.gguf \(same size 10; hash not computed'
check "different-size skipped-hash model reported as size mismatch" has "$BASE/out_real.txt" 'm_diff_size.gguf \(size 10 vs 12; content not hashed'
check "executable-mode mismatch laptop vs Git tree: locally executable, mode 100644" has "$BASE/out_real.txt" 'tool.sh: local executable, GitHub mode 100644'
check "executable-mode mismatch laptop vs Git tree: locally not executable, mode 100755" has "$BASE/out_real.txt" 'plain.sh: local not executable, GitHub mode 100755'
check "matching executable file (ok.sh) not reported" hasnt "$BASE/out_real.txt" 'ok.sh: local'
check "stale-cache warning shown for cached GitHub tree" hasF "$BASE/out_real.txt" 'may be STALE'
check "build/ exclusion: files in build-backup/ and mybuild/ are NOT 'under an excluded directory'" "$BASH" -c "! grep -q 'build-backup/keep.txt' <(sed -n '/inside a directory excluded/,/in GitHub tree but its local/p' '$BASE/out_real.txt')"
check "accounting: every compared path falls in exactly one category (pair)" "$BASH" -c "grep -E 'paths compared: ([0-9]+), accounted for in the categories below: \1\$' '$BASE/out_real.txt' | head -1 | grep -q ."
check "accounting: every GitHub-compared local record falls in exactly one category" "$BASH" -c "grep -E 'local records compared: ([0-9]+), accounted for below: \1\$' '$BASE/out_real.txt' | grep -q ."

section "COMPARATOR: crafted manifests (every bucket once; accurate totals)"
python3 -B "$BASE/mkcx.py" "$BASE/cx" > "$BASE/mkcx.txt" 2>&1; RC=$?
check "crafted test inputs generated" rc_is 0
CX="$BASE/cx"
cmpr c1 a="$CX/c1_a.tsv" b="$CX/c1_b.tsv"
O="$BASE/out_c1.txt"
check "C1 exits 3 because exactly one unreadable record exists" rc_is 3
check "C1 summary: 16 paths, all accounted" has "$O" 'accounting +: 16 of 16 paths'
check "C1 identical verified = 1" has "$O" 'identical verified files +: 1'
check "C1 different verified = 1" has "$O" 'different verified files +: 1'
check "C1 only in a = 1" has "$O" 'only in a +: 1'
check "C1 only in b = 1" has "$O" 'only in b +: 1'
check "C1 same-size unverified = 1 (never identical)" has "$O" 'same-size UNVERIFIED files +: 1'
check "C1 size mismatches = 1" has "$O" 'size mismatches \(hash skipped\) +: 1'
check "C1 symlink differences = 2 (retargeted link + file-vs-symlink)" has "$O" 'symlink differences +: 2'
check "C1 submodule differences = 1" has "$O" 'submodule differences +: 1'
check "C1 special files = 2 (manual inspection)" has "$O" 'special files \(manual\) +: 2'
check "C1 type mismatches = 1 (file vs submodule)" has "$O" 'type mismatches +: 1'
check "C1 tracked-absent / unreadable = 1 / 1" has "$O" 'tracked-but-absent / unreadable +: 1 / 1'
check "C1 unreadable record counted ONCE in the data-problem total (1)" hasF "$O" 'data problems found (malformed + unreadable + tree/format): 1'
check "C1 per-manifest line shows the unreadable record on a only" has "$O" ' a +manifest problems=0, unreadable records=1, special files \(manual inspection\)=2'

section "COMPARATOR: invalid, contradictory and malformed records (C2, C9, C10)"
cmpr c2 good="$CX/good.tsv" invalid="$CX/c2_invalid.tsv" --max 100
O="$BASE/out_c2.txt"
check "C2 exits 3" rc_is 3
check "C2 manifest-check line says 24 PROBLEM(S)" has "$O" 'invalid .*24 PROBLEM\(S\)'
check "C2 lists 24 error lines" count_is "$O" '^      line [0-9]+:' 24
for phrase in 'invalid sha256 value' 'invalid git blob id for declared object format' "invalid size '12x'" 'symlink note must be' \
              'symlink size does not match its target' 'symlink blob id does not match its target' 'invalid symlink flags' \
              'invalid submodule commit id' 'submodule record must have' 'model hash present although header says hashing was off' \
              'tracked state decided without a computed blob id' 'excluded record path must end' 'special record must have' \
              "missing record must have state 'missing'" 'unreadable record must have' 'unknown record kind' 'malformed record' \
              'DUPLICATE path' "lies under 'file1'" "lies under excluded directory 'venv/'" 'unsafe path'; do
    check "C2 detects: $phrase" hasF "$O" "$phrase"
done
check "C2 warns that results are INCOMPLETE and the verdict is NOT TRUSTWORTHY" "$BASH" -c "grep -q 'results below are INCOMPLETE' '$O' && grep -q 'VERDICT: NOT TRUSTWORTHY - 24' '$O'"
check "C2 duplicate path excluded from the comparison (not silently trusted)" hasnt "$O" 'dup.txt (size'
cmpr c9 good="$CX/good.tsv" contra="$CX/c9_contra.tsv"
check "C9 contradictory header/record combinations rejected (2 problems)" "$BASH" -c "grep -q 'contra .*2 PROBLEM' '$BASE/out_c9.txt' && grep -q 'no git state\\|git state recorded but manifest says not a git repository' '$BASE/out_c9.txt' && grep -q 'model hash not computed but hashing was requested' '$BASE/out_c9.txt'"
cmpr c10 good="$CX/good.tsv" alg="$CX/c10_alg.tsv"
check "C10 blob id of the wrong length for the declared algorithm rejected (1 problem)" "$BASH" -c "grep -q 'alg .*1 PROBLEM' '$BASE/out_c10.txt' && grep -q 'invalid git blob id for declared object format' '$BASE/out_c10.txt'"

section "COMPARATOR: incomplete manifests (C3)"
cmpr c3a good="$CX/good.tsv" x="$CX/c3_noend.tsv"
check "missing #end marker reported as INCOMPLETE (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q \"INCOMPLETE: no '#end' marker\" '$BASE/out_c3a.txt'"
cmpr c3b good="$CX/good.tsv" x="$CX/c3_badcount.tsv"
check "#end count mismatch reported (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q \"'#end' says 99 records, file contains 2\" '$BASE/out_c3b.txt'"
cmpr c3c good="$CX/good.tsv" x="$CX/c3_trunc.tsv"
check "truncated manifest: malformed row and missing end marker both reported (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q 'malformed record' '$BASE/out_c3c.txt' && grep -q 'INCOMPLETE' '$BASE/out_c3c.txt'"
cmpr c3d good="$CX/good.tsv" x="$CX/c3_zero.tsv"
check "zero-byte manifest reported, no crash (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q 'completely empty' '$BASE/out_c3d.txt'"
cmpr c3e a="$CX/c3_headeronly.tsv" b="$CX/c3_headeronly.tsv"
check "header-only manifest is valid and empty (exit 0, zero usable records)" "$BASH" -c "[ $RC = 0 ] && grep -q 'no usable file records' '$BASE/out_c3e.txt' && grep -q 'VERDICT: comparison complete' '$BASE/out_c3e.txt'"
cmpr c3f good="$CX/good.tsv" x="$CX/c3_nomagic.tsv"
check "missing '#leah-manifest 3' header reported (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q \"missing or unsupported '#leah-manifest 3'\" '$BASE/out_c3f.txt'"
cmpr c8v2 good="$CX/good.tsv" old="$CX/c8_oldv2.tsv"
check "old v2 manifest recognised with an explanatory warning (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q 'OLD (v2' '$BASE/out_c8v2.txt'"

section "COMPARATOR: GitHub tree comparison (C4-C8)"
cmpr c4 local="$CX/c4_local.tsv" --github "$CX/c4_tree.bin" --github-source fresh
O="$BASE/out_c4.txt"
check "C4 exits 0" rc_is 0
check "C4 'build/' exclusion covers only build/ itself (1 file)" hasF "$O" 'remote-only but inside a directory excluded from the manifest: 1'
check "C4 build-backup/ and mybuild/ files are remote-only, NOT swallowed by the exclusion (2 files)" hasF "$O" 'remote-only (in GitHub tree, absent from local manifest): 2'
check "C4 names listed: build-backup/b.txt and mybuild/c.txt" "$BASH" -c "grep -qF 'build-backup/b.txt' '$O' && grep -qF 'mybuild/c.txt' '$O'"
check "C4 fresh source explained" hasF "$O" 'FRESH: described as freshly retrieved'
cmpr c5 local="$CX/c5_local.tsv" --github "$CX/c5_tree.bin" --github-source cached
O="$BASE/out_c5.txt"
check "C5 invalid mode/type combinations rejected (6) and reported (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -qF 'malformed or rejected tree entries: 6' '$O'"
check "C5 each rejection names the invalid combination" count_is "$O" "invalid mode/type combination" 6
check "C5 valid entries compared: file, executable file, symlink match (3) and submodule commit matches (1)" hasF "$O" 'identical to GitHub (git blob id match): 3   (submodule commits matching: 1)'
check "C5 valid tree entry (040000 tree) accepted, not rejected" hasnt "$O" "'040000 tree'"
cmpr c6 local="$CX/c6_local.tsv" --github "$CX/c6_tree.bin" --github-source cached
O="$BASE/out_c6.txt"
check "C6 exits 0 (mode differences are findings, not data errors)" rc_is 0
check "C6 reports 2 executable-bit differences" hasF "$O" 'executable-bit differences (Git modes 100644 vs 100755; NOT full Unix permissions): 2'
check "C6 valid executable (run.sh, 100755) not reported" hasnt "$O" 'run.sh: local'
check "C6 summary line counts them" hasF "$O" 'executable-bit differences=2'
cmpr c6n local="$CX/c6_nomodes.tsv" --github "$CX/c6_tree.bin"
check "C6 manifest without mode information: comparison explicitly NOT performed" hasF "$BASE/out_c6n.txt" 'executable-bit comparison NOT performed'
cmpr c7 local="$CX/c7_local.tsv" --github "$CX/c7_tree.bin" --github-source cached
O="$BASE/out_c7.txt"
check "C7 exits 3 because of the unreadable local record (counted once)" "$BASH" -c "[ $RC = 3 ] && grep -qF 'data problems found (malformed + unreadable + tree/format): 1' '$O'"
check "C7 special files listed as unsupported/manual (2)" hasF "$O" 'special files (unsupported; need manual inspection): 2'
check "C7 untracked and ignored local-only files distinguished" "$BASH" -c "grep -qF 'local-only: untracked: 1' '$O' && grep -qF 'local-only: ignored by .gitignore: 1' '$O'"
check "C7 tracked-but-missing file that exists on GitHub reported" hasF "$O" 'tracked in git but missing locally (and present on GitHub): 1'
check "C7 remote-only file reported" hasF "$O" 'remote-only (in GitHub tree, absent from local manifest): 1'
check "C7 accounting consistent (all local records in exactly one category)" "$BASH" -c "grep -E 'local records compared: ([0-9]+), accounted for below: \1\$' '$O' | grep -q ."
cmpr c8 local="$CX/c8_local.tsv" --github "$CX/c8_tree.bin"
check "C8 real tab and newline file names match the GitHub tree (2 identical)" "$BASH" -c "[ $RC = 0 ] && grep -qF 'identical to GitHub (git blob id match): 2' '$BASE/out_c8.txt'"
cmpr c8q local="$CX/c8_local.tsv" --github "$CX/c8_quoted.txt"
check "C8 git-quoted path in newline-format tree rejected with an explanation (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q 'git-quoted path; regenerate with ls-tree -z' '$BASE/out_c8q.txt'"
cmpr c8s local="$CX/c8_local.tsv" --github "$CX/c8_sha256.bin"
check "C8 SHA-256 GitHub tree refused instead of mis-compared (exit 3)" "$BASH" -c "[ $RC = 3 ] && grep -q 'UNSUPPORTED' '$BASE/out_c8s.txt' && grep -q 'NOT compared' '$BASE/out_c8s.txt'"
cmpr c8e local="$CX/c8_local.tsv" --github "$CX/c8_empty.bin"
check "C8 empty GitHub tree handled (exit 0, local records become local-only)" "$BASH" -c "[ $RC = 0 ] && grep -q 'empty tree' '$BASE/out_c8e.txt'"
cmpr c11 a="$CX/c11_a.tsv" c="$CX/c11_c.tsv" b="$CX/c11_b.tsv"
O="$BASE/out_c11.txt"
check "C11 hashed models: equal hash is verified identical (1), different hash differs (1)" "$BASH" -c "grep -Ec 'identical verified files +: 1' '$O' | grep -qx 1 && grep -Ec 'different verified files +: 1' '$O' | grep -qx 1"
check "C11 skipped model hashes stay UNVERIFIED (2) and are never counted identical (0)" "$BASH" -c "grep -Ec 'same-size UNVERIFIED files +: 2' '$O' | grep -qx 1 && grep -Ec 'identical verified files +: 0' '$O' | grep -qx 1"

section "COMPARATOR: command-line handling"
cmpr cli1 a="$CX/good.tsv" b="$CX/good.tsv" --max -1;                 check "negative --max rejected" "$BASH" -c "[ $RC = 2 ] && grep -q 'must not be negative' '$BASE/out_cli1.txt'"
cmpr cli2 a="$CX/good.tsv" b="$CX/good.tsv" --max abc;                check "non-numeric --max rejected" rc_is 2
cmpr cli3 a="$CX/good.tsv" a="$CX/good.tsv";                          check "duplicate label rejected" "$BASH" -c "[ $RC = 2 ] && grep -q 'Duplicate label' '$BASE/out_cli3.txt'"
cmpr cli4 a="$CX/good.tsv" b=/nonexistent/m.tsv;                      check "missing manifest gives a helpful error" "$BASH" -c "[ $RC = 2 ] && grep -q 'Cannot read manifest' '$BASE/out_cli4.txt'"
cmpr cli5 a="$CX/good.tsv" 'bad label'="$CX/good.tsv";                check "invalid label rejected" rc_is 2
cmpr cli6 a="$CX/good.tsv" --github /nope.bin;                        check "missing GitHub tree file gives an error" rc_is 2
cmpr cli7 a="$CX/good.tsv" b="$CX/good.tsv"
check "a manifest compared with itself: all identical, no differences, exit 0" "$BASH" -c "[ $RC = 0 ] && grep -Eq 'identical verified files +: 4' '$BASE/out_cli7.txt' && grep -Eq 'different verified files +: 0' '$BASE/out_cli7.txt'"

# ------------------------------------------------------------------ result
echo
echo "================================================================"
echo "ENVIRONMENT : $PYV | bash $BASH_VERSION | $GITV | ${OSV:-unknown}"
echo "RESULT      : total $((PASS+FAIL+SKIP)) checks: $PASS passed, $FAIL failed, $SKIP skipped"
echo "NOT TESTED  : Python 3.5/3.7 runtime, Raspberry Pi OS Buster userland (mawk 1.3.3, git 2.20), real hardware, real mounts,"
echo "              real crontab/ss/systemctl/ufw output, a real llama.cpp binary."
if [ "$FAIL" = 0 ] && [ "$KEEP" = 0 ]; then
    cleanup_temp && echo "CLEANUP     : removed the temporary folder (confined to /tmp/leah_selftest.*)"
else
    echo "TEMP FOLDER : kept at $BASE  (delete it yourself when finished)"
fi
[ "$FAIL" = 0 ]
