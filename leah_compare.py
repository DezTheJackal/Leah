#!/usr/bin/env python3
"""
leah_compare.py v3 - READ-ONLY comparison of LEAH audit manifests (and a GitHub tree).

Reads only the files named on the command line. Writes nothing (prints to the screen).
Python 3.5+, standard library only.

USAGE
  python3 leah_compare.py laptop=<dir>/manifest_repo.tsv pi=<dir>/manifest_repo.tsv \
                          backup=<dir>/manifest_backup.tsv  [options]

  Every later manifest is compared with the FIRST one listed.

OPTIONS
  --max N               detail lines per section (whole number >= 0, default 40)
  --github FILE         output of:  git ls-tree -r -z <ref>   (leah_audit.sh saves one as
                        cached_origin_main_tree.bin). Compared with the FIRST manifest.
  --github-source S     cached | fresh | unknown (default unknown): says how the tree was
                        obtained so the report can explain what it proves.

EXIT STATUS
  0 comparison finished and every input was valid
  3 comparison finished but data problems were found (malformed, duplicate, invalid,
    contradictory or incomplete records, unreadable records, unsupported formats)
  4 internal accounting inconsistency (a bug; please report)
  2 usage error or an input file that cannot be read

RULES
  * A record whose hash was NOT-COMPUTED is never reported as identical.
  * Symlinks, submodules, special files and regular files are compared separately.
  * A record that fails validation is excluded from the comparison and counted once.
  * Executable-bit comparison with GitHub uses Git's own modes (100644 vs 100755) only; it is
    NOT a comparison of full Unix permissions.
"""
import argparse
import hashlib
import os
import re
import sys

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEXPAIR = re.compile(r"^[0-9a-f]{2}$")
LABEL = re.compile(r"^[A-Za-z0-9_.-]+$")
DIGITS = re.compile(r"^[0-9]+$")
BIG = 50 * 1024 * 1024
REGULAR = ("source", "binary", "model")
KINDS = REGULAR + ("symlink", "submodule", "special", "unreadable", "excluded", "missing")
TRACKED = ("tracked-clean", "tracked-modified", "tracked-unchecked")
FILE_STATES = TRACKED + ("untracked", "ignored", "untracked-nested-repo", "unknown", "n/a")
FLAGS_OK = ("lfs-pointer", "size-limit-50MB", "hash-not-requested", "exec")
SYMLINK_FLAGS_OK = ("absolute", "outside-root(lexical)")
SPECIAL_TYPES = ("fifo", "socket", "chardev", "blockdev", "other")
TREE_OK = (("100644", "blob"), ("100755", "blob"), ("120000", "blob"),
           ("160000", "commit"), ("040000", "tree"))


def esc(text):
    """Same escaping as leah_audit.sh so GitHub paths line up with manifest paths."""
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


def unesc(text):
    """Inverse of esc(); raises ValueError on a malformed escape sequence."""
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        if i + 1 >= n:
            raise ValueError("dangling backslash")
        nxt = text[i + 1]
        if nxt == "\\":
            out.append("\\")
            i += 2
        elif nxt == "t":
            out.append("\t")
            i += 2
        elif nxt == "n":
            out.append("\n")
            i += 2
        elif nxt == "r":
            out.append("\r")
            i += 2
        elif nxt == "x" and HEXPAIR.match(text[i + 2:i + 4]):
            value = int(text[i + 2:i + 4], 16)
            out.append(chr(0xDC00 + value) if value >= 0x80 else chr(value))
            i += 4
        else:
            raise ValueError("bad escape sequence")
    return "".join(out)


def under(path, dirkey):
    """Component-aware: 'build/' covers 'build' and 'build/x' but NOT 'build-backup/x' or 'mybuild/x'."""
    d = dirkey.rstrip("/")
    return path == d or path.startswith(d + "/")


class Row(object):
    __slots__ = ("kind", "path", "size", "sha", "blob", "state", "note", "line")

    def __init__(self, kind, path, size, sha, blob, state, note, line):
        self.kind, self.path, self.size, self.sha = kind, path, size, sha
        self.blob, self.state, self.note, self.line = blob, state, note, line

    def flags(self):
        return set(self.note.split(";")) if self.kind in REGULAR else set()

    def target(self):
        return self.note.partition("|target=")[2]


class Manifest(object):
    def __init__(self, label, path):
        self.label, self.path = label, path
        self.header = {}
        self.rows = {}
        self.excluded = {}
        self.errors = []
        self.invalid = set()
        self.empty_file = False
        self.record_lines = 0

    def count_kind(self, kind):
        return sum(1 for r in self.rows.values() if r.kind == kind)


def blob_ok(man, value):
    alg = man.header.get("blob_algorithm")
    if alg == "sha1":
        return bool(HEX40.match(value))
    if alg == "sha256":
        return bool(HEX64.match(value))
    return bool(HEX40.match(value) or HEX64.match(value))      # manifest from an earlier build


def validate_row(man, kind, path, size, sha, blob, state, note):
    """Return a list of problems with one record (empty list = valid)."""
    bad = []
    if kind not in KINDS:
        return ["unknown record kind '%s'" % kind[:20]]
    if not path:
        return ["empty path"]
    if path.startswith("/") or "//" in path.rstrip("/") or any(c == ".." for c in path.split("/")):
        bad.append("unsafe path (absolute, empty or '..' component)")
    git_repo = man.header.get("git_repo")
    if kind in REGULAR:
        if not DIGITS.match(size):
            bad.append("invalid size '%s'" % size[:20])
        if not (HEX64.match(sha) or sha == "NOT-COMPUTED"):
            bad.append("invalid sha256 value")
        if not (blob_ok(man, blob) or blob == "NOT-COMPUTED"):
            bad.append("invalid git blob id for declared object format")
        if state not in FILE_STATES:
            bad.append("unknown git-state '%s'" % state[:24])
        toks = note.split(";")
        if note != "-" and (not all(t in FLAGS_OK for t in toks) or len(set(toks)) != len(toks)):
            bad.append("unknown or repeated note flag")
        if not bad:
            flags = set(toks) if note != "-" else set()
            limit = "size-limit-50MB" in flags
            if kind == "model":
                if blob != "NOT-COMPUTED":
                    bad.append("contradictory: model record carries a git blob id")
                if sha == "NOT-COMPUTED" and ("hash-not-requested" not in flags
                                              or man.header.get("hash_models") == "1"):
                    bad.append("contradictory: model hash not computed but hashing was requested")
                if sha != "NOT-COMPUTED" and man.header.get("hash_models") == "0":
                    bad.append("contradictory: model hash present although header says hashing was off")
            else:
                if limit and not (sha == "NOT-COMPUTED" and blob == "NOT-COMPUTED" and int(size) > BIG):
                    bad.append("contradictory: size-limit flag without matching size/hash fields")
                if not limit and (sha == "NOT-COMPUTED" or blob == "NOT-COMPUTED"):
                    bad.append("contradictory: hash missing for a file without a size-limit flag")
                if "hash-not-requested" in flags:
                    bad.append("contradictory: hash-not-requested on a non-model file")
            if "lfs-pointer" in flags and (kind != "source" or int(size) > 1024):
                bad.append("contradictory: lfs-pointer flag on an unsuitable record")
            if state in ("tracked-clean", "tracked-modified") and blob == "NOT-COMPUTED":
                bad.append("contradictory: tracked state decided without a computed blob id")
            if git_repo == "0" and state != "n/a":
                bad.append("contradictory: git state recorded but manifest says not a git repository")
            if git_repo == "1" and state == "n/a":
                bad.append("contradictory: no git state although manifest says it is a git repository")
    elif kind == "symlink":
        if not DIGITS.match(size):
            bad.append("invalid symlink size")
        if sha != "-":
            bad.append("symlink record must not carry a sha256")
        if not blob_ok(man, blob):
            bad.append("invalid symlink blob id")
        if state not in FILE_STATES:
            bad.append("unknown git-state '%s'" % state[:24])
        head, sep, target = note.partition("|target=")
        if not sep or not target or not head.startswith("flags="):
            bad.append("symlink note must be 'flags=...|target=<target>'")
        else:
            ftoks = [t for t in head[6:].split(",") if t]
            if ftoks != ["none"] and (not ftoks or any(t not in SYMLINK_FLAGS_OK for t in ftoks)
                                      or len(set(ftoks)) != len(ftoks)):
                bad.append("invalid symlink flags")
            try:
                raw = unesc(target).encode("utf-8", "surrogateescape")
            except (ValueError, UnicodeError):
                raw = None
                bad.append("symlink target has a malformed escape sequence")
            if raw is not None and not bad:
                if DIGITS.match(size) and int(size) != len(raw):
                    bad.append("contradictory: symlink size does not match its target")
                alg = "sha256" if len(blob) == 64 else "sha1"
                digest = hashlib.new(alg, b"blob %d\0" % len(raw) + raw).hexdigest()
                if digest != blob:
                    bad.append("contradictory: symlink blob id does not match its target")
                if ("absolute" in ftoks) != raw.startswith(b"/"):
                    bad.append("contradictory: 'absolute' flag does not match the target")
    elif kind == "submodule":
        if size != "-" or sha != "-":
            bad.append("submodule record must have '-' size and sha256")
        if not blob_ok(man, blob):
            bad.append("invalid submodule commit id")
        if state != "tracked-clean":
            bad.append("submodule state must be tracked-clean")
        if note in ("", "-"):
            bad.append("submodule record needs a note")
    elif kind == "missing":
        if size != "-" or sha != "-":
            bad.append("missing record must have '-' size and sha256")
        if blob != "-" and not blob_ok(man, blob):
            bad.append("invalid blob id in missing record")
        if state != "missing":
            bad.append("missing record must have state 'missing'")
        if note in ("", "-"):
            bad.append("missing record needs a note")
        if git_repo == "0":
            bad.append("contradictory: tracked-but-missing record in a non-git manifest")
    elif kind == "excluded":
        if not path.endswith("/") or path == "/":
            bad.append("excluded record path must end with '/'")
        if (size, sha, blob, state) != ("-", "-", "-", "-"):
            bad.append("excluded record must have '-' in size/sha256/blob/state")
        if not note.startswith("reason=") or len(note) <= 7:
            bad.append("excluded record needs 'reason=<text>'")
    elif kind == "unreadable":
        if sha != "-" or blob != "-" or state != "-":
            bad.append("unreadable record must have '-' in sha256/blob/state")
        if size != "-" and not DIGITS.match(size):
            bad.append("invalid size in unreadable record")
        if note in ("", "-"):
            bad.append("unreadable record needs a reason")
    elif kind == "special":
        if (size, sha, blob, state) != ("-", "-", "-", "-"):
            bad.append("special record must have '-' in size/sha256/blob/state")
        if not (note.startswith("type=") and note[5:] in SPECIAL_TYPES):
            bad.append("special record needs type=fifo|socket|chardev|blockdev|other")
    return bad


def load_manifest(label, path):
    man = Manifest(label, path)
    with open(path, "rb") as handle:
        data = handle.read()
    if not data:
        man.empty_file = True
        man.errors.append("file is completely empty (0 bytes): the copy may have failed")
        return man
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("utf-8", "replace")
        man.errors.append("file is not valid UTF-8")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    seen, end_seen, end_value = {}, False, None
    for num, line in enumerate(lines, 1):
        if end_seen:
            man.errors.append("line %d: content after the '#end' marker" % num)
            continue
        if line.startswith("#"):
            key, _, value = line[1:].partition("\t")
            if key == "end":
                end_seen, end_value = True, value
            elif key in man.header:
                man.errors.append("line %d: duplicate header '%s'" % (num, key))
            else:
                man.header[key] = value
            continue
        parts = line.split("\t")
        if num == 1 and len(parts) == 4:
            man.errors.append("line 1: looks like an OLD (v2, 4-column) manifest; "
                              "re-run leah_audit.sh v3 on that machine")
            return man
        man.record_lines += 1
        if len(parts) != 7:
            man.errors.append("line %d: malformed record (%d fields, expected 7)" % (num, len(parts)))
            continue
        kind, rpath, size, sha, blob, state, note = parts
        problems = validate_row(man, kind, rpath, size, sha, blob, state, note)
        if problems:
            man.errors.append("line %d: %s (%s)" % (num, "; ".join(problems), rpath[:80]))
            if rpath:
                man.invalid.add(rpath)
            continue
        row = Row(kind, rpath, size, sha, blob, state, note, num)
        if rpath in seen:
            man.errors.append("line %d: DUPLICATE path '%s' (first seen at line %d); "
                              "both records excluded" % (num, rpath[:80], seen[rpath]))
            man.invalid.add(rpath)
            man.rows.pop(rpath, None)
            man.excluded.pop(rpath, None)
            continue
        seen[rpath] = num
        (man.excluded if kind == "excluded" else man.rows)[rpath] = row

    if man.header.get("leah-manifest") != "3":
        man.errors.append("missing or unsupported '#leah-manifest 3' header line")
    for key, allowed in (("git_repo", ("0", "1")), ("hash_models", ("0", "1"))):
        if man.header.get(key) not in allowed:
            man.errors.append("missing or invalid header '%s'" % key)
    if not man.header.get("git_object_format"):
        man.errors.append("missing header 'git_object_format'")
    if man.header.get("blob_algorithm") not in (None, "sha1", "sha256"):
        man.errors.append("invalid header 'blob_algorithm'")
    if man.header.get("modes_recorded") not in (None, "0", "1"):
        man.errors.append("invalid header 'modes_recorded'")
    if not end_seen:
        man.errors.append("INCOMPLETE: no '#end' marker (truncated copy, or a manifest from an "
                          "earlier build); completeness cannot be confirmed")
    elif not DIGITS.match(end_value or "") or int(end_value) != man.record_lines:
        man.errors.append("INCOMPLETE or inconsistent: '#end' says %s records, file contains %d"
                          % ((end_value or "?")[:12], man.record_lines))
    check_containment(man)
    return man


def check_containment(man):
    """No record may live underneath a file, symlink, submodule, special or excluded entry."""
    filelike = set(p for p, r in man.rows.items() if r.kind != "unreadable")
    excl = dict((p.rstrip("/"), r) for p, r in man.excluded.items())
    for path, row in list(man.rows.items()):
        parts = path.split("/")
        for i in range(1, len(parts)):
            anc = "/".join(parts[:i])
            problem = None
            if anc in filelike:
                problem = "lies under '%s', which is a %s record" % (anc[:60], man.rows[anc].kind)
            elif anc in excl:
                reason = excl[anc].note
                if not (reason.startswith("reason=generated build directory") and row.kind in ("binary", "unreadable")):
                    problem = "lies under excluded directory '%s/'" % anc[:60]
            if problem:
                man.errors.append("line %d: contradictory: '%s' %s" % (row.line, path[:80], problem))
                man.invalid.add(path)
                del man.rows[path]
                break


def show(title, items, limit):
    print("  %s: %d" % (title, len(items)))
    for item in items[:limit]:
        print("      " + item)
    if len(items) > limit:
        print("      ... %d more" % (len(items) - limit))


def snapshot_notes(manifests):
    print("\n=== SNAPSHOT INFORMATION ===")
    for m in manifests:
        h = m.header
        print("  %-10s created=%s  git_head=%s  uncommitted=%s  hash_models=%s  object_format=%s  modes=%s"
              % (m.label, h.get("created", "?"), h.get("git_head", "?")[:12],
                 h.get("git_dirty_entries", "?"), h.get("hash_models", "?"),
                 h.get("git_object_format", "?"), "yes" if h.get("modes_recorded") == "1" else "no"))
        if not m.rows and not m.empty_file:
            print("             (this manifest has zero usable file records)")
    heads = set(m.header.get("git_head", "?") for m in manifests)
    dirty = [m.label for m in manifests if m.header.get("git_dirty_entries", "0") not in ("0", "-", "?")]
    print("  These are DIFFERENT SNAPSHOTS taken at different times. A difference shows what each")
    print("  side contained when its manifest was made; it does not prove which side is correct.")
    if len(heads) > 1:
        print("  NOTE: the manifests were taken at different git commits.")
    if dirty:
        print("  NOTE: uncommitted changes existed when these were created: " + ", ".join(dirty))
    if len(set(m.header.get("hash_models", "?") for m in manifests)) > 1:
        print("  NOTE: model hashing differs between manifests; model files may be 'unverified'.")
    if len(set(m.header.get("git_object_format", "?") for m in manifests)) > 1:
        print("  WARNING: git object formats differ between manifests; git blob ids are not comparable.")


def category(row):
    return "file" if row.kind in REGULAR else row.kind


def compare_pair(a, b, limit, results):
    print("\n=== %s  vs  %s ===" % (a.label, b.label))
    for m in (a, b):
        if m.errors:
            print("  WARNING: manifest '%s' has %d problem(s); %d record path(s) were EXCLUDED from this "
                  "comparison, so the results below are INCOMPLETE." % (m.label, len(m.errors), len(m.invalid)))
    skip = a.invalid | b.invalid
    universe = (set(a.rows) | set(b.rows)) - skip
    s = dict((k, []) for k in ("different", "only_a", "only_b", "same_unverified", "size_mismatch",
                               "symlink_diffs", "submodule_diffs", "type_mismatch", "unreadable",
                               "missing", "special", "class_diff"))
    s["identical"], s["symlink_same"], s["submodule_same"] = 0, 0, 0
    for path in sorted(universe):
        ra, rb = a.rows.get(path), b.rows.get(path)
        if (ra is not None and ra.kind == "missing") or (rb is not None and rb.kind == "missing"):
            side = [m.label for m, r in ((a, ra), (b, rb)) if r is not None and r.kind == "missing"]
            s["missing"].append("%s (tracked in git index but absent on disk: %s)" % (path, ", ".join(side)))
            continue
        if ra is None:
            s["only_b"].append(path)
            continue
        if rb is None:
            s["only_a"].append(path)
            continue
        if "unreadable" in (ra.kind, rb.kind):
            s["unreadable"].append("%s (%s: %s / %s: %s)" % (path, a.label, ra.kind, b.label, rb.kind))
            continue
        ca, cb = category(ra), category(rb)
        if ca != cb:
            if "symlink" in (ca, cb):
                s["symlink_diffs"].append("%s: %s is %s, %s is %s" % (path, a.label, ca, b.label, cb))
            else:
                s["type_mismatch"].append("%s: %s is %s, %s is %s" % (path, a.label, ca, b.label, cb))
            continue
        if ca == "symlink":
            if ra.target() == rb.target():
                s["symlink_same"] += 1
            else:
                s["symlink_diffs"].append("%s: target '%s' vs '%s'" % (path, ra.target(), rb.target()))
        elif ca == "submodule":
            if ra.blob == rb.blob:
                s["submodule_same"] += 1
            else:
                s["submodule_diffs"].append("%s: commit %s vs %s" % (path, ra.blob[:12], rb.blob[:12]))
        elif ca == "special":
            if ra.note == rb.note:
                s["special"].append("%s: %s on both sides; UNSUPPORTED, content cannot be compared "
                                    "(manual inspection)" % (path, ra.note))
            else:
                s["special"].append("%s: DIFFERENT special types (%s vs %s)" % (path, ra.note, rb.note))
        else:
            if ra.kind != rb.kind:
                s["class_diff"].append("%s: classified %s vs %s" % (path, ra.kind, rb.kind))
            if ra.sha != "NOT-COMPUTED" and rb.sha != "NOT-COMPUTED":
                if ra.sha == rb.sha:
                    s["identical"] += 1
                else:
                    s["different"].append("%s (size %s vs %s)" % (path, ra.size, rb.size))
            elif ra.size == rb.size:
                s["same_unverified"].append("%s (same size %s; hash not computed on one or both sides)"
                                            % (path, ra.size))
            else:
                s["size_mismatch"].append("%s (size %s vs %s; content not hashed, so not a proven "
                                          "content difference)" % (path, ra.size, rb.size))
    accounted = (s["identical"] + s["symlink_same"] + s["submodule_same"]
                 + sum(len(s[k]) for k in ("different", "only_a", "only_b", "same_unverified",
                                           "size_mismatch", "symlink_diffs", "submodule_diffs",
                                           "type_mismatch", "unreadable", "missing", "special")))
    s["paths"], s["accounted"] = len(universe), accounted
    print("  paths compared: %d, accounted for in the categories below: %d%s"
          % (len(universe), accounted, "" if accounted == len(universe) else "   <-- INTERNAL ERROR"))
    print("  identical (verified by SHA256): %d" % s["identical"])
    show("different content (verified by SHA256)", s["different"], limit)
    show("only in " + a.label, s["only_a"], limit)
    show("only in " + b.label, s["only_b"], limit)
    show("same size but UNVERIFIED (never counted as identical)", s["same_unverified"], limit)
    show("size mismatches (hash skipped)", s["size_mismatch"], limit)
    show("symlink differences (compared separately)", s["symlink_diffs"], limit)
    show("submodule commit differences", s["submodule_diffs"], limit)
    show("special files (unsupported; need manual inspection)", s["special"], limit)
    show("file-type mismatches", s["type_mismatch"], limit)
    show("tracked-in-git but absent on disk", s["missing"], limit)
    show("unreadable on at least one side", s["unreadable"], limit)
    show("classification differences (source/binary/model; also counted above)", s["class_diff"], limit)
    ea, eb = set(a.excluded), set(b.excluded)
    print("  excluded directories only in %s: %d, only in %s: %d (informational)"
          % (a.label, len(ea - eb), b.label, len(eb - ea)))
    results.append((a, b, s, len(skip)))


def parse_github(path):
    with open(path, "rb") as handle:
        data = handle.read()
    tree, errors, unsupported = {}, [], False
    if not data:
        return tree, errors, unsupported, "empty tree (0 bytes)"
    if b"\0" in data:
        entries = [e for e in data.split(b"\0") if e]
        mode = "NUL-separated (git ls-tree -z)"
    else:
        entries = [e for e in data.split(b"\n") if e]
        mode = "newline-separated (paths with unusual characters may be quoted by git)"
    for num, raw in enumerate(entries, 1):
        meta, tab, rawpath = raw.partition(b"\t")
        fields = meta.decode("ascii", "replace").split()
        if not tab or len(fields) != 3 or not rawpath:
            errors.append("tree entry %d: malformed" % num)
            continue
        fmode, ftype, sha = fields
        if (fmode, ftype) not in TREE_OK:
            errors.append("tree entry %d: invalid mode/type combination '%s %s'" % (num, fmode[:8], ftype[:8]))
            continue
        if HEX64.match(sha):
            unsupported = True
            continue
        if not HEX40.match(sha):
            errors.append("tree entry %d: invalid object id" % num)
            continue
        text = rawpath.decode("utf-8", "surrogateescape")
        if mode.startswith("newline") and text.startswith('"'):
            errors.append("tree entry %d: git-quoted path; regenerate with ls-tree -z" % num)
            continue
        key = esc(text)
        if key in tree:
            errors.append("tree entry %d: DUPLICATE path '%s'" % (num, key[:80]))
            continue
        tree[key] = (fmode, ftype, sha)
    return tree, errors, unsupported, mode


def compare_github(local, treefile, source, limit):
    """Returns (problem_count, results_or_None)."""
    print("\n=== %s  vs  GITHUB TREE (%s) ===" % (local.label, os.path.basename(treefile)))
    tree, errors, unsupported, mode = parse_github(treefile)
    print("  tree format: " + mode)
    explain = {"cached": "CACHED: produced from a local origin/main reference. It reflects GitHub as of "
                         "the last fetch and may be STALE. Compare leah_audit.sh --remote output to learn "
                         "whether it is current.",
               "fresh": "FRESH: described as freshly retrieved. This reflects GitHub at retrieval time.",
               "unknown": "UNKNOWN freshness: nothing says whether this tree is current."}[source]
    print("  " + explain)
    print("  The local manifest and the GitHub tree are different snapshots: local files may have "
          "changed since the manifest, and GitHub may have changed since the tree was made.")
    if local.errors:
        print("  WARNING: manifest '%s' has %d problem(s); %d record path(s) are EXCLUDED, so this "
              "comparison is INCOMPLETE." % (local.label, len(local.errors), len(local.invalid)))
    if unsupported or local.header.get("git_object_format", "sha1") not in ("sha1", "-"):
        print("  UNSUPPORTED: SHA-256 object format detected (tree or local repository). "
              "Blob comparison would be misleading, so it was NOT performed.")
        return 1 + len(errors), None
    show("malformed or rejected tree entries", errors, limit)
    c = dict((k, []) for k in ("differs", "unverified", "untracked", "ignored", "tracked_not_in_tree",
                               "local_other", "type", "sub_diff", "missing_in_tree", "missing_but_remote",
                               "special", "unreadable", "remote_only", "remote_under_excluded",
                               "remote_unverifiable", "exec_diffs"))
    c["match"], c["sub_match"], c["trees"] = 0, 0, 0
    modes_known = local.header.get("modes_recorded") == "1"
    excl = list(local.excluded)
    locals_ = [(p, r) for p, r in sorted(local.rows.items()) if p not in local.invalid]
    for path, r in locals_:
        t = tree.get(path)
        if r.kind == "missing":
            (c["missing_but_remote"] if t else c["missing_in_tree"]).append(path)
            continue
        if r.kind == "special":
            c["special"].append("%s (%s; unsupported, not in Git)" % (path, r.note) if t is None
                                else "%s (local %s, GitHub mode %s)" % (path, r.note, t[0]))
            continue
        if r.kind == "unreadable":
            c["unreadable"].append(path)
            continue
        if t is None:
            label = "%s (local state: %s)" % (path, r.state)
            if r.state in ("untracked", "untracked-nested-repo"):
                c["untracked"].append(label)
            elif r.state == "ignored":
                c["ignored"].append(label)
            elif r.state.startswith("tracked"):
                c["tracked_not_in_tree"].append(label)
            else:
                c["local_other"].append(label)
            continue
        fmode, ftype, sha = t
        if r.kind == "submodule":
            if fmode == "160000":
                if r.blob == sha:
                    c["sub_match"] += 1
                else:
                    c["sub_diff"].append("%s: local %s vs GitHub %s" % (path, r.blob[:12], sha[:12]))
            else:
                c["type"].append("%s: local submodule, GitHub mode %s" % (path, fmode))
        elif r.kind == "symlink":
            if fmode != "120000":
                c["type"].append("%s: local symlink, GitHub mode %s" % (path, fmode))
            elif r.blob == sha:
                c["match"] += 1
            else:
                c["differs"].append("%s (symlink target differs)" % path)
        else:
            if fmode in ("120000", "160000", "040000"):
                c["type"].append("%s: local file, GitHub mode %s" % (path, fmode))
            else:
                if modes_known:
                    local_exec, remote_exec = "exec" in r.flags(), fmode == "100755"
                    if local_exec != remote_exec:
                        c["exec_diffs"].append("%s: local %s, GitHub mode %s"
                                               % (path, "executable" if local_exec else "not executable", fmode))
                if r.blob == "NOT-COMPUTED":
                    c["unverified"].append("%s (hash not computed locally)" % path)
                elif r.blob == sha:
                    c["match"] += 1
                else:
                    note = " [LFS pointer locally]" if "lfs-pointer" in r.flags() else ""
                    c["differs"].append("%s (local state: %s)%s" % (path, r.state, note))
    local_all = set(local.rows) | set(local.invalid)
    for path in sorted(tree):
        if tree[path][1] == "tree":
            c["trees"] += 1
            continue
        if path in local.invalid:
            c["remote_unverifiable"].append(path)
        elif path in local.rows:
            continue
        elif any(under(path, e) for e in excl):
            c["remote_under_excluded"].append(path)
        else:
            c["remote_only"].append(path)
    local_total = len(locals_)
    accounted = (c["match"] + c["sub_match"]
                 + sum(len(c[k]) for k in ("differs", "unverified", "untracked", "ignored",
                                           "tracked_not_in_tree", "local_other", "type", "sub_diff",
                                           "missing_in_tree", "missing_but_remote", "special",
                                           "unreadable")))
    c["local_total"], c["accounted"] = local_total, accounted
    print("  local records compared: %d, accounted for below: %d%s"
          % (local_total, accounted, "" if accounted == local_total else "   <-- INTERNAL ERROR"))
    print("  identical to GitHub (git blob id match): %d   (submodule commits matching: %d)"
          % (c["match"], c["sub_match"]))
    show("different from GitHub", c["differs"], limit)
    show("remote-only (in GitHub tree, absent from local manifest)", c["remote_only"], limit)
    show("remote-only but inside a directory excluded from the manifest", c["remote_under_excluded"], limit)
    show("in GitHub tree but its local record was invalid (not compared)", c["remote_unverifiable"], limit)
    show("tracked locally but not in this GitHub tree (unpushed, or different ref)", c["tracked_not_in_tree"], limit)
    show("local-only: untracked", c["untracked"], limit)
    show("local-only: ignored by .gitignore", c["ignored"], limit)
    show("local-only: state unknown", c["local_other"], limit)
    show("tracked in git but missing locally (and present on GitHub)", c["missing_but_remote"], limit)
    show("tracked in local index, missing locally, not in this GitHub tree", c["missing_in_tree"], limit)
    show("submodule commit differences", c["sub_diff"], limit)
    show("type mismatches (file/symlink/submodule)", c["type"], limit)
    show("special files (unsupported; need manual inspection)", c["special"], limit)
    show("unreadable locally", c["unreadable"], limit)
    show("unverified (hash not computed)", c["unverified"], limit)
    if modes_known:
        show("executable-bit differences (Git modes 100644 vs 100755; NOT full Unix permissions)",
             c["exec_diffs"], limit)
    else:
        print("  executable-bit comparison NOT performed: the manifest has no mode information "
              "(created by an earlier build).")
    if local.header.get("lfs_gitattributes") == "1" or any("lfs-pointer" in r.flags() for r in local.rows.values()):
        print("  LFS NOTE: this repository uses Git LFS. GitHub trees contain LFS pointer files, so a "
              "locally downloaded large file will appear 'different'. That is expected, not corruption.")
    print("  Not compared: full Unix permissions, ownership, timestamps, and line-ending or filter conversions.")
    return len(errors), c


def die(message):
    sys.stderr.write(message + "\n")
    sys.exit(2)


def nonneg(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("--max must be a whole number, got '%s'" % value)
    if number < 0:
        raise argparse.ArgumentTypeError("--max must not be negative")
    return number


def main():
    parser = argparse.ArgumentParser(description="Compare LEAH audit manifests (read-only).")
    parser.add_argument("manifests", nargs="+", help="label=path pairs; first one is the baseline")
    parser.add_argument("--github", help="git ls-tree -r -z output")
    parser.add_argument("--github-source", choices=("cached", "fresh", "unknown"), default="unknown")
    parser.add_argument("--max", type=nonneg, default=40)
    args = parser.parse_args()

    manifests, labels = [], set()
    for item in args.manifests:
        label, eq, path = item.partition("=")
        if not eq or not label or not path:
            die("Use label=path (for example laptop=manifest_repo.tsv), got: %s" % item)
        if not LABEL.match(label):
            die("Label '%s' may only contain letters, digits, '_', '.', '-'." % label)
        if label in labels:
            die("Duplicate label '%s'. Every manifest needs a unique label." % label)
        labels.add(label)
        try:
            manifests.append(load_manifest(label, path))
        except OSError as error:
            die("Cannot read manifest '%s' at %s: %s\n"
                     "Run leah_audit.sh on that machine and copy its manifest_*.tsv here."
                     % (label, path, error.strerror or error))
    if len(manifests) < 2 and not args.github:
        die("Give at least two manifests, or one manifest plus --github.")
    if args.github and not os.path.isfile(args.github):
        die("Cannot read GitHub tree file: %s" % args.github)

    print("=== MANIFEST CHECKS ===")
    for m in manifests:
        status = "OK" if not m.errors else "%d PROBLEM(S)" % len(m.errors)
        extra = "  (no usable file records)" if not m.rows and not m.empty_file else ""
        print("  %-10s %d file records, %d excluded dirs: %s%s" % (m.label, len(m.rows), len(m.excluded), status, extra))
        for e in m.errors[:args.max]:
            print("      " + e)
        if len(m.errors) > args.max:
            print("      ... %d more" % (len(m.errors) - args.max))

    snapshot_notes(manifests)
    results = []
    for other in manifests[1:]:
        compare_pair(manifests[0], other, args.max, results)
    gh_problems, gh = 0, None
    if args.github:
        gh_problems, gh = compare_github(manifests[0], args.github, args.github_source, args.max)

    manifest_problems = sum(len(m.errors) for m in manifests)
    unreadable_records = sum(m.count_kind("unreadable") for m in manifests)
    special_records = sum(m.count_kind("special") for m in manifests)
    internal = any(s["accounted"] != s["paths"] for _, _, s, _ in results)
    if gh is not None and gh["accounted"] != gh["local_total"]:
        internal = True

    print("\n=== SUMMARY ===")
    print("  data problems, each counted ONCE:")
    for m in manifests:
        print("    %-10s manifest problems=%d, unreadable records=%d, special files (manual inspection)=%d"
              % (m.label, len(m.errors), m.count_kind("unreadable"), m.count_kind("special")))
    if args.github:
        print("    GitHub tree: %s" % ("NOT compared (unsupported object format)" if gh is None
                                       else "%d malformed/rejected entries" % gh_problems))
    for a, b, s, skipped in results:
        print("  %s vs %s   (%d paths, %d excluded for validation errors)" % (a.label, b.label, s["paths"], skipped))
        print("    identical verified files        : %d" % s["identical"])
        print("    different verified files        : %d" % len(s["different"]))
        print("    only in %-14s          : %d" % (a.label, len(s["only_a"])))
        print("    only in %-14s          : %d" % (b.label, len(s["only_b"])))
        print("    same-size UNVERIFIED files      : %d" % len(s["same_unverified"]))
        print("    size mismatches (hash skipped)  : %d" % len(s["size_mismatch"]))
        print("    symlink differences             : %d" % len(s["symlink_diffs"]))
        print("    submodule differences           : %d" % len(s["submodule_diffs"]))
        print("    special files (manual)          : %d" % len(s["special"]))
        print("    type mismatches                 : %d" % len(s["type_mismatch"]))
        print("    tracked-but-absent / unreadable : %d / %d" % (len(s["missing"]), len(s["unreadable"])))
        print("    accounting                      : %d of %d paths" % (s["accounted"], s["paths"]))
    if gh is not None:
        print("  GitHub: match=%d differ=%d remote-only=%d untracked-local=%d executable-bit differences=%d "
              "malformed-tree-entries=%d" % (gh["match"], len(gh["differs"]), len(gh["remote_only"]),
                                              len(gh["untracked"]), len(gh["exec_diffs"]), gh_problems))
    total = manifest_problems + unreadable_records + gh_problems
    print("  data problems found (malformed + unreadable + tree/format): %d" % total)
    if internal:
        print("  VERDICT: INTERNAL ACCOUNTING ERROR in this tool; do not trust the numbers above.")
        sys.exit(4)
    if total:
        print("  VERDICT: NOT TRUSTWORTHY - %d data problem(s) are listed above; excluded records mean the "
              "comparison is incomplete." % total)
        sys.exit(3)
    note = " (%d special file record(s) need manual inspection)" % special_records if special_records else ""
    print("  VERDICT: comparison complete; all inputs were valid%s." % note)
    sys.exit(0)


if __name__ == "__main__":
    main()
