// ─── FedEx Cup Playoffs — Draft room sound effects ─────────────────────
// Short tones synthesized with the Web Audio API for key draft moments.
// No audio assets to host/license; everything is generated on the fly.
// Loaded before draft.js so its functions are ready when draft.js calls
// them (soundYourTurn, soundDraftStart, soundDraftComplete,
// soundCountdownTick, soundLobbyTick, soundPickMade, soundChatMessage).

let audioCtx = null;

function getAudioCtx() {
  if (!audioCtx) {
    const Ctor = window.AudioContext || window.webkitAudioContext;
    audioCtx = new Ctor();
  }
  if (audioCtx.state === 'suspended') audioCtx.resume();
  return audioCtx;
}

// Browsers block audio playback before a user gesture — unlock the
// context on the first interaction anywhere on the page.
document.addEventListener('pointerdown', getAudioCtx, { once: true, capture: true });
document.addEventListener('keydown', getAudioCtx, { once: true, capture: true });

function playTone(freq, durationMs, type = 'sine', volume = 0.15) {
  const ctx = getAudioCtx();
  const osc = ctx.createOscillator();
  const gain = ctx.createGain();
  osc.type = type;
  osc.frequency.value = freq;
  gain.gain.setValueAtTime(volume, ctx.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + durationMs / 1000);
  osc.connect(gain).connect(ctx.destination);
  osc.start();
  osc.stop(ctx.currentTime + durationMs / 1000);
}

// ─── Preferences ────────────────────────────────────────────────────────
function isSoundEnabled() {
  return localStorage.getItem('fcp_sound_enabled') !== 'false';
}

function setSoundEnabled(enabled) {
  localStorage.setItem('fcp_sound_enabled', enabled ? 'true' : 'false');
}

function isChatSoundEnabled() {
  return localStorage.getItem('fcp_chat_sound_enabled') !== 'false';
}

function setChatSoundEnabled(enabled) {
  localStorage.setItem('fcp_chat_sound_enabled', enabled ? 'true' : 'false');
}

// ─── Cues ───────────────────────────────────────────────────────────────
function soundYourTurn() {
  if (!isSoundEnabled()) return;
  playTone(880, 140, 'sine', 0.2);
  setTimeout(() => playTone(1174, 200, 'sine', 0.2), 140);
}

function soundDraftStart() {
  if (!isSoundEnabled()) return;
  // Rising run into a held landing chord — reads as an announcement/fanfare
  // rather than the short single-line blips used for the other cues.
  playTone(523, 130, 'triangle', 0.22);
  setTimeout(() => playTone(659, 130, 'triangle', 0.22), 130);
  setTimeout(() => playTone(784, 130, 'triangle', 0.22), 260);
  setTimeout(() => {
    playTone(659, 550, 'triangle', 0.22);
    playTone(784, 550, 'triangle', 0.2);
    playTone(1046, 550, 'triangle', 0.22);
  }, 390);
}

function soundDraftComplete() {
  if (!isSoundEnabled()) return;
  // Bigger fanfare than the other cues — this only fires once per draft,
  // so it can afford to be a full ascending run into a held landing chord.
  playTone(659, 110, 'triangle', 0.2);
  setTimeout(() => playTone(784, 110, 'triangle', 0.2), 110);
  setTimeout(() => playTone(988, 110, 'triangle', 0.2), 220);
  setTimeout(() => playTone(1175, 140, 'triangle', 0.22), 330);
  setTimeout(() => {
    playTone(784, 650, 'triangle', 0.2);
    playTone(988, 650, 'triangle', 0.18);
    playTone(1318, 650, 'triangle', 0.2);
  }, 470);
}

// Commissioner pauses the draft — a short descending pair reads as "hold."
function soundDraftPaused() {
  if (!isSoundEnabled()) return;
  playTone(659, 120, 'sine', 0.16);
  setTimeout(() => playTone(440, 220, 'sine', 0.16), 120);
}

// Commissioner resumes — mirror of soundDraftPaused, ascending instead.
function soundDraftResumed() {
  if (!isSoundEnabled()) return;
  playTone(440, 120, 'sine', 0.16);
  setTimeout(() => playTone(659, 220, 'sine', 0.16), 120);
}

// Pick-clock urgency (own turn, <=10s left).
function soundCountdownTick() {
  if (!isSoundEnabled()) return;
  playTone(1046, 90, 'square', 0.12);
}

// Lobby final-countdown (<=10s before the draft goes live) — deliberately
// a different pitch/timbre than soundCountdownTick so the two contexts
// don't sound identical.
function soundLobbyTick() {
  if (!isSoundEnabled()) return;
  playTone(523, 90, 'sine', 0.15);
}

function soundPickMade() {
  if (!isSoundEnabled()) return;
  playTone(440, 80, 'sine', 0.08);
}

// Gated on the chat flag alone — the master toggle's effect on chat is
// applied by force-syncing fcp_chat_sound_enabled when master is pressed
// (see wireSoundToggle below), not by gating playback on both flags. That
// way, re-enabling chat sound after a master press actually plays again.
function soundChatMessage() {
  if (!isChatSoundEnabled()) return;
  playTone(1568, 60, 'sine', 0.06);
}

// ─── Toggle buttons ─────────────────────────────────────────────────────
function wireSoundToggle(btnId, getEnabled, setEnabled, onToggle) {
  const btn = document.getElementById(btnId);
  if (!btn) return null;
  const sync = () => {
    const on = getEnabled();
    btn.textContent = on ? '🔊' : '🔇';
    btn.setAttribute('aria-pressed', String(on));
  };
  sync();
  btn.addEventListener('click', () => {
    const on = !getEnabled();
    setEnabled(on);
    sync();
    onToggle?.(on);
  });
  return sync;
}

document.addEventListener('DOMContentLoaded', () => {
  // Master toggle forces chat's own flag to match on every press, then
  // chat stays independently controllable again until master is pressed
  // again — pressing master always wins, syncing both flags/icons together.
  const syncChat = wireSoundToggle('chat-sound-toggle-btn', isChatSoundEnabled, setChatSoundEnabled);
  wireSoundToggle('sound-toggle-btn', isSoundEnabled, setSoundEnabled, on => {
    setChatSoundEnabled(on);
    syncChat?.();
  });
});
