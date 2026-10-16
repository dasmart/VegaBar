# Changelog

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
