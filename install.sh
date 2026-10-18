#!/usr/bin/env bash
# Installs a release package, or builds from a source checkout.
#
#   ./install.sh              install for the current user
#   ./install.sh --uninstall  remove everything this script installed
#
# On GNOME the bundled shell extension launches the widget and pins it to the
# desktop. Other desktops use XDG autostart; standalone WMs use their configs.
set -euo pipefail

APP_ID=dev.megalith.MegalithWidgets
BINARY=megalith-widgets
EXTENSION=megalith-widgets@MegalithOfficial

BIN_DIR=${XDG_BIN_HOME:-$HOME/.local/bin}
DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}
EXTENSION_DIR=$DATA_DIR/gnome-shell/extensions/$EXTENSION
DESKTOP_FILE=$DATA_DIR/applications/$APP_ID.desktop
ICON_FILE=$DATA_DIR/icons/hicolor/scalable/apps/$APP_ID.svg
AUTOSTART_FILE=$CONFIG_DIR/autostart/$APP_ID.desktop

cd "$(dirname "$0")"
source scripts/autostart.sh

is_gnome() {
    [[ ${XDG_CURRENT_DESKTOP:-} == *GNOME* ]]
}

uninstall() {
    if is_gnome; then
        gnome-extensions disable "$EXTENSION" 2>/dev/null || true
    fi
    configure_wm_autostart "$CONFIG_DIR" "$HOME" "$BIN_DIR/$BINARY" remove
    rm -rf "$EXTENSION_DIR"
    rm -f "$BIN_DIR/$BINARY" "$DESKTOP_FILE" "$ICON_FILE" "$AUTOSTART_FILE"
    echo "Removed Megalith Widgets. Settings remain in $CONFIG_DIR/megalith-widgets."
}

install_widget() {
    local source_binary
    if [[ -f Cargo.toml ]]; then
        cargo build --release --locked
        source_binary="target/release/$BINARY"
    elif [[ -x $BINARY ]]; then
        source_binary=$BINARY
    else
        echo "No prebuilt binary or source checkout found." >&2
        return 1
    fi

    install -Dm755 "$source_binary" "$BIN_DIR/$BINARY"
    install -Dm644 "data/$APP_ID.svg" "$ICON_FILE"
    # Absolute Exec path: ~/.local/bin isn't on every session's PATH.
    write_desktop_entry "data/$APP_ID.desktop" "$DESKTOP_FILE" "$BIN_DIR/$BINARY"
    install -Dm644 "$DESKTOP_FILE" "$AUTOSTART_FILE"
    # The extension owns startup in GNOME; the entry also covers DE switches.
    printf 'NotShowIn=GNOME;\n' >> "$AUTOSTART_FILE"
    configure_wm_autostart "$CONFIG_DIR" "$HOME" "$BIN_DIR/$BINARY" install

    if is_gnome; then
        install -d "$EXTENSION_DIR"
        install -m644 "gnome-extension/$EXTENSION/"* "$EXTENSION_DIR/"
        if gnome-extensions enable "$EXTENSION" 2>/dev/null; then
            echo "Installed. The extension is enabled and will launch the widget."
        else
            echo "Installed. Log out and back in, then run:"
            echo "    gnome-extensions enable $EXTENSION"
        fi
    else
        echo "Installed. Megalith Widgets starts at login; run '$BINARY' to start it now."
    fi
}

case ${1:-} in
    --uninstall) uninstall ;;
    "") install_widget ;;
    *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac
