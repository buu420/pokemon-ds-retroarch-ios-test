#!/bin/bash
# Turn the built RetroArch.app into a free-account-sideloadable .ipa.
#
# RetroArch has no .ipa producer of its own: nothing in the repo builds a Payload/ directory, and
# the only export path (fastlane, or the unused pkg/apple/iOS/gitlabExportOptions.plist) hardcodes
# the libretro team and App Store distribution. So the .ipa is assembled here, by hand, from the
# plain `xcodebuild build` product. That is also the simplest thing AltStore can consume.
#
# Order matters: every change to the bundle happens BEFORE it is signed, and the signature is then
# verified. Xcode's own signing was switched off during the build, so this is the only thing that
# signs the app. AltStore re-signs it again with the user's certificate at install time.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_macos
require_cmd zip unzip codesign
[ -x /usr/libexec/PlistBuddy ] || die "PlistBuddy not found at /usr/libexec/PlistBuddy"

APP="${APP_PATH:-$(cat "${WORK_DIR}/.app-path" 2>/dev/null || true)}"
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app -- run scripts/build_app_ios.sh first."

INFO_FILE="${OUT_DIR}/${CORE_INFO_NAME}"
[ -f "$INFO_FILE" ] || die "no corrected core info at $INFO_FILE -- run scripts/build_core_ios.sh first."

STAGE="${WORK_DIR}/ipa"
mkdir -p "$WORK_DIR"
safe_rm_rf "$STAGE" "$WORK_DIR"
mkdir -p "${STAGE}/Payload" "$OUT_DIR"

log "staging Payload"
cp -R "$APP" "${STAGE}/Payload/"
PAYLOAD_APP="${STAGE}/Payload/$(basename "$APP")"
[ -d "$PAYLOAD_APP" ] || die "the app did not copy into the Payload"

if [ "$KEEP_APP_EXTENSIONS" = "0" ]; then
    # The widget extension is a hard target dependency of the app, so it is always built and
    # embedded; it cannot be dropped without editing the Xcode project, which this kit does not do.
    # Removing it from the Payload is the minimal packaging-only equivalent. It matters for a free
    # account: every embedded extension needs its own App ID, and a free account gets 10 per 7 days.
    for dir in PlugIns Extensions; do
        if [ -d "${PAYLOAD_APP}/${dir}" ]; then
            log "removing embedded app extensions (${dir})"
            ls "${PAYLOAD_APP}/${dir}" | while read -r e; do info "dropped ${e}"; done
            safe_rm_rf "${PAYLOAD_APP}/${dir}" "$STAGE"
        fi
    done
else
    info "keeping embedded app extensions (KEEP_APP_EXTENSIONS=1)"
fi

# --- core info, into the bundled assets archive ------------------------------------------------
# platform_darwin.m extracts <bundle>/assets.zip to <Documents>/RetroArch on first launch, and
# DEFAULT_DIR_CORE_INFO is <Documents>/RetroArch/info. Putting our .info in the archive's info/
# directory means the core is identified by name in the menu with nothing for the user to copy.
# The archive already ships an info/ directory (~190 entries), so this ADDS one entry and leaves
# everything else exactly as it was.
log "adding the core info to assets.zip"
ASSETS="${PAYLOAD_APP}/assets.zip"
[ -f "$ASSETS" ] || die "assets.zip is not in the bundle: $ASSETS"

grep -q '^hw_render = "false"' "$INFO_FILE" || die "$INFO_FILE does not have hw_render = \"false\""
! grep -q '^required_hw_api' "$INFO_FILE" || die "$INFO_FILE still has required_hw_api"

BEFORE_COUNT="$(unzip -l "$ASSETS" | tail -1 | awk '{print $2}')"
INSERT="${STAGE}/assets-insert"
mkdir -p "${INSERT}/info"
cp "$INFO_FILE" "${INSERT}/info/${CORE_INFO_NAME}"
( cd "$INSERT" && zip -q "$ASSETS" "info/${CORE_INFO_NAME}" ) \
    || die "could not add info/${CORE_INFO_NAME} to assets.zip"
safe_rm_rf "$INSERT" "$STAGE"

AFTER_COUNT="$(unzip -l "$ASSETS" | tail -1 | awk '{print $2}')"
info "archive entries: ${BEFORE_COUNT} -> ${AFTER_COUNT}"
[ "$AFTER_COUNT" -ge "$BEFORE_COUNT" ] || die "assets.zip lost entries: ${BEFORE_COUNT} -> ${AFTER_COUNT}"

# NEVER pipe unzip into `grep -q`. grep -q exits at the first match, unzip then dies of SIGPIPE,
# and `set -o pipefail` (from common.sh) turns that into exit 141 -- so a perfectly good archive is
# rejected. Reproduced against the real 2006-entry assets.zip: `unzip -l ... | grep -q info/` exits
# 141 while the same command redirected to /dev/null exits 0. Every archive check below therefore
# writes the bytes out first and greps the FILE, which also leaves the evidence on disk.
ARCHIVED_INFO="${STAGE}/info.in-archive"
unzip -p "$ASSETS" "info/${CORE_INFO_NAME}" > "$ARCHIVED_INFO" \
    || die "info/${CORE_INFO_NAME} could not be read back out of assets.zip"
[ -s "$ARCHIVED_INFO" ] || die "info/${CORE_INFO_NAME} in assets.zip is empty"
grep -q '^hw_render = "false"' "$ARCHIVED_INFO" \
    || die "the info inside assets.zip does not have hw_render = \"false\""
if grep -q '^required_hw_api' "$ARCHIVED_INFO"; then
    die "the info inside assets.zip still has required_hw_api"
fi
info "info/${CORE_INFO_NAME}: hw_render=false, no required_hw_api"

# --- identity ----------------------------------------------------------------------------------
# CFBundleDisplayName and CFBundleName are literal strings in pkg/apple/iOS/Info.plist, so unlike
# the bundle id they cannot be set from a build setting. Patch the built copy so this test build is
# distinguishable on the home screen from an App Store RetroArch.
log "setting the app name"
PLIST="${PAYLOAD_APP}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_DISPLAY_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_DISPLAY_NAME}" "$PLIST"
ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
info "CFBundleDisplayName = ${APP_DISPLAY_NAME}"
info "CFBundleIdentifier  = ${ACTUAL_ID}"
[ "$ACTUAL_ID" = "$APP_BUNDLE_ID" ] || die "the built bundle id is ${ACTUAL_ID}, expected ${APP_BUNDLE_ID}.
       The IOS_BUNDLE_IDENTIFIER override did not take effect; installing this would collide with
       an existing RetroArch."

# --- signing -----------------------------------------------------------------------------------
# Xcode's signing was disabled for the build, so this is the app's only signature. It is ad-hoc:
# there is no Apple account here and none is needed, because AltStore re-signs the whole bundle
# with the user's own free certificate when it installs. A failure here is NOT swallowed -- an
# unsigned or half-signed bundle is a real defect, not a cosmetic one.
log "signing the bundle (ad-hoc)"
codesign --force --sign - --deep --timestamp=none "$PAYLOAD_APP" \
    || die "ad-hoc signing failed. The bundle is not well-formed; fix that rather than shipping it."
codesign --verify --deep --strict --verbose=2 "$PAYLOAD_APP" \
    || die "the signature did not verify after signing."
info "signature verifies"
codesign --verify --strict "${PAYLOAD_APP}/Frameworks/melondsds.libretro.framework" \
    || die "the core framework's signature did not verify."
info "core framework signature verifies"

# --- package -----------------------------------------------------------------------------------
IPA="${OUT_DIR}/${IPA_NAME}.ipa"
rm -f "$IPA"
log "packaging ${IPA_NAME}.ipa"
( cd "$STAGE" && zip -qry "$IPA" Payload )
[ -f "$IPA" ] || die "the .ipa was not produced"

# Verify what actually ended up in the shipped archive, not what we think we put there.
log "verifying the packaged ipa"
APP_IN_IPA="Payload/$(basename "$APP")"
# Listed to a file rather than piped into grep -q, for the SIGPIPE reason explained above.
IPA_LISTING="${STAGE}/ipa-listing.txt"
unzip -l "$IPA" > "$IPA_LISTING" || die "could not list the contents of $IPA"
grep -q "${APP_IN_IPA}/Frameworks/melondsds\.libretro\.framework/melondsds\.libretro" "$IPA_LISTING" \
    || die "the .ipa does not contain the core framework executable -- refusing to ship it"
info "melondsds.libretro.framework present"

VERIFY_DIR="${STAGE}/verify"
mkdir -p "$VERIFY_DIR"
unzip -qo "$IPA" "${APP_IN_IPA}/assets.zip" -d "$VERIFY_DIR" \
    || die "assets.zip is not in the packaged .ipa"
unzip -p "${VERIFY_DIR}/${APP_IN_IPA}/assets.zip" "info/${CORE_INFO_NAME}" > "${VERIFY_DIR}/info.check" \
    || die "info/${CORE_INFO_NAME} is not inside the packaged assets.zip"
grep -q '^hw_render = "false"' "${VERIFY_DIR}/info.check" \
    || die "the packaged core info does not have hw_render = \"false\""
if grep -q '^required_hw_api' "${VERIFY_DIR}/info.check"; then
    die "the packaged core info still has required_hw_api"
fi
info "packaged info/${CORE_INFO_NAME} verified inside assets.zip"
safe_rm_rf "$VERIFY_DIR" "$STAGE"

log "done"
info "$IPA"
info "$(du -h "$IPA" | cut -f1)"
if command -v shasum >/dev/null 2>&1; then
    info "sha256 $(shasum -a 256 "$IPA" | cut -d' ' -f1)"
fi
cat <<'NOTE'

    NOT TESTED ON A PHYSICAL DEVICE. These checks confirm the build completed, the core framework
    and the corrected core info are inside the bundle, and the signature verifies. Whether the app
    launches, whether speech is audible and whether the reader reads are open until someone
    installs it.
NOTE
