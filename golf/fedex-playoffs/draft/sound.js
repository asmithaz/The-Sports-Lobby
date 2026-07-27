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
  playTone(659, 110, 'triangle', 0.18);
  setTimeout(() => playTone(880, 110, 'triangle', 0.18), 110);
  setTimeout(() => playTone(1318, 220, 'triangle', 0.18), 220);
}

function soundDraftComplete() {
  if (!isSoundEnabled()) return;
  playTone(880, 160, 'triangle', 0.18);
  setTimeout(() => playTone(587, 260, 'triangle', 0.18), 160);
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

function soundChatMessage() {
  if (!isSoundEnabled() || !isChatSoundEnabled()) return;
  playTone(1568, 60, 'sine', 0.06);
}

// ─── Toggle buttons ─────────────────────────────────────────────────────
function wireSoundToggle(btnId, getEnabled, setEnabled) {
  const btn = document.getElementById(btnId);
  if (!btn) return;
  const sync = () => {
    const on = getEnabled();
    btn.textContent = on ? '🔊' : '🔇';
    btn.setAttribute('aria-pressed', String(on));
  };
  sync();
  btn.addEventListener('click', () => {
    setEnabled(!getEnabled());
    sync();
  });
}

document.addEventListener('DOMContentLoaded', () => {
  wireSoundToggle('sound-toggle-btn', isSoundEnabled, setSoundEnabled);
  wireSoundToggle('chat-sound-toggle-btn', isChatSoundEnabled, setChatSoundEnabled);
});
