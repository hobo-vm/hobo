#!/usr/bin/python3
# hobo ui's backend in a Linux guest (designs/hobo-ui-linux-windows.md). The VM process's
# UIDriver speaks to it in JSON lines over stdin and stdout for one command's life: it reads the
# tree through AT-SPI, places windows through hobo's GNOME Shell extension (Wayland tells an app
# nothing of where its windows are), and sends input through a uinput device, which reaches
# Wayland apps as a person's mouse and keyboard would. hobo-agent fetches it as the `ui` tool and
# runs it in the desktop session. Frames are [x, y, w, h] in GNOME's logical screen coordinates.
import json
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

TREE_LIMIT = 20000
TEXT_LIMIT = 2000


def say(answer):
    sys.stdout.write(json.dumps(answer) + "\n")
    sys.stdout.flush()


class Failure(Exception):
    pass


def inside(frame, x, y):
    """Whether the point is in the [x, y, w, h] frame."""
    fx, fy, fw, fh = frame
    return fx <= x < fx + fw and fy <= y < fy + fh


def has(accessible, interface):
    """Whether the element implements an AT-SPI interface, whose methods are then called as
    Atspi.<Interface>.<method>(accessible, …)."""
    try:
        return interface in accessible.get_interfaces()
    except GLib.Error:
        return False


# MARK: GNOME Shell


class Shell:
    """hobo's extension, on GNOME Shell's own D-Bus connection (Agent/gnome-extension)."""

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(self, method, parameters=None, reply="(s)"):
        # Just after the session starts, the shell may not have enabled extensions yet (or even
        # be on the bus): wait for the extension's object up to 15 s rather than fail.
        deadline = time.monotonic() + 15
        while True:
            try:
                result = self.bus.call_sync(
                    "org.gnome.Shell", "/app/gsquared/Hobo", "app.gsquared.Hobo", method, parameters,
                    GLib.VariantType(reply), Gio.DBusCallFlags.NONE, 5000, None)
                return result.unpack()[0]
            except GLib.Error as error:
                starting = "UnknownMethod" in error.message or "ServiceUnknown" in error.message
                if not starting or time.monotonic() >= deadline:
                    raise Failure("hobo's GNOME Shell extension didn't answer (%s); was this VM's desktop set up "
                                  "by a current hobo init --os linux recipe?" % error.message)
                time.sleep(0.5)

    def windows(self):
        return json.loads(self.call("Windows"))

    def screen(self):
        return json.loads(self.call("Screen"))

    def activate(self, window_id):
        return self.call("Activate", GLib.Variant("(t)", (window_id,)), "(b)")


# MARK: Input


# Linux's input event codes (linux/input-event-codes.h).
EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
ABS_X, ABS_Y = 0, 1
REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 6, 8, 11, 12
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA = 29, 42, 56, 125

KEYS = dict(zip("1234567890", range(2, 12)))
KEYS.update(zip("qwertyuiop", range(16, 26)))
KEYS.update(zip("asdfghjkl", range(30, 39)))
KEYS.update(zip("zxcvbnm", range(44, 51)))
KEYS.update({
    "escape": 1, "-": 12, "=": 13, "delete": 14, "tab": 15, "[": 26, "]": 27, "return": 28, ";": 39, "'": 40,
    "`": 41, "\\": 43, ",": 51, ".": 52, "/": 53, "space": 57, "home": 102, "up": 103, "pageup": 104, "left": 105,
    "right": 106, "end": 107, "down": 108, "pagedown": 109, "forwarddelete": 111,
})
KEYS.update({"f%d" % n: 58 + n for n in range(1, 11)})
KEYS.update({"f11": 87, "f12": 88})
MODIFIERS = {"command": KEY_LEFTMETA, "control": KEY_LEFTCTRL, "option": KEY_LEFTALT, "shift": KEY_LEFTSHIFT}

# What a US keyboard types without and with Shift, by the key it's on.
SHIFTED = dict(zip('~!@#$%^&*()_+{}|:"<>?', "`1234567890-=[]\\;',./"))

# uinput's ioctls: _IOW('U', n, int) and _IO('U', n).
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045566, 0x40045567
UI_DEV_CREATE = 0x5501


class Device:
    """A uinput device, made with the legacy uinput_user_dev setup, which every kernel takes."""

    RANGE = 65535

    def __init__(self, name, keys=(), relative=(), absolute=()):
        import fcntl
        import os
        import struct
        self.os, self.struct = os, struct
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for kind, bits, ioctl in ((EV_KEY, keys, UI_SET_KEYBIT), (EV_REL, relative, UI_SET_RELBIT), (EV_ABS, absolute, UI_SET_ABSBIT)):
            if bits:
                fcntl.ioctl(self.fd, UI_SET_EVBIT, kind)
                for bit in bits:
                    fcntl.ioctl(self.fd, ioctl, bit)
        maximum = [0] * 64
        for axis in absolute:
            maximum[axis] = self.RANGE
        # struct uinput_user_dev: name[80], input_id (bustype, vendor, product, version), ff_effects_max,
        # then absmax, absmin, absfuzz and absflat, 64 each.
        setup = struct.pack("80sHHHHI", name.encode(), 0x06, 0x1209, 0x0001, 1, 0)
        setup += struct.pack("64i", *maximum) + struct.pack("64i", *([0] * 64)) * 3
        os.write(self.fd, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def write(self, kind, code, value):
        # struct input_event: a timeval the kernel fills in, then type, code and value.
        self.os.write(self.fd, self.struct.pack("qqHHi", 0, 0, kind, code, value))

    def syn(self):
        self.write(EV_SYN, 0, 0)


def wait_until_opened(names, timeout=3):
    """Waits for gnome-shell, which runs as this user, to open the event devices of the uinput
    devices `names`: it has them in its fds once libinput has added them."""
    import glob
    import os
    nodes = set()
    for name_file in glob.glob("/sys/devices/virtual/input/input*/name"):
        try:
            with open(name_file) as f:
                if f.read().strip() not in names:
                    continue
        except OSError:
            continue
        for event in glob.glob(os.path.join(os.path.dirname(name_file), "event*")):
            nodes.add("/dev/input/" + os.path.basename(event))
    shells = []
    for comm in glob.glob("/proc/[0-9]*/comm"):
        try:
            with open(comm) as f:
                if f.read().strip() == "gnome-shell":
                    shells.append(os.path.dirname(comm))
        except OSError:
            continue
    deadline = time.time() + timeout
    while nodes and shells and time.time() < deadline:
        opened = set()
        for shell in shells:
            for fd in glob.glob(shell + "/fd/*"):
                try:
                    opened.add(os.readlink(fd))
                except OSError:
                    pass
        if nodes <= opened:
            time.sleep(0.05)
            return
        time.sleep(0.02)
    # Not seen (an older layout, or no access): the time a new device took on Ubuntu 26.04.
    time.sleep(0.5)


class Input:
    """A uinput absolute pointer and keyboard, made on first use: the kernel hands their events to
    the compositor as hardware's, so Wayland apps get them as a person's."""

    def __init__(self, screen):
        self.screen = screen
        self.pointer = None
        self.keyboard = None

    def devices(self):
        if self.pointer:
            return
        try:
            self.pointer = Device("hobo ui pointer", keys=(BTN_LEFT, BTN_RIGHT, BTN_MIDDLE),
                                  relative=(REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES), absolute=(ABS_X, ABS_Y))
            self.keyboard = Device("hobo ui keyboard", keys=sorted(set(KEYS.values()) | set(MODIFIERS.values())))
        except OSError as error:
            raise Failure("can't make input devices (%s); was this VM's desktop set up by a current hobo init --os "
                          "linux recipe, which gives hobo /dev/uinput?" % error)
        # Events sent before the compositor has opened a new device are lost.
        wait_until_opened(["hobo ui pointer", "hobo ui keyboard"])

    def move(self, x, y, settle=0.03):
        self.devices()
        sx, sy, sw, sh = self.screen
        ax = round((x - sx) / max(sw, 1) * Device.RANGE)
        ay = round((y - sy) / max(sh, 1) * Device.RANGE)
        self.pointer.write(EV_ABS, ABS_X, max(0, min(Device.RANGE, ax)))
        self.pointer.write(EV_ABS, ABS_Y, max(0, min(Device.RANGE, ay)))
        self.pointer.syn()
        time.sleep(settle)

    def modifiers(self, names, down):
        for name in names:
            if name in MODIFIERS:
                self.keyboard.write(EV_KEY, MODIFIERS[name], 1 if down else 0)
        self.keyboard.syn()

    def click(self, x, y, right=False, count=1, mods=()):
        self.move(x, y)
        button = BTN_RIGHT if right else BTN_LEFT
        self.modifiers(mods, True)
        for _ in range(count):
            for value in (1, 0):
                self.pointer.write(EV_KEY, button, value)
                self.pointer.syn()
                time.sleep(0.02)
        self.modifiers(mods, False)

    def drag(self, start, end, mods=()):
        self.move(*start)
        self.modifiers(mods, True)
        self.pointer.write(EV_KEY, BTN_LEFT, 1)
        self.pointer.syn()
        time.sleep(0.1)
        steps = 20
        for step in range(1, steps + 1):
            t = step / steps
            self.move(start[0] + (end[0] - start[0]) * t, start[1] + (end[1] - start[1]) * t, settle=0.015)
        time.sleep(0.3)
        self.pointer.write(EV_KEY, BTN_LEFT, 0)
        self.pointer.syn()
        self.modifiers(mods, False)
        time.sleep(0.1)

    def scroll(self, x, y, direction, notches):
        self.move(x, y)
        axis, hi, sign = {
            "up": (REL_WHEEL, REL_WHEEL_HI_RES, 1), "down": (REL_WHEEL, REL_WHEEL_HI_RES, -1),
            "left": (REL_HWHEEL, REL_HWHEEL_HI_RES, -1), "right": (REL_HWHEEL, REL_HWHEEL_HI_RES, 1),
        }[direction]
        for _ in range(notches):
            self.pointer.write(EV_REL, axis, sign)
            self.pointer.write(EV_REL, hi, 120 * sign)
            self.pointer.syn()
            time.sleep(0.02)
        time.sleep(0.1)

    def tap(self, code, mods=()):
        self.modifiers(mods, True)
        self.keyboard.write(EV_KEY, code, 1)
        self.keyboard.syn()
        time.sleep(0.01)
        self.keyboard.write(EV_KEY, code, 0)
        self.keyboard.syn()
        self.modifiers(mods, False)
        time.sleep(0.01)

    def key(self, name, mods):
        self.devices()
        if name not in KEYS:
            raise Failure("this guest's keyboard has no key %s" % name)
        self.tap(KEYS[name], mods)

    def type(self, text):
        """US-layout keys for what the layout has; IBus's Unicode entry (Ctrl-Shift-U, the code
        point in hex, Space) for the rest."""
        self.devices()
        # A CRLF is one line break, as on macOS and Windows guests.
        for character in text.replace("\r\n", "\n"):
            if character in "\r\n":
                self.tap(KEYS["return"])
            elif character == " ":
                self.tap(KEYS["space"])
            elif character == "\t":
                self.tap(KEYS["tab"])
            elif character in KEYS:
                self.tap(KEYS[character])
            elif character.isascii() and character.isalpha():
                self.tap(KEYS[character.lower()], ["shift"])
            elif character in SHIFTED:
                self.tap(KEYS[SHIFTED[character]], ["shift"])
            else:
                # IBus takes these keys in turn as it gets to them; ones sent before it has
                # started or finished the entry go astray (taken as more hex, or typed twice).
                self.tap(KEYS["u"], ["control", "shift"])
                time.sleep(0.1)
                for digit in "%x" % ord(character):
                    self.tap(KEYS[digit])
                    time.sleep(0.03)
                self.tap(KEYS["space"])
                time.sleep(0.15)
            time.sleep(0.008)
        time.sleep(0.05)


# MARK: Accessibility


class Backend:
    def __init__(self):
        self.shell = Shell()
        self.elements = []
        self.ids = {}
        self.window_cache = None
        screen = self.shell.screen()
        self.scale = float(screen.get("scale", 1))
        width, height = screen.get("size", [0, 0])
        self.screen = [0, 0, width, height]
        self.input = Input(self.screen)

    # Elements are numbered as they're met, the same number for the same object all session:
    # libatspi keeps one object per remote accessible, and PyGObject one wrapper per object.
    def id(self, accessible):
        key = accessible
        if key not in self.ids:
            self.ids[key] = len(self.elements)
            self.elements.append(accessible)
        return self.ids[key]

    def get(self, arguments):
        index = arguments.get("id")
        if not isinstance(index, int) or not 0 <= index < len(self.elements):
            raise Failure("no element %r this session" % index)
        return self.elements[index]

    def windows(self, fresh=False):
        if fresh or self.window_cache is None:
            self.window_cache = self.shell.windows()
        return self.window_cache

    # AT-SPI's frames for a window ("frame", "dialog", …) are relative to it on Wayland: to the
    # frame a person sees, not the surface with its shadow (GTK 4, checked against a screenshot
    # on Ubuntu 26.04). The extension says where that frame is. A window is matched by its pid
    # and title, else by its pid alone when that pid has one window.
    def window_origin(self, top):
        try:
            pid = top.get_process_id()
            title = top.get_name() or ""
        except GLib.Error:
            return (0, 0)
        mine = [w for w in self.windows() if w["pid"] == pid and not w["menu"]]
        named = [w for w in mine if w["title"] == title]
        found = named[0] if named else (mine[0] if len(mine) == 1 else None)
        if not found:
            return (0, 0)
        return (found["frame"][0], found["frame"][1])

    def top_level(self, accessible):
        """The child of the app that the element is in: its window."""
        current = accessible
        for _ in range(200):
            try:
                parent = current.get_parent()
            except GLib.Error:
                return current
            if parent is None or parent.get_role() == Atspi.Role.APPLICATION:
                return current
            current = parent
        return current

    def frame(self, accessible, origin=None):
        try:
            if not has(accessible, "Component"):
                return None
            extents = Atspi.Component.get_extents(accessible, Atspi.CoordType.WINDOW)
        except GLib.Error:
            return None
        if origin is None:
            origin = self.window_origin(self.top_level(accessible))
        return [extents.x + origin[0], extents.y + origin[1], extents.width, extents.height]

    def node(self, accessible, origin=None, depth=None, budget=None):
        # An element gone since it was found (a closed menu, a list row replaced) is left out,
        # rather than failing the whole tree.
        try:
            role = accessible.get_role_name()
            states = accessible.get_state_set()
            name = accessible.get_name() or self.labelled_by(accessible)
            description = accessible.get_description()
        except GLib.Error:
            return None
        node = {"id": self.id(accessible), "role": role}
        if name:
            node["title"] = name
        try:
            identifier = accessible.get_accessible_id()
            # GtkBuilder names the objects a .ui file leaves unnamed ___object_25___: they say nothing.
            if identifier and not (identifier.startswith("___object_") and identifier.endswith("___")):
                node["identifier"] = identifier
        except (GLib.Error, AttributeError):
            pass
        if description:
            node["label"] = description
        value = self.value(accessible, role)
        if value is not None:
            node["value"] = value
        if role != "application":
            frame = self.frame(accessible, origin)
            if frame:
                node["frame"] = frame
        if not states.contains(Atspi.StateType.SENSITIVE) and not states.contains(Atspi.StateType.ENABLED):
            node["enabled"] = False
        if states.contains(Atspi.StateType.FOCUSED):
            node["focused"] = True
        if states.contains(Atspi.StateType.SELECTED):
            node["selected"] = True
        if states.contains(Atspi.StateType.CHECKABLE) or role in ("check box", "radio button", "check menu item", "radio menu item", "switch", "toggle button"):
            node["checked"] = states.contains(Atspi.StateType.CHECKED) or states.contains(Atspi.StateType.PRESSED)
        if depth is not None:
            node["children"] = self.child_nodes(accessible, depth, budget, origin if role != "application" else None)
        return node

    def child_nodes(self, accessible, depth, budget, origin):
        found = []
        try:
            count = accessible.get_child_count()
        except GLib.Error:
            return found
        for index in range(count):
            if budget[0] <= 0:
                break
            try:
                child = accessible.get_child_at_index(index)
            except GLib.Error:
                continue
            if child is None:
                continue
            budget[0] -= 1
            # Each window is placed once, for everything in it.
            child_origin = origin if origin is not None else self.window_origin(child)
            node = self.node(child, child_origin, depth + 1, budget)
            if node:
                found.append(node)
        return found

    def labelled_by(self, accessible):
        """The text of the labels an unnamed element is labelled by: how GTK 4 names a menu item."""
        try:
            relations = accessible.get_relation_set()
        except GLib.Error:
            return None
        texts = []
        for relation in relations or []:
            if relation.get_relation_type() != Atspi.RelationType.LABELLED_BY:
                continue
            for index in range(relation.get_n_targets()):
                label = relation.get_target(index)
                try:
                    text = label.get_name() or (Atspi.Text.get_text(label, 0, TEXT_LIMIT) if has(label, "Text") else "")
                except GLib.Error:
                    text = ""
                if text:
                    texts.append(text)
        return " ".join(texts) or None

    def value(self, accessible, role):
        try:
            if has(accessible, "Text") and role in ("text", "entry", "password text", "editbar", "label", "static", "caption", "paragraph", "heading", "spin button", "combo box"):
                count = Atspi.Text.get_character_count(accessible)
                content = Atspi.Text.get_text(accessible, 0, min(count, TEXT_LIMIT))
                # A label's text is its name already.
                if content and content != accessible.get_name():
                    return content
            if has(accessible, "Value"):
                current = Atspi.Value.get_current_value(accessible)
                return ("%g" % current)
        except GLib.Error:
            pass
        return None

    # MARK: Apps

    def apps(self):
        windows = self.windows(fresh=True)
        by_pid = self.windows_by_pid(windows)
        desktop = Atspi.get_desktop(0)
        apps = []
        for index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(index)
            if app is None:
                continue
            try:
                pid = app.get_process_id()
                at_name = app.get_name() or ""
            except GLib.Error:
                continue
            window = by_pid.get(pid)
            if not window:
                # No window: gnome-shell's own tree, daemons, and so on.
                continue
            aliases = [at_name] if at_name else []
            apps.append(dict(self.identity(window, at_name, pid), aliases=aliases))
        focused = next((w["pid"] for w in windows if w["focused"]), None)
        return {"apps": apps, "focused": focused}

    @staticmethod
    def windows_by_pid(windows):
        """Each pid's window that names its app: a window of its own over a transient one."""
        by_pid = {}
        for window in windows:
            if window["menu"]:
                continue
            if window["pid"] not in by_pid or (by_pid[window["pid"]].get("transient") and not window.get("transient")):
                by_pid[window["pid"]] = window
        return by_pid

    @staticmethod
    def identity(window, at_name, pid):
        """An app's name and ID. The shell names a transient window's app after its parent's, which
        for a portal's file chooser is another process's (Text Editor's for Nautilus's), so a pid
        with only transient windows goes by its AT-SPI name."""
        if window.get("transient"):
            return {"name": at_name or ("pid %d" % pid), "id": None, "pid": pid}
        return {"name": window.get("appName") or at_name or ("pid %d" % pid), "id": window.get("app"), "pid": pid}

    def application(self, pid):
        desktop = Atspi.get_desktop(0)
        for index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(index)
            try:
                if app is not None and app.get_process_id() == pid:
                    return app
            except GLib.Error:
                # An app that has quit and not yet left the registry.
                continue
        raise Failure("no app with pid %d has an accessibility tree" % pid)

    def app_of(self, accessible):
        try:
            app = accessible.get_application()
            pid = app.get_process_id()
        except GLib.Error:
            return None
        window = self.windows_by_pid(self.windows()).get(pid, {})
        return self.identity(window, app.get_name() or "", pid)

    # MARK: Hit-testing

    def at(self, x, y):
        """What's at a point: the topmost window there, then AT-SPI's hit-testing down from its
        window, in that window's coordinates."""
        for window in self.windows(fresh=True):
            if not inside(window["frame"], x, y):
                continue
            if window["menu"]:
                # A popover is a window of its own to the shell, but its elements are in its
                # parent window's tree, where hit-testing from the window doesn't reach them.
                return self.in_menus(window["pid"], x, y)
            top = self.window_accessible(window)
            if top is None:
                return None
            ox, oy = window["frame"][0], window["frame"][1]
            found = top
            for _ in range(100):
                if not has(found, "Component"):
                    break
                try:
                    inner = Atspi.Component.get_accessible_at_point(found, int(x - ox), int(y - oy), Atspi.CoordType.WINDOW)
                except GLib.Error:
                    break
                if inner is None or inner == found:
                    break
                found = inner
            return found
        return None

    def in_menus(self, pid, x, y):
        """The deepest element at a point in the app's open menus, by their frames."""
        try:
            app = self.application(pid)
        except Failure:
            return None
        def contains(accessible):
            frame = self.frame(accessible)
            return frame is not None and inside(frame, x, y)
        def deepest(accessible):
            for child in self.children(accessible):
                if contains(child):
                    return deepest(child)
            return accessible
        def menus(accessible, depth):
            if accessible.get_role() == Atspi.Role.MENU and accessible.get_state_set().contains(Atspi.StateType.SHOWING):
                yield accessible
            elif depth > 0:
                for child in self.children(accessible):
                    yield from menus(child, depth - 1)
        for menu in menus(app, 30):
            if contains(menu):
                return deepest(menu)
        return None

    def window_accessible(self, window):
        try:
            app = self.application(window["pid"])
        except Failure:
            return None
        tops = self.children(app)
        try:
            named = [t for t in tops if (t.get_name() or "") == window["title"]]
        except GLib.Error:
            return None
        if named:
            return named[0]
        return tops[0] if len(tops) == 1 else None

    # MARK: Requests

    def handle(self, request):
        op = request.get("op")
        if op == "hello":
            return {"platform": "linux", "scale": self.scale, "screen": self.screen, "access": None}
        if op == "apps":
            return self.apps()
        if op == "tree":
            app = self.application(request["pid"])
            return self.node(app, depth=0, budget=[TREE_LIMIT])
        if op == "children":
            accessible = self.get(request)
            return self.child_nodes(accessible, 0, [TREE_LIMIT], None if accessible.get_role() == Atspi.Role.APPLICATION else self.window_origin(self.top_level(accessible)))
        if op == "node":
            return self.node(self.get(request))
        if op == "parent":
            try:
                parent = self.get(request).get_parent()
            except GLib.Error:
                return None
            return self.node(parent) if parent is not None else None
        if op == "at":
            found = self.at(request["x"], request["y"])
            return self.node(found) if found is not None else None
        if op == "app_of":
            return self.app_of(self.get(request))
        if op == "raise":
            return self.raise_window(self.get(request), request.get("pid"))
        if op == "windows":
            return self.windows_over(request["area"])
        if op == "open_menu":
            return self.open_menu(request["x"], request["y"])
        if op == "press":
            accessible = self.get(request)
            if not has(accessible, "Action") or Atspi.Action.get_n_actions(accessible) == 0:
                raise Failure("it has no action to press")
            if not Atspi.Action.do_action(accessible, 0):
                raise Failure("its %s action failed" % Atspi.Action.get_action_name(accessible, 0))
            return None
        if op == "scroll_to":
            accessible = self.get(request)
            try:
                return has(accessible, "Component") and bool(Atspi.Component.scroll_to(accessible, Atspi.ScrollType.ANYWHERE))
            except GLib.Error:
                return False
        if op == "menubar":
            return self.menubar(self.get(request))
        if op == "menu_items":
            accessible = self.get(request)
            return [n for n in (self.node(c) for c in self.children(accessible)) if n]
        if op == "menu_item":
            return self.menu_item(self.get(request))
        if op == "click":
            self.input.click(request["x"], request["y"], request.get("right", False), request.get("count", 1), request.get("mods", []))
            return None
        if op == "drag":
            self.input.drag(request["from"], request["to"], request.get("mods", []))
            return None
        if op == "scroll":
            notches = request.get("lines") or max(1, round(request.get("distance", 50) / 50))
            self.input.scroll(request["x"], request["y"], request["direction"], int(notches))
            return None
        if op == "key":
            self.input.key(request["key"], request.get("mods", []))
            return None
        if op == "type":
            self.input.type(request["text"])
            return None
        raise Failure("unknown request %r" % op)

    def raise_window(self, accessible, pid):
        """Brings the element's window forward, if it isn't already."""
        top = self.top_level(accessible)
        # The element's own process, which for a portal's dialog isn't the app asked about.
        try:
            pid = top.get_application().get_process_id()
        except GLib.Error:
            pass
        windows = [w for w in self.windows(fresh=True) if w["pid"] == pid and not w["menu"]]
        title = top.get_name() or ""
        chosen = next((w for w in windows if w["title"] == title), windows[0] if windows else None)
        if chosen and not chosen["focused"]:
            self.shell.activate(chosen["id"])
            time.sleep(0.15)
        self.window_cache = None

    def windows_over(self, area):
        """The windows drawn over the [x, y, w, h] area, as they are mid-animation."""
        ax, ay, aw, ah = area
        found = []
        for window in self.windows(fresh=True):
            x, y, w, h = window["drawn"]
            if x < ax + aw and ax < x + w and y < ay + ah and ay < y + h:
                found.append({"id": window["id"], "bounds": window["drawn"], "alpha": window["opacity"]})
        return found

    def open_menu(self, x, y):
        """A menu that is open, described, when the point isn't in any open menu: a point in a
        submenu is in a menu, though its parent menu is elsewhere."""
        menus = [w for w in self.windows(fresh=True) if w["menu"]]
        if not menus or any(inside(w["frame"], x, y) for w in menus):
            return None
        return "a menu of %s" % (menus[0].get("appName") or "pid %d" % menus[0]["pid"])

    def children(self, accessible):
        try:
            return [c for c in (accessible.get_child_at_index(i) for i in range(accessible.get_child_count())) if c is not None]
        except GLib.Error:
            return []

    def menubar(self, app):
        """The menu bar in one of the app's windows, a few levels down at most."""
        def search(accessible, depth):
            if accessible.get_role() == Atspi.Role.MENU_BAR:
                return accessible
            if depth == 0:
                return None
            for child in self.children(accessible):
                found = search(child, depth - 1)
                if found:
                    return found
            return None
        for top in self.children(app):
            found = search(top, 6)
            if found:
                return self.node(found)
        return None

    def menu_item(self, accessible):
        states = accessible.get_state_set()
        role = accessible.get_role()
        shortcut = None
        if has(accessible, "Action") and Atspi.Action.get_n_actions(accessible) > 0:
            binding = Atspi.Action.get_key_binding(accessible, 0) or ""
            # "<Control>s", or "m;<Alt>f;<Control>s": the last part is the accelerator.
            accelerator = binding.split(";")[-1]
            if accelerator:
                parts = []
                for name, ours in (("<Control>", "ctrl"), ("<Primary>", "ctrl"), ("<Shift>", "shift"), ("<Alt>", "alt"), ("<Super>", "cmd")):
                    if name in accelerator:
                        parts.append(ours)
                        accelerator = accelerator.replace(name, "")
                if accelerator:
                    shortcut = "+".join(parts + [accelerator.lower()])
        return {
            "title": accessible.get_name() or self.labelled_by(accessible) or "",
            "enabled": states.contains(Atspi.StateType.SENSITIVE) or states.contains(Atspi.StateType.ENABLED),
            "checked": states.contains(Atspi.StateType.CHECKED),
            "shortcut": shortcut,
            "submenu": role == Atspi.Role.MENU,
        }


def main():
    try:
        backend = Backend()
    except Failure as error:
        backend = None
        failure = str(error)
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            say({"error": "not JSON: %r" % line[:200]})
            continue
        if backend is None:
            if request.get("op") == "hello":
                say({"ok": {"platform": "linux", "access": failure}})
            else:
                say({"error": failure})
            continue
        try:
            say({"ok": backend.handle(request)})
        except Failure as error:
            say({"error": str(error)})
        except (GLib.Error, KeyError, TypeError, ValueError) as error:
            say({"error": "%s: %s" % (request.get("op"), error)})


if __name__ == "__main__":
    main()
