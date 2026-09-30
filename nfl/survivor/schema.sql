-- ============================================================
-- NFL Survivor Pool — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE / ON CONFLICT)
--
-- Assumes the shared `leagues`, `league_members`, `profiles` tables
-- and the `is_league_member(uuid)` helper already exist (see
-- soccer/world-cup-bracket-challenge/schema.sql), plus the shared
-- `join_league_by_invite_code()` / `set_team_name()` RPCs.
--
-- Prefix: nsv_ (NFL SurVivor). game_type = 'nfl-survivor'.
--
-- DELIBERATE BREAK FROM CONVENTION: every other module in this repo
-- (nwpe_/wpe_/bpe_) owns its own `*_games` table and its own 15-min
-- ESPN sync cron, even when the underlying slate overlaps another
-- module's. Survivor doesn't — it reads `nwpe_games`,
-- `nwpe_game_spread_locks`, and calls `nwpe_ats_cover()` /
-- `nwpe_is_game_locked()` / reads `nwpe_season_state` directly,
-- entirely READ-ONLY, all defined in nfl/weekly-pick-em/schema.sql.
-- Justified here (and only here) because Survivor needs a strict
-- subset of exactly what NFL Weekly Pick'em already maintains
-- (kickoff time, teams, final score/winner, and — for spread mode —
-- the same per-lock-mode frozen spread snapshot), with no
-- Survivor-specific freeze policy of its own. Running a 4th
-- independent cron against the identical NFL scoreboard would just be
-- redundant ESPN load for data that already exists. If NFL Weekly
-- Pick'em is ever removed from the site, this module breaks — that
-- coupling is accepted as the tradeoff.
--
-- MECHANIC: each week, pick ONE team from that week's slate. No
-- repeat teams all season (enforced by a hard UNIQUE constraint on
-- nsv_picks, not just app-level validation). Commissioner sets:
--   - pick_mode: 'straight_up' (plain win/loss) or 'spread' (ATS,
--     reusing nwpe_game_spread_locks/nwpe_ats_cover exactly as NFL
--     Weekly Pick'em's spread mode does, including the same
--     null-spread-at-lock pick'em fallback).
--   - result_mode: 'survive_on_win' (classic — your pick must win/
--     cover) or 'survive_on_loss' (Eliminator — your pick must lose/
--     fail to cover). Generalized internally as "hit" (won or
--     covered) vs. "survive" (hit, in survive_on_win mode; a miss, in
--     survive_on_loss mode) so one grading path serves both modes.
--   - lives_allowed: 0, 1, or 2 mulligans. A mulligan burns a life
--     instead of eliminating the member; the team picked that week
--     still counts as used either way. pick_mode/result_mode/
--     lives_allowed all LOCK once any pick exists this season, same
--     enforcement pattern as nwpe_update_league_settings.
--   - continue_to_playoffs: same opt-in flag as NFL Weekly Pick'em,
--     reusing nwpe_games' season_type = 3 rows.
--
-- GRADING IS ORDER-DEPENDENT, unlike nwpe_recalculate_scores' pure
-- set-based JOIN — elimination in week N depends on how many lives
-- were already spent in weeks 1..N-1, so nsv_recalculate_status walks
-- each member's picks in week order procedurally (see section 6)
-- rather than aggregating with a single query.
-- ============================================================


-- ------------------------------------------------------------
-- 1. NSV LEAGUES
-- One row per (league, season) — reused year over year (same
-- leagues.id, same invite code) via nsv_start_new_season().
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nsv_leagues (
  league_id             uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season                int  NOT NULL DEFAULT extract(year from now())::int,
  pick_mode             text NOT NULL DEFAULT 'straight_up' CHECK (pick_mode IN ('straight_up', 'spread')),
  result_mode           text NOT NULL DEFAULT 'survive_on_win' CHECK (result_mode IN ('survive_on_win', 'survive_on_loss')),
  lives_allowed         int  NOT NULL DEFAULT 0 CHECK (lives_allowed IN (0, 1, 2)),
  -- Only meaningful when pick_mode = 'spread' — same two modes as NFL
  -- Weekly Pick'em, reading the matching row out of the SHARED
  -- nwpe_game_spread_locks table (not a Survivor-owned snapshot).
  spread_lock_mode      text NOT NULL DEFAULT 'week_reveal' CHECK (spread_lock_mode IN ('week_reveal', 'day_before_kickoff')),
  -- Commissioner-configurable PICK lock timing (distinct from
  -- spread_lock_mode above, which only controls when the SPREAD NUMBER
  -- freezes). 'per_game' (default) matches Yahoo/ESPN's own survivor
  -- products — each game locks 5 min before its own kickoff, so a
  -- member can hold a Monday-night pick and watch Thursday + the whole
  -- Sunday slate first. 'sunday_kickoff' and 'week_kickoff' close that
  -- information gap by locking the ENTIRE week's pick at once — see
  -- nsv_week_lock_threshold below for the exact per-mode cutoff.
  pick_lock_mode        text NOT NULL DEFAULT 'per_game' CHECK (pick_lock_mode IN ('per_game', 'sunday_kickoff', 'week_kickoff')),
  continue_to_playoffs  boolean NOT NULL DEFAULT false,
  -- Only meaningful when continue_to_playoffs = true. By Week 19, a
  -- member who's survived the whole regular season has already used up
  -- to 18 of the 32 teams — and some of those already-used teams are
  -- routinely playoff qualifiers, which can leave a still-alive member
  -- with zero legal teams left for a round. Same "editable any time, only
  -- affects future weeks" treatment as continue_to_playoffs itself (see
  -- nsv_update_league_settings) — changing it doesn't retroactively
  -- alter any pick already made, since nsv_picks.phase (below) is
  -- computed and stored once, at submit time.
  reset_teams_for_playoffs boolean NOT NULL DEFAULT false,
  created_at            timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season)
);

-- Idempotent add for the already-live table (CREATE TABLE IF NOT EXISTS
-- above is a no-op once nsv_leagues already exists).
ALTER TABLE nsv_leagues ADD COLUMN IF NOT EXISTS reset_teams_for_playoffs boolean NOT NULL DEFAULT false;

ALTER TABLE nsv_leagues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view nsv league" ON nsv_leagues;
CREATE POLICY "League members can view nsv league" ON nsv_leagues FOR SELECT
  USING (is_league_member(league_id));

DROP POLICY IF EXISTS "Commissioner can insert nsv league" ON nsv_leagues;
CREATE POLICY "Commissioner can insert nsv league" ON nsv_leagues FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM leagues WHERE id = nsv_leagues.league_id AND commissioner_id = auth.uid()
  ));
-- No direct UPDATE policy — settings changes go through
-- nsv_update_league_settings(), which rejects pick_mode/result_mode/
-- lives_allowed changes once picks already exist.

GRANT SELECT, INSERT ON nsv_leagues TO authenticated;


-- ------------------------------------------------------------
-- 2. NSV PICKS
-- One pick per member per week (UNIQUE on league/season/user/week),
-- AND a hard UNIQUE on league/season/user/picked_team/phase so "no
-- repeat teams" is a real DB constraint, not just app-level validation
-- in nsv_submit_pick. `phase` is 'season' for every pick (regular AND
-- playoff weeks share one no-repeat pool, unchanged default behavior)
-- UNLESS the league has reset_teams_for_playoffs enabled, in which case
-- weeks 1-18 are 'regular' and weeks 19+ are 'playoffs' — two
-- independent no-repeat pools, so a team already used in the regular
-- season is still legal once in the playoffs. Computed and stored by
-- nsv_submit_pick at submit time (not derived live), so toggling the
-- league setting later never rewrites an already-made pick's phase.
-- Same lock-gated-visibility RLS pattern as nwpe_picks: your own picks
-- always visible; others' visible only once that specific game locks
-- (nwpe_is_game_locked). `used_mulligan` is set by
-- nsv_recalculate_status, not at submit time — outcome isn't known
-- until the game is final.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nsv_picks (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season         int  NOT NULL,
  week           int  NOT NULL,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id        uuid NOT NULL REFERENCES nwpe_games(id) ON DELETE CASCADE,
  picked_team    text NOT NULL,
  used_mulligan  boolean NOT NULL DEFAULT false,
  phase          text NOT NULL DEFAULT 'season' CHECK (phase IN ('season', 'regular', 'playoffs')),
  submitted_at   timestamptz DEFAULT now(),
  updated_at     timestamptz DEFAULT now(),
  UNIQUE (league_id, season, user_id, week),
  UNIQUE (league_id, season, user_id, picked_team, phase)
);

-- Idempotent migration for the already-live table — CREATE TABLE IF NOT
-- EXISTS above is a no-op once nsv_picks already exists, and a UNIQUE
-- constraint's columns can't be altered in place.
ALTER TABLE nsv_picks ADD COLUMN IF NOT EXISTS phase text NOT NULL DEFAULT 'season';
ALTER TABLE nsv_picks DROP CONSTRAINT IF EXISTS nsv_picks_phase_check;
ALTER TABLE nsv_picks ADD CONSTRAINT nsv_picks_phase_check CHECK (phase IN ('season', 'regular', 'playoffs'));
ALTER TABLE nsv_picks DROP CONSTRAINT IF EXISTS nsv_picks_league_id_season_user_id_picked_team_key;
ALTER TABLE nsv_picks DROP CONSTRAINT IF EXISTS nsv_picks_league_id_season_user_id_picked_team_phase_key;
ALTER TABLE nsv_picks ADD CONSTRAINT nsv_picks_league_id_season_user_id_picked_team_phase_key
  UNIQUE (league_id, season, user_id, picked_team, phase);

CREATE INDEX IF NOT EXISTS nsv_picks_league_season_week_idx ON nsv_picks(league_id, season, week);

ALTER TABLE nsv_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own picks always visible; others after game locks" ON nsv_picks;
CREATE POLICY "Own picks always visible; others after game locks" ON nsv_picks FOR SELECT
  USING (
    user_id = auth.uid()
    OR (is_league_member(nsv_picks.league_id) AND nwpe_is_game_locked(nsv_picks.game_id))
  );
-- No direct INSERT/UPDATE/DELETE policy — all writes go through
-- nsv_submit_pick() / nsv_clear_pick().

GRANT SELECT ON nsv_picks TO authenticated;


-- ------------------------------------------------------------
-- 3. NSV STATUS
-- Alive/eliminated state per member, recomputed from scratch by
-- nsv_recalculate_status(). Deliberately named _status rather than
-- following the _scores convention every other module uses — this
-- table holds elimination state, not accumulated points, so the
-- naming mismatch is intentional, not an oversight.
--
-- Unlike nsv_picks, is_alive/lives_remaining/eliminated_* are visible
-- to every league member always (no lock-gating) — "who's still in"
-- is core to a survivor pool and doesn't reveal which team anyone
-- picked, only whether they're still standing.
--
-- weeks_survived exists so eliminated members still get a real rank
-- ("how far did you get") instead of collapsing into one undifferentiated
-- "eliminated" bucket — see nsv_get_standings.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nsv_status (
  league_id         uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season            int  NOT NULL,
  user_id           uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  is_alive          boolean NOT NULL DEFAULT true,
  lives_remaining   int  NOT NULL DEFAULT 0,
  eliminated_week   int,
  eliminated_team   text,
  weeks_survived    int  NOT NULL DEFAULT 0,
  last_updated      timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, user_id)
);

ALTER TABLE nsv_status ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view nsv status" ON nsv_status;
CREATE POLICY "League members can view nsv status" ON nsv_status FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON nsv_status TO authenticated;
GRANT SELECT, INSERT, UPDATE ON nsv_status TO service_role;


-- ------------------------------------------------------------
-- 4. RPCs — slate, picks, settings
-- ------------------------------------------------------------

-- nsv_get_slate: same shape as nwpe_get_slate, just querying the
-- shared nwpe_games table under a different league-settings row.
CREATE OR REPLACE FUNCTION nsv_get_slate(p_league_id uuid, p_season int, p_week int DEFAULT NULL)
RETURNS SETOF nwpe_games
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_league nsv_leagues%ROWTYPE;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT * INTO v_league FROM nsv_leagues WHERE league_id = p_league_id AND season = p_season;

  RETURN QUERY
  SELECT g.*
  FROM nwpe_games g
  WHERE g.season = p_season
    AND (p_week IS NULL OR g.week = p_week)
    AND (g.season_type = 2 OR (g.season_type = 3 AND COALESCE(v_league.continue_to_playoffs, false)))
  ORDER BY g.week, g.kickoff_at NULLS LAST, g.away_team, g.home_team;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_get_slate(uuid, int, int) TO authenticated;


-- nsv_week_lock_threshold: returns the whole-week pick-lock cutoff for
-- 'sunday_kickoff'/'week_kickoff' modes, or NULL for 'per_game' (no
-- additional cutoff beyond each game's own kickoff). Day-of-week is
-- evaluated in America/New_York wall-clock time, matching how the NFL
-- actually schedules Thursday/Sunday/Monday slots regardless of server
-- timezone. If a week genuinely has no non-Thursday game (shouldn't
-- normally happen), 'sunday_kickoff' falls back to the week's first
-- kickoff overall rather than returning NULL.
CREATE OR REPLACE FUNCTION nsv_week_lock_threshold(p_league_id uuid, p_season int, p_week int)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_mode text;
  v_threshold timestamptz;
BEGIN
  SELECT pick_lock_mode INTO v_mode FROM nsv_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_mode IS NULL OR v_mode = 'per_game' THEN
    RETURN NULL;
  END IF;

  IF v_mode = 'week_kickoff' THEN
    SELECT MIN(kickoff_at) - interval '5 minutes' INTO v_threshold
    FROM nwpe_games WHERE season = p_season AND week = p_week;
  ELSE -- sunday_kickoff
    SELECT MIN(kickoff_at) - interval '5 minutes' INTO v_threshold
    FROM nwpe_games
    WHERE season = p_season AND week = p_week
      AND extract(dow from (kickoff_at AT TIME ZONE 'America/New_York')) != 4; -- exclude Thursday

    IF v_threshold IS NULL THEN
      SELECT MIN(kickoff_at) - interval '5 minutes' INTO v_threshold
      FROM nwpe_games WHERE season = p_season AND week = p_week;
    END IF;
  END IF;

  RETURN v_threshold;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_week_lock_threshold(uuid, int, int) TO authenticated, service_role;


-- nsv_is_pick_locked: the real lock check nsv_submit_pick/nsv_clear_pick
-- use — a game is pick-locked once EITHER its own kickoff-minus-5-min
-- has passed (nwpe_is_game_locked, always true regardless of mode) OR
-- the league's whole-week threshold has passed (only set in
-- 'sunday_kickoff'/'week_kickoff' modes).
CREATE OR REPLACE FUNCTION nsv_is_pick_locked(p_league_id uuid, p_season int, p_game_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_week int;
  v_threshold timestamptz;
BEGIN
  IF nwpe_is_game_locked(p_game_id) THEN
    RETURN true;
  END IF;

  SELECT week INTO v_week FROM nwpe_games WHERE id = p_game_id;
  v_threshold := nsv_week_lock_threshold(p_league_id, p_season, v_week);

  RETURN v_threshold IS NOT NULL AND now() >= v_threshold;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_is_pick_locked(uuid, int, uuid) TO authenticated, service_role;


-- nsv_submit_pick: one pick per week (upsert on league/season/user/
-- week), hard-blocked from reusing an already-picked team (friendly
-- error ahead of the UNIQUE constraint), and blocked entirely once
-- the member is eliminated. No confidence points — Survivor has no
-- scoring, just a single team choice.
CREATE OR REPLACE FUNCTION nsv_submit_pick(
  p_league_id uuid,
  p_game_id uuid,
  p_picked_team text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season      int;
  v_game        nwpe_games%ROWTYPE;
  v_is_alive    boolean;
  v_already_used boolean;
  v_existing_game_id uuid;
  v_reset_playoffs boolean;
  v_phase       text;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT COALESCE(reset_teams_for_playoffs, false) INTO v_reset_playoffs
  FROM nsv_leagues WHERE league_id = p_league_id AND season = v_season;

  SELECT COALESCE(
    (SELECT is_alive FROM nsv_status WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid()),
    true
  ) INTO v_is_alive;
  IF NOT v_is_alive THEN
    RAISE EXCEPTION 'You have been eliminated from this pool';
  END IF;

  SELECT * INTO v_game FROM nwpe_games WHERE id = p_game_id AND season = v_season;
  IF v_game.id IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;
  IF nsv_is_pick_locked(p_league_id, v_season, p_game_id) THEN
    RAISE EXCEPTION 'Picks for this week have already locked';
  END IF;
  IF p_picked_team NOT IN (v_game.home_team, v_game.away_team) THEN
    RAISE EXCEPTION 'Invalid team for this game';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM nsv_get_slate(p_league_id, v_season, v_game.week) s WHERE s.id = p_game_id) THEN
    RAISE EXCEPTION 'This game is not part of your league''s weekly slate';
  END IF;

  -- The lock check above only covers the NEWLY clicked game — a
  -- member switching their pick to a still-open game elsewhere in the
  -- same week would otherwise silently overwrite an existing pick
  -- whose own game has already gone final (already graded, possibly
  -- already a win). nsv_clear_pick already guards this by checking the
  -- EXISTING pick's own lock status; this mirrors that check here.
  SELECT game_id INTO v_existing_game_id FROM nsv_picks
  WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND week = v_game.week;

  IF v_existing_game_id IS NOT NULL AND v_existing_game_id != p_game_id
     AND nsv_is_pick_locked(p_league_id, v_season, v_existing_game_id) THEN
    RAISE EXCEPTION 'Your pick for this week has already locked and can''t be changed';
  END IF;

  -- 'season' (one no-repeat pool covering the whole year) unless the
  -- league opted into resetting used teams for the playoffs, in which
  -- case weeks 1-18 and weeks 19+ are two independent no-repeat pools.
  v_phase := CASE
    WHEN NOT v_reset_playoffs THEN 'season'
    WHEN v_game.week <= 18 THEN 'regular'
    ELSE 'playoffs'
  END;

  SELECT EXISTS (
    SELECT 1 FROM nsv_picks
    WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid()
      AND picked_team = p_picked_team AND week != v_game.week AND phase = v_phase
  ) INTO v_already_used;
  IF v_already_used THEN
    RAISE EXCEPTION 'You''ve already used %', p_picked_team ||
      (CASE v_phase WHEN 'playoffs' THEN ' in the playoffs' WHEN 'regular' THEN ' this regular season' ELSE ' this season' END);
  END IF;

  INSERT INTO nsv_picks (league_id, season, week, user_id, game_id, picked_team, phase, updated_at)
  VALUES (p_league_id, v_season, v_game.week, auth.uid(), p_game_id, p_picked_team, v_phase, now())
  ON CONFLICT (league_id, season, user_id, week)
  DO UPDATE SET game_id = EXCLUDED.game_id, picked_team = EXCLUDED.picked_team, phase = EXCLUDED.phase, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_submit_pick(uuid, uuid, text) TO authenticated;


-- nsv_clear_pick: undo a week's pick, only while that game is open.
CREATE OR REPLACE FUNCTION nsv_clear_pick(p_league_id uuid, p_week int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season  int;
  v_game_id uuid;
BEGIN
  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT game_id INTO v_game_id FROM nsv_picks
  WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND week = p_week;

  IF v_game_id IS NULL THEN
    RETURN; -- nothing to clear
  END IF;
  IF nsv_is_pick_locked(p_league_id, v_season, v_game_id) THEN
    RAISE EXCEPTION 'Picks for this week have already locked';
  END IF;

  DELETE FROM nsv_picks
  WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND week = p_week;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_clear_pick(uuid, int) TO authenticated;


-- nsv_update_league_settings: pick_mode/result_mode/lives_allowed/
-- pick_lock_mode lock once any pick exists this season (same rule/
-- reasoning as nwpe_update_league_settings) — pick_lock_mode is
-- included because nsv_week_lock_threshold reads the CURRENT setting
-- live rather than a per-week snapshot, so letting it change
-- mid-season could retroactively alter whether an already-closed week
-- counts as closed. spread_lock_mode/continue_to_playoffs stay
-- editable any time — they only affect future weeks.
DROP FUNCTION IF EXISTS nsv_update_league_settings(uuid, text, text, int, text, boolean);
DROP FUNCTION IF EXISTS nsv_update_league_settings(uuid, text, text, int, text, text, boolean);
DROP FUNCTION IF EXISTS nsv_update_league_settings(uuid, text, text, int, text, text, boolean, boolean);
CREATE OR REPLACE FUNCTION nsv_update_league_settings(
  p_league_id uuid,
  p_pick_mode text,
  p_result_mode text,
  p_lives_allowed int,
  p_pick_lock_mode text,
  p_spread_lock_mode text,
  p_continue_to_playoffs boolean,
  p_reset_teams_for_playoffs boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season int;
  v_is_commissioner boolean;
  v_current_pick_mode text;
  v_current_result_mode text;
  v_current_lives int;
  v_current_pick_lock_mode text;
  v_pick_count int;
BEGIN
  SELECT current_season, (commissioner_id = auth.uid())
    INTO v_season, v_is_commissioner
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can change league settings';
  END IF;

  SELECT pick_mode, result_mode, lives_allowed, pick_lock_mode
    INTO v_current_pick_mode, v_current_result_mode, v_current_lives, v_current_pick_lock_mode
  FROM nsv_leagues WHERE league_id = p_league_id AND season = v_season;

  IF p_pick_mode IS DISTINCT FROM v_current_pick_mode
     OR p_result_mode IS DISTINCT FROM v_current_result_mode
     OR p_lives_allowed IS DISTINCT FROM v_current_lives
     OR p_pick_lock_mode IS DISTINCT FROM v_current_pick_lock_mode THEN
    SELECT count(*) INTO v_pick_count FROM nsv_picks WHERE league_id = p_league_id AND season = v_season;
    IF v_pick_count > 0 THEN
      RAISE EXCEPTION 'Cannot change pick mode, result mode, lives, or lock timing after picks have been made this season';
    END IF;
  END IF;

  UPDATE nsv_leagues SET
    pick_mode = p_pick_mode, result_mode = p_result_mode, lives_allowed = p_lives_allowed,
    pick_lock_mode = p_pick_lock_mode,
    spread_lock_mode = p_spread_lock_mode, continue_to_playoffs = p_continue_to_playoffs,
    reset_teams_for_playoffs = p_reset_teams_for_playoffs
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_update_league_settings(uuid, text, text, int, text, text, boolean, boolean) TO authenticated;


-- ------------------------------------------------------------
-- 5. NSV REMINDER PREFS/LOG — same shape as nwpe's, own table so
-- eliminated members can be excluded from future reminders (see the
-- nsv-send-pick-reminders edge function).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nsv_reminder_prefs (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  hours_before   int, -- NULL = no reminder; otherwise one of 48 / 24 / 2
  updated_at     timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, user_id),
  CHECK (hours_before IS NULL OR hours_before IN (48, 24, 2))
);

ALTER TABLE nsv_reminder_prefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members manage their own reminder pref" ON nsv_reminder_prefs;
CREATE POLICY "Members manage their own reminder pref" ON nsv_reminder_prefs FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid() AND is_league_member(league_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON nsv_reminder_prefs TO authenticated;
GRANT SELECT ON nsv_reminder_prefs TO service_role;

CREATE TABLE IF NOT EXISTS nsv_reminder_log (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  season         int  NOT NULL,
  week           int  NOT NULL,
  hours_before   int  NOT NULL,
  sent_at        timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, user_id, season, week, hours_before)
);

ALTER TABLE nsv_reminder_log ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON nsv_reminder_log TO service_role;


-- ------------------------------------------------------------
-- 6. GRADING — nsv_recalculate_status
--
-- Order-dependent per member: walks every week in the league's SLATE
-- (not just weeks the member actually picked) in order, tracking
-- lives_remaining and is_alive as it goes, and stops entirely once
-- eliminated. Critically, this walks the full week list rather than
-- just nsv_picks rows — a week where the member never submitted a
-- pick still needs to be evaluated once it's fully closed (every game
-- in that week locked): a missed pick on a closed week is an
-- automatic miss, same as a wrong pick, burning a life or eliminating
-- exactly like nsv-send-pick-reminders' copy promises. A week that
-- ISN'T closed yet (still has an open game) or whose existing pick's
-- game hasn't gone final yet stops the loop for that member — nothing
-- past that point can be evaluated until more games finish.
--
-- Same straight_up/spread grading logic as nwpe_recalculate_scores
-- for weeks WITH a pick: spread mode reads the league's own locked
-- snapshot from the SHARED nwpe_game_spread_locks (filtered by this
-- league's spread_lock_mode), with the same null-spread-at-lock
-- pick'em fallback and push-is-a-non-event handling (a push neither
-- survives nor eliminates — counts as a survived week, burns no life).
--
-- result_mode flips what counts as "surviving" a made pick:
-- survive_on_win needs a hit (won straight-up, or covered in spread
-- mode); survive_on_loss needs a miss. A push is never a "hit" or a
-- "miss" in either mode. A MISSED pick (no row at all) always counts
-- as a miss regardless of result_mode — there's no pick to have
-- "survived on losing."
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION nsv_recalculate_status(p_league_id uuid, p_season int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pick_mode            text;
  v_result_mode           text;
  v_lives_allowed         int;
  v_spread_lock_mode      text;
  v_continue_to_playoffs  boolean;
  v_member                record;
  v_week_row              record;
  v_lives_remaining       int;
  v_is_alive              boolean;
  v_eliminated_week       int;
  v_eliminated_team       text;
  v_weeks_survived        int;
  v_week_closed           boolean;
  v_pick_id               uuid;
  v_pick_game_id          uuid;
  v_pick_team             text;
  v_game_status           text;
  v_winner_team           text;
  v_home_team             text;
  v_away_team             text;
  v_home_score            int;
  v_away_score            int;
  v_hit                   boolean;
  v_gradeable             boolean;
  v_survive               boolean;
  v_locked_spread         numeric;
  v_locked_fav            text;
  v_ats_winner            text;
  v_league_created_at     timestamptz;
BEGIN
  SELECT pick_mode, result_mode, lives_allowed, spread_lock_mode, continue_to_playoffs, created_at
    INTO v_pick_mode, v_result_mode, v_lives_allowed, v_spread_lock_mode, v_continue_to_playoffs, v_league_created_at
  FROM nsv_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_pick_mode IS NULL THEN
    RETURN; -- no nsv_leagues row for this league/season yet — nothing to grade
  END IF;

  FOR v_member IN SELECT user_id FROM league_members WHERE league_id = p_league_id LOOP
    v_lives_remaining := v_lives_allowed;
    v_is_alive := true;
    v_eliminated_week := NULL;
    v_eliminated_team := NULL;
    v_weeks_survived := 0;

    FOR v_week_row IN
      SELECT DISTINCT g.week
      FROM nwpe_games g
      WHERE g.season = p_season
        AND (g.season_type = 2 OR (g.season_type = 3 AND COALESCE(v_continue_to_playoffs, false)))
      ORDER BY g.week
    LOOP
      EXIT WHEN NOT v_is_alive;

      SELECT
        (nsv_week_lock_threshold(p_league_id, p_season, v_week_row.week) IS NOT NULL
         AND now() >= nsv_week_lock_threshold(p_league_id, p_season, v_week_row.week))
        OR NOT EXISTS (
          SELECT 1 FROM nwpe_games g2
          WHERE g2.season = p_season AND g2.week = v_week_row.week AND NOT nwpe_is_game_locked(g2.id)
        )
      INTO v_week_closed;

      SELECT p.id, p.game_id, p.picked_team INTO v_pick_id, v_pick_game_id, v_pick_team
      FROM nsv_picks p
      WHERE p.league_id = p_league_id AND p.season = p_season AND p.user_id = v_member.user_id AND p.week = v_week_row.week;

      v_gradeable := true;

      IF v_pick_id IS NULL THEN
        IF NOT v_week_closed THEN
          EXIT; -- still open / future — nothing more to evaluate yet
        END IF;

        -- A missing pick on a closed week is only a real miss if the
        -- member actually had a fair look at this week's full slate —
        -- skip it silently (no penalty either way) if ANY of its games
        -- had already kicked off before this league (nsv_leagues row)
        -- was even created. nwpe_games is shared across every module,
        -- so a Survivor pool created mid-season inherits weeks that are
        -- already partway (or fully) synced/final; same "earliest
        -- kickoff" concept nsv_enforce_join_cutoff uses to gate new
        -- members joining at all, just applied per-week. This check
        -- ONLY applies to a missing pick — a week the member actually
        -- picked in (the ELSE branch below) is always graded normally,
        -- since submitting a pick is itself proof they had a real
        -- opportunity that week regardless of what else already
        -- happened in it.
        CONTINUE WHEN EXISTS (
          SELECT 1 FROM nwpe_games g3
          WHERE g3.season = p_season AND g3.week = v_week_row.week
            AND g3.kickoff_at IS NOT NULL AND g3.kickoff_at < v_league_created_at
        );

        v_hit := false; -- missed pick on a closed week = automatic miss
      ELSE
        SELECT status, winner_team, home_team, away_team, home_score, away_score
          INTO v_game_status, v_winner_team, v_home_team, v_away_team, v_home_score, v_away_score
        FROM nwpe_games WHERE id = v_pick_game_id;

        IF v_game_status != 'final' THEN
          EXIT; -- pick made but not resolved yet — nothing more to evaluate
        END IF;

        IF v_pick_mode = 'straight_up' THEN
          v_hit := (v_pick_team = v_winner_team);
        ELSE
          SELECT locked_spread, locked_favorite_team INTO v_locked_spread, v_locked_fav
          FROM nwpe_game_spread_locks WHERE game_id = v_pick_game_id AND lock_mode = v_spread_lock_mode;

          IF v_locked_spread IS NULL THEN
            v_hit := (v_pick_team = v_winner_team); -- pick'em fallback, same as Weekly Pick'em
          ELSE
            v_ats_winner := nwpe_ats_cover(v_home_team, v_away_team, v_home_score, v_away_score, v_locked_spread, v_locked_fav);
            IF v_ats_winner IS NULL THEN
              v_gradeable := false; -- push
            ELSE
              v_hit := (v_pick_team = v_ats_winner);
            END IF;
          END IF;
        END IF;
      END IF;

      IF NOT v_gradeable THEN
        v_weeks_survived := v_weeks_survived + 1;
        CONTINUE;
      END IF;

      v_survive := v_pick_id IS NOT NULL
        AND ((v_result_mode = 'survive_on_win' AND v_hit) OR (v_result_mode = 'survive_on_loss' AND NOT v_hit));

      IF v_survive THEN
        v_weeks_survived := v_weeks_survived + 1;
        UPDATE nsv_picks SET used_mulligan = false WHERE id = v_pick_id;
      ELSIF v_lives_remaining > 0 THEN
        v_lives_remaining := v_lives_remaining - 1;
        v_weeks_survived := v_weeks_survived + 1;
        IF v_pick_id IS NOT NULL THEN
          UPDATE nsv_picks SET used_mulligan = true WHERE id = v_pick_id;
        END IF;
      ELSE
        v_is_alive := false;
        v_eliminated_week := v_week_row.week;
        v_eliminated_team := v_pick_team; -- NULL if the elimination was a missed pick
        IF v_pick_id IS NOT NULL THEN
          UPDATE nsv_picks SET used_mulligan = false WHERE id = v_pick_id;
        END IF;
      END IF;
    END LOOP;

    INSERT INTO nsv_status (league_id, season, user_id, is_alive, lives_remaining, eliminated_week, eliminated_team, weeks_survived, last_updated)
    VALUES (p_league_id, p_season, v_member.user_id, v_is_alive, v_lives_remaining, v_eliminated_week, v_eliminated_team, v_weeks_survived, now())
    ON CONFLICT (league_id, season, user_id) DO UPDATE SET
      is_alive = EXCLUDED.is_alive, lives_remaining = EXCLUDED.lives_remaining,
      eliminated_week = EXCLUDED.eliminated_week, eliminated_team = EXCLUDED.eliminated_team,
      weeks_survived = EXCLUDED.weeks_survived, last_updated = now();
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_recalculate_status(uuid, int) TO authenticated, service_role;


-- nsv_recalculate_all_status: service_role only, called by NFL Weekly
-- Pick'em's own sync function (see the wiring note in
-- nfl/weekly-pick-em's nwpe-sync-games — Survivor rides that cron's
-- completion rather than running its own) after every ESPN pull.
-- A league completes either when the season/playoffs the league opted
-- into are fully done (reusing nwpe_season_state, same check as
-- nwpe_recalculate_all_scores), OR the moment at most one member is
-- still alive — a survivor pool can crown its winner early.
CREATE OR REPLACE FUNCTION nsv_recalculate_all_status()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_league        record;
  v_state         record;
  v_season_done   boolean;
  v_alive_count   int;
  v_member_count  int;
BEGIN
  FOR v_league IN
    SELECT id, current_season FROM leagues
    WHERE game_type = 'nfl-survivor' AND status IN ('active', 'pending')
  LOOP
    PERFORM nsv_recalculate_status(v_league.id, v_league.current_season);

    SELECT regular_season_complete_at, playoffs_complete_at INTO v_state
    FROM nwpe_season_state WHERE season = v_league.current_season;

    SELECT COALESCE(
      CASE WHEN nl.continue_to_playoffs
        THEN v_state.playoffs_complete_at IS NOT NULL
        ELSE v_state.regular_season_complete_at IS NOT NULL
      END, false)
    INTO v_season_done
    FROM nsv_leagues nl WHERE nl.league_id = v_league.id AND nl.season = v_league.current_season;

    SELECT count(*) FILTER (WHERE is_alive) INTO v_alive_count
    FROM nsv_status WHERE league_id = v_league.id AND season = v_league.current_season;

    SELECT count(*) INTO v_member_count FROM league_members WHERE league_id = v_league.id;

    -- "at most one alive = crown the winner early" only means something
    -- once there were multiple entrants to begin with — a single-member
    -- league (a solo test, or a "race the field" style pool) has
    -- v_alive_count <= 1 trivially true from the moment it's created,
    -- which was completing it before its one member ever got a pick in.
    -- A solo member who's since been fully eliminated (v_alive_count = 0)
    -- still correctly completes the league either way.
    IF COALESCE(v_season_done, false)
       OR COALESCE(v_alive_count, 999) = 0
       OR (v_member_count > 1 AND COALESCE(v_alive_count, 999) <= 1) THEN
      UPDATE leagues SET status = 'completed' WHERE id = v_league.id AND status != 'completed';
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_recalculate_all_status() TO service_role;


-- nsv_get_standings: alive members first, then eliminated members
-- ranked by how far they got (weeks_survived DESC), so elimination
-- doesn't collapse everyone into one undifferentiated bucket.
CREATE OR REPLACE FUNCTION nsv_get_standings(p_league_id uuid, p_season int DEFAULT NULL)
RETURNS TABLE (
  user_id          uuid,
  team_name        text,
  is_alive         boolean,
  lives_remaining  int,
  eliminated_week  int,
  eliminated_team  text,
  weeks_survived   int
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_season int;
  v_lives_allowed int;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  v_season := p_season;
  IF v_season IS NULL THEN
    SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  END IF;

  SELECT lives_allowed INTO v_lives_allowed FROM nsv_leagues WHERE league_id = p_league_id AND season = v_season;

  RETURN QUERY
  SELECT
    m.user_id, m.team_name,
    -- A member with no nsv_status row yet (nsv_recalculate_status hasn't
    -- run since they joined — e.g. a league created after the last sync
    -- tick) hasn't lost any mulligans, so they should still show the
    -- league's full lives_allowed, not a hardcoded 0.
    COALESCE(s.is_alive, true), COALESCE(s.lives_remaining, v_lives_allowed, 0),
    s.eliminated_week, s.eliminated_team, COALESCE(s.weeks_survived, 0)
  FROM league_members m
  LEFT JOIN nsv_status s ON s.league_id = p_league_id AND s.season = v_season AND s.user_id = m.user_id
  WHERE m.league_id = p_league_id
  ORDER BY
    COALESCE(s.is_alive, true) DESC,
    COALESCE(s.weeks_survived, 0) DESC,
    m.team_name ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_get_standings(uuid, int) TO authenticated;


-- nsv_start_new_season: commissioner-only. Carries forward pick_mode/
-- result_mode/lives_allowed/spread_lock_mode/continue_to_playoffs as
-- next year's defaults. nsv_picks/nsv_status need no explicit reset —
-- both are already season-scoped via composite keys, so a new season
-- starts empty automatically. Reuses the same leagues.id/invite code.
CREATE OR REPLACE FUNCTION nsv_start_new_season(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_is_commissioner       boolean;
  v_prev_season           int;
  v_new_season            int;
  v_pick_mode             text;
  v_result_mode           text;
  v_lives_allowed         int;
  v_pick_lock_mode        text;
  v_spread_lock_mode      text;
  v_continue_to_playoffs  boolean;
  v_reset_teams_for_playoffs boolean;
BEGIN
  SELECT (commissioner_id = auth.uid()), current_season INTO v_is_commissioner, v_prev_season
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can start a new season';
  END IF;

  v_new_season := v_prev_season + 1;

  SELECT pick_mode, result_mode, lives_allowed, pick_lock_mode, spread_lock_mode, continue_to_playoffs, reset_teams_for_playoffs
    INTO v_pick_mode, v_result_mode, v_lives_allowed, v_pick_lock_mode, v_spread_lock_mode, v_continue_to_playoffs, v_reset_teams_for_playoffs
  FROM nsv_leagues WHERE league_id = p_league_id AND season = v_prev_season;

  INSERT INTO nsv_leagues (league_id, season, pick_mode, result_mode, lives_allowed, pick_lock_mode, spread_lock_mode, continue_to_playoffs, reset_teams_for_playoffs)
  VALUES (p_league_id, v_new_season, COALESCE(v_pick_mode, 'straight_up'), COALESCE(v_result_mode, 'survive_on_win'),
          COALESCE(v_lives_allowed, 0), COALESCE(v_pick_lock_mode, 'per_game'),
          COALESCE(v_spread_lock_mode, 'week_reveal'), COALESCE(v_continue_to_playoffs, false), COALESCE(v_reset_teams_for_playoffs, false))
  ON CONFLICT (league_id, season) DO NOTHING;

  UPDATE leagues SET current_season = v_new_season, status = 'active' WHERE id = p_league_id;
END;
$$;
GRANT EXECUTE ON FUNCTION nsv_start_new_season(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 7. REALTIME
-- ------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nsv_picks;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE nsv_status;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;


-- ------------------------------------------------------------
-- 8. JOIN CUTOFF — no new members once the league's own first game
-- has kicked off. Same rationale/shape as NFL Weekly Pick'em's
-- SECTION 10, reading the shared nwpe_games via nsv_get_slate_unchecked.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION nsv_get_slate_unchecked(p_league_id uuid, p_season int, p_week int DEFAULT NULL)
RETURNS SETOF nwpe_games
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_league nsv_leagues%ROWTYPE;
BEGIN
  SELECT * INTO v_league FROM nsv_leagues WHERE league_id = p_league_id AND season = p_season;
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
GRANT EXECUTE ON FUNCTION nsv_get_slate_unchecked(uuid, int, int) TO service_role;

CREATE OR REPLACE FUNCTION nsv_enforce_join_cutoff() RETURNS trigger
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
  IF v_game_type IS DISTINCT FROM 'nfl-survivor' THEN
    RETURN NEW;
  END IF;

  SELECT MIN(kickoff_at) INTO v_first_kickoff FROM nsv_get_slate_unchecked(NEW.league_id, v_season);
  IF v_first_kickoff IS NOT NULL AND now() >= v_first_kickoff - interval '5 minutes' THEN
    RAISE EXCEPTION 'This league''s first game has already kicked off — new members can no longer join.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS nsv_join_cutoff ON league_members;
CREATE TRIGGER nsv_join_cutoff
  BEFORE INSERT ON league_members
  FOR EACH ROW
  EXECUTE FUNCTION nsv_enforce_join_cutoff();


-- ------------------------------------------------------------
-- 9. GRADING + REMINDER SCHEDULING (pg_cron + pg_net)
--
-- No games-sync cron here (see file header) — nsv_recalculate_all_status
-- needs to run on the SAME cadence NFL Weekly Pick'em's sync already
-- does, right after nwpe_games/nwpe_game_spread_locks refresh, so it's
-- called directly from nwpe-sync-games/index.ts (one extra RPC call
-- at the end of that function) rather than getting its own cron entry
-- here. See the wiring note added to that file when this module ships.
--
-- Pick reminders DO need their own cron, since nsv-send-pick-reminders
-- is a separate edge function with its own dedup log
-- (nsv_reminder_log) and its own "skip eliminated members" filter.
--
-- NOTE: do not run this until nsv-send-pick-reminders has been
-- deployed and smoke-tested.
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net  WITH SCHEMA extensions;

SELECT cron.schedule(
  'nsv-send-pick-reminders-cron',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://rjtlolzdwmrhctdatekj.supabase.co/functions/v1/nsv-send-pick-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'fcp_service_role_key')
    ),
    body := '{}'::jsonb
  )
  WHERE current_date BETWEEN DATE '2026-08-25' AND DATE '2027-02-15';
  $$
);
