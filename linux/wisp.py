#!/usr/bin/env python3
"""Wisp for Linux (Cinnamon / X11): hold-to-talk dictation and call notes.

Tray icon + floating W widget, like the Mac app. Run through wisp-launch (sets up the GPU libraries).
Test modes (no GUI):  --test file.wav [category]   --test-call folder   --render-notes notes.md out.html   --check
"""
import datetime as dt
import fcntl
import math
import os
import shutil
import subprocess
import sys
import threading
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wisp_core as core  # noqa: E402


def load_wav(path):
    w = wave.open(path)
    a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if w.getnchannels() > 1:
        a = a.reshape(-1, w.getnchannels()).mean(axis=1)
    if w.getframerate() != 16000:
        n = int(len(a) * 16000 / w.getframerate())
        a = np.interp(np.linspace(0, len(a) - 1, n), np.arange(len(a)), a).astype(np.float32)
    return a


# ---------------------------------------------------------------- test modes (no GUI)

def run_tests():
    args = sys.argv[1:]
    if args[0] == "--test":
        t = core.Transcriber()
        t0 = time.time(); t.load(); print(f"model on {t.device}, load {time.time() - t0:.1f}s")
        audio = load_wav(args[1])
        cat = args[2] if len(args) > 2 else "other"
        for i in range(2):
            t0 = time.time(); raw = t.transcribe(audio, core.vocabulary()); t1 = time.time()
            print(f"whisper {t1 - t0:.2f}s: {raw}")
        cleaned = core.clean(raw, None, cat, core.vocabulary())
        print(f"cleanup ({cat} / {core.style_for(cat)}) {time.time() - t1:.2f}s: {cleaned}")
    elif args[0] == "--test-call":
        src = args[1]
        work = os.path.join(core.CALLS_DIR, "test-" + dt.datetime.now().strftime("%H%M%S"))
        os.makedirs(work, exist_ok=True)
        for name in ("me", "them"):
            wav = os.path.join(src, name + ".wav")
            if os.path.exists(wav):
                load_wav(wav).tofile(os.path.join(work, name + ".raw"))
        core.settings.data["notes_folder"] = os.path.join(core.APP_DIR, "test-notes")  # not saved
        t = core.Transcriber()
        t0 = time.time()
        path = core.process_call(work, 75, "Zoom", t, status=lambda s: print("  ", s))
        print(f"notes in {time.time() - t0:.1f}s: {path}")
        print(open(path).read())
    elif args[0] == "--render-notes":
        md = open(args[1]).read()
        open(args[2], "w").write(core.notes_html(md, core.extract_title(md) or "Call Notes"))
    elif args[0] == "--check":
        t = core.Transcriber(); t.load()
        print("whisper on", t.device, "| model ready", core.model_ready(), "| key saved", bool(core.api_key()))
        print(subprocess.run(["pactl", "list", "short", "sources"], capture_output=True, text=True).stdout)
    return 0


if len(sys.argv) > 1 and sys.argv[1].startswith("--") and sys.argv[1] != "--gui":
    sys.exit(run_tests())

# ---------------------------------------------------------------- GUI

import cairo  # noqa: E402
import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("XApp", "1.0")
gi.require_version("WebKit2", "4.1")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, GLib, Gtk, Pango, PangoCairo, WebKit2, XApp  # noqa: E402
from pynput import keyboard  # noqa: E402
from Xlib import X, XK  # noqa: E402
from Xlib import display as xdisplay  # noqa: E402
from Xlib.ext import xtest  # noqa: E402

RED = (0xE1 / 255, 0x1D / 255, 0x3C / 255)
W_POINTS = [(26, 31), (38, 71), (50, 47), (62, 71), (74, 31)]
ICON_DIR = os.path.join(core.APP_DIR, "icons")
LAUNCHER = os.path.join(core.APP_DIR, "wisp-launch")
SOUNDS = "/usr/share/sounds/freedesktop/stereo/"


def play(name):
    path = SOUNDS + name
    if os.path.exists(path):
        subprocess.Popen(["paplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def draw_logo(cr, cx, cy, diameter, level=0.0, listening=False, thinking=False, t=0.0):
    unit = diameter / 100
    ox, oy = cx - diameter / 2, cy - diameter / 2
    if listening:  # glow
        cr.set_source_rgba(*RED, 0.35 + 0.35 * level)
        cr.arc(cx, cy, diameter / 2 + 2 + 3 * level, 0, 2 * math.pi)
        cr.fill()
    cr.set_source_rgb(*RED)
    cr.arc(cx, cy, diameter / 2, 0, 2 * math.pi)
    cr.fill()
    amp = 3 + 11 * level if listening else 0
    cr.set_source_rgb(1, 1, 1)
    cr.set_line_width(9 * unit)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    for i, (px, py) in enumerate(W_POINTS):
        dy = amp * math.sin(t * 14 + i * 1.15)
        (cr.move_to if i == 0 else cr.line_to)(ox + px * unit, oy + (py + dy) * unit)
    cr.stroke()
    if thinking:
        start = (t * 360) % 360
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.set_line_width(2)
        cr.arc(cx, cy, diameter / 2 + 1.5, math.radians(start), math.radians(start + 100))
        cr.stroke()


def make_icons():
    os.makedirs(ICON_DIR, exist_ok=True)
    for name, rec in (("wisp", False), ("wisp-rec", True)):
        s = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
        cr = cairo.Context(s)
        draw_logo(cr, 32, 32, 60)
        if rec:
            cr.set_source_rgb(1, 1, 1); cr.arc(52, 12, 11, 0, 2 * math.pi); cr.fill()
            cr.set_source_rgb(0.9, 0.05, 0.1); cr.arc(52, 12, 8, 0, 2 * math.pi); cr.fill()
        s.write_to_png(os.path.join(ICON_DIR, name + ".png"))


# ---------------------------------------------------------------- X11 helpers

_xd = None


def xd():
    global _xd
    if _xd is None:
        _xd = xdisplay.Display()
    return _xd


def _window_info(d, w):
    cls = w.get_wm_class() or ("", "")
    name = w.get_full_property(d.intern_atom("_NET_WM_NAME"), d.intern_atom("UTF8_STRING"))
    title = name.value.decode("utf-8", "replace") if name else (w.get_wm_name() or "")
    return (cls[1] or cls[0] or ""), title


def active_window():
    """(app class, window title) of the window you're typing in."""
    try:
        d = xd()
        prop = d.screen().root.get_full_property(d.intern_atom("_NET_ACTIVE_WINDOW"), X.AnyPropertyType)
        return _window_info(d, d.create_resource_object("window", prop.value[0]))
    except Exception:
        return "", ""


def all_windows():
    try:
        d = xd()
        prop = d.screen().root.get_full_property(d.intern_atom("_NET_CLIENT_LIST"), X.AnyPropertyType)
        return [_window_info(d, d.create_resource_object("window", wid)) for wid in prop.value]
    except Exception:
        return []


BROWSERS = ("firefox", "chrome", "chromium", "brave", "vivaldi", "opera", "edge", "librewolf")


def detect_call_app():
    for cls, title in all_windows():
        c, t = cls.lower(), title.lower()
        if "zoom" in c and ("meeting" in t or "webinar" in t):
            return "Zoom"
        if "slack" in c and "huddle" in t:
            return "Slack"
        if "teams" in c and ("meeting" in t or "call" in t):
            return "Microsoft Teams"
        if any(b in c for b in BROWSERS):
            if t.startswith("meet -") or "google meet" in t:
                return "Google Meet"
            if "zoom meeting" in t or "app.zoom.us" in t:
                return "Zoom"
            if "microsoft teams" in t and ("meeting" in t or "call" in t):
                return "Microsoft Teams"
            if "huddle" in t:
                return "Slack"
    return None


TERMINALS = ("terminal", "tilix", "kitty", "alacritty", "terminator", "konsole", "xterm", "urxvt",
             "wezterm", "guake", "tilda")


def send_paste(shift=False):
    d = xd()
    names = ["Control_L"] + (["Shift_L"] if shift else []) + ["v"]
    codes = [d.keysym_to_keycode(XK.string_to_keysym(n)) for n in names]
    for c in codes:
        xtest.fake_input(d, X.KeyPress, c)
    for c in reversed(codes):
        xtest.fake_input(d, X.KeyRelease, c)
    d.sync()


# ---------------------------------------------------------------- hotkey

class Hotkey:
    """Hold-to-talk. Pressing any other key while holding it cancels (you were using it as a modifier)."""

    def __init__(self, on_press, on_release, on_cancel):
        self.cb = (on_press, on_release, on_cancel)
        self.down = False
        self.cancelled = False
        self.listener = keyboard.Listener(on_press=self._press, on_release=self._release)
        self.listener.daemon = True
        self.listener.start()

    def keys(self):
        k = keyboard.Key
        return {k.alt_r, k.alt_gr} if core.settings["hotkey"] == "right_alt" else {k.ctrl_r}

    def _press(self, key):
        if key in self.keys():
            if not self.down:
                self.down, self.cancelled = True, False
                GLib.idle_add(self.cb[0])
        elif self.down and not self.cancelled:
            self.cancelled = True
            GLib.idle_add(self.cb[2])

    def _release(self, key):
        if key in self.keys() and self.down:
            self.down = False
            if not self.cancelled:
                GLib.idle_add(self.cb[1])


# ---------------------------------------------------------------- floating W widget

class Head(Gtk.Window):
    H = 48
    LOGO_W = 52

    def __init__(self, app):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.app = app
        self.mode = "idle"        # idle | listening | thinking
        self.level = 0.0
        self.anim_id = None
        self.drag = None
        self.set_app_paintable(True)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.set_keep_above(True)
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
                        | Gdk.EventMask.POINTER_MOTION_MASK)
        self.connect("draw", self.on_draw)
        self.connect("button-press-event", self.on_press)
        self.connect("button-release-event", self.on_release)
        self.connect("motion-notify-event", self.on_motion)
        self.width = 150
        self.set_default_size(self.width, self.H)
        self.resize(self.width, self.H)
        self.place()

    # -- text and size
    def label(self):
        a = self.app
        if a.setup:
            return a.setup
        if a.call_busy:
            return "Writing notes"
        if a.call_rec:
            s = a.call_seconds
            return f"Stop {s // 60}:{s % 60:02d}"
        return "Notes"

    def _layout(self, cr, text):
        layout = PangoCairo.create_layout(cr)
        layout.set_font_description(Pango.FontDescription("Sans Bold 9"))
        layout.set_text(text, -1)
        return layout

    def refresh(self):
        s = cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1)
        w = self._layout(cairo.Context(s), self.label()).get_pixel_size()[0]
        new_w = self.LOGO_W + 9 + 8 + 5 + w + 9 + 6
        if new_w != self.width:
            self.width = new_w
            self.resize(self.width, self.H)
        needs_anim = self.mode != "idle" or self.app.call_rec or self.app.call_busy or self.app.setup
        if needs_anim and not self.anim_id:
            self.anim_id = GLib.timeout_add(33, self._tick)
        self.queue_draw()

    def _tick(self):
        self.queue_draw()
        if self.mode == "idle" and not (self.app.call_rec or self.app.call_busy or self.app.setup):
            self.anim_id = None
            return False
        return True

    def place(self):
        pos = core.settings["head_pos"]
        geo = Gdk.Display.get_default().get_primary_monitor() or Gdk.Display.get_default().get_monitor(0)
        wa = geo.get_workarea()
        if pos and wa.x - 40 <= pos[0] <= wa.x + wa.width and wa.y - 40 <= pos[1] <= wa.y + wa.height:
            self.move(*pos)
        else:
            self.move(wa.x + wa.width // 2 - self.width // 2, wa.y + wa.height - self.H - 24)

    # -- drawing
    def on_draw(self, _w, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        w, h, r = self.width, self.H, self.H / 2 - 2
        self._rounded(cr, 1, 2, w - 2, h - 4, r)
        cr.set_source_rgba(0.11, 0.11, 0.11, 0.92)
        cr.fill_preserve()
        cr.set_source_rgba(1, 1, 1, 0.12)
        cr.set_line_width(1)
        cr.stroke()
        t = time.time()
        listening = self.mode == "listening"
        pulse = 0.90 + 0.10 * self.level if listening else 0.90
        draw_logo(cr, 8 + 18, h / 2, 36 * pulse, self.level, listening, self.mode == "thinking", t)

        a = self.app
        text = self.label()
        layout = self._layout(cr, text)
        tw, th = layout.get_pixel_size()
        px, pw, ph = self.LOGO_W + 4, 9 + 8 + 5 + tw + 9, 26
        py = (h - ph) / 2
        self._rounded(cr, px, py, pw, ph, ph / 2)
        cr.set_source_rgba(*(RED + (0.28,)) if a.call_rec else (1, 1, 1, 0.10))
        cr.fill()
        dx, dy = px + 9 + 4, h / 2
        if a.call_busy or a.setup:
            cr.set_source_rgba(1, 1, 1, 0.9)
            cr.set_line_width(1.6)
            s = (t * 360) % 360
            cr.arc(dx, dy, 4, math.radians(s), math.radians(s + 270))
            cr.stroke()
        else:
            blink = a.call_rec and int(t) % 2 == 1
            if a.call_rec:
                cr.set_source_rgba(1, 0.15, 0.2, 0.35 if blink else 1)
            else:
                cr.set_source_rgba(1, 1, 1, 0.55)
            cr.arc(dx, dy, 4, 0, 2 * math.pi)
            cr.fill()
        cr.set_source_rgb(1, 1, 1)
        cr.move_to(px + 9 + 8 + 5, (h - th) / 2)
        PangoCairo.show_layout(cr, layout)
        self.pill = (px, px + pw)

    @staticmethod
    def _rounded(cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    # -- mouse: click W = Style, drag W = move, click pill = Notes, right-click = menu
    def on_press(self, _w, e):
        if e.button == 3:
            m = Gtk.Menu()
            for label, fn in (("Style…", self.app.show_styles), ("Hide Floating W", lambda: self.app.set_head(False))):
                it = Gtk.MenuItem(label=label)
                it.connect("activate", lambda _i, f=fn: f())
                m.append(it)
            m.show_all()
            m.popup_at_pointer(e)
            return True
        if e.button == 1:
            x, y = self.get_position()
            self.drag = (e.x_root, e.y_root, x, y, False, e.x)
        return True

    def on_motion(self, _w, e):
        if self.drag:
            sx, sy, wx, wy, moved, ex = self.drag
            dx, dy = e.x_root - sx, e.y_root - sy
            if moved or abs(dx) > 3 or abs(dy) > 3:
                self.drag = (sx, sy, wx, wy, True, ex)
                self.move(int(wx + dx), int(wy + dy))
        return True

    def on_release(self, _w, e):
        if e.button != 1 or not self.drag:
            return True
        moved, ex = self.drag[4], self.drag[5]
        self.drag = None
        if moved:
            core.settings["head_pos"] = list(self.get_position())
        elif ex <= self.LOGO_W:
            self.app.show_styles()
        elif not (self.app.call_busy or self.app.setup):
            self.app.toggle_call()
        return True


# ---------------------------------------------------------------- Style window

STYLE_CSS = b"""
.wisp-styles { background: #fafafa; color: #1d1d1f; }
.wisp-h1 { font-size: 26px; font-weight: 600; }
.wisp-tab { background: none; border: none; border-bottom: 2px solid transparent; border-radius: 0;
            padding: 6px 2px; margin-right: 22px; color: #6e6e73; box-shadow: none; font-size: 14px; }
.wisp-tab.active { color: #1d1d1f; border-bottom-color: #1d1d1f; font-weight: 600; }
.wisp-banner { border-radius: 18px; padding: 24px 28px;
               background-image: linear-gradient(to right, #381a19, rgba(225,29,60,0.88), #403848); }
.wisp-banner-title { color: white; font-family: serif; font-size: 22px; }
.wisp-banner-apps { color: rgba(255,255,255,0.85); font-size: 13px; }
.wisp-card { background: white; border: 1px solid rgba(0,0,0,0.10); border-radius: 14px; padding: 18px;
             box-shadow: none; color: #1d1d1f; }
.wisp-card:hover { background: #fffafb; }
.wisp-card.selected { border: 2px solid #e11d3c; }
.wisp-card-title { font-size: 15px; font-weight: 500; }
.wisp-card-sub { font-size: 15px; color: #3a3a3c; }
.wisp-bubble { background: rgba(225,29,60,0.06); border-radius: 12px; padding: 14px; font-size: 14px; }
.wisp-check { color: white; background: #e11d3c; border-radius: 22px; min-width: 40px; min-height: 40px;
              font-weight: bold; font-size: 18px; }
.wisp-check.off { background: rgba(225,29,60,0.25); }
.wisp-foot { color: #6e6e73; font-size: 12px; }
"""


class StylesWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="Wisp Style")
        self.set_default_size(920, 640)
        self.set_icon_from_file(os.path.join(ICON_DIR, "wisp.png"))
        prov = Gtk.CssProvider()
        prov.load_from_data(STYLE_CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.tab = "personal"
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20, margin=32)
        outer = Gtk.EventBox()
        outer.get_style_context().add_class("wisp-styles")
        outer.add(self.box)
        self.add(outer)
        self.connect("delete-event", lambda *_: self.hide() or True)
        self.build()

    def build(self):
        for c in self.box.get_children():
            self.box.remove(c)
        h1 = Gtk.Label(label="Style", xalign=0)
        h1.get_style_context().add_class("wisp-h1")
        self.box.pack_start(h1, False, False, 0)

        tabs = Gtk.Box(spacing=0)
        for cat in core.CATEGORY_ORDER:
            b = Gtk.Button(label=core.CATEGORIES[cat]["title"])
            b.set_relief(Gtk.ReliefStyle.NONE)
            sc = b.get_style_context()
            sc.add_class("wisp-tab")
            if cat == self.tab:
                sc.add_class("active")
            b.connect("clicked", lambda _b, c=cat: self.select_tab(c))
            tabs.pack_start(b, False, False, 0)
        self.box.pack_start(tabs, False, False, 0)

        info = core.CATEGORIES[self.tab]
        banner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        banner.get_style_context().add_class("wisp-banner")
        t = Gtk.Label(label=info["banner"], xalign=0)
        t.get_style_context().add_class("wisp-banner-title")
        a = Gtk.Label(label=info["apps"], xalign=0)
        a.get_style_context().add_class("wisp-banner-apps")
        banner.pack_start(t, False, False, 0)
        banner.pack_start(a, False, False, 0)
        self.box.pack_start(banner, False, False, 0)

        cards = Gtk.Box(spacing=18, homogeneous=True)
        chosen = core.style_for(self.tab)
        for i, key in enumerate(core.STYLE_ORDER):
            title, sub, _ = core.STYLES[key]
            b = Gtk.Button()
            b.set_relief(Gtk.ReliefStyle.NONE)
            sc = b.get_style_context()
            sc.add_class("wisp-card")
            if key == chosen:
                sc.add_class("selected")
            v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            for text, cls in ((title, "wisp-card-title"), (sub, "wisp-card-sub")):
                l = Gtk.Label(label=text, xalign=0)
                l.get_style_context().add_class(cls)
                v.pack_start(l, False, False, 0)
            v.pack_start(Gtk.Box(), True, True, 30)
            bub = Gtk.Label(label=info["sample"][i], xalign=0, wrap=True, max_width_chars=28)
            bub.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
            bub.get_style_context().add_class("wisp-bubble")
            v.pack_start(bub, False, False, 0)
            chk = Gtk.Label(label="✓" if key == chosen else "W")
            chk.get_style_context().add_class("wisp-check")
            if key != chosen:
                chk.get_style_context().add_class("off")
            row = Gtk.Box()
            row.pack_end(chk, False, False, 0)
            v.pack_start(row, False, False, 8)
            b.add(v)
            b.set_size_request(-1, 340)
            b.connect("clicked", lambda _b, k=key: self.choose(k))
            cards.pack_start(b, True, True, 0)
        self.box.pack_start(cards, False, False, 0)

        foot = Gtk.Label(label="Wisp picks the style from the app you're dictating into. Spoken words stay the "
                               "same; only capitals and punctuation change.", xalign=0)
        foot.get_style_context().add_class("wisp-foot")
        self.box.pack_start(foot, False, False, 0)
        self.box.show_all()

    def select_tab(self, cat):
        self.tab = cat
        self.build()

    def choose(self, key):
        core.set_style(self.tab, key)
        self.build()


# ---------------------------------------------------------------- notes window

class NotesWindow(Gtk.Window):
    open_windows = {}

    @classmethod
    def show_file(cls, path):
        if path in cls.open_windows:
            cls.open_windows[path].present()
            return
        w = cls(path)
        cls.open_windows[path] = w
        w.show_all()
        w.present()

    def __init__(self, path):
        self.path = path
        self.md = open(path).read()
        title = core.extract_title(self.md) or "Call Notes"
        super().__init__(title=title)
        self.set_default_size(780, 860)
        self.set_icon_from_file(os.path.join(ICON_DIR, "wisp.png"))
        self.html = core.notes_html(self.md, title)
        hb = Gtk.HeaderBar(title=title, show_close_button=True)
        for label, icon, fn in (("Copy Notes", "edit-copy-symbolic", self.copy),
                                ("Open in Browser", "web-browser-symbolic", self.browser),
                                ("Show in Folder", "folder-symbolic", self.folder)):
            b = Gtk.Button()
            bx = Gtk.Box(spacing=6)
            bx.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON), False, False, 0)
            bx.pack_start(Gtk.Label(label=label), False, False, 0)
            b.add(bx)
            b.connect("clicked", lambda _b, f=fn: f())
            hb.pack_start(b)
        self.set_titlebar(hb)
        web = WebKit2.WebView()
        web.load_html(self.html, "file:///")
        self.add(web)
        self.connect("destroy", lambda *_: NotesWindow.open_windows.pop(self.path, None))

    def copy(self):
        notes = self.md.split("## Full Transcript")[0].rstrip().removesuffix("---").rstrip()
        cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        cb.set_text(notes, -1)
        cb.store()

    def browser(self):
        d = os.path.join(os.path.expanduser("~/.cache"), "wisp-notes-html")
        os.makedirs(d, exist_ok=True)
        out = os.path.join(d, os.path.splitext(os.path.basename(self.path))[0] + ".html")
        open(out, "w").write(self.html)
        subprocess.Popen(["xdg-open", out])

    def folder(self):
        if shutil.which("nemo"):
            subprocess.Popen(["nemo", self.path])
        else:
            subprocess.Popen(["xdg-open", os.path.dirname(self.path)])


# ---------------------------------------------------------------- the app

class App:
    def __init__(self):
        make_icons()
        self.transcriber = core.Transcriber()
        self.state = "idle"        # idle | recording | working
        self.note = None
        self.setup = None
        self.last_text = None
        self.recorder = None
        self.target = ("", "")
        self.pressed_at = 0
        self.call_rec = False
        self.call_busy = None
        self.call_seconds = 0
        self.call = None
        self.styles_window = None

        self.tray = XApp.StatusIcon()
        self.tray.set_name("wisp")
        self.tray.set_icon_name(os.path.join(ICON_DIR, "wisp.png"))
        self.head = Head(self)
        if core.settings["show_head"]:
            self.head.show_all()
        self.update()
        self.hotkey = Hotkey(self.on_press, self.on_release, self.on_cancel)

        if core.model_ready():
            threading.Thread(target=self._preload, daemon=True).start()
        else:
            self.start_download()
        if not core.api_key():
            GLib.timeout_add(1500, lambda: self.ask_key(first_run=True) and False)

    def _preload(self):
        try:
            self.transcriber.load()
        except Exception as e:
            core.log("model load failed:", e)
            GLib.idle_add(self.set_note, f"Speech model failed to load: {e}")
        GLib.idle_add(self.update)

    # ---- first-run model download
    def start_download(self):
        self.setup = "Setting up 0%"
        self.update()

        def work():
            try:
                core.download_model(lambda p: GLib.idle_add(self._setup_progress, p))
                GLib.idle_add(self._setup_done, None)
            except Exception as e:
                GLib.idle_add(self._setup_done, e)
        threading.Thread(target=work, daemon=True).start()

    def _setup_progress(self, p):
        self.setup = f"Setting up {p}%"
        self.head.refresh()

    def _setup_done(self, err):
        self.setup = None
        if err:
            self.set_note(f"Speech model download failed: {err}. Use Retry Model Download in the tray menu.")
        else:
            threading.Thread(target=self._preload, daemon=True).start()
        self.update()

    # ---- state display
    def set_note(self, text):
        self.note = text
        self.update()

    def update(self):
        self.head.refresh()
        rec = self.call_rec or self.state == "recording"
        self.tray.set_icon_name(os.path.join(ICON_DIR, "wisp-rec.png" if rec else "wisp.png"))
        key = "Right Alt" if core.settings["hotkey"] == "right_alt" else "Right Ctrl"
        self.tray.set_tooltip_text(f"Wisp: hold {key} to dictate")
        self.build_menu()

    def build_menu(self):
        m = Gtk.Menu()

        def item(label, fn=None, sensitive=True):
            it = Gtk.MenuItem(label=label)
            it.set_sensitive(sensitive and fn is not None)
            if fn:
                it.connect("activate", lambda *_: fn())
            m.append(it)
            return it

        def submenu(label, options, current, setter):
            it = Gtk.MenuItem(label=label)
            sub = Gtk.Menu()
            group = None
            for value, text in options:
                r = Gtk.RadioMenuItem(label=text, group=group)
                group = group or r
                r.set_active(value == current)
                r.connect("toggled", lambda w, v=value: w.get_active() and setter(v))
                sub.append(r)
            it.set_submenu(sub)
            m.append(it)
            return sub

        key = "Right Alt" if core.settings["hotkey"] == "right_alt" else "Right Ctrl"
        if self.setup:
            head = f"⬇ First-time setup: {self.setup}"
        elif self.state == "recording":
            head = "● Listening…"
        elif self.state == "working":
            head = "… Transcribing and cleaning up"
        else:
            dev = f" (speech on {self.transcriber.device})" if self.transcriber.device else ""
            head = f"Ready: hold {key} to dictate{dev}"
        item(head)
        if self.note:
            item("⚠ " + self.note)
        m.append(Gtk.SeparatorMenuItem())
        if self.call_rec:
            item(f"🔴 Recording call · {core.clock(self.call_seconds)}")
            item("Stop & Write Call Notes", self.stop_call)
            item("Discard This Recording", self.discard_call)
        elif self.call_busy:
            item("📝 " + self.call_busy)
        else:
            item("Start Call Notes", self.start_call if not self.setup else None)
        last = core.settings["last_notes"]
        if last and os.path.exists(last):
            item("Show Last Call Notes", lambda: NotesWindow.show_file(last))
        m.append(Gtk.SeparatorMenuItem())
        item("Copy Last Dictation", self.copy_last if self.last_text else None)
        item("Style…", self.show_styles)
        submenu("Dictation Key", [("right_ctrl", "Right Ctrl"), ("right_alt", "Right Alt")],
                core.settings["hotkey"], lambda v: self._set("hotkey", v))
        submenu("Cleanup", [("claude", "Claude (best cleanup)"), ("none", "No cleanup (raw Whisper text)")],
                core.settings["cleanup"], lambda v: self._set("cleanup", v))
        sub = submenu("Call Notes Settings", [("sonnet", "Claude Sonnet 5.5 (faster, cheaper)"),
                                              ("opus", "Claude Opus 5.5 (best notes)"),
                                              ("none", "Transcript only (fully private)")],
                      core.settings["summary"], lambda v: self._set("summary", v))
        sub.append(Gtk.SeparatorMenuItem())
        for label, fn in (("Choose Notes Folder…", self.choose_folder),
                          ("Open Notes Folder", lambda: self._open(core.settings["notes_folder"])),
                          ("Open Call Recordings", lambda: self._open(core.CALLS_DIR))):
            it = Gtk.MenuItem(label=label)
            it.connect("activate", lambda *_, f=fn: f())
            sub.append(it)
        item("Change Anthropic API Key…" if core.api_key() else "Set Anthropic API Key… (needed for Claude)",
             lambda: self.ask_key(False))
        item("Edit Vocabulary…", lambda: (core.vocabulary(), self._open(core.VOCAB_PATH)))
        item("Open Dictation History", lambda: self._open(core.HISTORY_PATH)
             if os.path.exists(core.HISTORY_PATH) else None)
        if not core.model_ready() and not self.setup:
            item("Retry Model Download", self.start_download)
        m.append(Gtk.SeparatorMenuItem())
        c = Gtk.CheckMenuItem(label="Show Floating W")
        c.set_active(core.settings["show_head"])
        c.connect("toggled", lambda w: self.set_head(w.get_active()))
        m.append(c)
        c2 = Gtk.CheckMenuItem(label="Start at Login")
        c2.set_active(os.path.exists(AUTOSTART))
        c2.connect("toggled", lambda w: set_autostart(w.get_active()))
        m.append(c2)
        m.append(Gtk.SeparatorMenuItem())
        item("Quit Wisp", self.quit)
        m.show_all()
        self.tray.set_primary_menu(m)
        self.tray.set_secondary_menu(m)
        self.menu = m

    def _set(self, k, v):
        core.settings[k] = v
        self.update()

    def _open(self, path):
        if path:
            os.makedirs(path if not os.path.splitext(path)[1] else os.path.dirname(path), exist_ok=True)
            subprocess.Popen(["xdg-open", path])

    def set_head(self, show):
        core.settings["show_head"] = show
        self.head.show_all() if show else self.head.hide()
        self.update()

    def show_styles(self):
        if not self.styles_window:
            self.styles_window = StylesWindow()
        self.styles_window.build()
        self.styles_window.show_all()
        self.styles_window.present()

    def copy_last(self):
        cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        cb.set_text(self.last_text, -1)
        cb.store()

    def choose_folder(self):
        d = Gtk.FileChooserDialog(title="Save call notes in…", action=Gtk.FileChooserAction.SELECT_FOLDER)
        d.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Choose", Gtk.ResponseType.OK)
        d.set_current_folder(core.settings["notes_folder"] if os.path.isdir(core.settings["notes_folder"])
                             else os.path.expanduser("~"))
        if d.run() == Gtk.ResponseType.OK:
            core.settings["notes_folder"] = d.get_filename()
        d.destroy()
        self.update()

    def ask_key(self, first_run):
        d = Gtk.Dialog(title="Welcome to Wisp" if first_run else "Anthropic API Key", modal=True)
        d.set_icon_from_file(os.path.join(ICON_DIR, "wisp.png"))
        d.add_buttons("Skip for Now" if first_run else "Cancel", Gtk.ResponseType.CANCEL,
                      "Save", Gtk.ResponseType.OK)
        d.set_default_response(Gtk.ResponseType.OK)
        box = d.get_content_area()
        box.set_spacing(10)
        box.set_margin_start(18); box.set_margin_end(18); box.set_margin_top(14); box.set_margin_bottom(10)
        text = ("Wisp uses Claude to clean up your dictation and write call notes. Paste your Anthropic API key "
                "(it starts with sk-ant-). It's stored in this computer's keyring.\n\nYou can skip this and use "
                "Wisp without cleanup, then add a key later from the tray menu."
                if first_run else "Paste your Anthropic API key (it starts with sk-ant-).")
        lab = Gtk.Label(label=text, xalign=0, wrap=True, max_width_chars=60)
        entry = Gtk.Entry(visibility=False, activates_default=True, width_chars=50)
        entry.set_placeholder_text("sk-ant-…")
        box.pack_start(lab, False, False, 0)
        box.pack_start(entry, False, False, 0)
        d.show_all()
        resp = d.run()
        key = entry.get_text().strip()
        d.destroy()
        if resp != Gtk.ResponseType.OK or not key:
            return
        if not core.save_api_key(key):
            self.message("Couldn't save the key in the keyring.")
            return

        def check():
            ok, msg = core.validate_key(key)
            GLib.idle_add(self.message, msg)
            GLib.idle_add(self.update)
        threading.Thread(target=check, daemon=True).start()

    def message(self, text):
        d = Gtk.MessageDialog(message_type=Gtk.MessageType.INFO, buttons=Gtk.ButtonsType.OK, text=text)
        d.run()
        d.destroy()

    # ---- dictation
    def on_press(self):
        if self.state != "idle":
            return
        if self.setup or not core.model_ready():
            self.set_note("Wait for first-time setup to finish.")
            return
        self.target = active_window()
        self.recorder = core.Recorder(on_level=lambda l: GLib.idle_add(self._level, l))
        try:
            self.recorder.start()
        except Exception as e:
            self.set_note(f"Microphone error: {e}")
            return
        self.pressed_at = time.time()
        self.state = "recording"
        self.head.mode = "listening"
        play("audio-volume-change.oga")
        self.update()

    def _level(self, l):
        if self.state == "recording":
            self.head.level = self.head.level * 0.5 + l * 0.5

    def on_cancel(self):
        if self.state == "recording":
            self.recorder.stop()
            self._idle()

    def _idle(self):
        self.state = "idle"
        self.head.mode = "idle"
        self.head.level = 0
        self.update()

    def on_release(self):
        if self.state != "recording":
            return
        audio = self.recorder.stop()
        secs = len(audio) / 16000
        # Ignore taps and silence (Whisper invents words like "Thank you." from silence).
        if time.time() - self.pressed_at < 0.35 or secs < 0.3 or core.rms(audio) < 0.002:
            self._idle()
            return
        self.state = "working"
        self.head.mode = "thinking"
        self.update()
        cls, title = self.target
        category = core.classify(cls, title)
        threading.Thread(target=self._work, args=(audio, secs, cls, category), daemon=True).start()

    def _work(self, audio, secs, app, category):
        vocab = core.vocabulary()
        try:
            raw = self.transcriber.transcribe(audio, vocab)
        except Exception as e:
            GLib.idle_add(self.set_note, f"Transcription failed: {e}")
            GLib.idle_add(self._idle)
            return
        if not raw:
            GLib.idle_add(self._idle)
            return
        note = None
        try:
            text = core.clean(raw, app, category, vocab) or raw
        except Exception as e:
            text, note = raw, f"Cleanup failed, pasted raw text: {e}"
        core.history_append(raw, text, app, core.settings["cleanup"], secs, note)
        GLib.idle_add(self._paste, text, note, app)

    def _paste(self, text, note, app):
        self.last_text = text
        self.note = note
        cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        prev = cb.wait_for_text()
        cb.set_text(text, -1)
        cb.store()
        shift = any(t in (app or "").lower() for t in TERMINALS)
        GLib.timeout_add(60, lambda: send_paste(shift) and False)
        if prev is not None:
            GLib.timeout_add(900, lambda: (cb.set_text(prev, -1), cb.store()) and False)
        self._idle()

    # ---- call notes
    def toggle_call(self):
        self.stop_call() if self.call_rec else self.start_call()

    def start_call(self):
        if self.call_rec or self.call_busy:
            return
        folder = os.path.join(core.CALLS_DIR, dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S"))
        os.makedirs(folder, exist_ok=True)
        me = core.Recorder("@DEFAULT_SOURCE@", os.path.join(folder, "me.raw"))
        them = core.Recorder("@DEFAULT_MONITOR@", os.path.join(folder, "them.raw"))
        me.start()
        them.start()
        self.call = {"folder": folder, "me": me, "them": them, "start": time.time(), "app": detect_call_app()}
        self.call_rec, self.call_seconds, self.note = True, 0, None
        GLib.timeout_add(1000, self._call_tick)
        play("message.oga")
        self.update()

    def _call_tick(self):
        if not self.call_rec:
            return False
        self.call_seconds = int(time.time() - self.call["start"])
        if not (self.call["me"].running and self.call["them"].running):
            self.set_note("A recording stream stopped unexpectedly; check your sound settings.")
        self.update()
        return True

    def _end_recording(self):
        c = self.call
        c["me"].stop()
        c["them"].stop()
        self.call_rec = False
        return c

    def discard_call(self):
        if self.call_rec:
            c = self._end_recording()
            shutil.rmtree(c["folder"], ignore_errors=True)
            self.update()

    def stop_call(self):
        if not self.call_rec:
            return
        c = self._end_recording()
        duration = time.time() - c["start"]
        app = c["app"] or detect_call_app()
        self.call_busy = "Transcribing…"
        self.update()

        def work():
            try:
                path = core.process_call(c["folder"], duration, app, self.transcriber,
                                         status=lambda s: GLib.idle_add(self._busy, s))
                GLib.idle_add(self._call_done, path, None)
            except Exception as e:
                core.log("call notes failed:", e)
                GLib.idle_add(self._call_done, None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def _busy(self, s):
        self.call_busy = s
        self.update()

    def _call_done(self, path, err):
        self.call_busy = None
        if path:
            core.settings["last_notes"] = path
            play("complete.oga")
            NotesWindow.show_file(path)
        else:
            play("dialog-warning.oga")
            self.note = err
        self.update()

    def quit(self):
        if self.call_rec:
            self._end_recording()
        if self.recorder:
            self.recorder.stop()
        Gtk.main_quit()


AUTOSTART = os.path.expanduser("~/.config/autostart/wisp.desktop")
DESKTOP_ENTRY = f"""[Desktop Entry]
Type=Application
Name=Wisp
Comment=Hold-to-talk dictation and call notes
Exec={LAUNCHER}
Icon={os.path.join(ICON_DIR, "wisp.png")}
Terminal=false
Categories=Utility;AudioVideo;
X-GNOME-Autostart-enabled=true
"""


def set_autostart(on):
    if on:
        os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
        open(AUTOSTART, "w").write(DESKTOP_ENTRY)
    elif os.path.exists(AUTOSTART):
        os.remove(AUTOSTART)


def main():
    os.makedirs(core.APP_DIR, exist_ok=True)
    lock = open(os.path.join(core.APP_DIR, "wisp.lock"), "w")
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Wisp is already running.")
        return
    core.log("Wisp starting")
    App()
    Gtk.main()


if __name__ == "__main__":
    main()
