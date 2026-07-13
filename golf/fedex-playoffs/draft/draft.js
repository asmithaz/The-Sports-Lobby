// ─── FedEx Cup Playoffs — Live Draft Room ──────────────────────────────
// All state lives in Supabase. fcp_leagues / fcp_picks / fcp_draft_order
// are kept in sync across clients via Realtime; turn order, golfer
// availability, tier-slot limits, and the pick clock are enforced
// server-side by the fcp_make_draft_pick / fcp_autopick_if_expired /
// fcp_start_draft RPCs.

let currentUserId = null;
let leagueId      = null;

let league     = null;  // leagues row
let fcpLeague  = null;  // fcp_leagues row (roster_mode, roster_size, tier1_count..3_count, draft state)
let draftOrder = [];    // fcp_draft_order rows [{user_id, position}]
let golfers    = [];    // golfers rows [{id, name, fedex_rank, tier}]
let picks      = [];    // fcp_picks rows [{user_id, golfer_id, pick_number, tier_slot}]
let profileMap = {};    // user_id -> display_name

let lobbyOrderIds  = null; // working copy of draft order while in the lobby
let timerInterval    = null;
let autopickInterval = null;
let lobbyInterval    = null;

const TIER_RANGES = { 1: 'Rank 1-30', 2: 'Rank 31-50', 3: 'Rank 51-70' };

// ─── Helpers ────────────────────────────────────────────────────────────
function escHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatDraftTime(d) {
  if (!d) return '—';
  return new Date(d).toLocaleString(undefined, {
    month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
  });
}

function showView(name) {
  ['loading', 'early', 'lobby', 'auction', 'draft', 'complete'].forEach(v => {
    document.getElementById(`view-${v}`).hidden = v !== name;
  });
  document.getElementById('chat-panel').hidden = (name === 'loading' || name === 'early');
}

function clearAllTimers() {
  clearInterval(timerInterval);
  clearInterval(autopickInterval);
  clearInterval(lobbyInterval);
  timerInterval = autopickInterval = lobbyInterval = null;
}

function rosterSize() {
  return fcpLeague?.roster_size ?? 4;
}

function tierCount(tier) {
  return fcpLeague?.[`tier${tier}_count`] ?? 0;
}

// Mirrors the _expected_drafter() snake-order formula in schema.sql.
function expectedDrafterId(pickNumber) {
  const n = draftOrder.length;
  if (n === 0) return null;
  let slot = (pickNumber - 1) % n;
  if (Math.floor((pickNumber - 1) / n) % 2 === 1) slot = n - 1 - slot;
  const entry = draftOrder.find(o => o.position === slot + 1);
  return entry ? entry.user_id : null;
}

// Counts of golfers already drafted by a user, grouped by tier.
function tierCountsForUser(userId) {
  const golferById = {};
  golfers.forEach(g => { golferById[g.id] = g; });

  const counts = { 1: 0, 2: 0, 3: 0 };
  picks.filter(p => p.user_id === userId).forEach(p => {
    const g = golferById[p.golfer_id];
    if (g) counts[g.tier] = (counts[g.tier] ?? 0) + 1;
  });
  return counts;
}

// ─── Data loading ───────────────────────────────────────────────────────
async function loadAll() {
  const [leagueRes, fcpRes, orderRes, golfersRes, picksRes] = await Promise.all([
    supabase.from('leagues').select('*').eq('id', leagueId).single(),
    supabase.from('fcp_leagues').select('*').eq('league_id', leagueId).maybeSingle(),
    supabase.from('fcp_draft_order').select('user_id, position').eq('league_id', leagueId).order('position'),
    supabase.from('golfers').select('id, name, fedex_rank, tier').order('fedex_rank'),
    supabase.from('fcp_picks').select('user_id, golfer_id, pick_number, tier_slot').eq('league_id', leagueId).order('pick_number')
  ]);

  league     = leagueRes.data;
  fcpLeague  = fcpRes.data;
  draftOrder = orderRes.data ?? [];
  golfers    = golfersRes.data ?? [];
  picks      = picksRes.data ?? [];

  // Member count/identity comes from fcp_draft_order — readable by all
  // league members, unlike league_members whose RLS only returns the
  // caller's own row.
  const ids = draftOrder.map(o => o.user_id);
  if (ids.length) {
    const { data: profiles } = await supabase.from('profiles').select('id, display_name').in('id', ids);
    profileMap = {};
    (profiles ?? []).forEach(p => { profileMap[p.id] = p.display_name; });
  }
}

// ─── Top-level render ───────────────────────────────────────────────────
async function render() {
  clearAllTimers();

  if (!league || !fcpLeague) {
    showView('loading');
    return;
  }

  if (fcpLeague.draft_format === 'auction') {
    showView('auction');
    return;
  }

  if (fcpLeague.draft_status === 'completed') {
    renderBoard('complete-table');
    showView('complete');
    return;
  }

  if (fcpLeague.draft_status === 'active') {
    renderDraftView();
    showView('draft');
    return;
  }

  // pending
  const draftTime = fcpLeague.draft_time ? new Date(fcpLeague.draft_time) : null;
  const lobbyOpensAt = draftTime ? new Date(draftTime.getTime() - 30 * 60 * 1000) : null;
  const now = new Date();

  if (!draftTime || now < lobbyOpensAt) {
    document.getElementById('early-draft-time').textContent = formatDraftTime(draftTime);
    showView('early');
    return;
  }

  if (draftOrder.length === 0) {
    await supabase.rpc('fcp_ensure_draft_order', { p_league_id: leagueId });
    await loadAll();
  }

  renderLobby();
  showView('lobby');
}

// ─── Lobby view ─────────────────────────────────────────────────────────
function renderLobby() {
  document.getElementById('lobby-draft-time').textContent = formatDraftTime(fcpLeague.draft_time);

  if (!lobbyOrderIds || lobbyOrderIds.length !== draftOrder.length) {
    lobbyOrderIds = [...draftOrder].sort((a, b) => a.position - b.position).map(o => o.user_id);
  }

  const isCommissioner = league.commissioner_id === currentUserId;
  document.getElementById('lobby-commissioner-controls').hidden = !isCommissioner;
  document.getElementById('lobby-save-status').textContent = '';

  const list = document.getElementById('lobby-order-list');
  list.innerHTML = lobbyOrderIds.map((uid, i) => `
    <li class="order-item">
      <span class="order-pos">${i + 1}</span>
      <span class="order-name">${escHtml(profileMap[uid] ?? 'Unknown')}</span>
      ${isCommissioner ? `
        <button class="order-move" data-dir="up" data-idx="${i}" ${i === 0 ? 'disabled' : ''}>↑</button>
        <button class="order-move" data-dir="down" data-idx="${i}" ${i === lobbyOrderIds.length - 1 ? 'disabled' : ''}>↓</button>
      ` : ''}
    </li>
  `).join('');

  if (isCommissioner) {
    list.querySelectorAll('.order-move').forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = parseInt(btn.dataset.idx, 10);
        const swapIdx = btn.dataset.dir === 'up' ? idx - 1 : idx + 1;
        [lobbyOrderIds[idx], lobbyOrderIds[swapIdx]] = [lobbyOrderIds[swapIdx], lobbyOrderIds[idx]];
        renderLobby();
      });
    });
  }

  startLobbyCountdown();
}

async function saveLobbyOrder() {
  const statusEl = document.getElementById('lobby-save-status');
  statusEl.textContent = 'Saving…';
  const { error } = await supabase.rpc('fcp_set_draft_order', {
    p_league_id: leagueId,
    p_user_ids: lobbyOrderIds
  });
  if (error) {
    statusEl.textContent = 'Failed: ' + error.message;
    return;
  }
  statusEl.textContent = 'Saved!';
  await loadAll();
}

function startLobbyCountdown() {
  clearInterval(lobbyInterval);
  updateLobbyCountdown();
  lobbyInterval = setInterval(updateLobbyCountdown, 1000);
}

async function updateLobbyCountdown() {
  const draftTimeMs = new Date(fcpLeague.draft_time).getTime();
  const remaining = Math.max(0, Math.floor((draftTimeMs - Date.now()) / 1000));

  const el = document.getElementById('lobby-countdown');
  const h = Math.floor(remaining / 3600);
  const m = Math.floor((remaining % 3600) / 60);
  const s = remaining % 60;
  el.textContent = h > 0
    ? `${h}h ${m}m ${s}s`
    : `${m}m ${s}s`;

  if (remaining <= 0) {
    clearInterval(lobbyInterval);
    lobbyInterval = null;
    await supabase.rpc('fcp_start_draft', { p_league_id: leagueId });
    await loadAll();
    await render();
  }
}

// ─── Draft view ─────────────────────────────────────────────────────────
function renderRosterStatus() {
  const el = document.getElementById('roster-status');

  if (fcpLeague.roster_mode === 'open') {
    const myPickCount = picks.filter(p => p.user_id === currentUserId).length;
    el.innerHTML = `<div class="roster-status-item">Your roster: <strong>${myPickCount} / ${rosterSize()}</strong></div>`;
    return;
  }

  const counts = tierCountsForUser(currentUserId);
  el.innerHTML = [1, 2, 3].filter(t => tierCount(t) > 0).map(t => `
    <div class="roster-status-item">
      ${escHtml(TIER_RANGES[t])}: <strong>${counts[t] ?? 0} / ${tierCount(t)}</strong>
    </div>
  `).join('');
}

function renderDraftView() {
  const n = draftOrder.length;
  const pickNum = fcpLeague.current_pick_number;
  const rnd = Math.floor((pickNum - 1) / n) + 1;
  const posInRound = ((pickNum - 1) % n) + 1;
  const expectedUser = expectedDrafterId(pickNum);
  const who = profileMap[expectedUser] ?? 'Unknown';
  const isMyTurn = expectedUser === currentUserId;
  const isPaused = !!fcpLeague.paused_at;
  const isCommissioner = league.commissioner_id === currentUserId;

  document.getElementById('pick-banner-text').textContent = isPaused
    ? `Draft Paused — Now Picking: ${who} — Round ${rnd}, Pick ${posInRound} of ${n}`
    : `Now Picking: ${who} — Round ${rnd}, Pick ${posInRound} of ${n}`;
  document.getElementById('pick-banner').classList.toggle('paused', isPaused);

  const pauseBtn = document.getElementById('pause-toggle-btn');
  pauseBtn.hidden = !isCommissioner;
  pauseBtn.disabled = false;
  pauseBtn.textContent = isPaused ? 'Resume Draft' : 'Pause Draft';

  renderRosterStatus();

  const pickedIds = new Set(picks.map(p => p.golfer_id));
  const avail = golfers.filter(g => !pickedIds.has(g.id));
  const myTierCounts = tierCountsForUser(currentUserId);

  const tbody = document.getElementById('avail-body');
  tbody.innerHTML = avail.map(g => {
    let canPick = isMyTurn && !isPaused;
    let disabledReason = isPaused ? 'Draft paused' : '';

    if (canPick && fcpLeague.roster_mode === 'tiered') {
      if ((myTierCounts[g.tier] ?? 0) >= tierCount(g.tier)) {
        canPick = false;
        disabledReason = 'Tier full';
      }
    } else if (canPick && fcpLeague.roster_mode === 'open') {
      const myPickCount = picks.filter(p => p.user_id === currentUserId).length;
      if (myPickCount >= rosterSize()) {
        canPick = false;
        disabledReason = 'Roster full';
      }
    }

    const action = isMyTurn
      ? (canPick
          ? `<button class="pick-btn" data-id="${escHtml(g.id)}">Pick</button>`
          : `<span class="pick-disabled">${escHtml(disabledReason)}</span>`)
      : '';

    return `
      <tr>
        <td class="rank-num">${g.fedex_rank ?? '—'}</td>
        <td>${escHtml(g.name)}</td>
        <td>${escHtml(TIER_RANGES[g.tier] ?? '')}</td>
        <td>${action}</td>
      </tr>`;
  }).join('');

  tbody.querySelectorAll('.pick-btn').forEach(btn => {
    btn.addEventListener('click', () => makePick(btn.dataset.id));
  });

  renderBoard('board-table');
  startTimer();
  startAutopickWatcher();
}

async function makePick(golferId) {
  document.querySelectorAll('#avail-body .pick-btn').forEach(b => b.disabled = true);
  const { error } = await supabase.rpc('fcp_make_draft_pick', {
    p_league_id: leagueId,
    p_golfer_id: golferId
  });
  if (error) {
    alert(error.message);
    await loadAll();
    await render();
  }
  // On success, the Realtime subscription refreshes state for everyone.
}

function startTimer() {
  clearInterval(timerInterval);
  updateTimer();
  timerInterval = setInterval(updateTimer, 1000);
}

function updateTimer() {
  const el = document.getElementById('pick-timer');
  el.classList.remove('timer-low');

  if (fcpLeague?.paused_at) {
    el.textContent = 'Paused';
    el.classList.add('timer-paused');
    return;
  }
  el.classList.remove('timer-paused');

  if (!fcpLeague?.pick_deadline) { el.textContent = ''; return; }

  const remaining = Math.max(0, Math.floor((new Date(fcpLeague.pick_deadline).getTime() - Date.now()) / 1000));
  const m = Math.floor(remaining / 60);
  const s = remaining % 60;
  el.textContent = `${m}:${String(s).padStart(2, '0')}`;
  el.classList.toggle('timer-low', remaining <= 10);
}

function startAutopickWatcher() {
  clearInterval(autopickInterval);
  autopickInterval = setInterval(async () => {
    if (fcpLeague?.draft_status !== 'active' || fcpLeague?.paused_at || !fcpLeague.pick_deadline) return;
    if (Date.now() > new Date(fcpLeague.pick_deadline).getTime()) {
      await supabase.rpc('fcp_autopick_if_expired', { p_league_id: leagueId });
    }
  }, 3000);
}

async function togglePause() {
  const btn = document.getElementById('pause-toggle-btn');
  btn.disabled = true;
  const rpc = fcpLeague.paused_at ? 'fcp_resume_draft' : 'fcp_pause_draft';
  const { error } = await supabase.rpc(rpc, { p_league_id: leagueId });
  if (error) {
    alert(error.message);
    btn.disabled = false;
  }
  // On success, the Realtime subscription on fcp_leagues refreshes state.
}

// ─── Draft board (shared by draft + complete views) ───────────────────
function renderBoard(tableId) {
  const table = document.getElementById(tableId);
  const n = draftOrder.length;
  if (n === 0) { table.innerHTML = ''; return; }

  const order  = [...draftOrder].sort((a, b) => a.position - b.position);
  const rounds = rosterSize();
  const curPickNum = fcpLeague.draft_status === 'active' ? fcpLeague.current_pick_number : -1;

  const pickByNumber = {};
  picks.forEach(p => { pickByNumber[p.pick_number] = p; });
  const golferById = {};
  golfers.forEach(g => { golferById[g.id] = g; });

  let html = '<thead><tr><th class="rnd-head">Rnd</th>';
  order.forEach(o => { html += `<th>${escHtml(profileMap[o.user_id] ?? 'Unknown')}</th>`; });
  html += '</tr></thead><tbody>';

  for (let r = 0; r < rounds; r++) {
    html += `<tr><td class="rnd-num">R${r + 1}</td>`;
    order.forEach((_, idx) => {
      const slot = (r % 2 === 0) ? idx : n - 1 - idx;
      const pickNum = r * n + slot + 1;
      const pick = pickByNumber[pickNum];
      const golfer = pick ? golferById[pick.golfer_id] : null;
      const active = pickNum === curPickNum ? ' class="active-cell"' : '';
      const tierTag = golfer ? `<span class="tier-tag">T${golfer.tier}</span>` : '';
      const label = golfer ? `${escHtml(golfer.name)} ${tierTag}` : '';
      html += `<td${active}>${label}</td>`;
    });
    html += '</tr>';
  }
  html += '</tbody>';
  table.innerHTML = html;
}

// ─── Chat ───────────────────────────────────────────────────────────────
function appendChatMessage(m) {
  const container = document.getElementById('chat-messages');
  const mine = m.user_id === currentUserId ? ' chat-msg-mine' : '';
  const name = profileMap[m.user_id] ?? 'Unknown';

  const div = document.createElement('div');
  div.className = `chat-msg${mine}`;
  div.innerHTML = `<span class="chat-msg-author">${escHtml(name)}</span><span class="chat-msg-body">${escHtml(m.body)}</span>`;
  container.appendChild(div);
  container.scrollTop = container.scrollHeight;
}

async function loadChatMessages() {
  const { data } = await supabase
    .from('fcp_draft_messages')
    .select('id, user_id, body, created_at')
    .eq('league_id', leagueId)
    .order('created_at', { ascending: true })
    .limit(100);

  document.getElementById('chat-messages').innerHTML = '';
  (data ?? []).forEach(appendChatMessage);
}

async function sendChatMessage(e) {
  e.preventDefault();
  const input = document.getElementById('chat-input');
  const body = input.value.trim();
  if (!body) return;
  input.value = '';

  const { error } = await supabase
    .from('fcp_draft_messages')
    .insert({ league_id: leagueId, user_id: currentUserId, body });
  if (error) alert(error.message);
}

function subscribeChatRealtime() {
  supabase
    .channel(`fcp-chat-${leagueId}`)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'fcp_draft_messages', filter: `league_id=eq.${leagueId}` },
      payload => appendChatMessage(payload.new))
    .subscribe();
}

// ─── Realtime ───────────────────────────────────────────────────────────
function subscribeRealtime() {
  const refresh = async () => { await loadAll(); await render(); };

  supabase
    .channel(`fcp-draft-${leagueId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fcp_picks',       filter: `league_id=eq.${leagueId}` }, refresh)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fcp_leagues',     filter: `league_id=eq.${leagueId}` }, refresh)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fcp_draft_order', filter: `league_id=eq.${leagueId}` }, refresh)
    .subscribe();
}

// ─── Init ─────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) { window.location.href = '/login/index.html'; return; }
  currentUserId = session.user.id;

  leagueId = sessionStorage.getItem('league_id');
  if (!leagueId) { window.location.href = '/golf/index.html'; return; }

  document.getElementById('lobby-save-order').addEventListener('click', saveLobbyOrder);
  document.getElementById('pause-toggle-btn').addEventListener('click', togglePause);
  document.getElementById('chat-form').addEventListener('submit', sendChatMessage);

  await loadAll();
  await render();
  subscribeRealtime();
  await loadChatMessages();
  subscribeChatRealtime();

  // Fallback poll — catches the early→lobby transition and anything a
  // realtime event might have missed.
  setInterval(async () => { await loadAll(); await render(); }, 20000);
});
