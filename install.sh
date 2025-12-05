#!/usr/bin/env bash
set -e

APP_USER=${SUDO_USER:-$USER}

BASE_DIR="/opt/nexus"
BACKEND_DIR="$BASE_DIR/backend"
FRONTEND_DIR="$BASE_DIR/frontend"
CONFIG_DIR="$BASE_DIR/config"
SERVICE_NAME="nexus"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

TMP_BACKUP_DIR="/tmp/nexus_backup_$$"

REPO_OWNER="flicky1155"
REPO_NAME="Selfbondage"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

# Decide whether to use sudo
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: Please run as root or install sudo."
    exit 1
  fi
fi

# Curl helper (optionally with GitHub token for private repo)
CURL="curl -fsSL"
if [ -n "$GITHUB_TOKEN" ]; then
  CURL="$CURL -H Authorization: token $GITHUB_TOKEN"
fi

echo "======================================="
echo " Nexus – Installer / Updater"
echo "======================================="

echo "[1/7] Backing up config/session (if any)..."
mkdir -p "$TMP_BACKUP_DIR"
if [ -f "$CONFIG_DIR/config.json" ]; then
  cp "$CONFIG_DIR/config.json" "$TMP_BACKUP_DIR/config.json" || true
  echo " - Backed up config.json"
fi
if [ -f "$CONFIG_DIR/session.json" ]; then
  cp "$CONFIG_DIR/session.json" "$TMP_BACKUP_DIR/session.json" || true
  echo " - Backed up session.json"
fi

echo "[2/7] Installing system dependencies..."
$SUDO apt update -y
$SUDO apt install -y python3 python3-venv python3-pip curl

echo "[3/7] Resetting install directory..."
$SUDO rm -rf "$BASE_DIR"
$SUDO mkdir -p "$BACKEND_DIR"
$SUDO mkdir -p "$FRONTEND_DIR/templates"
$SUDO mkdir -p "$FRONTEND_DIR/static/css"
$SUDO mkdir -p "$FRONTEND_DIR/static/js"
$SUDO mkdir -p "$CONFIG_DIR"

echo "[4/7] Creating Python virtual environment..."
cd "$BASE_DIR"
$SUDO python3 -m venv "$BASE_DIR/venv"
# shellcheck disable=SC1091
source "$BASE_DIR/venv/bin/activate"
pip install --upgrade pip
pip install flask requests

echo "[5/7] Downloading backend & frontend from GitHub..."

# --- Backend ---
$CURL "${RAW_BASE}/backend/app.py" -o "$BACKEND_DIR/app.py"

# --- Templates ---
$CURL "${RAW_BASE}/frontend/templates/index.html"   -o "$FRONTEND_DIR/templates/index.html"
$CURL "${RAW_BASE}/frontend/templates/settings.html" -o "$FRONTEND_DIR/templates/settings.html"
$CURL "${RAW_BASE}/frontend/templates/videos.html"   -o "$FRONTEND_DIR/templates/videos.html"
$CURL "${RAW_BASE}/frontend/templates/bridge.html"   -o "$FRONTEND_DIR/templates/bridge.html"

# --- Static assets ---
$CURL "${RAW_BASE}/frontend/static/css/style.css" -o "$FRONTEND_DIR/static/css/style.css"
$CURL "${RAW_BASE}/frontend/static/js/main.js"   -o "$FRONTEND_DIR/static/js/main.js"

echo "[6/7] Installing systemd service file..."
if $CURL "${RAW_BASE}/systemd/nexus.service" -o /tmp/nexus.service; then
  $SUDO mv /tmp/nexus.service "$SERVICE_FILE"
else
  echo "WARNING: Could not download systemd/nexus.service from GitHub."
  echo "Using built-in default service definition."
  $SUDO bash -c "cat > '$SERVICE_FILE'" <<EOF
[Unit]
Description=Nexus
After=network.target

[Service]
User=${APP_USER}
WorkingDirectory=${BASE_DIR}
Environment=NEXUS_PORT=8080
Environment=PATH=${BASE_DIR}/venv/bin
ExecStart=${BASE_DIR}/venv/bin/python backend/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

echo "[6.1/7] Restoring config/session backups (if any)..."
if [ -f "$TMP_BACKUP_DIR/config.json" ]; then
  cp "$TMP_BACKUP_DIR/config.json" "$CONFIG_DIR/config.json"
  echo " - Restored config.json"
fi
if [ -f "$TMP_BACKUP_DIR/session.json" ]; then
  cp "$TMP_BACKUP_DIR/session.json" "$CONFIG_DIR/session.json"
  echo " - Restored session.json"
fi
rm -rf "$TMP_BACKUP_DIR"

echo "[6.2/7] Setting ownership..."
$SUDO chown -R "$APP_USER":"$APP_USER" "$BASE_DIR"

echo "[7/7] Enabling and restarting service..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"
$SUDO systemctl restart "${SERVICE_NAME}"

echo
echo "======================================="
echo " Nexus Installed / Updated"
echo "======================================="
echo " - Service   : ${SERVICE_NAME}"
echo " - Base dir  : ${BASE_DIR}"
echo " - URL       : http://<LXC-IP>:8080"
echo
echo "Pages:"
echo "  /         -> Session"
echo "  /settings -> Settings (ESP32, rules, head behaviour, voice, video, bridge)"
echo "  /videos   -> Focus video list"
echo "  /bridge   -> Xtoys / webhook bridge"
echo
