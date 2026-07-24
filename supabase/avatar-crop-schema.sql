-- ================================================================
-- Avatar reposition support
-- Applied once via: supabase db query --linked -f supabase/avatar-crop-schema.sql
--
-- Lets a user reopen the cropper on their existing avatar without
-- re-picking a file: avatar_crop stores the pan/zoom transform, and
-- <user_id>/original.jpg (uploaded alongside the cropped avatar.jpg,
-- same "avatars" bucket/policies from avatar-schema.sql) is the
-- capped-resolution working copy the crop is measured against.
-- ================================================================

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_crop jsonb;

GRANT UPDATE (avatar_crop) ON profiles TO authenticated;
