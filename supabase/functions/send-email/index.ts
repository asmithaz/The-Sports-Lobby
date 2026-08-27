// Generic transactional email sender via Resend, used by:
//  - golf/fedex-playoffs/invite/index.html (invite emails)
//  - join/index.html (join confirmation)
//
// Requires a valid user JWT (default Edge Function auth) — only logged-in
// pages of this app can trigger a send.
//
// Secrets required (set with `supabase secrets set NAME=value`):
//  - RESEND_API_KEY   (required)
//  - RESEND_FROM_EMAIL (optional — defaults to Resend's sandbox sender,
//    which can only deliver to your own verified Resend account email
//    until a real domain is verified)
//
// Deploy with: supabase functions deploy send-email

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY is not set");
    }
    const from = Deno.env.get("RESEND_FROM_EMAIL") ?? "The Sports Lobby <onboarding@resend.dev>";

    const { to, subject, html } = await req.json();
    if (!to || !subject || !html) {
      throw new Error("Missing required fields: to, subject, html");
    }

    const resendRes = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from, to, subject, html }),
    });

    const result = await resendRes.json();
    if (!resendRes.ok) {
      throw new Error(result?.message ?? `Resend request failed: ${resendRes.status}`);
    }

    return new Response(
      JSON.stringify({ ok: true, id: result?.id }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
