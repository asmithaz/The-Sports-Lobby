// CFB Bowl Season Pick 'Em — game/score sync
//
// Pulls the college football postseason schedule + live/final scores
// from ESPN's public scoreboard API, upserts them into `bpe_games`
// (cfb/bowl-season-pick-em/schema.sql), and recalculates every active
// league's standings. A game's `spread` is written only on first
// insert and never touched again on subsequent syncs — that's what
// keeps it frozen per "Bowl Season Pick 'Em.txt". If an already-known
// game's teams change (opt-out / vacated bid), picks on that game are
// cleared and every member of every Bowl Pick 'Em league is emailed.
//
// KNOWN OPEN RISK (see the build plan / rules doc): the exact query
// params below were derived from web UI URLs the user confirmed work
// (espn.com/college-football/scoreboard/_/week/1/year/{season}/seasontype/3
// for bowls, .../week/999/year/{season}/seasontype/3 for the CFP bracket),
// translated to the JSON API host already used elsewhere in this repo.
// The JSON API's param names are NOT guaranteed identical to the web
// UI's — verify with ?dry_run=true against real data once bowl season
// actually starts, before trusting the unattended cron. Tier classification
// within the CFP response (R1 vs QF vs SF vs Championship) is a best-effort
// text match against the event's name/notes and may need a one-off manual
// correction (`UPDATE bpe_games SET tier = ...`) for a misclassified game —
// acceptable at ~46 rows/season, not worth a UI.
//
// Triggered by:
//  - A GitHub Actions cron every 15 minutes during bowl season
//    (.github/workflows/bpe-sync-games.yml)
//  - The "Refresh" button on the Bowl Pick 'Em dashboard
//  - Manually with ?dry_run=true to inspect the mapped output without writing
//
// Deploy with: supabase functions deploy bpe-sync-games

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

// site.api.espn.com started returning 403 to non-browser clients on
// 2026-08-19 (confirmed across unrelated sports/endpoints on that
// subdomain, so it's an ESPN-side block, not a golf-specific issue —
// see fcp-sync-scores/index.ts, which hit this first).
// site.web.api.espn.com — the host ESPN's own site JS calls — serves the
// identical scoreboard payload shape and isn't blocked.
const ESPN_BASE = "https://site.web.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard";

function bowlsUrl(season: number) {
  return `${ESPN_BASE}?seasontype=3&week=1&year=${season}`;
}
function cfpUrl(season: number) {
  return `${ESPN_BASE}?seasontype=3&week=999&year=${season}`;
}

interface MappedGame {
  espn_event_id: string;
  tier: "bowl" | "cfp_r1" | "cfp_qf" | "cfp_sf" | "cfp_championship";
  bowl_name: string;
  home_team: string;
  away_team: string;
  home_team_logo: string | null;
  away_team_logo: string | null;
  favorite_team: string | null;
  spread: number | null;
  kickoff_at: string | null;
  status: "scheduled" | "live" | "final";
  home_score: number | null;
  away_score: number | null;
  winner_team: string | null;
  ats_winner_team: string | null;
}

// Confirmed via a live ?raw=true inspection (2026-08): ESPN's `event.name`/
// `shortName` are literally "TBD at TBD" until matchups are set, useless for
// classification — but `competition.notes[0].headline` reliably carries the
// real bowl/round name even while teams are still TBD (e.g. "Cricket
// Celebration Bowl", "College Football Playoff First Round Game"). Applied
// uniformly to every event regardless of which of the two ESPN calls it came
// from, so a CFP game misfiled into the "bowls" response (or vice versa)
// still classifies correctly instead of silently trusting the source call.
function classifyTier(headline: string): MappedGame["tier"] {
  const h = headline.toLowerCase();
  if (h.includes("national championship") || h.includes("championship game")) return "cfp_championship";
  if (h.includes("semifinal")) return "cfp_sf";
  if (h.includes("quarterfinal")) return "cfp_qf";
  if (h.includes("first round")) return "cfp_r1";
  return "bowl";
}

function statusFor(competition: any): "scheduled" | "live" | "final" {
  const state = String(competition?.status?.type?.state ?? "").toLowerCase();
  if (state === "post") return "final";
  if (state === "in") return "live";
  return "scheduled";
}

function mapEvent(ev: any): MappedGame | null {
  const competition = ev?.competitions?.[0];
  const competitors: any[] = competition?.competitors ?? [];
  if (competitors.length !== 2) return null;

  const home = competitors.find((c) => c.homeAway === "home");
  const away = competitors.find((c) => c.homeAway === "away");
  // `team.isActive === false` (with displayName/abbreviation literally "TBD"
  // and a negative placeholder id) is how ESPN marks a not-yet-determined
  // matchup — confirmed via live inspection. A plain falsy-displayName check
  // doesn't catch this, since "TBD" is itself a non-empty, truthy string.
  if (!home?.team || !away?.team || home.team.isActive === false || away.team.isActive === false) {
    return null; // matchup not yet set — not pickable yet
  }

  const headline = String(competition?.notes?.[0]?.headline ?? ev?.name ?? ev?.shortName ?? "");
  const tier = classifyTier(headline);

  const odds = competition?.odds?.[0];
  let favoriteTeam: string | null = null;
  let spread: number | null = null;
  if (odds) {
    // ESPN typically reports `spread` as a signed number from the home
    // team's perspective (negative = home favored). Falls back to
    // parsing `details` (e.g. "TEAM -6.5") if the numeric field is absent.
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
      : null; // a tie is theoretically impossible in CFB, but don't crash if it happens
    if (spread != null && favoriteTeam != null) {
      const favIsHome = favoriteTeam === home.team.displayName;
      const margin = favIsHome ? homeScore - awayScore : awayScore - homeScore;
      atsWinnerTeam = margin > spread ? favoriteTeam
        : margin < spread ? (favIsHome ? away.team.displayName : home.team.displayName)
        : null; // push
    }
  }

  return {
    espn_event_id: String(ev.id),
    tier,
    bowl_name: headline,
    home_team: home.team.displayName,
    away_team: away.team.displayName,
    home_team_logo: home.team.logo ?? null,
    away_team_logo: away.team.logo ?? null,
    favorite_team: favoriteTeam,
    spread,
    kickoff_at: ev?.date ?? null,
    status,
    home_score: homeScore,
    away_score: awayScore,
    winner_team: winnerTeam,
    ats_winner_team: atsWinnerTeam,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const dryRun = url.searchParams.get("dry_run") === "true";
    const rawInspect = url.searchParams.get("raw") === "true";
    const season = parseInt(url.searchParams.get("season") ?? String(new Date().getFullYear()), 10);

    if (rawInspect) {
      const [bRes, cRes] = await Promise.all([fetch(bowlsUrl(season)), fetch(cfpUrl(season))]);
      const bData = await bRes.json();
      const cData = await cRes.json();
      return new Response(
        JSON.stringify({
          bowl_sample: (bData?.events ?? []).slice(0, 1),
          cfp_sample: (cData?.events ?? []).slice(0, 4),
        }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const [bowlsRes, cfpRes] = await Promise.all([
      fetch(bowlsUrl(season)),
      fetch(cfpUrl(season)),
    ]);
    if (!bowlsRes.ok) throw new Error(`ESPN bowls request failed: ${bowlsRes.status}`);
    if (!cfpRes.ok) throw new Error(`ESPN CFP request failed: ${cfpRes.status}`);

    const bowlsData = await bowlsRes.json();
    const cfpData = await cfpRes.json();

    // Dedupe by event id — a CFP game could in principle surface in both
    // calls (e.g. if ESPN's "postseason week 1" ever included CFP first
    // round games directly); classifyTier() being source-independent means
    // it doesn't matter which copy wins.
    const seen = new Set<string>();
    const mapped: MappedGame[] = [
      ...(bowlsData?.events ?? []),
      ...(cfpData?.events ?? []),
    ]
      .map((ev: any) => mapEvent(ev))
      .filter((g: MappedGame | null): g is MappedGame => {
        if (g == null || seen.has(g.espn_event_id)) return false;
        seen.add(g.espn_event_id);
        return true;
      });

    if (dryRun) {
      return new Response(
        JSON.stringify({ ok: true, dry_run: true, season, count: mapped.length, games: mapped }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: existingGames, error: existingErr } = await supabase
      .from("bpe_games")
      .select("id, espn_event_id, home_team, away_team")
      .eq("season", season);
    if (existingErr) throw existingErr;

    const existingByEspnId = new Map<string, { id: string; home_team: string; away_team: string }>();
    for (const g of existingGames ?? []) existingByEspnId.set(g.espn_event_id, g);

    const toInsert: any[] = [];
    const changedGames: { id: string; game: MappedGame }[] = [];

    for (const game of mapped) {
      const existing = existingByEspnId.get(game.espn_event_id);
      if (!existing) {
        toInsert.push({ season, ...game });
        continue;
      }
      if (existing.home_team !== game.home_team || existing.away_team !== game.away_team) {
        changedGames.push({ id: existing.id, game });
        continue;
      }
      // Routine refresh — spread is intentionally excluded from this update.
      const { error: updateErr } = await supabase
        .from("bpe_games")
        .update({
          status: game.status,
          home_score: game.home_score,
          away_score: game.away_score,
          winner_team: game.winner_team,
          ats_winner_team: game.ats_winner_team,
          kickoff_at: game.kickoff_at,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existing.id);
      if (updateErr) throw updateErr;
    }

    if (toInsert.length > 0) {
      const { error: insertErr } = await supabase.from("bpe_games").insert(toInsert);
      if (insertErr) throw insertErr;
    }

    for (const { id, game } of changedGames) {
      const { error: changeErr } = await supabase.rpc("bpe_apply_matchup_change", {
        p_game_id: id,
        p_home_team: game.home_team,
        p_away_team: game.away_team,
        p_spread: game.spread,
        p_kickoff_at: game.kickoff_at,
      });
      if (changeErr) throw changeErr;
    }

    if (changedGames.length > 0) {
      await notifyMatchupChanges(supabase, season);
    }

    const { error: recalcErr } = await supabase.rpc("bpe_recalculate_all_scores");
    if (recalcErr) throw recalcErr;

    await maybeNotifyAllBowlsSet(supabase, season);

    return new Response(
      JSON.stringify({ ok: true, season, inserted: toInsert.length, matchup_changes: changedGames.length }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});

// Emails every member of every active Bowl Pick 'Em league that a
// matchup changed. No `profiles.email` column exists in this codebase —
// same admin lookup pattern as fcp-draft-cron/index.ts. Sent directly via
// Resend (not the shared send-email Edge Function, which requires a user
// JWT this service-role cron doesn't have — same reasoning fcp-draft-cron
// already applies).
async function notifyMatchupChanges(supabase: any, season: number) {
  const { data: leagues } = await supabase
    .from("leagues")
    .select("id")
    .eq("game_type", "cfb-bowl-season-pick-em")
    .eq("current_season", season);
  if (!leagues || leagues.length === 0) return;

  const leagueIds = leagues.map((l: any) => l.id);
  const { data: members } = await supabase
    .from("league_members")
    .select("user_id")
    .in("league_id", leagueIds);
  if (!members) return;

  const userIds = [...new Set(members.map((m: any) => m.user_id))];
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <noreply@thesportslobby.com>";
  if (!resendKey) return;

  for (const userId of userIds) {
    const { data: userRes } = await supabase.auth.admin.getUserById(userId);
    const email = userRes?.user?.email;
    if (!email) continue;

    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: email,
        subject: "A bowl matchup just changed",
        html: `<p>One of the bowl games in your Bowl Season Pick 'Em pool had a matchup change (team dropout, opt-out, or vacated bid). Any pick you'd already made on that game has been cleared — head back to your dashboard to re-pick it.</p>`,
      }),
    });
  }
}

// Fires once, the first time bpe_games reaches the season's expected
// count, to everyone who opted in via bpe_opt_in_bowls_set_notification.
async function maybeNotifyAllBowlsSet(supabase: any, season: number) {
  const { data: meta } = await supabase
    .from("bpe_season_meta")
    .select("expected_game_count, all_bowls_set_at")
    .eq("season", season)
    .maybeSingle();

  const expected = meta?.expected_game_count ?? 46;
  if (meta?.all_bowls_set_at) return; // already fired

  const { count } = await supabase
    .from("bpe_games")
    .select("id", { count: "exact", head: true })
    .eq("season", season);

  if ((count ?? 0) < expected) return;

  await supabase
    .from("bpe_season_meta")
    .upsert({ season, expected_game_count: expected, all_bowls_set_at: new Date().toISOString() });

  const { data: signups } = await supabase
    .from("bpe_notify_signups")
    .select("user_id")
    .eq("season", season)
    .is("notified_at", null);
  if (!signups || signups.length === 0) return;

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <noreply@thesportslobby.com>";
  if (!resendKey) return;

  for (const s of signups) {
    const { data: userRes } = await supabase.auth.admin.getUserById(s.user_id);
    const email = userRes?.user?.email;
    if (email) {
      await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: fromEmail,
          to: email,
          subject: "All bowl matchups are set!",
          html: `<p>Every bowl game (and CFP first-round matchup) for this season is now set. Head to your Bowl Season Pick 'Em dashboard to make your picks.</p>`,
        }),
      });
    }
    await supabase.from("bpe_notify_signups")
      .update({ notified_at: new Date().toISOString() })
      .eq("user_id", s.user_id).eq("season", season);
  }
}
