# Megalith Widgets

A desktop widget for GitHub pull request reviews on Linux and macOS.
The Linux app uses Rust, GTK 4 and libadwaita; the macOS app uses SwiftUI
and AppKit.

It tracks review requests and new commits on pull requests you've already
reviewed, alongside CI results, merge conflicts and diff sizes. Desktop
notifications alert you when a pull request needs your attention. You can pin
pull requests, ignore them or hide repositories from the widget.

## Linux

Building requires Rust 1.88+, GTK 4.12+, libadwaita 1.6+, Pango 1.56+ and
gtk4-layer-shell, including development files for the system libraries.

On Arch Linux, install the libraries and GitHub CLI with:

```sh
sudo pacman -S gtk4 libadwaita gtk4-layer-shell github-cli
```

Sign in with the [GitHub CLI](https://cli.github.com/), then run the installer
from the repository directory:

```sh
gh auth login
./install.sh
```

The installer builds a release binary and installs it to `~/.local/bin`, along
with a desktop entry and icon. Installation is per user.

Alternatively, supply a token through `GITHUB_TOKEN` in the widget's launch
environment.

To uninstall, run `./install.sh --uninstall`. Your settings are preserved.

### Desktop integration

On **GNOME Wayland**, the bundled shell extension launches the widget on every
workspace and keeps it out of the dock, Alt+Tab and overview. The extension
supports GNOME Shell 49, 50 and 51. If it isn't detected
after installation, log out and back in, then enable it:

```sh
gnome-extensions enable megalith-widgets@MegalithOfficial
```

On **Wayland compositors with layer-shell support**, the widget sits below other
windows. Both integrations support the corner and Custom position settings.
`MEGALITH_WIDGETS_CORNER` sets the initial corner before a position is saved.
Other environments use a borderless window with native window dragging;
restoring coordinates requires GNOME or layer-shell support.

Outside GNOME, the installer adds an autostart entry. Run
`~/.local/bin/megalith-widgets` to start it immediately after installation.

To build and run without gtk4-layer-shell:

```sh
cargo build --release --no-default-features
./target/release/megalith-widgets
```

## macOS

Building requires macOS 14+, Swift 5.9+ and the Xcode command line tools.
Install the GitHub CLI with Homebrew, sign in and run the build script:

```sh
xcode-select --install
brew install gh
gh auth login
cd macos
./build.sh --install
```

The script builds `macos/build/Megalith Widgets.app`, copies it to `/Applications`
and opens it. Run `./build.sh` without `--install` to build the app bundle only.

The widget sits on the desktop, above the wallpaper and below other windows, on
every Space. It has no Dock icon; the menu bar icon offers refresh, settings and
quit. **Avoid desktop widgets** looks for free space near the selected corner using
desktop window bounds. It runs at launch and when the corner, display layout or
Space changes; use **Find Free Space** in the menu bar to run it again after
moving other widgets.

Custom positions remain fixed. Widget avoidance and opening at login can be
enabled in settings.

The build script signs the app ad hoc for local use; it does not notarize it.

## Configuration

Both apps refresh every two minutes by default. Settings include the refresh
interval, desktop notifications, draft visibility, repository filters and
system, light or dark appearance.

Choose one of the four corners in **Position**, or select **Custom** to enter X/Y
coordinates. On GNOME, layer-shell desktops and macOS, dragging the **Reviews**
title selects Custom and saves the coordinates to `prefs.json`. Coordinates are
logical pixels from the top-left of the main display's usable area.

Preferences use the same JSON format on both platforms and are stored locally:

- **Linux:** `~/.config/megalith-widgets/prefs.json`, or
  `$XDG_CONFIG_HOME/megalith-widgets/prefs.json` when set.
- **macOS:** `~/Library/Application Support/megalith-widgets/prefs.json`.

## License

Copyright (c) 2026 MegalithOfficial.

The Linux and macOS application source code is licensed under the
[GNU General Public License v3.0](LICENSE) (GPL-3.0-only).
Bundled fonts and icons retain their respective licenses listed below.

## Credits

- [GitHub Octicons](https://github.com/primer/octicons) — MIT License.
- [IBM Plex Sans](https://github.com/IBM/plex) and
  [Lilex](https://github.com/mishamyrt/Lilex) — SIL Open Font License.
  License files are included in [`data/fonts/`](data/fonts/).
- Colors follow Zed's *GitHub Dark Tritanopia* and *Ayu Light* themes.
