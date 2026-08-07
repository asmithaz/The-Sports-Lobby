-- ================================================================
-- League status (Active / Completed)
-- Applied once via: supabase db query --linked -f supabase/league-status-schema.sql
--
-- Adds leagues.status, defaulting existing rows to 'active'. Leagues
-- transition to 'completed' automatically once their season/tournament
-- ends (see the updated fcp_recalculate_all_scores() in
-- golf/fedex-playoffs/schema.sql and _recalculate_all_league_scores()
-- in soccer/world-cup-bracket-challenge/schema.sql — both already run
-- on the existing score-sync paths, so this needs no new cron job).
-- These two RPCs are a commissioner-only manual override alongside
-- that automatic detection.
-- ================================================================

ALTER TABLE leagues
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active'
  CHECK (status IN ('active', 'completed'));

-- 'pending' — the setup/invite flow for draft-based games (fedex-playoffs,
-- world-cup-draft) inserts the `leagues` row on Step 1's "Next" before the
-- Step 2 "Launch League" step creates the game's own fcp_leagues/wcd_leagues
-- config row. Without this, the on_league_created trigger (see
-- soccer/world-cup-bracket-challenge/schema.sql) immediately adds the
-- commissioner to league_members, so an abandoned Step 2 left a
-- half-configured league showing on the dashboard as if it were fully
-- created. Step 1 now inserts status='pending' for those two games; Step 2
-- flips it to 'active' once its config row is saved. 'pending' matches
-- neither dashboard tab filter ('active'/'completed'), so it stays hidden
-- until setup actually finishes. Idempotent for installs that ran this
-- schema before 'pending' existed.
ALTER TABLE leagues DROP CONSTRAINT IF EXISTS leagues_status_check;
ALTER TABLE leagues ADD CONSTRAINT leagues_status_check
  CHECK (status IN ('pending', 'active', 'completed'));


CREATE OR REPLACE FUNCTION complete_league(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can mark this league completed';
  END IF;

  UPDATE leagues SET status = 'completed' WHERE id = p_league_id;
END;
$$;

GRANT EXECUTE ON FUNCTION complete_league(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION reactivate_league(p_league_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM leagues WHERE id = p_league_id AND commissioner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Only the commissioner can reactivate this league';
  END IF;

  UPDATE leagues SET status = 'active' WHERE id = p_league_id;
END;
$$;

GRANT EXECUTE ON FUNCTION reactivate_league(uuid) TO authenticated;


-- ------------------------------------------------------------
-- Pending-league cleanup
-- A 'pending' league (see above) sits abandoned forever if the
-- commissioner never returns to finish Step 2. Sweep those away after a
-- day's grace period so they don't accumulate as dead rows. league_members
-- and the game-specific config tables (fcp_leagues, wcd_leagues, etc.) all
-- reference leagues.id with ON DELETE CASCADE, so deleting the leagues
-- row alone is enough — and a 'pending' league never has a config row
-- anyway, since Step 2 only flips status to 'active' after saving one.
-- Runs inside Postgres via pg_cron, same pattern as golf/fedex-playoffs
-- /schema.sql SECTION 12. On Supabase, pg_cron must be enabled once via
-- Database > Extensions before this CREATE EXTENSION will succeed.
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION cleanup_pending_leagues()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM leagues
  WHERE status = 'pending' AND created_at < now() - interval '24 hours';
$$;

GRANT EXECUTE ON FUNCTION cleanup_pending_leagues() TO service_role;

SELECT cron.schedule(
  'cleanup-pending-leagues',
  '0 * * * *', -- hourly
  $$ SELECT cleanup_pending_leagues(); $$
);
