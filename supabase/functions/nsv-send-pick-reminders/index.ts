// NFL Survivor Pool — pick reminder emails
//
// For every active/pending Survivor league, finds the current week's
// earliest kickoff and emails any STILL-ALIVE member who opted into a
// reminder (nsv_reminder_prefs, Settings page — optional, off by
// default) once that threshold (48h / 24h / 2h before kickoff) has
// passed, IF they haven't submitted this week's pick yet. One email
// per (league, member, week, interval), ever — nsv_reminder_log's
// unique constraint is the dedup/claim mechanism (schema.sql SECTION 5),
// so polling every 15 minutes is harmless.
//
// Eliminated members are filtered out entirely (nsv_status.is_alive) —
// reminding someone to pick after they're out of the pool is just noise.
//
// Uses nsv_get_slate_unchecked instead of the regular nsv_get_slate RPC
// — this is a service-role job with no real user session, and
// nsv_get_slate's membership check would reject every call.
//
// Triggered by pg_cron + pg_net every 15 min (schema.sql SECTION 9).
// Emails go straight through Resend, not the shared send-email Edge
// Function, same reasoning every other reminder cron in this repo uses.
//
// Call with ?dry_run=true to see what WOULD be sent/claimed without
// actually sending or writing to nsv_reminder_log.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

async function sendForLeague(supabase: any, league: { id: string; name: string; current_season: number }, week: number, dryRun: boolean, results: any[]) {
  const { data: weekGames } = await supabase.rpc("nsv_get_slate_unchecked", {
    p_league_id: league.id,
    p_season: league.current_season,
    p_week: week,
  });
  if (!weekGames || weekGames.length === 0) return;

  const kickoffs = weekGames.map((g: any) => g.kickoff_at).filter(Boolean).map((k: string) => new Date(k).getTime());
  if (kickoffs.length === 0) return;
  const earliestKickoffMs = Math.min(...kickoffs);

  const { data: prefs } = await supabase
    .from("nsv_reminder_prefs")
    .select("user_id, hours_before")
    .eq("league_id", league.id)
    .not("hours_before", "is", null);
  if (!prefs || prefs.length === 0) return;

  const { data: statusRows } = await supabase
    .from("nsv_status")
    .select("user_id, is_alive")
    .eq("league_id", league.id)
    .eq("season", league.current_season)
    .eq("is_alive", false);
  const eliminated = new Set((statusRows ?? []).map((r: any) => r.user_id));
  const alivePrefs = prefs.filter((p: any) => !eliminated.has(p.user_id));
  if (alivePrefs.length === 0) return;

  const { data: weekPicks } = await supabase
    .from("nsv_picks")
    .select("user_id")
    .eq("league_id", league.id)
    .eq("season", league.current_season)
    .eq("week", week);
  const pickedUserIds = new Set((weekPicks ?? []).map((p: any) => p.user_id));

  const nowMs = Date.now();
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <noreply@thesportslobby.com>";

  for (const pref of alivePrefs) {
    const dueAtMs = earliestKickoffMs - pref.hours_before * 60 * 60 * 1000;
    if (nowMs < dueAtMs) continue;
    if (pickedUserIds.has(pref.user_id)) continue; // already picked this week

    if (!dryRun) {
      const { data: claimed } = await supabase
        .from("nsv_reminder_log")
        .upsert(
          { league_id: league.id, user_id: pref.user_id, season: league.current_season, week, hours_before: pref.hours_before },
          { onConflict: "league_id,user_id,season,week,hours_before", ignoreDuplicates: true },
        )
        .select();
      if (!claimed || claimed.length === 0) continue; // already sent
    }

    if (dryRun) {
      results.push({ league: league.name, user_id: pref.user_id, hours_before: pref.hours_before, needs_pick: true });
      continue;
    }

    if (!resendKey) continue;
    const { data: userRes } = await supabase.auth.admin.getUserById(pref.user_id);
    const email = userRes?.user?.email;
    if (!email) continue;

    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: email,
        subject: `Your Survivor pick for Week ${week} is still open`,
        html: `
          <p>You haven't made your Week ${week} pick yet in <strong>${league.name}</strong>, and the earliest kickoff is coming up. No pick means no life spent trying — but a locked week with no pick is an automatic elimination.</p>
          <p><a href="https://thesportslobby.com/nfl/survivor/picks/?league_id=${league.id}" style="display:inline-block;padding:10px 20px;background:#4ade80;color:#0f1117;font-weight:600;border-radius:6px;text-decoration:none;">Make Your Pick</a></p>
        `,
      }),
    });
    results.push({ league: league.name, user_id: pref.user_id, hours_before: pref.hours_before, sent: true });
  }
}

async function sendPickReminders(supabase: any, dryRun: boolean) {
  const results: any[] = [];

  const { data: leagues } = await supabase
    .from("leagues")
    .select("id, name, current_season")
    .eq("game_type", "nfl-survivor")
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
