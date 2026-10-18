#!/usr/bin/env bash
# Login startup setup used by install.sh.

quote_shell_path() {
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

write_desktop_entry() {
    local template=$1 destination=$2 executable=$3
    local escaped=$executable line
    escaped=${escaped//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    escaped=${escaped//\$/\\\$}
    escaped=${escaped//\`/\\\`}
    escaped=${escaped//%/%%}
    # Desktop entry string escaping happens before Exec argument parsing.
    escaped=${escaped//\\/\\\\}
    install -d "$(dirname "$destination")"
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            Exec=*) printf 'Exec="%s"\n' "$escaped" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$template" > "$destination"
    chmod 644 "$destination"
}

update_wm_autostart() {
    local file=$1 syntax=$2 executable=$3 mode=$4
    [[ -f $file ]] || return 0
    local prefix='#' command temporary
    [[ $syntax != hyprland-lua ]] || prefix='--'
    local begin="$prefix >>> megalith-widgets autostart"
    local end="$prefix <<< megalith-widgets autostart"
    if [[ $mode == remove ]] && ! grep -Fxq -- "$begin" "$file"; then
        return 0
    fi
    temporary=$(mktemp)
    if ! awk -v begin="$begin" -v end="$end" '
        $0 == begin { if (inside) exit 1; inside = 1; next }
        $0 == end { if (!inside) exit 1; inside = 0; next }
        !inside { print }
        END { if (inside) exit 1 }
    ' "$file" > "$temporary"; then
        rm -f "$temporary"
        echo "Incomplete Megalith Widgets autostart block in $file" >&2
        return 1
    fi
    if [[ $mode == install ]]; then
        command="exec $(quote_shell_path "$executable")"
        {
            printf '%s\n' "$begin"
            case $syntax in
                sway|i3) printf 'exec --no-startup-id %s\n' "$command" ;;
                hyprland) printf 'exec-once = %s\n' "$command" ;;
                hyprland-lua)
                    command=${command//\\/\\\\}
                    command=${command//\"/\\\"}
                    printf 'hl.on("hyprland.start", function()\n    hl.exec_cmd("%s")\nend)\n' "$command"
                    ;;
            esac
            printf '%s\n' "$end"
        } >> "$temporary"
    fi
    if ! cmp -s "$temporary" "$file"; then
        # Write through symlinks so dotfile managers keep ownership of the file.
        cat "$temporary" > "$file"
        echo "Updated autostart: $file"
    fi
    rm -f "$temporary"
}

configure_wm_autostart() {
    local config_dir=$1 user_home=$2 executable=$3 mode=$4
    update_wm_autostart "$config_dir/sway/config" sway "$executable" "$mode"
    update_wm_autostart "$config_dir/i3/config" i3 "$executable" "$mode"
    if [[ $mode == remove || ! -f $config_dir/i3/config ]]; then
        update_wm_autostart "$user_home/.i3/config" i3 "$executable" "$mode"
    fi
    update_wm_autostart "$config_dir/hypr/hyprland.lua" hyprland-lua "$executable" "$mode"
    update_wm_autostart "$config_dir/hypr/hyprland.conf" hyprland "$executable" "$mode"
}
