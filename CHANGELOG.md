# Changelog

## 0.4.0 — 2026-10-17

- Pairing no longer fails with "No GATT Proxy Node is connected" or stalls on "Reading composition…": VegaBar waits for the light to identify itself as a proxy, creates the Mac's own mesh models, and times out a configuration step that gets no usable answer.
- Lights are named like the phone app names them ("MOLUS G60_8723" rather than the Bluetooth name "PL103_8723"). A light you renamed keeps your name.
- The menu popover resizes with its content instead of clipping it.
- About window (from the menu, or `vegabar://about`) with the version and the licenses of the bundled open source libraries; `ACKNOWLEDGMENTS.md` and `LICENSE` now ship inside the app.
- Installing the command-line tool no longer assumes Homebrew. It reads your shell's PATH and uses Homebrew's folder, `~/.local/bin` or `~/bin` when they're there, or `/usr/local/bin` with a password prompt on a Mac without them. It updates an existing link in place and won't install from a copy of the app that macOS is running from a temporary location.
- The CLI finds VegaBar.app from its real path, not argv[0], and launches it with NSWorkspace.
- The menu's Rename item now reads "Rename in VegaBar…": the light has no command to store a name, so the name is VegaBar's only.
- Homebrew: the cask's caveats no longer suggest `--no-quarantine`, which Homebrew has removed.
- Mac App Store build: a sandboxed AppStore configuration (`./build-appstore.sh`), with the control socket in a shared App Group container, pairing data migrated into the sandbox, a privacy manifest, and a copyable command in place of the CLI installer. See APPSTORE.md.

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
