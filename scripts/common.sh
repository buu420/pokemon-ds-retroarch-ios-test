#!/bin/bash
# Shared settings for the iOS build kit. Sourced by the other scripts; not run on its own.
#
# Every value here is overridable from the environment, so CI and a local Mac use the same code.
#
# shellcheck disable=SC2034
# SC2034 ("appears unused") is disabled for this file, deliberately and only here. Everything below
# is a setting consumed by a DIFFERENT script -- XCODE_PROJECT_REL by build_app_ios.sh,
# VBAM_INFO_REL by fetch_sources.sh and build_vbam_ios.sh, and so on -- so read on its own this file
# has no users for any of them and shellcheck is right to say so and wrong to worry.
#
# That does mean a genuinely dead setting would not be flagged here. To check one for real, lint the
# CONSUMER with -x, which follows the source and sees the actual uses. From the scripts directory,
# so that the relative path in the source line resolves:
#
#     cd scripts && shellcheck -x build_vbam_ios.sh
#
# (Careful with the wording of comments in this file: a comment whose first word is the linter's own
# name is parsed as a directive, not as prose, and becomes a parse error.)
#
# Nothing in this file is exported: the scripts source it rather than inheriting it, so an
# environment override stays an override and a stray variable from a parent shell cannot stand in
# for a setting that was supposed to be defined here.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${KIT_DIR}/work}"
SRC_DIR="${SRC_DIR:-${WORK_DIR}/src}"
OUT_DIR="${OUT_DIR:-${WORK_DIR}/out}"

CORE_SRC="${CORE_SRC:-${SRC_DIR}/melonds-ds}"
VBAM_SRC="${VBAM_SRC:-${SRC_DIR}/vbam-libretro}"
FRONTEND_SRC="${FRONTEND_SRC:-${SRC_DIR}/RetroArch}"

# Pinned upstream bases. patches/pins.json carries the same values for machine use.
CORE_UPSTREAM="${CORE_UPSTREAM:-https://github.com/JesseTG/melonds-ds.git}"
CORE_BASE="${CORE_BASE:-bc4e4b67d2d470d7c682810a1e892cafd6f9082b}"
VBAM_UPSTREAM="${VBAM_UPSTREAM:-https://github.com/libretro/vbam-libretro.git}"
VBAM_BASE="${VBAM_BASE:-115defb3a318258ab84746d45258a1aec19d0b4b}"
FRONTEND_UPSTREAM="${FRONTEND_UPSTREAM:-https://github.com/libretro/RetroArch.git}"
FRONTEND_BASE="${FRONTEND_BASE:-69a4f0ea1e8aaf442ae4858f2e7f2b31a1776576}"

# Core build. ENABLE_JIT and ENABLE_OPENGL are ALREADY off by default under the iOS toolchain
# (melonds-ds CMakeLists.txt gates both on IOS); they are passed explicitly so the intent is on the
# record and a future default change cannot silently turn them on.
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-14}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"

# App identity. A DISTINCT bundle id is what keeps this test build separate from an App Store
# RetroArch: iOS containers are keyed by bundle id, so the user's existing install, its saves and
# its settings are untouched and both apps can be installed at once.
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.example.RetroArchAccess}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-RetroArch Access}"
IPA_NAME="${IPA_NAME:-RetroArchAccess}"

# The widget extension is a hard target dependency of the app, so it is always built; it is then
# removed from the Payload. A free Apple account gets 10 app IDs per 7 days and the widget would
# consume a second one for a feature this test build does not need.
KEEP_APP_EXTENSIONS="${KEEP_APP_EXTENSIONS:-0}"

XCODE_PROJECT_REL="pkg/apple/RetroArch_iOS13.xcodeproj"
XCODE_SCHEME="${XCODE_SCHEME:-RetroArch iOS Release}"
XCODE_CONFIG="${XCODE_CONFIG:-Release}"

# --- the two cores -------------------------------------------------------------------------------
# Both are staged into pkg/apple/iOS/modules/ under their canonical libretro names. The app build
# phase pkg/apple/make-frameworks.sh turns every *libretro*.dylib there into <name>.framework with
# '_' replaced by '.', so these names decide the framework names, and the framework name is what
# RetroArch dlopens. It also strips a trailing '_ios' first, so vbam_libretro_ios.dylib (what the
# VBA-M Makefile actually emits) and vbam_libretro.dylib both end up as vbam.libretro.framework;
# the plain name is staged so the two cores are named the same way.
CORE_DYLIB_NAME="melondsds_libretro.dylib"
CORE_INFO_NAME="melondsds_libretro.info"
CORE_FRAMEWORK_NAME="melondsds.libretro"

# VBA-M keeps its ordinary libretro identity: target name 'vbam', corename 'VBA-M'. The accessibility
# adapter is a compile-time addition to that core, not a fork with a new name, so nothing here is
# renamed and the stock vbam_libretro.info from the pinned source is the metadata that ships.
VBAM_DYLIB_NAME="vbam_libretro.dylib"
VBAM_BUILT_DYLIB_NAME="vbam_libretro_ios.dylib"
VBAM_INFO_NAME="vbam_libretro.info"
VBAM_INFO_REL="src/libretro/vbam_libretro.info"
VBAM_FRAMEWORK_NAME="vbam.libretro"
VBAM_CORENAME="VBA-M"

# Every packaging check loops over this, so a core can never be half-added: name the dylib and the
# info together or the loop does not see it.
CORE_DYLIBS=("$CORE_DYLIB_NAME" "$VBAM_DYLIB_NAME")
CORE_INFOS=("$CORE_INFO_NAME" "$VBAM_INFO_NAME")
CORE_FRAMEWORKS=("$CORE_FRAMEWORK_NAME" "$VBAM_FRAMEWORK_NAME")

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Recursive delete with a containment check. $1 must resolve to a path strictly inside $2, which
# must itself exist. Symlinks are resolved first (pwd -P), so a link pointing out of the work
# directory cannot be followed into somewhere that matters. Used for the few scratch directories
# these scripts own; nothing else is ever deleted.
safe_rm_rf() {
    local target="$1" parent="$2" resolved_target resolved_parent target_dir

    [ -n "$target" ] || die "safe_rm_rf: empty target"
    [ -n "$parent" ] || die "safe_rm_rf: empty parent"
    [ -d "$parent" ] || die "safe_rm_rf: parent does not exist: $parent"

    target_dir="$(dirname "$target")"
    [ -d "$target_dir" ] || return 0   # nothing to delete
    resolved_target="$(cd "$target_dir" && pwd -P)/$(basename "$target")"
    resolved_parent="$(cd "$parent" && pwd -P)"

    case "$resolved_parent" in
        ""|"/") die "safe_rm_rf: refusing to use $resolved_parent as a parent" ;;
    esac
    case "$resolved_target" in
        "$resolved_parent"/?*) ;;
        *) die "safe_rm_rf: refusing to delete ${target}: it resolves to ${resolved_target},
       which is not inside ${resolved_parent}." ;;
    esac

    rm -rf "$resolved_target"
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS; it needs Xcode."
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}
