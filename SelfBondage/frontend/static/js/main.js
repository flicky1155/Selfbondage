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
