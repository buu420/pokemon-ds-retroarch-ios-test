#!/bin/bash
# Build RetroArch.app for an iOS device with no Apple developer account.
#
# The signing story, from reading the project rather than guessing:
#
#  * DEVELOPMENT_TEAM = UK699V5ZS8 (libretro's team) is baked into the PROJECT-level Debug and
#    Release configs, and CODE_SIGN_STYLE is unset, so it defaults to Automatic. Left alone,
#    xcodebuild tries to fetch a provisioning profile for a team we are not in and fails. So the
#    team is emptied and Xcode's own signing is switched OFF entirely
#    (CODE_SIGNING_ALLOWED=NO, CODE_SIGNING_REQUIRED=NO): no profile is ever looked up, which is
#    the point -- there is no Apple account here.
#  * pkg/apple/make-frameworks.sh runs as a build phase and calls
#    `codesign --force --verbose --sign "$EXPANDED_CODE_SIGN_IDENTITY"` UNCONDITIONALLY on every
#    core framework and on MoltenVK.framework. There is no code path that skips it, and with
#    Xcode's signing disabled it would otherwise be handed an empty identity. It is given the
#    ad-hoc identity "-" instead, both as CODE_SIGN_IDENTITY and as EXPANDED_CODE_SIGN_IDENTITY
#    (the one it prefers), so the nested frameworks get a real ad-hoc signature. Passing these as
#    build settings puts them in the script phase's environment without editing the project.
#  * CODE_SIGN_ENTITLEMENTS is emptied. pkg/apple/iOS/RetroArch.entitlements asks for multicast,
#    push, iCloud/CloudKit and Siri, every one of which needs a PAID account.
#  * -xcconfig pkg/apple/iOS/AppStore.xcconfig is deliberately NOT passed. It sets APPSTORE_BUILD,
#    which makes the build phase `rm -f iOS/modules/*.dylib` -- deleting the core staged by
#    build_core_ios.sh -- and then download stock cores and assets over the network.
#
# The app bundle itself is signed ad-hoc later, by make_ipa.sh, after packaging has finished
# changing it. AltStore re-signs everything with the free account's own certificate at install.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_macos
require_cmd xcodebuild python3

PROJECT="${FRONTEND_SRC}/${XCODE_PROJECT_REL}"
[ -d "$PROJECT" ] || die "no Xcode project at $PROJECT -- run scripts/fetch_sources.sh first."

STAGED_CORE="${FRONTEND_SRC}/pkg/apple/iOS/modules/${CORE_DYLIB_NAME}"
[ -f "$STAGED_CORE" ] || die "no core staged at $STAGED_CORE -- run scripts/build_core_ios.sh first.
       Building without it would produce an app with no DS core in it."

DERIVED="${WORK_DIR}/derived"
mkdir -p "$DERIVED" "$OUT_DIR"

ASSETS_ZIP="${FRONTEND_SRC}/pkg/apple/assets.zip"
[ -f "$ASSETS_ZIP" ] || die "no $ASSETS_ZIP -- run scripts/fetch_sources.sh first.
       The app scheme does not build it, so the app would ship without its bundled assets and
       without a core info directory."

# The app target depends on the widget extension and embeds the .appex, and Xcode then runs
# ValidateEmbeddedBinary, which demands the embedded binary carry the parent's signing certificate.
# With Xcode signing off and the app signed ad-hoc afterwards, the widget is unsigned and the build
# dies (observed: "Embedded Binary Signing Certificate: Not Code Signed" vs "- (Ad Hoc Code
# Signed)"). Dropping the .appex from the Payload later cannot help -- validation happens during
# the build. So the dependency and the embed are removed from the EPHEMERAL FETCHED copy of the
# project first. The widget is not wanted here anyway: it would consume a second App ID out of a
# free account's ten per seven days.
if [ "$KEEP_APP_EXTENSIONS" = "0" ]; then
    log "unhooking the widget extension from the app target"
    python3 "${KIT_DIR}/scripts/strip_widget_extension.py" "${PROJECT}/project.pbxproj" \
        || die "could not unhook the widget extension from the project. The script refuses rather
       than edit something it does not recognise, so the message above says what did not match."
else
    die "KEEP_APP_EXTENSIONS=1 is not supported by this kit.
       The widget is embedded but cannot be signed: this build has no Apple account, Xcode signing
       is disabled, and Xcode's ValidateEmbeddedBinary step then fails the build outright --
       confirmed on a real macOS runner, GitHub run 34909462095. Keeping the widget needs a signing
       identity that can cover both the app and the extension, which is out of scope here. Unset
       KEEP_APP_EXTENSIONS to build without it."
fi

log "building RetroArch.app for iOS"
info "scheme      ${XCODE_SCHEME}"
info "bundle id   ${APP_BUNDLE_ID} (widget removed, so no second App ID is needed)"
info "min iOS     ${IOS_DEPLOYMENT_TARGET} for the app"
info "signing     Xcode signing off; nested frameworks ad-hoc; no team, profile or entitlements"

# RA_IPHONEOS_DEPLOYMENT_TARGET, not IPHONEOS_DEPLOYMENT_TARGET: only the two app configurations
# read it (`$(RA_IPHONEOS_DEPLOYMENT_TARGET:default=12.0)`). Overriding the generic setting would
# also rewrite every other target in the project, which is not what is wanted. This matters
# beyond metadata: make-frameworks.sh rewrites the core's Mach-O with
# `vtool -set-build-version ios $IPHONEOS_DEPLOYMENT_TARGET`, so leaving the app at the 12.0
# default would stamp the core as iOS 12 when it was compiled for ${IOS_DEPLOYMENT_TARGET}.
set -x
xcodebuild \
    -project "$PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIG" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    IOS_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
    RA_IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    EXPANDED_CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_ENTITLEMENTS="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO \
    build
set +x

APP="${DERIVED}/Build/Products/${XCODE_CONFIG}-iphoneos/RetroArch.app"
[ -d "$APP" ] || die "the app did not build: $APP is missing"

# The whole point of this build: the core has to actually be inside the bundle, as a framework,
# because an iOS RetroArch build looks for cores in <bundle>/Frameworks with the extension
# 'framework' (frontend/frontend_driver.c) and dylib_load() dlopens
# <name>.framework/<name>. make-frameworks.sh derives that name by replacing '_' with '.'.
FW="${APP}/Frameworks/melondsds.libretro.framework"
[ -d "$FW" ] || die "melondsds.libretro.framework is not in the app bundle.
       make-frameworks.sh did not pick up ${STAGED_CORE}. Without it the app has no DS core."
[ -f "${FW}/melondsds.libretro" ] || die "${FW} has no executable inside it"
log "core framework is in the bundle"
info "$(ls -l "${FW}/melondsds.libretro" | awk '{print $5" bytes"}')"

# Nothing should be embedded under PlugIns: the widget was unhooked from the target before the
# build, so Xcode's ValidateEmbeddedBinary had nothing to validate. If it is here, the project edit
# silently did not take and the next build would fail signing validation again.
if [ "$KEEP_APP_EXTENSIONS" = "0" ] && [ -d "${APP}/PlugIns" ]; then
    ls -1 "${APP}/PlugIns" | sed 's/^/       still embedded: /'
    die "${APP}/PlugIns exists, but the widget was supposed to have been unhooked before the build.
       The project edit did not take effect; the next build would fail signing validation again."
fi
info "no embedded app extensions"

# assets.zip is extracted to <Documents>/RetroArch on first launch, and its info/ directory is
# where RetroArch looks for core info. make_ipa.sh adds our core's .info to it.
[ -f "${APP}/assets.zip" ] || die "assets.zip is not in the built bundle.
       Without it the app has no assets and no core info directory to add to."
info "assets.zip in the bundle, $(wc -c < "${APP}/assets.zip" | tr -d ' ') bytes"

echo "$APP" > "${WORK_DIR}/.app-path"
info "app: $APP"
