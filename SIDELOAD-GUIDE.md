# Installing the iPhone test build

You will end up with a second RetroArch on the phone, called **RetroArch Access**, that does not
touch the one from the App Store. Its saves, settings and cores are completely separate, because
iOS keeps each app's files in a container keyed to its bundle identifier and this build has its own.

> **This is an untested iPhone build.** A successful Mac build checks compilation, packaging and
> signatures; launch, speech and gameplay still need testing on the phone.

## What you need

* an iPhone, and a computer running AltServer
* AltStore, signed in with your free Apple account — which you have
* the `.ipa` from the build
* the real `pokemon_bw_reader.lua` (it is **not** in the build; see below)
* your own Pokémon Black or White ROM file

## What a free Apple account means

These are Apple's limits, not this build's:

* **the app stops working after 7 days** unless AltStore refreshes it. Refreshing renews the
  app's signing and keeps your data.
* **three sideloaded apps at once**, and ten new App IDs per seven days. This build deliberately
  ships without its widget extension so it only uses one of them.
* the first launch needs you to trust the certificate, once. AltStore tells you when.

AltStore's own screens are the authority on refreshing; if what it says differs from this page,
believe AltStore.

## 1. Install the app

In AltStore, open **My Apps**, select the **Add (+)** button, then browse to the `.ipa` in Files
and select it. Keep AltServer running on the computer while installation completes. Then, if
iOS asks you to trust the developer:

> Settings → General → VPN & Device Management → your Apple ID → **Trust**

Open **RetroArch Access** once and close it again. That first launch is what creates the folders
you are about to copy files into. If you copy files before it, the folders will not be there.

## 2. Copy the files in

Open the **Files** app → **On My iPhone** → **RetroArch Access**. You will see a `RetroArch`
folder. Put these in it — create any folder that is missing, and match the names exactly, including
spaces and capitals:

| Copy this | To here |
| --- | --- |
| `pokemon_bw_reader.lua` | `RetroArch/system/melondsds_access/pokemon_bw_reader.lua` |
| `melonDS DS.opt` | `RetroArch/config/melonDS DS/melonDS DS.opt` |
| your ROM | anywhere under `RetroArch`, e.g. `RetroArch/roms/` |

You do **not** need to copy a `melondsds_libretro.info` anywhere. It is built into the app and
unpacked on first launch, which is what makes the core show up as "melonDS DS" in the menu rather
than as a filename.

**`system/melondsds_access/` is the important one.** It is where the core looks for the reader
before falling back to the placeholder built into it. If the reader is missing or in the wrong
folder, the core will not fail quietly — when you start the game it says:

> "Accessibility reader stopped. The Pokémon reader script is not included in this build. Copy
> pokemon_bw_reader.lua into the melondsds_access folder inside RetroArch's system folder, then
> reload the game."

If you hear that, the file is not where the core is looking. Check the folder name — it is
`melondsds_access`, one word, all lower case, and it goes inside `system`.

You do not need a BIOS or firmware dump. The core options file sets melonDS's built-in firmware.

## 3. Turn on speech

In RetroArch Access:

> Settings → Accessibility → **Enable Accessibility** → ON
> Settings → Accessibility → **Narrator Speech Speed** → 5

(1 is slowest, 10 fastest; 5 is the default.) If VoiceOver is already running, RetroArch turns
accessibility on by itself — but set it explicitly anyway, so it does not change depending on
whether VoiceOver happens to be on.

This is RetroArch's own narrator, speaking through Apple's built-in speech API. Nothing extra to
install.

## 4. Start the game

> Main Menu → **Load Core** → **melonDS DS**
> Main Menu → **Load Content** → find your ROM

Load the core first and the content second. The reader starts a moment after the game does and
introduces itself; if it does not say anything at all, see below.

## If something is wrong

**"Accessibility reader stopped…"** — the reader file is not in
`RetroArch/system/melondsds_access/`. Fix the path and reload the game from the menu.

**No speech at all** — check Settings → Accessibility → Enable Accessibility is ON. If RetroArch's
menu itself does not speak either, the problem is the narrator, not the core. If the menu speaks
but the game does not, check that `melonds_access_speech` is `frontend` in the core options file
and that `melonds_access_reader` is `enabled`.

**It says the reader needs the Nintendo DS memory layout** — the console is in DSi mode. Set the
core's Console Mode option to DS and reload. The `melonDS DS.opt` file already does this; if you
see it, that file did not land where RetroArch could read it.

**"Layout 1 of 2" over and over** — `melonds_show_current_layout` is still enabled. The core
rebuilds that status line every frame. The supplied `melonDS DS.opt` sets it to `disabled`; you can
also turn it off in Quick Menu → Options → Show Screen Layout.

**The app will not open after a week** — that is the 7-day free-account limit. Refresh it in
AltStore. Your saves stay.

**The app was replaced / my App Store RetroArch is gone** — it should not be: this build has its own
bundle identifier. If it did happen, the `.ipa` was built without the identifier override, and the
build should be redone rather than worked around.

## What this build will not do

* It does not include the reader script, a ROM, a save, or any BIOS file.
* It does not use JIT, so DS emulation runs on the interpreter and is slower than on a computer.
* It is software-rendered: there is no OpenGL renderer on iOS here.
* Controls and menus are stock RetroArch for iOS. Nothing about them was redesigned.
