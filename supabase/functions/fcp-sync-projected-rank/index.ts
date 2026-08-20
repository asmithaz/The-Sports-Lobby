// FedEx Cup Playoffs — projected rank sync
//
// Pulls pgatour.com's own live "Proj." FedExCup rank for every golfer —
// what their rank would be if the current playoff event ended today, based
// on how they're actually playing this week — and writes it to
// golfers.fedex_rank_projected (see golf/fedex-playoffs/schema.sql).
// Distinct from fedex_rank_current (the static "Official" rank entering
// the event, refreshed by hand once per event via
// golf/fedex-playoffs/scripts/Update-CurrentFedexRank.ps1): this one moves
// during live play.
//
// pgatour.com/fedexcup/projected-standings is a server-rendered Next.js
// page — the data isn't in the visible HTML table markup, it's in a
// `<script id="__NEXT_DATA__">` JSON blob the page hydrates from, under
// props.pageProps.dehydratedState.queries[].queryKey[0] === "tourCupSplit".
// That's a private, undocumented shape PGA Tour could change at any time —
// if it does, this returns ok:false the same way fcp-sync-scores does on
// an ESPN shape change, rather than anything more elaborate.
//
// Triggered by a GitHub Actions cron job every 10 minutes during playoff
// weeks (.github/workflows/fcp-sync-projected-rank.yml) — kept as its own
// function/cron rather than folded into fcp-sync-scores so a pgatour.com
// shape change can't take down the ESPN score sync too.
//
// Deploy with: supabase functions deploy fcp-sync-projected-rank

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PROJECTED_STANDINGS_URL = "https://www.pgatour.com/fedexcup/projected-standings";

// A plain Deno fetch (no User-Agent) risks the same kind of bot block that
// hit site.api.espn.com — send a normal browser UA up front rather than
// waiting to discover that the hard way.
const BROWSER_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

// golfers.name is plain ASCII (see golf/fedex-playoffs/scripts/golfers-2026.csv
// — e.g. "Ludvig Aberg", "Nicolai Hojgaard"), but pgatour.com's displayName
// carries real diacritics ("Ludvig Åberg"). Stripping them here instead of
// hardcoding per-name fixes (as the initial CSV-based rank load needed —
// see golf/fedex-playoffs/scripts/fedex-rank-current-2026-bmw.csv's history)
// keeps the match working for any accented name, present or future. Uses
// explicit \u escapes (not literal combining-mark characters) so the
// source stays plain ASCII and can't get mangled by an editor/encoding
// round-trip.
const COMBINING_DIACRITICS = new RegExp("[\\u0300-\\u036f]", "g");

function stripDiacritics(name: string): string {
  return name.normalize("NFD").replace(COMBINING_DIACRITICS, "");
}

// rankingData.projected is usually a plain digit string ("12") but ties
// beyond the field's cutoff are reported as "T212" — strip a leading T
// before parsing either way.
function parseRank(raw: unknown): number | null {
  if (typeof raw !== "string") return null;
  const n = parseInt(raw.replace(/^T/i, ""), 10);
  return Number.isFinite(n) ? n : null;
}

interface ProjectedPlayer {
  displayName?: string;
  rankingData?: { projected?: string };
}

function extractProjectedRanks(html: string): { name: string; rank: number }[] {
  const match = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!match) throw new Error("__NEXT_DATA__ script tag not found in pgatour.com response");

  const nextData = JSON.parse(match[1]);
  const queries = nextData?.props?.pageProps?.dehydratedState?.queries ?? [];
  const tourCupQuery = queries.find((q: any) => Array.isArray(q?.queryKey) && q.queryKey[0] === "tourCupSplit");
  const players: ProjectedPlayer[] = tourCupQuery?.state?.data?.projectedPlayers ?? [];
  if (players.length === 0) throw new Error("No projectedPlayers found in tourCupSplit query data");

  const updates: { name: string; rank: number }[] = [];
  for (const p of players) {
    const rank = parseRank(p.rankingData?.projected);
    if (!p.displayName || rank == null) continue;
    updates.push({ name: stripDiacritics(p.displayName), rank });
  }
  return updates;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const pgatourRes = await fetch(PROJECTED_STANDINGS_URL, {
      headers: { "User-Agent": BROWSER_USER_AGENT },
    });
    if (!pgatourRes.ok) {
      throw new Error(`pgatour.com projected-standings request failed: ${pgatourRes.status}`);
    }
    const html = await pgatourRes.text();

    const updates = extractProjectedRanks(html);

    const { error: rpcErr } = await supabase.rpc("fcp_update_projected_ranks", { p_updates: updates });
    if (rpcErr) throw rpcErr;

    return new Response(
      JSON.stringify({ ok: true, updated: updates.length }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    // Supabase errors (PostgrestError etc.) are plain objects, not Error
    // instances — String(err) collapses them to "[object Object]" with no
    // way to tell what actually failed.
    const message = err instanceof Error ? err.message : (err as any)?.message ?? JSON.stringify(err);
    return new Response(
      JSON.stringify({ ok: false, error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
