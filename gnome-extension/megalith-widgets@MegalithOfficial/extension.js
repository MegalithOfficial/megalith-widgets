// GNOME doesn't let Wayland clients position themselves or sit on the
// desktop, so this extension launches the widget itself. Windows created by a
// process the shell spawned can be identified, turned into desktop windows
// (below everything, out of the dock, Alt+Tab and the overview), stuck to
// every workspace and parked in the top-left corner.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BINARY = 'megalith-widgets';
// Distance from the work area's corner. The widget draws its own 14px
// shadow margin, so the visible gap is a little larger.
const MARGIN = 10;
const RELAUNCH_DELAY_SECONDS = 3;
// Mutter places a freshly mapped window itself; move it after that settles.
const PLACE_DELAY_MS = 250;

export default class MegalithWidgets extends Extension {
    enable() {
        this._window = null;
        this._signals = [];
        this._timeouts = new Set();

        this._connect(global.window_manager, 'map', (_wm, actor) => {
            this._onMapped(actor.get_meta_window());
        }, true);
        this._connect(Main.layoutManager, 'monitors-changed', () => this._place());
        this._connect(global.display, 'workareas-changed', () => this._place());

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

        const subprocess = this._client.get_subprocess();
        this._cancellable = new Gio.Cancellable();
        subprocess.wait_async(this._cancellable, () => {
            this._client = null;
            this._release();
            // Quitting from the widget's menu exits cleanly; respect that
            // until the next login. Anything else is a crash, so restart.
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
        // Another desktop window (e.g. Desktop Icons NG) would cover ours.
        if (this._window && window.get_window_type() === Meta.WindowType.DESKTOP)
            this._later(0, () => this._window?.raise());
    }

    _adopt(window) {
        this._release();
        this._window = window;
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
        for (const id of this._windowSignals ?? [])
            this._window?.disconnect(id);
        this._windowSignals = [];
        this._window = null;
    }

    _place() {
        const window = this._window;
        if (!window)
            return;
        const area = window.get_work_area_for_monitor(Main.layoutManager.primaryIndex);
        window.move_frame(false, area.x + MARGIN, area.y + MARGIN);
    }
}
