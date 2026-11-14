# BooxBridge

BooxBridge is a macOS app for Boox notebook users. It copies auto-exported notebook PDFs over USB into an offline library and transcribes page images with a provider you choose. Imports are one-way: BooxBridge does not delete, rename, or move files on the device during import.

## Install and run

BooxBridge requires **macOS 26.1 or newer**. The supported installation method is to build the app from source. There is no installer, Homebrew formula, or published release download.

You need Android platform-tools, which includes **adb**, the program that connects your Mac to the Boox. BooxBridge does not bundle or download adb.

Transcription requires a provider API key, which authorizes requests to your provider account. BooxBridge supports OpenAI, Anthropic, DeepInfra, Z.ai, and OpenAI-compatible endpoints. Provider requests can incur charges. Transcription sends page images to the selected provider. BooxBridge stores API keys in the macOS Keychain.

**Prepare your Mac and Boox**

1. Complete the toolchain installation in [Developer setup](#developer-setup).
2. Download the Mac version of [Android platform-tools](https://developer.android.com/tools/releases/platform-tools).
3. Extract the downloaded archive.
4. Copy this project's source folder to your Mac.
5. Enable USB debugging on the Boox.
6. Connect the Boox to your Mac with a USB cable.
7. Accept the USB debugging prompt on the Boox.
8. Enable PDF auto-export in the Boox Notes app.

The export folder is usually `/sdcard/note`. Use the folder selected in your Boox export settings if it differs.

**Start BooxBridge**

1. Open Terminal from Applications → Utilities in Finder.
2. Type `cd` followed by a space in Terminal.
3. Drag the project folder from Finder into Terminal.
4. Press Return.

The project folder contains `Package.swift`, `Makefile`, and `build.sh`. The `cd` command selects that folder for subsequent commands.

5. Run this command:

   ```sh
   make run
   ```

The command builds BooxBridge and opens its library window. Local runs do not require a signing account. If the command reports a missing prerequisite, resolve that error before you run it again.

**Import your first notebook**

1. Open Settings → Device Import in BooxBridge.
2. Click **Browse…** to select the `adb` executable inside your extracted `platform-tools` folder.
3. Click **Verify**.

A checkmark and the adb version confirm verification.

4. Enter your Boox export folder in **Device folder**.
5. Click **Enroll Current Device**.
6. Select **Sync Now**, or press Command-S.

Imported PDFs appear in the library. Automatic import also runs when the device connects, if you enable that option and leave BooxBridge open.

For transcription, configure a provider profile and model in Settings → Providers. **Test Connection** checks that combination with a synthetic image, not a notebook page.

To quit BooxBridge, press Command-Q.

## Developer setup

Install Xcode from the Mac App Store or the [Swift toolchain for macOS](https://swift.org/install/macos/). The project requires Swift 6.0 or newer and uses Swift 6 language mode. A toolchain supplies the compiler that builds the app from source.

Clone this repository or copy its source folder. Open Terminal in the folder that contains `Package.swift` and `Makefile`.

There is no Xcode project. `swift build` compiles the package. `./build.sh` compiles, bundles, and signs `build/BooxBridge.app`. The Makefile coordinates these steps. Swift Package Manager resolves the declared `swift-crypto` 3.x dependency. The core also uses the host SQLite library.

On macOS:

| Command | Purpose |
| --- | --- |
| `make check` | Compile without app bundling or signing. |
| `make test` | Run the full Swift Package Manager test suite, including macOS app-target tests. |
| `make run` | Build and open the app. |
| `make help` | List the build and release commands. |

On Linux, run `swift test` or `make test-core` to test the core. The package excludes app targets on Linux, so Linux cannot run BooxBridge. Do not use `make check` or `make test` on Linux. Their prerequisite check requires macOS. On macOS, `make test-core` runs the same suite as `make test`.

BooxBridge is non-sandboxed by design because it must start the user's own adb executable. Local builds use ad-hoc signing by default with hardened runtime enabled. Replace the development bundle identifier, `dev.booxbridge.app`, before distribution.

For maintainers, `make dist` builds a release package. It requires an exact `vX.Y.Z` Git tag, a Developer ID signing identity, and notarization credentials. Run `make help` for the release command list. This pipeline is not a user installation method.

Read the repository guidance before changes:

- [AGENTS.md](AGENTS.md): working agreements and verification requirements.
- [SWIFTUI-RULES.md](SWIFTUI-RULES.md): SwiftUI and concurrency rules.
