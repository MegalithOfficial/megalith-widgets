# Install on Linux

The binary is built on Arch Linux and needs compatible glibc, GTK 4,
libadwaita, Pango and gtk4-layer-shell libraries. On Arch Linux, install the
runtime libraries and GitHub CLI with:

```sh
sudo pacman -S gtk4 libadwaita gtk4-layer-shell github-cli
```

Extract the archive, open a terminal in the extracted directory and run:

```sh
gh auth login
./install.sh
```

No Rust compiler is needed. The installer copies the app to `~/.local/bin`,
adds its desktop entry and sets up startup at login. Run
`~/.local/bin/megalith-widgets` to open it immediately.

GNOME uses the included shell extension; log out and back in if it isn't
detected. Other desktops use XDG autostart. Existing Sway, i3 and Hyprland
configs get a startup entry.

Run `./install.sh --uninstall` from this directory to remove the app.
Your preferences are kept.
