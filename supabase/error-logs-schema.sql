-- ============================================================
-- Client-side Error Logs
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- Safe to re-run (uses IF NOT EXISTS / DROP POLICY IF EXISTS)
--
-- Captures uncaught JS errors and unhandled promise rejections
-- from the browser (see js/error-logging.js). Write-only from the
-- client — no SELECT policy is granted, so logs are only readable
-- via the Supabase dashboard or service role.
-- ============================================================

CREATE TABLE IF NOT EXISTS error_logs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message     text NOT NULL,
  stack       text,
  url         text,
  user_agent  text,
  created_at  timestamptz DEFAULT now()
);

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT INSERT ON error_logs TO anon, authenticated;

ALTER TABLE error_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can insert error logs" ON error_logs;
CREATE POLICY "Anyone can insert error logs"
  ON error_logs FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);
