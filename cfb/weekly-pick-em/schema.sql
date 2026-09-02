-- ============================================================
-- CFB Weekly Pick 'Em — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE / ON CONFLICT)
--
-- Assumes the shared `leagues`, `league_members`, `profiles` tables
-- and the `is_league_member(uuid)` helper already exist (see
-- soccer/world-cup-bracket-challenge/schema.sql), plus the shared
-- `join_league_by_invite_code()` / `set_team_name()` RPCs.
--
-- Prefix: wpe_ (Weekly Pick 'Em). game_type = 'cfb-weekly-pick-em'.
-- REGULAR SEASON ONLY — bowls/CFP are exclusively
-- cfb/bowl-season-pick-em's territory. The regular-season/postseason
-- boundary is auto-detected from ESPN's own season.type field by the
-- sync function (2 = regular, 3 = postseason), not a hardcoded date.
-- ============================================================


-- ------------------------------------------------------------
-- 1. WPE GAMES
-- One shared global table for the whole regular season, same
-- "singleton shared data" pattern as bpe_games. Conference, AP/CFP
-- rank, and the "Sports Lobby Choice" flag are denormalized directly
-- onto each row (computed/populated at sync time) so per-league slate
-- filtering (wpe_get_slate below) is a plain WHERE clause against
-- this one table — no per-league materialized slate, no separate
-- conferences table.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wpe_games (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  season                int  NOT NULL DEFAULT extract(year from now())::int,
  week                  int  NOT NULL,               -- ESPN's own week number, not computed locally
  espn_event_id         text NOT NULL,
  home_team             text NOT NULL,
  away_team             text NOT NULL,
  home_team_logo        text,
  away_team_logo        text,
  home_conference       text,                        -- nullable — see sync function's primary/fallback strategy
  away_conference       text,
  home_rank             int,                         -- AP/CFP rank 1-25, NULL if unranked (ESPN's 99 sentinel normalized to NULL)
  away_rank             int,
  sports_lobby_choice   boolean NOT NULL DEFAULT false,  -- set by the sync function's weekly "best games" heuristic
  favorite_team         text,                        -- one of home_team/away_team, or NULL if pick'em/no line yet
  spread                numeric,                     -- FROZEN at first sync — never updated by a routine re-sync
  kickoff_at            timestamptz,
  status                text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'live', 'final')),
  home_score            int,
  away_score            int,
  winner_team           text,                        -- straight-up winner, set once status = 'final'
  ats_winner_team       text,                        -- against-the-spread winner; NULL on a push
  matchup_version       int  NOT NULL DEFAULT 1,      -- bumped by wpe_apply_matchup_change() on a teams change
  synced_at             timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season, espn_event_id)
);

CREATE INDEX IF NOT EXISTS wpe_games_season_week_idx ON wpe_games(season, week);

ALTER TABLE wpe_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Weekly games readable by all" ON wpe_games;
CREATE POLICY "Weekly games readable by all" ON wpe_games FOR SELECT USING (true);

GRANT SELECT ON wpe_games TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON wpe_games TO service_role;

-- True once a game is finished, or its kickoff-minus-5-minutes lock has
-- passed. Same rule as Bowl Pick'em's bpe_is_game_locked.
CREATE OR REPLACE FUNCTION wpe_is_game_locked(p_game_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT status = 'final' OR (kickoff_at IS NOT NULL AND now() >= kickoff_at - interval '5 minutes')
     FROM wpe_games WHERE id = p_game_id),
    false
  );
$$;
GRANT EXECUTE ON FUNCTION wpe_is_game_locked(uuid) TO anon, authenticated;

-- Canonical conference name lists, used by wpe_get_slate,
-- wpe_scope_preview_counts, and mirrored in the sync function (as a TS
-- constant) for the Sports Lobby Choice heuristic's Power 4 bonus.
-- MUST be kept in sync with whatever conference name strings ESPN's
-- payload actually produces — confirm via dry-run before trusting in
-- production (see wpe-sync-games' own header comment).
CREATE OR REPLACE FUNCTION wpe_power4_conferences() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['ACC','Big 12','Big Ten','SEC'];
$$;
CREATE OR REPLACE FUNCTION wpe_group_of_5_conferences() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['American','Conference USA','MAC','Mountain West','Sun Belt'];
$$;


-- ------------------------------------------------------------
-- 2. WPE LEAGUES
-- One row per league PER SEASON — a league is reused year over year
-- (same leagues.id, same invite code) via wpe_start_new_season(), same
-- widened-PK pattern bpe_leagues/fcp_leagues use. `scope_mode` is the
-- commissioner's chosen preset; `conferences`/`include_top25` are ONLY
-- consulted when scope_mode = 'custom' (still stored otherwise so
-- switching back to custom later remembers the prior manual choice).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wpe_leagues (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season         int  NOT NULL DEFAULT extract(year from now())::int,
  pick_mode      text NOT NULL DEFAULT 'straight_up' CHECK (pick_mode IN ('straight_up', 'spread')),
  scoring_mode   text NOT NULL DEFAULT 'flat' CHECK (scoring_mode IN ('flat', 'confidence')),
  scope_mode     text NOT NULL DEFAULT 'sports_lobby_choice'
                   CHECK (scope_mode IN ('power4', 'group_of_5', 'all_fbs', 'sports_lobby_choice', 'custom')),
  conferences    text[] NOT NULL DEFAULT '{}',
  include_top25  boolean NOT NULL DEFAULT true,
  -- Week 0 (the season-opening slate ~a week before the main schedule —
  -- Ireland Classic, island-travel openers, etc.) defaults OFF: it's a
  -- small, unusual slate a commissioner may not want counted alongside
  -- the regular weekly cadence. Applies on top of scope_mode filtering —
  -- a week-0 game still has to pass the league's conference/Top25/etc.
  -- scope to be pickable even when this is on.
  include_week_zero boolean NOT NULL DEFAULT false,
  created_at     timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season),
  CHECK (scope_mode != 'custom' OR COALESCE(array_length(conferences, 1), 0) > 0 OR include_top25)
);

-- `CREATE TABLE IF NOT EXISTS` above is a no-op once the table already
-- exists (true from the second time this file runs onward) — it does NOT
-- retroactively add new columns, so any column added after initial launch
-- needs its own explicit ALTER TABLE here.
ALTER TABLE wpe_leagues ADD COLUMN IF NOT EXISTS include_week_zero boolean NOT NULL DEFAULT false;

ALTER TABLE wpe_leagues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view wpe league" ON wpe_leagues;
CREATE POLICY "League members can view wpe league" ON wpe_leagues FOR SELECT
  USING (is_league_member(league_id));

DROP POLICY IF EXISTS "Commissioner can insert wpe league" ON wpe_leagues;
CREATE POLICY "Commissioner can insert wpe league" ON wpe_leagues FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM leagues WHERE id = wpe_leagues.league_id AND commissioner_id = auth.uid()
  ));
-- Deliberately no direct UPDATE policy — every post-creation change to
-- a season's settings goes through wpe_update_league_settings(), which
-- can reject the pick_mode/scoring_mode change once picks already
-- exist. A raw UPDATE policy can't express that guard.

GRANT SELECT, INSERT ON wpe_leagues TO authenticated;


-- ------------------------------------------------------------
-- 3. WPE PICKS
-- The lock-gated-visibility table: your own picks are always visible
-- to you; other members' picks on a given game only become visible
-- once THAT SPECIFIC GAME locks. Same shape as bpe_picks. `week` is
-- denormalized from the game row so per-week confidence uniqueness
-- and the picks page's per-week sectioning don't need a join.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wpe_picks (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id          uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season             int  NOT NULL,
  week               int  NOT NULL,
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id            uuid NOT NULL REFERENCES wpe_games(id) ON DELETE CASCADE,
  picked_team        text NOT NULL,   -- must equal wpe_games.home_team or .away_team — checked in wpe_submit_pick
  confidence_points  int,             -- NULL in flat mode; dynamic 1..N (N = that week's slate size) in confidence mode
  submitted_at       timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now(),
  UNIQUE (league_id, season, user_id, game_id)
);

CREATE INDEX IF NOT EXISTS wpe_picks_league_season_week_idx ON wpe_picks(league_id, season, week);

ALTER TABLE wpe_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own picks always visible; others after game locks" ON wpe_picks;
CREATE POLICY "Own picks always visible; others after game locks" ON wpe_picks FOR SELECT
  USING (
    user_id = auth.uid()
    OR (is_league_member(wpe_picks.league_id) AND wpe_is_game_locked(wpe_picks.game_id))
  );
-- No direct INSERT/UPDATE/DELETE policy — all writes go through
-- wpe_submit_pick() / wpe_clear_pick(), which is what enforces the
-- lock/team-validity/confidence-range rules.

GRANT SELECT ON wpe_picks TO authenticated;


-- ------------------------------------------------------------
-- 4. WPE SCORES
-- Running total only — no fixed wave buckets like Bowl Pick'em, since
-- a regular season has 13-15+ weeks rather than 4 fixed waves.
-- Per-week breakdown is computed live off wpe_picks/wpe_games when a
-- standings row is expanded (same "fetch on click" approach Bowl's
-- dashboard already uses for its per-wave breakdown, grouped by week
-- instead of tier).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wpe_scores (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season         int  NOT NULL,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  total_points   int  NOT NULL DEFAULT 0,
  wins           int  NOT NULL DEFAULT 0,
  losses         int  NOT NULL DEFAULT 0,
  last_updated   timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, user_id)
);

ALTER TABLE wpe_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view wpe scores" ON wpe_scores;
CREATE POLICY "League members can view wpe scores" ON wpe_scores FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON wpe_scores TO authenticated;
GRANT SELECT, INSERT, UPDATE ON wpe_scores TO service_role;


-- ------------------------------------------------------------
-- 5. WPE SEASON STATE
-- Tracks ESPN's own reported week/season-type per season — this is
-- how "current week" is known (never computed locally from today's
-- date) and how the regular-season/postseason boundary is detected
-- (season_type flips 2->3 once conference championship weekend ends).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wpe_season_state (
  season                       int PRIMARY KEY,
  season_type                  int,             -- ESPN's own value: 2 = regular season, 3 = postseason
  current_week                 int,
  regular_season_complete_at   timestamptz,     -- set once season_type is first observed as 3
  updated_at                   timestamptz DEFAULT now()
);

ALTER TABLE wpe_season_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Season state readable by all" ON wpe_season_state;
CREATE POLICY "Season state readable by all" ON wpe_season_state FOR SELECT USING (true);

GRANT SELECT ON wpe_season_state TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON wpe_season_state TO service_role;


-- ------------------------------------------------------------
-- 6. RPCs
-- ------------------------------------------------------------

-- wpe_list_conferences: powers the setup/settings page's conference
-- multi-select (the 'custom' scope option). Reads DISTINCT conference
-- names actually seen in synced games rather than a hardcoded roster
-- — sidesteps conference realignment maintenance entirely.
CREATE OR REPLACE FUNCTION wpe_list_conferences()
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT DISTINCT conf FROM (
    SELECT home_conference AS conf FROM wpe_games WHERE home_conference IS NOT NULL
    UNION
    SELECT away_conference FROM wpe_games WHERE away_conference IS NOT NULL
  ) x ORDER BY conf;
$$;
GRANT EXECUTE ON FUNCTION wpe_list_conferences() TO anon, authenticated;

-- wpe_scope_preview_counts: live "approx. N games/week" counts for
-- every scope option on the setup/settings page, including a live
-- count for whatever the custom checkboxes currently have checked.
-- Callable with no league_id — pure public-data preview, usable
-- before a league even exists.
CREATE OR REPLACE FUNCTION wpe_scope_preview_counts(
  p_season int,
  p_week int DEFAULT NULL,
  p_custom_conferences text[] DEFAULT '{}',
  p_custom_include_top25 boolean DEFAULT false
)
RETURNS TABLE (scope_mode text, game_count int)
LANGUAGE sql STABLE
AS $$
  WITH wk AS (
    SELECT COALESCE(p_week, (SELECT current_week FROM wpe_season_state WHERE season = p_season)) AS w
  ), g AS (
    SELECT * FROM wpe_games, wk WHERE season = p_season AND week = wk.w
  )
  SELECT 'power4', count(*)::int FROM g
    WHERE home_conference = ANY(wpe_power4_conferences()) OR away_conference = ANY(wpe_power4_conferences())
  UNION ALL
  SELECT 'group_of_5', count(*)::int FROM g
    WHERE home_conference = ANY(wpe_group_of_5_conferences()) OR away_conference = ANY(wpe_group_of_5_conferences())
  UNION ALL
  SELECT 'all_fbs', count(*)::int FROM g
  UNION ALL
  SELECT 'sports_lobby_choice', count(*)::int FROM g WHERE sports_lobby_choice
  UNION ALL
  SELECT 'custom', count(*)::int FROM g
    WHERE home_conference = ANY(p_custom_conferences) OR away_conference = ANY(p_custom_conferences)
       OR (p_custom_include_top25 AND ((home_rank BETWEEN 1 AND 25) OR (away_rank BETWEEN 1 AND 25)));
$$;
GRANT EXECUTE ON FUNCTION wpe_scope_preview_counts(int, int, text[], boolean) TO anon, authenticated;

-- wpe_get_slate: the single source of truth for "which games does
-- this league pick from this week" — branches on the league's
-- scope_mode. Reused by the picks page, the dashboard's Pick
-- Comparison grid, and wpe_submit_pick's own eligibility/confidence-
-- range check.
CREATE OR REPLACE FUNCTION wpe_get_slate(p_league_id uuid, p_season int, p_week int DEFAULT NULL)
RETURNS SETOF wpe_games
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_league wpe_leagues%ROWTYPE;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT * INTO v_league FROM wpe_leagues WHERE league_id = p_league_id AND season = p_season;

  RETURN QUERY
  SELECT g.*
  FROM wpe_games g
  WHERE g.season = p_season
    AND (p_week IS NULL OR g.week = p_week)
    AND (g.week != 0 OR v_league.include_week_zero)
    AND (
      (v_league.scope_mode = 'power4' AND (g.home_conference = ANY(wpe_power4_conferences()) OR g.away_conference = ANY(wpe_power4_conferences())))
      OR (v_league.scope_mode = 'group_of_5' AND (g.home_conference = ANY(wpe_group_of_5_conferences()) OR g.away_conference = ANY(wpe_group_of_5_conferences())))
      OR (v_league.scope_mode = 'all_fbs')
      OR (v_league.scope_mode = 'sports_lobby_choice' AND g.sports_lobby_choice)
      OR (v_league.scope_mode = 'custom' AND (
            g.home_conference = ANY(v_league.conferences) OR g.away_conference = ANY(v_league.conferences)
            OR (v_league.include_top25 AND ((g.home_rank BETWEEN 1 AND 25) OR (g.away_rank BETWEEN 1 AND 25)))
         ))
    )
  ORDER BY g.week, g.kickoff_at NULLS LAST;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_get_slate(uuid, int, int) TO authenticated;


-- wpe_submit_pick: the main write path for the picks tab. Validates
-- membership, lock state, team validity, and that the game is
-- actually in this league's filtered slate — then, in confidence
-- mode, that the value is within THIS WEEK's dynamic range (1..N,
-- N = this league's slate size for that week, NOT a hardcoded range
-- like Bowl Pick'em's fixed per-wave ranks). Uniqueness enforced via a
-- displacement swap rather than a hard UNIQUE constraint, scoped to
-- (league, season, week) instead of a wave — same drag-to-reorder
-- semantics as bpe_submit_pick.
CREATE OR REPLACE FUNCTION wpe_submit_pick(
  p_league_id uuid,
  p_game_id uuid,
  p_picked_team text,
  p_confidence_points int DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season         int;
  v_scoring_mode   text;
  v_game           wpe_games%ROWTYPE;
  v_slate_size     int;
  v_prev_conf      int;
  v_swap_game_id   uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT * INTO v_game FROM wpe_games WHERE id = p_game_id AND season = v_season;
  IF v_game.id IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;
  IF wpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  IF p_picked_team NOT IN (v_game.home_team, v_game.away_team) THEN
    RAISE EXCEPTION 'Invalid team for this game';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM wpe_get_slate(p_league_id, v_season, v_game.week) s WHERE s.id = p_game_id) THEN
    RAISE EXCEPTION 'This game is not part of your league''s weekly slate';
  END IF;

  SELECT scoring_mode INTO v_scoring_mode FROM wpe_leagues
    WHERE league_id = p_league_id AND season = v_season;
  IF v_scoring_mode IS NULL THEN
    RAISE EXCEPTION 'League is not configured for the current season';
  END IF;

  IF v_scoring_mode = 'confidence' THEN
    SELECT count(*) INTO v_slate_size FROM wpe_get_slate(p_league_id, v_season, v_game.week);

    IF p_confidence_points IS NULL OR p_confidence_points < 1 OR p_confidence_points > v_slate_size THEN
      RAISE EXCEPTION 'Confidence must be between 1 and % for Week %', v_slate_size, v_game.week;
    END IF;

    SELECT confidence_points INTO v_prev_conf
    FROM wpe_picks
    WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = p_game_id;

    SELECT p2.game_id INTO v_swap_game_id
    FROM wpe_picks p2
    WHERE p2.league_id = p_league_id AND p2.season = v_season AND p2.user_id = auth.uid()
      AND p2.week = v_game.week AND p2.game_id != p_game_id AND p2.confidence_points = p_confidence_points
    LIMIT 1;

    IF v_swap_game_id IS NOT NULL THEN
      UPDATE wpe_picks SET confidence_points = v_prev_conf, updated_at = now()
      WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = v_swap_game_id;
    END IF;
  ELSE
    p_confidence_points := NULL; -- flat mode never stores a confidence value
  END IF;

  INSERT INTO wpe_picks (league_id, season, week, user_id, game_id, picked_team, confidence_points, updated_at)
  VALUES (p_league_id, v_season, v_game.week, auth.uid(), p_game_id, p_picked_team, p_confidence_points, now())
  ON CONFLICT (league_id, season, user_id, game_id)
  DO UPDATE SET picked_team = EXCLUDED.picked_team, confidence_points = EXCLUDED.confidence_points, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_submit_pick(uuid, uuid, text, int) TO authenticated;


-- wpe_clear_pick: undo a pick, only while its game is still open.
CREATE OR REPLACE FUNCTION wpe_clear_pick(p_league_id uuid, p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF wpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  DELETE FROM wpe_picks
  WHERE league_id = p_league_id AND user_id = auth.uid() AND game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_clear_pick(uuid, uuid) TO authenticated;


-- wpe_update_league_settings: unlike bpe_update_league_settings, only
-- pick_mode/scoring_mode are lock-sensitive (they change how already-
-- scored picks are interpreted). scope_mode/conferences/include_top25
-- only affect which games are offered going forward and stay editable
-- any time — deliberately less restrictive than Bowl's all-or-nothing
-- lock, since changing the weekly game pool doesn't corrupt past
-- weeks' already-scored picks the way flipping pick/scoring mode would.
-- Adding a parameter changes the signature — CREATE OR REPLACE would leave
-- the old 6-arg version behind as a separate overload rather than
-- replacing it, so drop it explicitly first.
DROP FUNCTION IF EXISTS wpe_update_league_settings(uuid, text, text, text, text[], boolean);
CREATE OR REPLACE FUNCTION wpe_update_league_settings(
  p_league_id uuid,
  p_pick_mode text,
  p_scoring_mode text,
  p_scope_mode text,
  p_conferences text[],
  p_include_top25 boolean,
  p_include_week_zero boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season int;
  v_is_commissioner boolean;
  v_current_pick_mode text;
  v_current_scoring_mode text;
  v_pick_count int;
BEGIN
  SELECT current_season, (commissioner_id = auth.uid())
    INTO v_season, v_is_commissioner
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can change league settings';
  END IF;

  IF p_scope_mode = 'custom' AND COALESCE(array_length(p_conferences, 1), 0) = 0 AND NOT p_include_top25 THEN
    RAISE EXCEPTION 'Select at least one conference, or turn on Top 25 games';
  END IF;

  SELECT pick_mode, scoring_mode INTO v_current_pick_mode, v_current_scoring_mode
  FROM wpe_leagues WHERE league_id = p_league_id AND season = v_season;

  IF p_pick_mode IS DISTINCT FROM v_current_pick_mode OR p_scoring_mode IS DISTINCT FROM v_current_scoring_mode THEN
    SELECT count(*) INTO v_pick_count FROM wpe_picks WHERE league_id = p_league_id AND season = v_season;
    IF v_pick_count > 0 THEN
      RAISE EXCEPTION 'Cannot change pick/scoring mode after picks have been made this season';
    END IF;
  END IF;

  UPDATE wpe_leagues SET
    pick_mode = p_pick_mode, scoring_mode = p_scoring_mode,
    scope_mode = p_scope_mode, conferences = p_conferences, include_top25 = p_include_top25,
    include_week_zero = p_include_week_zero
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_update_league_settings(uuid, text, text, text, text[], boolean, boolean) TO authenticated;


-- wpe_recalculate_scores: recomputes one league+season's wpe_scores
-- from scratch off wpe_picks + wpe_games. Flat mode is a uniform 1
-- pt/correct pick (no per-tier point table — weekly games have no
-- tiers, unlike Bowl's bowl/CFP-round tiers). A push (ats_winner_team
-- IS NULL under spread mode) scores 0 and doesn't count as a win or a
-- loss.
CREATE OR REPLACE FUNCTION wpe_recalculate_scores(p_league_id uuid, p_season int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pick_mode text;
  v_scoring_mode text;
BEGIN
  SELECT pick_mode, scoring_mode INTO v_pick_mode, v_scoring_mode
  FROM wpe_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_pick_mode IS NULL THEN
    RETURN; -- no wpe_leagues row for this league/season yet — nothing to score
  END IF;

  INSERT INTO wpe_scores (league_id, season, user_id, total_points, wins, losses, last_updated)
  SELECT
    p_league_id, p_season, m.user_id,
    COALESCE(SUM(calc.pts), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_win), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_loss), 0),
    now()
  FROM league_members m
  LEFT JOIN wpe_picks p ON p.league_id = p_league_id AND p.season = p_season AND p.user_id = m.user_id
  LEFT JOIN wpe_games g ON g.id = p.game_id AND g.status = 'final'
  LEFT JOIN LATERAL (
    SELECT
      (g.id IS NOT NULL AND NOT (v_pick_mode = 'spread' AND g.ats_winner_team IS NULL)
        AND ((v_pick_mode = 'straight_up' AND p.picked_team = g.winner_team)
             OR (v_pick_mode = 'spread' AND p.picked_team = g.ats_winner_team))
      ) AS is_correct
  ) chk ON true
  LEFT JOIN LATERAL (
    SELECT
      CASE WHEN NOT chk.is_correct THEN 0
        WHEN v_scoring_mode = 'confidence' THEN COALESCE(p.confidence_points, 0)
        ELSE 1
      END AS pts,
      chk.is_correct AS is_win,
      (g.id IS NOT NULL AND NOT (v_pick_mode = 'spread' AND g.ats_winner_team IS NULL) AND NOT chk.is_correct) AS is_loss
  ) calc ON true
  WHERE m.league_id = p_league_id
  GROUP BY m.user_id
  ON CONFLICT (league_id, season, user_id) DO UPDATE SET
    total_points = EXCLUDED.total_points, wins = EXCLUDED.wins, losses = EXCLUDED.losses, last_updated = now();
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_recalculate_scores(uuid, int) TO authenticated, service_role;


-- wpe_recalculate_all_scores: service_role only, called by the sync
-- function after every ESPN pull. Flips a league to 'completed' once
-- wpe_season_state shows the regular season is over for that season.
CREATE OR REPLACE FUNCTION wpe_recalculate_all_scores()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_league record;
  v_season_complete boolean;
BEGIN
  FOR v_league IN
    SELECT id, current_season FROM leagues
    WHERE game_type = 'cfb-weekly-pick-em' AND status IN ('active', 'pending')
  LOOP
    PERFORM wpe_recalculate_scores(v_league.id, v_league.current_season);

    SELECT (regular_season_complete_at IS NOT NULL) INTO v_season_complete
    FROM wpe_season_state WHERE season = v_league.current_season;

    IF COALESCE(v_season_complete, false) THEN
      UPDATE leagues SET status = 'completed' WHERE id = v_league.id AND status != 'completed';
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_recalculate_all_scores() TO service_role;


-- ------------------------------------------------------------
-- WEEKLY TIEBREAKERS — added post-launch per user request, styled on
-- Yahoo's two-tiebreaker pattern (Yahoo's own pick'em pools use exactly
-- this shape: guess the total of a highlighted game, plus guess the
-- total of the week's last game). Every league gets both, every week —
-- not a setup toggle. They exist purely to break SEASON-LONG standings
-- ties (closest cumulative guess wins); they carry no point value of
-- their own and never affect wpe_scores.
-- ------------------------------------------------------------

-- WPE TIEBREAKER GAMES — which game is Tiebreaker 1 / Tiebreaker 2 for
-- a given league+week. Tiebreaker 1 is randomly assigned ONCE (lazily,
-- the first time anyone asks — see wpe_get_tiebreaker_games below) and
-- then frozen, exactly like a pick's spread: if it re-rolled on every
-- read, everyone's guess would be against a moving target. Tiebreaker
-- 2 doesn't need persisting for correctness (it's a deterministic
-- "latest kickoff in the slate" query) but is stored alongside it for
-- a single source of truth and one join site.
CREATE TABLE IF NOT EXISTS wpe_tiebreaker_games (
  league_id     uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season        int  NOT NULL,
  week          int  NOT NULL,
  tb1_game_id   uuid REFERENCES wpe_games(id),
  tb2_game_id   uuid REFERENCES wpe_games(id),
  assigned_at   timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, week)
);

ALTER TABLE wpe_tiebreaker_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view tiebreaker games" ON wpe_tiebreaker_games;
CREATE POLICY "League members can view tiebreaker games" ON wpe_tiebreaker_games FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON wpe_tiebreaker_games TO authenticated;
-- No direct write policy — only wpe_get_tiebreaker_games() (SECURITY
-- DEFINER) ever inserts a row, on first request for that league+week.


-- WPE TIEBREAKER GUESSES — one row per league/season/week/user, holding
-- both slots. Visibility is plain league-membership (no lock-gating
-- like picks get): a total-score guess doesn't leak a "pick," so
-- there's no strategic reason to hide it pre-lock the way Bowl hid its
-- championship guess.
CREATE TABLE IF NOT EXISTS wpe_tiebreaker_guesses (
  league_id   uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season      int  NOT NULL,
  week        int  NOT NULL,
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tb1_guess   int,
  tb2_guess   int,
  updated_at  timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, week, user_id)
);

ALTER TABLE wpe_tiebreaker_guesses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view tiebreaker guesses" ON wpe_tiebreaker_guesses;
CREATE POLICY "League members can view tiebreaker guesses" ON wpe_tiebreaker_guesses FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON wpe_tiebreaker_guesses TO authenticated;
-- No direct write policy — writes go through wpe_submit_tiebreaker_guess().


-- wpe_get_tiebreaker_games: lazily assigns + freezes this league's two
-- tiebreaker games for a week the first time they're requested, off
-- that league's OWN filtered slate (wpe_get_slate) — a Group-of-5-only
-- league never gets handed a Power 4 game to guess on. Idempotent under
-- concurrent first-callers via ON CONFLICT DO NOTHING + read-back.
CREATE OR REPLACE FUNCTION wpe_get_tiebreaker_games(p_league_id uuid, p_season int, p_week int)
RETURNS wpe_tiebreaker_games
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row wpe_tiebreaker_games%ROWTYPE;
  v_tb1 uuid;
  v_tb2 uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT * INTO v_row FROM wpe_tiebreaker_games
  WHERE league_id = p_league_id AND season = p_season AND week = p_week;
  IF v_row.league_id IS NOT NULL THEN
    RETURN v_row;
  END IF;

  SELECT id INTO v_tb1 FROM wpe_get_slate(p_league_id, p_season, p_week) ORDER BY random() LIMIT 1;
  SELECT id INTO v_tb2 FROM wpe_get_slate(p_league_id, p_season, p_week) ORDER BY kickoff_at DESC NULLS LAST LIMIT 1;

  INSERT INTO wpe_tiebreaker_games (league_id, season, week, tb1_game_id, tb2_game_id)
  VALUES (p_league_id, p_season, p_week, v_tb1, v_tb2)
  ON CONFLICT (league_id, season, week) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.league_id IS NULL THEN
    -- Lost a race with a concurrent first-caller — read back their insert.
    SELECT * INTO v_row FROM wpe_tiebreaker_games
    WHERE league_id = p_league_id AND season = p_season AND week = p_week;
  END IF;

  RETURN v_row;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_get_tiebreaker_games(uuid, int, int) TO authenticated;


-- wpe_submit_tiebreaker_guess: p_slot 1 or 2. Locks independently per
-- slot at that slot's own game's kickoff-minus-5-minutes — same rule
-- as every pick. A guess doesn't depend on knowing who wins, so it's
-- freely editable any time before its own game locks.
CREATE OR REPLACE FUNCTION wpe_submit_tiebreaker_guess(
  p_league_id uuid, p_week int, p_slot int, p_guess int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season  int;
  v_tg      wpe_tiebreaker_games%ROWTYPE;
  v_game_id uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;
  IF p_slot NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Invalid tiebreaker slot';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  v_tg := wpe_get_tiebreaker_games(p_league_id, v_season, p_week);
  v_game_id := CASE p_slot WHEN 1 THEN v_tg.tb1_game_id ELSE v_tg.tb2_game_id END;

  IF v_game_id IS NULL OR wpe_is_game_locked(v_game_id) THEN
    RAISE EXCEPTION 'This tiebreaker has already locked';
  END IF;

  INSERT INTO wpe_tiebreaker_guesses (league_id, season, week, user_id, tb1_guess, tb2_guess, updated_at)
  VALUES (p_league_id, v_season, p_week, auth.uid(),
          CASE WHEN p_slot = 1 THEN p_guess END,
          CASE WHEN p_slot = 2 THEN p_guess END,
          now())
  ON CONFLICT (league_id, season, week, user_id) DO UPDATE SET
    tb1_guess  = CASE WHEN p_slot = 1 THEN p_guess ELSE wpe_tiebreaker_guesses.tb1_guess END,
    tb2_guess  = CASE WHEN p_slot = 2 THEN p_guess ELSE wpe_tiebreaker_guesses.tb2_guess END,
    updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_submit_tiebreaker_guess(uuid, int, int, int) TO authenticated;


-- wpe_get_standings: defaults to the league's current season; a past
-- season can be passed explicitly for the history page. `tiebreak_error`
-- is the sum of |guess - actual| across every RESOLVED tiebreaker guess
-- (both slots, every week) this season — NULL if the member never
-- submitted one. Used ONLY to break a tie in total_points; a lower
-- error sorts first (closest overall guesser), NULLs (no participation)
-- sort last. DROP + recreate below since changing a RETURNS TABLE
-- shape isn't something CREATE OR REPLACE can do.
DROP FUNCTION IF EXISTS wpe_get_standings(uuid, int);
CREATE OR REPLACE FUNCTION wpe_get_standings(p_league_id uuid, p_season int DEFAULT NULL)
RETURNS TABLE (
  user_id uuid,
  team_name text,
  total_points int,
  wins int,
  losses int,
  tiebreak_error numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_season int;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  v_season := p_season;
  IF v_season IS NULL THEN
    SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  END IF;

  RETURN QUERY
  SELECT
    m.user_id, m.team_name,
    COALESCE(s.total_points, 0), COALESCE(s.wins, 0), COALESCE(s.losses, 0),
    tb.total_error
  FROM league_members m
  LEFT JOIN wpe_scores s ON s.league_id = p_league_id AND s.season = v_season AND s.user_id = m.user_id
  LEFT JOIN LATERAL (
    SELECT SUM(err)::numeric AS total_error
    FROM (
      SELECT ABS(g.tb1_guess - (gm1.home_score + gm1.away_score)) AS err
      FROM wpe_tiebreaker_guesses g
      JOIN wpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
      JOIN wpe_games gm1 ON gm1.id = tg.tb1_game_id AND gm1.status = 'final'
      WHERE g.league_id = p_league_id AND g.season = v_season AND g.user_id = m.user_id AND g.tb1_guess IS NOT NULL
      UNION ALL
      SELECT ABS(g.tb2_guess - (gm2.home_score + gm2.away_score))
      FROM wpe_tiebreaker_guesses g
      JOIN wpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
      JOIN wpe_games gm2 ON gm2.id = tg.tb2_game_id AND gm2.status = 'final'
      WHERE g.league_id = p_league_id AND g.season = v_season AND g.user_id = m.user_id AND g.tb2_guess IS NOT NULL
    ) errs
  ) tb ON true
  WHERE m.league_id = p_league_id
  ORDER BY
    COALESCE(s.total_points, 0) DESC,
    CASE WHEN tb.total_error IS NULL THEN 1 ELSE 0 END,
    tb.total_error ASC,
    COALESCE(s.wins, 0) DESC,
    m.team_name ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_get_standings(uuid, int) TO authenticated;


-- wpe_start_new_season: commissioner-only. Carries forward
-- pick_mode/scoring_mode/scope_mode/conferences/include_top25 as next
-- year's defaults. Reuses the same leagues.id / invite code, matching
-- the root dashboard's existing "Reactivate" pattern for other
-- season-aware modules.
CREATE OR REPLACE FUNCTION wpe_start_new_season(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_is_commissioner boolean;
  v_prev_season int;
  v_new_season int;
  v_pick_mode text;
  v_scoring_mode text;
  v_scope_mode text;
  v_conferences text[];
  v_include_top25 boolean;
  v_include_week_zero boolean;
BEGIN
  SELECT (commissioner_id = auth.uid()), current_season INTO v_is_commissioner, v_prev_season
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can start a new season';
  END IF;

  v_new_season := v_prev_season + 1;

  SELECT pick_mode, scoring_mode, scope_mode, conferences, include_top25, include_week_zero
    INTO v_pick_mode, v_scoring_mode, v_scope_mode, v_conferences, v_include_top25, v_include_week_zero
  FROM wpe_leagues WHERE league_id = p_league_id AND season = v_prev_season;

  INSERT INTO wpe_leagues (league_id, season, pick_mode, scoring_mode, scope_mode, conferences, include_top25, include_week_zero)
  VALUES (p_league_id, v_new_season, COALESCE(v_pick_mode, 'straight_up'), COALESCE(v_scoring_mode, 'flat'),
          COALESCE(v_scope_mode, 'sports_lobby_choice'), COALESCE(v_conferences, '{}'), COALESCE(v_include_top25, true),
          COALESCE(v_include_week_zero, false))
  ON CONFLICT (league_id, season) DO NOTHING;

  UPDATE leagues SET current_season = v_new_season, status = 'active' WHERE id = p_league_id;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_start_new_season(uuid) TO authenticated;


-- wpe_apply_matchup_change: service_role only, called by the sync
-- function ONLY when an already-known game's teams actually change —
-- never on a routine score/status refresh. Unlike Bowl, no mass email
-- is sent here; regular-season matchup changes are rare and lower-
-- stakes than a bowl opt-out, so a silent version-bump + pick-clear is
-- sufficient for v1.
CREATE OR REPLACE FUNCTION wpe_apply_matchup_change(
  p_game_id uuid,
  p_home_team text,
  p_away_team text,
  p_home_conference text,
  p_away_conference text,
  p_home_rank int,
  p_away_rank int,
  p_spread numeric,
  p_kickoff_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE wpe_games SET
    home_team = p_home_team, away_team = p_away_team,
    home_conference = p_home_conference, away_conference = p_away_conference,
    home_rank = p_home_rank, away_rank = p_away_rank,
    spread = p_spread, kickoff_at = p_kickoff_at,
    matchup_version = matchup_version + 1, updated_at = now()
  WHERE id = p_game_id;

  DELETE FROM wpe_picks WHERE game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION wpe_apply_matchup_change(uuid, text, text, text, text, int, int, numeric, timestamptz) TO service_role;


-- ------------------------------------------------------------
-- 7. REALTIME
-- ------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE wpe_games;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE wpe_picks;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE wpe_scores;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE wpe_tiebreaker_guesses;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;


-- ------------------------------------------------------------
-- 8. LIVE SYNC SCHEDULING (pg_cron + pg_net)
-- Launching directly on this pattern rather than GitHub Actions —
-- GH Actions' `schedule:` trigger was found unreliable in production
-- (fcp-sync-scores went silent 5+ hours during a live event on
-- 2026-08-27) and was replaced there with pg_cron+pg_net (see
-- golf/fedex-playoffs/schema.sql SECTION 13). Bowl Pick'em's own sync
-- (bpe-sync-games) hasn't been migrated off GitHub Actions yet, but
-- new sync functions should launch on the better pattern from day one.
--
-- Reuses the SAME 'fcp_service_role_key' Vault secret golf/fedex-
-- playoffs/schema.sql already created (Database > Vault) — it's this
-- Supabase project's one service role key, not FedEx-specific, so
-- there's no reason to duplicate it under a new name.
--
-- Update the date window each season.
--
-- NOTE: do not run this section until wpe-sync-games has been
-- deployed AND verified live via ?raw=true / ?dry_run=true — see the
-- header comment in supabase/functions/wpe-sync-games/index.ts.
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net  WITH SCHEMA extensions;

SELECT cron.schedule(
  'wpe-sync-games-cron',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://rjtlolzdwmrhctdatekj.supabase.co/functions/v1/wpe-sync-games',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'fcp_service_role_key')
    ),
    body := '{}'::jsonb
  )
  WHERE current_date BETWEEN DATE '2026-08-25' AND DATE '2026-12-13';
  $$
);
