#!/bin/bash
# Build the melonDS DS accessibility core for an iOS device (arm64), then stage it where the
# RetroArch Xcode project expects to find it.
#
# Needs: macOS with Xcode, cmake >= 3.19, ninja, and network access at configure time (the core's
# CMake fetches melonDS, libretro-common, embed-binaries, glm, zlib, libslirp, pntr, fmt, yamc,
# span-lite, date and Lua 5.4.9 -- the Lua tarball is pinned by SHA256 in the core's own CMake).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_macos
require_cmd cmake ninja xcodebuild git

[ -d "$CORE_SRC" ] || die "no core source at $CORE_SRC -- run scripts/fetch_sources.sh first."

BUILD_DIR="${WORK_DIR}/build-core-ios"
TOOLCHAIN="${CORE_SRC}/cmake/toolchain/ios.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || die "missing iOS toolchain file: $TOOLCHAIN"

log "configuring the core for iOS"
info "PLATFORM=OS64 (arm64 device), DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}, ${CMAKE_BUILD_TYPE}"

# -DBUILD_AS_SHARED_LIBRARY=ON: the core's own CMakeLists says "iOS/tvOS want the library built
#   SHARED", and the libretro buildbot recipe (.gitlab-ci.yml) passes it for the iOS job. Without
#   it CMake produces a MODULE (-bundle), which is not what a .framework payload should contain.
# -DMELONDSDS_ACCESS_TESTS=OFF: the adapter tests default to ON and build a host executable that
#   cannot run on a cross-compiled iOS target.
# -DENABLE_JIT=OFF / -DENABLE_OPENGL=OFF: already the iOS defaults inside the core's CMakeLists;
#   passed explicitly so a future default change cannot quietly turn them on. JIT is useless in a
#   sideloaded app with no dynamic-codesigning entitlement, and melonDS has no GLES renderer, so
#   iOS is software-rendered.
cmake -S "$CORE_SRC" -B "$BUILD_DIR" -G Ninja \
    --toolchain "$TOOLCHAIN" \
    -DPLATFORM=OS64 \
    -DDEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DBUILD_AS_SHARED_LIBRARY=ON \
    -DMELONDSDS_ACCESS_TESTS=OFF \
    -DENABLE_JIT=OFF \
    -DENABLE_OPENGL=OFF \
    -DCMAKE_CXX_FLAGS="-Wno-deprecated-declarations -Wno-unknown-attributes" \
    -Wno-deprecated

log "building the core"
cmake --build "$BUILD_DIR" --config "${CMAKE_BUILD_TYPE}" --target melondsds_libretro

DYLIB="${BUILD_DIR}/src/libretro/${CORE_DYLIB_NAME}"
[ -f "$DYLIB" ] || die "the core did not build: $DYLIB is missing"

INFO_SRC="${BUILD_DIR}/${CORE_INFO_NAME}"
[ -f "$INFO_SRC" ] || die "the generated core info is missing: $INFO_SRC"

mkdir -p "$OUT_DIR"

# The generic melondsds_libretro.info.in hard-codes hw_render = "true" and
# required_hw_api = "OpenGL Core >= 3.2" for every platform. Neither is true of this build: iOS has
# no OpenGL here at all. Correct the staged copy rather than the source, which is shared with the
# desktop builds.
log "correcting the core info for iOS"
INFO_OUT="${OUT_DIR}/${CORE_INFO_NAME}"
sed -e 's/^hw_render = "true"/hw_render = "false"/' \
    -e '/^required_hw_api = /d' "$INFO_SRC" > "$INFO_OUT"
grep -q '^hw_render = "false"' "$INFO_OUT" || die "hw_render was not corrected in $INFO_OUT"
if grep -q '^required_hw_api' "$INFO_OUT"; then
    die "required_hw_api is still present in $INFO_OUT"
fi
info "hw_render=false, required_hw_api removed"
info "$(grep -E '^(corename|display_version|supported_extensions)' "$INFO_OUT" | tr '\n' ' ')"

# make-frameworks.sh (an existing RetroArch build phase) turns every
# pkg/apple/iOS/modules/*libretro*.dylib into <name>.framework inside the app's Frameworks folder,
# which is where an iOS RetroArch build (HAVE_FRAMEWORKS) looks for cores. It rewrites the dylib in
# place with vtool, so stage a COPY and keep the build output pristine.
MODULES_DIR="${FRONTEND_SRC}/pkg/apple/iOS/modules"
[ -d "$MODULES_DIR" ] || die "no $MODULES_DIR -- run scripts/fetch_sources.sh first."
log "staging the core for the app build"
cp "$DYLIB" "${MODULES_DIR}/${CORE_DYLIB_NAME}"
cp "$DYLIB" "${OUT_DIR}/${CORE_DYLIB_NAME}"
info "${MODULES_DIR}/${CORE_DYLIB_NAME}"
info "it will become Frameworks/melondsds.libretro.framework in the app"

if command -v shasum >/dev/null 2>&1; then
    info "sha256 $(shasum -a 256 "$DYLIB" | cut -d' ' -f1)"
fi
