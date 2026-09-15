// NFL Weekly Pick 'Em — pick reminder emails
//
// For every active/pending league, finds the current week's earliest kickoff
// and emails any member who opted into a reminder (nwpe_reminder_prefs,
// set on the Settings page — optional, off by default) once that
// threshold (48h / 24h / 2h before kickoff) has passed, IF they still
// have unset picks for that week. One email per (league, member, week,
// interval), ever — nwpe_reminder_log's unique constraint is the
// dedup/claim mechanism (see schema.sql SECTION 11), so polling every
// 15 minutes (more often than any reminder needs to fire) is harmless.
//
// Uses nwpe_get_slate_unchecked (schema.sql SECTION 10) instead of the
// regular nwpe_get_slate RPC — this is a service-role job with no real
// user session, and nwpe_get_slate's own membership check would reject
// every call (auth.uid() is NULL under a service-role key).
//
// Triggered by pg_cron + pg_net every 15 min (schema.sql SECTION 12),
// same pattern as nwpe-sync-games / every other sync function in this
// repo. Emails go straight through Resend, not the shared send-email
// Edge Function (which requires a logged-in user's JWT this cron
// doesn't have) — same reasoning CFB Weekly's own reminder function
// applies.
//
// Call with ?dry_run=true to see what WOULD be sent/claimed without
// actually sending or writing to nwpe_reminder_log.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const LOCK_BUFFER_MS = 5 * 60 * 1000; // same 5-minutes-before-kickoff rule as nwpe_is_game_locked

function pickIsComplete(pick: any, needsConfidence: boolean) {
  return !!pick?.picked_team && (!needsConfidence || pick.confidence_points != null);
}

async function sendForLeague(supabase: any, league: { id: string; name: string; current_season: number }, week: number, dryRun: boolean, results: any[]) {
  const { data: weekGames } = await supabase.rpc("nwpe_get_slate_unchecked", {
    p_league_id: league.id,
    p_season: league.current_season,
    p_week: week,
  });
  if (!weekGames || weekGames.length === 0) return;

  const kickoffs = weekGames.map((g: any) => g.kickoff_at).filter(Boolean).map((k: string) => new Date(k).getTime());
  if (kickoffs.length === 0) return;
  const earliestKickoffMs = Math.min(...kickoffs);

  const { data: prefs } = await supabase
    .from("nwpe_reminder_prefs")
    .select("user_id, hours_before")
    .eq("league_id", league.id)
    .not("hours_before", "is", null);
  if (!prefs || prefs.length === 0) return;

  const { data: nwpeLeagueRow } = await supabase
    .from("nwpe_leagues")
    .select("scoring_mode")
    .eq("league_id", league.id)
    .eq("season", league.current_season)
    .maybeSingle();
  // Postseason weeks never use confidence (see nwpe_submit_pick), but
  // weekGames here is a single week's slate, so this per-league flag is
  // still correct for whichever week is actually being checked — a
  // playoff week's picks simply never carry a confidence_points value
  // to begin with, so pickIsComplete's confidence check is a harmless
  // no-op for those.
  const needsConfidence = nwpeLeagueRow?.scoring_mode === "confidence";

  const { data: weekPicks } = await supabase
    .from("nwpe_picks")
    .select("user_id, game_id, picked_team, confidence_points")
    .eq("league_id", league.id)
    .eq("season", league.current_season)
    .eq("week", week);

  const picksByUser = new Map<string, Map<string, any>>();
  for (const p of weekPicks ?? []) {
    if (!picksByUser.has(p.user_id)) picksByUser.set(p.user_id, new Map());
    picksByUser.get(p.user_id)!.set(p.game_id, p);
  }

  const nowMs = Date.now();
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <noreply@thesportslobby.com>";

  for (const pref of prefs) {
    const dueAtMs = earliestKickoffMs - pref.hours_before * 60 * 60 * 1000;
    if (nowMs < dueAtMs) continue;

    if (!dryRun) {
      const { data: claimed } = await supabase
        .from("nwpe_reminder_log")
        .upsert(
          { league_id: league.id, user_id: pref.user_id, season: league.current_season, week, hours_before: pref.hours_before },
          { onConflict: "league_id,user_id,season,week,hours_before", ignoreDuplicates: true },
        )
        .select();
      if (!claimed || claimed.length === 0) continue; // already sent
    }

    const userPicks = picksByUser.get(pref.user_id);
    const unsetGames = weekGames.filter((g: any) => {
      const kickoffMs = g.kickoff_at ? new Date(g.kickoff_at).getTime() : null;
      const locked = kickoffMs != null && nowMs >= kickoffMs - LOCK_BUFFER_MS;
      if (locked) return false; // already locked either way — nothing left to remind about on this one
      return !pickIsComplete(userPicks?.get(g.id), needsConfidence);
    });
    if (unsetGames.length === 0) continue; // fully caught up already — logged above so this interval won't re-check

    if (dryRun) {
      results.push({ league: league.name, user_id: pref.user_id, hours_before: pref.hours_before, unset: unsetGames.length });
      continue;
    }

    if (!resendKey) continue;
    const { data: userRes } = await supabase.auth.admin.getUserById(pref.user_id);
    const email = userRes?.user?.email;
    if (!email) continue;

    const pickCount = unsetGames.length;
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: email,
        subject: `${pickCount} pick${pickCount === 1 ? "" : "s"} still need${pickCount === 1 ? "s" : ""} to be made — Week ${week}`,
        html: `
          <p>You still have <strong>${pickCount} game${pickCount === 1 ? "" : "s"}</strong> unpicked for Week ${week} in <strong>${league.name}</strong>, and the earliest kickoff is coming up.</p>
          <p><a href="https://thesportslobby.com/nfl/weekly-pick-em/picks/?league_id=${league.id}" style="display:inline-block;padding:10px 20px;background:#4ade80;color:#0f1117;font-weight:600;border-radius:6px;text-decoration:none;">Make Your Picks</a></p>
        `,
      }),
    });
    results.push({ league: league.name, user_id: pref.user_id, hours_before: pref.hours_before, unset: pickCount, sent: true });
  }
}

async function sendPickReminders(supabase: any, dryRun: boolean) {
  const results: any[] = [];

  // Same status set nwpe_recalculate_all_scores treats as live — a new
  // league starts 'pending' (setup/index.html) and picks/scoring already
  // work in that state, so reminders need to cover it too, not just
  // 'active'.
  const { data: leagues } = await supabase
    .from("leagues")
    .select("id, name, current_season")
    .eq("game_type", "nfl-weekly-pick-em")
    .in("status", ["active", "pending"]);
  if (!leagues || leagues.length === 0) return results;

  const seasons = [...new Set(leagues.map((l: any) => l.current_season))];
  const { data: stateRows } = await supabase
    .from("nwpe_season_state")
    .select("season, current_week")
    .in("season", seasons);
  const currentWeekBySeason = new Map((stateRows ?? []).map((r: any) => [r.season, r.current_week]));

  for (const league of leagues) {
    const week = currentWeekBySeason.get(league.current_season);
    if (week == null) continue;
    await sendForLeague(supabase, league, week, dryRun, results);
  }

  return results;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const dryRun = url.searchParams.get("dry_run") === "true";

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const results = await sendPickReminders(supabase, dryRun);

    return new Response(
      JSON.stringify({ ok: true, dry_run: dryRun, sent_or_would_send: results.length, results }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
