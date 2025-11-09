# /!\ DISCLAIMER /!\

This project is not affiliated with Apple Inc. or any other company.

The vast majority of this project was made using AI, I only provided the logic of the app but the code was not written by me but by AI. I'm not interested in learning Swift. This project was made to satisfy my OCD and to provide a simple and lightweight solution for extracting a color palette from your current wallpaper. Be aware that the agent requires some permissions to access your wallpaper and I will not be held responsible for any damages caused by this project.

Lastly, I will probably continue to improve this project on my free time, if you have any suggestions or feedback, feel free to open an issue or submit a pull request. I will look into them and add them if they are relevant/interesting for me or regarding the project's evolution.

I hope this project will suit your ricing needs and have fun with it!

# WallpaperPalette

WallpaperPalette is a lightweight macOS menu bar utility that extracts a color palette from your current wallpaper and exposes a small set of configurable options via a status bar menu. The project is self-contained and includes simple scripts to build a standalone `.app` bundle and to install/uninstall it on your system.

---

## Project layout

- `sources/` — Swift source files (app logic, status bar controller, etc.).
- `scripts/` — helper scripts:
  - `build_app.sh` — builds a standalone `.app` in `dist/` and optionally packages as `.zip` / `.dmg`. This script only builds and packages the app; it does not install or enable launch-at-login.
  - `install.sh` — installs the built `.app` to a target directory (e.g. `/Applications`) and can enable a per-user LaunchAgent (launch at login).
  - `uninstall.sh` — removes a previously installed app and its LaunchAgent.
- `dist/` — build artifacts (created by `build_app.sh`).
- `build/` — temporary build files.

---

## Prerequisites

For ghostty, make sure your ghossty config file is at the root of your home directory.

```sh
~/.config/ghossty/config
```

Be careful you can add everything you want to your config file but make sure to not have anything related to the color palette as this make break your config file with the app running in the background. When enabled, ghossty synchronzation will add the color palette at the end of the config file.

To build and package on macOS you should have:

- Xcode Command Line Tools (provides `swiftc`, `clang` tooling).
- `swiftc` available on your `PATH`.
- `xcrun` is optional but recommended (used by the build script for SDK discovery).
- For universal builds: `lipo`.
- Packaging tools which are available on macOS:
  - `ditto` (for creating `.zip`)
  - `hdiutil` (for creating `.dmg`)
  - `sips` and `iconutil` (for generating/processing icons)
- `codesign` is optional — the build script performs an ad-hoc code sign if available.

Minimum supported macOS (runtime) depends on `DEPLOYMENT_TARGET` in the build script (default: macOS 12.0).

---

## Build

The repository contains a minimal build script that compiles the Swift sources into a standalone `.app` bundle without Xcode.

Basic build:

```sh
./scripts/build_app.sh
```

This will create `dist/WallpaperPalette.app` and (by default) a `.zip` and `.dmg` in `dist/`.

Common environment variables you can set to customize the build:

- `APP_NAME` — app display name (default: `WallpaperPalette`)
- `BUNDLE_ID` — bundle identifier (default: `com.example.WallpaperPalette`)
- `VERSION` — version string (defaults to `git describe` if available, else `1.0.0`)
- `BUILD_NUMBER` — build number (defaults to timestamp)
- `DEPLOYMENT_TARGET` — macOS deployment target (default: `12.0`)
- `UNIVERSAL=1` — build a universal binary (arm64 + x86_64) — requires `lipo`
- `PACKAGE_ZIP=0|1` — whether to create a `.zip` artifact (default: `1`)
- `PACKAGE_DMG=0|1` — whether to create a `.dmg` artifact (default: `1`)
- `ZIP_NAME`, `DMG_NAME`, `DMG_VOLNAME` — artifact names

Examples:

- Build a simple artifact:

  ```sh
  ./scripts/build_app.sh
  ```

- Build a universal binary and only produce a ZIP:

  ```sh
  UNIVERSAL=1 PACKAGE_DMG=0 ./scripts/build_app.sh
  ```

- Override app name and bundle id:

Notes:
- The build script can create a placeholder icon if none is provided. If you have a custom `.icns`, place it at `sources/WallpaperPalette.icns` or at the repository root `WallpaperPalette.icns` and the script will copy it into the bundle.
- The build script intentionally only builds and packages the app. Installation and enabling launch-at-login are handled by `scripts/install.sh`.

---

## Install

Use `scripts/install.sh` to copy the built `.app` into a system or user applications folder, optionally enable launch at login (user-level LaunchAgent), and optionally open the app after installation.

Basic install (system `/Applications`):

```sh
# May prompt for sudo if writing to /Applications
./scripts/install.sh --app dist/WallpaperPalette.app
```

Install to the current user's `~/Applications`:

```sh
./scripts/install.sh --app dist/WallpaperPalette.app --user
```

Enable launch at login and open the app after installing:

```sh
./scripts/install.sh --app dist/WallpaperPalette.app --login --open
```

Common flags:

- `--app PATH` — path to the source `.app` bundle (defaults to `dist/WallpaperPalette.app` if present)
- `--dir PATH` — install destination directory (default `/Applications`)
- `--user` — install to `~/Applications` (same as `--dir "$HOME/Applications"`)
- `--login` — enable launch at login (writes a `~/Library/LaunchAgents/*.plist` and loads it)
- `--no-login` — explicitly disable launch at login
- `--open` — open the app after installation
- `-f`, `--force` — overwrite existing app at target without prompting
- `-y`, `--yes` — assume yes to prompts
- `--label` — custom LaunchAgent label
- `--bundle-id` — override the bundle identifier used when installing
- `--name` — override the display name used for the installed `.app`

To uninstall, use the included `scripts/uninstall.sh` script which will remove the app and unload/remove the LaunchAgent.

---

## Configuration & Settings

The app persists settings in `UserDefaults`. The status menu exposes common settings such as:

- Polling interval
- Sampling limits / quality parameters
- Brightness delta
- Notifications
- Launch-at-login preference (this preference is independent from the installer — installer writes the LaunchAgent; the preference is stored for the app's own settings view)

Numerical controls visible in the status menu show brief help and min/max via hover tooltips (the info "?" affordance is hover-only).

If you want to change defaults programmatically in a local dev environment, you can set `UserDefaults` keys used by the app. See the source (e.g. `Config` usage in the Swift sources) for the exact keys.

---

## Usage

- Once installed and running, the app places an icon in the system status bar.
- Click the status icon to open the menu and view the palette preview and settings.
- Use the numeric fields to adjust values; values are clamped to configured min/max and snapped to the configured step size.
- To force a recompute of the palette, choose "Recompute Now" from the menu.
- To have the app start at login automatically, run the installer with `--login` or enable the preference in the menu; the installer writes and loads a user LaunchAgent.

Example workflow:

1. Build the .app:

   ```sh
   ./scripts/build_app.sh
   ```

2. Install to `/Applications` and enable launch-at-login:

   ```sh
   ./scripts/install.sh --app dist/WallpaperPalette.app --login --open
   ```

3. Adjust settings via the status bar menu.

4. If you want to access the generated palette, it is located in /tmp/wallpaper-palette/current-palette.json

---

## Development notes

- Sources are plain Swift and do not require Xcode — `swiftc` is used by the build script.
- The status menu is implemented manually with `NSMenu` and custom view-based `NSMenuItem`s.
- The info affordance for numeric inputs is hover-only (tooltip) by design to avoid modal alerts while interacting with the menu.

---

## Troubleshooting

- If `swiftc` is not found, install Xcode Command Line Tools: `xcode-select --install`.
- If packaging steps fail, make sure the macOS tools `ditto`, `hdiutil`, `sips`, and `iconutil` are available (they are part of macOS).
- If you run into permission issues when installing to `/Applications`, the installer will prompt to escalate with `sudo`.

---
