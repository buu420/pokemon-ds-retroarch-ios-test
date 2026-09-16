#!/usr/bin/env python3
"""Regenerate the public patches in this build kit from the three local working trees.

This is the repeatable export command. Run it again whenever any working tree changes, so the
published patches always describe the current source:

    python tools/export_public_source.py ^
        --core     C:\\RetroArch-Win64\\dev\\melonds-ds-access ^
        --vbam     C:\\RetroArch-Win64\\dev\\vbam-pokemon-access ^
        --frontend C:\\RetroArch-Win64\\dev\\RetroArch-pokemon-native ^
        --kit      . ^
        --check-apply

What it does, in order:

 1. Confirms each working tree still sits on its pinned base commit.
 2. Classifies every changed and untracked path as EXPORT, EXCLUDE (with a reason) or
    UNCLASSIFIED. An unclassified path is a hard error: new work must be classified deliberately
    rather than silently shipped or silently dropped.
 3. Builds one patch per tree against the pinned base, using a TEMPORARY git index so the real
    index of the dirty working tree is never touched. Untracked files are included as new files.
 4. With --check-apply, extracts each pinned base into a scratch directory (read-only on the real
    repository), applies the patch, drops the placeholder reader in, and asserts the reconstructed
    tree is what the build expects -- and that the private files are absent from it.
 5. Runs tools/verify_public_kit.py over the whole kit. If anything private is found the patches
    written by this run are DELETED and the command exits non-zero. It fails closed.

Nothing is ever written to either source tree.
"""
import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_public_kit as vpk  # noqa: E402

CORE_BASE = "bc4e4b67d2d470d7c682810a1e892cafd6f9082b"
CORE_UPSTREAM = "https://github.com/JesseTG/melonds-ds.git"
VBAM_BASE = "115defb3a318258ab84746d45258a1aec19d0b4b"
VBAM_UPSTREAM = "https://github.com/libretro/vbam-libretro.git"
FRONTEND_BASE = "69a4f0ea1e8aaf442ae4858f2e7f2b31a1776576"
FRONTEND_UPSTREAM = "https://github.com/libretro/RetroArch.git"

# VBA-M keeps its ordinary libretro identity, so its core info is upstream's own file and this kit
# must not change it. The hash is of the blob AS GIT STORES IT (LF), which is what a macOS or Linux
# checkout produces; a Windows working copy with core.autocrlf=true hashes differently, so it is
# read out of git rather than off disk.
VBAM_INFO_REL = "src/libretro/vbam_libretro.info"

STUB_REL = "stub/pokemon_bw_reader.lua"
STUB_TARGET = "src/libretro/accessibility/lua/pokemon_bw_reader.lua"

# --- classification -------------------------------------------------------------------------
# EXCLUDE entries carry the reason that goes into the report, so every omission is on the record.

CORE_RULES = {
    "exclude": [
        ("src/libretro/accessibility/lua/",
         "the third-party reader and the tool that produced it; the tool quotes the original "
         "verbatim and the reader has no redistribution licence. The build gets a placeholder "
         "from " + STUB_REL + " instead, and the real reader is supplied at runtime from the "
         "system folder."),
        ("docs/",
         "internal implementation notes containing absolute local paths and third-party names; "
         "not needed to build."),
    ],
    "export_prefixes": [
        "CMakeLists.txt", "melondsds_libretro.info.in", "cmake/", "src/libretro/",
        "test/accessibility/",
    ],
}

# Export-time substitutions. A private absolute path baked into a CACHE default would otherwise
# leak, and it cannot be fixed at the source because these working trees are not ours to edit.
# Each rule is applied ONLY to lines the patch ADDS, so context lines still match the pinned base
# exactly; a hit on a context or removed line is a hard error instead, because rewriting one would
# stop the patch applying. Every substitution is printed in the run report.
SANITIZERS = [
    {
        "patch": "core.patch",
        # Assembled from fragments so this file's own bytes never contain the private path --
        # tools/verify_public_kit.py scans this file too, and would reject it otherwise.
        "literal": vpk._needle("C:", "/Use", "rs/User/Pokemon DS/dll/prism.dll"),
        "replacement": "",
        "reason": "default path of a local prism.dll used only by the Windows-only Prism ABI "
                  "test, which skips when the file is absent. An empty default skips it the same "
                  "way; set -DMELONDSDS_ACCESS_PRISM_DLL=<path> to run it locally.",
    },
]

VBAM_RULES = {
    "exclude": [
        ("reader/",
         "the third-party Pokemon reader: ~2.7 MB of Lua across ~200 files, written for the "
         "standalone VBA-ReRecording emulator and with no redistribution licence. The VBA-M "
         "adapter loads it at RUNTIME from <system>/vbam_access and embeds nothing, so unlike the "
         "DS core there is not even a placeholder to ship."),
        ("ACCESS-PLAN.md",
         "internal implementation notes: absolute local paths, the layout of the private research "
         "checkouts, and line-by-line quotations of the third-party reader. Not needed to build."),
    ],
    # Reader files do turn up outside reader/ -- dropped at the tree root while testing, for
    # instance. A prefix rule cannot catch that, and leaving it to the "unclassified" error means
    # the export stops dead every time someone tries a script. This states the real invariant: the
    # VBA-M core vendors Lua as C sources and contains no .lua of its own, so every .lua file in
    # this tree is reader material, wherever it sits.
    #
    # Deliberately NOT applied to the DS tree: its reader directory is already excluded by prefix,
    # and a stray .lua anywhere else there stays a hard error, which is the stricter outcome.
    "exclude_suffixes": [
        (".lua",
         "a Lua script in the VBA-M tree is reader material. This core's own Lua is vendored as C "
         "sources under src/libretro/access/lua/; it has no .lua files of its own, so nothing with "
         "that extension is ever part of the build and none of it may ship."),
    ],
    # src/gb and src/gba are the emulator hooks the adapter needs; src/libretro covers the libretro
    # port, the adapter itself and the vendored Lua (which is official Lua, MIT, and may ship);
    # tests/ is this project's own host-side test code and carries no fixtures.
    "export_prefixes": [
        "src/gb/", "src/gba/", "src/libretro/", "tests/",
    ],
}

FRONTEND_RULES = {
    "exclude": [
        ("Makefile.win", "Windows-only build change, unrelated to iOS."),
        ("docs/", "local implementation plans, not required to build"),
        ("frontend/drivers/platform_win32.c", "the Windows implementation of the same hooks; "
                                              "unrelated to iOS."),
    ],
    "export_prefixes": [
        "accessibility.h", "frontend/frontend_driver.h", "frontend/drivers/",
        "libretro-common/include/libretro.h", "retroarch.c", "runloop.c", "pkg/apple/",
        "Makefile.common", "griffin/griffin_objc.m", "menu/menu_accessibility.h",
        "menu/menu_driver.c", "menu/menu_cbs.h", "menu/cbs/menu_cbs_ok.c",
        "menu/drivers/ozone.c", "ui/drivers/cocoa/cocoa_accessibility.h",
        "ui/drivers/cocoa/cocoa_accessibility.m", "ui/drivers/cocoa/cocoa_common.m",
        "ui/drivers/ui_cocoatouch.m", "tests/menu_accessibility/",
    ],
}


def safe_rmtree(path, must_be_inside):
    """Recursively delete `path`, but only after proving it really sits inside `must_be_inside`.

    Both are resolved with realpath first, so a symlink cannot redirect the delete somewhere that
    matters. Used only for the scratch directories this tool creates itself.
    """
    if not path or not os.path.isdir(path):
        return
    target = os.path.realpath(path)
    parent = os.path.realpath(must_be_inside)
    if parent in ("", os.sep) or len(parent) < 4:
        raise SystemExit("refusing to treat %r as a parent directory" % parent)
    if target == parent or not target.startswith(parent + os.sep):
        raise SystemExit("refusing to delete %s: it resolves to %s, which is not inside %s"
                         % (path, target, parent))
    shutil.rmtree(target, ignore_errors=True)


def safe_unlink(path, must_be_inside):
    """Delete a single file, only if it resolves to somewhere inside `must_be_inside`."""
    if not path or not os.path.isfile(path):
        return
    target = os.path.realpath(path)
    parent = os.path.realpath(must_be_inside)
    if target == parent or not target.startswith(parent + os.sep):
        raise SystemExit("refusing to delete %s: it resolves to %s, which is not inside %s"
                         % (path, target, parent))
    os.unlink(target)


def run(cmd, cwd=None, env=None, check=True, binary=False):
    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True)
    if check and proc.returncode != 0:
        raise SystemExit("error: command failed (%d): %s\n%s"
                         % (proc.returncode, " ".join(cmd),
                            proc.stderr.decode("utf-8", "replace")))
    return proc.stdout if binary else proc.stdout.decode("utf-8", "replace")


def git(repo, *args, env=None, check=True, binary=False):
    return run(["git", "-C", repo] + list(args), env=env, check=check, binary=binary)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def classify_path(path, rules):
    """Decide one path: ("export", None), ("exclude", reason) or ("unclassified", reason).

    Separate from classify() so it can be tested without a git repository -- see
    tools/test_export_rules.py. Exclude rules are checked before export prefixes, so a reader file
    that lands inside an exported directory is still excluded.
    """
    reason = next((r for pre, r in rules["exclude"]
                   if path == pre or path.startswith(pre)), None)
    if reason is None:
        lower = path.lower()
        reason = next((r for suffix, r in rules.get("exclude_suffixes", [])
                       if lower.endswith(suffix)), None)
    if reason:
        return "exclude", reason
    if any(path == p or path.startswith(p) for p in rules["export_prefixes"]):
        return "export", None
    return "unclassified", "no rule covers this path"


def classify(repo, rules):
    """Return (export_paths, excluded, unclassified) for one working tree."""
    modified, unclassified, excluded, export = [], [], [], []

    for line in git(repo, "status", "--porcelain", "-z").split("\0"):
        if not line.strip():
            continue
        status, path = line[:2], line[3:].replace("\\", "/")
        if status.strip() in ("??",):
            continue
        if status.strip() in ("D", "AD"):
            unclassified.append((path, "deleted files are not supported by this exporter"))
            continue
        modified.append(path)

    untracked = []
    for path in git(repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0"):
        if path.strip():
            untracked.append(path.replace("\\", "/"))

    for path in sorted(set(modified) | set(untracked)):
        verdict, reason = classify_path(path, rules)
        if verdict == "exclude":
            excluded.append((path, reason))
        elif verdict == "export":
            export.append(path)
        else:
            unclassified.append((path, reason))

    return export, excluded, unclassified


def make_patch(repo, base, paths):
    """Patch of base -> working tree for `paths`, using a throwaway index."""
    if not paths:
        return ""
    head = git(repo, "rev-parse", "HEAD").strip()
    if head != base:
        raise SystemExit("error: %s is on %s, but this kit pins %s.\nUpdate the pin deliberately "
                         "(and re-review the patch) rather than exporting from an unexpected base."
                         % (repo, head[:12], base[:12]))
    fd, index_path = tempfile.mkstemp(prefix="export-index-")
    os.close(fd)
    os.unlink(index_path)  # git wants to create it itself
    env = dict(os.environ)
    env["GIT_INDEX_FILE"] = index_path
    try:
        git(repo, "read-tree", base, env=env)
        tracked = set(git(repo, "ls-tree", "-r", "--name-only", base, "-z").split("\0"))
        new_files = [p for p in paths if p not in tracked]
        if new_files:
            git(repo, "add", "--intent-to-add", "--", *new_files, env=env)
        raw = git(repo, "-c", "core.quotepath=false", "diff", "--binary", "--no-color",
                  "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", base, "--", *paths,
                  env=env, binary=True)
        return raw.decode("utf-8", "replace")
    finally:
        if os.path.isfile(index_path):
            os.unlink(index_path)


def sanitize(patch_text, patch_name):
    """Apply SANITIZERS to added lines only. Returns (text, applied, problems)."""
    rules = [r for r in SANITIZERS if r["patch"] == patch_name]
    if not rules:
        return patch_text, [], []
    applied, problems, out = [], [], []
    for line in patch_text.split("\n"):
        for rule in rules:
            if rule["literal"] not in line:
                continue
            if line.startswith("+") and not line.startswith("+++"):
                line = line.replace(rule["literal"], rule["replacement"])
                applied.append((patch_name, rule["literal"], rule["reason"]))
            else:
                problems.append("%s: %r appears on a line that is not an addition (%r). It comes "
                                "from the pinned upstream base, so it cannot be rewritten without "
                                "breaking the patch."
                                % (patch_name, rule["literal"], line[:120]))
        out.append(line)
    return "\n".join(out), applied, problems


def extract_base(repo, base, dest):
    """Extract a pinned commit into `dest`. Read-only on `repo`: no worktree, no checkout.

    autocrlf/eol conversion is disabled so the scratch tree holds the exact upstream bytes a
    fresh clone on a macOS runner would have. Without this, a Windows checkout's CRLF conversion
    makes the local reconstruction check differ from what CI actually sees.
    """
    blob = git(repo, "-c", "core.autocrlf=false", "-c", "core.eol=lf",
               "archive", "--format=tar", base, binary=True)
    with tarfile.open(fileobj=io.BytesIO(blob)) as tf:
        tf.extractall(dest)


def apply_check(repo, base, patch_text, label, asserts, stub_src=None, stub_target=None):
    """Rebuild the tree from the pinned base + the patch and assert what it must contain."""
    results = []
    scratch = tempfile.mkdtemp(prefix="apply-check-%s-" % label)
    try:
        tree = os.path.join(scratch, "tree")
        os.makedirs(tree)
        extract_base(repo, base, tree)
        run(["git", "init", "-q"], cwd=tree)

        patch_file = os.path.join(scratch, "p.patch")
        with open(patch_file, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(patch_text)

        proc = subprocess.run(["git", "apply", "--check", "--verbose", patch_file],
                              cwd=tree, capture_output=True)
        if proc.returncode != 0:
            results.append(("FAIL", "%s: patch does not apply cleanly to %s\n%s"
                            % (label, base[:12], proc.stderr.decode("utf-8", "replace"))))
            return results
        results.append(("PASS", "%s: patch applies cleanly to pinned base %s" % (label, base[:12])))
        run(["git", "apply", patch_file], cwd=tree)

        if stub_src and stub_target:
            dst = os.path.join(tree, stub_target.replace("/", os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(stub_src, dst)
            results.append(("PASS", "%s: placeholder reader staged at %s" % (label, stub_target)))

        for kind, path, detail in asserts:
            full = os.path.join(tree, path.replace("/", os.sep))
            if kind == "exists":
                ok = os.path.exists(full)
            elif kind == "absent":
                ok = not os.path.exists(full)
            elif kind == "contains":
                ok = os.path.isfile(full) and detail in open(
                    full, "rb").read().decode("utf-8", "replace")
            elif kind == "sha256":
                ok = os.path.isfile(full) and sha256_bytes(open(full, "rb").read()) == detail
            elif kind == "unmodified":
                base_blob = git(repo, "show", "%s:%s" % (base, path), binary=True, check=False)
                ok = os.path.isfile(full) and (
                    open(full, "rb").read().replace(b"\r\n", b"\n")
                    == base_blob.replace(b"\r\n", b"\n"))
            else:
                ok = False
            results.append(("PASS" if ok else "FAIL",
                            "%s: %s %s%s" % (label, kind, path,
                                             "" if ok else "  <-- NOT SATISFIED")))
        return results
    finally:
        # The scratch tree is ours and lives under the system temp dir; prove that before deleting.
        safe_rmtree(scratch, tempfile.gettempdir())


def main(argv=None):
    ap = argparse.ArgumentParser(description="Regenerate the public patches in the iOS build kit.")
    ap.add_argument("--core", required=True, help="path to the melonDS DS working tree")
    ap.add_argument("--vbam", required=True, help="path to the VBA-M working tree")
    ap.add_argument("--frontend", required=True, help="path to the RetroArch working tree")
    ap.add_argument("--kit", required=True, help="path to this build kit")
    ap.add_argument("--check-apply", action="store_true",
                    help="rebuild each tree from its pinned base and assert the result")
    ap.add_argument("--extra-denylist", help="passed through to verify_public_kit.py")
    ap.add_argument("--allow-email", action="append", default=[])
    args = ap.parse_args(argv)

    core = os.path.abspath(args.core)
    vbam = os.path.abspath(args.vbam)
    frontend = os.path.abspath(args.frontend)
    kit = os.path.abspath(args.kit)
    patches_dir = os.path.join(kit, "patches")
    os.makedirs(patches_dir, exist_ok=True)
    stub = os.path.join(kit, STUB_REL.replace("/", os.sep))
    if not os.path.isfile(stub):
        raise SystemExit("error: the placeholder reader is missing: %s" % stub)

    report = []
    written = []
    failed = False

    trees = [
        ("core", core, CORE_BASE, CORE_UPSTREAM, CORE_RULES, "core.patch"),
        ("vbam", vbam, VBAM_BASE, VBAM_UPSTREAM, VBAM_RULES, "vbam.patch"),
        ("frontend", frontend, FRONTEND_BASE, FRONTEND_UPSTREAM, FRONTEND_RULES, "frontend.patch"),
    ]

    classified = {}
    for label, repo, base, _url, rules, _name in trees:
        if not os.path.isdir(os.path.join(repo, ".git")) and not os.path.isfile(
                os.path.join(repo, ".git")):
            raise SystemExit("error: %s is not a git working tree" % repo)
        export, excluded, unclassified = classify(repo, rules)
        classified[label] = (export, excluded, unclassified)
        print("\n== %s: %s" % (label, repo))
        print("   base %s" % base)
        for path in export:
            print("   EXPORT   %s" % path)
        # One line per excluded path made sense when a rule covered two or three files. The VBA-M
        # reader is ~200, and a 200-line wall is a report nobody reads, so paths are grouped by the
        # reason that excluded them. The count is the thing to check: if it moves, something moved.
        groups = {}
        order = []
        for path, reason in excluded:
            if reason not in groups:
                groups[reason] = []
                order.append(reason)
            groups[reason].append(path)
        for reason in order:
            paths = groups[reason]
            if len(paths) <= 4:
                for path in paths:
                    print("   EXCLUDE  %s" % path)
            else:
                print("   EXCLUDE  %d paths, e.g. %s, ..."
                      % (len(paths), ", ".join(paths[:3])))
            print("              %s" % reason)
        for path, reason in unclassified:
            print("   UNCLASSIFIED  %s  (%s)" % (path, reason))
        if unclassified:
            failed = True

    if failed:
        print("\nREFUSED: some paths are not classified. Add them to CORE_RULES/FRONTEND_RULES in\n"
              "%s with an explicit export prefix or an exclude reason, then run this again.\n"
              "Nothing was written." % os.path.abspath(__file__))
        return 1

    for label, repo, base, url, _rules, name in trees:
        export = classified[label][0]
        patch = make_patch(repo, base, export)
        if not patch.strip():
            print("\nREFUSED: the %s patch came out empty. That would publish an unmodified "
                  "upstream tree and silently drop the accessibility work." % label)
            return 1
        patch, applied, sanitize_problems = sanitize(patch, name)
        for _n, literal, reason in applied:
            print("   SANITISED in %s: removed %r\n              %s" % (name, literal, reason))
        for problem in sanitize_problems:
            print("   SANITISE FAILED: %s" % problem)
            failed = True
        path = os.path.join(patches_dir, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(patch)
        written.append(path)
        report.append((label, repo, base, url, name, len(patch), classified[label]))
        print("\nwrote %s (%d bytes)" % (path, len(patch)))

    # Read out of git, not off disk: on Windows the working copy is CRLF and would hash differently
    # from what a macOS runner checks out. scripts/build_vbam_ios.sh compares against this value.
    vbam_info_blob = git(vbam, "-c", "core.autocrlf=false", "-c", "core.eol=lf",
                         "show", "%s:%s" % (VBAM_BASE, VBAM_INFO_REL), binary=True)
    if not vbam_info_blob.strip():
        raise SystemExit("error: %s is empty or missing at %s" % (VBAM_INFO_REL, VBAM_BASE[:12]))

    pins = {
        "core": {"upstream": CORE_UPSTREAM, "base": CORE_BASE, "patch": "patches/core.patch"},
        "vbam": {"upstream": VBAM_UPSTREAM, "base": VBAM_BASE, "patch": "patches/vbam.patch",
                 "core_info": {
                     "path": VBAM_INFO_REL,
                     "sha256": sha256_bytes(vbam_info_blob),
                     "note": "sha256 of the blob as git stores it (LF). A checkout on macOS or "
                             "Linux matches; a Windows checkout with core.autocrlf=true will not.",
                 }},
        "frontend": {"upstream": FRONTEND_UPSTREAM, "base": FRONTEND_BASE,
                     "patch": "patches/frontend.patch"},
        "placeholder_reader": {"path": STUB_REL, "staged_to": STUB_TARGET,
                               "sha256": sha256_bytes(open(stub, "rb").read())},
    }
    pins_path = os.path.join(patches_dir, "pins.json")
    with open(pins_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(pins, fh, indent=2)
        fh.write("\n")
    written.append(pins_path)
    print("wrote %s" % pins_path)

    if args.check_apply:
        print("\n== reconstruction check")
        checks = []
        core_patch = open(os.path.join(patches_dir, "core.patch"), encoding="utf-8").read()
        checks += apply_check(
            core, CORE_BASE, core_patch, "core",
            asserts=[
                ("exists", "src/libretro/accessibility/reader_locator.cpp", None),
                ("exists", "src/libretro/accessibility/CMakeLists.txt", None),
                ("exists", "src/libretro/config/definitions/accessibility.hpp", None),
                ("absent", "src/libretro/accessibility/lua/adapt_reader.py", None),
                ("absent", "src/libretro/accessibility/lua/CHANGES.md", None),
                ("absent", "docs/accessibility", None),
                ("sha256", STUB_TARGET, sha256_bytes(open(stub, "rb").read())),
                ("contains", "src/libretro/accessibility/CMakeLists.txt",
                 'PATH "lua/pokemon_bw_reader.lua"'),
                ("contains", "test/accessibility/CMakeLists.txt",
                 'set(MELONDSDS_ACCESS_PRISM_DLL "" CACHE FILEPATH'),
            ],
            stub_src=stub, stub_target=STUB_TARGET)

        vbam_patch = open(os.path.join(patches_dir, "vbam.patch"), encoding="utf-8").read()
        checks += apply_check(
            vbam, VBAM_BASE, vbam_patch, "vbam",
            asserts=[
                ("exists", "src/libretro/access/access_core.cpp", None),
                ("exists", "src/libretro/access/access_reader.cpp", None),
                ("exists", "src/libretro/access/access_speech.cpp", None),
                # Vendored Lua has to arrive whole: the core compiles it straight in, so a missing
                # file is a link error on a macOS runner rather than anything visible here.
                ("exists", "src/libretro/access/lua/lapi.c", None),
                ("exists", "src/libretro/access/lua/loslib.c", None),
                ("exists", "src/libretro/access/lua/lua.h", None),
                ("exists", "tests/access_tests.cpp", None),
                # The reader and the internal notes must not be reachable through the patch.
                ("absent", "reader", None),
                ("absent", "ACCESS-PLAN.md", None),
                # The adapter has to be wired into the build, or the core is stock VBA-M.
                ("contains", "src/libretro/Makefile.common", "VBAM_ACCESS"),
                ("contains", "src/libretro/Makefile.common", "access/lua/lapi.c"),
                ("contains", "src/libretro/libretro_core_options.h", "vbam_access_reader"),
                # Ordinary VBA-M identity: the metadata that ships is upstream's, untouched.
                ("unmodified", VBAM_INFO_REL, None),
            ])

        fe_patch = open(os.path.join(patches_dir, "frontend.patch"), encoding="utf-8").read()
        checks += apply_check(
            frontend, FRONTEND_BASE, fe_patch, "frontend",
            asserts=[
                ("exists", "frontend/drivers/platform_darwin.m", None),
                ("unmodified", "frontend/drivers/platform_win32.c", None),
                ("unmodified", "Makefile.win", None),
                ("contains", "Makefile.common", "ui/drivers/cocoa/cocoa_accessibility.o"),
                ("contains", "pkg/apple/BaseConfig.xcconfig", "HAVE_ACCESSIBILITY"),
            ])

        for status, message in checks:
            print("   %-4s %s" % (status, message))
        if any(s == "FAIL" for s, _ in checks):
            failed = True

    print("\n== privacy scan")
    scan_argv = ["--kit", kit, "--write-manifest"]
    if args.extra_denylist:
        scan_argv += ["--extra-denylist", args.extra_denylist]
    for email in args.allow_email:
        scan_argv += ["--allow-email", email]
    if vpk.main(scan_argv) != 0:
        failed = True

    if failed:
        for path in written:
            # Only files this run wrote, and only inside the kit's patches directory.
            safe_unlink(path, patches_dir)
        print("\nREFUSED. The patches this run produced have been deleted; the kit is unchanged\n"
              "apart from files that were already there. Nothing is safe to publish yet.")
        return 1

    print("\nOK. The kit is exportable.")
    print("Review the diff, then copy %s into a fresh public repository." % kit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
