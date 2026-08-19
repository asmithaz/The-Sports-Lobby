-- ============================================================
-- World Cup Bracket Challenge — Supabase Schema
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / ON CONFLICT DO NOTHING)
-- ============================================================

-- ============================================================
-- SCORING REFERENCE
-- ============================================================
-- GROUP STAGE ONLY mode:
--   Picked team wins their group (actual group_finish = 1):   20 pts
--   Picked team finishes 2nd (actual group_finish = 2):       10 pts
--   Next 8 pick correct (advanced_as_third = true):            5 pts
--   User picks 2 teams per group to advance + up to 8 Next 8 candidates.
--   Points are awarded based on how the team actually finishes — no need
--   for the user to specify 1st vs 2nd.
--   Round of 32 winner correct:    40 pts
--   Round of 16 winner correct:    80 pts
--   Quarterfinal winner correct:  160 pts
--   Semifinal winner correct:     320 pts
--   3rd Place winner correct:     160 pts  (same as QF — single game but narrows
--                                            naturally since both SF losers must be right)
--   Final winner correct:         640 pts
--
-- KNOCKOUT ONLY mode:
--   Round of 32 winner correct:    10 pts
--   Round of 16 winner correct:    20 pts
--   Quarterfinal winner correct:   40 pts
--   Semifinal winner correct:      80 pts
--   3rd Place winner correct:      40 pts  (same as QF)
--   Final winner correct:         160 pts
--
-- GROUP AND REPICK mode:
--   Picked team wins their group:  20 pts
--   Picked team finishes 2nd:      10 pts
--   Next 8 pick correct:            5 pts
--   Round of 32 winner correct:    10 pts
--   Round of 16 winner correct:    20 pts
--   Quarterfinal winner correct:   40 pts
--   Semifinal winner correct:      80 pts
--   3rd Place winner correct:      40 pts  (same as QF)
--   Final winner correct:         160 pts
-- ============================================================


-- ------------------------------------------------------------
-- 1. LEAGUES (may already exist from setup form — IF NOT EXISTS is safe)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leagues (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text        NOT NULL,
  visibility      text        NOT NULL CHECK (visibility IN ('public', 'private')),
  league_type     text        NOT NULL CHECK (league_type IN ('group-stage-only', 'knockout-only', 'group-and-repick')),
  commissioner_id uuid        REFERENCES auth.users(id) ON DELETE CASCADE,
  invite_code     text        UNIQUE NOT NULL,
  game_type       text        NOT NULL DEFAULT 'world-cup-bracket-challenge',
  password_hash   text,
  created_at      timestamptz DEFAULT now()
);


-- ------------------------------------------------------------
-- 2. LEAGUE MEMBERS
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS league_members (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id  uuid        NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  joined_at  timestamptz DEFAULT now(),
  UNIQUE(league_id, user_id)
);

-- Per-league team name (distinct from profiles.display_name, which is
-- global). Added here, ahead of get_league_leaderboard() in Section 13,
-- so a top-to-bottom re-run of this file on a fresh environment doesn't
-- reference a column that doesn't exist yet. The write-side RPC
-- (set_team_name) lives in Section 15, at the end of the file, since it
-- depends on is_league_member() from soccer/world-cup-draft/schema.sql.
ALTER TABLE league_members ADD COLUMN IF NOT EXISTS team_name text;

-- Auto-add commissioner as a member when a league is created
CREATE OR REPLACE FUNCTION add_commissioner_as_member()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO league_members (league_id, user_id)
  VALUES (NEW.id, NEW.commissioner_id)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_league_created ON leagues;
CREATE TRIGGER on_league_created
  AFTER INSERT ON leagues
  FOR EACH ROW EXECUTE FUNCTION add_commissioner_as_member();


-- ------------------------------------------------------------
-- 3. TEAMS (static seed data — 48 teams across 12 groups)
--
-- IMPORTANT: Verify group assignments against the official 2026 WC draw
-- before going live. Update with:
--   UPDATE wc_teams SET group_letter = 'X' WHERE id = 'YYY';
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc_teams (
  id                      text    PRIMARY KEY,  -- e.g. 'USA', 'BRA'
  name                    text    NOT NULL,
  group_letter            text    NOT NULL CHECK (group_letter IN ('A','B','C','D','E','F','G','H','I','J','K','L')),
  flag_emoji              text,
  -- Set by admin as tournament progresses:
  group_finish            int,    -- 1, 2, 3, or 4 (actual final group position)
  advanced_as_third       boolean DEFAULT false,  -- true if this team was one of the 8 best 3rd-place teams that advanced
  eliminated              boolean DEFAULT false,
  elimination_round       text    CHECK (elimination_round IN ('group','r32','r16','qf','sf','final'))
  -- elimination_round = null means the team is the champion
);

INSERT INTO wc_teams (id, name, group_letter, flag_emoji) VALUES
  -- Group A
  ('MEX', 'Mexico',          'A', '🇲🇽'),
  ('ZAF', 'South Africa',    'A', '🇿🇦'),
  ('KOR', 'South Korea',     'A', '🇰🇷'),
  ('CZE', 'Czechia',         'A', '🇨🇿'),
  -- Group B
  ('CAN', 'Canada',          'B', '🇨🇦'),
  ('BIH', 'Bosnia & Herz.',  'B', '🇧🇦'),
  ('QAT', 'Qatar',           'B', '🇶🇦'),
  ('SUI', 'Switzerland',     'B', '🇨🇭'),
  -- Group C
  ('BRA', 'Brazil',          'C', '🇧🇷'),
  ('MOR', 'Morocco',         'C', '🇲🇦'),
  ('HTI', 'Haiti',           'C', '🇭🇹'),
  ('SCO', 'Scotland',        'C', 'sc'),
  -- Group D
  ('USA', 'United States',   'D', '🇺🇸'),
  ('PAR', 'Paraguay',        'D', '🇵🇾'),
  ('AUS', 'Australia',       'D', '🇦🇺'),
  ('TUR', 'Turkey',          'D', '🇹🇷'),
  -- Group E
  ('GER', 'Germany',         'E', '🇩🇪'),
  ('CUR', 'Curaçao',         'E', 'cu'),
  ('CIV', 'Ivory Coast',     'E', '🇨🇮'),
  ('ECU', 'Ecuador',         'E', '🇪🇨'),
  -- Group F
  ('NED', 'Netherlands',     'F', '🇳🇱'),
  ('JPN', 'Japan',           'F', '🇯🇵'),
  ('SWE', 'Sweden',          'F', '🇸🇪'),
  ('TUN', 'Tunisia',         'F', '🇹🇳'),
  -- Group G
  ('BEL', 'Belgium',         'G', '🇧🇪'),
  ('EGY', 'Egypt',           'G', '🇪🇬'),
  ('IRN', 'Iran',            'G', '🇮🇷'),
  ('NZL', 'New Zealand',     'G', '🇳🇿'),
  -- Group H
  ('ESP', 'Spain',           'H', '🇪🇸'),
  ('CPV', 'Cape Verde',      'H', '🇨🇻'),
  ('KSA', 'Saudi Arabia',    'H', '🇸🇦'),
  ('URU', 'Uruguay',         'H', '🇺🇾'),
  -- Group I
  ('FRA', 'France',          'I', '🇫🇷'),
  ('SEN', 'Senegal',         'I', '🇸🇳'),
  ('IRQ', 'Iraq',            'I', '🇮🇶'),
  ('NOR', 'Norway',          'I', '🇳🇴'),
  -- Group J
  ('ARG', 'Argentina',       'J', '🇦🇷'),
  ('ALG', 'Algeria',         'J', '🇩🇿'),
  ('AUT', 'Austria',         'J', '🇦🇹'),
  ('JOR', 'Jordan',          'J', '🇯🇴'),  
  -- Group K
  ('POR','Portugal',         'K', '🇵🇹'),
  ('CGO', 'DR Congo',        'K', '🇨🇩'),
  ('UZB', 'Uzbekistan',      'K', '🇺🇿'),
  ('COL', 'Colombia',        'K', '🇨🇴'),
  -- Group L
  ('ENG', 'England',         'L', '🇬🇧'),
  ('CRO', 'Croatia',         'L', '🇭🇷'),
  ('GHA', 'Ghana',           'L', '🇬🇭'),
  ('PAN', 'Panama',          'L', '🇵🇦')
ON CONFLICT (id) DO NOTHING;


-- ------------------------------------------------------------
-- 4. MATCHES (admin updates scores + winner as tournament progresses)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc_matches (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  round        text        NOT NULL CHECK (round IN ('group','r32','r16','qf','sf','final')),
  match_number int         NOT NULL,   -- position in round (1-indexed)
  group_letter text,                   -- only set for group stage matches
  home_team_id text        REFERENCES wc_teams(id),
  away_team_id text        REFERENCES wc_teams(id),
  home_score   int,
  away_score   int,
  winner_id    text        REFERENCES wc_teams(id),
  match_date   timestamptz,
  status       text        DEFAULT 'scheduled' CHECK (status IN ('scheduled','live','completed')),
  UNIQUE(round, match_number)
);


-- ------------------------------------------------------------
-- 5. GROUP STAGE PICKS
-- User picks 2 teams per group to advance (no 1st/2nd distinction).
-- For up to 8 groups, user also picks a Next 8 candidate (3rd place team).
-- Scoring (applied for 'group-stage-only' and 'group-and-repick'):
--   advance_1 or advance_2 team actually wins group (group_finish = 1):  20 pts
--   advance_1 or advance_2 team actually finishes 2nd (group_finish = 2): 10 pts
--   next_8 team has advanced_as_third = true:                              5 pts
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc_group_picks (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id    uuid        NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  group_letter text        NOT NULL,
  advance_1    text        REFERENCES wc_teams(id),   -- first team picked to advance
  advance_2    text        REFERENCES wc_teams(id),   -- second team picked to advance
  next_8       text        REFERENCES wc_teams(id),   -- optional Next 8 candidate (3rd place pick)
  submitted_at timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now(),
  UNIQUE(league_id, user_id, group_letter)
);


-- ------------------------------------------------------------
-- 6. KNOCKOUT BRACKET PICKS
-- One row per (league, user, round, match_number).
-- match_number is the bracket slot (1-indexed per round).
--
-- Points by round and league_type:
--   group-stage-only:  r32=40, r16=80,  qf=160, sf=320, final=640
--   knockout-only:     r32=10, r16=20,  qf=40,  sf=80,  final=160
--   group-and-repick:  r32=10, r16=20,  qf=40,  sf=80,  final=160
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc_bracket_picks (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id           uuid        NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id             uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  round               text        NOT NULL CHECK (round IN ('r32','r16','qf','sf','final')),
  match_number        int         NOT NULL,
  predicted_winner_id text        REFERENCES wc_teams(id),
  submitted_at        timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  UNIQUE(league_id, user_id, round, match_number)
);


-- ------------------------------------------------------------
-- 7. SCORES (cached — recalculate whenever wc_matches or wc_teams update)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc_scores (
  league_id          uuid NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  group_stage_points int  DEFAULT 0,
  knockout_points    int  DEFAULT 0,
  total_points       int  GENERATED ALWAYS AS (group_stage_points + knockout_points) STORED,
  last_updated       timestamptz DEFAULT now(),
  PRIMARY KEY(league_id, user_id)
);


-- ------------------------------------------------------------
-- 8. GRANTS
-- Tables created via SQL editor need explicit grants (unlike tables
-- made in the Supabase UI which get these automatically).
-- ------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON leagues          TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON league_members   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wc_group_picks   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wc_bracket_picks TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wc_scores        TO authenticated;

GRANT SELECT ON wc_teams   TO anon, authenticated;
GRANT SELECT ON wc_matches TO anon, authenticated;

-- service_role bypasses RLS but still needs table grants for the
-- FedEx Cup Playoffs fcp-draft-cron Edge Function, which reads league_members
-- and joins leagues(name) to build draft reminder emails.
GRANT SELECT ON leagues        TO service_role;
GRANT SELECT ON league_members TO service_role;

-- ------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- ------------------------------------------------------------
ALTER TABLE leagues          ENABLE ROW LEVEL SECURITY;
ALTER TABLE league_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE wc_teams         ENABLE ROW LEVEL SECURITY;
ALTER TABLE wc_matches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE wc_group_picks   ENABLE ROW LEVEL SECURITY;
ALTER TABLE wc_bracket_picks ENABLE ROW LEVEL SECURITY;
ALTER TABLE wc_scores        ENABLE ROW LEVEL SECURITY;

-- leagues
DROP POLICY IF EXISTS "Public leagues visible to all"          ON leagues;
DROP POLICY IF EXISTS "Private leagues visible to members"     ON leagues;
DROP POLICY IF EXISTS "Authenticated users can create leagues" ON leagues;
DROP POLICY IF EXISTS "Commissioner can update their league"   ON leagues;

CREATE POLICY "Public leagues visible to all"
  ON leagues FOR SELECT USING (visibility = 'public');

CREATE POLICY "Private leagues visible to members"
  ON leagues FOR SELECT USING (
    visibility = 'private' AND
    EXISTS (SELECT 1 FROM league_members WHERE league_id = leagues.id AND user_id = auth.uid())
  );

CREATE POLICY "Authenticated users can create leagues"
  ON leagues FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Commissioner can update their league"
  ON leagues FOR UPDATE USING (commissioner_id = auth.uid());

-- league_members
DROP POLICY IF EXISTS "Members can view their memberships"   ON league_members;
DROP POLICY IF EXISTS "Authenticated users can join leagues" ON league_members;

CREATE POLICY "Members can view their memberships"
  ON league_members FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Authenticated users can join leagues"
  ON league_members FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Enforce leagues.max_players regardless of entry point (the RPC above,
-- or a direct insert under the "Authenticated users can join leagues"
-- policy). RLS WITH CHECK can't see other rows' counts cheaply/atomically
-- across concurrent inserts, so this is done as a trigger instead.
CREATE OR REPLACE FUNCTION enforce_league_capacity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_max_players int;
BEGIN
  -- BEFORE INSERT fires even when ON CONFLICT DO NOTHING will no-op the
  -- row, so skip the check entirely for an already-existing member
  -- (e.g. re-clicking an invite link) rather than blocking their re-join.
  IF EXISTS (
    SELECT 1 FROM league_members
    WHERE league_id = NEW.league_id AND user_id = NEW.user_id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT max_players INTO v_max_players FROM leagues WHERE id = NEW.league_id;

  IF v_max_players IS NOT NULL
     AND (SELECT count(*) FROM league_members WHERE league_id = NEW.league_id) >= v_max_players
  THEN
    RAISE EXCEPTION 'This league is full';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_league_capacity_on_join ON league_members;
CREATE TRIGGER enforce_league_capacity_on_join
  BEFORE INSERT ON league_members
  FOR EACH ROW
  EXECUTE FUNCTION enforce_league_capacity();

-- wc_teams / wc_matches — public read-only
DROP POLICY IF EXISTS "Teams readable by all"   ON wc_teams;
DROP POLICY IF EXISTS "Matches readable by all" ON wc_matches;

CREATE POLICY "Teams readable by all"   ON wc_teams   FOR SELECT USING (true);
CREATE POLICY "Matches readable by all" ON wc_matches  FOR SELECT USING (true);

-- group picks
DROP POLICY IF EXISTS "Users manage own group picks"        ON wc_group_picks;
DROP POLICY IF EXISTS "League members can read group picks" ON wc_group_picks;

CREATE POLICY "Users manage own group picks"
  ON wc_group_picks FOR ALL USING (user_id = auth.uid());

CREATE POLICY "League members can read group picks"
  ON wc_group_picks FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wc_group_picks.league_id AND user_id = auth.uid())
  );

-- bracket picks
DROP POLICY IF EXISTS "Users manage own bracket picks"        ON wc_bracket_picks;
DROP POLICY IF EXISTS "League members can read bracket picks" ON wc_bracket_picks;

CREATE POLICY "Users manage own bracket picks"
  ON wc_bracket_picks FOR ALL USING (user_id = auth.uid());

CREATE POLICY "League members can read bracket picks"
  ON wc_bracket_picks FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wc_bracket_picks.league_id AND user_id = auth.uid())
  );

-- scores
DROP POLICY IF EXISTS "League members can read scores" ON wc_scores;

CREATE POLICY "League members can read scores"
  ON wc_scores FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wc_scores.league_id AND user_id = auth.uid())
  );


-- ------------------------------------------------------------
-- 10. SCHEMA MIGRATIONS
-- Run these after the initial schema to add score boxes,
-- 3rd-place match, and tiebreaker features.
-- ------------------------------------------------------------

-- Allow 'third' as a valid round in bracket picks
ALTER TABLE wc_bracket_picks
  DROP CONSTRAINT IF EXISTS wc_bracket_picks_round_check;

ALTER TABLE wc_bracket_picks
  ADD CONSTRAINT wc_bracket_picks_round_check
  CHECK (round IN ('r32','r16','qf','sf','final','third'));

-- Predicted scores per team slot
ALTER TABLE wc_bracket_picks
  ADD COLUMN IF NOT EXISTS predicted_score_1 int,
  ADD COLUMN IF NOT EXISTS predicted_score_2 int;

-- Tiebreaker picks (one row per league+user)
CREATE TABLE IF NOT EXISTS wc_bracket_tiebreakers (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  league_id       uuid        NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tb_final_goals  int,
  tb_third_goals  int,
  submitted_at    timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),
  UNIQUE(league_id, user_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON wc_bracket_tiebreakers TO authenticated;

ALTER TABLE wc_bracket_tiebreakers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own tiebreakers"        ON wc_bracket_tiebreakers;
DROP POLICY IF EXISTS "League members can read tiebreakers" ON wc_bracket_tiebreakers;

CREATE POLICY "Users manage own tiebreakers"
  ON wc_bracket_tiebreakers FOR ALL USING (user_id = auth.uid());

CREATE POLICY "League members can read tiebreakers"
  ON wc_bracket_tiebreakers FOR SELECT USING (
    EXISTS (SELECT 1 FROM league_members WHERE league_id = wc_bracket_tiebreakers.league_id AND user_id = auth.uid())
  );


-- ------------------------------------------------------------
-- 11. SCORING CALCULATION
-- Run this block after Section 10.
-- Scores are recalculated automatically via triggers whenever
-- an admin updates wc_matches.winner_id or wc_teams.group_finish.
-- Can also be called manually: SELECT calculate_league_scores('<league_id>');
-- ------------------------------------------------------------

-- Allow wc_matches to record the 3rd-place game
ALTER TABLE wc_matches
  DROP CONSTRAINT IF EXISTS wc_matches_round_check;

ALTER TABLE wc_matches
  ADD CONSTRAINT wc_matches_round_check
  CHECK (round IN ('group','r32','r16','qf','sf','final','third'));

-- ── Core function ─────────────────────────────────────────────────────────
-- Recalculates group-stage and knockout points for every member of one league
-- and upserts the results into wc_scores.
CREATE OR REPLACE FUNCTION calculate_league_scores(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_league_type text;
    v_user_id     uuid;
    v_group_pts   int;
    v_ko_pts      int;
BEGIN
    SELECT league_type INTO v_league_type
    FROM   leagues WHERE id = p_league_id;
    IF NOT FOUND THEN RETURN; END IF;

    FOR v_user_id IN
        SELECT user_id FROM league_members WHERE league_id = p_league_id
    LOOP
        -- ── Group stage points ───────────────────────────────────
        -- Applies to 'group-stage-only' and 'group-and-repick' leagues.
        -- advance_1 / advance_2 picks: 20 pts if team won group, 10 if 2nd.
        -- next_8 pick: 5 pts if that team advanced as a best-3rd-place side.
        v_group_pts := 0;

        IF v_league_type IN ('group-stage-only', 'group-and-repick') THEN
            SELECT COALESCE(SUM(pts), 0) INTO v_group_pts
            FROM (
                SELECT CASE t.group_finish WHEN 1 THEN 20 WHEN 2 THEN 10 ELSE 0 END AS pts
                FROM   wc_group_picks gp
                JOIN   wc_teams t ON t.id = gp.advance_1
                WHERE  gp.league_id = p_league_id AND gp.user_id = v_user_id
                  AND  gp.advance_1 IS NOT NULL AND t.group_finish IS NOT NULL

                UNION ALL

                SELECT CASE t.group_finish WHEN 1 THEN 20 WHEN 2 THEN 10 ELSE 0 END
                FROM   wc_group_picks gp
                JOIN   wc_teams t ON t.id = gp.advance_2
                WHERE  gp.league_id = p_league_id AND gp.user_id = v_user_id
                  AND  gp.advance_2 IS NOT NULL AND t.group_finish IS NOT NULL

                UNION ALL

                SELECT CASE WHEN t.advanced_as_third THEN 5 ELSE 0 END
                FROM   wc_group_picks gp
                JOIN   wc_teams t ON t.id = gp.next_8
                WHERE  gp.league_id = p_league_id AND gp.user_id = v_user_id
                  AND  gp.next_8 IS NOT NULL
            ) g;
        END IF;

        -- ── Knockout + 3rd-place points ──────────────────────────
        -- Points per correct winner pick, scaled by league type.
        --
        -- group-stage-only:   r32=40  r16=80  qf=160  sf=320  3rd=160  final=640
        -- knockout-only:      r32=10  r16=20  qf=40   sf=80   3rd=40   final=160
        -- group-and-repick:   r32=10  r16=20  qf=40   sf=80   3rd=40   final=160
        SELECT COALESCE(SUM(
            CASE
                WHEN v_league_type = 'group-stage-only' THEN
                    CASE bp.round
                        WHEN 'r32'   THEN  40  WHEN 'r16'   THEN  80
                        WHEN 'qf'    THEN 160  WHEN 'sf'    THEN 320
                        WHEN 'third' THEN 160  WHEN 'final' THEN 640
                        ELSE 0
                    END
                ELSE
                    CASE bp.round
                        WHEN 'r32'   THEN  10  WHEN 'r16'   THEN  20
                        WHEN 'qf'    THEN  40  WHEN 'sf'    THEN  80
                        WHEN 'third' THEN  40  WHEN 'final' THEN 160
                        ELSE 0
                    END
            END
        ), 0) INTO v_ko_pts
        FROM  wc_bracket_picks bp
        JOIN  wc_matches m
              ON  m.round        = bp.round
              AND m.match_number = bp.match_number
        WHERE bp.league_id           = p_league_id
          AND bp.user_id             = v_user_id
          AND bp.predicted_winner_id IS NOT NULL
          AND m.winner_id            = bp.predicted_winner_id;

        -- ── Write results ────────────────────────────────────────
        INSERT INTO wc_scores
            (league_id, user_id, group_stage_points, knockout_points, last_updated)
        VALUES
            (p_league_id, v_user_id, v_group_pts, v_ko_pts, now())
        ON CONFLICT (league_id, user_id) DO UPDATE SET
            group_stage_points = EXCLUDED.group_stage_points,
            knockout_points    = EXCLUDED.knockout_points,
            last_updated       = EXCLUDED.last_updated;

    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION calculate_league_scores(uuid) TO authenticated;

-- ── Trigger function ──────────────────────────────────────────────────────
-- Called by both triggers below; recalculates scores for every league.
CREATE OR REPLACE FUNCTION _recalculate_all_league_scores()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    PERFORM calculate_league_scores(id) FROM leagues;

    -- Tournament is over once the final match has a result — auto-complete
    -- both World Cup game modules (they share this leagues/wc_matches data)
    -- so affected leagues move to the dashboard's "Completed Leagues" tab.
    UPDATE leagues SET status = 'completed'
    WHERE status = 'active'
      AND game_type IN ('world-cup-bracket-challenge', 'world-cup-draft')
      AND EXISTS (SELECT 1 FROM wc_matches WHERE round = 'final' AND status = 'completed');

    RETURN NEW;
END;
$$;

-- Fire when admin sets a knockout match winner
DROP TRIGGER IF EXISTS on_match_winner_set ON wc_matches;
CREATE TRIGGER on_match_winner_set
    AFTER INSERT OR UPDATE OF winner_id ON wc_matches
    FOR EACH ROW
    WHEN (NEW.winner_id IS NOT NULL)
    EXECUTE FUNCTION _recalculate_all_league_scores();

-- Fire when admin records a group-stage result
DROP TRIGGER IF EXISTS on_team_result_set ON wc_teams;
CREATE TRIGGER on_team_result_set
    AFTER UPDATE OF group_finish, advanced_as_third ON wc_teams
    FOR EACH ROW
    EXECUTE FUNCTION _recalculate_all_league_scores();


-- ------------------------------------------------------------
-- 12. PROFILES TABLE
-- Mirrors display info from auth.users without needing direct access.
-- Auto-populated on signup; existing users backfilled by the INSERT below.
-- Run this block before Section 13.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS profiles (
  id           uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text,
  updated_at   timestamptz DEFAULT now()
);

-- Auto-create profile when a new user signs up
-- search_path is set explicitly because this fires (as SECURITY DEFINER)
-- from GoTrue's own session on auth.users INSERT, whose search_path does
-- not include public — an unqualified "profiles" reference here 500s
-- every signup/admin-create-user call with "relation profiles does not exist".
CREATE OR REPLACE FUNCTION create_profile_on_signup()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    INSERT INTO public.profiles (id, display_name)
    VALUES (
        NEW.id,
        COALESCE(
            NULLIF(TRIM(NEW.raw_user_meta_data->>'name'),      ''),
            NULLIF(TRIM(NEW.raw_user_meta_data->>'full_name'), ''),
            split_part(NEW.email, '@', 1)
        )
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_user_signup ON auth.users;
CREATE TRIGGER on_user_signup
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION create_profile_on_signup();

-- Backfill profiles for users who already exist
INSERT INTO profiles (id, display_name)
SELECT
    id,
    COALESCE(
        NULLIF(TRIM(raw_user_meta_data->>'name'),      ''),
        NULLIF(TRIM(raw_user_meta_data->>'full_name'), ''),
        split_part(email, '@', 1)
    )
FROM auth.users
ON CONFLICT (id) DO NOTHING;

GRANT SELECT ON profiles TO authenticated;
GRANT UPDATE (display_name, updated_at) ON profiles TO authenticated;

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Profiles readable by authenticated" ON profiles;
DROP POLICY IF EXISTS "Users manage own profile"          ON profiles;

CREATE POLICY "Profiles readable by authenticated"
    ON profiles FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Users manage own profile"
    ON profiles FOR UPDATE USING (auth.uid() = id);


-- ------------------------------------------------------------
-- 13. LEADERBOARD FUNCTION
-- Returns one row per league member with all data needed to
-- render both the pre-tournament and post-tournament leaderboard.
-- Only callable by authenticated members of the league.
-- ------------------------------------------------------------
-- CREATE OR REPLACE cannot change a RETURNS TABLE signature (team_name
-- added below), so the old signature must be dropped first.
DROP FUNCTION IF EXISTS get_league_leaderboard(uuid);

CREATE FUNCTION get_league_leaderboard(p_league_id uuid)
RETURNS TABLE (
    user_id         uuid,
    display_name    text,
    team_name       text,
    picks_submitted boolean,
    champion_name   text,
    champion_flag   text,
    picks_correct   int,
    points_achieved int,
    points_possible int
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_league_type text;
BEGIN
    -- Only league members may view this data
    IF NOT EXISTS (
        SELECT 1 FROM league_members lm_check
        WHERE lm_check.league_id = p_league_id AND lm_check.user_id = auth.uid()
    ) THEN
        RETURN;
    END IF;

    SELECT league_type INTO v_league_type FROM leagues WHERE id = p_league_id;

    RETURN QUERY
    SELECT
        lm.user_id,

        COALESCE(p.display_name, lm.user_id::text)::text AS display_name,

        lm.team_name,

        -- Did this user submit any bracket picks?
        EXISTS(
            SELECT 1 FROM wc_bracket_picks bp
            WHERE bp.league_id = p_league_id AND bp.user_id = lm.user_id
        ) AS picks_submitted,

        -- Team they picked to win the Final
        COALESCE((
            SELECT t.name
            FROM   wc_bracket_picks bp
            JOIN   wc_teams t ON t.id = bp.predicted_winner_id
            WHERE  bp.league_id = p_league_id AND bp.user_id = lm.user_id
              AND  bp.round = 'final' AND bp.match_number = 1
        ), '—') AS champion_name,

        COALESCE((
            SELECT t.flag_emoji
            FROM   wc_bracket_picks bp
            JOIN   wc_teams t ON t.id = bp.predicted_winner_id
            WHERE  bp.league_id = p_league_id AND bp.user_id = lm.user_id
              AND  bp.round = 'final' AND bp.match_number = 1
        ), '') AS champion_flag,

        -- Number of bracket picks that matched the actual result
        COALESCE((
            SELECT COUNT(*)::int
            FROM   wc_bracket_picks bp
            JOIN   wc_matches m
                   ON m.round = bp.round AND m.match_number = bp.match_number
            WHERE  bp.league_id           = p_league_id
              AND  bp.user_id             = lm.user_id
              AND  m.winner_id            IS NOT NULL
              AND  m.winner_id            = bp.predicted_winner_id
        ), 0) AS picks_correct,

        -- Points earned so far (from wc_scores cache)
        COALESCE((
            SELECT s.total_points FROM wc_scores s
            WHERE  s.league_id = p_league_id AND s.user_id = lm.user_id
        ), 0) AS points_achieved,

        -- Points still achievable: earned + value of all remaining picks
        -- where the picked team has not yet been eliminated
        (
            COALESCE((
                SELECT s.total_points FROM wc_scores s
                WHERE  s.league_id = p_league_id AND s.user_id = lm.user_id
            ), 0)
            +
            COALESCE((
                SELECT SUM(
                    CASE WHEN v_league_type = 'group-stage-only' THEN
                        CASE bp.round
                            WHEN 'r32'   THEN  40  WHEN 'r16'   THEN  80
                            WHEN 'qf'    THEN 160  WHEN 'sf'    THEN 320
                            WHEN 'third' THEN 160  WHEN 'final' THEN 640
                            ELSE 0
                        END
                    ELSE
                        CASE bp.round
                            WHEN 'r32'   THEN  10  WHEN 'r16'   THEN  20
                            WHEN 'qf'    THEN  40  WHEN 'sf'    THEN  80
                            WHEN 'third' THEN  40  WHEN 'final' THEN 160
                            ELSE 0
                        END
                    END
                )::int
                FROM  wc_bracket_picks bp
                JOIN  wc_teams t ON t.id = bp.predicted_winner_id
                WHERE bp.league_id           = p_league_id
                  AND bp.user_id             = lm.user_id
                  AND bp.predicted_winner_id IS NOT NULL
                  AND (t.eliminated = false OR t.eliminated IS NULL)
                  AND NOT EXISTS (
                      SELECT 1 FROM wc_matches m
                      WHERE  m.round        = bp.round
                        AND  m.match_number = bp.match_number
                        AND  m.winner_id    IS NOT NULL
                  )
            ), 0)
        )::int AS points_possible

    FROM  league_members lm
    LEFT JOIN profiles p ON p.id = lm.user_id
    WHERE lm.league_id = p_league_id
    ORDER BY points_achieved DESC, picks_correct DESC, display_name;
END;
$$;

GRANT EXECUTE ON FUNCTION get_league_leaderboard(uuid) TO authenticated;


-- ------------------------------------------------------------
-- 14. JOIN-BY-INVITE-CODE FUNCTION
-- Used by /join/?code=<prefix>-<code> (shared across all games).
-- SECURITY DEFINER so it can look up private leagues (which RLS
-- hides from non-members) and insert the caller as a member.
--
-- Rate limited via invite_code_attempts: since this function is
-- callable directly through the Supabase REST API (not just the UI),
-- an authenticated user could otherwise script requests to brute-force
-- another league's invite code. Every call — success or failure —
-- logs an attempt; more than 10 in a rolling 5-minute window blocks
-- further attempts for that user.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS invite_code_attempts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_invite_code_attempts_user_time
    ON invite_code_attempts(user_id, attempted_at);

DROP FUNCTION IF EXISTS join_league_by_invite_code(text);

CREATE OR REPLACE FUNCTION join_league_by_invite_code(p_invite_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_league          leagues;
    v_user_id         uuid;
    v_recent_attempts int;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Must be logged in to join a league';
    END IF;

    SELECT count(*) INTO v_recent_attempts
    FROM   invite_code_attempts
    WHERE  user_id = v_user_id AND attempted_at > now() - interval '5 minutes';

    IF v_recent_attempts >= 10 THEN
        RAISE EXCEPTION 'Too many invite code attempts. Please wait a few minutes and try again.';
    END IF;

    INSERT INTO invite_code_attempts (user_id) VALUES (v_user_id);

    -- Case-insensitive match (invite codes are stored uppercase, links lowercase)
    SELECT * INTO v_league
    FROM   public.leagues
    WHERE  upper(invite_code) = upper(p_invite_code);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid invite code';
    END IF;

    -- Capacity (max_players) is enforced by the enforce_league_capacity
    -- trigger on league_members below, so it also covers the direct
    -- "Authenticated users can join leagues" INSERT policy, not just this RPC.

    -- Idempotent insert — safe to call even if already a member
    INSERT INTO public.league_members (league_id, user_id)
    VALUES (v_league.id, v_user_id)
    ON CONFLICT DO NOTHING;

    RETURN jsonb_build_object(
        'id',          v_league.id,
        'name',        v_league.name,
        'game_type',   v_league.game_type,
        'league_type', v_league.league_type,
        'invite_code', v_league.invite_code,
        'visibility',  v_league.visibility
    );
END;
$$;

GRANT EXECUTE ON FUNCTION join_league_by_invite_code(text) TO authenticated;

ALTER TABLE invite_code_attempts ENABLE ROW LEVEL SECURITY;
-- No SELECT/INSERT policies for anon/authenticated: this table is only
-- ever written to via the SECURITY DEFINER function above, which runs
-- as the table owner and bypasses RLS.


-- ------------------------------------------------------------
-- 15. TEAM NAMES (write-side RPC)
-- league_members.team_name itself is added in Section 2, above, so it's
-- available to get_league_leaderboard() in Section 13. Writes go through
-- set_team_name() rather than a direct UPDATE policy, consistent with how
-- other per-member writes are gated elsewhere (e.g. fcp_picks,
-- wc_group_picks). Reuses is_league_member(), already defined in
-- soccer/world-cup-draft/schema.sql Section 15.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_team_name(p_league_id uuid, p_team_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT is_league_member(p_league_id) THEN
        RAISE EXCEPTION 'Not a member of this league';
    END IF;

    IF p_team_name IS NULL OR length(trim(p_team_name)) = 0 THEN
        RAISE EXCEPTION 'Team name cannot be empty';
    END IF;

    IF length(p_team_name) > 30 THEN
        RAISE EXCEPTION 'Team name must be 30 characters or fewer';
    END IF;

    UPDATE league_members
    SET    team_name = trim(p_team_name)
    WHERE  league_id = p_league_id AND user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION set_team_name(uuid, text) TO authenticated;
