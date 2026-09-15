# Prepared configuration

Two settings live in RetroArch's own config, and the rest are core options. They go to different
places on iOS, and only one of those places is reachable through the Files app.

There is one core options file per core: `melonDS DS.opt` for the DS core and `VBA-M.opt` for the
VBA-M core. The two cores are independent — neither reads the other's options, and turning one on
does nothing to the other.

## Core options — `melonDS DS.opt` (copy this one)

Copy `melonDS DS.opt` to, on the phone:

```
On My iPhone / <the app> / RetroArch / config / melonDS DS / melonDS DS.opt
```

Create the `melonDS DS` folder if it is not there. The folder name must match the core's name
exactly, including the space and the capitals. RetroArch writes this same file itself when you
change a core option in the menu, so it is safe to edit and safe to let RetroArch overwrite.

| Key | Value | Why |
| --- | --- | --- |
| `melonds_access_reader` | `enabled` | runs the Pokemon reader |
| `melonds_access_speech` | `frontend` | speaks through RetroArch's own accessibility, which on iOS is `AVSpeechSynthesizer`. The other values are `prism` (Windows only, needs `prism.dll`) and `log` (silent) |
| `melonds_access_controller_layer` | `enabled` | the reader's controller commands |
| `melonds_access_keyboard` | `enabled` | the reader's keyboard hotkeys |
| `melonds_access_l3_role` | `accessibility` | L3 drives the reader rather than the microphone |
| `melonds_show_current_layout` | **`disabled`** | **this is the "Layout 1/2" one.** The core rebuilds that on-screen status line every single frame; leaving it on is what floods speech. It is the only producer of that string in the core |
| `melonds_console_mode` | `ds` | the reader's address model was only ever validated against the DS 4 MiB layout. In DSi mode the core refuses to start it and says so |
| `melonds_boot_mode` | `direct` | boot straight into the game |
| `melonds_sysfile_mode` | `builtin` | use melonDS's built-in firmware, so no BIOS dump is needed |

## Core options — `VBA-M.opt` (copy this one too)

Copy `VBA-M.opt` to, on the phone:

```
On My iPhone / <the app> / RetroArch / config / VBA-M / VBA-M.opt
```

Create the `VBA-M` folder if it is not there. The name has to match the core's name exactly,
including the hyphen and the capitals.

| Key | Value | Why |
| --- | --- | --- |
| `vbam_access_reader` | `enabled` | runs the Pokemon reader inside the VBA-M core. It is `disabled` by default, so the core behaves exactly like stock VBA-M until this is set |

That is the only option this core's adapter adds. Everything else under VBA-M is stock and can be
left alone.

The reader files themselves are **not** in this repository and are not in the build. The core looks
for them at runtime in:

```
On My iPhone / <the app> / RetroArch / system / vbam_access
```

With the option enabled and that folder missing, the core **speaks** the reason and carries on as an
ordinary emulator rather than failing silently — a core that starts silently is indistinguishable
from a screen reader that has stopped.

Speech goes through RetroArch's own accessibility, the same path the DS core uses — there is no
separate speech setting for this core, so the two menu settings below cover both.

## RetroArch's own accessibility — set these in the menu

`accessibility_enable` and `accessibility_narrator_speech_speed` live in `retroarch.cfg`, and on
iOS that file is **not** under Documents. `open_default_config_file()` takes the
`!defined(RARCH_CONSOLE)` branch for iOS, which resolves to `~/.config/retroarch/retroarch.cfg`
inside the app's sandbox container — the Files app cannot see it. So set them in the UI:

> Settings → Accessibility → **Enable Accessibility** = ON
> Settings → Accessibility → **Narrator Speech Speed** = 5 (1 slowest … 10 fastest)

RetroArch also turns accessibility on by itself when VoiceOver is running: `config_set_defaults()`
has an `#if __APPLE__` branch that seeds `accessibility_enable` from `RAIsVoiceOverRunning()`. That
is a default, so an explicit setting still wins — but it does mean behaviour changes with VoiceOver
on or off, which is worth knowing when something sounds different than expected.

`retroarch.cfg.reference` in this folder lists the same two keys for reference. Do **not** copy a
Windows `retroarch.cfg` onto the phone: its paths, drivers and input bindings are all wrong for iOS
and would break the install.
