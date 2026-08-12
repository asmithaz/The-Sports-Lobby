// FedEx Cup Playoffs — score sync
//
// Pulls the live PGA Tour leaderboard from ESPN's public scoreboard API,
// converts each golfer's current position into FedEx Cup Playoffs fantasy
// points (highest-tier-only, see golf/fedex-playoffs/schema.sql), and
// upserts the results into `fcp_event_results`. Finally recalculates the
// cached `fcp_scores` for every league.
//
// Triggered by:
//  - A GitHub Actions cron job every 10 minutes during playoff weeks
//    (.github/workflows/fcp-sync-scores.yml)
//  - The "Refresh Scores" button on the FedEx Cup Playoffs dashboard
//
// Deploy with: supabase functions deploy fcp-sync-scores

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ESPN_SCOREBOARD_URL =
  "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard";

// Maps ESPN tournament names (lowercased, substring match) to fcp_event_results.event values.
const EVENT_NAME_MATCH: Record<string, string> = {
  "st. jude": "st_jude",
  "st jude": "st_jude",
  "bmw championship": "bmw",
  "tour championship": "tour_championship",
};

// Highest-tier-only scoring: Win=10, Top 3=5, Top 10=3, Top 30=1, else 0.
function pointsForPosition(position: number | null): number {
  if (position == null) return 0;
  if (position <= 1) return 10;
  if (position <= 3) return 5;
  if (position <= 10) return 3;
  if (position <= 30) return 1;
  return 0;
}

function findEventKey(events: any[]): { event: string; competition: any } | null {
  for (const ev of events ?? []) {
    const name = String(ev?.name ?? ev?.shortName ?? "").toLowerCase();
    for (const [needle, key] of Object.entries(EVENT_NAME_MATCH)) {
      if (name.includes(needle)) {
        const competition = ev?.competitions?.[0];
        if (competition) return { event: key, competition };
      }
    }
  }
  return null;
}

// Normalizes ESPN's per-competitor status into our fcp_event_results.status enum.
function statusFor(competitor: any): "active" | "made_cut" | "cut" | "withdrawn" {
  const typeName = String(competitor?.status?.type?.name ?? "").toUpperCase();
  const typeDesc = String(competitor?.status?.type?.description ?? "").toLowerCase();

  if (typeName.includes("WITHDR") || typeDesc.includes("withdr")) return "withdrawn";
  if (typeName.includes("CUT") || typeDesc.includes("cut")) return "cut";
  if (typeName.includes("FINAL") || typeDesc.includes("final")) return "made_cut";
  return "active";
}

function positionFor(competitor: any): number | null {
  const raw =
    competitor?.status?.position?.id ??
    competitor?.status?.position?.displayName ??
    competitor?.order;
  if (raw == null) return null;
  const n = parseInt(String(raw).replace(/[^0-9]/g, ""), 10);
  return Number.isFinite(n) ? n : null;
}

// TOUR Championship par (East Lake GC, 4 rounds) — used to convert ESPN's
// relative-to-par score into a total-strokes number for the
// fcp_tiebreakers guessing game (golf/fedex-playoffs/schema.sql).
const TOUR_CHAMPIONSHIP_PAR = 288;

// ESPN reports score relative to par as a string, e.g. "-18", "+2", or "E"
// for even par.
function relativeScoreFor(competitor: any): number | null {
  const raw = competitor?.score?.displayValue ?? competitor?.score;
  if (raw == null) return null;
  const s = String(raw).trim().toUpperCase();
  if (s === "E") return 0;
  const n = parseInt(s.replace(/^\+/, ""), 10);
  return Number.isFinite(n) ? n : null;
}

Deno.serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const espnRes = await fetch(ESPN_SCOREBOARD_URL);
    if (!espnRes.ok) {
      throw new Error(`ESPN scoreboard request failed: ${espnRes.status}`);
    }
    const espnData = await espnRes.json();

    const matched = findEventKey(espnData?.events ?? []);
    if (!matched) {
      return new Response(
        JSON.stringify({ ok: true, message: "No active FedEx Cup Playoffs event found", updated: 0 }),
        { headers: { "Content-Type": "application/json" } },
      );
    }

    const { event, competition } = matched;
    const competitors: any[] = competition?.competitors ?? [];

    // Map ESPN athlete IDs to our golfer ids.
    const { data: golfers, error: golfersErr } = await supabase
      .from("golfers")
      .select("id, espn_id");
    if (golfersErr) throw golfersErr;

    const espnIdToGolferId = new Map<string, string>();
    for (const g of golfers ?? []) {
      if (g.espn_id) espnIdToGolferId.set(String(g.espn_id), g.id);
    }

    const rows: any[] = [];
    const tourChampionWinner = event === "tour_championship";
    // ESPN's scoreboard always reflects whatever tournament is live right
    // now, so "season" is simply the current calendar year — matches
    // fcp_event_results.season in golf/fedex-playoffs/schema.sql.
    const season = new Date().getFullYear();

    for (const competitor of competitors) {
      const espnId = String(competitor?.athlete?.id ?? competitor?.id ?? "");
      const golferId = espnIdToGolferId.get(espnId);
      if (!golferId) continue;

      const status = statusFor(competitor);
      const position = positionFor(competitor);

      let points = 0;
      if (status === "active" || status === "made_cut") {
        points = pointsForPosition(position);
        // FedEx Cup Champion bonus: the TOUR Championship winner is the FedEx Cup champion.
        if (tourChampionWinner && position === 1) {
          points += 5;
        }
      }

      const relative = relativeScoreFor(competitor);

      let totalStrokes: number | null = null;
      if (tourChampionWinner && relative != null) {
        totalStrokes = TOUR_CHAMPIONSHIP_PAR + relative;
      }

      rows.push({
        golfer_id: golferId,
        event,
        season,
        finish_position: position,
        status,
        points,
        total_strokes: totalStrokes,
        score_to_par: relative,
        updated_at: new Date().toISOString(),
      });
    }

    if (rows.length > 0) {
      const { error: upsertErr } = await supabase
        .from("fcp_event_results")
        .upsert(rows, { onConflict: "golfer_id,event,season" });
      if (upsertErr) throw upsertErr;
    }

    const { error: recalcErr } = await supabase.rpc("fcp_recalculate_all_scores");
    if (recalcErr) throw recalcErr;

    return new Response(
      JSON.stringify({ ok: true, event, updated: rows.length }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
