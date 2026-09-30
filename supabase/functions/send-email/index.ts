// Transactional email sender via Resend, used by:
//  - */invite/index.html (invite emails, kind: "invite")
//  - join/index.html (join confirmation, kind: "join_confirmation")
//
// Requires a valid user JWT (default Edge Function auth), same as before —
// but that alone used to be the ONLY check: the old version took a raw
// {to, subject, html} straight from the client and forwarded it to Resend
// unmodified, so any signed-up user could call this function directly
// (bypassing the UI) and send arbitrary HTML, with an arbitrary subject, to
// any address — an open relay riding on thesportslobby.com's sending
// domain. Now the client only ever supplies a `kind` + `league_id` (+
// `emails` for invites); the recipient (for join_confirmation) and all
// email content are derived server-side, and league membership is checked
// before anything is sent.
//
// Secrets required (set with `supabase secrets set NAME=value`):
//  - RESEND_API_KEY    (required)
//  - RESEND_FROM_EMAIL (optional — defaults to Resend's sandbox sender,
//    which can only deliver to your own verified Resend account email
//    until a real domain is verified)
//  - SITE_URL          (optional — defaults to https://thesportslobby.com)
//
// SUPABASE_URL / SUPABASE_ANON_KEY are auto-injected by the platform.
//
// Deploy with: supabase functions deploy send-email

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_INVITE_EMAILS = 25;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const GAME_META: Record<string, { label: string; prefix: string }> = {
  "fedex-playoffs": { label: "FedEx Cup Playoffs fantasy golf", prefix: "fcp" },
  "cfb-weekly-pick-em": { label: "College Football Weekly Pick 'Em", prefix: "wpe" },
  "cfb-bowl-season-pick-em": { label: "College Football Bowl Season Pick 'Em", prefix: "bpe" },
  "nfl-weekly-pick-em": { label: "NFL Weekly Pick 'Em", prefix: "nwpe" },
};

function escapeHtml(str: string) {
  return String(str ?? "").replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!
  ));
}

function wrapEmail(title: string, bodyHtml: string) {
  return `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1117;padding:32px 16px;">
        <div style="max-width:480px;margin:0 auto;background:#1a1d27;border:1px solid rgba(255,255,255,0.08);border-radius:10px;overflow:hidden;">
            <div style="padding:20px 28px;border-bottom:1px solid rgba(255,255,255,0.08);">
                <span style="font-size:13px;font-weight:700;letter-spacing:0.08em;color:#4ade80;text-transform:uppercase;">The Sports Lobby</span>
            </div>
            <div style="padding:28px;">
                <h1 style="font-size:20px;font-weight:700;margin:0 0 16px 0;color:#f0f0f2;">${title}</h1>
                <div style="font-size:14px;line-height:1.6;color:#8b8fa8;">${bodyHtml}</div>
            </div>
            <div style="padding:16px 28px;border-top:1px solid rgba(255,255,255,0.08);font-size:12px;color:#555870;">
                2026 The Sports Lobby. All rights reserved.
            </div>
        </div>
    </div>`;
}

function emailButton(href: string, label: string) {
  return `<a href="${href}" style="display:inline-block;margin-top:8px;padding:10px 20px;background:#4ade80;color:#0f1117;font-weight:700;font-size:14px;text-decoration:none;border-radius:6px;">${label}</a>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization header");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    // Scoped to the calling user — runs under RLS, not the service role.
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await userClient.auth.getUser();
    if (!user) throw new Error("Not authenticated");

    const { kind, league_id, emails } = await req.json();
    if (!league_id) throw new Error("Missing league_id");

    const { data: membership } = await userClient
      .from("league_members")
      .select("league_id")
      .eq("league_id", league_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!membership) throw new Error("Not a member of this league");

    const { data: league, error: leagueErr } = await userClient
      .from("leagues")
      .select("name, game_type, invite_code")
      .eq("id", league_id)
      .single();
    if (leagueErr || !league) throw new Error("League not found");

    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) throw new Error("RESEND_API_KEY is not set");
    const from = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <onboarding@resend.dev>";
    const siteUrl = Deno.env.get("SITE_URL") ?? "https://thesportslobby.com";

    async function send(to: string, subject: string, html: string) {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendApiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to, subject, html }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result?.message ?? `Resend request failed: ${res.status}`);
      return result;
    }

    if (kind === "invite") {
      const meta = GAME_META[league.game_type as string];
      if (!meta) throw new Error("Unsupported game type");

      if (!Array.isArray(emails) || emails.length === 0) throw new Error("Missing emails");
      if (emails.length > MAX_INVITE_EMAILS) throw new Error(`Too many recipients (max ${MAX_INVITE_EMAILS})`);
      const validEmails = [...new Set(emails.filter((e: unknown) => typeof e === "string" && EMAIL_RE.test(e)))];
      if (validEmails.length === 0) throw new Error("No valid email addresses");

      const inviteLink = `${siteUrl}/join/?code=${meta.prefix}-${(league.invite_code as string).toLowerCase()}`;
      const subject = `You're invited to join ${league.name} on The Sports Lobby`;
      const body = `
        <p>You've been invited to join <strong>${escapeHtml(league.name as string)}</strong>, a ${meta.label} league on The Sports Lobby.</p>
        ${emailButton(inviteLink, "Join League")}
        <p style="margin-top:16px;font-size:12px;">Or copy this link: ${escapeHtml(inviteLink)}</p>
      `;
      const html = wrapEmail("You're invited!", body);

      const results = await Promise.allSettled(validEmails.map((to) => send(to as string, subject, html)));
      const sent = results.filter((r) => r.status === "fulfilled").length;
      const failed = results.length - sent;

      return new Response(
        JSON.stringify({ ok: failed === 0, sent, failed }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (kind === "join_confirmation") {
      if (!user.email) throw new Error("No email on account");
      const subject = `You've joined ${league.name} on The Sports Lobby`;
      const body = `<p>You're in! You've successfully joined <strong>${escapeHtml(league.name as string)}</strong>.</p>`;
      const html = wrapEmail("You're in!", body);
      await send(user.email, subject, html);

      return new Response(
        JSON.stringify({ ok: true }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    throw new Error("Unknown kind");
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err instanceof Error ? err.message : err) }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
