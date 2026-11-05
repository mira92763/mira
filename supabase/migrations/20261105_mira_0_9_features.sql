-- MIRA 0.9 database migration
-- Run in the Supabase SQL Editor after reviewing the project backup.

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reply_to UUID;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'messages_reply_to_fkey'
      AND conrelid = 'public.messages'::regclass
  ) THEN
    ALTER TABLE public.messages
      ADD CONSTRAINT messages_reply_to_fkey
      FOREIGN KEY (reply_to) REFERENCES public.messages(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS messages_reply_to_idx
  ON public.messages(reply_to);

CREATE OR REPLACE FUNCTION public.mira_validate_reply_target()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.reply_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.messages AS parent
    WHERE parent.id = NEW.reply_to
      AND parent.conversation_id = NEW.conversation_id
  ) THEN
    RAISE EXCEPTION 'Reply target must belong to the same conversation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mira_validate_reply_target_trigger ON public.messages;
CREATE TRIGGER mira_validate_reply_target_trigger
BEFORE INSERT OR UPDATE OF reply_to, conversation_id
ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.mira_validate_reply_target();

-- Create presence rows for older accounts without changing existing settings.
INSERT INTO public.user_presence
  (user_id, is_online, last_seen, show_online, show_last_seen, updated_at)
SELECT u.id, FALSE,
       COALESCE(u.last_sign_in_at, u.created_at, NOW()),
       TRUE, TRUE,
       COALESCE(u.last_sign_in_at, u.created_at, NOW())
FROM auth.users AS u
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.mira_set_presence(
  p_is_online BOOLEAN DEFAULT NULL,
  p_show_online BOOLEAN DEFAULT NULL,
  p_show_last_seen BOOLEAN DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  INSERT INTO public.user_presence
    (user_id, is_online, last_seen, show_online, show_last_seen, updated_at)
  VALUES (
    v_user_id, COALESCE(p_is_online, FALSE), NOW(),
    COALESCE(p_show_online, TRUE), COALESCE(p_show_last_seen, TRUE), NOW()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    is_online = COALESCE(p_is_online, public.user_presence.is_online),
    last_seen = CASE WHEN p_is_online = FALSE THEN NOW()
                     ELSE public.user_presence.last_seen END,
    show_online = COALESCE(p_show_online, public.user_presence.show_online),
    show_last_seen = COALESCE(p_show_last_seen, public.user_presence.show_last_seen),
    updated_at = NOW();

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.mira_set_presence(BOOLEAN, BOOLEAN, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mira_set_presence(BOOLEAN, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.mira_get_presence(p_user_id UUID)
RETURNS TABLE (user_id UUID, is_online BOOLEAN, last_seen TIMESTAMPTZ)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    p.user_id,
    CASE WHEN p.user_id = auth.uid() OR p.show_online
      THEN (p.is_online AND p.updated_at > NOW() - INTERVAL '75 seconds')
      ELSE NULL END,
    CASE WHEN p.user_id = auth.uid() OR p.show_last_seen
      THEN CASE
        WHEN p.is_online AND p.updated_at > NOW() - INTERVAL '75 seconds' THEN NULL
        ELSE COALESCE(p.last_seen, p.updated_at)
      END
      ELSE NULL END
  FROM public.user_presence AS p
  WHERE p.user_id = p_user_id
    AND (
      p.user_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.conversations AS c
        WHERE (c.user_one = auth.uid() AND c.user_two = p.user_id)
           OR (c.user_two = auth.uid() AND c.user_one = p.user_id)
      )
    );
$$;

REVOKE ALL ON FUNCTION public.mira_get_presence(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mira_get_presence(UUID) TO authenticated;

-- Private Realtime Broadcast: only members of the conversation may send/read typing events.
ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mira_typing_broadcast_read ON realtime.messages;
CREATE POLICY mira_typing_broadcast_read
ON realtime.messages FOR SELECT TO authenticated
USING (
  split_part((SELECT realtime.topic()), ':', 1) = 'mira-typing'
  AND CASE
    WHEN split_part((SELECT realtime.topic()), ':', 2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN EXISTS (
      SELECT 1 FROM public.conversations AS c
      WHERE c.id = split_part((SELECT realtime.topic()), ':', 2)::UUID
        AND (c.user_one = (SELECT auth.uid()) OR c.user_two = (SELECT auth.uid()))
    )
    ELSE FALSE
  END
);

DROP POLICY IF EXISTS mira_typing_broadcast_send ON realtime.messages;
CREATE POLICY mira_typing_broadcast_send
ON realtime.messages FOR INSERT TO authenticated
WITH CHECK (
  split_part((SELECT realtime.topic()), ':', 1) = 'mira-typing'
  AND CASE
    WHEN split_part((SELECT realtime.topic()), ':', 2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN EXISTS (
      SELECT 1 FROM public.conversations AS c
      WHERE c.id = split_part((SELECT realtime.topic()), ':', 2)::UUID
        AND (c.user_one = (SELECT auth.uid()) OR c.user_two = (SELECT auth.uid()))
    )
    ELSE FALSE
  END
);
