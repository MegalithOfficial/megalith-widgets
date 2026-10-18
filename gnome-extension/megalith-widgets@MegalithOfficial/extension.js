// Launch the widget through Mutter so its window can join the desktop layer.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {resolvePosition} from './position.js';

const BINARY = 'megalith-widgets';
const RELAUNCH_DELAY_SECONDS = 3;
// Wait for Mutter's initial placement before moving the window.
const PLACE_DELAY_MS = 250;

export default class MegalithWidgets extends Extension {
    enable() {
        this._window = null;
        this._signals = [];
        this._timeouts = new Set();
        this._actions = null;
        this._actionSignals = [];

        this._connect(global.window_manager, 'map', (_wm, actor) => {
            this._onMapped(actor.get_meta_window());
        }, true);
        this._connect(Main.layoutManager, 'monitors-changed', () => this._place());
        this._connect(global.display, 'workareas-changed', () => this._place());
        this._connect(global.display, 'grab-op-end', (_display, window) => {
            if (window === this._window)
                this._savePosition();
        });

        this._launch();
    }

    disable() {
        for (const [object, id] of this._signals)
            object.disconnect(id);
        this._signals = [];

        for (const id of this._timeouts)
            GLib.source_remove(id);
        this._timeouts.clear();

        this._cancellable?.cancel();
        this._cancellable = null;
        this._client?.get_subprocess()?.force_exit();
        this._client = null;
        this._release();
    }

    _connect(object, signal, handler, after = false) {
        const id = after ? object.connect_after(signal, handler) : object.connect(signal, handler);
        this._signals.push([object, id]);
    }

    _later(ms, callback) {
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._timeouts.delete(id);
            callback();
            return GLib.SOURCE_REMOVE;
        });
        this._timeouts.add(id);
    }

    _launch() {
        const binary = GLib.find_program_in_path(BINARY) ??
            GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', BINARY]);
        const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});

        try {
            this._client = Meta.WaylandClient.new_subprocess(global.context, launcher, [binary]);
        } catch (e) {
            console.error(`[megalith-widgets] couldn't start ${binary}: ${e.message}`);
            this._client = null;
            return;
        } finally {
            launcher.close();
        }

        const client = this._client;
        const subprocess = client.get_subprocess();
        this._cancellable = new Gio.Cancellable();
        subprocess.wait_async(this._cancellable, (process, result) => {
            try {
                process.wait_finish(result);
            } catch (error) {
                if (!error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    console.error(`[megalith-widgets] ${error.message}`);
                return;
            }
            if (this._client !== client)
                return;
            this._client = null;
            this._release();
            // Restart after crashes; leave intentional exits alone.
            if (subprocess.get_if_exited() && subprocess.get_exit_status() === 0)
                return;
            this._later(RELAUNCH_DELAY_SECONDS * 1000, () => this._launch());
        });
    }

    _onMapped(window) {
        if (this._client?.owns_window(window)) {
            this._adopt(window);
            return;
        }
        // Stay above desktop icon extensions.
        if (this._window && window.get_window_type() === Meta.WindowType.DESKTOP)
            this._later(0, () => this._window?.raise());
    }

    _adopt(window) {
        this._release();
        this._window = window;
        const busName = window.get_gtk_unique_bus_name();
        const objectPath = window.get_gtk_application_object_path();
        if (busName && objectPath) {
            this._actions = Gio.DBusActionGroup.get(Gio.DBus.session, busName, objectPath);
            this._actionSignals = [
                this._actions.connect('action-added', (_group, name) => {
                    if (name === 'placement')
                        this._place();
                }),
                this._actions.connect('action-state-changed', (_group, name) => {
                    if (name === 'placement')
                        this._place();
                }),
            ];
        }
        this._windowSignals = [
            window.connect('size-changed', () => this._place()),
            window.connect('unmanaged', () => this._release()),
        ];

        window.set_type(Meta.WindowType.DESKTOP);
        window.stick();
        window.raise();
        this._later(PLACE_DELAY_MS, () => this._place());
    }

    _release() {
        for (const id of this._actionSignals ?? [])
            this._actions.disconnect(id);
        this._actions = null;
        this._actionSignals = [];
        for (const id of this._windowSignals ?? [])
            this._window?.disconnect(id);
        this._windowSignals = [];
        this._window = null;
    }

    _place() {
        const window = this._window;
        if (!window)
            return;
        const areas = Main.layoutManager.monitors.map((_monitor, index) => window.get_work_area_for_monitor(index));
        const state = this._actions?.get_action_state('placement')?.deep_unpack() ?? ['top-left', 10, 10];
        const position = resolvePosition(state, window.get_frame_rect(), areas, Main.layoutManager.primaryIndex);
        if (position)
            window.move_frame(false, position.x, position.y);
    }

    _savePosition() {
        if (!this._actions?.has_action('placement'))
            return;
        const area = this._window.get_work_area_for_monitor(Main.layoutManager.primaryIndex);
        const frame = this._window.get_frame_rect();
        this._actions.activate_action('placement', new GLib.Variant('(sii)', ['custom', frame.x - area.x, frame.y - area.y]));
    }
}
