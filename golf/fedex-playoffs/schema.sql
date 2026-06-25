-- ============================================================
-- FedEx Cup Playoffs Fantasy Golf — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / ON CONFLICT DO NOTHING)
--
-- Assumes the shared `leagues`, `league_members`, `profiles` tables
-- and the `is_league_member(uuid)` helper already exist (see
-- soccer/world-cup-draft/schema.sql).
-- ============================================================


-- ------------------------------------------------------------
-- 1. GOLFERS
-- One row per golfer in the FedEx Cup Playoffs field. Populated
-- once per season from the FedEx Cup standings entering the
-- St. Jude Championship (top 70). `tier` is derived from
-- `fedex_rank` and drives tiered-draft roster validation.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS golfers (
  id         text PRIMARY KEY,
  name       text NOT NULL,
  espn_id    text UNIQUE,
  fedex_rank int  NOT NULL CHECK (fedex_rank BETWEEN 1 AND 70),
  tier       int  GENERATED ALWAYS AS (
    CASE
      WHEN fedex_rank <= 30 THEN 1
      WHEN fedex_rank <= 50 THEN 2
      ELSE 3
    END
  ) STORED
);


-- ------------------------------------------------------------
-- 2. FCP LEAGUES
-- One row per league — stores draft format, roster configuration,
-- and draft state. Created via the setup/invite forms.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fcp_leagues (
  league_id           uuid PRIMARY KEY REFERENCES leagues(id) ON DELETE CASCADE,
  draft_format        text NOT NULL DEFAULT 'snake' CHECK (draft_format IN ('snake', 'auction')),
  draft_status        text NOT NULL DEFAULT 'pending' CHECK (draft_status IN ('pending', 'active', 'completed')),
  draft_time          timestamptz,
  pick_seconds        int  NOT NULL DEFAULT 90,
  pick_deadline       timestamptz,
  current_pick_number int  NOT NULL DEFAULT 1,
  roster_mode         text NOT NULL DEFAULT 'tiered' CHECK (roster_mode IN ('tiered', 'open')),
  roster_size         int  NOT NULL DEFAULT 4 CHECK (roster_size > 0),
  tier1_count         int  NOT NULL DEFAULT 2 CHECK (tier1_count >= 0),
  tier2_count         int  NOT NULL DEFAULT 1 CHECK (tier2_count >= 0),
  tier3_count         int  NOT NULL DEFAULT 1 CHECK (tier3_count >= 0),
  created_at          timestamptz DEFAULT now()
);


-- ------------------------------------------------------------
-- 3. DRAFT ORDER
-- One row per (league, user) — position in the snake draft.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fcp_draft_order (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id  uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  position   int  NOT NULL,
  UNIQUE(league_id, user_id),
  UNIQUE(league_id, position)
);


-- ------------------------------------------------------------
-- 4. DRAFT PICKS
-- One row per golfer picked. pick_number is the global pick
-- sequence across all rounds (1, 2, 3 … roster_size * members).
-- tier_slot identifies which roster slot this pick fills:
--   1..tier1_count               -> Tier 1 (rank 1-30)
--   tier1_count+1..+tier2_count  -> Tier 2 (rank 31-50)
--   ...+tier3_count              -> Tier 3 (rank 51-70)
-- In 'open' mode, tier_slot is simply the pick order (1..roster_size).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fcp_picks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id    uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  golfer_id    text NOT NULL REFERENCES golfers(id),
  pick_number  int  NOT NULL,
  tier_slot    int  NOT NULL,
  picked_at    timestamptz DEFAULT now(),
  UNIQUE(league_id, golfer_id),
  UNIQUE(league_id, pick_number)
);


-- ------------------------------------------------------------
-- 5. EVENT RESULTS
-- One row per (golfer, event). Synced from ESPN's scoreboard by
-- the fcp-sync-scores Edge Function (service role — bypasses RLS).
-- `points` is the final score for that event using highest-tier-only
-- scoring, including the FedEx Cup Champion bonus when applicable:
--   Win = 10, Top 3 = 5, Top 10 = 3, Top 30 = 1, else 0
--   FedEx Cup Champion (tour_championship row only): +10
-- `status` lets the UI render "CUT" instead of a point value.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fcp_event_results (
  golfer_id       text NOT NULL REFERENCES golfers(id),
  event           text NOT NULL CHECK (event IN ('st_jude', 'bmw', 'tour_championship')),
  finish_position int,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'made_cut', 'cut', 'withdrawn')),
  points          int  NOT NULL DEFAULT 0,
  updated_at      timestamptz DEFAULT now(),
  PRIMARY KEY (golfer_id, event)
);


-- ------------------------------------------------------------
-- 6. SCORES
-- Cached total points per user per league — sum of fcp_event_results
-- .points for every golfer on that user's roster. Recalculated via
-- fcp_recalculate_scores() whenever event results change.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fcp_scores (
  league_id    uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  total_points int  NOT NULL DEFAULT 0,
  last_updated timestamptz DEFAULT now(),
  PRIMARY KEY(league_id, user_id)
);


-- ------------------------------------------------------------
-- 7. FREE AGENCY — placeholder (not implemented)
-- Initial build keeps rosters locked for all three events. When
-- swaps are added, transactions will need roughly:
--
-- CREATE TABLE fcp_transactions (
--   id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--   league_id   uuid REFERENCES leagues(id) ON DELETE CASCADE,
--   user_id     uuid REFERENCES auth.users(id),
--   dropped_golfer_id text REFERENCES golfers(id),
--   added_golfer_id   text REFERENCES golfers(id),
--   effective_before  text REFERENCES (event enum), -- swap takes effect before this event
--   created_at  timestamptz DEFAULT now()
-- );
--
-- fcp_recalculate_scores() would need to sum points per golfer only
-- for the events during which that golfer was on the roster.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
-- 8. GRANTS
-- ------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT ON golfers              TO anon, authenticated;
GRANT SELECT ON fcp_event_results    TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON fcp_leagues     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON fcp_draft_order TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON fcp_picks       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON fcp_scores      TO authenticated;

-- service_role bypasses RLS but still needs table grants for the
-- fcp-sync-scores Edge Function and the golfer-roster setup script.
GRANT SELECT, INSERT, UPDATE        ON golfers           TO service_role;
GRANT SELECT, INSERT, UPDATE        ON fcp_event_results TO service_role;
GRANT SELECT, INSERT, UPDATE        ON fcp_scores        TO service_role;


-- ------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- ------------------------------------------------------------
ALTER TABLE golfers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcp_leagues       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcp_draft_order   ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcp_picks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcp_event_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcp_scores        ENABLE ROW LEVEL SECURITY;

-- golfers / fcp_event_results — public reference data
DROP POLICY IF EXISTS "Anyone can view golfers" ON golfers;
CREATE POLICY "Anyone can view golfers" ON golfers FOR SELECT USING (true);

DROP POLICY IF EXISTS "Anyone can view event results" ON fcp_event_results;
CREATE POLICY "Anyone can view event results" ON fcp_event_results FOR SELECT USING (true);

-- fcp_leagues
DROP POLICY IF EXISTS "League members can view fcp league" ON fcp_leagues;
DROP POLICY IF EXISTS "Commissioner can insert fcp league"  ON fcp_leagues;
DROP POLICY IF EXISTS "Commissioner can update fcp league"  ON fcp_leagues;

CREATE POLICY "League members can view fcp league"
  ON fcp_leagues FOR SELECT USING (is_league_member(league_id));

CREATE POLICY "Commissioner can insert fcp league"
  ON fcp_leagues FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM leagues WHERE id = fcp_leagues.league_id AND commissioner_id = auth.uid())
  );

CREATE POLICY "Commissioner can update fcp league"
  ON fcp_leagues FOR UPDATE USING (
    EXISTS (SELECT 1 FROM leagues WHERE id = fcp_leagues.league_id AND commissioner_id = auth.uid())
  );

-- fcp_draft_order
DROP POLICY IF EXISTS "League members can view draft order" ON fcp_draft_order;
DROP POLICY IF EXISTS "Commissioner can manage draft order"  ON fcp_draft_order;

CREATE POLICY "League members can view draft order"
  ON fcp_draft_order FOR SELECT USING (is_league_member(fcp_draft_order.league_id));

CREATE POLICY "Commissioner can manage draft order"
  ON fcp_draft_order FOR ALL USING (
    EXISTS (SELECT 1 FROM leagues WHERE id = fcp_draft_order.league_id AND commissioner_id = auth.uid())
  );

-- fcp_picks — writes only via the RPCs below (SECURITY DEFINER)
DROP POLICY IF EXISTS "League members can view picks" ON fcp_picks;

CREATE POLICY "League members can view picks"
  ON fcp_picks FOR SELECT USING (is_league_member(fcp_picks.league_id));

-- fcp_scores
DROP POLICY IF EXISTS "League members can view scores" ON fcp_scores;

CREATE POLICY "League members can view scores"
  ON fcp_scores FOR SELECT USING (is_league_member(fcp_scores.league_id));


-- ============================================================
-- SECTION 10 — DRAFT ENGINE
-- Snake-draft lobby, turn enforcement, tier-aware pick validation,
-- pick timer + autopick. All writes to fcp_picks / fcp_draft_order /
-- fcp_leagues during an active draft go through the SECURITY DEFINER
-- RPCs below.
-- ============================================================

-- ------------------------------------------------------------
-- 10.1 Draft order helpers
-- ------------------------------------------------------------

-- Populate a randomized draft order the first time anyone opens the lobby.
-- Idempotent — does nothing once an order exists for the league.
CREATE OR REPLACE FUNCTION fcp_ensure_draft_order(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM fcp_draft_order WHERE league_id = p_league_id) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM league_members WHERE league_id = p_league_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  INSERT INTO fcp_draft_order (league_id, user_id, position)
  SELECT p_league_id, user_id, row_number() OVER (ORDER BY random())
  FROM league_members
  WHERE league_id = p_league_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_ensure_draft_order(uuid) TO authenticated;


-- Let the commissioner reorder drafters any time before the draft starts.
-- p_user_ids must contain every league member exactly once, in the desired
-- pick order (index 0 picks first).
CREATE OR REPLACE FUNCTION fcp_set_draft_order(p_league_id uuid, p_user_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_status       text;
  v_draft_time   timestamptz;
  v_member_count int;
  i              int;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can set the draft order';
  END IF;

  SELECT draft_status, draft_time INTO v_status, v_draft_time
  FROM fcp_leagues WHERE league_id = p_league_id;

  IF v_status IS DISTINCT FROM 'pending' OR v_draft_time IS NULL OR now() >= v_draft_time THEN
    RAISE EXCEPTION 'Draft order can only be changed before the draft starts';
  END IF;

  SELECT count(*) INTO v_member_count FROM league_members WHERE league_id = p_league_id;
  IF p_user_ids IS NULL OR array_length(p_user_ids, 1) IS DISTINCT FROM v_member_count THEN
    RAISE EXCEPTION 'Draft order must include every league member exactly once';
  END IF;

  PERFORM fcp_ensure_draft_order(p_league_id);

  -- Shift existing positions out of the way first so the per-row updates
  -- below never collide with the UNIQUE(league_id, position) constraint.
  UPDATE fcp_draft_order SET position = position + v_member_count WHERE league_id = p_league_id;

  FOR i IN 1..v_member_count LOOP
    UPDATE fcp_draft_order SET position = i
    WHERE league_id = p_league_id AND user_id = p_user_ids[i];
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_set_draft_order(uuid, uuid[]) TO authenticated;


-- ------------------------------------------------------------
-- 10.2 Snake order helper
-- Returns the user_id expected to make the given global pick number.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fcp_expected_drafter(p_league_id uuid, p_pick_number int)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_n    int;
  v_slot int;
BEGIN
  SELECT count(*) INTO v_n FROM league_members WHERE league_id = p_league_id;
  IF v_n = 0 THEN RETURN NULL; END IF;

  v_slot := (p_pick_number - 1) % v_n;
  IF ((p_pick_number - 1) / v_n) % 2 = 1 THEN
    v_slot := v_n - 1 - v_slot;
  END IF;

  RETURN (
    SELECT user_id FROM fcp_draft_order
    WHERE league_id = p_league_id AND position = v_slot + 1
  );
END;
$$;


-- Advance current_pick_number / pick_deadline after a pick is recorded,
-- or mark the draft completed if that was the last pick.
CREATE OR REPLACE FUNCTION _fcp_advance_after_pick(p_league_id uuid, p_pick_number int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_n          int;
  v_roster     int;
  v_pick_secs  int;
BEGIN
  SELECT count(*) INTO v_n FROM league_members WHERE league_id = p_league_id;
  SELECT roster_size, pick_seconds INTO v_roster, v_pick_secs
  FROM fcp_leagues WHERE league_id = p_league_id;

  IF p_pick_number >= v_roster * v_n THEN
    UPDATE fcp_leagues SET draft_status = 'completed' WHERE league_id = p_league_id;
  ELSE
    UPDATE fcp_leagues
    SET current_pick_number = p_pick_number + 1,
        pick_deadline       = now() + (v_pick_secs * interval '1 second')
    WHERE league_id = p_league_id;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 10.3 Tier-slot helper
-- Computes the tier_slot for a user's next pick of the given golfer,
-- raising an exception if that tier (or the overall roster, in
-- 'open' mode) is already full for this user.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fcp_next_tier_slot(p_league_id uuid, p_user_id uuid, p_golfer_tier int)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_roster_mode text;
  v_t1 int; v_t2 int; v_t3 int;
  v_count_t1 int; v_count_t2 int; v_count_t3 int;
  v_total int;
BEGIN
  SELECT roster_mode, tier1_count, tier2_count, tier3_count
  INTO v_roster_mode, v_t1, v_t2, v_t3
  FROM fcp_leagues WHERE league_id = p_league_id;

  IF v_roster_mode = 'open' THEN
    SELECT count(*) INTO v_total FROM fcp_picks WHERE league_id = p_league_id AND user_id = p_user_id;
    IF v_total >= (v_t1 + v_t2 + v_t3) THEN
      RAISE EXCEPTION 'Roster is already full';
    END IF;
    RETURN v_total + 1;
  END IF;

  SELECT
    count(*) FILTER (WHERE g.tier = 1),
    count(*) FILTER (WHERE g.tier = 2),
    count(*) FILTER (WHERE g.tier = 3)
  INTO v_count_t1, v_count_t2, v_count_t3
  FROM fcp_picks p JOIN golfers g ON g.id = p.golfer_id
  WHERE p.league_id = p_league_id AND p.user_id = p_user_id;

  IF p_golfer_tier = 1 THEN
    IF v_count_t1 >= v_t1 THEN RAISE EXCEPTION 'Tier 1 (rank 1-30) roster slots are full'; END IF;
    RETURN v_count_t1 + 1;
  ELSIF p_golfer_tier = 2 THEN
    IF v_count_t2 >= v_t2 THEN RAISE EXCEPTION 'Tier 2 (rank 31-50) roster slots are full'; END IF;
    RETURN v_t1 + v_count_t2 + 1;
  ELSE
    IF v_count_t3 >= v_t3 THEN RAISE EXCEPTION 'Tier 3 (rank 51-70) roster slots are full'; END IF;
    RETURN v_t1 + v_t2 + v_count_t3 + 1;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 10.4 fcp_start_draft
-- Manual early start by the commissioner, or auto-start by any
-- league member once draft_time has passed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_start_draft(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_is_commissioner boolean;
  v_draft_time      timestamptz;
  v_pick_seconds    int;
BEGIN
  SELECT (commissioner_id = auth.uid()) INTO v_is_commissioner
  FROM leagues WHERE id = p_league_id;

  SELECT draft_time, pick_seconds INTO v_draft_time, v_pick_seconds
  FROM fcp_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF NOT (v_is_commissioner OR (v_draft_time IS NOT NULL AND now() >= v_draft_time)) THEN
    RAISE EXCEPTION 'Draft cannot be started yet';
  END IF;

  PERFORM fcp_ensure_draft_order(p_league_id);

  UPDATE fcp_leagues
  SET draft_status        = 'active',
      current_pick_number = 1,
      pick_deadline       = now() + (v_pick_seconds * interval '1 second')
  WHERE league_id = p_league_id AND draft_status = 'pending';
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_start_draft(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 10.5 fcp_make_draft_pick
-- The only way a player records a pick. Enforces turn order, golfer
-- availability, and tier-slot limits; advances the clock.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_make_draft_pick(p_league_id uuid, p_golfer_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_status   text;
  v_pick_num int;
  v_expected uuid;
  v_tier     int;
  v_slot     int;
BEGIN
  SELECT draft_status, current_pick_number INTO v_status, v_pick_num
  FROM fcp_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Draft is not active';
  END IF;

  v_expected := _fcp_expected_drafter(p_league_id, v_pick_num);
  IF v_expected IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'It is not your turn';
  END IF;

  SELECT tier INTO v_tier FROM golfers WHERE id = p_golfer_id;
  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'Unknown golfer';
  END IF;

  IF EXISTS (SELECT 1 FROM fcp_picks WHERE league_id = p_league_id AND golfer_id = p_golfer_id) THEN
    RAISE EXCEPTION 'That golfer has already been picked';
  END IF;

  v_slot := _fcp_next_tier_slot(p_league_id, auth.uid(), v_tier);

  INSERT INTO fcp_picks (league_id, user_id, golfer_id, pick_number, tier_slot)
  VALUES (p_league_id, auth.uid(), p_golfer_id, v_pick_num, v_slot);

  PERFORM _fcp_advance_after_pick(p_league_id, v_pick_num);
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_make_draft_pick(uuid, text) TO authenticated;


-- ------------------------------------------------------------
-- 10.6 fcp_autopick_if_expired
-- Called speculatively by any connected client. No-ops unless the
-- current pick's timer has actually expired. Picks the
-- highest-ranked remaining golfer that still fits one of the
-- expected drafter's open tier slots.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_autopick_if_expired(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_status   text;
  v_deadline timestamptz;
  v_pick_num int;
  v_expected uuid;
  v_roster_mode text;
  v_golfer_id text;
  v_tier int;
  v_slot int;
BEGIN
  SELECT draft_status, pick_deadline, current_pick_number, roster_mode
  INTO v_status, v_deadline, v_pick_num, v_roster_mode
  FROM fcp_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' OR v_deadline IS NULL OR now() < v_deadline THEN
    RETURN;
  END IF;

  v_expected := _fcp_expected_drafter(p_league_id, v_pick_num);
  IF v_expected IS NULL THEN RETURN; END IF;

  -- Walk remaining golfers by FedEx rank, taking the first one that
  -- fits an open tier slot (or any slot in 'open' mode).
  FOR v_golfer_id, v_tier IN
    SELECT g.id, g.tier
    FROM golfers g
    WHERE NOT EXISTS (
      SELECT 1 FROM fcp_picks p WHERE p.league_id = p_league_id AND p.golfer_id = g.id
    )
    ORDER BY g.fedex_rank
  LOOP
    BEGIN
      v_slot := _fcp_next_tier_slot(p_league_id, v_expected, v_tier);
    EXCEPTION WHEN OTHERS THEN
      v_slot := NULL;
    END;

    IF v_slot IS NOT NULL THEN
      INSERT INTO fcp_picks (league_id, user_id, golfer_id, pick_number, tier_slot)
      VALUES (p_league_id, v_expected, v_golfer_id, v_pick_num, v_slot);

      PERFORM _fcp_advance_after_pick(p_league_id, v_pick_num);
      RETURN;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_autopick_if_expired(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 10.7 fcp_recalculate_scores
-- Recomputes fcp_scores for a league from fcp_picks + fcp_event_results.
-- Called by the dashboard's "Refresh Scores" button (after the
-- fcp-sync-scores Edge Function updates fcp_event_results) and can
-- also be run after manual result corrections.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_recalculate_scores(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  INSERT INTO fcp_scores (league_id, user_id, total_points, last_updated)
  SELECT p_league_id, p.user_id, COALESCE(SUM(r.points), 0), now()
  FROM fcp_picks p
  LEFT JOIN fcp_event_results r ON r.golfer_id = p.golfer_id
  WHERE p.league_id = p_league_id
  GROUP BY p.user_id
  ON CONFLICT (league_id, user_id)
  DO UPDATE SET total_points = EXCLUDED.total_points, last_updated = now();
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_recalculate_scores(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 10.7b fcp_recalculate_all_scores
-- Same as fcp_recalculate_scores but for every league at once, with
-- no membership check. Used by the fcp-sync-scores Edge Function
-- (service role) after it refreshes fcp_event_results from ESPN.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_recalculate_all_scores()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO fcp_scores (league_id, user_id, total_points, last_updated)
  SELECT p.league_id, p.user_id, COALESCE(SUM(r.points), 0), now()
  FROM fcp_picks p
  LEFT JOIN fcp_event_results r ON r.golfer_id = p.golfer_id
  GROUP BY p.league_id, p.user_id
  ON CONFLICT (league_id, user_id)
  DO UPDATE SET total_points = EXCLUDED.total_points, last_updated = now();
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_recalculate_all_scores() TO service_role;


-- ------------------------------------------------------------
-- 10.8 Realtime — broadcast pick/order/status changes to clients
-- ------------------------------------------------------------
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE fcp_picks;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE fcp_leagues;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE fcp_draft_order;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE fcp_scores;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
