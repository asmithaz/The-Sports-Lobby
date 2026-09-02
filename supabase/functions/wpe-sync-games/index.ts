// CFB Weekly Pick 'Em — game/score sync
//
// Pulls the college football REGULAR SEASON schedule + live/final scores
// from ESPN's public scoreboard API, upserts them into `wpe_games`
// (cfb/weekly-pick-em/schema.sql), computes the weekly "Sports Lobby
// Choice" curated slate, and recalculates every active league's
// standings. A game's `spread` is written only on first insert and never
// touched again on subsequent syncs — conference/rank/sports_lobby_choice
// DO refresh on every routine sync (descriptive metadata, not a frozen
// betting line). If an already-known game's teams change, its picks are
// cleared via wpe_apply_matchup_change (no mass email — regular-season
// matchup changes are rare/low-stakes, unlike a bowl opt-out).
//
// CONFERENCE RESOLUTION — history worth keeping, because two earlier
// approaches looked right and were both wrong:
//   1. First guess: `team.conferenceId` (a numeric string field ESPN
//      DOES return on every competitor) maps 1:1 to a real conference.
//      WRONG — live-verified 2026-08-31: San José State (Mountain West),
//      UTEP (Conference USA), Northern Illinois (MAC), and North Dakota
//      State (FCS, not even FBS) all report the SAME conferenceId (17).
//      Whatever that field encodes, it isn't athletic conference.
//   2. Second guess: the scoreboard's `groups=<id>` query param filters
//      to one real conference. Also WRONG — `groups=17` returned Oklahoma,
//      USC, Iowa, and Stanford alongside genuine Mountain West teams; it's
//      some kind of featured/editorial grouping, not a conference filter.
//   3. What actually works: ESPN's STANDINGS endpoint
//      (site.web.api.espn.com/apis/v2/.../standings?season=YYYY) returns
//      a real conference hierarchy — `children[]`, each with a stable
//      `id` and a `standings.entries[].team.id` roster. Cross-checked
//      directly against known reality: Conference USA=10 teams, MAC=13,
//      Big Ten=18, Mountain West=10 — all correct. This is fetched once
//      per sync and turned into a team-id → conference-name map; a
//      team's OWN `conferenceId`/`groups` are no longer trusted at all.
//   The numeric ids this endpoint returns per conference (ACC=1, Big
//   12=4, Big Ten=5, SEC=8, Pac-12=9, Conference USA=12, MAC=15,
//   Mountain West=17, Independents=18, Sun Belt=37, American=151)
//   happen to be the same values guessed in the two wrong approaches —
//   only the SOURCE of team membership was wrong, not the id table.
//
// Verify via ?raw=true / ?dry_run=true against the deployed function
// before trusting any change here unattended (this sandbox gets 403'd
// hitting ESPN directly, so verification must happen through the
// deployed function).
//
// Triggered by:
//  - pg_cron + pg_net every 15 minutes during the regular season
//    (schema.sql SECTION 8) — launched directly on this pattern rather
//    than GitHub Actions, per the lesson learned from fcp-sync-scores'
//    GH Actions schedule going silent 5+ hours during a live event.
//  - Manually with ?dry_run=true to inspect mapped output without writing,
//    or ?raw=true (optionally &team=<substring>) to inspect the unmapped
//    ESPN payload.
//
// Deploy with: supabase functions deploy wpe-sync-games

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

// Same confirmed-working host bpe-sync-games and fcp-sync-scores use —
// site.api.espn.com started 403-blocking non-browser clients 2026-08-19.
const ESPN_HOST = "https://site.web.api.espn.com";
const ESPN_SCOREBOARD = `${ESPN_HOST}/apis/site/v2/sports/football/college-football/scoreboard`;
const ESPN_STANDINGS = `${ESPN_HOST}/apis/v2/sports/football/college-football/standings`;

function scoreboardUrl(params: Record<string, string | number>) {
  const qs = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&");
  return qs ? `${ESPN_SCOREBOARD}?${qs}` : ESPN_SCOREBOARD;
}

// How many weeks beyond "current" to sync proactively, so upcoming weeks
// show up on the picks page as their own section (with spread/rank filled
// in as ESPN posts them) instead of only appearing once they become
// "current" — matches ESPN's own schedule availability, which is
// typically known well ahead of kickoff even before odds are posted.
const LOOKAHEAD_WEEKS = 2;

// Must match wpe_power4_conferences() / wpe_group_of_5_conferences() in
// cfb/weekly-pick-em/schema.sql exactly. Ids confirmed via the standings
// endpoint (see file header) — this is the id table, not the resolution
// mechanism; membership is now sourced from wpe_games via fetchConferenceMap().
const CONFERENCE_IDS: Record<string, number> = {
  ACC: 1, "Big Ten": 5, "Big 12": 4, SEC: 8, American: 151,
  "Conference USA": 12, MAC: 15, "Mountain West": 17, "Sun Belt": 37,
  Independents: 18, "Pac-12": 9,
};
const POWER4 = ["ACC", "Big 12", "Big Ten", "SEC"];
const GROUP_OF_5 = ["American", "Conference USA", "MAC", "Mountain West", "Sun Belt"];

// Builds a team-id → conference-name map from ESPN's standings hierarchy
// (the only verified-reliable source — see file header). One fetch per
// sync run, reused across every week being synced this run.
async function fetchConferenceMap(season: number): Promise<Map<string, string>> {
  const idToName = new Map(Object.entries(CONFERENCE_IDS).map(([name, id]) => [String(id), name]));
  const teamConference = new Map<string, string>();
  try {
    const res = await fetch(`${ESPN_STANDINGS}?season=${season}`);
    if (!res.ok) return teamConference;
    const data = await res.json();
    for (const child of data?.children ?? []) {
      const confName = idToName.get(String(child?.id));
      if (!confName) continue; // an id outside our 11 tracked conferences (or a non-conference grouping) — skip

      // Most conferences list teams directly in `standings.entries`. Sun
      // Belt (confirmed live 2026-09-01, the only one of the 11 that does
      // this) still carries an East/West divisional split — its OWN
      // `standings.entries` is empty, and the actual teams live one level
      // deeper under `children[].standings.entries` for each division.
      // Checking both shapes here covers a conference either way, present
      // or future, without needing to special-case Sun Belt by id.
      const entryGroups = [child?.standings?.entries, ...(child?.children ?? []).map((d: any) => d?.standings?.entries)];
      for (const entries of entryGroups) {
        for (const entry of entries ?? []) {
          const teamId = entry?.team?.id != null ? String(entry.team.id) : null;
          if (teamId) teamConference.set(teamId, confName);
        }
      }
    }
  } catch {
    // Leave the map empty/partial — every team just resolves to null
    // conference for this run rather than crashing the whole sync.
  }
  return teamConference;
}
// RESOLVED 2026-09-01: this endpoint returned 0 entries for Sun Belt (id
// 37) specifically, while all 10 other tracked conferences matched real
// membership counts exactly. Root cause: Sun Belt is the only one of the
// 11 still carrying an East/West divisional split in this dataset — its
// own `standings.entries` is empty, teams live one level deeper under
// `children[].standings.entries`. Fixed by checking both shapes above.

interface MappedGame {
  espn_event_id: string;
  week: number;
  home_team: string;
  away_team: string;
  home_team_logo: string | null;
  away_team_logo: string | null;
  home_conference: string | null;
  away_conference: string | null;
  home_rank: number | null;
  away_rank: number | null;
  favorite_team: string | null;
  spread: number | null;
  kickoff_at: string | null;
  status: "scheduled" | "live" | "final";
  home_score: number | null;
  away_score: number | null;
  winner_team: string | null;
  ats_winner_team: string | null;
  sports_lobby_choice: boolean;
}

// AP/CFP rank; ESPN's "unranked" sentinel (99) is normalized to null.
function resolveRank(competitor: any): number | null {
  const r = competitor?.curatedRank?.current;
  return (typeof r === "number" && r >= 1 && r <= 25) ? r : null;
}

function statusFor(competition: any): "scheduled" | "live" | "final" {
  const state = String(competition?.status?.type?.state ?? "").toLowerCase();
  if (state === "post") return "final";
  if (state === "in") return "live";
  return "scheduled";
}

function mapEvent(ev: any, week: number, teamConference: Map<string, string>): MappedGame | null {
  const competition = ev?.competitions?.[0];
  const competitors: any[] = competition?.competitors ?? [];
  if (competitors.length !== 2) return null;

  const home = competitors.find((c) => c.homeAway === "home");
  const away = competitors.find((c) => c.homeAway === "away");
  if (!home?.team || !away?.team || home.team.isActive === false || away.team.isActive === false) {
    return null; // matchup not yet set — not pickable yet
  }

  const odds = competition?.odds?.[0];
  let favoriteTeam: string | null = null;
  let spread: number | null = null;
  if (odds) {
    if (typeof odds.spread === "number") {
      spread = Math.abs(odds.spread);
      favoriteTeam = odds.spread < 0 ? home.team.displayName
        : odds.spread > 0 ? away.team.displayName
        : null;
    } else if (typeof odds.details === "string") {
      const m = odds.details.match(/(.+?)\s*(-\d+(\.\d+)?)/);
      if (m) {
        spread = Math.abs(parseFloat(m[2]));
        const favAbbrev = m[1].trim();
        favoriteTeam = home.team.abbreviation === favAbbrev ? home.team.displayName
          : away.team.abbreviation === favAbbrev ? away.team.displayName
          : null;
      }
    }
  }

  const status = statusFor(competition);
  const homeScore = home.score != null ? parseInt(String(home.score), 10) : null;
  const awayScore = away.score != null ? parseInt(String(away.score), 10) : null;

  let winnerTeam: string | null = null;
  let atsWinnerTeam: string | null = null;
  if (status === "final" && homeScore != null && awayScore != null) {
    winnerTeam = homeScore > awayScore ? home.team.displayName
      : awayScore > homeScore ? away.team.displayName
      : null;
    if (spread != null && favoriteTeam != null) {
      const favIsHome = favoriteTeam === home.team.displayName;
      const margin = favIsHome ? homeScore - awayScore : awayScore - homeScore;
      atsWinnerTeam = margin > spread ? favoriteTeam
        : margin < spread ? (favIsHome ? away.team.displayName : home.team.displayName)
        : null; // push
    }
  }

  const homeId = home.team.id != null ? String(home.team.id) : null;
  const awayId = away.team.id != null ? String(away.team.id) : null;

  return {
    espn_event_id: String(ev.id),
    week,
    home_team: home.team.displayName,
    away_team: away.team.displayName,
    home_team_logo: home.team.logo ?? null,
    away_team_logo: away.team.logo ?? null,
    home_conference: (homeId && teamConference.get(homeId)) ?? null,
    away_conference: (awayId && teamConference.get(awayId)) ?? null,
    home_rank: resolveRank(home),
    away_rank: resolveRank(away),
    favorite_team: favoriteTeam,
    spread,
    kickoff_at: ev?.date ?? null,
    status,
    home_score: homeScore,
    away_score: awayScore,
    winner_team: winnerTeam,
    ats_winner_team: atsWinnerTeam,
    sports_lobby_choice: false, // set by computeSportsLobbyChoice() below, after all games are mapped
  };
}

// ESPN's own `week.number` is NOT reliable at the season-opening boundary:
// live-verified 2026-08-31 — USC's Aug 29 game (vs San José State, already
// final) AND its Sep 5 game (vs Fresno State, still scheduled) BOTH report
// `week.number: 1`. Explicitly requesting `week=0` returns the identical
// 99-event set as `week=1` — ESPN has no separate Week 0 bucket at all for
// this season; it just lumps the season-opening "Week 0" slate (Ireland
// Classic, island-travel openers like Hawai'i/San José State, etc. — real,
// recognized part of the modern CFB calendar) into the same `week.number`
// as the following week's main slate, producing one ~8-day window instead
// of two ~5-day ones. Fixed by re-deriving week boundaries from each
// batch's own kickoff DATES: sort by kickoff, split wherever the gap
// between consecutive games exceeds GAP_DAYS, and treat the LAST
// (latest-dated) cluster as ESPN's claimed week number — any earlier
// cluster in the same batch is an extra week bundled in ahead of it, so it
// counts DOWN from there (…, N-2, N-1, N). This is what naturally produces
// a genuine "Week 0" label the first time this collision happens, without
// hardcoding any calendar dates.
const WEEK_SPLIT_GAP_DAYS = 4;

function reassignWeekBoundaries(events: { ev: any; kickoff: string | null }[], claimedWeek: number): { ev: any; week: number }[] {
  const withDates = events.filter((e) => e.kickoff)
    .sort((a, b) => new Date(a.kickoff!).getTime() - new Date(b.kickoff!).getTime());
  const withoutDates = events.filter((e) => !e.kickoff);

  const clusters: { ev: any; kickoff: string | null }[][] = [];
  let current: { ev: any; kickoff: string | null }[] = [];
  let lastTime: number | null = null;
  for (const e of withDates) {
    const t = new Date(e.kickoff!).getTime();
    if (lastTime !== null && t - lastTime > WEEK_SPLIT_GAP_DAYS * 24 * 60 * 60 * 1000) {
      clusters.push(current);
      current = [];
    }
    current.push(e);
    lastTime = t;
  }
  if (current.length) clusters.push(current);
  // Undated events (kickoff still TBD) ride along with whichever cluster is
  // closest to "now" — there's no date to sort them by, and this is the
  // batch that's actually relevant right now.
  if (withoutDates.length) {
    if (clusters.length) clusters[clusters.length - 1].push(...withoutDates);
    else clusters.push(withoutDates);
  }

  const out: { ev: any; week: number }[] = [];
  clusters.forEach((cluster, idx) => {
    const week = claimedWeek - (clusters.length - 1 - idx);
    for (const { ev } of cluster) out.push({ ev, week });
  });
  return out;
}

function rankScore(rank: number | null): number {
  return rank != null ? (26 - rank) * 3 : 0;
}
function p4Bonus(conf: string | null): number {
  return conf != null && POWER4.includes(conf) ? 10 : 0;
}
function gameScore(g: MappedGame): number {
  return rankScore(g.home_rank) + rankScore(g.away_rank) + p4Bonus(g.home_conference) + p4Bonus(g.away_conference);
}
function isGroupOf5Game(g: MappedGame): boolean {
  return (g.home_conference != null && GROUP_OF_5.includes(g.home_conference))
      || (g.away_conference != null && GROUP_OF_5.includes(g.away_conference));
}

const SLC_GENERAL_COUNT = 19;
const SLC_G5_RESERVE = 6; // SLC_GENERAL_COUNT + SLC_G5_RESERVE = 25 target

// Sets `sports_lobby_choice = true` on the ~25 best games PER WEEK present
// in `games` (mutates in place). Two-pass: rank/Power-4 score picks the
// top 19 generally, then a separate pass reserves up to 6 more slots for
// the best Group of 5 games that didn't already make the general pool —
// a pure top-25-by-score cut would starve G5 out most weeks otherwise.
// Falls short of 25 gracefully in a bye-heavy week rather than padding
// with a weak match.
function computeSportsLobbyChoice(games: MappedGame[]): void {
  const byWeek = new Map<number, MappedGame[]>();
  for (const g of games) {
    if (!byWeek.has(g.week)) byWeek.set(g.week, []);
    byWeek.get(g.week)!.push(g);
  }

  for (const weekGames of byWeek.values()) {
    const sorted = [...weekGames].sort((a, b) => gameScore(b) - gameScore(a));
    const general = sorted.slice(0, SLC_GENERAL_COUNT);
    const chosen = new Set(general.map((g) => g.espn_event_id));

    const g5Candidates = sorted.filter((g) => !chosen.has(g.espn_event_id) && isGroupOf5Game(g));
    for (const g of g5Candidates.slice(0, SLC_G5_RESERVE)) chosen.add(g.espn_event_id);

    const target = SLC_GENERAL_COUNT + SLC_G5_RESERVE;
    if (chosen.size < target) {
      for (const g of sorted) {
        if (chosen.size >= target) break;
        chosen.add(g.espn_event_id);
      }
    }

    for (const g of weekGames) g.sports_lobby_choice = chosen.has(g.espn_event_id);
  }
}

async function upsertSeasonState(supabase: any, season: number, seasonType: number, week: number) {
  const { data: existing } = await supabase
    .from("wpe_season_state").select("regular_season_complete_at").eq("season", season).maybeSingle();
  const regularSeasonCompleteAt = existing?.regular_season_complete_at ?? (seasonType === 3 ? new Date().toISOString() : null);
  await supabase.from("wpe_season_state").upsert({
    season,
    season_type: seasonType,
    current_week: week,
    regular_season_complete_at: regularSeasonCompleteAt,
    updated_at: new Date().toISOString(),
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const dryRun = url.searchParams.get("dry_run") === "true";
    const rawInspect = url.searchParams.get("raw") === "true";
    const overrideWeek = url.searchParams.get("week") ? parseInt(url.searchParams.get("week")!, 10) : undefined;
    const overrideYear = url.searchParams.get("year") ? parseInt(url.searchParams.get("year")!, 10) : undefined;
    const overrideSeasontype = url.searchParams.get("seasontype") ? parseInt(url.searchParams.get("seasontype")!, 10) : undefined;

    // No week/year/seasontype override = ESPN's own notion of "current" —
    // deliberately not computed locally from today's date.
    const primaryParams: Record<string, string | number> = { groups: 80, limit: 200 };
    if (overrideWeek) primaryParams.week = overrideWeek;
    if (overrideYear) primaryParams.year = overrideYear;
    if (overrideSeasontype) primaryParams.seasontype = overrideSeasontype;

    const primaryRes = await fetch(scoreboardUrl(primaryParams));
    if (!primaryRes.ok) throw new Error(`ESPN scoreboard request failed: ${primaryRes.status}`);
    const primaryData = await primaryRes.json();

    if (rawInspect) {
      const teamFilter = url.searchParams.get("team");
      let events = primaryData?.events ?? [];
      if (teamFilter) {
        const needle = teamFilter.toLowerCase();
        events = events.filter((ev: any) =>
          (ev?.competitions?.[0]?.competitors ?? []).some((c: any) =>
            String(c?.team?.displayName ?? "").toLowerCase().includes(needle)
          )
        );
      }
      return new Response(
        JSON.stringify({
          season: primaryData?.season,
          week: primaryData?.week,
          event_count: (primaryData?.events ?? []).length,
          filtered_count: events.length,
          event_sample: teamFilter ? events.slice(0, 20) : events.slice(0, 3),
        }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const seasonYear = primaryData?.season?.year ?? overrideYear ?? new Date().getFullYear();
    const seasonType = primaryData?.season?.type ?? overrideSeasontype ?? 2;
    const weekNumber = primaryData?.week?.number ?? overrideWeek ?? 1;

    // Sync ahead LOOKAHEAD_WEEKS beyond current, so upcoming weeks appear
    // on the picks page as their own (initially spread-less) section
    // instead of only showing up once they become "current". Skipped
    // when a caller explicitly pins a single week (manual backfill/testing).
    const weeksToFetch: { events: any[]; week: number }[] = [{ events: primaryData?.events ?? [], week: weekNumber }];
    if (overrideWeek === undefined) {
      const extras = await Promise.all(
        Array.from({ length: LOOKAHEAD_WEEKS }, (_, i) => weekNumber + i + 1).map(async (wk) => {
          try {
            const res = await fetch(scoreboardUrl({ groups: 80, limit: 200, week: wk, year: seasonYear, seasontype: seasonType }));
            if (!res.ok) return { events: [], week: wk };
            const data = await res.json();
            return { events: data?.events ?? [], week: wk };
          } catch {
            return { events: [], week: wk };
          }
        }),
      );
      weeksToFetch.push(...extras);
    }

    const teamConference = await fetchConferenceMap(seasonYear);

    // Re-derive real week boundaries from kickoff dates BEFORE mapping —
    // see reassignWeekBoundaries() header comment for why ESPN's own
    // per-batch week number can't be trusted as-is at the season opener.
    const reassigned = weeksToFetch.flatMap(({ events, week }) =>
      reassignWeekBoundaries(events.map((ev: any) => ({ ev, kickoff: ev?.date ?? null })), week),
    );

    const mapped: MappedGame[] = reassigned
      .map(({ ev, week }) => mapEvent(ev, week, teamConference))
      .filter((g): g is MappedGame => g != null);

    computeSportsLobbyChoice(mapped);

    const actualWeeks = [...new Set(mapped.map((g) => g.week))].sort((a, b) => a - b);

    if (dryRun) {
      const unresolved = mapped.filter((g) => g.home_conference == null && g.away_conference == null).length;
      return new Response(
        JSON.stringify({
          ok: true, dry_run: true, season: seasonYear, week: weekNumber,
          weeks_synced: actualWeeks, count: mapped.length, unresolved_conference_both_sides: unresolved,
          games: mapped,
        }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data: existingGames, error: existingErr } = await supabase
      .from("wpe_games")
      .select("id, espn_event_id, home_team, away_team")
      .eq("season", seasonYear);
    if (existingErr) throw existingErr;

    const existingByEspnId = new Map<string, { id: string; home_team: string; away_team: string }>();
    for (const g of existingGames ?? []) existingByEspnId.set(g.espn_event_id, g);

    const toInsert: any[] = [];
    const changedGames: { id: string; game: MappedGame }[] = [];

    for (const game of mapped) {
      const existing = existingByEspnId.get(game.espn_event_id);
      if (!existing) {
        toInsert.push({ season: seasonYear, ...game });
        continue;
      }
      if (existing.home_team !== game.home_team || existing.away_team !== game.away_team) {
        changedGames.push({ id: existing.id, game });
        continue;
      }
      // Routine refresh — spread is intentionally excluded so it stays
      // frozen at first sync. Conference/rank/sports_lobby_choice DO
      // refresh here (descriptive metadata, not a frozen betting line).
      // `week` is included so the one-time Week 0/Week 1 boundary fix
      // (see reassignWeekBoundaries) can correct already-synced rows —
      // safe pre-launch since no real league has picks on these games yet.
      const { error: updateErr } = await supabase
        .from("wpe_games")
        .update({
          week: game.week,
          status: game.status,
          home_score: game.home_score,
          away_score: game.away_score,
          winner_team: game.winner_team,
          ats_winner_team: game.ats_winner_team,
          kickoff_at: game.kickoff_at,
          home_conference: game.home_conference,
          away_conference: game.away_conference,
          home_rank: game.home_rank,
          away_rank: game.away_rank,
          sports_lobby_choice: game.sports_lobby_choice,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existing.id);
      if (updateErr) throw updateErr;
    }

    if (toInsert.length > 0) {
      const { error: insertErr } = await supabase.from("wpe_games").insert(toInsert);
      if (insertErr) throw insertErr;
    }

    for (const { id, game } of changedGames) {
      const { error: changeErr } = await supabase.rpc("wpe_apply_matchup_change", {
        p_game_id: id,
        p_home_team: game.home_team,
        p_away_team: game.away_team,
        p_home_conference: game.home_conference,
        p_away_conference: game.away_conference,
        p_home_rank: game.home_rank,
        p_away_rank: game.away_rank,
        p_spread: game.spread,
        p_kickoff_at: game.kickoff_at,
      });
      if (changeErr) throw changeErr;
    }

    const { error: recalcErr } = await supabase.rpc("wpe_recalculate_all_scores");
    if (recalcErr) throw recalcErr;

    await upsertSeasonState(supabase, seasonYear, seasonType, weekNumber);

    return new Response(
      JSON.stringify({
        ok: true, season: seasonYear, week: weekNumber, weeks_synced: actualWeeks,
        inserted: toInsert.length, matchup_changes: changedGames.length,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
