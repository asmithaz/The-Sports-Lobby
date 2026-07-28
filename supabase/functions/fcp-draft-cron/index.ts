// FedEx Cup Playoffs — draft scheduling cron
//
// Three jobs, run together so a single scheduled invocation covers all:
//  1. Auto-start any pending draft whose draft_time has passed. This backs
//     up the client-side auto-start in golf/fedex-playoffs/draft/draft.js
//     (which only fires if a league member happens to have the lobby page
//     open at draft_time) with a server-side guarantee that doesn't depend
//     on anyone's browser being open.
//  2. Email every member of a league whose draft starts within the next 30
//     minutes, once, via fcp_leagues.draft_reminder_sent_at as a dedupe flag.
//  3. Autopick any active draft whose current pick's clock has expired.
//     This backs up the client-side watcher in draft.js (startAutopickWatcher,
//     a 3s poll) — if nobody has the draft board open, picks would otherwise
//     never advance and the draft would stall indefinitely. fcp_autopick_if_expired
//     only advances one pick per call, so a stalled draft needs the loop below
//     to catch it back up to the present.
//
// Triggered by:
//  - A GitHub Actions cron job every 5 minutes
//    (.github/workflows/fcp-draft-cron.yml)
//
// Deploy with: supabase functions deploy fcp-draft-cron

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const REMINDER_WINDOW_MS = 30 * 60 * 1000;
const DASHBOARD_URL = "https://thesportslobby.com/golf/fedex-playoffs/dashboard/";

// Upper bound on autopicks per league per invocation, so a pathological
// state (e.g. pick_deadline stuck in the past because a draft can never
// finish) can't loop forever — well above any realistic roster_size *
// draft_order length for this format.
const MAX_AUTOPICKS_PER_LEAGUE = 200;

function reminderEmailHtml(leagueName: string, draftTime: string): string {
  const when = new Date(draftTime).toLocaleString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  });

  return `
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1117;padding:32px 16px;">
    <div style="max-width:480px;margin:0 auto;background:#1a1d27;border:1px solid rgba(255,255,255,0.08);border-radius:10px;overflow:hidden;">
      <div style="padding:20px 28px;border-bottom:1px solid rgba(255,255,255,0.08);">
        <span style="font-size:13px;font-weight:700;letter-spacing:0.08em;color:#4ade80;text-transform:uppercase;">The Sports Lobby</span>
      </div>
      <div style="padding:28px;">
        <h1 style="font-size:20px;font-weight:700;margin:0 0 16px 0;color:#f0f0f2;">Draft starts in 30 minutes</h1>
        <div style="font-size:14px;line-height:1.6;color:#8b8fa8;">
          <p style="margin:0 0 16px 0;">The draft for <strong style="color:#f0f0f2;">${leagueName}</strong> starts at ${when}. Be in the lobby when the clock hits zero — the draft begins automatically, whether or not you're there.</p>
          <a href="${DASHBOARD_URL}" style="display:inline-block;margin-top:8px;padding:10px 20px;background:#4ade80;color:#0f1117;font-weight:700;font-size:14px;text-decoration:none;border-radius:6px;">Open Dashboard</a>
        </div>
      </div>
      <div style="padding:16px 28px;border-top:1px solid rgba(255,255,255,0.08);font-size:12px;color:#555870;">
        2026 The Sports Lobby. All rights reserved.
      </div>
    </div>
  </div>`;
}

async function sendReminderEmail(to: string, leagueName: string, draftTime: string): Promise<void> {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) throw new Error("RESEND_API_KEY is not set");
  const from = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <onboarding@resend.dev>";

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to,
      subject: `Draft starts in 30 minutes — ${leagueName}`,
      html: reminderEmailHtml(leagueName, draftTime),
    }),
  });

  if (!resendRes.ok) {
    const result = await resendRes.json().catch(() => ({}));
    throw new Error(result?.message ?? `Resend request failed: ${resendRes.status}`);
  }
}

Deno.serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const now = new Date();
  const nowIso = now.toISOString();
  const reminderWindowEndIso = new Date(now.getTime() + REMINDER_WINDOW_MS).toISOString();

  const started: string[] = [];
  const startErrors: Record<string, string> = {};
  const reminded: string[] = [];
  const reminderErrors: Record<string, string> = {};

  // ── 1. Auto-start drafts whose draft_time has arrived ──────────────────
  const { data: dueLeagues, error: dueErr } = await supabase
    .from("fcp_leagues")
    .select("league_id, season")
    .eq("draft_status", "pending")
    .not("draft_time", "is", null)
    .lte("draft_time", nowIso);

  if (dueErr) {
    return new Response(JSON.stringify({ ok: false, error: dueErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  for (const league of dueLeagues ?? []) {
    const { error } = await supabase.rpc("fcp_start_draft", { p_league_id: league.league_id });
    if (error) {
      startErrors[league.league_id] = error.message;
    } else {
      started.push(league.league_id);
    }
  }

  // ── 2. Autopick active drafts whose current pick has timed out ─────────
  const autopicked: Record<string, number> = {};
  const autopickErrors: Record<string, string> = {};

  const { data: stalledLeagues, error: stalledErr } = await supabase
    .from("fcp_leagues")
    .select("league_id")
    .eq("draft_status", "active")
    .not("pick_deadline", "is", null)
    .lte("pick_deadline", nowIso);

  if (stalledErr) {
    return new Response(JSON.stringify({ ok: false, error: stalledErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  for (const league of stalledLeagues ?? []) {
    let picksMade = 0;
    try {
      for (; picksMade < MAX_AUTOPICKS_PER_LEAGUE; picksMade++) {
        const { error } = await supabase.rpc("fcp_autopick_if_expired", { p_league_id: league.league_id });
        if (error) throw error;

        const { data: state, error: stateErr } = await supabase
          .from("fcp_leagues")
          .select("draft_status, pick_deadline")
          .eq("league_id", league.league_id)
          .eq("draft_status", "active")
          .maybeSingle();
        if (stateErr) throw stateErr;

        // Draft finished, or the next pick's clock hasn't expired yet —
        // either way, nothing left to catch up on for this league.
        if (!state || !state.pick_deadline || new Date(state.pick_deadline) > now) break;
      }
    } catch (err) {
      autopickErrors[league.league_id] = err instanceof Error ? err.message : String(err);
      continue;
    }
    if (picksMade > 0) autopicked[league.league_id] = picksMade;
  }

  // ── 3. Email members of leagues drafting within 30 minutes ─────────────
  const { data: soonLeagues, error: soonErr } = await supabase
    .from("fcp_leagues")
    .select("league_id, season, draft_time, leagues(name)")
    .eq("draft_status", "pending")
    .is("draft_reminder_sent_at", null)
    .not("draft_time", "is", null)
    .gt("draft_time", nowIso)
    .lte("draft_time", reminderWindowEndIso);

  if (soonErr) {
    return new Response(
      JSON.stringify({ ok: true, started, startErrors, autopicked, autopickErrors, reminded, reminderErrors, reminderQueryError: soonErr.message }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  for (const league of soonLeagues ?? []) {
    const leagueName = (league as any).leagues?.name ?? "your league";

    const { data: members, error: membersErr } = await supabase
      .from("league_members")
      .select("user_id")
      .eq("league_id", league.league_id);

    if (membersErr) {
      reminderErrors[league.league_id] = membersErr.message;
      continue;
    }

    const emails = (
      await Promise.all(
        (members ?? []).map(async (m) => {
          const { data, error } = await supabase.auth.admin.getUserById(m.user_id);
          if (error || !data?.user?.email) return null;
          return data.user.email;
        }),
      )
    ).filter((e): e is string => !!e);

    const results = await Promise.allSettled(
      emails.map((to) => sendReminderEmail(to, leagueName, league.draft_time as string)),
    );
    const failures = results.filter((r) => r.status === "rejected");
    if (failures.length > 0) {
      reminderErrors[league.league_id] = `${failures.length}/${emails.length} sends failed`;
    }

    // Mark as sent even on partial failure — this is a best-effort nudge,
    // not a guaranteed delivery, and we don't want a single bad address
    // to retry-spam the rest of the league every 5 minutes.
    await supabase
      .from("fcp_leagues")
      .update({ draft_reminder_sent_at: nowIso })
      .eq("league_id", league.league_id)
      .eq("season", league.season);

    reminded.push(league.league_id);
  }

  return new Response(
    JSON.stringify({ ok: true, started, startErrors, autopicked, autopickErrors, reminded, reminderErrors }),
    { headers: { "Content-Type": "application/json" } },
  );
});
