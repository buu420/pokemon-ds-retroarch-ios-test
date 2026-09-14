#!/usr/bin/env python3
"""Fail-closed check that the build kit contains nothing private.

The kit is meant to become a PUBLIC repository. The accessibility work in it is original and may
ship; three kinds of thing must never leave the machine it was built on:

  * the Pokemon Black/White reader script (~2 MB, third party, no established redistribution
    licence) and anything derived from it verbatim,
  * ROMs, saves, BIOS/firmware images, prebuilt binaries and local logs,
  * anything identifying: absolute user paths, e-mail addresses, credentials.

Every rule refuses by default. A file the scanner cannot classify is a failure, not a pass.

    python tools/verify_public_kit.py --kit .

Exit 0 clean, 1 something private was found, 2 usage error.

Note on the deny needles below: they are assembled from fragments at import time, so this file's
own bytes never contain the strings it searches for. Without that, the scanner would flag itself
and every run would fail.
"""
import argparse
import hashlib
import json
import os
import re
import sys


def _needle(*parts):
    """Join fragments so the resulting string never appears literally in this source file."""
    return "".join(parts)


# sha256 of the real reader. Its presence anywhere in the kit, under any name, is fatal.
PRIVATE_READER_SHA256 = _needle("3dcfee975bf37c5df43c808c714", "26b0af5eca87d2d572a948bc9bdd4f820f518")
# sha256 of the third-party original the reader was adapted from.
PRIVATE_ORIGINAL_SHA256 = _needle("abb737844a5ef78b6b1394ab3e2", "febc7492247b3ab3cbd6420cca9dd58e2649c")

# The only file in the kit allowed to be named pokemon_bw_reader.lua is the placeholder.
ALLOWED_READER_PATH = "stub/pokemon_bw_reader.lua"

DENY_SUFFIXES = (
    # game content
    ".nds", ".ids", ".dsi", ".gba", ".gb", ".gbc", ".sav", ".srm", ".dsv", ".sta", ".state",
    # firmware / nand / raw images
    ".bin", ".rom", ".nand",
    # built artefacts
    ".dll", ".exe", ".lib", ".a", ".o", ".obj", ".pdb", ".dylib", ".so", ".ipa",
    # archives and logs
    ".zip", ".7z", ".rar", ".tar", ".gz", ".log",
    # credentials
    ".pem", ".key", ".p12", ".pfx", ".mobileprovision", ".cer", ".p8",
)

DENY_NAMES = ("id_rsa", "id_ed25519", ".netrc", ".env", "credentials", "secrets.json")

# Literal strings that would identify the machine this was built on or the private package.
DENY_LITERALS = (
    _needle("C:", "\\Use", "rs\\"),
    _needle("C:", "/Use", "rs/"),
    _needle("Pokemon DS", "\\Lua"),
    _needle("Pokemon DS", "/Lua"),
    PRIVATE_READER_SHA256,
    PRIVATE_ORIGINAL_SHA256,
)

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

# Patch files may only touch these paths. This is the structural guarantee: even if a content scan
# missed something, a patch that reaches into the reader directory is rejected outright.
PATCH_RULES = {
    "patches/core.patch": {
        "allow": ("CMakeLists.txt", "melondsds_libretro.info.in", "cmake/",
                  "src/libretro/", "test/accessibility/"),
        "deny": ("src/libretro/accessibility/lua/", "docs/"),
    },
    "patches/frontend.patch": {
        "allow": ("accessibility.h", "frontend/frontend_driver.h", "frontend/drivers/",
                  "libretro-common/include/libretro.h", "retroarch.c", "runloop.c", "pkg/apple/"),
        "deny": ("Makefile.win", "Makefile.common", "frontend/drivers/platform_win32.c"),
    },
}

DIFF_HEADER_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)$", re.MULTILINE)

SKIP_DIRS = {".git", "__pycache__", "node_modules"}
SKIP_FILES = {"MANIFEST.sha256", ".DS_Store"}

# `work/` at the kit root is build scratch: the cloned upstream trees, the CMake build tree, Xcode
# derived data and the .ipa. It is hundreds of megabytes of fetched source and caches, it is
# gitignored, and it is neither scanned nor listed in MANIFEST.sha256 -- it is not part of the
# package. Its presence is reported, so it can never be mistaken for something that was checked.
BUILD_SCRATCH_DIR = "work"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk_kit(kit):
    for root, dirs, files in os.walk(kit):
        if os.path.abspath(root) == os.path.abspath(kit):
            dirs[:] = [d for d in dirs if d != BUILD_SCRATCH_DIR]
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name in SKIP_FILES:
                continue
            full = os.path.join(root, name)
            yield os.path.relpath(full, kit).replace(os.sep, "/"), full


def load_extra_literals(path):
    """Extra deny needles kept OUT of the public kit (names of people, machine-specific strings).

    JSON: {"literals": ["..."]}. Missing file is fine; the built-in rules still apply.
    """
    if not path:
        return []
    if not os.path.isfile(path):
        raise SystemExit("error: --extra-denylist %s does not exist" % path)
    with open(path, encoding="utf-8") as fh:
        return list(json.load(fh).get("literals", []))


def check(kit, max_file_bytes, max_total_bytes, allowed_emails, extra_literals):
    problems, notes, seen, total = [], [], [], 0
    literals = tuple(DENY_LITERALS) + tuple(extra_literals)

    if os.path.isdir(os.path.join(kit, BUILD_SCRATCH_DIR)):
        notes.append("%s/ is present and was NOT scanned: it is build scratch (fetched upstream "
                     "source, caches, derived data, the .ipa). It is gitignored and excluded from "
                     "MANIFEST.sha256, so it is not part of the package -- but do not copy it into "
                     "a repository by hand." % BUILD_SCRATCH_DIR)

    for rel, full in walk_kit(kit):
        size = os.path.getsize(full)
        total += size
        seen.append((rel, full, size))
        lower = rel.lower()
        base = os.path.basename(lower)

        for suffix in DENY_SUFFIXES:
            if lower.endswith(suffix):
                problems.append("%s: forbidden file type %s" % (rel, suffix))
                break
        for name in DENY_NAMES:
            if name in base:
                problems.append("%s: forbidden file name" % rel)
                break
        if base == "pokemon_bw_reader.lua" and rel != ALLOWED_READER_PATH:
            problems.append("%s: a reader script may only exist at %s" % (rel, ALLOWED_READER_PATH))
        if size > max_file_bytes:
            problems.append("%s: %d bytes exceeds the %d byte per-file limit; the private reader "
                            "is ~2 MB, so oversized files are refused on principle"
                            % (rel, size, max_file_bytes))

        digest = sha256_file(full)
        if digest == PRIVATE_READER_SHA256:
            problems.append("%s: THIS IS THE PRIVATE READER (sha256 matches)" % rel)
        if digest == PRIVATE_ORIGINAL_SHA256:
            problems.append("%s: THIS IS THE PRIVATE ORIGINAL SCRIPT (sha256 matches)" % rel)

        with open(full, "rb") as fh:
            text = fh.read().decode("utf-8", "replace")

        for literal in literals:
            if literal in text:
                line = next((l.strip() for l in text.splitlines() if literal in l), "")
                problems.append("%s: contains a forbidden literal  ->  %s" % (rel, line[:160]))
        for match in sorted(set(EMAIL_RE.findall(text))):
            if match.lower() in allowed_emails:
                notes.append("%s: allowed e-mail %s" % (rel, match))
            else:
                problems.append("%s: contains an e-mail address %r (pass --allow-email to permit "
                                "a deliberate one)" % (rel, match))

    if total > max_total_bytes:
        problems.append("the kit is %d bytes, over the %d byte total limit" % (total, max_total_bytes))

    for patch_rel, rules in PATCH_RULES.items():
        full = os.path.join(kit, patch_rel.replace("/", os.sep))
        if not os.path.isfile(full):
            notes.append("%s: NOT PRESENT (run export_public_source.py to generate it)" % patch_rel)
            continue
        with open(full, "rb") as fh:
            body = fh.read().decode("utf-8", "replace")
        touched = sorted({m.group(2) for m in DIFF_HEADER_RE.finditer(body)})
        if not touched:
            problems.append("%s: no 'diff --git' headers found; refusing to trust a patch this "
                            "scanner cannot parse" % patch_rel)
        for path in touched:
            if any(path == d or path.startswith(d) for d in rules["deny"]):
                problems.append("%s: touches denied path %s" % (patch_rel, path))
            elif not any(path == a or path.startswith(a) for a in rules["allow"]):
                problems.append("%s: touches %s, which is not on the allow list; classify it in "
                                "export_public_source.py rather than shipping it blind"
                                % (patch_rel, path))
        notes.append("%s: %d path(s) touched: %s"
                     % (patch_rel, len(touched), ", ".join(touched) if len(touched) <= 12
                        else ", ".join(touched[:12]) + ", ..."))

    return problems, notes, seen, total


def write_manifest(kit, seen):
    lines = ["%s  %s" % (sha256_file(full), rel) for rel, full, _ in seen]
    path = os.path.join(kit, "MANIFEST.sha256")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description="Fail-closed privacy check for the iOS build kit.")
    ap.add_argument("--kit", required=True, help="the build kit directory to check")
    ap.add_argument("--max-file-bytes", type=int, default=1 << 20)
    ap.add_argument("--max-total-bytes", type=int, default=8 << 20)
    ap.add_argument("--allow-email", action="append", default=[],
                    help="permit a specific e-mail address; repeatable")
    ap.add_argument("--extra-denylist", help="JSON file of extra literals, kept out of the kit")
    ap.add_argument("--write-manifest", action="store_true",
                    help="write MANIFEST.sha256 when the kit is clean")
    args = ap.parse_args(argv)

    kit = os.path.abspath(args.kit)
    if not os.path.isdir(kit):
        print("error: no such directory: %s" % kit, file=sys.stderr)
        return 2

    problems, notes, seen, total = check(
        kit, args.max_file_bytes, args.max_total_bytes,
        {e.lower() for e in args.allow_email}, load_extra_literals(args.extra_denylist))

    print("kit:   %s" % kit)
    print("files: %d, %.1f KiB total" % (len(seen), total / 1024.0))
    for note in notes:
        print("  note: %s" % note)

    if problems:
        print("\nREFUSED -- %d problem(s):" % len(problems))
        for p in problems:
            print("  * %s" % p)
        print("\nNothing was published. Fix the kit and run this again.")
        return 1

    print("\nCLEAN -- no private content found by any rule.")
    if args.write_manifest:
        print("manifest: %s" % write_manifest(kit, seen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
