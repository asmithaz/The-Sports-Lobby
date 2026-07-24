-- ================================================================
-- Profile avatars
-- Applied once via: supabase db query --linked -f supabase/avatar-schema.sql
--
-- Adds profiles.avatar_url and a public "avatars" Storage bucket.
-- Uploads go to <user_id>/avatar.<ext> so the storage RLS policies can
-- key off the first path segment matching auth.uid() — no separate
-- ownership table needed. Client resizes images before upload, so
-- objects stay small; the bucket-level size limit is just a backstop.
-- ================================================================

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url text;

GRANT UPDATE (avatar_url, updated_at) ON profiles TO authenticated;


INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, 2097152, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET
  public = true,
  file_size_limit = 2097152,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

DROP POLICY IF EXISTS "Avatar images are publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Users upload own avatar"              ON storage.objects;
DROP POLICY IF EXISTS "Users update own avatar"               ON storage.objects;
DROP POLICY IF EXISTS "Users delete own avatar"               ON storage.objects;

CREATE POLICY "Avatar images are publicly readable"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'avatars');

CREATE POLICY "Users upload own avatar"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "Users update own avatar"
    ON storage.objects FOR UPDATE
    USING (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "Users delete own avatar"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );
