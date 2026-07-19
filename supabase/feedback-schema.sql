-- ============================================================
-- Beta Feedback
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / DROP POLICY IF EXISTS)
--
-- Captures free-text feedback submitted via the "Feedback" link in
-- the site footer (see js/feedback.js). Write-only from the client —
-- no SELECT policy is granted, so feedback is only readable via the
-- Supabase dashboard or service role.
-- ============================================================

CREATE TABLE IF NOT EXISTS feedback (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message     text NOT NULL,
  page_url    text,
  user_agent  text,
  created_at  timestamptz DEFAULT now()
);

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT INSERT ON feedback TO anon, authenticated;

ALTER TABLE feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can insert feedback" ON feedback;
CREATE POLICY "Anyone can insert feedback"
  ON feedback FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);
