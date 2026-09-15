-- ============================================================
-- NFL Weekly Pick 'Em — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE / ON CONFLICT)
--
-- Assumes the shared `leagues`, `league_members`, `profiles` tables
-- and the `is_league_member(uuid)` helper already exist (see
-- soccer/world-cup-bracket-challenge/schema.sql), plus the shared
-- `join_league_by_invite_code()` / `set_team_name()` RPCs.
--
-- Prefix: nwpe_ (NFL Weekly Pick 'Em). game_type = 'nfl-weekly-pick-em'.
-- Modeled on cfb/weekly-pick-em/schema.sql (prefix wpe_), with the
-- CFB-only scale/quirk handling dropped (no conference/scope
-- filtering, no AP rank, no FBS-only param, no Week 0/1 merge — NFL's
-- ~13-16 games/week doesn't need narrowing the way CFB's ~130-team
-- slate does) and REGULAR SEASON + POSTSEASON both in scope (unlike
-- CFB Weekly, which is regular-season only and hands postseason off to
-- a separate Bowl Pick'em module — NFL Weekly's playoff continuation
-- is a per-league opt-in, see wnpe_leagues.continue_to_playoffs below).
--
-- WEEK NUMBERING: `week` stores ESPN's own regular-season week (1-18)
-- unchanged, but POSTSEASON weeks are stored as 18 + ESPN's own
-- postseason week number (1=Wild Card, 2=Divisional,
-- 3=Conference Championship, 4=Pro Bowl bye/no real games,
-- 5=Super Bowl) — i.e. postseason weeks are stored as 19-23. This
-- offset is applied by the sync function, NOT by ESPN itself, so that
-- postseason weeks sort continuously after the regular season instead
-- of colliding with weeks 1-5 of the regular season (both would
-- otherwise start counting from 1). VERIFY the actual ESPN postseason
-- week values via ?raw=true against a deployed nwpe-sync-games before
-- the postseason actually starts — this offset and the round-to-points
-- mapping in nwpe_playoff_round_points() below both assume the above
-- numbering and may need adjusting once real postseason data exists.
-- ============================================================


-- ------------------------------------------------------------
-- 1. NWPE GAMES
-- One shared global table for the whole season (regular + postseason).
-- Unlike wpe_games, `spread`/`favorite_team` here are NEVER frozen on
-- this row — they always hold the latest value synced from ESPN. Per-
-- league freeze timing is commissioner-configurable (spread_lock_mode
-- on nwpe_leagues), so the same shared game can need a different
-- "locked" spread for different leagues — see NWPE GAME SPREAD LOCKS
-- (section 2) for where that's actually captured.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_games (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  season                int  NOT NULL DEFAULT extract(year from now())::int,
  season_type           int  NOT NULL,               -- ESPN's own value: 2 = regular season, 3 = postseason
  week                  int  NOT NULL,                -- see WEEK NUMBERING note above — postseason is offset +18
  espn_event_id         text NOT NULL,
  home_team             text NOT NULL,
  away_team             text NOT NULL,
  home_team_abbr        text,
  away_team_abbr        text,
  home_team_logo        text,
  away_team_logo        text,
  favorite_team         text,                        -- latest ESPN value — one of home_team/away_team, or NULL if no line yet
  spread                numeric,                     -- latest ESPN value — NEVER frozen on this row (see section 2)
  kickoff_at            timestamptz,
  status                text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'live', 'final')),
  status_detail         text,                        -- ESPN's own live label, refreshed every sync
  home_score            int,
  away_score            int,
  winner_team           text,                        -- straight-up winner, set once status = 'final'
  matchup_version       int  NOT NULL DEFAULT 1,      -- bumped by nwpe_apply_matchup_change() on a teams change
  synced_at             timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season, espn_event_id)
);

CREATE INDEX IF NOT EXISTS nwpe_games_season_week_idx ON nwpe_games(season, week);

ALTER TABLE nwpe_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Weekly games readable by all" ON nwpe_games;
CREATE POLICY "Weekly games readable by all" ON nwpe_games FOR SELECT USING (true);

GRANT SELECT ON nwpe_games TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON nwpe_games TO service_role;

-- True once a game is finished, or its kickoff-minus-5-minutes lock has
-- passed. Unaffected by spread_lock_mode — that setting only controls
-- when the SPREAD NUMBER freezes, never the per-game pick deadline.
CREATE OR REPLACE FUNCTION nwpe_is_game_locked(p_game_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT status = 'final' OR (kickoff_at IS NOT NULL AND now() >= kickoff_at - interval '5 minutes')
     FROM nwpe_games WHERE id = p_game_id),
    false
  );
$$;
GRANT EXECUTE ON FUNCTION nwpe_is_game_locked(uuid) TO anon, authenticated;


-- ------------------------------------------------------------
-- 2. NWPE GAME SPREAD LOCKS
-- Because different leagues can choose different spread_lock_mode
-- values for the SAME shared game, the "frozen" spread can't live on
-- nwpe_games itself (that would force every league to share one
-- freeze policy, like CFB does today). Instead each (game, lock_mode)
-- pair gets its own snapshot row — at most 2 rows per game, since
-- there are only 2 possible modes, NOT one row per league.
--
-- 'week_reveal' rows: written once, the first sync where the game's
-- week becomes <= the season's current week — is_final = true
-- immediately (one-shot, exactly like CFB's on-row freeze today).
--
-- 'day_before_kickoff' rows: written on first sync after the week is
-- revealed, then re-upserted (refreshed, not re-inserted) AT MOST ONCE
-- PER 24 HOURS while more than 24h remains before that week's earliest
-- kickoff — daily checkpoints, not a continuously-live number. The
-- sync run that first observes less than 24h remaining does one final
-- overwrite and sets is_final = true; every sync after that leaves the
-- row untouched forever.
--
-- Grading (nwpe_recalculate_scores) always reads whichever row is
-- final at scoring time — a pick is never tied to whatever value a
-- user happened to see when they clicked; if the snapshot changes
-- under them before it finally locks, their pick is simply graded
-- against the eventual locked value, same as everyone else in that
-- league. No per-pick spread capture exists anywhere.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_game_spread_locks (
  game_id              uuid NOT NULL REFERENCES nwpe_games(id) ON DELETE CASCADE,
  lock_mode            text NOT NULL CHECK (lock_mode IN ('week_reveal', 'day_before_kickoff')),
  locked_spread         numeric,
  locked_favorite_team  text,
  is_final             boolean NOT NULL DEFAULT false,   -- true once this row will never be touched again
  snapshotted_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (game_id, lock_mode)
);

ALTER TABLE nwpe_game_spread_locks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Spread locks readable by all" ON nwpe_game_spread_locks;
CREATE POLICY "Spread locks readable by all" ON nwpe_game_spread_locks FOR SELECT USING (true);

GRANT SELECT ON nwpe_game_spread_locks TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON nwpe_game_spread_locks TO service_role;

-- Pure margin-vs-spread math, no sport-specific assumptions — mirrors
-- wpe-sync-games' computeAtsWinner() TS helper exactly, but lives in
-- SQL here since grading now depends on which league's locked snapshot
-- is being read (nwpe_game_spread_locks), not a single frozen column.
-- Returns the covering team, or NULL if no line / a push.
CREATE OR REPLACE FUNCTION nwpe_ats_cover(
  p_home_team text, p_away_team text,
  p_home_score int, p_away_score int,
  p_spread numeric, p_favorite_team text
)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_spread IS NULL OR p_favorite_team IS NULL THEN NULL
    WHEN p_favorite_team = p_home_team AND (p_home_score - p_away_score) > p_spread THEN p_home_team
    WHEN p_favorite_team = p_home_team AND (p_home_score - p_away_score) < p_spread THEN p_away_team
    WHEN p_favorite_team = p_away_team AND (p_away_score - p_home_score) > p_spread THEN p_away_team
    WHEN p_favorite_team = p_away_team AND (p_away_score - p_home_score) < p_spread THEN p_home_team
    ELSE NULL -- push
  END;
$$;


-- ------------------------------------------------------------
-- 3. NWPE LEAGUES
-- One row per league PER SEASON — reused year over year (same
-- leagues.id, same invite code) via nwpe_start_new_season(). No
-- scope/conference concept at all (see file header) — every league
-- picks from the full weekly NFL slate.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_leagues (
  league_id             uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season                int  NOT NULL DEFAULT extract(year from now())::int,
  pick_mode             text NOT NULL DEFAULT 'straight_up' CHECK (pick_mode IN ('straight_up', 'spread')),
  scoring_mode          text NOT NULL DEFAULT 'flat' CHECK (scoring_mode IN ('flat', 'confidence')),
  -- Only meaningful when pick_mode = 'spread' — setup/settings UI only
  -- shows this choice in that case. 'week_reveal' matches CFB's only
  -- behavior today; 'day_before_kickoff' is the new Yahoo-style option.
  spread_lock_mode      text NOT NULL DEFAULT 'week_reveal' CHECK (spread_lock_mode IN ('week_reveal', 'day_before_kickoff')),
  -- Setup-time opt-in, default OFF. When true, the league's slate
  -- (nwpe_get_slate) includes postseason weeks and nwpe_scores tracks
  -- playoff_points separately from regular_season_points.
  continue_to_playoffs  boolean NOT NULL DEFAULT false,
  tiebreakers_enabled   boolean NOT NULL DEFAULT true,
  created_at            timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season)
);

ALTER TABLE nwpe_leagues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view nwpe league" ON nwpe_leagues;
CREATE POLICY "League members can view nwpe league" ON nwpe_leagues FOR SELECT
  USING (is_league_member(league_id));

DROP POLICY IF EXISTS "Commissioner can insert nwpe league" ON nwpe_leagues;
CREATE POLICY "Commissioner can insert nwpe league" ON nwpe_leagues FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM leagues WHERE id = nwpe_leagues.league_id AND commissioner_id = auth.uid()
  ));
-- Deliberately no direct UPDATE policy — every post-creation settings
-- change goes through nwpe_update_league_settings(), which can reject
-- the pick_mode/scoring_mode change once picks already exist.

GRANT SELECT, INSERT ON nwpe_leagues TO authenticated;


-- ------------------------------------------------------------
-- 4. NWPE PICKS
-- Lock-gated-visibility table: your own picks are always visible to
-- you; other members' picks on a given game only become visible once
-- THAT SPECIFIC GAME locks. `week` is denormalized from the game row.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_picks (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id          uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season             int  NOT NULL,
  week               int  NOT NULL,
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id            uuid NOT NULL REFERENCES nwpe_games(id) ON DELETE CASCADE,
  picked_team        text NOT NULL,   -- must equal nwpe_games.home_team or .away_team — checked in nwpe_submit_pick
  confidence_points  int,             -- NULL in flat mode and for ALL postseason picks; dynamic 1..N in confidence mode for regular-season weeks
  submitted_at       timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now(),
  UNIQUE (league_id, season, user_id, game_id)
);

CREATE INDEX IF NOT EXISTS nwpe_picks_league_season_week_idx ON nwpe_picks(league_id, season, week);

ALTER TABLE nwpe_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own picks always visible; others after game locks" ON nwpe_picks;
CREATE POLICY "Own picks always visible; others after game locks" ON nwpe_picks FOR SELECT
  USING (
    user_id = auth.uid()
    OR (is_league_member(nwpe_picks.league_id) AND nwpe_is_game_locked(nwpe_picks.game_id))
  );
-- No direct INSERT/UPDATE/DELETE policy — all writes go through
-- nwpe_submit_pick() / nwpe_clear_pick().

GRANT SELECT ON nwpe_picks TO authenticated;


-- ------------------------------------------------------------
-- 5. NWPE SCORES
-- Running total, split into regular-season vs. playoff points per the
-- user's request (three columns on the dashboard: Reg. Pts / Playoff
-- Pts / Total Pts). total_points is redundant with the sum of the
-- other two but stored directly so ORDER BY / indexing stays simple.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_scores (
  league_id              uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season                 int  NOT NULL,
  user_id                uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  regular_season_points  int  NOT NULL DEFAULT 0,
  playoff_points         int  NOT NULL DEFAULT 0,
  total_points           int  NOT NULL DEFAULT 0,   -- = regular_season_points + playoff_points
  wins                   int  NOT NULL DEFAULT 0,
  losses                 int  NOT NULL DEFAULT 0,
  last_updated           timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, user_id)
);

ALTER TABLE nwpe_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view nwpe scores" ON nwpe_scores;
CREATE POLICY "League members can view nwpe scores" ON nwpe_scores FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON nwpe_scores TO authenticated;
GRANT SELECT, INSERT, UPDATE ON nwpe_scores TO service_role;


-- ------------------------------------------------------------
-- 6. NWPE SEASON STATE
-- Tracks ESPN's own reported week/season-type per season. `current_week`
-- uses the same postseason +18 offset as nwpe_games.week (see file
-- header) so "is this week revealed yet" comparisons work uniformly
-- across season types.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_season_state (
  season                       int PRIMARY KEY,
  season_type                  int,             -- ESPN's own value: 2 = regular season, 3 = postseason
  current_week                 int,             -- offset scheme — see file header
  regular_season_complete_at   timestamptz,     -- set once season_type is first observed as 3
  playoffs_complete_at         timestamptz,     -- set once the highest known postseason week's game(s) are final
  updated_at                   timestamptz DEFAULT now()
);

ALTER TABLE nwpe_season_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Season state readable by all" ON nwpe_season_state;
CREATE POLICY "Season state readable by all" ON nwpe_season_state FOR SELECT USING (true);

GRANT SELECT ON nwpe_season_state TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON nwpe_season_state TO service_role;


-- ------------------------------------------------------------
-- 7. RPCs
-- ------------------------------------------------------------

-- nwpe_playoff_round_points: fixed points per postseason round,
-- regardless of a league's scoring_mode — confidence ranking is
-- degenerate with 1-6 playoff games in a week (Super Bowl week = 1
-- game), so playoff weeks always score via this flat weight instead.
-- p_week is the STORED (offset +18) week number. Round order confirmed
-- against ESPN's own scoreboard UI (Wild Card, Divisional, Conference
-- Championship, Pro Bowl, Super Bowl) — matches the mapping below.
CREATE OR REPLACE FUNCTION nwpe_playoff_round_points(p_week int)
RETURNS int
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE p_week - 18
    WHEN 1 THEN 1  -- Wild Card
    WHEN 2 THEN 2  -- Divisional
    WHEN 3 THEN 3  -- Conference Championship
    WHEN 5 THEN 5  -- Super Bowl (round 4 is the Pro Bowl bye week, no real games)
    ELSE 0
  END;
$$;

-- nwpe_get_slate: the single source of truth for "which games does
-- this league pick from this week." No scope filtering (unlike
-- wpe_get_slate) — just season/week, plus excluding postseason
-- entirely when the league hasn't opted into continue_to_playoffs.
CREATE OR REPLACE FUNCTION nwpe_get_slate(p_league_id uuid, p_season int, p_week int DEFAULT NULL)
RETURNS SETOF nwpe_games
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_league nwpe_leagues%ROWTYPE;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT * INTO v_league FROM nwpe_leagues WHERE league_id = p_league_id AND season = p_season;

  RETURN QUERY
  SELECT g.*
  FROM nwpe_games g
  WHERE g.season = p_season
    AND (p_week IS NULL OR g.week = p_week)
    AND (g.season_type = 2 OR (g.season_type = 3 AND COALESCE(v_league.continue_to_playoffs, false)))
  ORDER BY g.week, g.kickoff_at NULLS LAST, g.away_team, g.home_team;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_get_slate(uuid, int, int) TO authenticated;


-- nwpe_submit_pick: same validation shape as wpe_submit_pick. Postseason
-- picks (season_type = 3) always force confidence_points to NULL
-- regardless of scoring_mode — playoff weeks never use confidence
-- ranking, see nwpe_playoff_round_points above.
CREATE OR REPLACE FUNCTION nwpe_submit_pick(
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
  v_game           nwpe_games%ROWTYPE;
  v_slate_size     int;
  v_prev_conf      int;
  v_swap_game_id   uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT * INTO v_game FROM nwpe_games WHERE id = p_game_id AND season = v_season;
  IF v_game.id IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;
  IF nwpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  IF p_picked_team NOT IN (v_game.home_team, v_game.away_team) THEN
    RAISE EXCEPTION 'Invalid team for this game';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM nwpe_get_slate(p_league_id, v_season, v_game.week) s WHERE s.id = p_game_id) THEN
    RAISE EXCEPTION 'This game is not part of your league''s weekly slate';
  END IF;

  SELECT scoring_mode INTO v_scoring_mode FROM nwpe_leagues
    WHERE league_id = p_league_id AND season = v_season;
  IF v_scoring_mode IS NULL THEN
    RAISE EXCEPTION 'League is not configured for the current season';
  END IF;

  IF v_game.season_type = 3 THEN
    p_confidence_points := NULL; -- playoff weeks always score via nwpe_playoff_round_points, never confidence
  ELSIF v_scoring_mode = 'confidence' THEN
    SELECT count(*) INTO v_slate_size FROM nwpe_get_slate(p_league_id, v_season, v_game.week);

    IF p_confidence_points IS NULL OR p_confidence_points < 1 OR p_confidence_points > v_slate_size THEN
      RAISE EXCEPTION 'Confidence must be between 1 and % for Week %', v_slate_size, v_game.week;
    END IF;

    SELECT confidence_points INTO v_prev_conf
    FROM nwpe_picks
    WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = p_game_id;

    SELECT p2.game_id INTO v_swap_game_id
    FROM nwpe_picks p2
    WHERE p2.league_id = p_league_id AND p2.season = v_season AND p2.user_id = auth.uid()
      AND p2.week = v_game.week AND p2.game_id != p_game_id AND p2.confidence_points = p_confidence_points
    LIMIT 1;

    IF v_swap_game_id IS NOT NULL THEN
      UPDATE nwpe_picks SET confidence_points = v_prev_conf, updated_at = now()
      WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = v_swap_game_id;
    END IF;
  ELSE
    p_confidence_points := NULL; -- flat mode never stores a confidence value
  END IF;

  INSERT INTO nwpe_picks (league_id, season, week, user_id, game_id, picked_team, confidence_points, updated_at)
  VALUES (p_league_id, v_season, v_game.week, auth.uid(), p_game_id, p_picked_team, p_confidence_points, now())
  ON CONFLICT (league_id, season, user_id, game_id)
  DO UPDATE SET picked_team = EXCLUDED.picked_team, confidence_points = EXCLUDED.confidence_points, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_submit_pick(uuid, uuid, text, int) TO authenticated;


-- nwpe_clear_pick: undo a pick, only while its game is still open.
CREATE OR REPLACE FUNCTION nwpe_clear_pick(p_league_id uuid, p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF nwpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  DELETE FROM nwpe_picks
  WHERE league_id = p_league_id AND user_id = auth.uid() AND game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_clear_pick(uuid, uuid) TO authenticated;


-- nwpe_update_league_settings: only pick_mode/scoring_mode are
-- lock-sensitive (they change how already-scored picks are
-- interpreted) — same rule as wpe_update_league_settings.
-- spread_lock_mode/continue_to_playoffs/tiebreakers_enabled stay
-- editable any time, since they only affect future weeks.
DROP FUNCTION IF EXISTS nwpe_update_league_settings(uuid, text, text, text, boolean, boolean);
CREATE OR REPLACE FUNCTION nwpe_update_league_settings(
  p_league_id uuid,
  p_pick_mode text,
  p_scoring_mode text,
  p_spread_lock_mode text,
  p_continue_to_playoffs boolean,
  p_tiebreakers_enabled boolean DEFAULT true
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

  SELECT pick_mode, scoring_mode INTO v_current_pick_mode, v_current_scoring_mode
  FROM nwpe_leagues WHERE league_id = p_league_id AND season = v_season;

  IF p_pick_mode IS DISTINCT FROM v_current_pick_mode OR p_scoring_mode IS DISTINCT FROM v_current_scoring_mode THEN
    SELECT count(*) INTO v_pick_count FROM nwpe_picks WHERE league_id = p_league_id AND season = v_season;
    IF v_pick_count > 0 THEN
      RAISE EXCEPTION 'Cannot change pick/scoring mode after picks have been made this season';
    END IF;
  END IF;

  UPDATE nwpe_leagues SET
    pick_mode = p_pick_mode, scoring_mode = p_scoring_mode,
    spread_lock_mode = p_spread_lock_mode, continue_to_playoffs = p_continue_to_playoffs,
    tiebreakers_enabled = p_tiebreakers_enabled
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_update_league_settings(uuid, text, text, text, boolean, boolean) TO authenticated;


-- nwpe_recalculate_scores: recomputes one league+season's nwpe_scores
-- from scratch off nwpe_picks + nwpe_games, split into
-- regular_season_points vs. playoff_points by g.season_type.
--
-- Grading reads the league's own locked spread snapshot
-- (nwpe_game_spread_locks, filtered to lock_mode = this league's
-- spread_lock_mode) rather than a column on nwpe_games — see section 2.
-- Same two-case null-spread split as CFB:
--   - locked_spread IS NULL: the game never had a line by the time it
--     locked for this league — plays as a plain straight-up pick'em,
--     graded against winner_team.
--   - locked_spread IS NOT NULL AND nwpe_ats_cover(...) IS NULL: an
--     actual push — scores 0, doesn't count as a win or a loss.
-- Postseason picks (season_type = 3) score via
-- nwpe_playoff_round_points(week) instead of flat-1/confidence, and
-- are excluded entirely (WHERE-filtered out) unless the league has
-- continue_to_playoffs = true.
CREATE OR REPLACE FUNCTION nwpe_recalculate_scores(p_league_id uuid, p_season int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pick_mode text;
  v_scoring_mode text;
  v_spread_lock_mode text;
  v_continue_to_playoffs boolean;
BEGIN
  SELECT pick_mode, scoring_mode, spread_lock_mode, continue_to_playoffs
    INTO v_pick_mode, v_scoring_mode, v_spread_lock_mode, v_continue_to_playoffs
  FROM nwpe_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_pick_mode IS NULL THEN
    RETURN; -- no nwpe_leagues row for this league/season yet — nothing to score
  END IF;

  INSERT INTO nwpe_scores (league_id, season, user_id, regular_season_points, playoff_points, total_points, wins, losses, last_updated)
  SELECT
    p_league_id, p_season, m.user_id,
    COALESCE(SUM(calc.pts) FILTER (WHERE g.season_type = 2), 0),
    COALESCE(SUM(calc.pts) FILTER (WHERE g.season_type = 3), 0),
    COALESCE(SUM(calc.pts), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_win), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_loss), 0),
    now()
  FROM league_members m
  LEFT JOIN nwpe_picks p ON p.league_id = p_league_id AND p.season = p_season AND p.user_id = m.user_id
  LEFT JOIN nwpe_games g ON g.id = p.game_id AND g.status = 'final'
    AND (g.season_type = 2 OR COALESCE(v_continue_to_playoffs, false))
  LEFT JOIN nwpe_game_spread_locks lk ON lk.game_id = g.id AND lk.lock_mode = v_spread_lock_mode
  LEFT JOIN LATERAL (
    SELECT nwpe_ats_cover(g.home_team, g.away_team, g.home_score, g.away_score, lk.locked_spread, lk.locked_favorite_team) AS ats_winner
  ) ats ON true
  LEFT JOIN LATERAL (
    SELECT
      (g.id IS NOT NULL AND NOT (v_pick_mode = 'spread' AND lk.locked_spread IS NOT NULL AND ats.ats_winner IS NULL)) AS is_gradeable,
      (g.id IS NOT NULL AND NOT (v_pick_mode = 'spread' AND lk.locked_spread IS NOT NULL AND ats.ats_winner IS NULL)
        AND (
          v_pick_mode = 'straight_up' AND p.picked_team = g.winner_team
          OR v_pick_mode = 'spread' AND lk.locked_spread IS NULL AND p.picked_team = g.winner_team
          OR v_pick_mode = 'spread' AND lk.locked_spread IS NOT NULL AND p.picked_team = ats.ats_winner
        )
      ) AS is_correct
  ) chk ON true
  LEFT JOIN LATERAL (
    SELECT
      CASE WHEN NOT chk.is_correct THEN 0
        WHEN g.season_type = 3 THEN nwpe_playoff_round_points(g.week)
        WHEN v_scoring_mode = 'confidence' THEN COALESCE(p.confidence_points, 0)
        ELSE 1
      END AS pts,
      chk.is_correct AS is_win,
      (chk.is_gradeable AND NOT chk.is_correct) AS is_loss
  ) calc ON true
  WHERE m.league_id = p_league_id
  GROUP BY m.user_id
  ON CONFLICT (league_id, season, user_id) DO UPDATE SET
    regular_season_points = EXCLUDED.regular_season_points,
    playoff_points = EXCLUDED.playoff_points,
    total_points = EXCLUDED.total_points,
    wins = EXCLUDED.wins, losses = EXCLUDED.losses, last_updated = now();
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_recalculate_scores(uuid, int) TO authenticated, service_role;


-- nwpe_recalculate_all_scores: service_role only, called by the sync
-- function after every ESPN pull. Completion check branches on
-- continue_to_playoffs — regular-season-only leagues complete right
-- after the regular season (like CFB does today); leagues that opted
-- into playoffs wait for playoffs_complete_at instead.
CREATE OR REPLACE FUNCTION nwpe_recalculate_all_scores()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_league record;
  v_state record;
  v_complete boolean;
BEGIN
  FOR v_league IN
    SELECT id, current_season FROM leagues
    WHERE game_type = 'nfl-weekly-pick-em' AND status IN ('active', 'pending')
  LOOP
    PERFORM nwpe_recalculate_scores(v_league.id, v_league.current_season);

    SELECT regular_season_complete_at, playoffs_complete_at INTO v_state
    FROM nwpe_season_state WHERE season = v_league.current_season;

    SELECT COALESCE(
      CASE WHEN nl.continue_to_playoffs
        THEN v_state.playoffs_complete_at IS NOT NULL
        ELSE v_state.regular_season_complete_at IS NOT NULL
      END, false)
    INTO v_complete
    FROM nwpe_leagues nl WHERE nl.league_id = v_league.id AND nl.season = v_league.current_season;

    IF COALESCE(v_complete, false) THEN
      UPDATE leagues SET status = 'completed' WHERE id = v_league.id AND status != 'completed';
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_recalculate_all_scores() TO service_role;


-- nwpe_apply_matchup_change: service_role only, called by the sync
-- function ONLY when an already-known game's teams actually change.
-- Clears both picks AND any spread-lock snapshots for that game (a
-- locked spread from the old matchup is meaningless once the teams
-- change) so they get re-captured fresh.
CREATE OR REPLACE FUNCTION nwpe_apply_matchup_change(
  p_game_id uuid,
  p_home_team text,
  p_away_team text,
  p_spread numeric,
  p_favorite_team text,
  p_kickoff_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE nwpe_games SET
    home_team = p_home_team, away_team = p_away_team,
    spread = p_spread, favorite_team = p_favorite_team, kickoff_at = p_kickoff_at,
    matchup_version = matchup_version + 1, updated_at = now()
  WHERE id = p_game_id;

  DELETE FROM nwpe_picks WHERE game_id = p_game_id;
  DELETE FROM nwpe_game_spread_locks WHERE game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_apply_matchup_change(uuid, text, text, numeric, text, timestamptz) TO service_role;


-- ------------------------------------------------------------
-- WEEKLY TIEBREAKERS — same mechanic as CFB Weekly Pick'em (see that
-- file's own header comment for the full design rationale). One
-- season-long metric that continues accumulating through playoff
-- weeks too when continue_to_playoffs is on — not reset at playoffs.
-- ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS nwpe_tiebreaker_games (
  league_id     uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season        int  NOT NULL,
  week          int  NOT NULL,
  tb1_game_id   uuid REFERENCES nwpe_games(id),
  tb2_game_id   uuid REFERENCES nwpe_games(id),
  assigned_at   timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, week)
);

ALTER TABLE nwpe_tiebreaker_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view tiebreaker games" ON nwpe_tiebreaker_games;
CREATE POLICY "League members can view tiebreaker games" ON nwpe_tiebreaker_games FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON nwpe_tiebreaker_games TO authenticated;


CREATE TABLE IF NOT EXISTS nwpe_tiebreaker_guesses (
  league_id   uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season      int  NOT NULL,
  week        int  NOT NULL,
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tb1_guess   int,
  tb2_guess   int,
  updated_at  timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, week, user_id)
);

ALTER TABLE nwpe_tiebreaker_guesses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view tiebreaker guesses" ON nwpe_tiebreaker_guesses;
CREATE POLICY "League members can view tiebreaker guesses" ON nwpe_tiebreaker_guesses FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON nwpe_tiebreaker_guesses TO authenticated;


CREATE OR REPLACE FUNCTION nwpe_get_tiebreaker_games(p_league_id uuid, p_season int, p_week int)
RETURNS nwpe_tiebreaker_games
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row nwpe_tiebreaker_games%ROWTYPE;
  v_tb1 uuid;
  v_tb2 uuid;
  v_enabled boolean;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT tiebreakers_enabled INTO v_enabled FROM nwpe_leagues WHERE league_id = p_league_id AND season = p_season;
  IF NOT COALESCE(v_enabled, true) THEN
    RAISE EXCEPTION 'Tiebreakers are disabled for this league';
  END IF;

  SELECT * INTO v_row FROM nwpe_tiebreaker_games
  WHERE league_id = p_league_id AND season = p_season AND week = p_week;
  IF v_row.league_id IS NOT NULL THEN
    RETURN v_row;
  END IF;

  SELECT id INTO v_tb1 FROM nwpe_get_slate(p_league_id, p_season, p_week) ORDER BY random() LIMIT 1;
  SELECT id INTO v_tb2 FROM nwpe_get_slate(p_league_id, p_season, p_week) ORDER BY kickoff_at DESC NULLS LAST LIMIT 1;

  INSERT INTO nwpe_tiebreaker_games (league_id, season, week, tb1_game_id, tb2_game_id)
  VALUES (p_league_id, p_season, p_week, v_tb1, v_tb2)
  ON CONFLICT (league_id, season, week) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.league_id IS NULL THEN
    SELECT * INTO v_row FROM nwpe_tiebreaker_games
    WHERE league_id = p_league_id AND season = p_season AND week = p_week;
  END IF;

  RETURN v_row;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_get_tiebreaker_games(uuid, int, int) TO authenticated;


CREATE OR REPLACE FUNCTION nwpe_submit_tiebreaker_guess(
  p_league_id uuid, p_week int, p_slot int, p_guess int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season  int;
  v_tg      nwpe_tiebreaker_games%ROWTYPE;
  v_game_id uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;
  IF p_slot NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Invalid tiebreaker slot';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  v_tg := nwpe_get_tiebreaker_games(p_league_id, v_season, p_week);
  v_game_id := CASE p_slot WHEN 1 THEN v_tg.tb1_game_id ELSE v_tg.tb2_game_id END;

  IF v_game_id IS NULL OR nwpe_is_game_locked(v_game_id) THEN
    RAISE EXCEPTION 'This tiebreaker has already locked';
  END IF;

  INSERT INTO nwpe_tiebreaker_guesses (league_id, season, week, user_id, tb1_guess, tb2_guess, updated_at)
  VALUES (p_league_id, v_season, p_week, auth.uid(),
          CASE WHEN p_slot = 1 THEN p_guess END,
          CASE WHEN p_slot = 2 THEN p_guess END,
          now())
  ON CONFLICT (league_id, season, week, user_id) DO UPDATE SET
    tb1_guess  = CASE WHEN p_slot = 1 THEN p_guess ELSE nwpe_tiebreaker_guesses.tb1_guess END,
    tb2_guess  = CASE WHEN p_slot = 2 THEN p_guess ELSE nwpe_tiebreaker_guesses.tb2_guess END,
    updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_submit_tiebreaker_guess(uuid, int, int, int) TO authenticated;


-- nwpe_get_standings: defaults to the league's current season. Adds
-- regular_season_points/playoff_points alongside total_points; same
-- tiebreak cascade as CFB (total_points, then tiebreaks_won, then
-- tiebreak_error, then wins, then name).
DROP FUNCTION IF EXISTS nwpe_get_standings(uuid, int);
CREATE OR REPLACE FUNCTION nwpe_get_standings(p_league_id uuid, p_season int DEFAULT NULL)
RETURNS TABLE (
  user_id uuid,
  team_name text,
  regular_season_points int,
  playoff_points int,
  total_points int,
  wins int,
  losses int,
  tiebreaks_won int,
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
  WITH slot_guesses AS (
    SELECT g.week, 1 AS slot, g.user_id,
           ABS(g.tb1_guess - (gm.home_score + gm.away_score)) AS err
    FROM nwpe_tiebreaker_guesses g
    JOIN nwpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
    JOIN nwpe_games gm ON gm.id = tg.tb1_game_id AND gm.status = 'final'
    WHERE g.league_id = p_league_id AND g.season = v_season AND g.tb1_guess IS NOT NULL
    UNION ALL
    SELECT g.week, 2, g.user_id,
           ABS(g.tb2_guess - (gm.home_score + gm.away_score))
    FROM nwpe_tiebreaker_guesses g
    JOIN nwpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
    JOIN nwpe_games gm ON gm.id = tg.tb2_game_id AND gm.status = 'final'
    WHERE g.league_id = p_league_id AND g.season = v_season AND g.tb2_guess IS NOT NULL
  ),
  slot_mins AS (
    SELECT week, slot, MIN(err) AS min_err FROM slot_guesses GROUP BY week, slot
  ),
  slot_wins AS (
    SELECT sg.user_id, COUNT(*) AS won
    FROM slot_guesses sg
    JOIN slot_mins sm ON sm.week = sg.week AND sm.slot = sg.slot
    WHERE sg.err = sm.min_err
    GROUP BY sg.user_id
  ),
  tb_total_error AS (
    SELECT sg.user_id, SUM(sg.err)::numeric AS total_error FROM slot_guesses sg GROUP BY sg.user_id
  )
  SELECT
    m.user_id, m.team_name,
    COALESCE(s.regular_season_points, 0), COALESCE(s.playoff_points, 0), COALESCE(s.total_points, 0),
    COALESCE(s.wins, 0), COALESCE(s.losses, 0),
    COALESCE(sw.won, 0)::int, te.total_error
  FROM league_members m
  LEFT JOIN nwpe_scores s ON s.league_id = p_league_id AND s.season = v_season AND s.user_id = m.user_id
  LEFT JOIN slot_wins sw ON sw.user_id = m.user_id
  LEFT JOIN tb_total_error te ON te.user_id = m.user_id
  WHERE m.league_id = p_league_id
  ORDER BY
    COALESCE(s.total_points, 0) DESC,
    COALESCE(sw.won, 0) DESC,
    CASE WHEN te.total_error IS NULL THEN 1 ELSE 0 END,
    te.total_error ASC,
    COALESCE(s.wins, 0) DESC,
    m.team_name ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_get_standings(uuid, int) TO authenticated;


-- nwpe_get_tiebreak_weekly: per-week tiebreaker detail for ONE member,
-- backing the dashboard's per-week breakdown.
CREATE OR REPLACE FUNCTION nwpe_get_tiebreak_weekly(p_league_id uuid, p_season int, p_user_id uuid)
RETURNS TABLE (
  week int,
  slot int,
  guess int,
  actual int,
  won boolean,
  matchup text
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  RETURN QUERY
  WITH slot_guesses AS (
    SELECT g.week, 1 AS slot, g.user_id, g.tb1_guess AS guess,
           (gm.home_score + gm.away_score) AS actual,
           ABS(g.tb1_guess - (gm.home_score + gm.away_score)) AS err,
           gm.away_team || ' @ ' || gm.home_team AS matchup
    FROM nwpe_tiebreaker_guesses g
    JOIN nwpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
    JOIN nwpe_games gm ON gm.id = tg.tb1_game_id AND gm.status = 'final'
    WHERE g.league_id = p_league_id AND g.season = p_season AND g.tb1_guess IS NOT NULL
    UNION ALL
    SELECT g.week, 2, g.user_id, g.tb2_guess,
           (gm.home_score + gm.away_score),
           ABS(g.tb2_guess - (gm.home_score + gm.away_score)),
           gm.away_team || ' @ ' || gm.home_team
    FROM nwpe_tiebreaker_guesses g
    JOIN nwpe_tiebreaker_games tg ON tg.league_id = g.league_id AND tg.season = g.season AND tg.week = g.week
    JOIN nwpe_games gm ON gm.id = tg.tb2_game_id AND gm.status = 'final'
    WHERE g.league_id = p_league_id AND g.season = p_season AND g.tb2_guess IS NOT NULL
  ),
  slot_mins AS (
    SELECT sg.week, sg.slot, MIN(sg.err) AS min_err FROM slot_guesses sg GROUP BY sg.week, sg.slot
  )
  SELECT sg.week, sg.slot, sg.guess, sg.actual, (sg.err = sm.min_err), sg.matchup
  FROM slot_guesses sg
  JOIN slot_mins sm ON sm.week = sg.week AND sm.slot = sg.slot
  WHERE sg.user_id = p_user_id
  ORDER BY sg.week, sg.slot;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_get_tiebreak_weekly(uuid, int, uuid) TO authenticated;


-- nwpe_start_new_season: commissioner-only. Carries forward
-- pick_mode/scoring_mode/spread_lock_mode/continue_to_playoffs/
-- tiebreakers_enabled as next year's defaults. Reuses the same
-- leagues.id / invite code, matching the root dashboard's "Reactivate"
-- pattern for other season-aware modules.
CREATE OR REPLACE FUNCTION nwpe_start_new_season(p_league_id uuid)
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
  v_spread_lock_mode text;
  v_continue_to_playoffs boolean;
  v_tiebreakers_enabled boolean;
BEGIN
  SELECT (commissioner_id = auth.uid()), current_season INTO v_is_commissioner, v_prev_season
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can start a new season';
  END IF;

  v_new_season := v_prev_season + 1;

  SELECT pick_mode, scoring_mode, spread_lock_mode, continue_to_playoffs, tiebreakers_enabled
    INTO v_pick_mode, v_scoring_mode, v_spread_lock_mode, v_continue_to_playoffs, v_tiebreakers_enabled
  FROM nwpe_leagues WHERE league_id = p_league_id AND season = v_prev_season;

  INSERT INTO nwpe_leagues (league_id, season, pick_mode, scoring_mode, spread_lock_mode, continue_to_playoffs, tiebreakers_enabled)
  VALUES (p_league_id, v_new_season, COALESCE(v_pick_mode, 'straight_up'), COALESCE(v_scoring_mode, 'flat'),
          COALESCE(v_spread_lock_mode, 'week_reveal'), COALESCE(v_continue_to_playoffs, false), COALESCE(v_tiebreakers_enabled, true))
  ON CONFLICT (league_id, season) DO NOTHING;

  UPDATE leagues SET current_season = v_new_season, status = 'active' WHERE id = p_league_id;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_start_new_season(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 8. REALTIME
-- ------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nwpe_games;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nwpe_picks;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nwpe_scores;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nwpe_tiebreaker_guesses;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;


-- ------------------------------------------------------------
-- 9. LIVE SYNC SCHEDULING (pg_cron + pg_net)
-- Launches directly on pg_cron+pg_net rather than GitHub Actions, same
-- reasoning as CFB Weekly Pick'em (see that schema's own SECTION 8
-- comment — a GH Actions schedule for a sibling function went silent
-- for 5+ hours during a live event). Reuses the same
-- 'fcp_service_role_key' Vault secret every other module's cron uses.
--
-- Date window needs to cover the full NFL season including playoffs —
-- CONFIRM the actual 2026 season kickoff date and Super Bowl LXI date
-- before enabling; the window below is a placeholder estimate.
--
-- NOTE: do not run this section until nwpe-sync-games has been
-- deployed AND verified live via ?raw=true / ?dry_run=true.
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net  WITH SCHEMA extensions;

SELECT cron.schedule(
  'nwpe-sync-games-cron',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://rjtlolzdwmrhctdatekj.supabase.co/functions/v1/nwpe-sync-games',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'fcp_service_role_key')
    ),
    body := '{}'::jsonb
  )
  WHERE current_date BETWEEN DATE '2026-08-25' AND DATE '2027-02-15';
  $$
);


-- ------------------------------------------------------------
-- 10. JOIN CUTOFF — no new members once the league's own first game
-- has kicked off. Same rationale as CFB Weekly Pick'em's SECTION 9.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION nwpe_get_slate_unchecked(p_league_id uuid, p_season int, p_week int DEFAULT NULL)
RETURNS SETOF nwpe_games
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_league nwpe_leagues%ROWTYPE;
BEGIN
  SELECT * INTO v_league FROM nwpe_leagues WHERE league_id = p_league_id AND season = p_season;
  IF v_league IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT g.*
  FROM nwpe_games g
  WHERE g.season = p_season
    AND (p_week IS NULL OR g.week = p_week)
    AND (g.season_type = 2 OR (g.season_type = 3 AND COALESCE(v_league.continue_to_playoffs, false)))
  ORDER BY g.week, g.kickoff_at NULLS LAST, g.away_team, g.home_team;
END;
$$;
GRANT EXECUTE ON FUNCTION nwpe_get_slate_unchecked(uuid, int, int) TO service_role;

CREATE OR REPLACE FUNCTION nwpe_enforce_join_cutoff() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_game_type text;
  v_season int;
  v_first_kickoff timestamptz;
BEGIN
  IF EXISTS (SELECT 1 FROM league_members WHERE league_id = NEW.league_id AND user_id = NEW.user_id) THEN
    RETURN NEW;
  END IF;

  SELECT game_type, current_season INTO v_game_type, v_season FROM leagues WHERE id = NEW.league_id;
  IF v_game_type IS DISTINCT FROM 'nfl-weekly-pick-em' THEN
    RETURN NEW;
  END IF;

  SELECT MIN(kickoff_at) INTO v_first_kickoff FROM nwpe_get_slate_unchecked(NEW.league_id, v_season);
  IF v_first_kickoff IS NOT NULL AND now() >= v_first_kickoff - interval '5 minutes' THEN
    RAISE EXCEPTION 'This league''s first game has already kicked off — new members can no longer join.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS nwpe_join_cutoff ON league_members;
CREATE TRIGGER nwpe_join_cutoff
  BEFORE INSERT ON league_members
  FOR EACH ROW
  EXECUTE FUNCTION nwpe_enforce_join_cutoff();


-- ------------------------------------------------------------
-- 11. PICK REMINDERS — optional, per (league, member). Same shape as
-- CFB Weekly Pick'em's SECTION 10.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nwpe_reminder_prefs (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  hours_before   int, -- NULL = no reminder; otherwise one of 48 / 24 / 2
  updated_at     timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, user_id),
  CHECK (hours_before IS NULL OR hours_before IN (48, 24, 2))
);

ALTER TABLE nwpe_reminder_prefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members manage their own reminder pref" ON nwpe_reminder_prefs;
CREATE POLICY "Members manage their own reminder pref" ON nwpe_reminder_prefs FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid() AND is_league_member(league_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON nwpe_reminder_prefs TO authenticated;
GRANT SELECT ON nwpe_reminder_prefs TO service_role;

CREATE TABLE IF NOT EXISTS nwpe_reminder_log (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  season         int  NOT NULL,
  week           int  NOT NULL,
  hours_before   int  NOT NULL,
  sent_at        timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, user_id, season, week, hours_before)
);

ALTER TABLE nwpe_reminder_log ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON nwpe_reminder_log TO service_role;


-- ------------------------------------------------------------
-- 12. PICK REMINDER SCHEDULING (pg_cron + pg_net)
-- Same pattern/reasoning as SECTION 9.
--
-- NOTE: do not run this until nwpe-send-pick-reminders has been
-- deployed and smoke-tested.
-- ------------------------------------------------------------
SELECT cron.schedule(
  'nwpe-send-pick-reminders-cron',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://rjtlolzdwmrhctdatekj.supabase.co/functions/v1/nwpe-send-pick-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'fcp_service_role_key')
    ),
    body := '{}'::jsonb
  )
  WHERE current_date BETWEEN DATE '2026-08-25' AND DATE '2027-02-15';
  $$
);
