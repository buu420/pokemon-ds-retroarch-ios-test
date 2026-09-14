# iOS build kit — accessible melonDS DS on iPhone

Builds an iPhone test version of the Pokémon Black/White accessibility port: the **melonDS DS
core with the accessibility work**, inside **RetroArch for iOS**, speaking through **RetroArch's
own built-in accessibility** (`AVSpeechSynthesizer` on Apple). No new speech system, no redesigned
controls — the same queue / interrupt / stop hooks the Windows build already uses, wired to the
Darwin platform driver.

The output is an ad-hoc-signed `.ipa` you install with **AltStore** and a **free Apple account**.

> **Nothing here has been built or tested yet.** A *successful* run of this pipeline would show
> that both halves compile, that the DS core ends up in the app bundle as a framework, that the
> corrected core info is inside the bundled assets archive, and that the ad-hoc signature verifies.
> It would still say nothing about whether the app launches, whether speech is audible, or whether
> the reader reads. Treat any artifact as a candidate until someone installs it and listens.

## What is in this repository

```
patches/core.patch       melonDS DS accessibility work, against a pinned upstream commit
patches/frontend.patch   RetroArch native-speech work, against a pinned upstream commit
patches/pins.json        the pinned commits, in machine-readable form
stub/                    a placeholder reader script (see "The reader is not here")
scripts/                 the build, runnable locally on a Mac and identically in CI
config/                  prepared core options and what to set in the menu
tools/                   the export command and its fail-closed privacy check
.github/workflows/       the GitHub Actions build
SIDELOAD-GUIDE.md        install and first-run instructions for the phone
```

There is no vendored source here. The build clones upstream at exactly:

| | upstream | commit |
| --- | --- | --- |
| core | `https://github.com/JesseTG/melonds-ds.git` | `bc4e4b67d2d470d7c682810a1e892cafd6f9082b` (v1.3.1) |
| frontend | `https://github.com/libretro/RetroArch.git` | `69a4f0ea1e8aaf442ae4858f2e7f2b31a1776576` |

## The reader is not here, and that is deliberate

The Pokémon Black/White reader script is a large third-party file with no established
redistribution licence, so it is **not** in this repository and never will be. Neither is any ROM,
save or BIOS image. `tools/verify_public_kit.py` enforces that by refusing to let the kit be
published if it finds any of them.

Nothing in the core was changed to make that work. `reader_locator.cpp` already searches, in order:

1. `<directory containing the core library>/melondsds_access/pokemon_bw_reader.lua`
2. `<RetroArch system directory>/melondsds_access/pokemon_bw_reader.lua`
3. the copy embedded at build time

The build simply embeds `stub/pokemon_bw_reader.lua` at step 3 instead of the real script. That
placeholder does not fake anything: it raises an error immediately, and the core speaks

> "Accessibility reader stopped. The Pokémon reader script is not included in this build. Copy
> pokemon_bw_reader.lua into the melondsds_access folder inside RetroArch's system folder, then
> reload the game."

Put the real script at step 2 on the phone (see `SIDELOAD-GUIDE.md`) and it takes precedence. The
core does not need rebuilding for that.

## Build it on a Mac

Needs macOS with Xcode (not just the Command Line Tools — the core's iOS toolchain file runs
`xcodebuild -version` and hard-fails without it), a current `cmake`, `ninja`, `git`, and network
access at configure time.

```bash
APP_BUNDLE_ID=com.example.RetroArchAccess bash scripts/build_all.sh
```

That runs four steps, which you can also run one at a time:

```bash
bash scripts/fetch_sources.sh     # clone pinned upstream, apply patches, stage the placeholder
bash scripts/build_core_ios.sh    # cmake + ninja -> melondsds_libretro.dylib, staged for the app
bash scripts/build_app_ios.sh     # xcodebuild -> RetroArch.app with the core inside it
bash scripts/make_ipa.sh          # -> work/out/RetroArchAccess.ipa
```

`fetch_sources.sh` alone needs neither macOS nor Xcode, so the patches can be checked anywhere.

## Build it in GitHub Actions

`.github/workflows/build-ios.yml`, on a GitHub-hosted macOS runner. Run it from the Actions tab
(**Run workflow**); it takes a runner label (restricted to the standard free images), a bundle id,
a display name and a deployment target. It uses **no secrets and no Apple account**, and uploads
the `.ipa` as a workflow artifact named `RetroArchAccess-ios-UNTESTED-ON-DEVICE`. That is not a
release, but it is still an upload: in a public repository, anyone who can read the repository can
download the artifact.

## How the pieces actually fit together

These are the non-obvious bits, all read out of the two upstream trees rather than assumed.

**The core is a framework, not a dylib.** An iOS RetroArch build is compiled with
`-DHAVE_FRAMEWORKS` (`pkg/apple/BaseConfig.xcconfig`), which makes `DEFAULT_DIR_CORE` the app
bundle's `Frameworks` folder and the core file extension `framework`
(`frontend/frontend_driver.c`). `dylib_load()` then `dlopen`s `<name>.framework/<name>`. The
existing `pkg/apple/make-frameworks.sh` build phase converts every
`pkg/apple/iOS/modules/*libretro*.dylib` into exactly that, replacing `_` with `.` — so
`melondsds_libretro.dylib` becomes `Frameworks/melondsds.libretro.framework`. `build_core_ios.sh`
stages the dylib there and `build_app_ios.sh` asserts the framework came out the other side.

**Signing, with no developer account.** `DEVELOPMENT_TEAM = UK699V5ZS8` (libretro's) is baked into
the project's Debug *and* Release configs and `CODE_SIGN_STYLE` is unset, so it defaults to
Automatic and xcodebuild would try to fetch a profile for a team you are not in. So Xcode's own
signing is switched off outright — `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, empty
team, empty entitlements, empty profile specifier — and no profile is ever looked up. There is no
provisioning dependency left enabled.

`make-frameworks.sh` is the exception: it calls
`codesign --force --verbose --sign "$EXPANDED_CODE_SIGN_IDENTITY"` *unconditionally* on every core
framework and on MoltenVK, and there is no path that skips it. With Xcode's signing off it would be
handed an empty identity, so the build passes it the ad-hoc identity `-` as both
`CODE_SIGN_IDENTITY` and `EXPANDED_CODE_SIGN_IDENTITY` (the one it prefers). Passing them as build
settings puts them in the script phase's environment without editing the project.

The app bundle itself is signed ad-hoc by `make_ipa.sh`, *after* packaging has finished changing it,
and the signature is then verified — a failure there stops the build rather than being logged and
ignored. AltStore re-signs everything with your own certificate at install time.

**No paid entitlements.** `CODE_SIGN_ENTITLEMENTS` expands to empty unless
`pkg/apple/iOS/AppStore.xcconfig` is used, so none are applied. That is the point:
`RetroArch.entitlements` asks for multicast networking, push, iCloud/CloudKit and Siri, and a free
account can sign none of them. `AppStore.xcconfig` is also never passed for a second reason — it
sets `APPSTORE_BUILD`, whose build-phase branch runs `rm -f iOS/modules/*.dylib` (deleting the core
just staged) and then downloads stock cores and assets over the network.

**No widget.** The widget extension is a hard target dependency of the app, so it is always built;
`make_ipa.sh` removes it from the `Payload` afterwards. That is a packaging-only change and it
matters, because every embedded extension needs its own App ID and a free account only gets ten per
seven days. Set `KEEP_APP_EXTENSIONS=1` to keep it.

**A distinct identity.** `APP_BUNDLE_ID` (default `com.example.RetroArchAccess`) is applied through
`IOS_BUNDLE_IDENTIFIER`, which also drives the widget's id. iOS keys containers by bundle id, so an
existing App Store RetroArch, its saves and its settings are untouched and both can be installed at
once. `CFBundleDisplayName` is a literal string in `pkg/apple/iOS/Info.plist` and cannot be set from
a build setting, so `make_ipa.sh` patches it in the built bundle and re-signs.

**The app's minimum iOS version is raised to match the core's.** The app target reads
`$(RA_IPHONEOS_DEPLOYMENT_TARGET:default=12.0)`, so the build passes
`RA_IPHONEOS_DEPLOYMENT_TARGET` rather than the generic `IPHONEOS_DEPLOYMENT_TARGET` — the widget
extension sets `IPHONEOS_DEPLOYMENT_TARGET = 16.0` outright and overriding the generic setting
would drag it down. This is not cosmetic: `make-frameworks.sh` rewrites the core's Mach-O with
`vtool -set-build-version ios $IPHONEOS_DEPLOYMENT_TARGET`, so leaving the app at 12.0 would stamp
the core as iOS 12 when it was compiled for 14.

**The core info is corrected for iOS.** `melondsds_libretro.info.in` hard-codes `hw_render = "true"`
and `required_hw_api = "OpenGL Core >= 3.2"` for every platform. Neither is true here: melonDS has
no GLES renderer, so `ENABLE_OPENGL` is off by default on iOS and the build is software-rendered.
`build_core_ios.sh` fixes the staged copy (`hw_render = "false"`, `required_hw_api` removed) rather
than the shared source.

**The core info travels inside the app.** `platform_darwin.m` extracts `<bundle>/assets.zip` to
`<Documents>/RetroArch` on first launch, and `DEFAULT_DIR_CORE_INFO` is `<Documents>/RetroArch/info`.
`make_ipa.sh` adds the corrected `info/melondsds_libretro.info` to that archive before signing —
one entry added to the ~190 already there, everything else untouched — and then verifies it inside
the packaged `.ipa`. So the core is identified by name in the menu with nothing for the user to
copy. The `.info` is still uploaded as a separate artifact for reference.

**JIT is off** — it is already the iOS default in the core's CMake, and a sideloaded app has no
`dynamic-codesigning` entitlement anyway. Both `-DENABLE_JIT=OFF` and `-DENABLE_OPENGL=OFF` are
passed explicitly so a future default change cannot quietly turn them on.

**The build is not offline.** The core's CMake fetches its dependencies at configure time —
melonDS, libretro-common, embed-binaries, glm, zlib, libslirp, pntr, fmt, yamc, span-lite, date —
and downloads the Lua 5.4.9 tarball from `lua.org`, pinned by SHA256 (`2335b6c5…`) and linked
statically. If `pkg/apple/assets.zip` is ever missing, regenerating it with upstream's
`rebuild-assets.sh` downloads from `git.libretro.com` too; at the pinned commit it is committed to
the repository, so that normally does not happen. What the build does *not* do is download a
prebuilt RetroArch or a prebuilt core — both are compiled here. On the Xcode side nothing is
fetched at all: RetroArch has no submodules, no Swift packages and no CocoaPods, and MoltenVK is
vendored in-tree.

## Refreshing the patches

The patches are generated from two local working trees, not edited by hand. Regenerate them
whenever either tree changes:

```
python tools/export_public_source.py ^
    --core     <path to melonds-ds working tree> ^
    --frontend <path to RetroArch working tree> ^
    --kit      . ^
    --check-apply
```

It classifies every changed and untracked path as export / exclude / unclassified — an unclassified
path is a hard error, so new work has to be classified deliberately rather than silently shipped or
silently dropped. It never writes to either source tree. With `--check-apply` it rebuilds each tree
from its pinned base, applies the patch, and asserts the result contains what the build needs and
none of what it must not. Finally it runs `tools/verify_public_kit.py`; if anything private turns
up, the patches that run produced are **deleted** again and it exits non-zero.

Run the privacy check on its own at any time:

```
python tools/verify_public_kit.py --kit .
```

## Licences

melonDS DS and RetroArch are GPLv3-or-later and GPLv3 respectively; the patches here are
derivative works under the same terms. The placeholder reader in `stub/` is original to this kit.
