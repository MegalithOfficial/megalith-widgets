#!/usr/bin/env bash
# Builds and installs Megalith Widgets for the current user.
#
#   ./install.sh              build and install
#   ./install.sh --uninstall  remove everything this script installed
#
# On GNOME the bundled shell extension launches the widget and pins it to the
# desktop. Elsewhere an autostart entry starts it at login.
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

is_gnome() {
    [[ ${XDG_CURRENT_DESKTOP:-} == *GNOME* ]]
}

uninstall() {
    if is_gnome; then
        gnome-extensions disable "$EXTENSION" 2>/dev/null || true
    fi
    rm -rf "$EXTENSION_DIR"
    rm -f "$BIN_DIR/$BINARY" "$DESKTOP_FILE" "$ICON_FILE" "$AUTOSTART_FILE"
    echo "Removed Megalith Widgets. Settings remain in $CONFIG_DIR/megalith-widgets."
}

install_widget() {
    cargo build --release

    install -Dm755 "target/release/$BINARY" "$BIN_DIR/$BINARY"
    install -Dm644 "data/$APP_ID.svg" "$ICON_FILE"
    # Absolute Exec path: ~/.local/bin isn't on every session's PATH.
    install -d "$(dirname "$DESKTOP_FILE")"
    sed "s|^Exec=.*|Exec=$BIN_DIR/$BINARY|" "data/$APP_ID.desktop" > "$DESKTOP_FILE"

    if is_gnome; then
        install -d "$EXTENSION_DIR"
        install -m644 "gnome-extension/$EXTENSION/"* "$EXTENSION_DIR/"
        rm -f "$AUTOSTART_FILE"
        if gnome-extensions enable "$EXTENSION" 2>/dev/null; then
            echo "Installed. The extension is enabled and will launch the widget."
        else
            echo "Installed. Log out and back in, then run:"
            echo "    gnome-extensions enable $EXTENSION"
        fi
    else
        install -Dm644 "$DESKTOP_FILE" "$AUTOSTART_FILE"
        echo "Installed. Megalith Widgets starts at login; run '$BINARY' to start it now."
    fi
}

case ${1:-} in
    --uninstall) uninstall ;;
    "") install_widget ;;
    *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac
