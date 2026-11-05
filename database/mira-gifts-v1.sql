-- MIRA Gifts v1
-- Run once in Supabase Dashboard -> SQL Editor.
-- This creates an internal, free-to-send gift system. No blockchain or payments.

create table if not exists public.gift_catalog (
  id text primary key,
  title text not null,
  description text not null default '',
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  emoji text not null default '🎁',
  is_active boolean not null default true,
  next_serial bigint not null default 1 check (next_serial > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.gift_instances (
  id uuid primary key default gen_random_uuid(),
  gift_id text not null references public.gift_catalog(id),
  serial_number bigint not null check (serial_number > 0),
  sender_id uuid not null references auth.users(id) on delete restrict,
  owner_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint gift_instances_gift_serial_unique unique (gift_id, serial_number)
);

create index if not exists gift_instances_owner_created_idx
  on public.gift_instances(owner_id, created_at desc);
create index if not exists gift_instances_sender_created_idx
  on public.gift_instances(sender_id, created_at desc);

alter table public.gift_catalog enable row level security;
alter table public.gift_instances enable row level security;

drop policy if exists "Authenticated users can view active gifts" on public.gift_catalog;
create policy "Authenticated users can view active gifts"
  on public.gift_catalog
  for select
  to authenticated
  using (is_active = true);

drop policy if exists "Users can view gifts they sent or own" on public.gift_instances;
create policy "Users can view gifts they sent or own"
  on public.gift_instances
  for select
  to authenticated
  using (
    (select auth.uid()) = owner_id
    or (select auth.uid()) = sender_id
  );

revoke insert, update, delete, truncate, references, trigger
  on public.gift_catalog from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.gift_instances from anon, authenticated;
grant select on public.gift_catalog to authenticated;
grant select on public.gift_instances to authenticated;

create or replace function public.mira_send_gift(
  p_recipient_id uuid,
  p_gift_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sender_id uuid := auth.uid();
  v_serial bigint;
  v_instance public.gift_instances;
begin
  if v_sender_id is null then
    raise exception 'Authentication required';
  end if;

  if p_recipient_id is null or p_recipient_id = v_sender_id then
    raise exception 'Choose another MIRA user';
  end if;

  if not exists (
    select 1 from auth.users where id = p_recipient_id
  ) then
    raise exception 'Recipient not found';
  end if;

  update public.gift_catalog
     set next_serial = next_serial + 1
   where id = p_gift_id
     and is_active = true
   returning next_serial - 1 into v_serial;

  if v_serial is null then
    raise exception 'Gift is unavailable';
  end if;

  insert into public.gift_instances (
    gift_id, serial_number, sender_id, owner_id
  )
  values (
    p_gift_id, v_serial, v_sender_id, p_recipient_id
  )
  returning * into v_instance;

  return jsonb_build_object(
    'id', v_instance.id,
    'gift_id', v_instance.gift_id,
    'serial_number', v_instance.serial_number,
    'sender_id', v_instance.sender_id,
    'owner_id', v_instance.owner_id,
    'created_at', v_instance.created_at
  );
end;
$$;

revoke all on function public.mira_send_gift(uuid, text) from public, anon;
grant execute on function public.mira_send_gift(uuid, text) to authenticated;

insert into public.gift_catalog (id, title, description, rarity, emoji)
values
  ('rose', 'Роза', 'Небольшой знак внимания.', 'common', '🌹'),
  ('star', 'Звезда', 'Пусть твои идеи сияют.', 'common', '⭐'),
  ('heart', 'Сердце', 'Тёплый подарок для особенного момента.', 'common', '💜'),
  ('coffee', 'Кофе', 'Для хорошего настроения и новых идей.', 'rare', '☕'),
  ('crystal', 'Кристалл', 'Редкий кристалл из коллекции MIRA.', 'rare', '💎'),
  ('moon', 'Лунный свет', 'Частичка ночного неба.', 'epic', '🌙'),
  ('crown', 'Корона', 'Символ больших амбиций.', 'epic', '👑'),
  ('phoenix', 'Феникс', 'Особенный экземпляр коллекции MIRA.', 'legendary', '🔥')
on conflict (id) do nothing;

-- Quick verification after running:
-- select id, title, rarity, next_serial from public.gift_catalog order by next_serial, id;
-- select proname from pg_proc where proname = 'mira_send_gift';
