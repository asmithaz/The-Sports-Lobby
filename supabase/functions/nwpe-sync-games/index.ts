// NFL Weekly Pick 'Em — game/score sync
//
// Pulls the NFL schedule (regular season + postseason) and live/final
// scores from ESPN's public scoreboard API, upserts them into
// `nwpe_games` (nfl/weekly-pick-em/schema.sql), maintains each game's
// spread-lock snapshots, and recalculates every active league's
// standings. Modeled on cfb/weekly-pick-em's wpe-sync-games, with the
// CFB-only handling dropped entirely (no conference resolution, no AP
// rank, no `groups` FBS filter, no Week 0/1 merge — see this repo's
// nfl-weekly-pickem-plan memory for why none of that applies to the NFL).
//
// UNLIKE CFB: `spread`/`favorite_team` on `nwpe_games` are NEVER frozen —
// they always hold the latest ESPN value. Freezing is commissioner-
// configurable PER LEAGUE (nwpe_leagues.spread_lock_mode), so the same
// shared game can need a different "locked" number for different
// leagues. That's handled by maintainSpreadLocks() below, which writes
// into `nwpe_game_spread_locks` (at most 2 snapshot rows per game — one
// per possible lock_mode, not one per league) instead of onto the game
// row itself. See that table's schema.sql comment for the full design.
//
// WEEK NUMBERING: postseason weeks are stored as 18 + ESPN's own
// postseason week number (so Wild Card=19, Divisional=20,
// Conference Championship=21, Super Bowl=23 — round 22/week 4 is the
// Pro Bowl bye, no real games) so they sort continuously after the
// regular season's weeks 1-18 instead of colliding with them (both
// would otherwise restart counting from 1). This offset — and which
// round each postseason week number actually represents — is an
// ASSUMPTION. Verify via ?raw=true against a deployed version of this
// function once real postseason data exists, before the postseason
// actually starts, the same way every other quirk in this codebase
// gets verified against live ESPN data before being trusted.
//
// Triggered by:
//  - pg_cron + pg_net every 15 minutes during the season (schema.sql
//    SECTION 9) — same pg_cron+pg_net-not-GitHub-Actions reasoning as
//    every other sync function in this repo.
//  - Manually with ?dry_run=true to inspect mapped output without
//    writing, or ?raw=true (optionally &team=<substring>) to inspect
//    the unmapped ESPN payload.
//
// Deploy with: supabase functions deploy nwpe-sync-games

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

// Same confirmed-working host every other sync function in this repo
// uses — site.api.espn.com started 403-blocking non-browser clients
// 2026-08-19.
const ESPN_HOST = "https://site.web.api.espn.com";
const ESPN_SCOREBOARD = `${ESPN_HOST}/apis/site/v2/sports/football/nfl/scoreboard`;

function scoreboardUrl(params: Record<string, string | number>) {
  const qs = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&");
  return qs ? `${ESPN_SCOREBOARD}?${qs}` : ESPN_SCOREBOARD;
}

// How many weeks beyond "current" to sync proactively during the
// POSTSEASON, where matchups for a round aren't even determined until
// the prior round finishes (mapEvent() filters those out anyway, so
// this is mostly a cheap ceiling). During the REGULAR SEASON, ahead
// sync instead runs all the way to REGULAR_SEASON_WEEKS in one shot —
// the full schedule is public the whole season, so there's no reason
// to trickle it out week by week; players can see and pick any
// upcoming week's already-known matchups immediately (spread shows as
// "no line yet" via nwpe_game_spread_locks until that week is
// revealed — see schema.sql section 2).
const LOOKAHEAD_WEEKS = 2;

// How many weeks BEHIND "current" to keep re-fetching, so a straggler
// Sunday/Monday-night game finishing after ESPN advances its own
// "current" week pointer still gets synced to "final". Same rationale
// as CFB's identical constant — once ESPN's week.number advances, the
// prior week's scoreboard is never returned by the "current" query
// again.
const LOOKBACK_WEEKS = 1;

// Postseason weeks restart from 1 in ESPN's own numbering — this is
// added to a postseason week to get the STORED week (see file header).
// NFL's regular season has been a stable 18 weeks since 2021; unlike
// CFB's hand-maintained per-year regular-season-length constant, this
// one is safe to hardcode.
const REGULAR_SEASON_WEEKS = 18;

interface MappedGame {
  espn_event_id: string;
  season_type: number;    // ESPN's own value: 2 = regular season, 3 = postseason
  week: number;            // STORED week — see file header for the postseason offset
  home_team: string;
  away_team: string;
  home_team_abbr: string | null;
  away_team_abbr: string | null;
  home_team_logo: string | null;
  away_team_logo: string | null;
  favorite_team: string | null;
  spread: number | null;
  kickoff_at: string | null;
  status: "scheduled" | "live" | "final";
  status_detail: string | null;
  home_score: number | null;
  away_score: number | null;
  winner_team: string | null;
}

function statusFor(competition: any): "scheduled" | "live" | "final" {
  const state = String(competition?.status?.type?.state ?? "").toLowerCase();
  if (state === "post") return "final";
  if (state === "in") return "live";
  return "scheduled";
}

function mapEvent(ev: any, storedWeek: number, seasonType: number): MappedGame | null {
  const competition = ev?.competitions?.[0];
  const competitors: any[] = competition?.competitors ?? [];
  if (competitors.length !== 2) return null;

  const home = competitors.find((c) => c.homeAway === "home");
  const away = competitors.find((c) => c.homeAway === "away");
  if (!home?.team || !away?.team || home.team.isActive === false || away.team.isActive === false) {
    return null; // matchup not yet set (e.g. a not-yet-determined playoff round) — not pickable yet
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
  const statusDetail: string | null = competition?.status?.type?.shortDetail ?? null;
  const homeScore = home.score != null ? parseInt(String(home.score), 10) : null;
  const awayScore = away.score != null ? parseInt(String(away.score), 10) : null;

  let winnerTeam: string | null = null;
  if (status === "final" && homeScore != null && awayScore != null) {
    winnerTeam = homeScore > awayScore ? home.team.displayName
      : awayScore > homeScore ? away.team.displayName
      : null;
  }

  return {
    espn_event_id: String(ev.id),
    season_type: seasonType,
    week: storedWeek,
    home_team: home.team.displayName,
    away_team: away.team.displayName,
    home_team_abbr: home.team.abbreviation ?? null,
    away_team_abbr: away.team.abbreviation ?? null,
    home_team_logo: home.team.logo ?? null,
    away_team_logo: away.team.logo ?? null,
    favorite_team: favoriteTeam,
    spread,
    kickoff_at: ev?.date ?? null,
    status,
    status_detail: statusDetail,
    home_score: homeScore,
    away_score: awayScore,
    winner_team: winnerTeam,
  };
}

// Maintains nwpe_game_spread_locks for every game whose week has been
// revealed (week <= this run's current stored week) among the games
// just synced — see that table's schema.sql comment for the full
// design. Reads the FRESH spread/favorite_team just written to
// nwpe_games (this function must run AFTER the games upsert/insert
// above completes).
async function maintainSpreadLocks(supabase: any, seasonYear: number, revealedEspnIds: string[]) {
  if (revealedEspnIds.length === 0) return;

  const { data: rows, error } = await supabase
    .from("nwpe_games")
    .select("id, week, spread, favorite_team, kickoff_at")
    .eq("season", seasonYear)
    .in("espn_event_id", revealedEspnIds);
  if (error) throw error;
  if (!rows || rows.length === 0) return;

  const earliestKickoffByWeek = new Map<number, number>();
  for (const r of rows) {
    if (!r.kickoff_at) continue;
    const t = new Date(r.kickoff_at).getTime();
    const cur = earliestKickoffByWeek.get(r.week);
    if (cur == null || t < cur) earliestKickoffByWeek.set(r.week, t);
  }

  const gameIds = rows.map((r: any) => r.id);
  const { data: existingLocks, error: locksErr } = await supabase
    .from("nwpe_game_spread_locks")
    .select("game_id, lock_mode, is_final, snapshotted_at")
    .in("game_id", gameIds);
  if (locksErr) throw locksErr;

  const lockKey = (gameId: string, mode: string) => `${gameId}:${mode}`;
  const existingByKey = new Map<string, any>();
  for (const l of existingLocks ?? []) existingByKey.set(lockKey(l.game_id, l.lock_mode), l);

  const now = Date.now();
  const DAY_MS = 24 * 60 * 60 * 1000;
  const nowIso = new Date().toISOString();
  const upserts: any[] = [];

  for (const r of rows) {
    // week_reveal: one-shot — insert only if it doesn't exist yet, final immediately.
    if (!existingByKey.has(lockKey(r.id, "week_reveal"))) {
      upserts.push({
        game_id: r.id, lock_mode: "week_reveal",
        locked_spread: r.spread, locked_favorite_team: r.favorite_team,
        is_final: true, snapshotted_at: nowIso,
      });
    }

    // day_before_kickoff: refresh at most once per 24h, freeze forever
    // once less than 24h remains before the week's earliest kickoff.
    const existing = existingByKey.get(lockKey(r.id, "day_before_kickoff"));
    if (existing?.is_final) continue; // already frozen forever, never touch again

    const earliestKickoff = earliestKickoffByWeek.get(r.week);
    const pastThreshold = earliestKickoff != null && now >= earliestKickoff - DAY_MS;
    const dueForDailyRefresh = !existing || (now - new Date(existing.snapshotted_at).getTime() >= DAY_MS);

    if (pastThreshold || dueForDailyRefresh) {
      upserts.push({
        game_id: r.id, lock_mode: "day_before_kickoff",
        locked_spread: r.spread, locked_favorite_team: r.favorite_team,
        is_final: pastThreshold, snapshotted_at: nowIso,
      });
    }
  }

  if (upserts.length > 0) {
    const { error: upsertErr } = await supabase
      .from("nwpe_game_spread_locks")
      .upsert(upserts, { onConflict: "game_id,lock_mode" });
    if (upsertErr) throw upsertErr;
  }
}

async function upsertSeasonState(supabase: any, season: number, seasonType: number, storedWeek: number, games: MappedGame[]) {
  const { data: existing } = await supabase
    .from("nwpe_season_state")
    .select("regular_season_complete_at, playoffs_complete_at")
    .eq("season", season)
    .maybeSingle();

  const regularSeasonCompleteAt = existing?.regular_season_complete_at ?? (seasonType === 3 ? new Date().toISOString() : null);

  // playoffs_complete_at: set once the highest known postseason week
  // synced THIS RUN is fully final, AND that week is the one we expect
  // the Super Bowl to be stored as (REGULAR_SEASON_WEEKS + 5) — guards
  // against marking playoffs complete just because we haven't synced
  // the later rounds yet.
  let playoffsCompleteAt = existing?.playoffs_complete_at ?? null;
  if (seasonType === 3 && !playoffsCompleteAt) {
    const postseasonGames = games.filter((g) => g.season_type === 3);
    if (postseasonGames.length > 0) {
      const maxWeek = Math.max(...postseasonGames.map((g) => g.week));
      const finalWeekGames = postseasonGames.filter((g) => g.week === maxWeek);
      if (maxWeek === REGULAR_SEASON_WEEKS + 5 && finalWeekGames.every((g) => g.status === "final")) {
        playoffsCompleteAt = new Date().toISOString();
      }
    }
  }

  await supabase.from("nwpe_season_state").upsert({
    season,
    season_type: seasonType,
    current_week: storedWeek,
    regular_season_complete_at: regularSeasonCompleteAt,
    playoffs_complete_at: playoffsCompleteAt,
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
    const primaryParams: Record<string, string | number> = { limit: 100 };
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
    const espnWeekNumber = primaryData?.week?.number ?? overrideWeek ?? 1;
    const storedWeekNumber = seasonType === 3 ? REGULAR_SEASON_WEEKS + espnWeekNumber : espnWeekNumber;

    // Sync ahead LOOKAHEAD_WEEKS and behind LOOKBACK_WEEKS, WITHIN the
    // current season_type — once ESPN's own "current" pointer flips from
    // regular season to postseason, lookahead/lookback naturally follow
    // along inside the new season_type on the next run. Skipped when a
    // caller explicitly pins a single week (manual backfill/testing).
    const weeksToFetch: { events: any[]; espnWeek: number }[] = [
      { events: primaryData?.events ?? [], espnWeek: espnWeekNumber },
    ];
    if (overrideWeek === undefined) {
      const maxAheadWeek = seasonType === 3 ? espnWeekNumber + LOOKAHEAD_WEEKS : REGULAR_SEASON_WEEKS;
      const aheadWeeks = Array.from(
        { length: Math.max(0, maxAheadWeek - espnWeekNumber) },
        (_, i) => espnWeekNumber + i + 1,
      );
      const behindWeeks = Array.from({ length: LOOKBACK_WEEKS }, (_, i) => espnWeekNumber - i - 1).filter((wk) => wk >= 1);
      const extras = await Promise.all(
        [...aheadWeeks, ...behindWeeks].map(async (wk) => {
          try {
            const res = await fetch(scoreboardUrl({ limit: 100, week: wk, year: seasonYear, seasontype: seasonType }));
            if (!res.ok) return { events: [], espnWeek: wk };
            const data = await res.json();
            return { events: data?.events ?? [], espnWeek: wk };
          } catch {
            return { events: [], espnWeek: wk };
          }
        }),
      );
      weeksToFetch.push(...extras);
    }

    const mapped: MappedGame[] = weeksToFetch
      .flatMap(({ events, espnWeek }) => {
        const storedWeek = seasonType === 3 ? REGULAR_SEASON_WEEKS + espnWeek : espnWeek;
        return events.map((ev: any) => mapEvent(ev, storedWeek, seasonType));
      })
      .filter((g): g is MappedGame => g != null);

    const actualWeeks = [...new Set(mapped.map((g) => g.week))].sort((a, b) => a - b);

    if (dryRun) {
      return new Response(
        JSON.stringify({
          ok: true, dry_run: true, season: seasonYear, season_type: seasonType, week: storedWeekNumber,
          weeks_synced: actualWeeks, count: mapped.length, games: mapped,
        }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data: existingGames, error: existingErr } = await supabase
      .from("nwpe_games")
      .select("id, espn_event_id, home_team, away_team")
      .eq("season", seasonYear);
    if (existingErr) throw existingErr;

    const existingByEspnId = new Map<string, { id: string; home_team: string; away_team: string }>();
    for (const g of existingGames ?? []) existingByEspnId.set(g.espn_event_id, g);

    const toInsert: any[] = [];
    const toUpdate: any[] = [];
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
      toUpdate.push({
        id: existing.id,
        // Required even though this row always takes the ON CONFLICT DO
        // UPDATE path below — see wpe-sync-games' identical note: Postgres
        // validates NOT NULL columns while constructing the candidate
        // INSERT row, before conflict resolution is considered.
        season: seasonYear,
        espn_event_id: game.espn_event_id,
        season_type: game.season_type,
        week: game.week,
        home_team: game.home_team,
        away_team: game.away_team,
        home_team_abbr: game.home_team_abbr,
        away_team_abbr: game.away_team_abbr,
        home_team_logo: game.home_team_logo,
        away_team_logo: game.away_team_logo,
        status: game.status,
        status_detail: game.status_detail,
        home_score: game.home_score,
        away_score: game.away_score,
        winner_team: game.winner_team,
        spread: game.spread,           // ALWAYS the latest value — never frozen on this row, see file header
        favorite_team: game.favorite_team,
        kickoff_at: game.kickoff_at,
        updated_at: new Date().toISOString(),
      });
    }

    // Batched as a single upsert keyed on `id` rather than one .update()
    // per game — same perf fix as every other sync function in this
    // repo (see wpe-sync-games' note: per-row updates blew past pg_net's
    // 5s cron timeout once game counts got large).
    if (toUpdate.length > 0) {
      const { error: updateErr } = await supabase.from("nwpe_games").upsert(toUpdate, { onConflict: "id" });
      if (updateErr) throw updateErr;
    }

    if (toInsert.length > 0) {
      const { error: insertErr } = await supabase.from("nwpe_games").insert(toInsert);
      if (insertErr) throw insertErr;
    }

    for (const { id, game } of changedGames) {
      const { error: changeErr } = await supabase.rpc("nwpe_apply_matchup_change", {
        p_game_id: id,
        p_home_team: game.home_team,
        p_away_team: game.away_team,
        p_spread: game.spread,
        p_favorite_team: game.favorite_team,
        p_kickoff_at: game.kickoff_at,
      });
      if (changeErr) throw changeErr;
    }

    const revealedEspnIds = mapped.filter((g) => g.week <= storedWeekNumber).map((g) => g.espn_event_id);
    await maintainSpreadLocks(supabase, seasonYear, revealedEspnIds);

    const { error: recalcErr } = await supabase.rpc("nwpe_recalculate_all_scores");
    if (recalcErr) throw recalcErr;

    await upsertSeasonState(supabase, seasonYear, seasonType, storedWeekNumber, mapped);

    return new Response(
      JSON.stringify({
        ok: true, season: seasonYear, season_type: seasonType, week: storedWeekNumber, weeks_synced: actualWeeks,
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
