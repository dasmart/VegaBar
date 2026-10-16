# Changelog

## Unreleased

- About window (from the menu, or `vegabar://about`) with the version and the licenses of the bundled open source libraries; `ACKNOWLEDGMENTS.md` and `LICENSE` now ship inside the app.
- Homebrew: the cask's caveats no longer suggest `--no-quarantine`, which Homebrew has removed.
- Pairing no longer fails with "No GATT Proxy Node is connected" or stalls on "Reading composition…": VegaBar waits for the light to identify itself as a proxy, creates the Mac's own mesh models, and times out a configuration step that gets no usable answer.
- Lights are named like the phone app names them ("MOLUS G60_8723" rather than the Bluetooth name "PL103_8723"). A light you renamed keeps your name.
- The menu's Rename item now reads "Rename in VegaBar…": the light has no command to store a name, so the name is VegaBar's only.

## 0.3.0 — 2026-10-16

First public release.

- Menubar controls: power, brightness, color temperature, presets; scroll the icon to dim, ⌥-click to toggle.
- Pairing over Bluetooth Mesh; the Mac is the provisioner.
- Automations: turn on when a camera is in use, off when the Mac sleeps or locks, optional time-of-day color temperature.
- Global hotkeys, launch at login.
- Shortcuts actions, `vegabar://` URLs, and a `vegabar` command-line tool.
- Safety layer: every frame is allow-listed, range-checked and rate-limited before it reaches the light.
- Unified logging; optional bounded frame-trace file for protocol debugging.
- Universal binary (Apple silicon and Intel), macOS 14 or later.
