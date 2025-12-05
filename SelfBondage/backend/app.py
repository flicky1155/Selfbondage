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
