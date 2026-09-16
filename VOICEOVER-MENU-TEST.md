# VoiceOver menu test

This candidate adds custom touch gestures to RetroArch's Ozone menu while
VoiceOver remains on. Install it as an update to RetroArch Access using AltStore.
The app identifier, the two Pokemon accessibility cores, and the native speech
queue/stop and selected-VoiceOver-voice support are retained. Keep the previous
installer until the candidate has passed a physical-phone test.

With Ozone and VoiceOver enabled:

- Swipe up/down with one finger to browse categories. Right enters the category.
- Within a category or submenu, up/down browses items and right opens submenus.
- Left returns to the previous menu, then to categories.
- Double-tap activates the selected item, including toggles and Save Current Configuration.
- Two-finger left/right changes an adjustable value. Double-tap uses the normal
  setting editor when one is available.
- A single tap repeats the selection. Long-press reads the entry help and gestures.
- Native accessibility actions provide the same navigation and help commands.

Start by opening Main Menu, then Configuration File, and return with a left flick.
Check that each flick advances once and that right does not trigger a save.
Then change a harmless setting and double-tap Save Current Configuration. Reopen
the app to check persistence. Check a native keyboard/dialog, an empty directory,
the controller, and a Pokemon game after returning from the menu.

The custom region uses Apple's Direct Touch API. On iOS 17 and newer it requests
silent touch passthrough, letting RetroArch provide speech. Older supported iOS
versions may add VoiceOver's own direct-touch announcement. Actual gesture delivery
and speech require testing with VoiceOver on a physical phone. A successful CI
build verifies compilation, routing tests and packaging, not that physical test.

Sighted touchscreen use and gameplay touch/controller input keep the normal paths.
The gesture surface is hidden when VoiceOver is off, during gameplay, and while a
native modal or keyboard is active. This candidate is a personal test build, not
an upstream submission.
