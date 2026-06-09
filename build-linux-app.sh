#!/bin/bash
# Build a desktop application shortcut for Odysseus on Linux.
#
#   ./build-linux-app.sh
#
# Creates:
#   dist/odysseus.png          — Application icon (cropped and scaled).
#   dist/odysseus-launcher.sh   — Starts uvicorn server in background and launches chromeless browser window.
#   dist/odysseus.desktop      — The desktop entry configuration file.
#
# Installs:
#   ~/.local/share/applications/odysseus.desktop — Symlink or copy to register with system menu.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Odysseus"
INSTALL_DIR="$REPO_DIR"
PORT="${ODYSSEUS_PORT:-7860}"
DIST="$REPO_DIR/dist"

echo "Building $APP_NAME Linux Desktop Shortcut"
echo "  Install directory: $INSTALL_DIR"
echo "  Port:              $PORT"

mkdir -p "$DIST"

# 1. Icon Crop & Convert from JPEG to PNG
ICON_JPG="$REPO_DIR/docs/odysseus.jpg"
ICON_PNG="$DIST/odysseus.png"

if [ -f "$ICON_JPG" ]; then
    echo "▶ Building app icon..."
    VENV_PY="$REPO_DIR/venv/bin/python3"
    if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import PIL" 2>/dev/null; then
        "$VENV_PY" -c "
import sys, os
from PIL import Image
im = Image.open('$ICON_JPG')
w, h = im.size
sz = min(w, h)
left = (w - sz) // 2
top = (h - sz) // 2
im = im.crop((left, top, left + sz, top + sz)).resize((512, 512), Image.Resampling.LANCZOS)
im.save('$ICON_PNG', 'PNG')
" && echo "  ✓ Generated PNG icon using Python Pillow" || cp "$ICON_JPG" "$ICON_PNG"
    elif command -v convert >/dev/null 2>&1; then
        convert "$ICON_JPG" -gravity center -crop 1:1 +repage -resize 512x512 "$ICON_PNG" && echo "  ✓ Generated PNG icon using ImageMagick" || cp "$ICON_JPG" "$ICON_PNG"
    else
        echo "  ⚠ Python Pillow and ImageMagick not found. Copying JPEG directly."
        cp "$ICON_JPG" "$ICON_PNG"
    fi
else
    echo "  ⚠ App icon docs/odysseus.jpg not found. Skipping icon packaging."
fi

# 2. Launcher Template
cat > "$DIST/odysseus-launcher.tmpl" <<'LAUNCHER'
#!/bin/bash
# Odysseus Linux Launcher — Starts local backend server and opens app in a desktop window.
INSTALL_DIR="__INSTALL_DIR__"
PORT="__PORT__"
URL="http://127.0.0.1:${PORT}"

UVICORN="$INSTALL_DIR/venv/bin/uvicorn"
LOG="$INSTALL_DIR/logs/odysseus-app.log"

notify() {
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Odysseus" "$1"
    fi
}

die_gui() {
    local msg="$1"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Odysseus" --text="$msg" --width=400
    elif command -v kdialog >/dev/null 2>&1; then
        kdialog --title "Odysseus" --error "$msg"
    elif command -v gxmessage >/dev/null 2>&1; then
        gxmessage -title "Odysseus" "$msg"
    else
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -a "Odysseus" -u critical "Odysseus Error" "$msg"
        fi
        echo "ERROR: $msg" >&2
    fi
    exit 1
}

# Verify venv/uvicorn is ready
[ -x "$UVICORN" ] || die_gui "Odysseus isn't set up yet. Open a terminal, cd into the install folder, and run:
./start-linux.sh"

mkdir -p "$INSTALL_DIR/logs"

# Search and open in app (chromeless) mode using any available Chromium-based browser.
open_ui() {
    local b
    for b in "google-chrome" "google-chrome-stable" "chrome" "brave-browser" "brave" "microsoft-edge" "microsoft-edge-stable" "chromium-browser" "chromium" "epiphany"; do
        if command -v "$b" >/dev/null 2>&1; then
            if [ "$b" = "epiphany" ]; then
                "$b" --application-mode="$URL" >/dev/null 2>&1 &
            else
                "$b" --app="$URL" --new-window >/dev/null 2>&1 &
            fi
            return 0
        fi
    done
    
    # Fallback to system default browser
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL"
        return 0
    fi
    die_gui "No browser or xdg-open found to open Odysseus."
}

# If uvicorn is already running, just open the interface.
if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null --max-time 2 "$URL"; then
        open_ui
        exit 0
    fi
fi

notify "Starting Odysseus..."
cd "$INSTALL_DIR" || die_gui "Install directory not found: $INSTALL_DIR"

"$UVICORN" app:app --host 127.0.0.1 --port "$PORT" >>"$LOG" 2>&1 &
SERVER_PID=$!

# Terminate server process on script exit
trap 'kill $SERVER_PID 2>/dev/null; exit 0' TERM INT EXIT

# Wait for server readiness
READY=0
for i in $(seq 1 120); do
    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null --max-time 2 "$URL" && { READY=1; break; }
    else
        # Fallback if curl is not installed
        if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
            READY=1
            break
        fi
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || die_gui "Odysseus failed to start. See log: $LOG"
    sleep 1
done

if [ "$READY" = "1" ]; then
    open_ui
else
    notify "Odysseus is taking a while to load. You can try opening $URL in your browser manually."
fi

wait "$SERVER_PID"
LAUNCHER

# 3. Process Launcher Script
sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__PORT__|$PORT|g" \
    "$DIST/odysseus-launcher.tmpl" > "$DIST/odysseus-launcher.sh"
rm -f "$DIST/odysseus-launcher.tmpl"
chmod +x "$DIST/odysseus-launcher.sh"
echo "  ✓ Generated launcher script: $DIST/odysseus-launcher.sh"

# 4. Generate Desktop Entry File
DESKTOP_FILE="$DIST/odysseus.desktop"
cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Odysseus
Comment=Self-hosted AI workspace
Exec=$DIST/odysseus-launcher.sh
Icon=$DIST/odysseus.png
Terminal=false
Categories=Utility;Development;
StartupNotify=true
DESKTOP

# 5. Install Desktop File
USER_APP_DIR="$HOME/.local/share/applications"
mkdir -p "$USER_APP_DIR"
cp "$DESKTOP_FILE" "$USER_APP_DIR/odysseus.desktop"
chmod +x "$USER_APP_DIR/odysseus.desktop"

# Refresh desktop launcher database
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$USER_APP_DIR" || true
fi

echo "  ✓ Installed desktop entry: $USER_APP_DIR/odysseus.desktop"
echo
echo "Successfully turned Odysseus into a Linux desktop application!"
echo "You can now launch Odysseus from your desktop application launcher / menu."
echo
