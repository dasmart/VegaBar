# Submitting VegaBar to the Mac App Store

The code is ready for the Mac App Store: a separate **AppStore** build configuration produces a sandboxed app that follows App Review guideline 2.4.5. What's left needs an Apple Developer account and App Store Connect, so it's yours to do. This page lists every step.

## How the App Store build differs

| | Direct download and Homebrew | Mac App Store |
|---|---|---|
| Build | `./build-app.sh` (configuration Release) | `./build-appstore.sh` (configuration AppStore) |
| App Sandbox | Off | On |
| Entitlements | None | Sandbox, Bluetooth, camera (in-use check only), App Group |
| Command-line tool | One-click install into a folder on the user's PATH | Bundled and sandboxed. Settings shows a command the user runs once. |
| Control socket | `~/Library/Application Support/VegaBar/control.sock` | The App Group container `<TEAMID>.org.dasmart.vegabar` |
| Pairing data | `~/Library/Application Support/VegaBar` | The app's container. On first launch macOS **moves** an existing folder there (`container-migration.plist`). |

Things to know before submitting:

- **Switching moves the pairing.** When someone who used the direct download first opens the App Store version, macOS moves their pairing folder into the sandbox. Their lights stay paired in the App Store version, and the old copy of the app then starts with no lights. Tell them to delete the old copy.
- **Test sandbox changes with `./build-appstore.sh --local`.** It builds the sandboxed app ad-hoc under its own bundle id, `org.dasmart.vegabar.sandboxtest`. Never run a sandboxed build with the real bundle id on a Mac before installing the App Store version: macOS migrates data only when it first creates the container.
- **The camera entitlement** exists because, inside the sandbox, CoreMediaIO lists no cameras without it, so "turn on when a camera is in use" would never fire. VegaBar only asks whether a camera is running. It never opens one, and macOS shows no camera prompt.

## One-time setup

1. **Join the Apple Developer Program** (99 USD a year). The nonprofit fee waiver applies only to organisations; see the earlier notes.
2. **Set your team.** Find the 10-character Team ID in the developer account's Membership page, then create `Configs/Team.xcconfig`. The file is git-ignored.

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```

3. **Register the bundle id** `org.dasmart.vegabar` in Certificates, Identifiers & Profiles with the App Groups capability. Add the group `<TEAMID>.org.dasmart.vegabar`. Register `org.dasmart.vegabar.cli` too, with the same group. Automatic signing (`-allowProvisioningUpdates`) can create these for you the first time you archive.
4. **Create the app in App Store Connect:** platform macOS, bundle id `org.dasmart.vegabar`, SKU `vegabar`, primary language English.

## Each submission

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`. App Store Connect rejects a build number it has seen before.
2. Archive and export:

   ```bash
   ./build-appstore.sh
   ```

   This writes `build/AppStore/VegaBar.pkg`.
3. Upload the package with **Transporter**, or open the archive in Xcode's Organizer and choose **Distribute App**. Fix anything validation reports before submitting.
4. In App Store Connect, attach the build to a new version, fill in the listing below, and submit for review.

## App Store Connect listing

| Field | Suggested value |
|---|---|
| Name | VegaBar |
| Subtitle | Control Zhiyun lights from the menu bar |
| Category | Utilities. Productivity is a reasonable secondary. |
| Price | Your choice. Free fits the open-source licence. |
| Age rating | 4+, with no objectionable content |
| Privacy policy URL | The GitHub URL of [PRIVACY.md](PRIVACY.md) |
| Support URL | The repository's Issues page |
| App Privacy | **Data Not Collected**. VegaBar makes no network connections. |
| Screenshots | At least one at 1280×800, 1440×900, 2560×1600 or 2880×1800. The menu and the Settings window work well. `docs/images/menu.png` is a start but must be placed on a full-size canvas. |

**Export compliance** is your decision. Bluetooth Mesh pairing uses standard encryption (AES-CCM, ECDH) through the nRF Mesh Library and CryptoSwift, only to talk to the user's own light. App Store Connect asks about this at upload. If you conclude it is exempt, you can add `ITSAppUsesNonExemptEncryption = NO` to the Info.plist properties in `project.yml` so it stops asking. Check Apple's export compliance guidance rather than relying on this note.

**Trademarks:** the description may say the app works with Zhiyun lights. Don't use Zhiyun's logo or product images, and keep the "not affiliated with or endorsed by Zhiyun" line from the README.

## Notes for App Review

App Review can't pair a light they don't have, so give them a way to see the app work. Paste the following into **App Review Information › Notes**, with a link to a short screen recording that shows pairing and the controls.

> VegaBar controls Zhiyun bi-colour Bluetooth lights (tested with the Zhiyun Molus G60) from the menu bar. Without one of these lights, the menu shows "No lights paired" and pairing finds nothing. This video shows pairing and control on real hardware: <link>.
>
> Entitlements:
> - Bluetooth: to pair with and control the light.
> - Camera: only to ask CoreMediaIO whether any camera is in use, for the optional "turn the light on during calls" automation. The app never opens a camera, captures frames, or shows a camera permission prompt. Inside the sandbox, CoreMediaIO lists no cameras without this entitlement.
> - App Group: a Unix socket in the group container lets the bundled `vegabar` command-line tool (Contents/Helpers/vegabar) talk to the running app. The app installs nothing outside its bundle. Settings shows users a command they can run themselves if they want the tool on their PATH.
>
> The app makes no network connections and collects no data. It is open source: <repository link>.

## Scripting without the command-line tool

Both of these work in every build with nothing installed, so mention them in the description or support page:

```bash
open -g vegabar://brightness/40
```

```bash
shortcuts run "Light On"
```

The second one needs a shortcut, here named "Light On", built once in the Shortcuts app from VegaBar's actions.
