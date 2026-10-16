# VegaBar

A native macOS menubar controller for Zhiyun's Bluetooth lights (the ones the ZY Vega phone app controls), written entirely in Swift. Tested with a Zhiyun Molus 60 (which advertises itself as `PL103`); other CCT-only Zhiyun lights that pair over Bluetooth Mesh should work the same way.

VegaBar is an independent project and is not affiliated with or endorsed by Zhiyun. The protocol was reverse-engineered from the behaviour of the official app; VegaBar contains no Zhiyun code.

## Install

Requires macOS 14 or later. Apple silicon and Intel.

**Download:** grab `VegaBar.zip` from the [latest release](../../releases/latest), unzip, and move `VegaBar.app` to Applications.

Releases are not yet notarized, so macOS will refuse to open the app the first time:
1. Double-click VegaBar. macOS says it can't verify the app. Click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the VegaBar message.
3. Confirm, and allow Bluetooth access when asked.

(Or, from Terminal: `xattr -d com.apple.quarantine /Applications/VegaBar.app`.) If you'd rather not do this, build it yourself; a locally built app needs none of it.

**Homebrew:**

```bash
brew install --cask dasmart/tap/vegabar
```

**Build from source:**

```bash
brew install xcodegen          # once
./build-app.sh && open build/VegaBar.app
```

## Build & test

```bash
./build-app.sh                 # universal Release build into build/
./test.sh                      # unit tests
```

`build-app.sh` generates `VegaBar.xcodeproj` from `project.yml` and builds a Release app into `build/`. `test.sh` runs the XCTest suite (protocol encoder/parser, safety rules, URL parsing, schedule maths, storage and settings migration). To work in Xcode, run `xcodegen generate` and open the project. The first launch asks for Bluetooth permission.

## Using it

- **Menubar icon:**
  - Click for the controls: power, brightness, colour temperature, presets and lights.
  - **⌥-click** or **right-click** toggles power.
  - **Scroll** over the icon to dim or brighten.
- **⚙ (or ⌘,)** opens Preferences:
  - **General:** launch at login, rename lights, install the CLI, log.
  - **Automation:** turn on with the camera, turn off on sleep/lock, time-of-day colour temperature.
  - **Hotkeys:** record global shortcuts for power, brightness up/down, warmer/cooler, and set the step sizes.
  - **Presets:** edit, apply and delete presets, or add one from the light's current state.

### Command line

Preferences › General › **Install Command-Line Tool** symlinks `vegabar` onto your PATH. It talks to the running app, launching it if needed:

```text
vegabar status [--json]       vegabar on | off | toggle
vegabar brightness 40         vegabar brightness +10
vegabar cct 5600              vegabar cct -300
vegabar preset Call           vegabar presets
vegabar identify
```

Exit status is 0 on success, so it works in scripts, Stream Deck, Raycast and cron.

### Shortcuts & URLs

Shortcuts lists VegaBar's actions:
- **Turn Light On or Off**
- **Set / Adjust Light Brightness**
- **Set Light Color Temperature**
- **Apply Light Preset**
- **Get Light Status**
- **Get Light Brightness / Color Temperature**
- **Is Light On**

They also work with Siri and Spotlight.

URLs work from anywhere: `vegabar://on`, `vegabar://off`, `vegabar://toggle`, `vegabar://brightness/40`, `vegabar://brightness/+10`, `vegabar://cct/5600`, `vegabar://preset/Call`.

## Light safety

Every frame passes through `LightSafety` immediately before it's written over Bluetooth, whatever its source (UI, hotkey, CLI, Shortcuts, URL, automation):

- **Allowed commands only:** power, brightness, colour temperature, reads, identify, register, unpair. Overdrive ("max mode"), firmware update, factory test, effects and RGB can't be sent at all.
- **Value checks:** brightness must be 0–100 % and finite, colour temperature 2700–6500 K, power 0 or 1, and the target must be a real device id. The encoder clamps values first, and anything else is rejected and logged.
- **Integrity checks:** header, length and CRC are re-verified.
- **Rate limits:** at most 20 frames per second and 32 queued frames, with the newest value winning when changes pile up. Brightness and color writes are spaced at least 0.1 s apart (no strobing faster than 10 Hz), power at least 1 s apart, and identify, register and unpair at least 2 s apart. Reads are never delayed.
- **Unpair confirmation:** unpairing always asks first, and says so when the light can't be reached and will need a factory reset.
- **Corrupt pairing file:** if `MeshNetwork.json` can't be read, VegaBar keeps it as `MeshNetwork.corrupt-<time>.json` and tells you, rather than silently replacing it.

## How it works

- **Pairing** uses Bluetooth Mesh, with the Mac as provisioner (via [Nordic's nRF Mesh library](https://github.com/NordicSemiconductor/IOS-nRF-Mesh-Library)). The steps copy the ZY Vega Android app:
  1. Provision the light.
  2. Send the network configuration.
  3. Register a ZY device id (0x8000 and up).
- **Control** writes plain ZY frames to the light's vendor GATT service (`FEE9`). See [PROTOCOL.md](PROTOCOL.md), including the corrections verified on hardware.
- **Data**, all in `~/Library/Application Support/VegaBar/` (owner-only, 0700):
  - `MeshNetwork.json`: the mesh network (keys and nodes), written by the nRF library. Back this folder up: without it a light must be factory-reset to pair again.
  - `lights.json`: VegaBar's own record of each light (its ZY device id).
  - `control.sock`: the CLI socket (0600).
  - Settings and presets are in `UserDefaults`. They were migrated once from the old bundle id, `org.smartfamilyfund.vegabar`.
- **Logging:** events go to the unified log (Console.app, subsystem `org.dasmart.vegabar`). Raw Bluetooth frames are only written to `~/Library/Logs/VegaBar.log` when "Log Bluetooth frames to a file" is on in Preferences › General; that file is capped at 2 MB.
- **Energy:** nothing polls. Camera use comes from CoreMediaIO property listeners (plus a 30 s safety check), sleep/lock from system notifications, and the color schedule from a once-a-minute timer with tolerance.

| File | Purpose |
|---|---|
| `ZYProtocol.swift` | Frame encoder/parser |
| `LightSafety.swift` | Allow-list, value limits and rate limits for everything sent |
| `ZYLink.swift` | CoreBluetooth link, coalescing queue, reconnect |
| `MeshController.swift` | Mesh network, provisioning, configuration |
| `AppModel.swift`, `Commands.swift` | State and the shared command layer |
| `Intents.swift` | Shortcuts / Siri actions |
| `ControlServer.swift`, `vegabar-cli/` | CLI and its Network.framework socket server |
| `LightStore.swift`, `SettingsMigration.swift` | Per-light records; one-time settings migration |
| `Log.swift` | Unified logging and the optional frame trace file |
| `Tests/` | XCTest suite |
| `Automations.swift` | Camera, sleep/lock, colour schedule, login item |
| `Hotkeys.swift` | Global shortcuts and recorder |
| `StatusItemController.swift`, `MenuView.swift`, `SettingsView.swift` | UI |

## Design notes

- **Singletons as composition root:** `AppModel.shared`, `Preferences.shared`, `Automations.shared` and `Hotkeys.shared` are the app's instances, but every initializer takes its collaborators, so tests build isolated objects with temporary stores and defaults.
- **Strict concurrency** checking is on (`SWIFT_STRICT_CONCURRENCY = complete`) and the app builds without warnings. CoreBluetooth and NordicMesh are imported `@preconcurrency`; their callbacks arrive on the main queue, which the `@preconcurrency` conformances verify at runtime.
- **Not sandboxed, not notarized (yet).** The CLI socket and the symlink installer don't fit App Sandbox. Release builds are ad-hoc signed with the hardened runtime; the release workflow signs and notarizes automatically once Developer ID secrets are configured (see `.github/workflows/release.yml`).
- **Privacy:** VegaBar makes no network connections of any kind and collects nothing. Bluetooth is used only to talk to your lights.
- **Mesh keys are files, not Keychain items.** With ad-hoc signing every rebuild is a "new" app to the Keychain, which would prompt or lose access on each build. The files are 0600 inside a 0700 folder instead.

## Tips

- **Bluetooth stuck:** if VegaBar stops connecting after being force-quit mid-connection, turn Bluetooth off and on.
- **Battery:** the PL103 reports battery as "unknown" (101), so no battery level is shown. Lights that report one show it in the menu.
- **Multiple lights:** the protocol supports groups, but VegaBar is single-light for now; there was no second light to test with.

## Releasing

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `project.yml` and add a section to `CHANGELOG.md`.
2. Tag and push: `git tag v0.3.0 && git push --tags`.
3. The release workflow builds a universal app, signs it as one unit (Developer ID and notarization if the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` and `NOTARY_KEY` are set; ad-hoc otherwise), zips it and attaches it to a GitHub Release, and prints the SHA-256 for the Homebrew cask in `homebrew/vegabar.rb`.

## Contributing

Issues and pull requests are welcome. Run `./test.sh` before opening a PR; the CI workflow runs the same build and tests. If you have a different Zhiyun light, a log from Preferences › General › "Log Bluetooth frames to a file" is the most useful thing you can attach to an issue.
