#!/usr/bin/env python3
"""Unhook the widget extension from the RetroArch iOS app target, before xcodebuild runs.

Why this exists
---------------
The app target declares the widget extension as a build dependency and embeds the resulting
.appex. Xcode then runs ValidateEmbeddedBinary, which requires the embedded binary to carry the
same signing certificate as its parent. This build deliberately has no Apple account: Xcode's own
signing is off and the app gets an ad-hoc signature afterwards, so the widget ends up unsigned and
validation fails the whole build:

    ValidateEmbeddedBinary .../RetroArch.app/PlugIns/RetroArchWidgetExtensionExtension.appex
    error: Embedded binary is not signed with the same certificate as the parent app.
            Embedded Binary Signing Certificate:  Not Code Signed
            Parent App Signing Certificate:       - (Ad Hoc Code Signed)

Removing the .appex from the Payload afterwards is too late -- validation runs during the build.
The widget is not wanted in this test build anyway (it would consume a second App ID from a free
account's ten-per-seven-days allowance), so the dependency and the embed are removed from the
*ephemeral fetched copy* of the project before building.

What it changes
---------------
Exactly two lines, both inside the app's PBXNativeTarget block:

  * the PBXTargetDependency entry in `dependencies`
  * the "Embed Foundation Extensions" entry in `buildPhases`

The widget target, its files and the orphaned objects are all left in place; they are simply no
longer referenced by the app, so the scheme does not build them. No signing setting is weakened
and no source file is touched.

Everything is asserted before and after. If the pinned project ever stops matching what this
expects, it fails and writes nothing rather than editing the wrong thing.

    python3 strip_widget_extension.py <path to project.pbxproj>

Exit 0 changed (or already stripped), 1 refused.
"""
import os
import re
import shutil
import sys

APP_TARGET_NAME = "RetroArchiOS"
WIDGET_HINT = "WidgetExtension"
EMBED_PHASE_NAME = "Embed Foundation Extensions"

OBJ_ID = r"[0-9A-F]{24}"


def fail(msg):
    print("REFUSED: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def find_block(text, header_re, what):
    """Return (start, end, body) for a `<id> /* name */ = { ... };` object block."""
    m = re.search(header_re, text)
    if not m:
        fail("could not find %s in the project" % what)
    start = m.start()
    end = text.find("\n\t\t};\n", m.end())
    if end < 0:
        fail("could not find the end of %s" % what)
    end += len("\n\t\t};\n")
    return start, end, text[start:end]


def object_block_by_id(text, obj_id, what):
    return find_block(text, r"(?m)^\t\t%s /\* [^\n]*\*/ = \{$" % obj_id, what)


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 1
    path = os.path.abspath(argv[1])
    if not os.path.isfile(path):
        fail("no such file: %s" % path)

    with open(path, "r", encoding="utf-8", newline="") as fh:
        raw = fh.read()

    # A fresh clone on the runner is LF, but a checkout on Windows (core.autocrlf) is CRLF. Work in
    # LF so the anchored patterns below stay simple, and restore the file's own ending on write.
    crlf = "\r\n" in raw
    text = raw.replace("\r\n", "\n") if crlf else raw

    # --- locate the app target by NAME, not just by id, so a pin change cannot mis-edit ---------
    start, end, target = find_block(
        text, r"(?m)^\t\t(%s) /\* %s \*/ = \{$" % (OBJ_ID, re.escape(APP_TARGET_NAME)),
        "the %s target" % APP_TARGET_NAME)
    if "isa = PBXNativeTarget;" not in target:
        fail("the %s block is not a PBXNativeTarget" % APP_TARGET_NAME)
    if 'productType = "com.apple.product-type.application";' not in target:
        fail("the %s target is not an application" % APP_TARGET_NAME)
    # The block header is only a comment. Check the real `name` field too, so a renamed target
    # cannot be edited just because its stale comment still reads RetroArchiOS.
    if "\n\t\t\tname = %s;\n" % APP_TARGET_NAME not in target:
        fail("the block commented %s does not actually have `name = %s;`"
             % (APP_TARGET_NAME, APP_TARGET_NAME))
    if "/* RetroArch.app */" not in target:
        fail("the %s target does not produce RetroArch.app" % APP_TARGET_NAME)

    dep_line_re = re.compile(r"(?m)^\t\t\t\t(%s) /\* PBXTargetDependency \*/,\n" % OBJ_ID)
    embed_line_re = re.compile(r"(?m)^\t\t\t\t(%s) /\* %s \*/,\n"
                               % (OBJ_ID, re.escape(EMBED_PHASE_NAME)))

    deps = dep_line_re.findall(target)
    embeds = embed_line_re.findall(target)

    if not deps and not embeds:
        # Already stripped; make the script safe to re-run.
        if "PBXTargetDependency" in target or EMBED_PHASE_NAME in target:
            fail("the %s target still mentions a dependency or embed phase in an unexpected form"
                 % APP_TARGET_NAME)
        print("already stripped: %s has no target dependency and no embed phase"
              % APP_TARGET_NAME)
        return 0

    if len(deps) != 1:
        fail("expected exactly 1 PBXTargetDependency in %s, found %d"
             % (APP_TARGET_NAME, len(deps)))
    if len(embeds) != 1:
        fail("expected exactly 1 '%s' phase in %s, found %d"
             % (EMBED_PHASE_NAME, APP_TARGET_NAME, len(embeds)))

    dep_id, embed_id = deps[0], embeds[0]

    # --- prove both really are the widget before removing anything -----------------------------
    _s, _e, dep_obj = object_block_by_id(text, dep_id, "PBXTargetDependency %s" % dep_id)
    if "isa = PBXTargetDependency;" not in dep_obj:
        fail("%s is not a PBXTargetDependency" % dep_id)
    dep_target = re.search(r"target = %s /\* ([^*]+?) \*/;" % OBJ_ID, dep_obj)
    if not dep_target:
        fail("could not read the dependency's target name from %s" % dep_id)
    dep_target_name = dep_target.group(1).strip()
    if WIDGET_HINT not in dep_target_name:
        fail("the app's only dependency is %r, which does not look like the widget extension. "
             "Refusing to remove it." % dep_target_name)

    _s, _e, embed_obj = object_block_by_id(text, embed_id, "embed phase %s" % embed_id)
    if "isa = PBXCopyFilesBuildPhase;" not in embed_obj:
        fail("%s is not a PBXCopyFilesBuildPhase" % embed_id)
    if "dstSubfolderSpec = 13;" not in embed_obj:
        fail("%s is not a PlugIns copy phase (dstSubfolderSpec 13)" % embed_id)
    embedded = re.findall(r"/\* ([^*]*\.appex) in %s \*/" % re.escape(EMBED_PHASE_NAME), embed_obj)
    if not embedded:
        fail("the embed phase %s copies no .appex; refusing to touch it" % embed_id)
    for name in embedded:
        if WIDGET_HINT not in name:
            fail("the embed phase also copies %r, which is not the widget. Refusing." % name)

    print("app target      : %s (%s)" % (APP_TARGET_NAME, text[start:start + 24]))
    print("dependency      : %s -> %s" % (dep_id, dep_target_name))
    print("embed phase     : %s -> %s" % (embed_id, ", ".join(embedded)))

    # --- the edit: drop the two reference lines from the app target ----------------------------
    before_phases = len(re.findall(r"(?m)^\t\t\t\t%s /\*" % OBJ_ID,
                                   target.split("buildPhases = (")[1].split(");")[0]))
    new_target, n1 = dep_line_re.subn("", target)
    new_target, n2 = embed_line_re.subn("", new_target)
    if (n1, n2) != (1, 1):
        fail("expected to remove exactly one line of each kind, removed %d and %d" % (n1, n2))

    # --- post-conditions on the rewritten target ------------------------------------------------
    if "dependencies = (\n\t\t\t);" not in new_target:
        fail("the app target's dependencies list is not empty after the edit")
    remaining = new_target.split("buildPhases = (")[1].split(");")[0]
    after_phases = len(re.findall(r"(?m)^\t\t\t\t%s /\*" % OBJ_ID, remaining))
    if after_phases != before_phases - 1:
        fail("build phase count went %d -> %d, expected %d"
             % (before_phases, after_phases, before_phases - 1))
    if after_phases < 4:
        fail("only %d build phases left; the app needs its Sources, Frameworks, Resources and "
             "script phases" % after_phases)
    for needed in ("Sources", "Frameworks", "Resources"):
        if "/* %s */" % needed not in remaining:
            fail("the %s build phase disappeared from the app target" % needed)
    if embed_id in new_target or dep_id in new_target:
        fail("a reference to the widget survives in the app target")

    out = text[:start] + new_target + text[end:]

    # The widget target itself is intentionally left defined -- just unreferenced.
    if "/* %s */ = {" % "RetroArchWidgetExtensionExtension" not in out:
        fail("the widget target definition vanished; this script should only unreference it")

    shutil.copyfile(path, path + ".orig")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(out.replace("\n", "\r\n") if crlf else out)

    print("removed the widget dependency and the embed phase from %s" % APP_TARGET_NAME)
    print("build phases    : %d -> %d (widget target left defined, now unreferenced)"
          % (before_phases, after_phases))
    print("original saved  : %s.orig" % os.path.basename(path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
