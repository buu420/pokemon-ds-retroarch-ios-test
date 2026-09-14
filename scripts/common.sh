#!/bin/bash
# Shared settings for the iOS build kit. Sourced by the other scripts; not run on its own.
#
# Every value here is overridable from the environment, so CI and a local Mac use the same code.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${KIT_DIR}/work}"
SRC_DIR="${SRC_DIR:-${WORK_DIR}/src}"
OUT_DIR="${OUT_DIR:-${WORK_DIR}/out}"

CORE_SRC="${CORE_SRC:-${SRC_DIR}/melonds-ds}"
FRONTEND_SRC="${FRONTEND_SRC:-${SRC_DIR}/RetroArch}"

# Pinned upstream bases. patches/pins.json carries the same values for machine use.
CORE_UPSTREAM="${CORE_UPSTREAM:-https://github.com/JesseTG/melonds-ds.git}"
CORE_BASE="${CORE_BASE:-bc4e4b67d2d470d7c682810a1e892cafd6f9082b}"
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

CORE_DYLIB_NAME="melondsds_libretro.dylib"
CORE_INFO_NAME="melondsds_libretro.info"

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
