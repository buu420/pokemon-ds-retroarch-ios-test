#!/usr/bin/env python3
"""Prove the privacy rules REFUSE, not just that they pass on a clean kit.

A fail-closed scanner that has only ever been run on clean input is an untested scanner: every rule
in tools/verify_public_kit.py is there to stop something specific, and the only way to know it
still does is to hand it that thing and watch it refuse.

Every fixture here is synthetic and built in a temporary directory -- no reader, no ROM, no local
path, nothing copied out of a real tree. Run it offline, on any machine:

    python tools/test_export_rules.py

Exit 0 all rules behaved, 1 a rule did not fire (or fired when it should not have).
"""
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_public_kit as vpk  # noqa: E402

PASS, FAIL = "PASS", "FAIL"

# A patch body the scanner can parse: it only reads the 'diff --git' headers to decide which paths
# a patch touches, so the hunks are deliberately minimal.
def patch_for(*paths):
    out = []
    for path in paths:
        out.append("diff --git a/%s b/%s" % (path, path))
        out.append("--- a/%s" % path)
        out.append("+++ b/%s" % path)
        out.append("@@ -0,0 +1 @@")
        out.append("+placeholder")
    return "\n".join(out) + "\n"


def write(kit, rel, text):
    full = os.path.join(kit, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return full


def make_kit(tmp, **overrides):
    """A minimal kit that passes every rule, unless a caller overrides a file to break one."""
    kit = os.path.join(tmp, "kit")
    os.makedirs(kit, exist_ok=True)
    files = {
        "README.md": "# a build kit\n",
        vpk.ALLOWED_READER_PATH: "error('the real reader is not included in this build')\n",
        "patches/core.patch": patch_for("src/libretro/accessibility/accessibility.cpp"),
        "patches/vbam.patch": patch_for("src/libretro/access/access_core.cpp",
                                        "src/libretro/access/lua/lapi.c",
                                        "src/gba/GBAinline.h",
                                        "tests/access_tests.cpp"),
        "patches/frontend.patch": patch_for("frontend/drivers/platform_darwin.m"),
    }
    files.update(overrides)
    for rel, text in files.items():
        if text is None:
            continue
        write(kit, rel, text)
    return kit


def run(kit, max_file_bytes=1 << 20, max_patch_bytes=4 << 20, max_total_bytes=8 << 20):
    problems, _notes, _seen, _total = vpk.check(
        kit, max_file_bytes, max_patch_bytes, max_total_bytes, set(), [])
    return problems


def case(name, kit, expect_refusal, needle=None):
    """expect_refusal: True if at least one problem must mention `needle`."""
    problems = run(kit)
    matched = [p for p in problems if needle is None or needle in p]
    if expect_refusal:
        ok = bool(matched)
        detail = matched[0] if matched else "no problem mentioned %r; got: %s" % (
            needle, problems or "nothing")
    else:
        ok = not problems
        detail = "clean" if ok else "unexpected: %s" % problems
    print("   %-4s %-52s %s" % (PASS if ok else FAIL, name, detail[:110]))
    return ok


def classification_cases():
    """The exporter's own rules, checked path by path. No git repository needed."""
    import export_public_source as eps

    expectations = [
        # (tree rules, path, expected verdict, what it is)
        (eps.VBAM_RULES, "src/libretro/access/access_core.cpp", "export", "adapter source"),
        (eps.VBAM_RULES, "src/libretro/access/lua/lapi.c", "export", "vendored Lua, a C file"),
        (eps.VBAM_RULES, "src/gba/GBAinline.h", "export", "emulator hook"),
        (eps.VBAM_RULES, "tests/access_tests.cpp", "export", "our own test source"),
        (eps.VBAM_RULES, "reader/game/red/en/memory.lua", "exclude", "reader, under reader/"),
        # The case that actually happened: reader scripts dropped at the tree root while testing.
        (eps.VBAM_RULES, "pokemon.lua", "exclude", "reader, at the tree root"),
        (eps.VBAM_RULES, "sub_data.lua", "exclude", "reader, at the tree root"),
        (eps.VBAM_RULES, "src/libretro/access/lua/extra.lua", "exclude",
         "a .lua inside an exported directory is still excluded"),
        (eps.VBAM_RULES, "ACCESS-PLAN.md", "exclude", "internal notes"),
        (eps.VBAM_RULES, "docs/whatever.md", "unclassified", "nothing covers it"),
        # The DS tree keeps its stricter behaviour: no suffix rule, so a stray .lua outside the
        # reader directory is a hard error rather than a quiet exclusion.
        (eps.CORE_RULES, "src/libretro/accessibility/lua/reader.lua", "exclude", "DS reader dir"),
        (eps.CORE_RULES, "stray.lua", "unclassified", "DS tree has no suffix rule, by design"),
    ]

    results = []
    for rules, path, expected, what in expectations:
        verdict, _reason = eps.classify_path(path, rules)
        ok = verdict == expected
        print("   %-4s %-52s %s" % (PASS if ok else FAIL, "%s -> %s" % (path, expected),
                                    what if ok else "got %r" % verdict))
        results.append(ok)
    return results


def main():
    tmp = tempfile.mkdtemp(prefix="kit-rule-test-")
    results = []
    try:
        print("== rules that must PASS a clean kit")
        results.append(case("a clean kit is accepted", make_kit(tmp), False))

        print("\n== rules that must REFUSE")
        # The structural guarantee for the VBA-M reader: it lives in reader/ and no patch may reach
        # into it, whatever the content scan does or does not recognise.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a vbam patch that touches reader/",
            make_kit(tmp, **{"patches/vbam.patch": patch_for("reader/game/red/en/memory.lua")}),
            True, "denied path"))

        # Internal notes carry local paths and quote the reader; they are excluded by name.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a vbam patch that touches ACCESS-PLAN.md",
            make_kit(tmp, **{"patches/vbam.patch": patch_for("ACCESS-PLAN.md")}),
            True, "denied path"))

        # Neither reader may travel in a patch under any path or any name.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a patch that adds a .lua file anywhere",
            make_kit(tmp, **{"patches/vbam.patch": patch_for("src/libretro/access/lua/reader.lua")}),
            True, "adds a Lua file"))

        # A path nobody classified must not ride along on an allow-list technicality.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a vbam patch that touches an unclassified path",
            make_kit(tmp, **{"patches/vbam.patch": patch_for("docs/internal-notes.md")}),
            True, "not on the allow list"))

        # The same rule, on the DS core's own reader directory.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a core patch that touches the DS reader directory",
            make_kit(tmp, **{"patches/core.patch":
                             patch_for("src/libretro/accessibility/lua/adapt_reader.py")}),
            True, "denied path"))

        # A reader renamed and dropped into the kit itself.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a stray .lua file in the kit",
            make_kit(tmp, **{"stub/other_reader.lua": "-- not the placeholder\n"}),
            True, "only Lua file"))

        # Size: the reader is ~2 MB, so a big ordinary file is refused even if it looks innocent,
        # while a patch -- which legitimately carries vendored source -- gets its own larger limit.
        shutil.rmtree(os.path.join(tmp, "kit"))
        kit = make_kit(tmp, **{"config/big.txt": "x" * (2 << 20)})
        results.append(case("an oversized ordinary file", kit, True, "exceeds the"))

        shutil.rmtree(os.path.join(tmp, "kit"))
        kit = make_kit(tmp)
        # 1.5 MiB of patch: over the 1 MiB file limit, under the 4 MiB patch limit. This is the
        # real VBA-M case -- vendored Lua makes that patch about this size.
        with open(os.path.join(kit, "patches", "vbam.patch"), "a", encoding="utf-8") as fh:
            fh.write("# padding\n" * 150000)
        results.append(case("a large patch, under the patch limit", kit, False))

        # An unparseable patch is refused rather than trusted.
        shutil.rmtree(os.path.join(tmp, "kit"))
        results.append(case(
            "a patch with no diff headers",
            make_kit(tmp, **{"patches/vbam.patch": "this is not a patch\n"}),
            True, "no 'diff --git' headers"))

        # A machine-identifying absolute path in any file.
        shutil.rmtree(os.path.join(tmp, "kit"))
        leak = "see " + vpk._needle("C:", "/Use", "rs/") + "someone/notes.txt\n"
        results.append(case("a file containing a user path", make_kit(tmp, **{"README.md": leak}),
                            True, "forbidden literal"))

        # An e-mail address, which identifies a person rather than a machine. Assembled from
        # fragments for the same reason the scanner assembles its own needles: this file is itself
        # scanned, and an address written out in full here would make the kit refuse to publish.
        shutil.rmtree(os.path.join(tmp, "kit"))
        address = vpk._needle("someone", "@", "example", ".com")
        results.append(case(
            "a file containing an e-mail address",
            make_kit(tmp, **{"README.md": "contact: %s\n" % address}),
            True, "e-mail address"))
        print("\n== classification, the rule that decides what goes in a patch at all")
        results.extend(classification_cases())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = results.count(False)
    print("\n%d/%d rules behaved as intended" % (len(results) - failed, len(results)))
    if failed:
        print("A rule did not fire. Something that should be impossible to publish is not.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
