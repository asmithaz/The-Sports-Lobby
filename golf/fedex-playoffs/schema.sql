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
  paused_at              timestamptz, -- non-null while the commissioner has the clock stopped
  pick_remaining_seconds int,         -- time left on pick_deadline when paused_at was set
  current_pick_number int  NOT NULL DEFAULT 1,
  roster_mode         text NOT NULL DEFAULT 'tiered' CHECK (roster_mode IN ('tiered', 'open')),
  roster_size         int  NOT NULL DEFAULT 4 CHECK (roster_size > 0),
  tier1_count         int  NOT NULL DEFAULT 2 CHECK (tier1_count >= 0),
  tier2_count         int  NOT NULL DEFAULT 1 CHECK (tier2_count >= 0),
  tier3_count         int  NOT NULL DEFAULT 1 CHECK (tier3_count >= 0),
  created_at          timestamptz DEFAULT now()
);

-- Idempotent for installs that ran this schema before pause/resume existed.
ALTER TABLE fcp_leagues ADD COLUMN IF NOT EXISTS paused_at timestamptz;
ALTER TABLE fcp_leagues ADD COLUMN IF NOT EXISTS pick_remaining_seconds int;

-- Idempotent for installs that ran this schema before the fcp-draft-cron
-- Edge Function existed. Set once the "30 minutes before draft_time" email
-- has gone out, so the cron doesn't re-send it on every run.
ALTER TABLE fcp_leagues ADD COLUMN IF NOT EXISTS draft_reminder_sent_at timestamptz;

-- Idempotent for installs that ran this schema before seasons existed.
-- `season` is a calendar year (2026, 2027, …) — a league gets a new
-- fcp_leagues row each time fcp_start_new_season() runs, so it can be
-- reactivated into a fresh draft while prior seasons stay queryable as
-- permanent history. PK widens accordingly.
ALTER TABLE fcp_leagues ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;
ALTER TABLE fcp_leagues DROP CONSTRAINT IF EXISTS fcp_leagues_pkey;
ALTER TABLE fcp_leagues DROP CONSTRAINT IF EXISTS fcp_leagues_league_id_season_pkey;
ALTER TABLE fcp_leagues ADD CONSTRAINT fcp_leagues_league_id_season_pkey PRIMARY KEY (league_id, season);


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

-- Idempotent for installs that ran this schema before seasons existed.
ALTER TABLE fcp_draft_order ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;
ALTER TABLE fcp_draft_order DROP CONSTRAINT IF EXISTS fcp_draft_order_league_id_user_id_key;
ALTER TABLE fcp_draft_order DROP CONSTRAINT IF EXISTS fcp_draft_order_league_id_season_user_id_key;
ALTER TABLE fcp_draft_order ADD CONSTRAINT fcp_draft_order_league_id_season_user_id_key
  UNIQUE (league_id, season, user_id);
ALTER TABLE fcp_draft_order DROP CONSTRAINT IF EXISTS fcp_draft_order_league_id_position_key;
ALTER TABLE fcp_draft_order DROP CONSTRAINT IF EXISTS fcp_draft_order_league_id_season_position_key;
ALTER TABLE fcp_draft_order ADD CONSTRAINT fcp_draft_order_league_id_season_position_key
  UNIQUE (league_id, season, position);


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

-- Idempotent for installs that ran this schema before seasons existed.
ALTER TABLE fcp_picks ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;
ALTER TABLE fcp_picks DROP CONSTRAINT IF EXISTS fcp_picks_league_id_golfer_id_key;
ALTER TABLE fcp_picks DROP CONSTRAINT IF EXISTS fcp_picks_league_id_season_golfer_id_key;
ALTER TABLE fcp_picks ADD CONSTRAINT fcp_picks_league_id_season_golfer_id_key
  UNIQUE (league_id, season, golfer_id);
ALTER TABLE fcp_picks DROP CONSTRAINT IF EXISTS fcp_picks_league_id_pick_number_key;
ALTER TABLE fcp_picks DROP CONSTRAINT IF EXISTS fcp_picks_league_id_season_pick_number_key;
ALTER TABLE fcp_picks ADD CONSTRAINT fcp_picks_league_id_season_pick_number_key
  UNIQUE (league_id, season, pick_number);


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

-- Idempotent for installs that ran this schema before seasons existed.
-- Season-scoping this table is what stops next year's ESPN sync from
-- silently overwriting this year's finished results in place — see
-- supabase/functions/fcp-sync-scores/index.ts.
ALTER TABLE fcp_event_results ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;
ALTER TABLE fcp_event_results DROP CONSTRAINT IF EXISTS fcp_event_results_pkey;
ALTER TABLE fcp_event_results DROP CONSTRAINT IF EXISTS fcp_event_results_golfer_id_event_season_pkey;
ALTER TABLE fcp_event_results ADD CONSTRAINT fcp_event_results_golfer_id_event_season_pkey
  PRIMARY KEY (golfer_id, event, season);


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

-- Idempotent for installs that ran this schema before seasons existed.
-- Widening the PK to include season is what preserves a prior season's
-- final standings instead of the next season's recalculation overwriting
-- them in place.
ALTER TABLE fcp_scores ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;
ALTER TABLE fcp_scores DROP CONSTRAINT IF EXISTS fcp_scores_pkey;
ALTER TABLE fcp_scores DROP CONSTRAINT IF EXISTS fcp_scores_league_id_season_user_id_pkey;
ALTER TABLE fcp_scores ADD CONSTRAINT fcp_scores_league_id_season_user_id_pkey
  PRIMARY KEY (league_id, season, user_id);


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

-- ...and for the fcp-draft-cron Edge Function (auto-starts pending drafts,
-- sends 30-minute-out reminder emails). league_members/leagues grants live
-- in soccer/world-cup-bracket-challenge/schema.sql where those shared
-- tables are defined.
GRANT SELECT, UPDATE                ON fcp_leagues       TO service_role;


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
DECLARE
  v_season int;
BEGIN
  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  IF EXISTS (SELECT 1 FROM fcp_draft_order WHERE league_id = p_league_id AND season = v_season) THEN
    RETURN;
  END IF;

  -- auth.uid() is NULL when called from the fcp-draft-cron Edge Function
  -- (service_role, no user session) via fcp_start_draft's time-based
  -- auto-start path — that caller already has no user to check membership
  -- against, so only enforce this for real user sessions.
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM league_members WHERE league_id = p_league_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  INSERT INTO fcp_draft_order (league_id, season, user_id, position)
  SELECT p_league_id, v_season, user_id, row_number() OVER (ORDER BY random())
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
  v_season       int;
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

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT draft_status, draft_time INTO v_status, v_draft_time
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season;

  IF v_status IS DISTINCT FROM 'pending' OR v_draft_time IS NULL OR now() >= v_draft_time THEN
    RAISE EXCEPTION 'Draft order can only be changed before the draft starts';
  END IF;

  SELECT count(*) INTO v_member_count FROM league_members WHERE league_id = p_league_id;
  IF p_user_ids IS NULL OR array_length(p_user_ids, 1) IS DISTINCT FROM v_member_count THEN
    RAISE EXCEPTION 'Draft order must include every league member exactly once';
  END IF;

  PERFORM fcp_ensure_draft_order(p_league_id);

  -- Shift existing positions out of the way first so the per-row updates
  -- below never collide with the UNIQUE(league_id, season, position) constraint.
  UPDATE fcp_draft_order SET position = position + v_member_count
  WHERE league_id = p_league_id AND season = v_season;

  FOR i IN 1..v_member_count LOOP
    UPDATE fcp_draft_order SET position = i
    WHERE league_id = p_league_id AND season = v_season AND user_id = p_user_ids[i];
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_set_draft_order(uuid, uuid[]) TO authenticated;


-- ------------------------------------------------------------
-- 10.2 Snake order helper
-- Returns the user_id expected to make the given global pick number.
-- ------------------------------------------------------------
-- Idempotent for installs that ran this schema before seasons existed
-- (this function's signature gained p_season).
DROP FUNCTION IF EXISTS _fcp_expected_drafter(uuid, int);

CREATE OR REPLACE FUNCTION _fcp_expected_drafter(p_league_id uuid, p_pick_number int, p_season int)
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
    WHERE league_id = p_league_id AND season = p_season AND position = v_slot + 1
  );
END;
$$;


-- Advance current_pick_number / pick_deadline after a pick is recorded,
-- or mark the draft completed if that was the last pick.
-- Idempotent for installs that ran this schema before seasons existed
-- (this function's signature gained p_season).
DROP FUNCTION IF EXISTS _fcp_advance_after_pick(uuid, int);

CREATE OR REPLACE FUNCTION _fcp_advance_after_pick(p_league_id uuid, p_pick_number int, p_season int)
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
  FROM fcp_leagues WHERE league_id = p_league_id AND season = p_season;

  IF p_pick_number >= v_roster * v_n THEN
    UPDATE fcp_leagues SET draft_status = 'completed' WHERE league_id = p_league_id AND season = p_season;
  ELSE
    UPDATE fcp_leagues
    SET current_pick_number = p_pick_number + 1,
        pick_deadline       = now() + (v_pick_secs * interval '1 second')
    WHERE league_id = p_league_id AND season = p_season;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 10.3 Tier-slot helper
-- Computes the tier_slot for a user's next pick of the given golfer,
-- raising an exception if that tier (or the overall roster, in
-- 'open' mode) is already full for this user.
-- ------------------------------------------------------------
-- Idempotent for installs that ran this schema before seasons existed
-- (this function's signature gained p_season).
DROP FUNCTION IF EXISTS _fcp_next_tier_slot(uuid, uuid, int);

CREATE OR REPLACE FUNCTION _fcp_next_tier_slot(p_league_id uuid, p_user_id uuid, p_golfer_tier int, p_season int)
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
  FROM fcp_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_roster_mode = 'open' THEN
    SELECT count(*) INTO v_total FROM fcp_picks
    WHERE league_id = p_league_id AND season = p_season AND user_id = p_user_id;
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
  WHERE p.league_id = p_league_id AND p.season = p_season AND p.user_id = p_user_id;

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
  v_season          int;
  v_is_commissioner boolean;
  v_draft_time      timestamptz;
  v_pick_seconds    int;
BEGIN
  SELECT current_season, (commissioner_id = auth.uid()) INTO v_season, v_is_commissioner
  FROM leagues WHERE id = p_league_id;

  SELECT draft_time, pick_seconds INTO v_draft_time, v_pick_seconds
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF NOT (v_is_commissioner OR (v_draft_time IS NOT NULL AND now() >= v_draft_time)) THEN
    RAISE EXCEPTION 'Draft cannot be started yet';
  END IF;

  PERFORM fcp_ensure_draft_order(p_league_id);

  UPDATE fcp_leagues
  SET draft_status        = 'active',
      current_pick_number = 1,
      pick_deadline       = now() + (v_pick_seconds * interval '1 second')
  WHERE league_id = p_league_id AND season = v_season AND draft_status = 'pending';
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_start_draft(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fcp_start_draft(uuid) TO service_role;


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
  v_season   int;
  v_status   text;
  v_pick_num int;
  v_paused   timestamptz;
  v_expected uuid;
  v_tier     int;
  v_slot     int;
BEGIN
  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT draft_status, current_pick_number, paused_at INTO v_status, v_pick_num, v_paused
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Draft is not active';
  END IF;

  IF v_paused IS NOT NULL THEN
    RAISE EXCEPTION 'Draft is paused';
  END IF;

  v_expected := _fcp_expected_drafter(p_league_id, v_pick_num, v_season);
  IF v_expected IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'It is not your turn';
  END IF;

  SELECT tier INTO v_tier FROM golfers WHERE id = p_golfer_id;
  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'Unknown golfer';
  END IF;

  IF EXISTS (
    SELECT 1 FROM fcp_picks WHERE league_id = p_league_id AND season = v_season AND golfer_id = p_golfer_id
  ) THEN
    RAISE EXCEPTION 'That golfer has already been picked';
  END IF;

  v_slot := _fcp_next_tier_slot(p_league_id, auth.uid(), v_tier, v_season);

  INSERT INTO fcp_picks (league_id, season, user_id, golfer_id, pick_number, tier_slot)
  VALUES (p_league_id, v_season, auth.uid(), p_golfer_id, v_pick_num, v_slot);

  PERFORM _fcp_advance_after_pick(p_league_id, v_pick_num, v_season);
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
  v_season   int;
  v_status   text;
  v_deadline timestamptz;
  v_pick_num int;
  v_expected uuid;
  v_roster_mode text;
  v_golfer_id text;
  v_tier int;
  v_slot int;
BEGIN
  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT draft_status, pick_deadline, current_pick_number, roster_mode
  INTO v_status, v_deadline, v_pick_num, v_roster_mode
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' OR v_deadline IS NULL OR now() < v_deadline THEN
    RETURN;
  END IF;

  v_expected := _fcp_expected_drafter(p_league_id, v_pick_num, v_season);
  IF v_expected IS NULL THEN RETURN; END IF;

  -- Walk remaining golfers by FedEx rank, taking the first one that
  -- fits an open tier slot (or any slot in 'open' mode).
  FOR v_golfer_id, v_tier IN
    SELECT g.id, g.tier
    FROM golfers g
    WHERE NOT EXISTS (
      SELECT 1 FROM fcp_picks p WHERE p.league_id = p_league_id AND p.season = v_season AND p.golfer_id = g.id
    )
    ORDER BY g.fedex_rank
  LOOP
    BEGIN
      v_slot := _fcp_next_tier_slot(p_league_id, v_expected, v_tier, v_season);
    EXCEPTION WHEN OTHERS THEN
      v_slot := NULL;
    END;

    IF v_slot IS NOT NULL THEN
      INSERT INTO fcp_picks (league_id, season, user_id, golfer_id, pick_number, tier_slot)
      VALUES (p_league_id, v_season, v_expected, v_golfer_id, v_pick_num, v_slot);

      PERFORM _fcp_advance_after_pick(p_league_id, v_pick_num, v_season);
      RETURN;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_autopick_if_expired(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fcp_autopick_if_expired(uuid) TO service_role;


-- ------------------------------------------------------------
-- 10.6b fcp_pause_draft / fcp_resume_draft
-- Commissioner-only. Pausing blanks pick_deadline (so
-- fcp_autopick_if_expired's `v_deadline IS NULL` check already no-ops
-- while paused) and stashes the remaining seconds; resuming restores
-- a fresh deadline from that stash so nobody loses pick time to the
-- pause itself.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_pause_draft(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season   int;
  v_status   text;
  v_deadline timestamptz;
  v_paused   timestamptz;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can pause the draft';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT draft_status, pick_deadline, paused_at INTO v_status, v_deadline, v_paused
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Draft is not active';
  END IF;

  IF v_paused IS NOT NULL THEN
    RETURN; -- already paused
  END IF;

  UPDATE fcp_leagues
  SET paused_at              = now(),
      pick_remaining_seconds = GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_deadline - now())))::int),
      pick_deadline          = NULL
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_pause_draft(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION fcp_resume_draft(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season    int;
  v_status    text;
  v_paused    timestamptz;
  v_remaining int;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can resume the draft';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT draft_status, paused_at, pick_remaining_seconds
  INTO v_status, v_paused, v_remaining
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' OR v_paused IS NULL THEN
    RAISE EXCEPTION 'Draft is not paused';
  END IF;

  UPDATE fcp_leagues
  SET pick_deadline          = now() + (COALESCE(v_remaining, 0) * interval '1 second'),
      paused_at              = NULL,
      pick_remaining_seconds = NULL
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_resume_draft(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 10.6c fcp_set_pick_seconds
-- Commissioner-only. Lets the commissioner change the per-pick clock
-- before or during the draft (mirrors the pause/resume time-banking
-- above). If a pick is currently in progress, its deadline shifts by
-- the same delta as the new setting so the change applies immediately
-- rather than only to future picks; if the draft is paused, the banked
-- pick_remaining_seconds is rescaled instead so fcp_resume_draft picks
-- it up correctly.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_set_pick_seconds(p_league_id uuid, p_pick_seconds int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season      int;
  v_old_seconds int;
  v_status      text;
  v_paused      boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can change the pick clock';
  END IF;

  IF p_pick_seconds IS NULL OR p_pick_seconds < 10 OR p_pick_seconds > 600 THEN
    RAISE EXCEPTION 'Pick clock must be between 10 and 600 seconds';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT pick_seconds, draft_status, (paused_at IS NOT NULL)
  INTO v_old_seconds, v_status, v_paused
  FROM fcp_leagues WHERE league_id = p_league_id AND season = v_season FOR UPDATE;

  IF v_status = 'active' AND NOT v_paused THEN
    UPDATE fcp_leagues
    SET pick_seconds  = p_pick_seconds,
        pick_deadline = GREATEST(
          now() + interval '5 seconds',
          pick_deadline + ((p_pick_seconds - v_old_seconds) * interval '1 second')
        )
    WHERE league_id = p_league_id AND season = v_season;
  ELSIF v_status = 'active' AND v_paused THEN
    UPDATE fcp_leagues
    SET pick_seconds           = p_pick_seconds,
        pick_remaining_seconds = GREATEST(5, COALESCE(pick_remaining_seconds, 0) + (p_pick_seconds - v_old_seconds))
    WHERE league_id = p_league_id AND season = v_season;
  ELSE
    UPDATE fcp_leagues SET pick_seconds = p_pick_seconds WHERE league_id = p_league_id AND season = v_season;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_set_pick_seconds(uuid, int) TO authenticated;


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
DECLARE
  v_season int;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  INSERT INTO fcp_scores (league_id, season, user_id, total_points, last_updated)
  SELECT p_league_id, v_season, p.user_id, COALESCE(SUM(r.points), 0), now()
  FROM fcp_picks p
  LEFT JOIN fcp_event_results r ON r.golfer_id = p.golfer_id AND r.season = p.season
  WHERE p.league_id = p_league_id AND p.season = v_season
  GROUP BY p.user_id
  ON CONFLICT (league_id, season, user_id)
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
  -- Joining on l.current_season = p.season is what keeps this
  -- season-correct across every league in one pass: a prior season's
  -- fcp_picks/fcp_scores rows simply stop matching this join once a
  -- league's current_season moves forward, so they're never touched
  -- again and remain permanent history.
  INSERT INTO fcp_scores (league_id, season, user_id, total_points, last_updated)
  SELECT p.league_id, p.season, p.user_id, COALESCE(SUM(r.points), 0), now()
  FROM fcp_picks p
  JOIN leagues l ON l.id = p.league_id AND l.current_season = p.season
  LEFT JOIN fcp_event_results r ON r.golfer_id = p.golfer_id AND r.season = p.season
  GROUP BY p.league_id, p.season, p.user_id
  ON CONFLICT (league_id, season, user_id)
  DO UPDATE SET total_points = EXCLUDED.total_points, last_updated = now();

  -- Season is over once every golfer's tour_championship result is final
  -- (ESPN "FINAL" status is normalized to 'made_cut' by fcp-sync-scores,
  -- see supabase/functions/fcp-sync-scores/index.ts) — auto-complete the
  -- league so it moves to the dashboard's "Completed Leagues" tab. Scoped
  -- to each league's own current_season so a league can never
  -- auto-complete off a stale prior season's synced results.
  UPDATE leagues AS lg SET status = 'completed'
  WHERE lg.status = 'active' AND lg.game_type = 'fedex-playoffs'
    AND EXISTS (
      SELECT 1 FROM fcp_event_results
      WHERE event = 'tour_championship' AND season = lg.current_season
    )
    AND NOT EXISTS (
      SELECT 1 FROM fcp_event_results
      WHERE event = 'tour_championship' AND season = lg.current_season AND status = 'active'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_recalculate_all_scores() TO service_role;


-- ------------------------------------------------------------
-- 10.9 fcp_start_new_season
-- Commissioner-only. Called when reactivating a completed league:
-- inserts a fresh fcp_leagues row for the next season (copying
-- forward roster/draft-format settings so the commissioner doesn't
-- reconfigure them every year) and points leagues.current_season at
-- it. Deliberately never touches the prior season's fcp_draft_order /
-- fcp_picks / fcp_scores / fcp_draft_messages rows — once
-- current_season moves forward those rows are simply never queried
-- again, so they become permanent, browsable history with no separate
-- archival step.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fcp_start_new_season(p_league_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_league_status text;
  v_prior_season  int;
  v_new_season    int;
  v_prior         fcp_leagues%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can start a new season';
  END IF;

  -- Lock the leagues row for the transaction so a double-click can't
  -- pass the status check twice and insert two new-season rows.
  SELECT status INTO v_league_status FROM leagues WHERE id = p_league_id FOR UPDATE;

  IF v_league_status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'League must be completed before starting a new season';
  END IF;

  SELECT max(season) INTO v_prior_season FROM fcp_leagues WHERE league_id = p_league_id;
  IF v_prior_season IS NULL THEN
    RAISE EXCEPTION 'No prior season found for this league';
  END IF;

  v_new_season := GREATEST(extract(year from now())::int, v_prior_season + 1);

  SELECT * INTO v_prior FROM fcp_leagues
  WHERE league_id = p_league_id AND season = v_prior_season;

  INSERT INTO fcp_leagues (
    league_id, season, draft_format, draft_status, draft_time, pick_seconds,
    pick_deadline, paused_at, pick_remaining_seconds, current_pick_number,
    roster_mode, roster_size, tier1_count, tier2_count, tier3_count
  ) VALUES (
    p_league_id, v_new_season, v_prior.draft_format, 'pending', NULL, v_prior.pick_seconds,
    NULL, NULL, NULL, 1,
    v_prior.roster_mode, v_prior.roster_size, v_prior.tier1_count, v_prior.tier2_count, v_prior.tier3_count
  );

  UPDATE leagues SET current_season = v_new_season, status = 'active' WHERE id = p_league_id;

  RETURN v_new_season;
END;
$$;

GRANT EXECUTE ON FUNCTION fcp_start_new_season(uuid) TO authenticated;


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


-- ============================================================
-- SECTION 11 — DRAFT CHAT
-- Lightweight chat scoped to a single league's draft room. Plain
-- inserts (no RPC) since there's no game-state logic to enforce —
-- RLS alone (own user_id + league membership) is enough.
-- ============================================================
CREATE TABLE IF NOT EXISTS fcp_draft_messages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id  uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body       text NOT NULL CHECK (char_length(trim(body)) BETWEEN 1 AND 280),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Idempotent for installs that ran this schema before seasons existed.
-- No unique constraint needed (append-only log) — just keeps a new
-- season's draft chat from mixing with a prior season's in the UI.
ALTER TABLE fcp_draft_messages ADD COLUMN IF NOT EXISTS season int NOT NULL
  DEFAULT extract(year from now())::int;

CREATE INDEX IF NOT EXISTS fcp_draft_messages_league_created_idx
  ON fcp_draft_messages (league_id, created_at);

GRANT SELECT, INSERT ON fcp_draft_messages TO authenticated;

ALTER TABLE fcp_draft_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view chat messages" ON fcp_draft_messages;
DROP POLICY IF EXISTS "League members can send chat messages" ON fcp_draft_messages;

CREATE POLICY "League members can view chat messages"
  ON fcp_draft_messages FOR SELECT USING (is_league_member(fcp_draft_messages.league_id));

CREATE POLICY "League members can send chat messages"
  ON fcp_draft_messages FOR INSERT WITH CHECK (
    user_id = auth.uid() AND is_league_member(fcp_draft_messages.league_id)
  );

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE fcp_draft_messages;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ============================================================
-- SECTION 12 — DRAFT AUTO-START SCHEDULING
-- Guarantees a pending draft goes active within seconds of its
-- draft_time, independent of any client's browser being open and
-- independent of the fcp-draft-cron edge function's 5-minute
-- GitHub Actions cadence (which is only precise to the minute and
-- isn't guaranteed to fire exactly on schedule). Runs inside
-- Postgres itself via pg_cron, so there's no HTTP round trip and
-- no dependency on external CI infrastructure for on-time starts.
-- fcp_start_draft is idempotent (only flips leagues still in
-- 'pending', schema.sql section 10.4) so this is safe to run
-- alongside the client-side lobby auto-start and a commissioner's
-- manual "Start Draft" with no risk of double-starting a draft.
--
-- On Supabase, pg_cron must be enabled once via Database > Extensions
-- in the dashboard before this CREATE EXTENSION will succeed.
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

SELECT cron.schedule(
  'fcp-draft-autostart',
  '15 seconds',
  $$
  SELECT fcp_start_draft(league_id) FROM fcp_leagues
  WHERE draft_status = 'pending' AND draft_time IS NOT NULL AND draft_time <= now();
  $$
);
