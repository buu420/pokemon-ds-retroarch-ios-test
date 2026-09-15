#!/bin/bash
# Reconstruct all three source trees: pinned upstream commit + our patch, plus the placeholder
# reader for the DS core.
#
#   melonds-ds     the accessible DS core
#   vbam-libretro  the accessible VBA-M core (ordinary VBA-M identity, adapter compiled in)
#   RetroArch      the frontend
#
# This runs on macOS, Linux or Git Bash; it does not need Xcode. Nothing outside $SRC_DIR is
# written, and nothing is ever deleted: a destination that already exists is REFUSED, because
# CORE_SRC and FRONTEND_SRC are caller-controlled and a stray value must not be able to turn this
# into a recursive delete of something that matters.
#
# To reconstruct from scratch, point it at a fresh work directory:
#
#     WORK_DIR=/tmp/kit-$(date +%s) bash scripts/fetch_sources.sh
#
# or remove the previous one yourself, deliberately.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd git

fetch_pinned() {
    local url="$1" sha="$2" dest="$3"
    log "fetching $(basename "$dest") at ${sha}"
    if [ -e "$dest" ]; then
        die "${dest} already exists. This script never deletes it for you.
       Use a fresh work directory:  WORK_DIR=<new empty dir> bash scripts/fetch_sources.sh
       or remove ${dest} yourself if you are sure that is what you want."
    fi
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"
    # Fetching an exact commit keeps this reproducible and avoids downloading history.
    if ! git -C "$dest" fetch -q --depth 1 origin "$sha"; then
        info "shallow fetch of the exact commit failed; falling back to a full fetch"
        git -C "$dest" fetch -q origin
    fi
    git -C "$dest" checkout -q "$sha" 2>/dev/null || git -C "$dest" checkout -q FETCH_HEAD
    local head
    head="$(git -C "$dest" rev-parse HEAD)"
    [ "$head" = "$sha" ] || die "expected $sha in $dest, got $head"
    info "at $head"
}

apply_patch() {
    local dest="$1" patch="$2"
    [ -f "$patch" ] || die "missing patch: $patch"
    log "applying $(basename "$patch")"
    # --check first so a failure names the conflict instead of leaving a half-applied tree.
    git -C "$dest" apply --check --verbose "$patch" \
        || die "$(basename "$patch") does not apply to the pinned base. Regenerate it with
       tools/export_public_source.py, or update the pin in scripts/common.sh."
    # Deliberately NOT -3: the patches are post-processed (a private absolute path is stripped at
    # export time), so their blob hashes do not match and three-way merge would reject them.
    git -C "$dest" apply "$patch"
    info "applied"
}

mkdir -p "$SRC_DIR"

fetch_pinned "$CORE_UPSTREAM"     "$CORE_BASE"     "$CORE_SRC"
apply_patch  "$CORE_SRC" "${KIT_DIR}/patches/core.patch"

fetch_pinned "$VBAM_UPSTREAM"     "$VBAM_BASE"     "$VBAM_SRC"
apply_patch  "$VBAM_SRC" "${KIT_DIR}/patches/vbam.patch"

fetch_pinned "$FRONTEND_UPSTREAM" "$FRONTEND_BASE" "$FRONTEND_SRC"
apply_patch  "$FRONTEND_SRC" "${KIT_DIR}/patches/frontend.patch"

# --- what the VBA-M tree must and must not contain ----------------------------------------------
# The VBA-M adapter loads its reader from <system>/vbam_access at RUNTIME and embeds nothing at
# build time, so unlike the DS core there is no placeholder to stage here -- and no reader files
# should exist in the reconstructed tree at all. If any appear, the patch is not the one that was
# reviewed and this build must not continue.
log "checking the VBA-M tree"
[ ! -d "${VBAM_SRC}/reader" ] || die "${VBAM_SRC}/reader exists. The reader is third-party, has no
       redistribution licence and is supplied at runtime from <system>/vbam_access -- it must never
       come out of a patch in this kit."
for required in \
    "src/libretro/access/access_core.cpp" \
    "src/libretro/access/access_reader.cpp" \
    "src/libretro/access/lua/lapi.c" \
    "${VBAM_INFO_REL}"; do
    [ -f "${VBAM_SRC}/${required}" ] || die "${required} is missing from the reconstructed VBA-M
       tree. The adapter would not build, or would build without its metadata."
done
grep -q 'VBAM_ACCESS' "${VBAM_SRC}/src/libretro/Makefile.common" \
    || die "src/libretro/Makefile.common has no VBAM_ACCESS block, so the adapter would not be
       compiled in and the core would be stock VBA-M with no reader."
grep -q '^corename = "'"${VBAM_CORENAME}"'"' "${VBAM_SRC}/${VBAM_INFO_REL}" \
    || die "${VBAM_INFO_REL} does not declare corename = \"${VBAM_CORENAME}\"."
info "adapter sources, vendored Lua and ${VBAM_INFO_NAME} present; no reader files"

# The real Pokemon reader is not in this repository and never will be. The core embeds whatever
# lua/pokemon_bw_reader.lua holds at build time, purely as a last-resort fallback; its runtime
# search order still prefers <system>/melondsds_access/pokemon_bw_reader.lua, which is where the
# user puts the real one. The placeholder raises an explicit error instead of pretending to read
# a game. reader_locator.cpp and the embed_binaries() call are untouched.
log "staging the placeholder reader"
READER_DIR="${CORE_SRC}/src/libretro/accessibility/lua"
mkdir -p "$READER_DIR"
cp "${KIT_DIR}/stub/pokemon_bw_reader.lua" "${READER_DIR}/pokemon_bw_reader.lua"
info "${READER_DIR}/pokemon_bw_reader.lua"

# Fail closed: if a real reader ever ends up here, stop rather than bake it into a public build.
READER_BYTES=$(wc -c < "${READER_DIR}/pokemon_bw_reader.lua" | tr -d ' ')
if [ "$READER_BYTES" -gt 16384 ]; then
    die "the staged reader is ${READER_BYTES} bytes. The placeholder is ~1.5 KB; anything this
       large is the real reader, which must not be compiled into a public build."
fi
info "${READER_BYTES} bytes (placeholder)"

# assets.zip is a Resource of the app target and is extracted on first launch to
# <Documents>/RetroArch, which is where the core info directory lives. At the pinned commit it is
# committed to the repository, so a plain non-AppStore build has it. The 'Rebuild assets.zip'
# aggregate target that regenerates it is NOT a dependency of the app scheme, so if it is ever
# missing xcodebuild will not produce it -- check now rather than discover it during packaging.
log "checking the bundled assets archive"
ASSETS_ZIP="${FRONTEND_SRC}/pkg/apple/assets.zip"
if [ ! -f "$ASSETS_ZIP" ]; then
    if [ "${ALLOW_ASSET_DOWNLOAD:-0}" = "1" ]; then
        info "missing; regenerating it with the upstream script (this downloads from libretro)"
        ( cd "${FRONTEND_SRC}/pkg/apple" && bash ./rebuild-assets.sh -o )
    else
        die "${ASSETS_ZIP} is missing and the app scheme will not build it.
       Regenerate it with the upstream script -- note that it DOWNLOADS from git.libretro.com:
           cd ${FRONTEND_SRC}/pkg/apple && bash ./rebuild-assets.sh -o
       or re-run this script with ALLOW_ASSET_DOWNLOAD=1 to do that automatically."
    fi
fi
info "$(basename "$ASSETS_ZIP") present, $(wc -c < "$ASSETS_ZIP" | tr -d ' ') bytes"

log "sources ready"
info "ds core   ${CORE_SRC}"
info "vbam core ${VBAM_SRC}"
info "frontend  ${FRONTEND_SRC}"
