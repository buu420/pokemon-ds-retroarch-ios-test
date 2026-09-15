#!/bin/bash
# Build the accessible VBA-M core for an iOS device (arm64), then stage it where the RetroArch
# Xcode project expects to find it, next to the DS core.
#
# Needs: macOS with Xcode (the iPhoneOS SDK and the system clang), and make.
#
# Unlike the DS core this is a plain libretro Makefile build. Nothing is downloaded: the adapter's
# Lua 5.4.9 is vendored in the source tree and compiled straight into the core, so there is no
# separate liblua, no package manager and no network access at build time.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_macos
require_cmd make xcodebuild python3 shasum

[ -d "$VBAM_SRC" ] || die "no VBA-M source at $VBAM_SRC -- run scripts/fetch_sources.sh first."

MAKE_DIR="${VBAM_SRC}/src/libretro"
MAKEFILE="${MAKE_DIR}/Makefile"
[ -f "$MAKEFILE" ] || die "missing $MAKEFILE"

# --- the two overrides, and why they are safe ----------------------------------------------------
# MINVERSION: the Makefile's ios-arm64 branch hardcodes -miphoneos-version-min=8.0. A command-line
# assignment wins over a makefile assignment (this Makefile does not use `override`), so one value
# sets the floor for CFLAGS, CXXFLAGS and LDFLAGS at once. The app is built for the same
# ${IOS_DEPLOYMENT_TARGET}, and make-frameworks.sh later re-stamps the Mach-O to match it.
#
# PLATFORM_DEFINES: the injection point for the iOS l_system override below. It is appended to both
# CFLAGS and CXXFLAGS after Makefile.common is included, and the ios branch of this Makefile does
# not assign it -- which is CHECKED rather than assumed, because a command-line assignment would
# silently replace anything that branch did set.

# Every check below writes its input to a file and greps the FILE. Never `producer | grep -q`:
# grep -q exits at the first match, the producer then dies of SIGPIPE, and `set -o pipefail` (from
# common.sh) turns that into exit 141 -- a correct check reported as a failure, on a build that was
# fine. This kit has hit that before, with `unzip -l | grep -q` against the real assets.zip. It is
# timing- and size-dependent, so it passes on a small core and fails on a big one; writing the
# bytes out first removes the race entirely and leaves the evidence on disk to look at.
CHECK_DIR="${WORK_DIR}/vbam-checks"
mkdir -p "$CHECK_DIR"

log "checking the VBA-M Makefile's iOS section"
IOS_BLOCK="${CHECK_DIR}/ios-branch.mk"
awk '/findstring ios,/{f=1; next} f && /^else if/{exit} f' "$MAKEFILE" > "$IOS_BLOCK"
[ -s "$IOS_BLOCK" ] || die "could not find the ios branch in $MAKEFILE. This kit's overrides were
       written against it; refusing to guess."
if grep -q 'PLATFORM_DEFINES' "$IOS_BLOCK"; then
    die "the ios branch of $MAKEFILE now sets PLATFORM_DEFINES. This kit passes PLATFORM_DEFINES on
       the command line to inject the iOS l_system override, which would silently replace it.
       Move the injection to another variable, or fold the override into the core's own build."
fi
grep -q 'miphoneos-version-min' "$IOS_BLOCK" \
    || die "the ios branch of $MAKEFILE no longer sets a minimum iOS version, so the MINVERSION
       override this script relies on may no longer reach the compiler."
info "ios branch found; PLATFORM_DEFINES free; MINVERSION honoured"

# Lua's os.execute calls system(), which the iOS SDK declares unavailable, so a stock build of the
# vendored Lua does not compile for iOS at all. loslib.c already has a guarded hook for exactly
# this -- `#if !defined(l_system)` -- so define it to the same failure stub Lua itself uses on iOS
# (os.execute then reports that there is no shell). The alternative, -DLUA_USE_IOS, also switches
# on LUA_USE_POSIX and LUA_USE_DLOPEN, which is more surface than this needs; the DS core makes the
# same choice for the same reason.
#
# The single quotes are PART OF THE VALUE. make expands this straight into the compile recipe, and
# that recipe is run by /bin/sh -- an unquoted '(' there is a shell syntax error before the
# compiler ever sees the flag. make itself does not strip them; the recipe's shell does.
#
# If a future toolchain disagrees about that, the probe below fails immediately and says so, and
# -DLUA_USE_IOS is the one-line fallback: it selects the same l_system stub from Lua's own iOS
# configuration, at the cost of also switching on LUA_USE_POSIX and LUA_USE_DLOPEN.
LUA_IOS_DEFINE="'-Dl_system(cmd)=((cmd)==NULL?0:-1)'"

# Prove the flag survives, BEFORE spending a full core build on finding out. This runs the value
# through a shell exactly the way make will: expanded into a command string, unquoted, and handed
# to sh. If the quoting is wrong this is a one-second failure with the reason attached, instead of
# a screenful of "syntax error near unexpected token `('" several minutes in.
log "checking the iOS Lua override"
PROBE_DIR="${WORK_DIR}/probe-lua-ios"
mkdir -p "$PROBE_DIR"
# <stddef.h> for NULL: the macro's replacement text uses it, and without a declaration this probe
# fails to compile for a reason that has nothing to do with what it is testing ("'NULL' undeclared")
# -- which would stop every run of this script before the real build. In Lua's own loslib.c the
# macro expands where NULL is already declared, so including it here is what makes the probe
# faithful rather than a special case.
cat > "${PROBE_DIR}/probe.c" <<'PROBE'
/* Compiled only to prove -Dl_system(cmd)=... arrived intact. */
#include <stddef.h>
#if !defined(l_system)
#error "l_system was not defined on the command line"
#endif
int probe(void) { return l_system((void *)0); }
PROBE
sh -c "cc -fsyntax-only ${LUA_IOS_DEFINE} '${PROBE_DIR}/probe.c'" \
    || die "the iOS Lua override did not survive the shell as a single argument, or the compiler
       rejected it.
       Value: ${LUA_IOS_DEFINE}
       Either quote it differently, or switch this line to -DLUA_USE_IOS (Lua's own iOS
       configuration), which selects the same os.execute stub without any shell metacharacters."
info "l_system override reaches the compiler intact"

IOSSDK="${IOSSDK:-$(xcodebuild -version -sdk iphoneos Path 2>/dev/null || true)}"
[ -n "$IOSSDK" ] && [ -d "$IOSSDK" ] || die "could not locate the iPhoneOS SDK.
       xcodebuild -version -sdk iphoneos Path returned: ${IOSSDK:-<nothing>}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

log "building the VBA-M core for iOS"
info "platform=ios-arm64, min iOS ${IOS_DEPLOYMENT_TARGET}"
info "SDK ${IOSSDK}"
info "ACCESS=1 (the adapter), Lua vendored and compiled in, no dynarec on this path"

set -x
make -C "$MAKE_DIR" \
    platform=ios-arm64 \
    IOSSDK="$IOSSDK" \
    MINVERSION="-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}" \
    PLATFORM_DEFINES="$LUA_IOS_DEFINE" \
    ACCESS=1 \
    -j"$JOBS"
set +x

BUILT="${MAKE_DIR}/${VBAM_BUILT_DYLIB_NAME}"
[ -f "$BUILT" ] || die "the VBA-M core did not build: $BUILT is missing"

# --- prove the thing that was built is the thing that was wanted ---------------------------------
log "checking the built core"

FILE_OUT="${CHECK_DIR}/file.txt"
file "$BUILT" > "$FILE_OUT"
grep -q 'arm64' "$FILE_OUT" || die "$BUILT is not arm64: $(cat "$FILE_OUT")"
info "$(cut -d: -f2- "$FILE_OUT" | sed 's/^ //')"

# A core the frontend can load has to export the libretro entry points. nm is run ONCE into a file:
# a core this size has thousands of symbols, and three `nm | grep -q` pipelines would be three
# chances for the producer to be killed mid-write by an early match.
SYMBOLS="${CHECK_DIR}/symbols.txt"
nm -gU "$BUILT" > "$SYMBOLS" 2>/dev/null || die "nm could not read $BUILT"
for sym in retro_api_version retro_load_game retro_run; do
    grep -q "_${sym}$" "$SYMBOLS" \
        || die "$BUILT does not export ${sym}, so it is not a loadable libretro core.
       Symbols are in ${SYMBOLS}."
done
info "libretro entry points exported ($(wc -l < "$SYMBOLS" | tr -d ' ') exported symbols)"

# ACCESS=0 builds a stock VBA-M that compiles, links and runs perfectly -- and has no reader. The
# core option key only exists when the adapter is compiled in, so look for that rather than trust
# the make variable that was passed in. Megabytes of output, matched near the start: exactly the
# shape that makes `strings | grep -q` a coin toss under pipefail.
CORE_STRINGS="${CHECK_DIR}/strings.txt"
strings -a "$BUILT" > "$CORE_STRINGS" || die "strings could not read $BUILT"
grep -q 'vbam_access_reader' "$CORE_STRINGS" \
    || die "the built core has no 'vbam_access_reader' core option, so the accessibility adapter
       was not compiled in. This would be stock VBA-M with no reader."
info "accessibility adapter is compiled in (vbam_access_reader present)"

# The minimum OS recorded in the Mach-O. This is what the MINVERSION override is for, and getting
# it wrong stays invisible until a phone refuses to load the core.
if command -v vtool >/dev/null 2>&1; then
    BUILD_VERSION="${CHECK_DIR}/vtool-show-build.txt"
    vtool -show-build "$BUILT" > "$BUILD_VERSION" 2>/dev/null || true
    # awk reads the file directly, so its `exit` cannot leave a producer writing into a closed pipe.
    MINOS="$(awk '/minos/{print $2; exit}' "$BUILD_VERSION")"
    grep -qi 'platform .*IOS' "$BUILD_VERSION" \
        || die "the built core is not marked as an iOS binary:
$(cat "$BUILD_VERSION")"
    case "$MINOS" in
        "${IOS_DEPLOYMENT_TARGET}"|"${IOS_DEPLOYMENT_TARGET}".*)
            info "minos ${MINOS}, platform IOS" ;;
        *)
            die "the built core records minos ${MINOS:-<none>}, but this build asked for
       ${IOS_DEPLOYMENT_TARGET}. The MINVERSION override did not reach the compiler." ;;
    esac
else
    info "vtool not available; the recorded minimum OS version was not checked"
fi

mkdir -p "$OUT_DIR"

# --- core info -----------------------------------------------------------------------------------
# VBA-M ships its own vbam_libretro.info in its libretro port directory, and this kit's patch does
# not touch it: the adapter adds one core option, it does not change the core's identity, its
# extensions or its firmware list. Pinning the sha256 means a patch that quietly edited the
# metadata fails here instead of shipping.
log "staging the core info"
INFO_SRC="${VBAM_SRC}/${VBAM_INFO_REL}"
[ -f "$INFO_SRC" ] || die "the core info is missing: $INFO_SRC"

EXPECTED_INFO_SHA="$(python3 -c 'import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["vbam"]["core_info"]["sha256"])' "${KIT_DIR}/patches/pins.json")"
ACTUAL_INFO_SHA="$(shasum -a 256 "$INFO_SRC" | cut -d' ' -f1)"
[ "$ACTUAL_INFO_SHA" = "$EXPECTED_INFO_SHA" ] || die "${VBAM_INFO_REL} hashes to
       ${ACTUAL_INFO_SHA}, but patches/pins.json pins ${EXPECTED_INFO_SHA}. Either the pinned base
       moved or the patch edited the core's metadata. Both need a deliberate decision."

INFO_OUT="${OUT_DIR}/${VBAM_INFO_NAME}"
cp "$INFO_SRC" "$INFO_OUT"
grep -q "^corename = \"${VBAM_CORENAME}\"" "$INFO_OUT" \
    || die "$INFO_OUT does not declare corename = \"${VBAM_CORENAME}\""
grep -q '^supported_extensions = ' "$INFO_OUT" \
    || die "$INFO_OUT has no supported_extensions, so RetroArch would offer it no content"
# Stock VBA-M is software-rendered, so unlike the DS core's generated info there is nothing to
# correct here -- but say so out loud rather than leaving it unchecked.
if grep -q '^hw_render = "true"' "$INFO_OUT"; then
    die "$INFO_OUT claims hw_render = \"true\", which this build cannot provide."
fi
info "$(grep -E '^(corename|display_version|supported_extensions)' "$INFO_OUT" | tr '\n' ' ')"

# --- stage for the app build ---------------------------------------------------------------------
# Staged WITHOUT the _ios suffix the Makefile gives it. make-frameworks.sh strips that suffix
# itself, so either name would land on vbam.libretro.framework, but the plain name is the one the
# DS core uses and the one the packaging checks and pins.json refer to.
MODULES_DIR="${FRONTEND_SRC}/pkg/apple/iOS/modules"
[ -d "$MODULES_DIR" ] || die "no $MODULES_DIR -- run scripts/fetch_sources.sh first."
log "staging the core for the app build"
cp "$BUILT" "${MODULES_DIR}/${VBAM_DYLIB_NAME}"
cp "$BUILT" "${OUT_DIR}/${VBAM_DYLIB_NAME}"
info "${MODULES_DIR}/${VBAM_DYLIB_NAME}"
info "it will become Frameworks/${VBAM_FRAMEWORK_NAME}.framework in the app"
info "sha256 $(shasum -a 256 "$BUILT" | cut -d' ' -f1)"
