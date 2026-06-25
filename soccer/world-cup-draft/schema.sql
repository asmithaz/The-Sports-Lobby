-- ============================================================
-- World Cup Country Draft — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / ON CONFLICT DO NOTHING)
-- ============================================================


-- ------------------------------------------------------------
-- 1. LEAGUES TABLE — shared with world-cup-bracket-challenge
-- These migrations extend the existing leagues table to support
-- draft leagues (league_type is not applicable, max_players is).
-- ------------------------------------------------------------
ALTER TABLE leagues ALTER COLUMN league_type DROP NOT NULL;
ALTER TABLE leagues ADD COLUMN IF NOT EXISTS max_players int;
ALTER TABLE leagues ADD COLUMN IF NOT EXISTS league_password text;


-- ------------------------------------------------------------
-- 2. DRAFT LEAGUES
-- One row per league — stores draft format and state.
-- Created automatically when a league is created via the setup form.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wcd_leagues (
  league_id     uuid PRIMARY KEY REFERENCES leagues(id) ON DELETE CASCADE,
  draft_format  text NOT NULL DEFAULT 'snake' CHECK (draft_format IN ('snake', 'auction')),
  draft_status  text NOT NULL DEFAULT 'pending' CHECK (draft_status IN ('pending', 'active', 'completed')),
  draft_time    timestamptz,
  created_at    timestamptz DEFAULT now()
);
ALTER TABLE wcd_leagues ADD COLUMN IF NOT EXISTS draft_time timestamptz;


-- ------------------------------------------------------------
-- 3. DRAFT ORDER
-- One row per (league, user) — position in the snake draft.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wcd_draft_order (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id  uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  position   int  NOT NULL,
  UNIQUE(league_id, user_id),
  UNIQUE(league_id, position)
);


-- ------------------------------------------------------------
-- 4. DRAFT PICKS
-- One row per country picked. pick_number is the global pick
-- sequence across all rounds (1, 2, 3 … max_players * 48).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wcd_picks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id    uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  team_id      text NOT NULL REFERENCES wc_teams(id),
  pick_number  int  NOT NULL,
  picked_at    timestamptz DEFAULT now(),
  UNIQUE(league_id, team_id),
  UNIQUE(league_id, pick_number)
);


-- ------------------------------------------------------------
-- 5. SCORES
-- Cached points per user per league. Recalculated as tournament
-- results come in (group_finish, elimination_round on wc_teams).
-- Points awarded per result for a drafted country:
--   Group stage win:    2 pts
--   Group stage draw:   1 pt
--   Group stage loss:   0 pts
--   Knockout win:       2 pts
--   Champion:           4 pts
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wcd_scores (
  league_id    uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  total_points int  NOT NULL DEFAULT 0,
  last_updated timestamptz DEFAULT now(),
  PRIMARY KEY(league_id, user_id)
);


-- ------------------------------------------------------------
-- 6. GRANTS
-- ------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON wcd_leagues    TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wcd_draft_order TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wcd_picks      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wcd_scores     TO authenticated;


-- ------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ------------------------------------------------------------
ALTER TABLE wcd_leagues     ENABLE ROW LEVEL SECURITY;
ALTER TABLE wcd_draft_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE wcd_picks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE wcd_scores      ENABLE ROW LEVEL SECURITY;

-- wcd_leagues
DROP POLICY IF EXISTS "League members can view draft league" ON wcd_leagues;
DROP POLICY IF EXISTS "Commissioner can insert draft league" ON wcd_leagues;
DROP POLICY IF EXISTS "Commissioner can update draft league" ON wcd_leagues;

CREATE POLICY "League members can view draft league"
  ON wcd_leagues FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wcd_leagues.league_id AND user_id = auth.uid())
  );

CREATE POLICY "Commissioner can insert draft league"
  ON wcd_leagues FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM leagues WHERE id = wcd_leagues.league_id AND commissioner_id = auth.uid())
  );

CREATE POLICY "Commissioner can update draft league"
  ON wcd_leagues FOR UPDATE USING (
    EXISTS (SELECT 1 FROM leagues WHERE id = wcd_leagues.league_id AND commissioner_id = auth.uid())
  );

-- wcd_draft_order
DROP POLICY IF EXISTS "League members can view draft order" ON wcd_draft_order;
DROP POLICY IF EXISTS "Commissioner can manage draft order" ON wcd_draft_order;

CREATE POLICY "League members can view draft order"
  ON wcd_draft_order FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wcd_draft_order.league_id AND user_id = auth.uid())
  );

CREATE POLICY "Commissioner can manage draft order"
  ON wcd_draft_order FOR ALL USING (
    EXISTS (SELECT 1 FROM leagues WHERE id = wcd_draft_order.league_id AND commissioner_id = auth.uid())
  );

-- wcd_picks
DROP POLICY IF EXISTS "League members can view picks" ON wcd_picks;
DROP POLICY IF EXISTS "Users manage own picks"        ON wcd_picks;

CREATE POLICY "League members can view picks"
  ON wcd_picks FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wcd_picks.league_id AND user_id = auth.uid())
  );

CREATE POLICY "Users manage own picks"
  ON wcd_picks FOR ALL USING (user_id = auth.uid());

-- wcd_scores
DROP POLICY IF EXISTS "League members can view scores" ON wcd_scores;

CREATE POLICY "League members can view scores"
  ON wcd_scores FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wcd_scores.league_id AND user_id = auth.uid())
  );


-- ============================================================
-- SECTION 14 — LIVE DRAFT ENGINE
-- Snake-draft lobby, turn enforcement, pick timer + autopick.
-- All writes to wcd_picks / wcd_draft_order / wcd_leagues during
-- an active draft go through the SECURITY DEFINER RPCs below so
-- turn order and team availability are enforced server-side.
-- ============================================================

-- ------------------------------------------------------------
-- 14.1 wcd_leagues — pick clock columns
-- ------------------------------------------------------------
ALTER TABLE wcd_leagues ADD COLUMN IF NOT EXISTS pick_seconds int NOT NULL DEFAULT 90;
ALTER TABLE wcd_leagues ADD COLUMN IF NOT EXISTS pick_deadline timestamptz;
ALTER TABLE wcd_leagues ADD COLUMN IF NOT EXISTS current_pick_number int NOT NULL DEFAULT 1;


-- ------------------------------------------------------------
-- 14.2 Draft order helpers
-- ------------------------------------------------------------

-- Populate a randomized draft order the first time anyone opens the lobby.
-- Idempotent — does nothing once an order exists for the league.
CREATE OR REPLACE FUNCTION ensure_draft_order(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM wcd_draft_order WHERE league_id = p_league_id) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM league_members WHERE league_id = p_league_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  INSERT INTO wcd_draft_order (league_id, user_id, position)
  SELECT p_league_id, user_id, row_number() OVER (ORDER BY random())
  FROM league_members
  WHERE league_id = p_league_id;
END;
$$;

GRANT EXECUTE ON FUNCTION ensure_draft_order(uuid) TO authenticated;


-- Let the commissioner reorder drafters any time before the draft starts.
-- p_user_ids must contain every league member exactly once, in the desired
-- pick order (index 0 picks first).
CREATE OR REPLACE FUNCTION set_draft_order(p_league_id uuid, p_user_ids uuid[])
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
  FROM wcd_leagues WHERE league_id = p_league_id;

  IF v_status IS DISTINCT FROM 'pending' OR v_draft_time IS NULL OR now() >= v_draft_time THEN
    RAISE EXCEPTION 'Draft order can only be changed before the draft starts';
  END IF;

  SELECT count(*) INTO v_member_count FROM league_members WHERE league_id = p_league_id;
  IF p_user_ids IS NULL OR array_length(p_user_ids, 1) IS DISTINCT FROM v_member_count THEN
    RAISE EXCEPTION 'Draft order must include every league member exactly once';
  END IF;

  PERFORM ensure_draft_order(p_league_id);

  -- Shift existing positions out of the way first so the per-row updates
  -- below never collide with the UNIQUE(league_id, position) constraint.
  UPDATE wcd_draft_order SET position = position + v_member_count WHERE league_id = p_league_id;

  FOR i IN 1..v_member_count LOOP
    UPDATE wcd_draft_order SET position = i
    WHERE league_id = p_league_id AND user_id = p_user_ids[i];
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION set_draft_order(uuid, uuid[]) TO authenticated;


-- ------------------------------------------------------------
-- 14.3 Snake order helper
-- Returns the user_id expected to make the given global pick number.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION _expected_drafter(p_league_id uuid, p_pick_number int)
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
    SELECT user_id FROM wcd_draft_order
    WHERE league_id = p_league_id AND position = v_slot + 1
  );
END;
$$;


-- Advance current_pick_number / pick_deadline after a pick is recorded,
-- or mark the draft completed if that was the last pick.
CREATE OR REPLACE FUNCTION _advance_after_pick(p_league_id uuid, p_pick_number int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_n          int;
  v_pick_secs  int;
BEGIN
  SELECT count(*) INTO v_n FROM league_members WHERE league_id = p_league_id;

  IF p_pick_number >= 48 * v_n THEN
    UPDATE wcd_leagues SET draft_status = 'completed' WHERE league_id = p_league_id;
  ELSE
    SELECT pick_seconds INTO v_pick_secs FROM wcd_leagues WHERE league_id = p_league_id;
    UPDATE wcd_leagues
    SET current_pick_number = p_pick_number + 1,
        pick_deadline       = now() + (v_pick_secs * interval '1 second')
    WHERE league_id = p_league_id;
  END IF;
END;
$$;


-- ------------------------------------------------------------
-- 14.4 start_draft
-- Manual early start by the commissioner, or auto-start by any
-- league member once draft_time has passed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION start_draft(p_league_id uuid)
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
  FROM wcd_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF NOT (v_is_commissioner OR (v_draft_time IS NOT NULL AND now() >= v_draft_time)) THEN
    RAISE EXCEPTION 'Draft cannot be started yet';
  END IF;

  PERFORM ensure_draft_order(p_league_id);

  UPDATE wcd_leagues
  SET draft_status        = 'active',
      current_pick_number = 1,
      pick_deadline       = now() + (v_pick_seconds * interval '1 second')
  WHERE league_id = p_league_id AND draft_status = 'pending';
END;
$$;

GRANT EXECUTE ON FUNCTION start_draft(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 14.5 make_draft_pick
-- The only way a player records a pick. Enforces turn order and
-- team availability; advances the clock.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION make_draft_pick(p_league_id uuid, p_team_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_status   text;
  v_pick_num int;
  v_expected uuid;
BEGIN
  SELECT draft_status, current_pick_number INTO v_status, v_pick_num
  FROM wcd_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Draft is not active';
  END IF;

  v_expected := _expected_drafter(p_league_id, v_pick_num);
  IF v_expected IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'It is not your turn';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM wc_teams WHERE id = p_team_id) THEN
    RAISE EXCEPTION 'Unknown team';
  END IF;

  IF EXISTS (SELECT 1 FROM wcd_picks WHERE league_id = p_league_id AND team_id = p_team_id) THEN
    RAISE EXCEPTION 'That team has already been picked';
  END IF;

  INSERT INTO wcd_picks (league_id, user_id, team_id, pick_number)
  VALUES (p_league_id, auth.uid(), p_team_id, v_pick_num);

  PERFORM _advance_after_pick(p_league_id, v_pick_num);
END;
$$;

GRANT EXECUTE ON FUNCTION make_draft_pick(uuid, text) TO authenticated;


-- ------------------------------------------------------------
-- 14.6 autopick_if_expired
-- Called speculatively by any connected client. No-ops unless the
-- current pick's timer has actually expired.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION autopick_if_expired(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_status   text;
  v_deadline timestamptz;
  v_pick_num int;
  v_expected uuid;
  v_team_id  text;
BEGIN
  SELECT draft_status, pick_deadline, current_pick_number
  INTO v_status, v_deadline, v_pick_num
  FROM wcd_leagues WHERE league_id = p_league_id FOR UPDATE;

  IF v_status IS DISTINCT FROM 'active' OR v_deadline IS NULL OR now() < v_deadline THEN
    RETURN;
  END IF;

  v_expected := _expected_drafter(p_league_id, v_pick_num);
  IF v_expected IS NULL THEN RETURN; END IF;

  -- Default autopick choice: alphabetically-first remaining team.
  SELECT t.id INTO v_team_id
  FROM wc_teams t
  WHERE NOT EXISTS (
    SELECT 1 FROM wcd_picks p WHERE p.league_id = p_league_id AND p.team_id = t.id
  )
  ORDER BY t.id
  LIMIT 1;

  IF v_team_id IS NULL THEN RETURN; END IF;

  INSERT INTO wcd_picks (league_id, user_id, team_id, pick_number)
  VALUES (p_league_id, v_expected, v_team_id, v_pick_num);

  PERFORM _advance_after_pick(p_league_id, v_pick_num);
END;
$$;

GRANT EXECUTE ON FUNCTION autopick_if_expired(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 14.7 RLS — picks are written only via the RPCs above
-- ------------------------------------------------------------
DROP POLICY IF EXISTS "Users manage own picks" ON wcd_picks;


-- ------------------------------------------------------------
-- 14.8 Realtime — broadcast pick/order/status changes to clients
-- ------------------------------------------------------------
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE wcd_picks;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE wcd_leagues;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE wcd_draft_order;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------
-- 14.9 Auction draft — placeholder (not implemented)
-- When auction support is built, it will need roughly:
--
-- CREATE TABLE wcd_auction_nominations (
--   league_id      uuid REFERENCES leagues(id) ON DELETE CASCADE,
--   team_id        text REFERENCES wc_teams(id),
--   nominated_by   uuid REFERENCES auth.users(id),
--   current_bid    int,
--   high_bidder    uuid REFERENCES auth.users(id),
--   bid_deadline   timestamptz,
--   PRIMARY KEY (league_id, team_id)
-- );
--
-- CREATE TABLE wcd_auction_bids (
--   id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--   league_id   uuid REFERENCES leagues(id) ON DELETE CASCADE,
--   team_id     text REFERENCES wc_teams(id),
--   user_id     uuid REFERENCES auth.users(id),
--   amount      int NOT NULL,
--   created_at  timestamptz DEFAULT now()
-- );
--
-- wcd_leagues.draft_format already accepts 'auction' (see Section 2),
-- and the draft page already branches on draft_format to show an
-- "Auction draft — coming soon" view for these leagues.
-- ------------------------------------------------------------


-- ============================================================
-- SECTION 15 — FIX: league_members SELECT visibility
-- The original "Members can view their memberships" policy only
-- matched user_id = auth.uid(), so a SELECT for a whole league only
-- ever returned the caller's own row — breaking any member list
-- (dashboard roster, draft lobby, etc.). Replace it with a policy
-- that lets a member see every row for leagues they belong to.
--
-- A SECURITY DEFINER helper is used (rather than an EXISTS subquery
-- directly inside the policy) to avoid the policy recursively
-- re-applying itself to league_members.
-- ============================================================
CREATE OR REPLACE FUNCTION is_league_member(p_league_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM league_members
    WHERE league_id = p_league_id AND user_id = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION is_league_member(uuid) TO authenticated;

DROP POLICY IF EXISTS "Members can view their memberships" ON league_members;

CREATE POLICY "Members can view fellow league members"
  ON league_members FOR SELECT USING (is_league_member(league_id));
