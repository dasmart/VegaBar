# VegaBar: development notes

Everything technical that doesn't belong in the [README](README.md): building, testing, how it works, where data lives, design decisions, releasing and contributing. The wire protocol has its own document, [PROTOCOL.md](PROTOCOL.md).

## Building and testing

```bash
brew install xcodegen          # once
./build-app.sh                 # Release build into build/
./build-appstore.sh --local    # sandboxed Mac App Store build, ad-hoc, for testing
./test.sh                      # unit tests
open build/VegaBar.app
```

`build-app.sh` generates `VegaBar.xcodeproj` from `project.yml`, builds an Apple silicon (arm64) Release app, signs the finished bundle as one unit and copies it to `build/`. Signing is ad-hoc unless `VEGABAR_SIGN_IDENTITY` names a certificate (a "Developer ID Application" or "Apple Development" identity, or its SHA-1 from `security find-identity -v -p codesigning`). `VEGABAR_ZIP=1` also produces `build/VegaBar.zip`.

`test.sh` runs the XCTest suite: protocol encoder and parser against reference frames and real replies, every `LightSafety` rule, URL parsing, the colour-schedule maths, storage and settings migration. The test host launches VegaBar in test mode, which skips Bluetooth, the control socket and hotkeys.

To work in Xcode, run `xcodegen generate` and open the project. If the package dependency shows a red ✕, Xcode's checkout was interrupted: **File › Packages › Reset Package Caches**.

Release builds are stripped and optimised for size (`-Osize`); the whole app is about 4.5 MB, of which the Nordic mesh library and its CryptoSwift dependency are most.

## How it works

### Pairing

Zhiyun's lights are Bluetooth Mesh nodes. VegaBar runs its own mesh network with the Mac as provisioner, using [Nordic's nRF Mesh library](https://github.com/NordicSemiconductor/IOS-nRF-Mesh-Library), and copies the sequence the ZY Vega Android app performs:

1. Identify and provision the light (No OOB).
2. Configure it: Composition Get, Default TTL Get, Network Transmit Set (2, 1), AppKey Add.
3. Reconnect over the vendor service and send the ZY `register` frame, which gives the light its ZY device id (0x8000 and up).

A light whose pairing was interrupted after step 1 reports device id 0x0000; VegaBar registers it on the next connection.

### Control

Day-to-day control doesn't go over the mesh. The Mac keeps a GATT connection to the light's vendor service (`FEE9`) and writes plain ZY frames to it — unencrypted, with a CRC. The light relays frames addressed to other device ids across the mesh (untested, since there was one light). The frame format, command ids and the corrections found on real hardware are in [PROTOCOL.md](PROTOCOL.md). The notable one: command 0x1008, which the SDK calls "sleep", is actually power enable (1 = on).

### Light safety

Every frame passes through `LightSafety` in `ZYLink.send`, immediately before it is written over Bluetooth, whatever its source (UI, hotkey, CLI, Shortcuts, URL, automation):

- **Allow-list:** power, brightness, colour temperature, their reads, identify, battery, register and unpair. Overdrive ("max mode"), firmware update, factory test, effects and RGB can't be sent at all.
- **Value checks:** brightness 0–100 % and finite, colour temperature 2700–6500 K, power 0 or 1, target a real device id. The encoder clamps first; anything that still fails is dropped and logged.
- **Integrity:** header, length and CRC are re-verified.
- **Rate limits:** at most 20 frames per second and 32 queued frames, with the newest value winning when changes pile up. Brightness and colour writes are at least 0.1 s apart (no strobing above 10 Hz), power at least 1 s apart, identify, register and unpair at least 2 s. Reads are never delayed.
- **Unpair** always confirms, and says so when the light can't be reached and will need a factory reset.
- **A pairing file that can't be read** is kept as `MeshNetwork.corrupt-<time>.json` and reported, never silently replaced.

### Data

All in `~/Library/Application Support/VegaBar/` (mode 0700, files 0600). In the Mac App Store build, that folder is inside the app's container, `~/Library/Containers/org.dasmart.vegabar/Data/`, and the socket is in the App Group container.

| File | Contents |
|---|---|
| `MeshNetwork.json` | The mesh network: keys, nodes, addresses. Written by the nRF library. Losing it means factory-resetting the light. |
| `lights.json` | VegaBar's record of each light (its ZY device id). |
| `control.sock` | The CLI socket. |

Settings and presets are in `UserDefaults` under `org.dasmart.vegabar` (migrated once from the earlier bundle id, `org.smartfamilyfund.vegabar`).

### Logging

Events go to the unified log: Console.app, subsystem `org.dasmart.vegabar`, categories `ble`, `mesh`, `pairing`, `control`, `automation`, `safety`, `hotkeys`, `storage`. Raw Bluetooth frames are written to `~/Library/Logs/VegaBar.log` only while "Log Bluetooth frames to a file" is on in Preferences › General; the file is capped at 2 MB with one older generation kept.

### Energy

Nothing polls. Camera use comes from CoreMediaIO property listeners (with a 30 s safety check), sleep and lock from system notifications, the colour schedule from a once-a-minute timer with a 20 s tolerance, and battery from a 60 s task with tolerance.

## Architecture

| File | Purpose |
|---|---|
| `ZYProtocol.swift` | Frame encoder and parser, CRC-16/XMODEM |
| `LightSafety.swift` | Allow-list, value limits and pacing for everything sent |
| `ZYLink.swift` | CoreBluetooth link, coalescing queue, reconnect |
| `MeshController.swift` | Mesh network, provisioning, configuration, storage |
| `AppModel.swift`, `Commands.swift` | State and the single command layer behind every entry point |
| `Intents.swift` | Shortcuts / Siri actions |
| `ControlServer.swift`, `vegabar-cli/` | The CLI and its Network.framework Unix-socket server |
| `URLCommand.swift` | `vegabar://` parsing |
| `Automations.swift` | Camera, sleep/lock, colour schedule, login item |
| `Hotkeys.swift` | Carbon global shortcuts and the recorder |
| `LightStore.swift`, `SettingsMigration.swift` | Per-light records; one-time settings migration |
| `Log.swift` | Unified logging and the optional frame trace file |
| `Main.swift`, `StatusItemController.swift` | AppKit entry point, menubar item, Settings window |
| `MenuView.swift`, `SettingsView.swift` | SwiftUI views |
| `Shared/ControlProtocol.swift` | Request/response types shared with the CLI |
| `Tests/` | XCTest suite |

### Design decisions

- **AppKit app, SwiftUI views.** The menubar item needs scroll-to-dim, ⌥-click and right-click, which SwiftUI's `MenuBarExtra` doesn't offer, so the entry point is `NSApplication` with an `NSStatusItem` and `NSPopover`. The Settings window is an `NSTabViewController` with toolbar-style tabs hosting SwiftUI panes.
- **One command layer.** The menu, hotkeys, Shortcuts, the CLI, URLs and automations all call the same `AppModel` methods, so they behave identically and are all covered by the same safety checks.
- **Singletons as the composition root.** `AppModel.shared` and friends are the app's instances, but every initializer takes its collaborators, so tests build isolated objects with temporary stores and defaults.
- **Strict concurrency** checking is on (`SWIFT_STRICT_CONCURRENCY = complete`) and the app builds without warnings. CoreBluetooth and NordicMesh are imported `@preconcurrency`; their callbacks arrive on the main queue, which the `@preconcurrency` conformances verify at runtime.
- **Two builds.** The direct download and Homebrew build (configuration Release) isn't sandboxed: it installs the CLI with one click and keeps the socket in Application Support. The Mac App Store build (configuration AppStore, `APP_STORE` compilation condition) is sandboxed: the installer is compiled out, the socket moves to the App Group container shared with the sandboxed CLI, and macOS migrates existing pairing data into the container. See [APPSTORE.md](APPSTORE.md).
- **Mesh keys are files, not Keychain items.** With ad-hoc signing every rebuild is a new app to the Keychain, which would prompt or lose access on each build. The files are 0600 inside a 0700 folder instead. Moving them to the Keychain becomes possible with a stable signing identity.
- **Why ask the light for its device id.** Device ids live in `lights.json`, separate from the nRF library's file. If the two ever disagree, the connected light reports its own id and VegaBar adopts it, or registers it afresh if it has none.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml` and add a section to `CHANGELOG.md`.
2. Tag and push: `git tag v0.3.0 && git push --tags`.
3. The release workflow builds the app, signs it, zips it and attaches it to a GitHub Release with the changelog section as notes, and prints the SHA-256 for the Homebrew cask (`homebrew/vegabar.rb`, which lives in the `dasmart/homebrew-tap` repository as `Casks/vegabar.rb`).

Signing and notarization happen automatically when these repository secrets exist; otherwise the build is ad-hoc signed and the release notes say so:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | base64 of the "Developer ID Application" certificate (.p12) |
| `DEVELOPER_ID_P12_PASSWORD` | its password |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key id and issuer id |
| `NOTARY_KEY` | base64 of the `AuthKey_XXXX.p8` file |

## Contributing

Issues and pull requests are welcome. Run `./test.sh` before opening a PR; the CI workflow runs the same build and tests on every push. If you have a different Zhiyun light, a frame log (Preferences › General › "Log Bluetooth frames to a file") is the most useful thing to attach to an issue. Please don't contribute anything derived from Zhiyun's own code; VegaBar is a clean implementation of the observed protocol.

## Screenshots

README images live in `docs/images/`. Capture windows with ⌘⇧4 then Space (Retina PNG with the window shadow), and reference them with an `<img width="…">` tag at half the pixel width so they display at 1x.

## Icon

The app icon is an original design, `Design/icon.svg`: a panel light with the warm-to-cool colour-temperature range over a slider. Render the asset catalog from it with any SVG rasteriser at 16–512 pt, 1x and 2x.
