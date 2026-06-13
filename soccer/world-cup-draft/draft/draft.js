const API_KEY = 'e87967bd39fd8844c217f40954ec5f4e';

// Pre-ranked fallback if the API is unavailable
const FALLBACK_TEAMS = [
  'France','England','Spain','Brazil','Germany','Argentina',
  'Portugal','Netherlands','Belgium','Italy','Morocco','Croatia',
  'Uruguay','Colombia','Japan','United States','Switzerland','Denmark',
  'Mexico','Australia','South Korea','Senegal','Austria','Poland',
  'Ecuador','Serbia','Turkey','Iran','Nigeria','Egypt',
  'Saudi Arabia','Algeria','Canada','South Africa','Panama','Costa Rica',
  'DR Congo','Cameroon','Tunisia','Venezuela','Honduras','Iraq',
  'Uzbekistan','Jordan','Scotland','New Zealand','Ukraine','Jamaica'
];

// ─── State ────────────────────────────────────────────────────────────
let state = {
  teams: [],            // [{rank, name, odds, picked}]
  drafters: [],         // ['Alice', 'Bob', ...]
  picks: [],            // picks[drafterIdx][roundIdx] = teamName
  currentPickIndex: 0,  // 0–47
  phase: 'setup'        // 'setup' | 'draft' | 'complete'
};

// ─── Storage ──────────────────────────────────────────────────────────
function saveState() {
  localStorage.setItem('wc2026Draft', JSON.stringify(state));
}

function loadState() {
  try {
    const s = localStorage.getItem('wc2026Draft');
    if (s) state = JSON.parse(s);
  } catch (_) {}
}

// ─── View management ──────────────────────────────────────────────────
function showView(name) {
  ['setup', 'draft', 'complete'].forEach(v => {
    document.getElementById(`view-${v}`).hidden = v !== name;
  });
}

// ─── Odds helpers ─────────────────────────────────────────────────────
function impliedProb(americanOdds) {
  return americanOdds > 0
    ? 100 / (americanOdds + 100)
    : (-americanOdds) / (-americanOdds + 100);
}

function formatOdds(price) {
  return price > 0 ? `+${price}` : `${price}`;
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ─── API – auto-discover sport key, then fetch outright odds ──────────
async function fetchTeamOdds() {
  const loadingEl = document.getElementById('rankings-loading');

  // Use session cache to avoid burning free-tier quota on refresh
  const cached = sessionStorage.getItem('wc2026OddsCache');
  if (cached) {
    try {
      state.teams = JSON.parse(cached);
      renderRankingsTable();
      return;
    } catch (_) {}
  }

  try {
    // Step 1: discover sport key
    const sportsRes = await fetch(
      `https://api.the-odds-api.com/v4/sports/?apiKey=${API_KEY}`
    );
    if (!sportsRes.ok) throw new Error('sports list unavailable');
    const sports = await sportsRes.json();

    // Look for a World Cup outright/futures market
    const wc =
      sports.find(s =>
        (s.key.toLowerCase().includes('world_cup') ||
         s.key.toLowerCase().includes('worldcup')) &&
        s.has_outrights
      ) ??
      sports.find(s =>
        s.title.toLowerCase().includes('world cup') && s.has_outrights
      );

    if (!wc) throw new Error('no World Cup outright market found');

    // Step 2: fetch odds
    const oddsUrl =
      `https://api.the-odds-api.com/v4/sports/${wc.key}/odds/` +
      `?apiKey=${API_KEY}&regions=us&markets=outrights&oddsFormat=american`;
    const oddsRes = await fetch(oddsUrl);
    if (!oddsRes.ok) throw new Error('odds request failed');
    const oddsData = await oddsRes.json();

    // Step 3: aggregate – average implied probability across bookmakers
    const teamProbs = {};
    const teamOdds  = {};

    for (const event of oddsData) {
      for (const bk of event.bookmakers ?? []) {
        for (const mkt of bk.markets ?? []) {
          if (mkt.key !== 'outrights') continue;
          for (const oc of mkt.outcomes ?? []) {
            if (!teamProbs[oc.name]) teamProbs[oc.name] = [];
            teamProbs[oc.name].push(impliedProb(oc.price));
            teamOdds[oc.name] = oc.price;
          }
        }
      }
    }

    const teams = Object.entries(teamProbs)
      .map(([name, probs]) => ({
        name,
        avgProb: probs.reduce((a, b) => a + b, 0) / probs.length,
        odds: formatOdds(teamOdds[name])
      }))
      .sort((a, b) => b.avgProb - a.avgProb)
      .map((t, i) => ({ rank: i + 1, name: t.name, odds: t.odds, picked: false }));

    if (teams.length < 5) throw new Error('too few teams returned');

    state.teams = teams;
    sessionStorage.setItem('wc2026OddsCache', JSON.stringify(teams));
    renderRankingsTable();

  } catch (_) {
    loadingEl.textContent = 'Live odds unavailable — using projected rankings.';
    state.teams = FALLBACK_TEAMS.map((name, i) => ({
      rank: i + 1, name, odds: 'N/A', picked: false
    }));
    renderRankingsTable();
  }
}

// ─── Rankings table (setup view) ──────────────────────────────────────
function renderRankingsTable() {
  const loadingEl = document.getElementById('rankings-loading');
  const tableEl   = document.getElementById('rankings-table');
  const tbody     = document.getElementById('rankings-body');

  tbody.innerHTML = state.teams.map(t =>
    `<tr>
      <td class="rank-num">${t.rank}</td>
      <td>${escHtml(t.name)}</td>
      <td class="odds-val">${escHtml(t.odds)}</td>
    </tr>`
  ).join('');

  loadingEl.hidden = true;
  tableEl.hidden   = false;
}

// ─── Setup events ─────────────────────────────────────────────────────
function initSetupView() {
  document.getElementById('add-drafter').addEventListener('click', () => {
    const wrap  = document.getElementById('drafter-inputs');
    const count = wrap.querySelectorAll('input').length;
    if (count >= 12) return;
    const div = document.createElement('div');
    div.className = 'drafter-row';
    div.innerHTML = `<input type="text" placeholder="Drafter ${count + 1}" />`;
    wrap.appendChild(div);
    updateOrderPreview();
  });

  document.getElementById('remove-drafter').addEventListener('click', () => {
    const wrap = document.getElementById('drafter-inputs');
    const rows = wrap.querySelectorAll('.drafter-row');
    if (rows.length <= 2) return;
    rows[rows.length - 1].remove();
    updateOrderPreview();
  });

  document.getElementById('drafter-inputs').addEventListener('input', updateOrderPreview);
  document.getElementById('start-draft').addEventListener('click', startDraft);
}

function updateOrderPreview() {
  const names = getDrafterNames();
  const el    = document.getElementById('order-preview');
  if (names.length < 2) { el.textContent = ''; return; }
  el.innerHTML =
    `<strong>Draft order:</strong><br>` +
    `Round 1: ${names.map(escHtml).join(' → ')}<br>` +
    `Round 2: ${[...names].reverse().map(escHtml).join(' → ')}<br>` +
    `<span class="note">…alternates direction each round</span>`;
}

function getDrafterNames() {
  return Array.from(document.querySelectorAll('#drafter-inputs input'))
    .map(i => i.value.trim())
    .filter(Boolean);
}

function startDraft() {
  const names = getDrafterNames();
  if (names.length < 2)                          { alert('Enter at least 2 drafter names.'); return; }
  if (new Set(names).size !== names.length)      { alert('Drafter names must be unique.'); return; }
  if (state.teams.length === 0)                  { alert('Teams are still loading — please wait.'); return; }

  // Ensure exactly 48 teams
  let teams = state.teams.map(t => ({ ...t, picked: false }));
  while (teams.length < 48) {
    teams.push({ rank: teams.length + 1, name: `Team ${teams.length + 1}`, odds: 'N/A', picked: false });
  }
  state.teams            = teams.slice(0, 48);
  state.drafters         = names;
  state.picks            = names.map(() => []);
  state.currentPickIndex = 0;
  state.phase            = 'draft';
  saveState();
  renderDraftView();
  showView('draft');
}

// ─── Snake draft logic ────────────────────────────────────────────────
function currentDrafterIdx() {
  const n   = state.drafters.length;
  const rnd = Math.floor(state.currentPickIndex / n);
  const pos = state.currentPickIndex % n;
  return rnd % 2 === 0 ? pos : n - 1 - pos;
}

function makePick(teamIdx) {
  const team = state.teams[teamIdx];
  if (!team || team.picked) return;

  const di = currentDrafterIdx();
  team.picked = true;
  state.picks[di].push(team.name);
  state.currentPickIndex++;

  if (state.currentPickIndex >= 48) {
    state.phase = 'complete';
    saveState();
    renderCompleteView();
    showView('complete');
  } else {
    saveState();
    renderDraftView();
  }
}

// ─── Draft view rendering ─────────────────────────────────────────────
function renderDraftView() {
  const n   = state.drafters.length;
  const rnd = Math.floor(state.currentPickIndex / n) + 1;
  const pos = (state.currentPickIndex % n) + 1;
  const who = state.drafters[currentDrafterIdx()];

  document.getElementById('pick-banner').textContent =
    `Now Picking: ${who}  —  Round ${rnd}, Pick ${pos} of ${n}`;

  const availBody = document.getElementById('avail-body');
  availBody.innerHTML = state.teams
    .map((t, idx) => ({ t, idx }))
    .filter(({ t }) => !t.picked)
    .map(({ t, idx }) =>
      `<tr>
        <td class="rank-num">${t.rank}</td>
        <td>${escHtml(t.name)}</td>
        <td class="odds-val">${escHtml(t.odds)}</td>
        <td><button class="pick-btn" data-idx="${idx}">Pick</button></td>
      </tr>`
    ).join('');

  availBody.querySelectorAll('.pick-btn').forEach(btn => {
    btn.addEventListener('click', () => makePick(parseInt(btn.dataset.idx, 10)));
  });

  renderBoard('board-table');
}

// ─── Draft board (shared by draft + complete views) ───────────────────
function renderBoard(tableId) {
  const table  = document.getElementById(tableId);
  const n      = state.drafters.length;
  const rounds = Math.ceil(48 / n);
  const curDI  = state.phase === 'draft' ? currentDrafterIdx() : -1;
  const curRnd = state.phase === 'draft' ? Math.floor(state.currentPickIndex / n) : -1;

  let html = '<thead><tr><th class="rnd-head">Rnd</th>';
  state.drafters.forEach(d => { html += `<th>${escHtml(d)}</th>`; });
  html += '</tr></thead><tbody>';

  for (let r = 0; r < rounds; r++) {
    html += `<tr><td class="rnd-num">R${r + 1}</td>`;
    state.drafters.forEach((_, di) => {
      const pick   = state.picks[di][r] ?? '';
      const active = (r === curRnd && di === curDI) ? ' class="active-cell"' : '';
      html += `<td${active}>${escHtml(pick)}</td>`;
    });
    html += '</tr>';
  }
  html += '</tbody>';
  table.innerHTML = html;
}

// ─── Complete view ────────────────────────────────────────────────────
function renderCompleteView() {
  renderBoard('complete-table');
}

// ─── Reset ────────────────────────────────────────────────────────────
function resetDraft(requireConfirm) {
  if (requireConfirm && !confirm('Reset the draft? All picks will be cleared.')) return;
  localStorage.removeItem('wc2026Draft');
  sessionStorage.removeItem('wc2026OddsCache');
  location.reload();
}

// ─── Init ─────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  loadState();

  document.getElementById('reset-btn')
    .addEventListener('click', () => resetDraft(true));
  document.getElementById('reset-btn-complete')
    .addEventListener('click', () => resetDraft(false));

  if (state.phase === 'draft') {
    renderDraftView();
    showView('draft');
  } else if (state.phase === 'complete') {
    renderCompleteView();
    showView('complete');
  } else {
    state.phase = 'setup';
    initSetupView();
    showView('setup');
    fetchTeamOdds();
  }
});
