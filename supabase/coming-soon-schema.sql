-- ============================================================
-- Coming Soon Notify-Me Signups
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / DROP POLICY IF EXISTS)
--
-- Captures emails submitted via the "Notify Me" form on
-- /coming-soon/index.html for game formats that aren't built yet.
-- Write-only from the client — no SELECT policy is granted, so
-- signups are only readable via the Supabase dashboard or service role.
-- ============================================================

CREATE TABLE IF NOT EXISTS coming_soon_signups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text NOT NULL,
  game        text NOT NULL,
  sport       text,
  page_url    text,
  created_at  timestamptz DEFAULT now(),
  UNIQUE (email, game)
);

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT INSERT ON coming_soon_signups TO anon, authenticated;

ALTER TABLE coming_soon_signups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can insert coming soon signups" ON coming_soon_signups;
CREATE POLICY "Anyone can insert coming soon signups"
  ON coming_soon_signups FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);
