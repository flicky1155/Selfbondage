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

# Decide whether to use sudo or not
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

echo "======================================="
echo " Nexus - Full Installer"
echo "======================================="

echo "[1/9] Backing up any existing config/session..."
mkdir -p "$TMP_BACKUP_DIR"
if [ -f "$CONFIG_DIR/config.json" ]; then
  cp "$CONFIG_DIR/config.json" "$TMP_BACKUP_DIR/config.json" || true
  echo " - Backed up config.json"
fi
if [ -f "$CONFIG_DIR/session.json" ]; then
  cp "$CONFIG_DIR/session.json" "$TMP_BACKUP_DIR/session.json" || true
  echo " - Backed up session.json"
fi

echo "[2/9] Installing system dependencies..."
$SUDO apt update -y
$SUDO apt install -y python3 python3-venv python3-pip curl

echo "[3/9] Resetting install directory..."
$SUDO rm -rf "$BASE_DIR"
$SUDO mkdir -p "$BACKEND_DIR"
$SUDO mkdir -p "$FRONTEND_DIR/templates"
$SUDO mkdir -p "$FRONTEND_DIR/static/css"
$SUDO mkdir -p "$FRONTEND_DIR/static/js"
$SUDO mkdir -p "$CONFIG_DIR"

echo "[4/9] Creating Python virtual environment..."
cd "$BASE_DIR"
$SUDO python3 -m venv "$BASE_DIR/venv"
# shellcheck disable=SC1091
source "$BASE_DIR/venv/bin/activate"
pip install --upgrade pip
pip install flask requests

echo "[5/9] Writing backend app.py..."
cat > "$BACKEND_DIR/app.py" << 'EOF'
import os
import json
import time
import random
import datetime
import requests
from flask import Flask, render_template, request, jsonify

# ---------- Paths & globals ----------

BACKEND_DIR = os.path.abspath(os.path.dirname(__file__))
ROOT_DIR = os.path.dirname(BACKEND_DIR)
CONFIG_DIR = os.path.join(ROOT_DIR, "config")
FRONTEND_DIR = os.path.join(ROOT_DIR, "frontend")

os.makedirs(CONFIG_DIR, exist_ok=True)

CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
SESSION_FILE = os.path.join(CONFIG_DIR, "session.json")

DEFAULT_ESP32_URL = "http://192.168.1.50"

app = Flask(
    __name__,
    template_folder=os.path.join(FRONTEND_DIR, "templates"),
    static_folder=os.path.join(FRONTEND_DIR, "static"),
)

session_state = {}

# ---------- Config helpers ----------

def load_config():
    try:
        with open(CONFIG_FILE, "r") as f:
            cfg = json.load(f)

        # Core device settings
        if "esp32_url" not in cfg or not isinstance(cfg["esp32_url"], str):
            cfg["esp32_url"] = DEFAULT_ESP32_URL

        # Video config
        if "video_urls" not in cfg or not isinstance(cfg.get("video_urls"), list):
            cfg["video_urls"] = []
        if "video_enabled" not in cfg:
            cfg["video_enabled"] = True

        # NEW: Video start + display behaviour
        cfg.setdefault("video_start_mode", "main_phase")  # immediate | main_phase | delayed
        cfg.setdefault("video_start_after_min", 0)        # minutes into main phase
        cfg.setdefault("video_display_mode", "auto")      # fullscreen | popup | auto

        # Head tracking toggles
        cfg.setdefault("head_tracking_enabled", True)
        cfg.setdefault("video_autopause_enabled", True)

        # Hybrid head thresholds (user bounds)
        cfg.setdefault("head_user_min_down_deg", 20)
        cfg.setdefault("head_user_max_down_deg", 45)
        cfg.setdefault("head_user_min_away_deg", 25)
        cfg.setdefault("head_user_max_away_deg", 60)
        cfg.setdefault("head_user_min_still_sec", 5)
        cfg.setdefault("head_user_max_still_sec", 20)
        cfg.setdefault("head_user_min_debounce_ms", 3000)
        cfg.setdefault("head_user_max_debounce_ms", 7000)

        # Mistress / control flags
        cfg.setdefault("head_mistress_control", True)

        # Session behaviour flags
        cfg.setdefault("strict_mode", False)
        cfg.setdefault("hardcore_mode", False)
        cfg.setdefault("lock_to_7am", False)

        # External bridge (generic automation / scripting)
        cfg.setdefault("external_bridge_enabled", False)
        cfg.setdefault("external_bridge_url", "")

        # Voice assistant
        cfg.setdefault("voice_enabled", False)
        cfg.setdefault("voice_persona", "neutral")

        return cfg
    except Exception:
        return {
            "esp32_url": DEFAULT_ESP32_URL,
            "video_urls": [],
            "video_enabled": True,
            "video_start_mode": "main_phase",
            "video_start_after_min": 0,
            "video_display_mode": "auto",
            "head_tracking_enabled": True,
            "video_autopause_enabled": True,
            "head_user_min_down_deg": 20,
            "head_user_max_down_deg": 45,
            "head_user_min_away_deg": 25,
            "head_user_max_away_deg": 60,
            "head_user_min_still_sec": 5,
            "head_user_max_still_sec": 20,
            "head_user_min_debounce_ms": 3000,
            "head_user_max_debounce_ms": 7000,
            "head_mistress_control": True,
            "strict_mode": False,
            "hardcore_mode": False,
            "lock_to_7am": False,
            "external_bridge_enabled": False,
            "external_bridge_url": "",
            "voice_enabled": False,
            "voice_persona": "neutral",
        }

config = load_config()


def save_config(cfg):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


def load_session():
    global session_state
    try:
        with open(SESSION_FILE, "r") as f:
            session_state = json.load(f)
    except Exception:
        reset_session()


def save_session():
    with open(SESSION_FILE, "w") as f:
        json.dump(session_state, f, indent=2)


def reset_session():
    global session_state
    session_state = {
        "active": False,
        "phase": "idle",  # idle, pre_wait, decision_hold, punishment_delay, main, lockout, finished
        "created_at": None,
        "start_time": None,
        "pre_wait_sec": 0,
        "decision_hold_sec": 0,
        "punishment_delay_sec": 0,
        "main_duration_sec": 0,
        "total_added_sec": 0,
        "mistress_message": "",
        "last_event": "",
        "head_violation_count": 0,
        "head_thresholds": None,
        "coyote_pulse_pending": False,
        # Locking
        "lock_fired": False,
        # Video per-session state
        "video_started": False,
        "video_start_mode": config.get("video_start_mode", "main_phase"),
        "video_start_after_sec": int(config.get("video_start_after_min", 0)) * 60,
    }
    save_session()


load_session()

# ---------- Mistress & head tracking helpers ----------

def choose_head_thresholds(violation_count=0):
    """Hybrid mode: user bounds + dynamic choice."""
    if not config.get("head_tracking_enabled", True):
        return None

    min_down = config.get("head_user_min_down_deg", 20)
    max_down = config.get("head_user_max_down_deg", 45)
    min_away = config.get("head_user_min_away_deg", 25)
    max_away = config.get("head_user_max_away_deg", 60)
    min_still = config.get("head_user_min_still_sec", 5)
    max_still = config.get("head_user_max_still_sec", 20)
    min_debounce = config.get("head_user_min_debounce_ms", 3000)
    max_debounce = config.get("head_user_max_debounce_ms", 7000)

    mistress = config.get("head_mistress_control", True)

    if max_down < min_down:
        max_down = min_down
    if max_away < min_away:
        max_away = min_away
    if max_still < min_still:
        max_still = min_still
    if max_debounce < min_debounce:
        max_debounce = min_debounce

    if not mistress:
        down = (min_down + max_down) // 2
        away = (min_away + max_away) // 2
        still = (min_still + max_still) // 2
        debounce = (min_debounce + max_debounce) // 2
    else:
        down = random.randint(min_down, max_down)
        away = random.randint(min_away, max_away)
        still = random.randint(min_still, max_still)
        debounce = random.randint(min_debounce, max_debounce)

        # Tighten with each violation
        down = max(min_down, down - violation_count * 2)
        away = max(min_away, away - violation_count * 3)
        still = max(min_still, still - violation_count * 1)
        debounce = max(min_debounce, debounce - violation_count * 250)

    return {
        "down_deg": down,
        "away_deg": away,
        "still_sec": still,
        "debounce_ms": debounce,
    }


def mistress_head_punishment_choice():
    """
    Decide a response to a head violation:
    time changes, messages, visual focus cues, etc.
    """
    roll = random.random()
    actions = {
        "add_time_min": 0,
        "coyote_pulse": False,
        "force_hood": False,
        "switch_video": False,
        "message": "",
    }

    if roll < 0.25:
        actions["message"] = "You looked away. Keep your attention where it belongs."
    elif roll < 0.55:
        extra = random.randint(5, 20)
        actions["add_time_min"] = extra
        actions["message"] = f"You lost focus. +{extra} minutes added."
    elif roll < 0.75:
        actions["coyote_pulse"] = True
        actions["message"] = "That lapse did not go unnoticed."
    elif roll < 0.9:
        actions["force_hood"] = True
        actions["switch_video"] = True
        actions["message"] = "If you drift, I narrow your world down for you."
    else:
        extra = random.randint(10, 30)
        actions["add_time_min"] = extra
        actions["coyote_pulse"] = True
        actions["force_hood"] = True
        actions["switch_video"] = True
        actions["message"] = (
            f"You keep testing limits. +{extra} minutes and refocused attention."
        )

    return actions


# ---------- ESP32 Lock Control ----------

def esp32_lock():
    """Send lock command to ESP32."""
    url = config.get("esp32_url", "").rstrip("/")
    if not url:
        print("ESP32: No URL configured.")
        return False
    try:
        r = requests.get(url + "/lock", timeout=3)
        print("ESP32 LOCK response:", r.text)
        return True
    except Exception as e:
        print("ESP32 LOCK failed:", e)
        return False


def esp32_unlock():
    """Send unlock command to ESP32."""
    url = config.get("esp32_url", "").rstrip("/")
    if not url:
        print("ESP32: No URL configured.")
        return False
    try:
        r = requests.get(url + "/unlock", timeout=3)
        print("ESP32 UNLOCK response:", r.text)
        return True
    except Exception as e:
        print("ESP32 UNLOCK failed:", e)
        return False


@app.route("/test_lock", methods=["POST"])
def test_lock():
    ok = esp32_lock()
    return jsonify({"ok": ok})


@app.route("/test_unlock", methods=["POST"])
def test_unlock():
    ok = esp32_unlock()
    return jsonify({"ok": ok})


# ---------- External Bridge (generic automation / webhooks) ----------

@app.route("/bridge_config", methods=["GET", "POST"])
def bridge_config():
    global config
    if request.method == "GET":
        return jsonify({
            "external_bridge_enabled": config.get("external_bridge_enabled", False),
            "external_bridge_url": config.get("external_bridge_url", ""),
        })

    data = request.get_json(force=True, silent=True) or {}
    config["external_bridge_enabled"] = bool(data.get("external_bridge_enabled", False))
    config["external_bridge_url"] = str(data.get("external_bridge_url", "")).strip()
    save_config(config)
    return jsonify({"ok": True, "config": {
        "external_bridge_enabled": config["external_bridge_enabled"],
        "external_bridge_url": config["external_bridge_url"],
    }})


@app.route("/bridge_test", methods=["POST"])
def bridge_test():
    """
    Send a simple JSON event to the configured endpoint.
    This is generic so it can be used with automation tools, custom scripts, etc.
    """
    if not config.get("external_bridge_enabled", False):
        return jsonify({"ok": False, "error": "Bridge not enabled"}), 400

    url = config.get("external_bridge_url", "").strip()
    if not url:
        return jsonify({"ok": False, "error": "No bridge URL configured"}), 400

    payload = {
        "source": "nexus",
        "event": "TEST",
        "timestamp": time.time(),
        "note": "Test event from Nexus bridge.",
    }

    try:
        r = requests.post(url, json=payload, timeout=5)
        return jsonify({"ok": True, "status_code": r.status_code})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


# ---------- Basic pages ----------

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/settings")
def settings_page():
    return render_template("settings.html")


@app.route("/videos")
def videos_page():
    return render_template("videos.html")


@app.route("/bridge")
def bridge_page():
    return render_template("bridge.html")


# ---------- Config endpoints ----------

@app.route("/config", methods=["GET", "POST"])
def config_endpoint():
    global config
    if request.method == "GET":
        return jsonify(config)

    data = request.get_json(force=True, silent=True) or {}

    for key in (
        "esp32_url",
        "video_enabled",
        "video_start_mode",
        "video_start_after_min",
        "video_display_mode",
        "head_tracking_enabled",
        "video_autopause_enabled",
        "head_mistress_control",
        "head_user_min_down_deg",
        "head_user_max_down_deg",
        "head_user_min_away_deg",
        "head_user_max_away_deg",
        "head_user_min_still_sec",
        "head_user_max_still_sec",
        "head_user_min_debounce_ms",
        "head_user_max_debounce_ms",
        "strict_mode",
        "hardcore_mode",
        "lock_to_7am",
        "voice_enabled",
        "voice_persona",
    ):
        if key in data:
            config[key] = data[key]

    save_config(config)
    return jsonify({"ok": True, "config": config})


# ---------- Video config endpoints ----------

MISTRESS_VIDEO_URLS = [
    # Optional additional URLs can be added here.
]


@app.route("/video_config", methods=["GET", "POST"])
def video_config():
    global config
    if request.method == "GET":
        return jsonify({
            "video_urls": config.get("video_urls", []),
            "video_enabled": config.get("video_enabled", True),
        })

    data = request.get_json(force=True, silent=True) or {}
    urls = data.get("video_urls", [])
    if not isinstance(urls, list):
        urls = []
    config["video_urls"] = [u for u in urls if isinstance(u, str) and u.strip()]
    config["video_enabled"] = bool(data.get("video_enabled", True))
    save_config(config)
    return jsonify({"ok": True})


@app.route("/video_random")
def video_random():
    urls = list(config.get("video_urls", [])) + list(MISTRESS_VIDEO_URLS)
    urls = [u for u in urls if isinstance(u, str) and u.strip()]
    if not urls:
        return jsonify({"error": "No videos configured"}), 400
    url = random.choice(urls)
    return jsonify({"url": url})


@app.route("/video_violation", methods=["POST"])
def video_violation():
    """
    User pressed 'I can't watch this' or closed video.
    Adjust time and state accordingly.
    """
    global session_state
    if not session_state.get("active"):
        return jsonify({"ok": True, "note": "No active session."})

    extra_min = random.randint(5, 30)
    if config.get("hardcore_mode"):
        extra_min += random.randint(10, 30)

    extra_sec = extra_min * 60
    phase = session_state.get("phase", "idle")

    if phase in ("pre_wait", "decision_hold", "punishment_delay"):
        session_state["punishment_delay_sec"] += extra_sec
    elif phase in ("main", "lockout"):
        session_state["main_duration_sec"] += extra_sec

    session_state["total_added_sec"] += extra_sec
    session_state["mistress_message"] = (
        f"You tried to escape the focus. +{extra_min} minutes."
    )
    session_state["last_event"] = "video_violation"
    session_state["coyote_pulse_pending"] = True
    save_session()
    return jsonify({"ok": True, "extra_min": extra_min})


# ---------- Head tracking endpoints ----------

@app.route("/head_config", methods=["GET", "POST"])
def head_config():
    global config
    if request.method == "GET":
        return jsonify({
            "head_tracking_enabled": config.get("head_tracking_enabled", True),
            "video_autopause_enabled": config.get("video_autopause_enabled", True),
            "head_mistress_control": config.get("head_mistress_control", True),
            "head_user_min_down_deg": config.get("head_user_min_down_deg", 20),
            "head_user_max_down_deg": config.get("head_user_max_down_deg", 45),
            "head_user_min_away_deg": config.get("head_user_min_away_deg", 25),
            "head_user_max_away_deg": config.get("head_user_max_away_deg", 60),
            "head_user_min_still_sec": config.get("head_user_min_still_sec", 5),
            "head_user_max_still_sec": config.get("head_user_max_still_sec", 20),
            "head_user_min_debounce_ms": config.get("head_user_min_debounce_ms", 3000),
            "head_user_max_debounce_ms": config.get("head_user_max_debounce_ms", 7000),
        })

    data = request.get_json(force=True, silent=True) or {}

    def clamp_int(key, default, lo, hi):
        try:
            val = int(data.get(key, default))
        except Exception:
            val = default
        return max(lo, min(hi, val))

    config["head_tracking_enabled"] = bool(data.get("head_tracking_enabled", True))
    config["video_autopause_enabled"] = bool(data.get("video_autopause_enabled", True))
    config["head_mistress_control"] = bool(data.get("head_mistress_control", True))

    config["head_user_min_down_deg"] = clamp_int("head_user_min_down_deg", 20, 5, 80)
    config["head_user_max_down_deg"] = clamp_int("head_user_max_down_deg", 45, 5, 80)
    config["head_user_min_away_deg"] = clamp_int("head_user_min_away_deg", 25, 5, 90)
    config["head_user_max_away_deg"] = clamp_int("head_user_max_away_deg", 60, 5, 90)
    config["head_user_min_still_sec"] = clamp_int("head_user_min_still_sec", 5, 1, 60)
    config["head_user_max_still_sec"] = clamp_int("head_user_max_still_sec", 20, 1, 120)
    config["head_user_min_debounce_ms"] = clamp_int("head_user_min_debounce_ms", 3000, 500, 20000)
    config["head_user_max_debounce_ms"] = clamp_int("head_user_max_debounce_ms", 7000, 500, 30000)

    save_config(config)
    return jsonify({"ok": True})


@app.route("/head_violation", methods=["POST"])
def head_violation():
    """Called when headset orientation suggests looking down/away/still."""
    global session_state
    if not session_state.get("active"):
        return jsonify({"ok": True, "note": "No active session."})

    count = session_state.get("head_violation_count", 0) + 1
    session_state["head_violation_count"] = count
    session_state["head_thresholds"] = choose_head_thresholds(violation_count=count)

    actions = mistress_head_punishment_choice()

    if config.get("hardcore_mode"):
        if actions["add_time_min"] > 0:
            actions["add_time_min"] += random.randint(5, 20)
        actions["coyote_pulse"] = True

    if actions["add_time_min"] > 0:
        extra_sec = actions["add_time_min"] * 60
        phase = session_state.get("phase", "idle")
        if phase in ("pre_wait", "decision_hold", "punishment_delay"):
            session_state["punishment_delay_sec"] += extra_sec
        elif phase in ("main", "lockout"):
            session_state["main_duration_sec"] += extra_sec
        session_state["total_added_sec"] += extra_sec

    if actions["coyote_pulse"]:
        session_state["coyote_pulse_pending"] = True

    if actions["switch_video"]:
        session_state["last_event"] = "head_video_switch"

    session_state["mistress_message"] = actions["message"]
    save_session()
    return jsonify({"ok": True, "actions": actions})


# ---------- Session control ----------

@app.route("/start_session", methods=["POST"])
def start_session():
    """
    Simple session model:
      - pre_wait_sec
      - decision_hold_sec
      - punishment_delay_sec (initial, can be 0)
      - main_min / main_max (random choice)
    """
    global session_state
    data = request.get_json(force=True, silent=True) or {}

    if session_state.get("active"):
        return jsonify({"error": "Session already active"}), 400

    pre = int(data.get("pre_wait_sec", 0))
    dec = int(data.get("decision_hold_sec", 0))
    punish = int(data.get("punishment_delay_sec", 0))
    main_min = int(data.get("main_min_sec", 30 * 60))
    main_max = int(data.get("main_max_sec", 120 * 60))
    if main_max < main_min:
        main_max = main_min

    main = random.randint(main_min, main_max)

    reset_session()
    now = time.time()
    session_state["active"] = True
    session_state["phase"] = "pre_wait" if pre > 0 else (
        "decision_hold" if dec > 0 else (
            "punishment_delay" if punish > 0 else "main"
        )
    )
    session_state["start_time"] = now
    session_state["created_at"] = now
    session_state["pre_wait_sec"] = pre
    session_state["decision_hold_sec"] = dec
    session_state["punishment_delay_sec"] = punish
    session_state["main_duration_sec"] = main
    session_state["mistress_message"] = "Session started. Your control ends here."
    session_state["head_violation_count"] = 0
    session_state["head_thresholds"] = choose_head_thresholds(violation_count=0)

    # Locking will occur when pre-wait ends (or immediately if pre_wait_sec == 0)
    session_state["lock_fired"] = False

    # Freeze video rules for this session
    session_state["video_started"] = False
    session_state["video_start_mode"] = config.get("video_start_mode", "main_phase")
    session_state["video_start_after_sec"] = int(config.get("video_start_after_min", 0)) * 60

    session_state["last_event"] = "session_started"
    save_session()
    return jsonify({"ok": True})


@app.route("/abort_session", methods=["POST"])
def abort_session():
    global session_state
    if not session_state.get("active"):
        return jsonify({"ok": True, "note": "No active session."})

    if config.get("strict_mode") or config.get("hardcore_mode"):
        return jsonify({"error": "Abort is disabled in strict/hardcore mode."}), 403

    esp32_unlock()
    reset_session()
    session_state["last_event"] = "aborted"
    save_session()
    return jsonify({"ok": True, "aborted": True})


@app.route("/session_status")
def session_status():
    """
    Compute current phase + seconds remaining based on start_time and durations.
    Also decides when to lock and when to trigger video start.
    """
    global session_state
    now = time.time()

    if not session_state.get("active"):
        return jsonify({
            "active": False,
            "phase": session_state.get("phase", "idle"),
            "remaining_sec": 0,
            "mistress_message": session_state.get("mistress_message", ""),
            "head_violation_count": session_state.get("head_violation_count", 0),
            "head_thresholds": session_state.get("head_thresholds", None),
            "coyote_pulse_pending": False,
            "video_should_start": False,
            "video_display_mode": config.get("video_display_mode", "auto"),
        })

    pre = session_state.get("pre_wait_sec", 0)
    dec = session_state.get("decision_hold_sec", 0)
    pun = session_state.get("punishment_delay_sec", 0)
    main = session_state.get("main_duration_sec", 0)
    start = session_state.get("start_time", now)

    elapsed = int(now - start)
    total = pre + dec + pun + main

    # Determine phase and per-phase elapsed/total
    if elapsed < pre:
        phase = "pre_wait"
        phase_elapsed = elapsed
        phase_total = pre
    elif elapsed < pre + dec:
        phase = "decision_hold"
        phase_elapsed = elapsed - pre
        phase_total = dec
    elif elapsed < pre + dec + pun:
        phase = "punishment_delay"
        phase_elapsed = elapsed - pre - dec
        phase_total = pun
    elif elapsed < total:
        phase = "main"
        phase_elapsed = elapsed - pre - dec - pun
        phase_total = main
    else:
        # Completed timing; handle lock_to_7am
        if config.get("lock_to_7am"):
            now_dt = datetime.datetime.now()
            target = now_dt.replace(hour=7, minute=0, second=0, microsecond=0)
            if now_dt >= target:
                target = target + datetime.timedelta(days=1)
            remaining = int((target - now_dt).total_seconds())
            if remaining > 0:
                session_state["active"] = True
                session_state["phase"] = "lockout"
                save_session()
                return jsonify({
                    "active": True,
                    "phase": "lockout",
                    "remaining_sec": remaining,
                    "pre_wait_sec": pre,
                    "decision_hold_sec": dec,
                    "punishment_delay_sec": pun,
                    "main_duration_sec": main,
                    "mistress_message": "Lockout until 07:00.",
                    "head_violation_count": session_state.get("head_violation_count", 0),
                    "head_thresholds": session_state.get("head_thresholds", None),
                    "coyote_pulse_pending": False,
                    "video_should_start": False,
                    "video_display_mode": config.get("video_display_mode", "auto"),
                })

        phase = "finished"
        session_state["active"] = False
        session_state["phase"] = "finished"
        esp32_unlock()
        session_state["last_event"] = "finished_unlocked"
        save_session()
        return jsonify({
            "active": False,
            "phase": "finished",
            "remaining_sec": 0,
            "mistress_message": "Session complete. You may release yourself.",
            "head_violation_count": session_state.get("head_violation_count", 0),
            "head_thresholds": session_state.get("head_thresholds", None),
            "coyote_pulse_pending": False,
            "video_should_start": False,
            "video_display_mode": config.get("video_display_mode", "auto"),
        })

    # Phase still ongoing
    remaining = max(phase_total - phase_elapsed, 0)
    session_state["phase"] = phase

    # Lock: fire once when pre-wait is over (or immediately if no pre-wait)
    if not session_state.get("lock_fired", False):
        if pre == 0 or elapsed >= pre:
            if esp32_lock():
                session_state["lock_fired"] = True
                session_state["last_event"] = "locked_after_prewait"

    # Decide if video should start (once per session)
    video_should_start = False
    if config.get("video_enabled", True) and not session_state.get("video_started", False):
        mode = session_state.get("video_start_mode", config.get("video_start_mode", "main_phase"))
        delay_sec = int(session_state.get("video_start_after_sec", int(config.get("video_start_after_min", 0)) * 60))

        if mode == "immediate":
            video_should_start = True
        elif mode == "main_phase":
            if phase == "main":
                video_should_start = True
        elif mode == "delayed":
            if phase == "main" and phase_elapsed >= delay_sec:
                video_should_start = True

    if video_should_start:
        session_state["video_started"] = True

    pulse = session_state.get("coyote_pulse_pending", False)
    session_state["coyote_pulse_pending"] = False
    save_session()

    return jsonify({
        "active": True,
        "phase": phase,
        "remaining_sec": remaining,
        "pre_wait_sec": pre,
        "decision_hold_sec": dec,
        "punishment_delay_sec": pun,
        "main_duration_sec": main,
        "mistress_message": session_state.get("mistress_message", ""),
        "head_violation_count": session_state.get("head_violation_count", 0),
        "head_thresholds": session_state.get("head_thresholds", None),
        "coyote_pulse_pending": pulse,
        "video_should_start": video_should_start,
        "video_display_mode": config.get("video_display_mode", "auto"),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("NEXUS_PORT", "8080")), debug=True)
EOF

echo "[6/9] Writing frontend templates..."

cat > "$FRONTEND_DIR/templates/index.html" << 'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Nexus WebBT – Session</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/css/style.css">
</head>
<body>
  <header class="topbar">
    <div class="brand">Nexus WebBT</div>
    <nav class="nav">
      <a href="/" class="nav-link active">Session</a>
      <a href="/settings" class="nav-link">Settings</a>
      <a href="/videos" class="nav-link">Videos</a>
      <a href="/bridge" class="nav-link">Bridge</a>
    </nav>
  </header>

  <main class="main">
    <section class="grid">
      <div class="card">
        <h2>Session Control</h2>
        <div class="form-row">
          <label>Pre-wait (min)</label>
          <input type="number" id="preWait" min="0" value="5">
        </div>
        <div class="form-row">
          <label>Decision hold (min)</label>
          <input type="number" id="decisionHold" min="0" value="15">
        </div>
        <div class="form-row">
          <label>Punishment delay (min)</label>
          <input type="number" id="punDelay" min="0" value="0">
        </div>
        <div class="form-row">
          <label>Main duration range (min)</label>
          <div class="inline-inputs">
            <input type="number" id="mainMin" min="1" value="30">
            <span>to</span>
            <input type="number" id="mainMax" min="1" value="120">
          </div>
        </div>
        <div class="button-row">
          <button id="btnStart" onclick="startSession()">Start Session</button>
          <button id="btnAbort" class="danger" onclick="abortSession()">Abort (testing only)</button>
        </div>
        <p class="hint">
          Once started, controls lock and Nexus handles the timing.
        </p>
      </div>

      <div class="card">
        <h2>Current Status</h2>
        <p><strong>Phase:</strong> <span id="phase">idle</span></p>
        <p><strong>Time remaining (this phase):</strong> <span id="timeRemaining">0:00</span></p>
        <p><strong>Head violations:</strong> <span id="headCount">0</span></p>
        <p><strong>Voice:</strong></p>
        <p id="mistressText" class="mistress-text">
          Waiting to begin…
        </p>
      </div>
    </section>
  </main>

  <div id="punishOverlay" class="overlay hidden">
    <div class="overlay-inner">
      <iframe id="punishFrame" src="" class="overlay-frame"></iframe>
      <button class="overlay-button" onclick="userTriedClosePunish()">I can't watch this</button>
      <p class="overlay-note">
        Closing this early will change your time.
      </p>
    </div>
  </div>

  <script src="/static/js/main.js"></script>
</body>
</html>
EOF

cat > "$FRONTEND_DIR/templates/settings.html" << 'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Nexus WebBT – Settings</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/css/style.css">
</head>
<body>
  <header class="topbar">
    <div class="brand">Nexus WebBT</div>
    <nav class="nav">
      <a href="/" class="nav-link">Session</a>
      <a href="/settings" class="nav-link active">Settings</a>
      <a href="/videos" class="nav-link">Videos</a>
      <a href="/bridge" class="nav-link">Bridge</a>
    </nav>
  </header>

  <main class="main">
    <section class="grid">
      <div class="card">
        <h2>ESP32 Lock Controller</h2>
        <p>Set the URL of your ESP32 lock controller.</p>
        <div class="form-row">
          <label>ESP32 URL</label>
          <input type="text" id="esp32Url" placeholder="http://192.168.1.50">
        </div>
        <button onclick="saveEsp32()">Save</button>
        <div class="button-row">
          <button onclick="testLock()">Test Lock</button>
          <button onclick="testUnlock()">Test Unlock</button>
        </div>
        <p id="esp32Status" class="status-text"></p>
      </div>

      <div class="card">
        <h2>Session Rules & Behaviour</h2>
        <p>
          These settings control how strict Nexus is and how it reacts to your movements
          when you're watching in the browser or headset.
        </p>

        <h3>Session Rules</h3>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkStrictMode">
            Strict mode (no abort, no changing rules mid-session)
          </label>
        </div>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkHardcoreMode">
            Hardcore mode (harsher timing changes)
          </label>
        </div>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkLockTo7">
            Lockout until 07:00 (if the timer ends before 07:00, you remain locked)
          </label>
        </div>

        <hr style="border-color:#1f2937;margin:0.7rem 0;">

        <h3>Head Tracking & Focus</h3>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkHeadTrack">
            Enable head tracking (for compatible browsers/headsets)
          </label>
        </div>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkVideoAutopause">
            Dim focus video when you look away
          </label>
        </div>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkMistressControl">
            Let Nexus dynamically tighten sensitivity over time
          </label>
        </div>

        <h3>User Bounds (Nexus picks inside these)</h3>
        <p class="hint">Lower values = stricter / more sensitive detection.</p>

        <div class="form-row">
          <label>Look down angle (deg):</label>
          <div class="inline-inputs">
            <span>min</span>
            <input type="number" id="minDown" min="5" max="80" value="20">
            <span>max</span>
            <input type="number" id="maxDown" min="5" max="80" value="45">
          </div>
        </div>

        <div class="form-row">
          <label>Look away angle (deg):</label>
          <div class="inline-inputs">
            <span>min</span>
            <input type="number" id="minAway" min="5" max="90" value="25">
            <span>max</span>
            <input type="number" id="maxAway" min="5" max="90" value="60">
          </div>
        </div>

        <div class="form-row">
          <label>Stillness timeout (sec):</label>
          <div class="inline-inputs">
            <span>min</span>
            <input type="number" id="minStill" min="1" max="60" value="5">
            <span>max</span>
            <input type="number" id="maxStill" min="1" max="120" value="20">
          </div>
        </div>

        <div class="form-row">
          <label>Debounce (ms) before counting a new violation:</label>
          <div class="inline-inputs">
            <span>min</span>
            <input type="number" id="minDebounce" min="500" max="20000" value="3000">
            <span>max</span>
            <input type="number" id="maxDebounce" min="500" max="30000" value="7000">
          </div>
        </div>

        <div class="button-row">
          <button onclick="saveHeadConfig()">Save behaviour settings</button>
          <button onclick="saveModes()">Save strict / hardcore / lockout</button>
        </div>
        <p id="headCfgStatus" class="status-text"></p>
      </div>
    </section>

    <section class="grid" style="margin-top:1rem;">
      <div class="card">
        <h2>Voice Assistant</h2>
        <p>
          Let your browser read out key status messages. This uses the browser's built-in
          speech system (no extra install required).
        </p>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkVoiceEnabled">
            Enable voice announcements
          </label>
        </div>

        <div class="form-row">
          <label>Persona (tone)</label>
          <select id="voicePersona">
            <option value="neutral">Neutral</option>
            <option value="firm">Firm</option>
            <option value="playful">Playful</option>
            <option value="strict">Strict</option>
          </select>
        </div>

        <p class="hint">
          The persona influences how messages are phrased in future,
          but the actual audio voice depends on your device/browser settings.
        </p>

        <div class="button-row">
          <button onclick="saveVoiceConfig()">Save voice settings</button>
          <button onclick="testVoice()">Test voice line</button>
        </div>
        <p id="voiceStatus" class="status-text"></p>
      </div>

      <div class="card">
        <h2>Video Behaviour</h2>
        <p>
          Control when and how Nexus shows focus videos during a session.
        </p>

        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkVideoEnabledGlobal">
            Enable video during sessions
          </label>
        </div>

        <div class="form-row">
          <label>When should video start?</label>
          <select id="videoStartMode">
            <option value="main_phase">When main phase begins (default)</option>
            <option value="immediate">Immediately when session starts</option>
            <option value="delayed">After X minutes into the main phase</option>
          </select>
        </div>

        <div class="form-row" id="videoDelayRow">
          <label>Delay into main phase (minutes)</label>
          <input type="number" id="videoStartDelayMin" min="0" value="0">
        </div>

        <div class="form-row">
          <label>How should video be displayed?</label>
          <select id="videoDisplayMode">
            <option value="auto">Fullscreen with popup fallback (recommended)</option>
            <option value="fullscreen">Fullscreen only</option>
            <option value="popup">Popup window only</option>
          </select>
        </div>

        <div class="button-row">
          <button onclick="saveVideoBehaviour()">Save video behaviour</button>
        </div>
        <p id="videoBehaviourStatus" class="status-text"></p>
        <p id="videoLockedNote" class="status-text"></p>
      </div>
    </section>
  </main>

  <script>
    function toggleVideoDelayVisibility() {
      const mode = document.getElementById("videoStartMode").value;
      const row = document.getElementById("videoDelayRow");
      if (mode === "delayed") {
        row.style.display = "block";
      } else {
        row.style.display = "none";
      }
    }

    async function loadEsp32() {
      try {
        const res = await fetch("/config");
        const data = await res.json();

        document.getElementById("esp32Url").value = data.esp32_url || "";
        document.getElementById("esp32Status").innerText =
          "Current: " + (data.esp32_url || "not set");

        document.getElementById("chkStrictMode").checked = !!data.strict_mode;
        document.getElementById("chkHardcoreMode").checked = !!data.hardcore_mode;
        document.getElementById("chkLockTo7").checked = !!data.lock_to_7am;

        document.getElementById("chkVoiceEnabled").checked = !!data.voice_enabled;
        document.getElementById("voicePersona").value = data.voice_persona || "neutral";

        // Video behaviour
        document.getElementById("chkVideoEnabledGlobal").checked =
          data.video_enabled !== false;
        document.getElementById("videoStartMode").value =
          data.video_start_mode || "main_phase";
        document.getElementById("videoStartDelayMin").value =
          data.video_start_after_min || 0;
        document.getElementById("videoDisplayMode").value =
          data.video_display_mode || "auto";

        toggleVideoDelayVisibility();
      } catch (e) {
        document.getElementById("esp32Status").innerText =
          "Failed to load config: " + e;
      }
    }

    async function saveEsp32() {
      const url = document.getElementById("esp32Url").value.trim();
      const s = document.getElementById("esp32Status");
      s.innerText = "Saving…";
      try {
        const res = await fetch("/config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({ esp32_url: url })
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error: " + (data.error || res.statusText);
        } else {
          s.innerText = "Saved: " + data.config.esp32_url;
        }
      } catch (e) {
        s.innerText = "Failed to save ESP32 URL: " + e;
      }
    }

    async function testLock() {
      const s = document.getElementById("esp32Status");
      s.innerText = "Sending LOCK…";
      try {
        const res = await fetch("/test_lock", { method: "POST" });
        const data = await res.json();
        s.innerText = data.ok ? "Lock fired successfully." : "Lock FAILED.";
      } catch (e) {
        s.innerText = "Error firing lock: " + e;
      }
    }

    async function testUnlock() {
      const s = document.getElementById("esp32Status");
      s.innerText = "Sending UNLOCK…";
      try {
        const res = await fetch("/test_unlock", { method: "POST" });
        const data = await res.json();
        s.innerText = data.ok ? "Unlock fired successfully." : "Unlock FAILED.";
      } catch (e) {
        s.innerText = "Error firing unlock: " + e;
      }
    }

    async function loadHeadConfig() {
      try {
        const res = await fetch("/head_config");
        const data = await res.json();

        document.getElementById("chkHeadTrack").checked = !!data.head_tracking_enabled;
        document.getElementById("chkVideoAutopause").checked = !!data.video_autopause_enabled;
        document.getElementById("chkMistressControl").checked = !!data.head_mistress_control;

        document.getElementById("minDown").value = data.head_user_min_down_deg;
        document.getElementById("maxDown").value = data.head_user_max_down_deg;
        document.getElementById("minAway").value = data.head_user_min_away_deg;
        document.getElementById("maxAway").value = data.head_user_max_away_deg;
        document.getElementById("minStill").value = data.head_user_min_still_sec;
        document.getElementById("maxStill").value = data.head_user_max_still_sec;
        document.getElementById("minDebounce").value = data.head_user_min_debounce_ms;
        document.getElementById("maxDebounce").value = data.head_user_max_debounce_ms;

        document.getElementById("headCfgStatus").innerText =
          "Loaded behaviour settings.";
      } catch (e) {
        document.getElementById("headCfgStatus").innerText =
          "Failed to load behaviour settings: " + e;
      }
    }

    async function saveHeadConfig() {
      const s = document.getElementById("headCfgStatus");
      s.innerText = "Saving…";
      try {
        const payload = {
          head_tracking_enabled: document.getElementById("chkHeadTrack").checked,
          video_autopause_enabled: document.getElementById("chkVideoAutopause").checked,
          head_mistress_control: document.getElementById("chkMistressControl").checked,
          head_user_min_down_deg: document.getElementById("minDown").value,
          head_user_max_down_deg: document.getElementById("maxDown").value,
          head_user_min_away_deg: document.getElementById("minAway").value,
          head_user_max_away_deg: document.getElementById("maxAway").value,
          head_user_min_still_sec: document.getElementById("minStill").value,
          head_user_max_still_sec: document.getElementById("maxStill").value,
          head_user_min_debounce_ms: document.getElementById("minDebounce").value,
          head_user_max_debounce_ms: document.getElementById("maxDebounce").value,
        };

        const res = await fetch("/head_config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(payload)
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error saving: " + (data.error || res.statusText);
        } else {
          s.innerText = "Behaviour settings saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save behaviour: " + e;
      }
    }

    async function saveModes() {
      const s = document.getElementById("headCfgStatus");
      s.innerText = "Saving modes…";
      try {
        const payload = {
          strict_mode: document.getElementById("chkStrictMode").checked,
          hardcore_mode: document.getElementById("chkHardcoreMode").checked,
          lock_to_7am: document.getElementById("chkLockTo7").checked,
        };
        const res = await fetch("/config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(payload),
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error saving modes: " + (data.error || res.statusText);
        } else {
          s.innerText = "Modes saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save modes: " + e;
      }
    }

    async function saveVoiceConfig() {
      const enabled = document.getElementById("chkVoiceEnabled").checked;
      const persona = document.getElementById("voicePersona").value;
      const s = document.getElementById("voiceStatus");
      s.innerText = "Saving…";
      try {
        const res = await fetch("/config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({
            voice_enabled: enabled,
            voice_persona: persona
          })
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error: " + (data.error || res.statusText);
        } else {
          s.innerText = "Voice settings saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save voice settings: " + e;
      }
    }

    function testVoice() {
      const enabled = document.getElementById("chkVoiceEnabled").checked;
      const persona = document.getElementById("voicePersona").value;
      const s = document.getElementById("voiceStatus");
      s.innerText = "Speaking test line (if supported)…";

      if (!('speechSynthesis' in window)) {
        s.innerText = "This browser does not support speechSynthesis.";
        return;
      }
      if (!enabled) {
        s.innerText = "Enable voice first, then try again.";
        return;
      }

      let line = "This is a test line from Nexus.";
      if (persona === "firm") {
        line = "Test message. Focus, and listen carefully.";
      } else if (persona === "playful") {
        line = "Just checking your speakers are awake.";
      } else if (persona === "strict") {
        line = "Test message. No excuses about not hearing me later.";
      }

      const utter = new SpeechSynthesisUtterance(line);
      if (persona === "firm") {
        utter.rate = 0.95;
        utter.pitch = 0.9;
      } else if (persona === "playful") {
        utter.rate = 1.05;
        utter.pitch = 1.1;
      } else if (persona === "strict") {
        utter.rate = 0.9;
        utter.pitch = 0.85;
      }

      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utter);
    }

    async function saveVideoBehaviour() {
      const s = document.getElementById("videoBehaviourStatus");
      s.innerText = "Saving…";
      try {
        const payload = {
          video_enabled: document.getElementById("chkVideoEnabledGlobal").checked,
          video_start_mode: document.getElementById("videoStartMode").value,
          video_start_after_min: parseInt(
            document.getElementById("videoStartDelayMin").value || "0",
            10
          ),
          video_display_mode: document.getElementById("videoDisplayMode").value,
        };
        const res = await fetch("/config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(payload),
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error saving video behaviour: " + (data.error || res.statusText);
        } else {
          s.innerText = "Video behaviour saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save video behaviour: " + e;
      }
    }

    async function applyVideoLockState() {
      try {
        const res = await fetch("/session_status");
        const data = await res.json();
        const locked = !!data.active;
        const ids = [
          "chkVideoEnabledGlobal",
          "videoStartMode",
          "videoStartDelayMin",
          "videoDisplayMode"
        ];
        ids.forEach(id => {
          const el = document.getElementById(id);
          if (el) el.disabled = locked;
        });
        const note = document.getElementById("videoLockedNote");
        if (note) {
          note.innerText = locked ? "Locked during active session." : "";
        }
      } catch (e) {
        console.log("applyVideoLockState error:", e);
      }
    }

    document.addEventListener("DOMContentLoaded", () => {
      loadEsp32();
      loadHeadConfig();
      toggleVideoDelayVisibility();
      applyVideoLockState();
      document.getElementById("videoStartMode").addEventListener("change", toggleVideoDelayVisibility);
      // Re-check lock state every few seconds
      setInterval(applyVideoLockState, 5000);
    });
  </script>
</body>
</html>
EOF

cat > "$FRONTEND_DIR/templates/videos.html" << 'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Nexus WebBT – Focus Videos</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/css/style.css">
</head>
<body>
  <header class="topbar">
    <div class="brand">Nexus WebBT</div>
    <nav class="nav">
      <a href="/" class="nav-link">Session</a>
      <a href="/settings" class="nav-link">Settings</a>
      <a href="/videos" class="nav-link active">Videos</a>
      <a href="/bridge" class="nav-link">Bridge</a>
    </nav>
  </header>

  <main class="main">
    <section class="grid">
      <div class="card">
        <h2>Video URLs</h2>
        <p>One URL per line. Nexus may randomly pick from these during certain phases.</p>
        <textarea id="videoList" class="textarea"></textarea>
        <div class="form-row checkbox-row">
          <label><input type="checkbox" id="videoEnabled"> Enable focus videos</label>
        </div>
        <div class="button-row">
          <button onclick="saveVideos()">Save</button>
          <button onclick="testRandomVideo()">Test random video</button>
        </div>
        <p id="videoStatus" class="status-text"></p>
      </div>
    </section>

    <div id="videoOverlay" class="overlay hidden">
      <div class="overlay-inner">
        <iframe id="videoFrame" src="" class="overlay-frame"></iframe>
        <button class="overlay-button" onclick="closeTestOverlay()">Close test video</button>
      </div>
    </div>
  </main>

  <script>
    async function loadVideos() {
      try {
        const res = await fetch("/video_config");
        const data = await res.json();
        const urls = data.video_urls || [];
        document.getElementById("videoList").value = urls.join("\n");
        document.getElementById("videoEnabled").checked = !!data.video_enabled;
        document.getElementById("videoStatus").innerText = "Loaded video configuration.";
      } catch (e) {
        document.getElementById("videoStatus").innerText = "Failed to load: " + e;
      }
    }

    async function saveVideos() {
      const raw = document.getElementById("videoList").value;
      const enabled = document.getElementById("videoEnabled").checked;
      const urls = raw.split(/\r?\n/).map(s => s.trim()).filter(s => s.length > 0);
      const s = document.getElementById("videoStatus");
      s.innerText = "Saving…";
      try {
        const res = await fetch("/video_config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({ video_urls: urls, video_enabled: enabled })
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error: " + (data.error || res.statusText);
        } else {
          s.innerText = "Saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save: " + e;
      }
    }

    async function testRandomVideo() {
      try {
        const res = await fetch("/video_random");
        const data = await res.json();
        if (!res.ok || data.error) {
          document.getElementById("videoStatus").innerText =
            "Error: " + (data.error || res.statusText);
          return;
        }
        const url = data.url;
        const overlay = document.getElementById("videoOverlay");
        const frame = document.getElementById("videoFrame");
        frame.src = url;
        overlay.classList.remove("hidden");
      } catch (e) {
        document.getElementById("videoStatus").innerText =
          "Failed to fetch random video: " + e;
      }
    }

    function closeTestOverlay() {
      const overlay = document.getElementById("videoOverlay");
      const frame = document.getElementById("videoFrame");
      overlay.classList.add("hidden");
      frame.src = "";
    }

    document.addEventListener("DOMContentLoaded", loadVideos);
  </script>
</body>
</html>
EOF

cat > "$FRONTEND_DIR/templates/bridge.html" << 'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Nexus WebBT – Bridge</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/css/style.css">
</head>
<body>
  <header class="topbar">
    <div class="brand">Nexus WebBT</div>
    <nav class="nav">
      <a href="/" class="nav-link">Session</a>
      <a href="/settings" class="nav-link">Settings</a>
      <a href="/videos" class="nav-link">Videos</a>
      <a href="/bridge" class="nav-link active">Bridge</a>
    </nav>
  </header>

  <main class="main">
    <section class="grid">
      <div class="card">
        <h2>External Bridge / Automation</h2>
        <p>
          Configure a generic HTTP endpoint that Nexus can send JSON events to.
          This can be used with automation tools, your own scripts, or other services.
        </p>
        <div class="form-row checkbox-row">
          <label>
            <input type="checkbox" id="chkBridgeEnabled">
            Enable external bridge
          </label>
        </div>
        <div class="form-row">
          <label>Bridge endpoint URL</label>
          <input type="text" id="bridgeUrl" placeholder="http://127.0.0.1:9000/nexus">
        </div>
        <div class="button-row">
          <button onclick="saveBridgeConfig()">Save bridge config</button>
          <button onclick="testBridge()">Send test event</button>
        </div>
        <p class="hint">
          Example flow: Nexus → sends a small JSON payload to this URL → your script
          or service decides what to do with it.
        </p>
        <p id="bridgeStatus" class="status-text"></p>
      </div>
    </section>
  </main>

  <script>
    async function loadBridgeConfig() {
      try {
        const res = await fetch("/bridge_config");
        const data = await res.json();
        document.getElementById("chkBridgeEnabled").checked =
          !!data.external_bridge_enabled;
        document.getElementById("bridgeUrl").value =
          data.external_bridge_url || "";
        document.getElementById("bridgeStatus").innerText =
          "Bridge config loaded.";
      } catch (e) {
        document.getElementById("bridgeStatus").innerText =
          "Failed to load bridge config: " + e;
      }
    }

    async function saveBridgeConfig() {
      const enabled = document.getElementById("chkBridgeEnabled").checked;
      const url = document.getElementById("bridgeUrl").value.trim();
      const s = document.getElementById("bridgeStatus");
      s.innerText = "Saving…";
      try {
        const res = await fetch("/bridge_config", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({
            external_bridge_enabled: enabled,
            external_bridge_url: url
          })
        });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Error: " + (data.error || res.statusText);
        } else {
          s.innerText = "Bridge settings saved.";
        }
      } catch (e) {
        s.innerText = "Failed to save bridge settings: " + e;
      }
    }

    async function testBridge() {
      const s = document.getElementById("bridgeStatus");
      s.innerText = "Sending test event…";
      try {
        const res = await fetch("/bridge_test", { method: "POST" });
        const data = await res.json();
        if (!res.ok || data.error) {
          s.innerText = "Bridge test failed: " + (data.error || res.statusText);
        } else {
          s.innerText = "Bridge test sent (HTTP " + data.status_code + ").";
        }
      } catch (e) {
        s.innerText = "Bridge test error: " + e;
      }
    }

    document.addEventListener("DOMContentLoaded", loadBridgeConfig);
  </script>
</body>
</html>
EOF

echo "[7/9] Writing CSS..."
cat > "$FRONTEND_DIR/static/css/style.css" << 'EOF'
* {
  box-sizing: border-box;
}

body {
  margin: 0;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: radial-gradient(circle at top, #111827 0, #020617 55%, #000 100%);
  color: #e5e7eb;
}

.topbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.75rem 1rem;
  background: rgba(15, 23, 42, 0.95);
  border-bottom: 1px solid #1f2937;
  position: sticky;
  top: 0;
  z-index: 10;
}

.brand {
  font-weight: 700;
  letter-spacing: 0.08em;
  font-size: 0.9rem;
  text-transform: uppercase;
  color: #a855f7;
}

.nav {
  display: flex;
  gap: 0.75rem;
}

.nav-link {
  color: #9ca3af;
  text-decoration: none;
  font-size: 0.9rem;
  padding: 0.3rem 0.75rem;
  border-radius: 999px;
  border: 1px solid transparent;
}

.nav-link:hover {
  color: #e5e7eb;
  border-color: #4b5563;
}

.nav-link.active {
  color: #e5e7eb;
  background: linear-gradient(to right, #a855f7, #6366f1);
}

.main {
  padding: 1rem;
  max-width: 1100px;
  margin: 0 auto;
}

.grid {
  display: grid;
  grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr);
  gap: 1rem;
}

@media (max-width: 800px) {
  .grid {
    grid-template-columns: minmax(0, 1fr);
  }
}

.card {
  background: rgba(15, 23, 42, 0.95);
  border-radius: 1rem;
  padding: 1rem 1.1rem 1.2rem;
  border: 1px solid #1f2937;
  box-shadow: 0 18px 50px rgba(0, 0, 0, 0.6);
}

h2 {
  margin-top: 0;
  margin-bottom: 0.75rem;
  font-size: 1.1rem;
}

h3 {
  margin-top: 0.75rem;
  margin-bottom: 0.5rem;
  font-size: 1rem;
}

.form-row {
  margin-bottom: 0.6rem;
}

.form-row label {
  display: block;
  font-size: 0.9rem;
  margin-bottom: 0.2rem;
  color: #d1d5db;
}

input[type="number"],
input[type="text"],
textarea,
select {
  width: 100%;
  padding: 0.4rem 0.6rem;
  border-radius: 0.65rem;
  border: 1px solid #374151;
  background: #020617;
  color: #e5e7eb;
  font-size: 0.9rem;
}

textarea.textarea {
  min-height: 150px;
  resize: vertical;
}

input:focus,
textarea:focus,
select:focus {
  outline: none;
  border-color: #6366f1;
}

.checkbox-row label {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.9rem;
}

.inline-inputs {
  display: flex;
  align-items: center;
  gap: 0.4rem;
}

button {
  border: none;
  border-radius: 999px;
  padding: 0.5rem 1.1rem;
  font-size: 0.9rem;
  font-weight: 600;
  cursor: pointer;
  background: linear-gradient(to right, #6366f1, #8b5cf6);
  color: #f9fafb;
}

button:hover {
  filter: brightness(1.08);
}

button.danger {
  background: linear-gradient(to right, #dc2626, #b91c1c);
}

.button-row {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.5rem;
  flex-wrap: wrap;
}

.hint {
  font-size: 0.8rem;
  color: #9ca3af;
}

.status-text {
  font-size: 0.8rem;
  color: #9ca3af;
  margin-top: 0.3rem;
}

.mistress-text {
  font-size: 0.9rem;
  color: #fbbf24;
}

.overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.93);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 50;
}

.overlay.hidden {
  display: none;
}

.overlay-inner {
  width: 95%;
  max-width: 960px;
  background: #020617;
  border-radius: 1rem;
  padding: 0.75rem 0.75rem 1rem;
  border: 1px solid #1f2937;
  box-shadow: 0 20px 60px rgba(0,0,0,0.85);
  display: flex;
  flex-direction: column;
  align-items: center;
}

.overlay-frame {
  width: 100%;
  height: 60vh;
  border-radius: 0.75rem;
  border: none;
  background: #000;
}

.overlay-button {
  margin-top: 0.6rem;
  background: linear-gradient(to right, #dc2626, #b91c1c);
}

.overlay-note {
  font-size: 0.8rem;
  color: #9ca3af;
  margin-top: 0.3rem;
  text-align: center;
}
EOF

echo "[8/9] Writing main.js..."
cat > "$FRONTEND_DIR/static/js/main.js" << 'EOF'
let videoModeEnabled = true;
let punishOverlayActive = false;
let videoDisplayMode = "auto";
let videoPopup = null;

let headTrackingEnabled = true;
let videoAutopauseEnabled = true;

let headDebounceMs = 5000;
let stillnessMs = 15000;
let downAngleDeg = 30;
let awayAngleDeg = 35;

let lastHeadEventTime = 0;
let lastOrientation = null;
let lastMoveTime = 0;
let headViolationPending = false;

let strictOrHardcore = false;

let voiceEnabled = false;
let voicePersona = "neutral";
let lastSpokenMessage = "";

function speakLine(text) {
  if (!voiceEnabled) return;
  if (!('speechSynthesis' in window)) return;
  if (!text) return;
  if (text === lastSpokenMessage) return;

  lastSpokenMessage = text;

  const utter = new SpeechSynthesisUtterance(text);
  if (voicePersona === "firm") {
    utter.rate = 0.95;
    utter.pitch = 0.9;
  } else if (voicePersona === "playful") {
    utter.rate = 1.05;
    utter.pitch = 1.1;
  } else if (voicePersona === "strict") {
    utter.rate = 0.9;
    utter.pitch = 0.85;
  }

  window.speechSynthesis.cancel();
  window.speechSynthesis.speak(utter);
}

function fmtTime(sec) {
  sec = Math.max(0, Math.floor(sec));
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return m + ":" + (s < 10 ? "0" + s : s);
}

async function startSession() {
  const preMin = parseInt(document.getElementById("preWait").value || "0", 10);
  const decMin = parseInt(document.getElementById("decisionHold").value || "0", 10);
  const punMin = parseInt(document.getElementById("punDelay").value || "0", 10);
  const mainMin = parseInt(document.getElementById("mainMin").value || "30", 10);
  const mainMax = parseInt(document.getElementById("mainMax").value || "120", 10);

  document.getElementById("btnStart").disabled = true;

  try {
    const payload = {
      pre_wait_sec: preMin * 60,
      decision_hold_sec: decMin * 60,
      punishment_delay_sec: punMin * 60,
      main_min_sec: mainMin * 60,
      main_max_sec: mainMax * 60,
    };
    const res = await fetch("/start_session", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok || data.error) {
      alert("Error starting session: " + (data.error || res.statusText));
      document.getElementById("btnStart").disabled = false;
    } else {
      const line = "Session has begun. You don't touch the controls anymore.";
      document.getElementById("mistressText").innerText = line;
      speakLine(line);
    }
  } catch (e) {
    alert("Failed to start session: " + e);
    document.getElementById("btnStart").disabled = false;
  }
}

async function abortSession() {
  if (strictOrHardcore) {
    const line = "Abort is disabled in strict or hardcore mode.";
    alert(line);
    speakLine(line);
    return;
  }
  if (!confirm("Abort session? (For testing only)")) return;
  try {
    const res = await fetch("/abort_session", { method: "POST" });
    const data = await res.json();
    if (!res.ok || data.error) {
      alert("Abort refused: " + (data.error || res.statusText));
    } else {
      const line = "Session aborted.";
      document.getElementById("mistressText").innerText = line;
      speakLine(line);
      closeAnyVideo();
    }
  } catch (e) {
    console.log("Abort error:", e);
  }
}

function closeAnyVideo() {
  const overlay = document.getElementById("punishOverlay");
  const frame = document.getElementById("punishFrame");
  if (overlay && frame) {
    overlay.classList.add("hidden");
    frame.src = "";
  }
  if (videoPopup && !videoPopup.closed) {
    try {
      videoPopup.close();
    } catch (e) {
      console.log("Error closing popup:", e);
    }
  }
  punishOverlayActive = false;
  videoPopup = null;
}

async function pollSessionStatus() {
  try {
    const res = await fetch("/session_status");
    const data = await res.json();

    document.getElementById("phase").innerText = data.phase || "idle";
    document.getElementById("timeRemaining").innerText = fmtTime(data.remaining_sec || 0);
    document.getElementById("headCount").innerText = data.head_violation_count || 0;

    if (data.mistress_message) {
      const text = data.mistress_message;
      document.getElementById("mistressText").innerText = text;
      speakLine(text);
    }

    if (data.active) {
      document.getElementById("btnStart").disabled = true;
    } else {
      document.getElementById("btnStart").disabled = false;
    }

    if (data.head_thresholds) {
      const ht = data.head_thresholds;
      if (ht.down_deg) downAngleDeg = ht.down_deg;
      if (ht.away_deg) awayAngleDeg = ht.away_deg;
      if (ht.still_sec) stillnessMs = ht.still_sec * 1000;
      if (ht.debounce_ms) headDebounceMs = ht.debounce_ms;
    }

    if (data.coyote_pulse_pending) {
      console.log("Pulse flag set (generic marker).");
    }

    if (typeof data.video_display_mode === "string") {
      videoDisplayMode = data.video_display_mode || "auto";
    }

    if (data.video_should_start && videoModeEnabled && !punishOverlayActive) {
      startPunishmentVideo();
    }

  } catch (e) {
    console.log("pollSessionStatus error:", e);
  } finally {
    setTimeout(pollSessionStatus, 1000);
  }
}

async function loadVideoConfig() {
  try {
    const res = await fetch("/video_config");
    const data = await res.json();
    videoModeEnabled = !!data.video_enabled;
  } catch (e) {
    console.log("loadVideoConfig error:", e);
  }
}

async function loadHeadModeConfig() {
  try {
    const res = await fetch("/head_config");
    const data = await res.json();
    headTrackingEnabled = !!data.head_tracking_enabled;
    videoAutopauseEnabled = !!data.video_autopause_enabled;
    if (headTrackingEnabled) {
      initHeadTracking();
    }
  } catch (e) {
    console.log("loadHeadModeConfig error:", e);
  }
}

async function loadSessionConfigModes() {
  try {
    const res = await fetch("/config");
    const data = await res.json();
    strictOrHardcore = !!(data.strict_mode || data.hardcore_mode);

    voiceEnabled = !!data.voice_enabled;
    voicePersona = data.voice_persona || "neutral";

    const abortBtn = document.getElementById("btnAbort");
    if (abortBtn) {
      if (strictOrHardcore) {
        abortBtn.disabled = true;
        abortBtn.textContent = "Abort disabled (strict/hardcore)";
      } else {
        abortBtn.disabled = false;
        abortBtn.textContent = "Abort (testing only)";
      }
    }
  } catch (e) {
    console.log("loadSessionConfigModes error:", e);
  }
}

function openVideoPopup(url) {
  const width = Math.floor(window.screen.width * 0.8);
  const height = Math.floor(window.screen.height * 0.8);
  const left = Math.floor((window.screen.width - width) / 2);
  const top = Math.floor((window.screen.height - height) / 2);

  videoPopup = window.open(
    url,
    "nexusVideo",
    `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes`
  );

  if (!videoPopup) {
    console.log("Popup may have been blocked by the browser.");
    return;
  }

  punishOverlayActive = true;

  const watcher = setInterval(() => {
    if (!videoPopup || videoPopup.closed) {
      clearInterval(watcher);
      videoPopup = null;
      punishOverlayActive = false;
      userTriedClosePunish();
    }
  }, 1000);
}

async function startPunishmentVideo() {
  if (!videoModeEnabled || punishOverlayActive) return;
  try {
    const res = await fetch("/video_random");
    const data = await res.json();
    if (!res.ok || data.error) {
      console.log("No focus video:", data.error || res.statusText);
      return;
    }
    const url = data.url;

    if (videoDisplayMode === "popup") {
      openVideoPopup(url);
      return;
    }

    // Default: try fullscreen overlay first
    const overlay = document.getElementById("punishOverlay");
    const frame = document.getElementById("punishFrame");
    frame.src = url;
    overlay.classList.remove("hidden");
    punishOverlayActive = true;

    const elem = overlay;
    if (videoDisplayMode === "fullscreen" || videoDisplayMode === "auto") {
      if (elem.requestFullscreen) {
        elem.requestFullscreen().catch(err => {
          console.log("Fullscreen failed:", err);
          if (videoDisplayMode === "auto") {
            overlay.classList.add("hidden");
            frame.src = "";
            punishOverlayActive = false;
            openVideoPopup(url);
          }
        });
      } else if (videoDisplayMode === "auto") {
        overlay.classList.add("hidden");
        frame.src = "";
        punishOverlayActive = false;
        openVideoPopup(url);
      }
    }
  } catch (e) {
    console.log("startPunishmentVideo error:", e);
  }
}

async function userTriedClosePunish() {
  try {
    const res = await fetch("/video_violation", { method: "POST" });
    const data = await res.json();
    const overlay = document.getElementById("punishOverlay");
    const frame = document.getElementById("punishFrame");
    if (overlay && frame) {
      overlay.classList.add("hidden");
      frame.src = "";
    }
    punishOverlayActive = false;
    if (res.ok && data.ok) {
      if (data.extra_min) {
        const line = "You tried to exit. " + data.extra_min + " minutes added.";
        document.getElementById("mistressText").innerText = line;
        speakLine(line);
      }
    } else {
      console.log("video_violation error:", data.error || res.statusText);
    }
  } catch (e) {
    console.log("video_violation failed:", e);
  }
}

function initHeadTracking() {
  if (!window.DeviceOrientationEvent) {
    console.log("DeviceOrientation not supported.");
    return;
  }

  window.addEventListener("deviceorientation", (e) => {
    const now = Date.now();
    const alpha = e.alpha;
    const beta = e.beta;
    const gamma = e.gamma;

    if (lastOrientation) {
      const dAlpha = Math.abs(alpha - lastOrientation.alpha);
      const dBeta = Math.abs(beta - lastOrientation.beta);
      const dGamma = Math.abs(gamma - lastOrientation.gamma);
      if (dAlpha > 3 || dBeta > 3 || dGamma > 3) {
        lastMoveTime = now;
      }
    } else {
      lastMoveTime = now;
    }

    lastOrientation = { alpha, beta, gamma };

    if (!headTrackingEnabled) return;

    const yawDev = Math.min(Math.abs(alpha), Math.abs(alpha - 360));
    const lookingDown = beta > downAngleDeg;
    const lookingAway = yawDev > awayAngleDeg;
    const tooStill = (now - lastMoveTime) > stillnessMs;

    if (lookingDown || lookingAway || tooStill) {
      triggerHeadViolation(lookingDown, lookingAway, tooStill);
    }
  });
}

async function triggerHeadViolation(lookingDown, lookingAway, tooStill) {
  const now = Date.now();
  if (headViolationPending) return;
  if (now - lastHeadEventTime < headDebounceMs) return;

  headViolationPending = true;
  lastHeadEventTime = now;

  try {
    if (videoAutopauseEnabled && punishOverlayActive) {
      document.getElementById("punishOverlay").style.opacity = "0.3";
    }

    const res = await fetch("/head_violation", { method: "POST" });
    const data = await res.json();
    if (res.ok && data.ok) {
      const actions = data.actions || {};
      if (actions.message) {
        document.getElementById("mistressText").innerText = actions.message;
        speakLine(actions.message);
      }
      if (actions.switch_video && videoModeEnabled) {
        closeAnyVideo();
        startPunishmentVideo();
      }
    } else {
      console.log("head_violation error:", data.error || res.statusText);
    }
  } catch (e) {
    console.log("head_violation failed:", e);
  } finally {
    headViolationPending = false;
    if (videoAutopauseEnabled && punishOverlayActive) {
      document.getElementById("punishOverlay").style.opacity = "1";
    }
  }
}

document.addEventListener("DOMContentLoaded", () => {
  loadVideoConfig();
  loadHeadModeConfig();
  loadSessionConfigModes();
  pollSessionStatus();
});
EOF

echo "[9/9] Creating systemd service..."
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

echo "[9.1/9] Restoring any backed up config/session..."
if [ -f "$TMP_BACKUP_DIR/config.json" ]; then
  cp "$TMP_BACKUP_DIR/config.json" "$CONFIG_DIR/config.json"
  echo " - Restored config.json"
fi
if [ -f "$TMP_BACKUP_DIR/session.json" ]; then
  cp "$TMP_BACKUP_DIR/session.json" "$CONFIG_DIR/session.json"
  echo " - Restored session.json"
fi
rm -rf "$TMP_BACKUP_DIR"

echo "[9.2/9] Setting ownership..."
$SUDO chown -R "$APP_USER":"$APP_USER" "$BASE_DIR"

echo "[9.3/9] Enabling and restarting service..."
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
echo "  /settings -> Settings (ESP32, rules, head behaviour, voice, video behaviour)"
echo "  /videos   -> Focus video configuration"
echo "  /bridge   -> External bridge / automation"
echo

