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
