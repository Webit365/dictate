#!/bin/bash
# Installs (or updates) Wisp for Linux Mint / Cinnamon into your user account. No sudo needed.
#   curl -fsSL https://raw.githubusercontent.com/Webit365/dictate/main/linux/install.sh | bash
# or, from a copy of the repo:  bash linux/install.sh
set -euo pipefail

D="$HOME/.local/share/wisp"
RAW="https://raw.githubusercontent.com/Webit365/dictate/main/linux"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

say() { printf '\033[1;31mW\033[0m %s\n' "$*"; }

# 1. Checks
[ "$(uname -m)" = "x86_64" ] || { say "Wisp for Linux needs a 64-bit PC (x86_64)."; exit 1; }
command -v parec >/dev/null || { say "Missing parec. Run: sudo apt install pulseaudio-utils"; exit 1; }
python3 -c "import gi; gi.require_version('Gtk','3.0'); gi.require_version('XApp','1.0'); gi.require_version('WebKit2','4.1')" 2>/dev/null \
  || { say "Missing desktop libraries. Run: sudo apt install python3-gi gir1.2-xapp-1.0 gir1.2-webkit2-4.1"; exit 1; }
python3 -m venv --help >/dev/null 2>&1 || { say "Missing venv. Run: sudo apt install python3-venv"; exit 1; }
[ "${XDG_SESSION_TYPE:-x11}" = "wayland" ] && say "Note: Wisp needs an X11 session (Mint's default Cinnamon session is fine)."

# 2. Python environment (speech model runs on an NVIDIA GPU when there is one)
mkdir -p "$D/app"
if [ ! -x "$D/venv/bin/python" ]; then
  say "Creating Python environment…"
  python3 -m venv --system-site-packages "$D/venv"
fi
say "Installing speech engine (first time downloads about 2.5 GB)…"
"$D/venv/bin/pip" install -q --upgrade pip
PKGS="faster-whisper pynput python-xlib"
if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  PKGS="$PKGS nvidia-cublas-cu12 nvidia-cudnn-cu12==9.*"
  say "NVIDIA GPU found: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
fi
"$D/venv/bin/pip" install -q $PKGS

# 3. App files
for f in wisp.py wisp_core.py; do
  if [ -n "$HERE" ] && [ -f "$HERE/$f" ]; then cp "$HERE/$f" "$D/app/$f"
  else curl -fsSL "$RAW/$f" -o "$D/app/$f"; fi
done

cat > "$D/wisp-launch" <<'EOF'
#!/bin/bash
# Starts Wisp with the NVIDIA libraries from its Python environment on the library path.
D="$HOME/.local/share/wisp"
NV=$(ls -d "$D"/venv/lib/python3*/site-packages/nvidia/*/lib 2>/dev/null | tr '\n' ':')
export LD_LIBRARY_PATH="${NV}${LD_LIBRARY_PATH:-}"
if [ $# -eq 0 ]; then exec >>"$D/wisp.log" 2>&1; fi   # normal runs log to a file; test modes print
exec "$D/venv/bin/python" "$D/app/wisp.py" "$@"
EOF
chmod +x "$D/wisp-launch"

# 4. Menu entry and start at login
mkdir -p "$HOME/.local/share/applications" "$HOME/.config/autostart" "$D/icons"
ENTRY="[Desktop Entry]
Type=Application
Name=Wisp
Comment=Hold-to-talk dictation and call notes
Exec=$D/wisp-launch
Icon=$D/icons/wisp.png
Terminal=false
Categories=Utility;AudioVideo;
X-GNOME-Autostart-enabled=true"
echo "$ENTRY" > "$HOME/.local/share/applications/wisp.desktop"
[ -f "$HOME/.config/autostart/wisp.desktop" ] || echo "$ENTRY" > "$HOME/.config/autostart/wisp.desktop"

# 5. (Re)start it
pkill -f "$D/app/wisp.py" 2>/dev/null || true
sleep 1
if [ -n "${DISPLAY:-}" ]; then
  nohup "$D/wisp-launch" >/dev/null 2>&1 &
  say "Wisp is running: look for the red W in the panel and at the bottom of the screen."
else
  say "Installed. Start Wisp from the menu (or log out and back in)."
fi
say "Hold Right Ctrl to dictate. Click the W for Style, Notes to record a call."
