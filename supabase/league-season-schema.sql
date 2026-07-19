-- ================================================================
-- League season pointer
-- Applied once via: supabase db query --linked -f supabase/league-season-schema.sql
--
-- Adds leagues.current_season, defaulting existing rows to the
-- current calendar year. Used today only by fedex-playoffs leagues
-- (see golf/fedex-playoffs/schema.sql "SECTION 12 — SEASONS"), which
-- is the only annual game module — ignored by other game_types.
-- ================================================================

ALTER TABLE leagues
  ADD COLUMN IF NOT EXISTS current_season int NOT NULL
  DEFAULT extract(year from now())::int;
