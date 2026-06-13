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
