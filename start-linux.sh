#!/bin/bash
# Odysseus — one-command quick start for Linux.
#
#   ./start-linux.sh
#
# Checks Linux dependencies, sets up a local Python environment,
# and launches the app. Safe to re-run; skips completed work.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Load .env variables if available
if [ -f .env ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [ -n "$key" ] && [ -z "${!key+x}" ] && export "$key=$value"
    done < .env
fi

PORT="${ODYSSEUS_PORT:-${APP_PORT:-7860}}"
HOST="${ODYSSEUS_HOST:-${APP_BIND:-127.0.0.1}}"
PROBE_HOST="$HOST"
if [ "$PROBE_HOST" = "0.0.0.0" ] || [ "$PROBE_HOST" = "::" ]; then
    PROBE_HOST="127.0.0.1"
fi

# Trap failure to display a friendly re-run tip
trap 'echo; echo "✗ Setup failed above. It is safe to re-run ./start-linux.sh."; exit 1' ERR

echo "▶ Odysseus quick start for Linux"

# Fail fast if port is in use
if (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null; then
    echo "✗ Port $PORT is already in use on $PROBE_HOST. Stop what's using it, or pick another port:"
    echo "    ODYSSEUS_PORT=7900 ./start-linux.sh"
    exit 1
fi

# Distro detection for helpful package recommendations
pkg_mgr=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID_LIKE" == *"ubuntu"* || "$ID" == "debian" || "$ID_LIKE" == *"debian"* ]]; then
        pkg_mgr="apt"
    elif [[ "$ID" == "fedora" || "$ID_LIKE" == *"fedora"* || "$ID" == "rhel" || "$ID_LIKE" == *"rhel"* || "$ID" == "centos" || "$ID_LIKE" == *"centos"* ]]; then
        pkg_mgr="dnf"
    elif [[ "$ID" == "arch" || "$ID_LIKE" == *"arch"* ]]; then
        pkg_mgr="pacman"
    fi
fi

echo "▶ Checking dependencies..."
PY=""
cands="python3 python3.13 python3.12 python3.11"
for cand in $cands; do
    p="$(command -v "$cand" 2>/dev/null)" || continue
    if "$p" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
        PY="$p"; break
    fi
done

if [ -n "$PY" ]; then
    echo "  ✓ Python found: $("$PY" --version 2>&1) at $PY"
else
    echo "✗ Couldn't find a Python 3.11+ interpreter."
    if [ "$pkg_mgr" = "apt" ]; then
        echo "  Install it with:  sudo apt update && sudo apt install python3 python3-pip python3-venv"
    elif [ "$pkg_mgr" = "dnf" ]; then
        echo "  Install it with:  sudo dnf install python3 python3-pip"
    elif [ "$pkg_mgr" = "pacman" ]; then
        echo "  Install it with:  sudo pacman -S python python-pip"
    else
        echo "  Please install Python 3.11+ and its venv/pip packages."
    fi
    exit 1
fi

# Check for tmux
if command -v tmux >/dev/null 2>&1; then
    echo "  ✓ tmux already installed"
else
    echo "  ⚠ tmux is missing. Cookbook (local model serving) requires tmux."
    if [ "$pkg_mgr" = "apt" ]; then
        echo "    Install with:   sudo apt install tmux"
    elif [ "$pkg_mgr" = "dnf" ]; then
        echo "    Install with:   sudo dnf install tmux"
    elif [ "$pkg_mgr" = "pacman" ]; then
        echo "    Install with:   sudo pacman -S tmux"
    else
        echo "    Please install tmux via your package manager."
    fi
fi

# Check for llama-server
if command -v llama-server >/dev/null 2>&1; then
    echo "  ✓ llama-server already installed"
else
    echo "  ℹ llama-server is not in PATH. This is fine: you can serve models via Ollama"
    echo "    or download/build llama.cpp manually to serve local models on GPU."
fi

# Python environment + dependencies setup
if [ ! -d venv ]; then
    echo "▶ Creating Python environment…"
    if ! "$PY" -m venv venv 2>/dev/null; then
        echo "✗ Failed to create venv. You might need to install python3-venv:"
        if [ "$pkg_mgr" = "apt" ]; then
            echo "  sudo apt install python3-venv"
        else
            echo "  Please install the python3-venv package for your distribution."
        fi
        exit 1
    fi
fi

VENV_PY="./venv/bin/python3"
REQ_HASH=""
if command -v md5sum >/dev/null 2>&1; then
    REQ_HASH="$(md5sum requirements.txt | cut -d' ' -f1)"
fi
REQ_HASH_FILE="venv/.requirements_hash"
if [ ! -f "$REQ_HASH_FILE" ] || [ "$REQ_HASH" != "$(cat "$REQ_HASH_FILE" 2>/dev/null)" ]; then
    echo "▶ Installing Python packages (first run downloads a few — can take a few minutes)…"
    "$VENV_PY" -m pip install --quiet --upgrade pip
    "$VENV_PY" -m pip install -r requirements.txt
    echo "$REQ_HASH" > "$REQ_HASH_FILE"
else
    echo "▶ Python packages up to date — skipping install"
fi

# Clean up conflicting chromadb-client if present
if "$VENV_PY" -m pip show chromadb-client >/dev/null 2>&1; then
    echo "▶ Cleaning up conflicting chromadb-client package…"
    "$VENV_PY" -m pip uninstall -y chromadb-client
    "$VENV_PY" -m pip install --force-reinstall chromadb
fi

# Run database/setup migrations
echo "▶ Preparing Odysseus..."
ODYSSEUS_SKIP_RUN_HINT=1 ./venv/bin/python setup.py

# Launch URL preparation
URL_HOST="$HOST"
if [ "$URL_HOST" = "0.0.0.0" ] || [ "$URL_HOST" = "::" ]; then
    URL_HOST="127.0.0.1"
fi
URL="http://$URL_HOST:$PORT"

TAILSCALE_URL=""
if [ "$HOST" = "0.0.0.0" ] && command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -n "$TS_IP" ]; then
        TAILSCALE_URL="http://$TS_IP:$PORT"
    fi
fi

# Auto-open browser when ready
POLLER_PID=""
if [ -z "$ODYSSEUS_NO_OPEN" ] && command -v xdg-open >/dev/null 2>&1; then
    (
        for _ in $(seq 1 90); do
            if (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null; then
                printf '\n'
                printf '  ┌────────────────────────────────────────────┐\n'
                printf '  │  ✓ Odysseus is ready — opening your browser  │\n'
                printf '  │     %-40s │\n' "$URL"
                printf '  │     (Press Ctrl+C in this window to stop)    │\n'
                printf '  └────────────────────────────────────────────┘\n\n'
                xdg-open "$URL"
                break
            fi
            sleep 1
        done
    ) &
    POLLER_PID=$!
fi

# Hand over to uvicorn
trap - ERR
trap '[ -n "$POLLER_PID" ] && kill "$POLLER_PID" 2>/dev/null' EXIT INT TERM

echo
echo "▶ Starting Odysseus — it will open in your browser at $URL"
if [ -n "$TAILSCALE_URL" ]; then
    echo "  Tailscale/LAN URL: $TAILSCALE_URL"
fi
echo "  (this takes a few seconds; press Ctrl+C here to stop)"
echo
"$VENV_PY" -m uvicorn app:app --host "$HOST" --port "$PORT"
