-- ============================================================
-- CFB Bowl Season Pick 'Em — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE / ON CONFLICT)
--
-- Assumes the shared `leagues`, `league_members`, `profiles` tables
-- and the `is_league_member(uuid)` helper already exist (see
-- soccer/world-cup-bracket-challenge/schema.sql), plus the shared
-- `join_league_by_invite_code()` / `set_team_name()` RPCs.
--
-- Rules/timing/scoring source of truth: "Bowl Season Pick 'Em.txt"
-- in this same directory. Read that first if anything here looks
-- surprising — it isn't arbitrary.
--
-- Prefix: bpe_ (Bowl Pick 'Em). game_type = 'cfb-bowl-season-pick-em'.
-- ============================================================


-- ------------------------------------------------------------
-- 1. BPE GAMES
-- Global reference table — ONE shared slate every Bowl Pick 'Em
-- league picks from (no commissioner exclusions, per the rules
-- doc), same "singleton shared data" pattern as World Cup's
-- wc_matches. A row is created the moment ESPN reports two real
-- (non-TBD) competitors for a game — there are no placeholder
-- rows to pre-seed, which is what makes "pickable the instant
-- the matchup syncs" trivially true rather than something that
-- needs separate enforcement.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_games (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  season           int  NOT NULL DEFAULT extract(year from now())::int,
  espn_event_id    text NOT NULL,
  tier             text NOT NULL CHECK (tier IN ('bowl', 'cfp_r1', 'cfp_qf', 'cfp_sf', 'cfp_championship')),
  bowl_name        text NOT NULL,
  home_team        text NOT NULL,
  away_team        text NOT NULL,
  home_team_logo   text,
  away_team_logo   text,
  favorite_team    text,                  -- one of home_team/away_team, or NULL if pick'em/no line yet
  spread            numeric,              -- FROZEN at first sync — never updated by a routine re-sync
  kickoff_at       timestamptz,           -- nullable: a few bowls have teams set but kickoff TBD at first sync
  status           text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'live', 'final')),
  home_score       int,
  away_score       int,
  winner_team      text,                  -- straight-up winner, set once status = 'final'
  ats_winner_team  text,                  -- against-the-spread winner; NULL on a push
  matchup_version  int  NOT NULL DEFAULT 1,  -- bumped by bpe_apply_matchup_change() on a teams change
  synced_at        timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season, espn_event_id)
);

ALTER TABLE bpe_games ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Bowl games readable by all" ON bpe_games;
CREATE POLICY "Bowl games readable by all" ON bpe_games FOR SELECT USING (true);

GRANT SELECT ON bpe_games TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON bpe_games TO service_role;

-- True once a game is finished, or its kickoff-minus-5-minutes lock has
-- passed. A game with no kickoff_at yet (straggler bowl) is never locked
-- by time — only by going final, which can't happen without a kickoff
-- anyway, so this is safe as written. Computed inline rather than off a
-- stored `lock_at` column — `timestamptz - interval` is STABLE, not
-- IMMUTABLE, in Postgres, so it can't back a GENERATED column.
CREATE OR REPLACE FUNCTION bpe_is_game_locked(p_game_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT status = 'final' OR (kickoff_at IS NOT NULL AND now() >= kickoff_at - interval '5 minutes')
     FROM bpe_games WHERE id = p_game_id),
    false
  );
$$;
GRANT EXECUTE ON FUNCTION bpe_is_game_locked(uuid) TO anon, authenticated;


-- ------------------------------------------------------------
-- 2. BPE LEAGUES
-- One row per league PER SEASON — a league is reused year over
-- year (same leagues.id, same invite code) via bpe_start_new_season(),
-- with each season's settings/history kept as its own row, same
-- widened-PK pattern fcp_leagues uses for the same reason: keep
-- prior seasons' final standings permanently browsable.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_leagues (
  league_id     uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season        int  NOT NULL DEFAULT extract(year from now())::int,
  pick_mode     text NOT NULL DEFAULT 'straight_up' CHECK (pick_mode IN ('straight_up', 'spread')),
  scoring_mode  text NOT NULL DEFAULT 'flat' CHECK (scoring_mode IN ('flat', 'confidence')),
  created_at    timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season)
);

ALTER TABLE bpe_leagues ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view bpe league" ON bpe_leagues;
CREATE POLICY "League members can view bpe league" ON bpe_leagues FOR SELECT
  USING (is_league_member(league_id));

DROP POLICY IF EXISTS "Commissioner can insert bpe league" ON bpe_leagues;
CREATE POLICY "Commissioner can insert bpe league" ON bpe_leagues FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM leagues WHERE id = bpe_leagues.league_id AND commissioner_id = auth.uid()
  ));
-- Deliberately no direct UPDATE policy — every post-creation change to a
-- season's settings goes through bpe_update_league_settings(), which can
-- reject the change once picks already exist. A raw UPDATE policy can't
-- express that guard.

GRANT SELECT, INSERT ON bpe_leagues TO authenticated;


-- ------------------------------------------------------------
-- 3. BPE PICKS
-- The lock-gated-visibility table: your own picks are always
-- visible to you; other members' picks on a given game only
-- become visible once THAT SPECIFIC GAME locks. This is the one
-- genuinely new RLS shape in this codebase — every other module's
-- SELECT policy is plain membership, not conditional on another
-- table's timestamp.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_picks (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id          uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season             int  NOT NULL,
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id            uuid NOT NULL REFERENCES bpe_games(id) ON DELETE CASCADE,
  picked_team        text NOT NULL,   -- must equal bpe_games.home_team or .away_team — checked in bpe_submit_pick
  confidence_points  int,             -- NULL in flat mode; wave-scoped value (1-39 / 8-32 / 13,27 / 20) in confidence mode
  submitted_at       timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now(),
  UNIQUE (league_id, season, user_id, game_id)
);

ALTER TABLE bpe_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Own picks always visible; others after game locks" ON bpe_picks;
CREATE POLICY "Own picks always visible; others after game locks" ON bpe_picks FOR SELECT
  USING (
    user_id = auth.uid()
    OR (is_league_member(bpe_picks.league_id) AND bpe_is_game_locked(bpe_picks.game_id))
  );
-- No direct INSERT/UPDATE/DELETE policy — all writes go through
-- bpe_submit_pick() / bpe_clear_pick(), which is what enforces the
-- lock/team-validity/confidence-uniqueness rules.

GRANT SELECT ON bpe_picks TO authenticated;


-- ------------------------------------------------------------
-- 4. BPE TIEBREAKERS
-- One combined-score guess per user per league per season for
-- the National Championship game. Independent of the Championship
-- pick itself — you don't need to know the matchup to guess a
-- total, so this can be submitted any time before its own lock.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_tiebreakers (
  league_id           uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season              int  NOT NULL,
  user_id             uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  guess_total_points  int  NOT NULL CHECK (guess_total_points BETWEEN 0 AND 150),
  updated_at          timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, user_id)
);

ALTER TABLE bpe_tiebreakers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view tiebreakers" ON bpe_tiebreakers;
CREATE POLICY "League members can view tiebreakers" ON bpe_tiebreakers FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON bpe_tiebreakers TO authenticated;


-- ------------------------------------------------------------
-- 5. BPE SCORES
-- Cached, wave-bucketed (bowls+CFP-R1 combined, then QF/SF/
-- Championship each their own bucket) — matches the confidence
-- scoring waves in the rules doc AND the dashboard's 4-box
-- standings breakdown exactly. Recomputed by bpe_recalculate_scores().
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_scores (
  league_id      uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  season         int  NOT NULL,
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  wave1_points   int  NOT NULL DEFAULT 0,  -- bowls + CFP Round 1
  wave2_points   int  NOT NULL DEFAULT 0,  -- CFP Quarterfinal
  wave3_points   int  NOT NULL DEFAULT 0,  -- CFP Semifinal
  wave4_points   int  NOT NULL DEFAULT 0,  -- CFP Championship
  total_points   int  GENERATED ALWAYS AS (wave1_points + wave2_points + wave3_points + wave4_points) STORED,
  wins           int  NOT NULL DEFAULT 0,
  losses         int  NOT NULL DEFAULT 0,
  last_updated   timestamptz DEFAULT now(),
  PRIMARY KEY (league_id, season, user_id)
);

ALTER TABLE bpe_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "League members can view scores" ON bpe_scores;
CREATE POLICY "League members can view scores" ON bpe_scores FOR SELECT
  USING (is_league_member(league_id));

GRANT SELECT ON bpe_scores TO authenticated;
GRANT SELECT, INSERT, UPDATE ON bpe_scores TO service_role;


-- ------------------------------------------------------------
-- 6. BPE NOTIFY SIGNUPS
-- "Email me once all bowls are set" — per USER per SEASON, not
-- per league. bpe_games is one shared season-wide table, so this
-- is one global event; scoping it per-league would email someone
-- in 3 leagues 3 times for the same thing.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_notify_signups (
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  season       int  NOT NULL,
  opted_in_at  timestamptz DEFAULT now(),
  notified_at  timestamptz,
  PRIMARY KEY (user_id, season)
);

ALTER TABLE bpe_notify_signups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own signup" ON bpe_notify_signups;
CREATE POLICY "Users can view their own signup" ON bpe_notify_signups FOR SELECT
  USING (user_id = auth.uid());

GRANT SELECT ON bpe_notify_signups TO authenticated;
GRANT SELECT, UPDATE ON bpe_notify_signups TO service_role;


-- ------------------------------------------------------------
-- 7. BPE SEASON META
-- So "all bowls are set" is detectable without hardcoding 46
-- into application code (the real number varies slightly year
-- to year — 2026-27 is tentatively 46 including CFP).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bpe_season_meta (
  season               int PRIMARY KEY,
  expected_game_count  int NOT NULL DEFAULT 46,
  all_bowls_set_at     timestamptz
);

ALTER TABLE bpe_season_meta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Season meta readable by all" ON bpe_season_meta;
CREATE POLICY "Season meta readable by all" ON bpe_season_meta FOR SELECT USING (true);

GRANT SELECT ON bpe_season_meta TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON bpe_season_meta TO service_role;


-- ------------------------------------------------------------
-- 8. RPCs
-- ------------------------------------------------------------

-- bpe_submit_pick: the main write path for picks/tab. Validates
-- membership, lock state, team validity, and — in confidence mode —
-- the wave-appropriate value range plus per-user-per-wave uniqueness.
-- Uniqueness is enforced via a displacement swap rather than a hard
-- UNIQUE constraint: reassigning game A to the number game B already
-- holds just gives B whatever A's old number was, instead of failing.
-- Standard drag-to-reorder semantics.
CREATE OR REPLACE FUNCTION bpe_submit_pick(
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
  v_game           bpe_games%ROWTYPE;
  v_wave           text;
  v_conf           int;
  v_prev_conf      int;
  v_swap_game_id   uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  SELECT * INTO v_game FROM bpe_games WHERE id = p_game_id;
  IF v_game.id IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;
  IF bpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  IF p_picked_team NOT IN (v_game.home_team, v_game.away_team) THEN
    RAISE EXCEPTION 'Invalid team for this game';
  END IF;

  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  SELECT scoring_mode INTO v_scoring_mode FROM bpe_leagues
    WHERE league_id = p_league_id AND season = v_season;
  IF v_scoring_mode IS NULL THEN
    RAISE EXCEPTION 'League is not configured for the current season';
  END IF;

  v_wave := CASE v_game.tier
    WHEN 'bowl' THEN 'w1' WHEN 'cfp_r1' THEN 'w1'
    WHEN 'cfp_qf' THEN 'w2' WHEN 'cfp_sf' THEN 'w3'
    WHEN 'cfp_championship' THEN 'w4'
  END;

  v_conf := p_confidence_points;

  IF v_scoring_mode = 'confidence' THEN
    IF v_wave = 'w1' AND (v_conf IS NULL OR v_conf < 1 OR v_conf > 39) THEN
      RAISE EXCEPTION 'Confidence must be between 1 and 39 for this game';
    ELSIF v_wave = 'w2' AND v_conf NOT IN (8, 16, 24, 32) THEN
      RAISE EXCEPTION 'Invalid confidence value for a Quarterfinal pick';
    ELSIF v_wave = 'w3' AND v_conf NOT IN (13, 27) THEN
      RAISE EXCEPTION 'Invalid confidence value for a Semifinal pick';
    ELSIF v_wave = 'w4' THEN
      v_conf := 20; -- forced — a single game has nothing to rank against
    END IF;

    SELECT confidence_points INTO v_prev_conf
    FROM bpe_picks
    WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = p_game_id;

    SELECT p2.game_id INTO v_swap_game_id
    FROM bpe_picks p2
    JOIN bpe_games g2 ON g2.id = p2.game_id
    WHERE p2.league_id = p_league_id AND p2.season = v_season AND p2.user_id = auth.uid()
      AND p2.game_id != p_game_id AND p2.confidence_points = v_conf
      AND (CASE g2.tier
             WHEN 'bowl' THEN 'w1' WHEN 'cfp_r1' THEN 'w1'
             WHEN 'cfp_qf' THEN 'w2' WHEN 'cfp_sf' THEN 'w3'
             WHEN 'cfp_championship' THEN 'w4'
           END) = v_wave
    LIMIT 1;

    IF v_swap_game_id IS NOT NULL THEN
      UPDATE bpe_picks SET confidence_points = v_prev_conf, updated_at = now()
      WHERE league_id = p_league_id AND season = v_season AND user_id = auth.uid() AND game_id = v_swap_game_id;
    END IF;
  ELSE
    v_conf := NULL; -- flat mode never stores a confidence value
  END IF;

  INSERT INTO bpe_picks (league_id, season, user_id, game_id, picked_team, confidence_points, updated_at)
  VALUES (p_league_id, v_season, auth.uid(), p_game_id, p_picked_team, v_conf, now())
  ON CONFLICT (league_id, season, user_id, game_id)
  DO UPDATE SET picked_team = EXCLUDED.picked_team, confidence_points = EXCLUDED.confidence_points, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_submit_pick(uuid, uuid, text, int) TO authenticated;


-- bpe_clear_pick: undo a pick, only while its game is still open.
CREATE OR REPLACE FUNCTION bpe_clear_pick(p_league_id uuid, p_game_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF bpe_is_game_locked(p_game_id) THEN
    RAISE EXCEPTION 'This game has already locked';
  END IF;
  DELETE FROM bpe_picks
  WHERE league_id = p_league_id AND user_id = auth.uid() AND game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_clear_pick(uuid, uuid) TO authenticated;


-- bpe_submit_tiebreaker_guess: locks at the Championship game's own
-- kickoff-minus-5-minutes, same rule as every other pick. If the
-- Championship game hasn't synced yet, there's nothing to lock
-- against, so the guess is freely editable.
CREATE OR REPLACE FUNCTION bpe_submit_tiebreaker_guess(p_league_id uuid, p_guess int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season int;
  v_champ_game_id uuid;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;
  SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;

  SELECT id INTO v_champ_game_id FROM bpe_games
  WHERE season = v_season AND tier = 'cfp_championship'
  LIMIT 1;

  IF v_champ_game_id IS NOT NULL AND bpe_is_game_locked(v_champ_game_id) THEN
    RAISE EXCEPTION 'Tiebreaker guesses are locked';
  END IF;

  INSERT INTO bpe_tiebreakers (league_id, season, user_id, guess_total_points, updated_at)
  VALUES (p_league_id, v_season, auth.uid(), p_guess, now())
  ON CONFLICT (league_id, season, user_id)
  DO UPDATE SET guess_total_points = EXCLUDED.guess_total_points, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_submit_tiebreaker_guess(uuid, int) TO authenticated;


-- bpe_update_league_settings: the only write path to bpe_leagues after
-- creation (there's deliberately no direct UPDATE RLS policy). Refuses
-- the change once any pick exists for the league this season, since
-- flipping pick_mode/scoring_mode mid-season would corrupt standings.
CREATE OR REPLACE FUNCTION bpe_update_league_settings(
  p_league_id uuid,
  p_pick_mode text,
  p_scoring_mode text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_season int;
  v_is_commissioner boolean;
  v_pick_count int;
BEGIN
  SELECT current_season, (commissioner_id = auth.uid())
    INTO v_season, v_is_commissioner
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can change league settings';
  END IF;

  SELECT count(*) INTO v_pick_count FROM bpe_picks
  WHERE league_id = p_league_id AND season = v_season;

  IF v_pick_count > 0 THEN
    RAISE EXCEPTION 'Cannot change pick/scoring mode after picks have been made this season';
  END IF;

  UPDATE bpe_leagues SET pick_mode = p_pick_mode, scoring_mode = p_scoring_mode
  WHERE league_id = p_league_id AND season = v_season;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_update_league_settings(uuid, text, text) TO authenticated;


-- bpe_opt_in_bowls_set_notification: idempotent per user/season.
CREATE OR REPLACE FUNCTION bpe_opt_in_bowls_set_notification(p_season int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM league_members lm
    JOIN leagues l ON l.id = lm.league_id
    WHERE lm.user_id = auth.uid() AND l.game_type = 'cfb-bowl-season-pick-em' AND l.current_season = p_season
  ) THEN
    RAISE EXCEPTION 'Not a member of any Bowl Pick ''Em league this season';
  END IF;

  INSERT INTO bpe_notify_signups (user_id, season)
  VALUES (auth.uid(), p_season)
  ON CONFLICT (user_id, season) DO NOTHING;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_opt_in_bowls_set_notification(int) TO authenticated;


-- bpe_recalculate_scores: recomputes one league+season's bpe_scores from
-- scratch off bpe_picks + bpe_games. Correctness (straight-up vs ATS) and
-- point values (flat tier table vs confidence_points) branch on the
-- league's own pick_mode/scoring_mode. A push (ats_winner_team IS NULL
-- under spread mode) scores 0 and doesn't count as a win or a loss.
CREATE OR REPLACE FUNCTION bpe_recalculate_scores(p_league_id uuid, p_season int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_pick_mode text;
  v_scoring_mode text;
BEGIN
  SELECT pick_mode, scoring_mode INTO v_pick_mode, v_scoring_mode
  FROM bpe_leagues WHERE league_id = p_league_id AND season = p_season;

  IF v_pick_mode IS NULL THEN
    RETURN; -- no bpe_leagues row for this league/season yet — nothing to score
  END IF;

  INSERT INTO bpe_scores (league_id, season, user_id, wave1_points, wave2_points, wave3_points, wave4_points, wins, losses, last_updated)
  SELECT
    p_league_id, p_season, m.user_id,
    COALESCE(SUM(calc.pts) FILTER (WHERE g.tier IN ('bowl', 'cfp_r1')), 0),
    COALESCE(SUM(calc.pts) FILTER (WHERE g.tier = 'cfp_qf'), 0),
    COALESCE(SUM(calc.pts) FILTER (WHERE g.tier = 'cfp_sf'), 0),
    COALESCE(SUM(calc.pts) FILTER (WHERE g.tier = 'cfp_championship'), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_win), 0),
    COALESCE(SUM(1) FILTER (WHERE calc.is_loss), 0),
    now()
  FROM league_members m
  LEFT JOIN bpe_picks p ON p.league_id = p_league_id AND p.season = p_season AND p.user_id = m.user_id
  LEFT JOIN bpe_games g ON g.id = p.game_id AND g.status = 'final'
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
        ELSE CASE g.tier
          WHEN 'bowl' THEN 1 WHEN 'cfp_r1' THEN 2 WHEN 'cfp_qf' THEN 3
          WHEN 'cfp_sf' THEN 4 WHEN 'cfp_championship' THEN 5
        END
      END AS pts,
      chk.is_correct AS is_win,
      (g.id IS NOT NULL AND NOT (v_pick_mode = 'spread' AND g.ats_winner_team IS NULL) AND NOT chk.is_correct) AS is_loss
  ) calc ON true
  WHERE m.league_id = p_league_id
  GROUP BY m.user_id
  ON CONFLICT (league_id, season, user_id) DO UPDATE SET
    wave1_points = EXCLUDED.wave1_points, wave2_points = EXCLUDED.wave2_points,
    wave3_points = EXCLUDED.wave3_points, wave4_points = EXCLUDED.wave4_points,
    wins = EXCLUDED.wins, losses = EXCLUDED.losses, last_updated = now();
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_recalculate_scores(uuid, int) TO authenticated, service_role;


-- bpe_recalculate_all_scores: service_role only, called by the sync
-- function after every ESPN pull. Loops every active Bowl Pick 'Em
-- league's current season, and flips the league to 'completed' once
-- that season's championship game is final — mirrors
-- fcp_recalculate_all_scores() / _recalculate_all_league_scores().
CREATE OR REPLACE FUNCTION bpe_recalculate_all_scores()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_league record;
  v_champ_final boolean;
BEGIN
  FOR v_league IN
    SELECT id, current_season FROM leagues
    WHERE game_type = 'cfb-bowl-season-pick-em' AND status IN ('active', 'pending')
  LOOP
    PERFORM bpe_recalculate_scores(v_league.id, v_league.current_season);

    SELECT EXISTS (
      SELECT 1 FROM bpe_games
      WHERE season = v_league.current_season AND tier = 'cfp_championship' AND status = 'final'
    ) INTO v_champ_final;

    IF v_champ_final THEN
      UPDATE leagues SET status = 'completed' WHERE id = v_league.id AND status != 'completed';
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_recalculate_all_scores() TO service_role;


-- bpe_get_standings: defaults to the league's current season; a past
-- season can be passed explicitly for the history page. Ties broken by
-- closeness of the tiebreaker guess to the real combined championship
-- score (NULL/no-guess sorts last).
CREATE OR REPLACE FUNCTION bpe_get_standings(p_league_id uuid, p_season int DEFAULT NULL)
RETURNS TABLE (
  user_id uuid,
  team_name text,
  total_points int,
  wave1_points int,
  wave2_points int,
  wave3_points int,
  wave4_points int,
  wins int,
  losses int,
  tiebreaker_guess int
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_season int;
  v_actual_total int;
BEGIN
  IF NOT is_league_member(p_league_id) THEN
    RAISE EXCEPTION 'Not a member of this league';
  END IF;

  v_season := p_season;
  IF v_season IS NULL THEN
    SELECT current_season INTO v_season FROM leagues WHERE id = p_league_id;
  END IF;

  SELECT g.home_score + g.away_score INTO v_actual_total
  FROM bpe_games g WHERE g.season = v_season AND g.tier = 'cfp_championship' AND g.status = 'final';

  RETURN QUERY
  SELECT
    m.user_id, m.team_name,
    COALESCE(s.total_points, 0), COALESCE(s.wave1_points, 0), COALESCE(s.wave2_points, 0),
    COALESCE(s.wave3_points, 0), COALESCE(s.wave4_points, 0),
    COALESCE(s.wins, 0), COALESCE(s.losses, 0), tb.guess_total_points
  FROM league_members m
  LEFT JOIN bpe_scores s ON s.league_id = p_league_id AND s.season = v_season AND s.user_id = m.user_id
  LEFT JOIN bpe_tiebreakers tb ON tb.league_id = p_league_id AND tb.season = v_season AND tb.user_id = m.user_id
  WHERE m.league_id = p_league_id
  ORDER BY
    COALESCE(s.total_points, 0) DESC,
    CASE WHEN v_actual_total IS NULL OR tb.guess_total_points IS NULL THEN 1 ELSE 0 END,
    ABS(COALESCE(tb.guess_total_points, 0) - COALESCE(v_actual_total, 0)) ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_get_standings(uuid, int) TO authenticated;


-- bpe_start_new_season: commissioner-only. Much simpler than
-- fcp_start_new_season() — no draft/roster to carry forward, since this
-- is a pure pick'em. Just opens a new bpe_leagues row (copying forward
-- the prior settings as defaults) and advances the shared season pointer.
-- Reuses the same leagues.id / invite code, matching the root dashboard's
-- existing "Reactivate" pattern for other season-aware modules.
CREATE OR REPLACE FUNCTION bpe_start_new_season(p_league_id uuid)
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
BEGIN
  SELECT (commissioner_id = auth.uid()), current_season INTO v_is_commissioner, v_prev_season
  FROM leagues WHERE id = p_league_id;

  IF NOT v_is_commissioner THEN
    RAISE EXCEPTION 'Only the commissioner can start a new season';
  END IF;

  v_new_season := v_prev_season + 1;

  SELECT pick_mode, scoring_mode INTO v_pick_mode, v_scoring_mode
  FROM bpe_leagues WHERE league_id = p_league_id AND season = v_prev_season;

  INSERT INTO bpe_leagues (league_id, season, pick_mode, scoring_mode)
  VALUES (p_league_id, v_new_season, COALESCE(v_pick_mode, 'straight_up'), COALESCE(v_scoring_mode, 'flat'))
  ON CONFLICT (league_id, season) DO NOTHING;

  UPDATE leagues SET current_season = v_new_season, status = 'active' WHERE id = p_league_id;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_start_new_season(uuid) TO authenticated;


-- bpe_apply_matchup_change: service_role only, called by the sync
-- function ONLY when an already-known game's teams actually change
-- (opt-out / vacated bid) — never on a routine score/status refresh.
-- Clearing existing picks here (rather than leaving them attached to a
-- team that's no longer playing) is what requirement drives the "auto
-- clear + email everyone" rule in the rules doc; the email itself is
-- sent by the calling edge function, not this RPC.
CREATE OR REPLACE FUNCTION bpe_apply_matchup_change(
  p_game_id uuid,
  p_home_team text,
  p_away_team text,
  p_spread numeric,
  p_kickoff_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE bpe_games SET
    home_team = p_home_team, away_team = p_away_team,
    spread = p_spread, kickoff_at = p_kickoff_at,
    matchup_version = matchup_version + 1, updated_at = now()
  WHERE id = p_game_id;

  DELETE FROM bpe_picks WHERE game_id = p_game_id;
END;
$$;
GRANT EXECUTE ON FUNCTION bpe_apply_matchup_change(uuid, text, text, numeric, timestamptz) TO service_role;


-- ------------------------------------------------------------
-- 9. REALTIME
-- ------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE bpe_games;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE bpe_picks;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE bpe_scores;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;
