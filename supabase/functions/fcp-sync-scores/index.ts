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

// Browser-invoked calls (the dashboard's "Refresh Scores" button) need CORS
// headers on every response, including the preflight OPTIONS request. The
// GitHub Actions cron job calls this function server-to-server and isn't
// subject to CORS, so it worked fine even before this was added.
const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// site.api.espn.com started returning 403 to non-browser clients on
// 2026-08-19 (confirmed across unrelated sports/endpoints on that
// subdomain, so it's an ESPN-side block, not a golf-specific issue).
// site.web.api.espn.com — the host ESPN's own site JS calls — serves the
// identical scoreboard payload shape and isn't blocked.
const ESPN_SCOREBOARD_URL =
  "https://site.web.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard";

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

// ESPN's status.type.state is "pre" | "in" | "post" across every sport on
// this API. Checked at both the event and competition level since golf's
// scoreboard has been observed to set it on either depending on the event.
function findEventKey(events: any[]): { event: string; competition: any; started: boolean } | null {
  for (const ev of events ?? []) {
    const name = String(ev?.name ?? ev?.shortName ?? "").toLowerCase();
    for (const [needle, key] of Object.entries(EVENT_NAME_MATCH)) {
      if (name.includes(needle)) {
        const competition = ev?.competitions?.[0];
        if (competition) {
          const state = competition?.status?.type?.state ?? ev?.status?.type?.state;
          return { event: key, competition, started: state !== "pre" };
        }
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

// ESPN's per-competitor position field is a plain sequential index — it does
// not group tied scores under a shared rank (e.g. two golfers both at -5 show
// as position 2 and 3 instead of both T2). Standard "1224" competition
// ranking is computed here instead: golfers with an equal score_to_par share
// the same rank, and the next distinct score skips ahead by the number tied.
function computeRanks(relatives: (number | null)[]): (number | null)[] {
  const indexed = relatives
    .map((relative, index) => ({ index, relative }))
    .filter((e): e is { index: number; relative: number } => e.relative != null)
    .sort((a, b) => a.relative - b.relative);

  const ranks: (number | null)[] = new Array(relatives.length).fill(null);
  let rank = 0;
  let seen = 0;
  let prevScore: number | null = null;
  for (const e of indexed) {
    seen++;
    if (prevScore === null || e.relative !== prevScore) {
      rank = seen;
      prevScore = e.relative;
    }
    ranks[e.index] = rank;
  }
  return ranks;
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

// A round a golfer hasn't played yet shows up in `linescores` as a bare
// { period: N } with no value/displayValue — any entry that does have one
// means at least one hole from that round is on the books. Used to tell
// "genuinely hasn't teed off in this tournament at all" (their real first
// tee time — show it) apart from "finished an earlier round and is simply
// waiting on today's" (their cumulative score is real and current — keep
// showing it, don't blank it out just because today hasn't started).
function hasRecordedAnyScore(competitor: any): boolean {
  const linescores = competitor?.linescores;
  if (!Array.isArray(linescores)) return false;
  return linescores.some((ls: any) => ls?.value != null || ls?.displayValue != null);
}

// The main scoreboard endpoint (ESPN_SCOREBOARD_URL above) doesn't carry
// per-golfer tee times — everyone shows tied at even par with no way to
// tell "hasn't teed off yet" from "actually shooting even par". ESPN's
// undocumented core API has that per-competitor, one call per golfer:
// .../events/{id}/competitions/{id}/competitors/{athleteId}/status. It
// returns both the individual pre/in/post state and, while pre, a
// `teeTime` ISO timestamp. Best-effort: any failure (rate limit, shape
// change, network) falls back to null so the caller uses the whole-event
// `started` flag instead of blocking the sync.
async function fetchIndividualStatus(
  competitionId: string,
  athleteId: string,
): Promise<{ started: boolean; teeTime: string | null } | null> {
  try {
    const url = `https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/${competitionId}/competitions/${competitionId}/competitors/${athleteId}/status?lang=en&region=us`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const data = await res.json();
    const state = data?.type?.state;
    if (!state) return null;
    return { started: state !== "pre", teeTime: state === "pre" ? (data?.teeTime ?? null) : null };
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

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
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { event, competition, started } = matched;
    // ESPN's scoreboard always reflects whatever tournament is live right
    // now, so "season" is simply the current calendar year — matches
    // fcp_event_results.season in golf/fedex-playoffs/schema.sql.
    const season = new Date().getFullYear();

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

    // First pass: figure out which competitors map to a known golfer, and
    // pull their status/score, plus (best-effort) their individual
    // pre/in/post state and tee time — the main scoreboard only reports
    // status/score at the whole-tournament level, so a golfer who simply
    // hasn't teed off yet today shows identically to one actively shooting
    // even par. Ranks are computed afterward across this filtered set so
    // ties are grouped correctly (an unmatched competitor sitting between
    // two tied golfers must not break the tie).
    const matchedCompetitors = (
      await Promise.all(
        competitors.map(async (competitor) => {
          const espnId = String(competitor?.athlete?.id ?? competitor?.id ?? "");
          const golferId = espnIdToGolferId.get(espnId);
          if (!golferId) return null;

          const individual = await fetchIndividualStatus(competition.id, espnId);
          // hasRecordedAnyScore wins whenever it's true: a golfer who's
          // already played at least one hole this tournament keeps their
          // real cumulative score/position showing through the gap before
          // their next round, instead of it blanking out the moment ESPN's
          // per-golfer status flips back to "pre" for that round. Only a
          // golfer with zero recorded holes anywhere in the tournament (a
          // genuine not-yet-teed-off-at-all case) falls through to the
          // individual lookup — which falls back to the whole-event flag if
          // that lookup itself fails, so a single ESPN hiccup can't
          // scramble the leaderboard.
          const hasStarted = hasRecordedAnyScore(competitor) || (individual?.started ?? started);

          return {
            golferId,
            status: hasStarted ? statusFor(competitor) : "scheduled" as const,
            relative: hasStarted ? relativeScoreFor(competitor) : null,
            teeTime: hasStarted ? null : individual?.teeTime ?? null,
          };
        }),
      )
    ).filter((e): e is { golferId: string; status: ReturnType<typeof statusFor> | "scheduled"; relative: number | null; teeTime: string | null } => e != null);

    const ranks = computeRanks(matchedCompetitors.map((e) => e.relative));

    const rows: any[] = [];
    const tourChampionWinner = event === "tour_championship";

    matchedCompetitors.forEach(({ golferId, status, relative, teeTime }, i) => {
      const position = ranks[i];

      let points = 0;
      if (status === "active" || status === "made_cut") {
        points = pointsForPosition(position);
        // FedEx Cup Champion bonus: the TOUR Championship winner is the FedEx Cup champion.
        if (tourChampionWinner && position === 1) {
          points += 5;
        }
      }

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
        tee_time: teeTime,
        updated_at: new Date().toISOString(),
      });
    });

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
