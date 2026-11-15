// hobo's GNOME Shell extension (designs/hobo-ui-linux-windows.md decision 3): on Wayland an app
// can't learn where its windows are, so AT-SPI gives element frames relative to their window.
// This tells hobo ui's backend each window's place on screen and stacking, and raises one, over
// D-Bus on the shell's own connection: org.gnome.Shell, /app/gsquared/Hobo.
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const INTERFACE = `
<node>
  <interface name="app.gsquared.Hobo">
    <method name="Windows"><arg type="s" direction="out" name="json"/></method>
    <method name="Screen"><arg type="s" direction="out" name="json"/></method>
    <method name="Activate">
      <arg type="t" direction="in" name="id"/>
      <arg type="b" direction="out" name="done"/>
    </method>
  </interface>
</node>`;

const MENU_TYPES = new Set([
    Meta.WindowType.DROPDOWN_MENU, Meta.WindowType.POPUP_MENU, Meta.WindowType.MENU, Meta.WindowType.COMBO,
]);

function rect(r) {
    return [r.x, r.y, r.width, r.height];
}

export default class HoboExtension extends Extension {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(INTERFACE, this);
        this._object.export(Gio.DBus.session, '/app/gsquared/Hobo');
    }

    disable() {
        this._object?.unexport();
        this._object = null;
    }

    // Every window on screen, topmost first, as JSON: where it is (the frame a person sees and
    // the buffer its surface covers, shadows included, which AT-SPI's window coordinates start
    // from), where its actor is drawn mid-animation, and whose it is.
    Windows() {
        const tracker = Shell.WindowTracker.get_default();
        const focus = global.display.focus_window;
        const windows = global.display.sort_windows_by_stacking(global.display.list_all_windows()).reverse();
        return JSON.stringify(windows.filter(w => !w.minimized && w.showing_on_its_workspace()).map(w => {
            const app = tracker.get_window_app(w);
            const actor = w.get_compositor_private();
            const [ax, ay] = actor ? actor.get_transformed_position() : [0, 0];
            const [aw, ah] = actor ? actor.get_transformed_size() : [0, 0];
            return {
                id: Number(w.get_id()),
                pid: w.get_pid(),
                title: w.get_title() ?? '',
                app: app ? app.get_id().replace(/\.desktop$/, '') : null,
                appName: app ? app.get_name() : null,
                frame: rect(w.get_frame_rect()),
                buffer: rect(w.get_buffer_rect()),
                drawn: [ax, ay, aw, ah],
                opacity: actor ? actor.opacity / 255 : 1,
                focused: w === focus,
                menu: MENU_TYPES.has(w.get_window_type()),
                transient: w.get_transient_for() !== null,
            };
        }));
    }

    Screen() {
        const display = global.display;
        const monitor = display.get_primary_monitor();
        return JSON.stringify({
            size: [global.stage.width, global.stage.height],
            scale: display.get_monitor_scale(monitor),
        });
    }

    Activate(id) {
        const window = global.display.list_all_windows().find(w => Number(w.get_id()) === Number(id));
        if (!window) return false;
        Main.activateWindow(window);
        return true;
    }
}
