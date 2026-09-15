# iOS build kit — accessible melonDS DS and VBA-M on iPhone

Builds an iPhone test version of the Pokémon accessibility port: **two cores with the accessibility
work** — melonDS DS (Nintendo DS) and VBA-M (Game Boy / Color / Advance) — inside **RetroArch for
iOS**, both speaking through **RetroArch's own built-in accessibility** (`AVSpeechSynthesizer` on
Apple). No new speech system, no redesigned controls — the same queue / interrupt / stop hooks the
Windows build already uses, wired to the Darwin platform driver.

Both cores go into one app. They are independent: each has its own core option to switch its reader
on, each looks for its own reader files, and neither one changes what the other does.

The output is an ad-hoc-signed `.ipa` you install with **AltStore** and a **free Apple account**.

> **The DS half has built on a Mac runner; the VBA-M half has not been built at all yet, and
> nothing has been tested on a phone.** An earlier build compiled the DS core and RetroArch,
> packaged the core and its corrected info file, and passed the app and core signature checks.
> The VBA-M core is new here: its iOS build has never run, so treat a green run as the first
> evidence it compiles, and nothing more. Neither core's narration has been heard on an iPhone.

## What is in this repository

```
patches/core.patch       melonDS DS accessibility work, against a pinned upstream commit
patches/vbam.patch       VBA-M accessibility work, against a pinned upstream commit
patches/frontend.patch   RetroArch native-speech work, against a pinned upstream commit
patches/pins.json        the pinned commits, in machine-readable form
stub/                    a placeholder reader script (see "The readers are not here")
scripts/                 the build, runnable locally on a Mac and identically in CI
config/                  prepared core options, one file per core, and what to set in the menu
tools/                   the export command, its fail-closed privacy check, and that check's tests
.github/workflows/       the GitHub Actions build
SIDELOAD-GUIDE.md        install and first-run instructions for the phone
```

There is no vendored upstream source here — the build clones it. The one thing that does travel
inside a patch is Lua 5.4.9, because the VBA-M adapter vendors it in-tree; it is official Lua, MIT
licensed, and it is what makes that core's build need no network at all.

| | upstream | commit |
| --- | --- | --- |
| DS core | `https://github.com/JesseTG/melonds-ds.git` | `bc4e4b67d2d470d7c682810a1e892cafd6f9082b` (v1.3.1) |
| VBA-M core | `https://github.com/libretro/vbam-libretro.git` | `115defb3a318258ab84746d45258a1aec19d0b4b` |
| frontend | `https://github.com/libretro/RetroArch.git` | `69a4f0ea1e8aaf442ae4858f2e7f2b31a1776576` |

## The readers are not here, and that is deliberate

Both readers are large third-party scripts with no established redistribution licence, so neither
is in this repository and neither ever will be. Neither is any ROM, save or BIOS image.
`tools/verify_public_kit.py` enforces that by refusing to let the kit be published if it finds any
of them, and `tools/test_export_rules.py` checks that those refusals still fire.

### The VBA-M reader

The VBA-M adapter embeds nothing at all. It loads its reader at runtime from
`<RetroArch system directory>/vbam_access`, so there is not even a placeholder to ship: the patch
simply does not contain the directory, `scripts/fetch_sources.sh` refuses to continue if a
reconstructed tree has one, and the privacy check refuses any patch that touches `reader/` or adds
a `.lua` file at all.

With the core option on and that folder missing, the core **speaks** the reason and keeps running
as an ordinary emulator. See `config/README.md` for where the folder goes on the phone.

### The DS reader

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

That runs five steps, which you can also run one at a time:

```bash
bash scripts/fetch_sources.sh     # clone pinned upstream, apply patches, stage the placeholder
bash scripts/build_core_ios.sh    # cmake + ninja -> melondsds_libretro.dylib, staged for the app
bash scripts/build_vbam_ios.sh    # make -> vbam_libretro.dylib, staged for the app
bash scripts/build_app_ios.sh     # xcodebuild -> RetroArch.app with BOTH cores inside it
bash scripts/make_ipa.sh          # -> work/out/RetroArchAccess.ipa
```

Both core builds have to run before `build_app_ios.sh`: the frameworks are made by a build phase
that only sees what is staged at that moment, so a core built afterwards is simply not in the app.
`build_app_ios.sh` refuses to start if either one is missing, and names the one that is.

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
`pkg/apple/iOS/modules/*libretro*.dylib` into exactly that, dropping a trailing `_ios` and
replacing `_` with `.` — so `melondsds_libretro.dylib` becomes
`Frameworks/melondsds.libretro.framework` and `vbam_libretro.dylib` becomes
`Frameworks/vbam.libretro.framework`. The build scripts stage both dylibs there and
`build_app_ios.sh` asserts both frameworks came out the other side.

(The VBA-M Makefile actually emits `vbam_libretro_ios.dylib`. Because the suffix is stripped,
either name would give the same framework; `build_vbam_ios.sh` stages the plain one so both cores
are named the same way and the packaging checks have one convention to follow.)

**The VBA-M core is a plain Makefile build, and needs two overrides.** `src/libretro/Makefile`
already supports `platform=ios-arm64`: it picks the system clang out of Xcode, points it at the
iPhoneOS SDK and links a `-dynamiclib`. Two things are passed on the command line:

* `MINVERSION=-miphoneos-version-min=14` — the ios branch hardcodes 8.0, and a command-line
  assignment beats a makefile one. This has to match the app, because `make-frameworks.sh` re-stamps
  the Mach-O with the app's deployment target. `build_vbam_ios.sh` reads the minimum back out of
  the built binary with `vtool` and fails if it is not what was asked for.
* `PLATFORM_DEFINES="'-Dl_system(cmd)=((cmd)==NULL?0:-1)'"` — Lua's `os.execute` calls `system()`,
  which the iOS SDK declares unavailable, so the vendored Lua does not compile for iOS without it.
  `loslib.c` has a guarded hook for exactly this case, and this is the same stub Lua itself uses on
  iOS. `-DLUA_USE_IOS` would do the same thing but also switches on `LUA_USE_POSIX` and
  `LUA_USE_DLOPEN`, which is more than this needs; the DS core makes the same choice.

Both overrides are checked rather than assumed: the script reads the Makefile's ios branch first and
stops if it has started setting `PLATFORM_DEFINES` itself (which the command line would silently
replace), and it compiles a two-line probe to prove the `l_system` define survives the shell before
spending a full build on finding out.

The core's Lua is vendored in the source tree and compiled straight into the dylib, so this half of
the build downloads nothing and links no separate Lua. VBA-M has no dynamic recompiler on this
path, so there is no JIT to disable. `ACCESS=0` would build stock VBA-M; the script looks for the
`vbam_access_reader` option string inside the built binary rather than trusting the flag it passed.

**VBA-M keeps its ordinary identity.** The adapter adds one core option and changes nothing else
that a user would see: the core is still `VBA-M`, still takes `gb|gbc|gba`, and ships upstream's own
`src/libretro/vbam_libretro.info` untouched. The export check asserts that file is byte-identical to
the pinned base, and the build checks its sha256 against `patches/pins.json` before staging it.

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

**No widget, and it has to go before the build.** The app target declares the widget extension as
a dependency and embeds the `.appex`; Xcode then runs `ValidateEmbeddedBinary`, which requires the
embedded binary to carry the parent app's signing certificate. With Xcode signing off and the app
signed ad-hoc afterwards the widget is unsigned, and that failed a real runner build outright:
*"Embedded Binary Signing Certificate: Not Code Signed"* vs *"- (Ad Hoc Code Signed)"*. Deleting the
`.appex` from the `Payload` later cannot help, because validation happens during the build. So
`scripts/strip_widget_extension.py` removes the dependency and the embed phase from the **ephemeral
fetched copy** of `project.pbxproj` before `xcodebuild` runs — two lines, both inside the app
target, with the widget target itself left defined but unreferenced. No signing setting is weakened
and no source file is touched. It is wanted anyway: every embedded extension needs its own App ID,
and a free account gets ten per seven days. `KEEP_APP_EXTENSIONS=1` is refused with an explanation
rather than silently producing a build that cannot be signed.

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
`make_ipa.sh` adds `info/melondsds_libretro.info` and `info/vbam_libretro.info` to that archive
before signing — two entries in the ~190 already there, everything else untouched — and then reads
both back out of the packaged `.ipa` and compares them byte for byte with what was staged. So both
cores are identified by name in the menu with nothing for the user to copy. (`zip` replaces an entry
of the same name, so for a core the stock archive already knows about, this substitutes the copy
that matches what was actually built here.) Both `.info` files are also uploaded as separate
artifacts for reference.

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

The patches are generated from three local working trees, not edited by hand. Regenerate them
whenever any tree changes:

```
python tools/export_public_source.py ^
    --core     <path to melonds-ds working tree> ^
    --vbam     <path to vbam-libretro working tree> ^
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

And check that the privacy check still refuses what it is supposed to refuse. This builds synthetic
fixtures in a temporary directory — no reader, no ROM, no local path — hands each one to the
scanner and asserts it is rejected:

```
python tools/test_export_rules.py
```

## Licences

melonDS DS and RetroArch are GPLv3-or-later and GPLv3 respectively, and VBA-M is GPLv2-or-later;
the patches here are derivative works under the same terms as the tree each one applies to. The
Lua 5.4.9 sources vendored inside `patches/vbam.patch` are official Lua, MIT licensed, with their
copyright notice intact. The placeholder reader in `stub/` is original to this kit.
