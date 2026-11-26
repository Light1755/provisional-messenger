-- One-to-one messaging features for the live schema_version 4 database.
-- Safe to run repeatedly: every statement is guarded, and functions are
-- dropped before creation so argument lists and output shapes cannot drift.
-- The two-person / expiry / burn / no-recovery model is unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Message columns
-- ---------------------------------------------------------------------------

alter table public.messages
  add column if not exists reply_to_id uuid null
    references public.messages (id) on delete set null;

alter table public.messages add column if not exists edited_at timestamptz null;
alter table public.messages add column if not exists deleted_at timestamptz null;
alter table public.messages
  add column if not exists delivered_at timestamptz null default now();

-- Repair a partial previous run where the column exists but its self-FK does
-- not. On a fresh run the inline REFERENCES above already created this name.
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.messages'::regclass
      and conname = 'messages_reply_to_id_fkey'
  ) then
    alter table public.messages
      add constraint messages_reply_to_id_fkey
      foreign key (reply_to_id) references public.messages (id)
      on delete set null;
  end if;
end;
$$;

-- delete_message() clears the content of a row while keeping the row itself,
-- so the existing content checks must skip soft-deleted tombstones.
alter table public.messages drop constraint if exists messages_text_body;
alter table public.messages add constraint messages_text_body check (
  deleted_at is not null
  or kind <> 'text'
  or (body is not null and length(body) between 1 and 4000)
);

alter table public.messages drop constraint if exists messages_attachment_meta;
alter table public.messages add constraint messages_attachment_meta check (
  deleted_at is not null
  or kind not in ('file', 'voice')
  or (
    attachment_name is not null
    and attachment_mime is not null
    and attachment_size is not null
    and attachment_size between 1 and 5242880
  )
);

alter table public.messages drop constraint if exists messages_voice_duration;
alter table public.messages add constraint messages_voice_duration check (
  deleted_at is not null
  or kind <> 'voice'
  or (duration_ms is not null and duration_ms between 500 and 600000)
);

-- ---------------------------------------------------------------------------
-- 2. New tables
-- ---------------------------------------------------------------------------

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  emoji text not null check (char_length(emoji) <= 8),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create table if not exists public.user_presence (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_seen timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Access helpers, RLS, and table privileges
-- ---------------------------------------------------------------------------

create or replace function public.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id
    where cm.conversation_id = p_conversation_id
      and cm.user_id = auth.uid()
      and c.expires_at > now()
  );
$$;

create or replace function public.can_access_message(p_message_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.messages m
    where m.id = p_message_id
      and public.is_conversation_member(m.conversation_id)
  );
$$;

revoke all on function public.is_conversation_member(uuid) from public, anon;
revoke all on function public.can_access_message(uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.can_access_message(uuid) to authenticated;

alter table public.message_reactions enable row level security;
alter table public.user_presence enable row level security;

drop policy if exists message_reactions_select on public.message_reactions;
create policy message_reactions_select on public.message_reactions
for select to authenticated
using (public.can_access_message(message_id));

-- Presence is only an opaque user id and a timestamp.
drop policy if exists user_presence_select on public.user_presence;
create policy user_presence_select on public.user_presence
for select to authenticated
using (true);

revoke all on public.message_reactions from anon, authenticated;
revoke all on public.user_presence from anon, authenticated;
grant select on public.message_reactions to authenticated;
grant select on public.user_presence to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Sending RPCs (old signatures dropped first, no overloads)
-- ---------------------------------------------------------------------------

drop function if exists public.send_text_message(uuid, uuid, text);
drop function if exists public.send_text_message(uuid, uuid, text, uuid);

create or replace function public.send_text_message(
  p_conversation_id uuid,
  p_client_id uuid,
  p_body text,
  p_reply_to_id uuid default null
)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := trim(p_body);
  v_msg public.messages;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if p_client_id is null then
    raise exception 'missing_client_id' using errcode = '22023';
  end if;

  if not public.is_conversation_member(p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  if v_body is null or length(v_body) = 0 then
    raise exception 'empty_message' using errcode = '22023';
  end if;

  if length(v_body) > 4000 then
    raise exception 'message_too_long' using errcode = '22023';
  end if;

  -- Replies must point at a live message in this same conversation; a
  -- soft-deleted target is a tombstone and cannot be replied to.
  if p_reply_to_id is not null and not exists (
    select 1
    from public.messages
    where id = p_reply_to_id
      and conversation_id = p_conversation_id
      and deleted_at is null
  ) then
    raise exception 'invalid_reply_target' using errcode = '22023';
  end if;

  select * into v_msg
  from public.messages
  where conversation_id = p_conversation_id
    and sender_id = v_uid
    and client_id = p_client_id;

  if found then
    return v_msg;
  end if;

  select count(*) into v_count
  from public.messages
  where conversation_id = p_conversation_id;
  if v_count >= 5000 then
    raise exception 'conversation_full' using errcode = '22023';
  end if;

  begin
    insert into public.messages (
      conversation_id, sender_id, kind, body, client_id, reply_to_id
    )
    values (
      p_conversation_id, v_uid, 'text', v_body, p_client_id, p_reply_to_id
    )
    returning * into v_msg;
  exception
    when unique_violation then
      select * into v_msg
      from public.messages
      where conversation_id = p_conversation_id
        and sender_id = v_uid
        and client_id = p_client_id;
      if not found then
        raise;
      end if;
      return v_msg;
  end;

  update public.conversations
  set updated_at = now()
  where id = p_conversation_id;

  return v_msg;
end;
$$;

drop function if exists public.send_attachment_message(uuid, uuid, text, text, text, integer, text);
drop function if exists public.send_attachment_message(uuid, uuid, text, text, text, integer, text, uuid);

create or replace function public.send_attachment_message(
  p_conversation_id uuid,
  p_client_id uuid,
  p_kind text,
  p_file_name text,
  p_mime text,
  p_duration_ms integer,
  p_data_base64 text,
  p_reply_to_id uuid default null
)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_kind text := lower(trim(p_kind));
  v_name text := nullif(trim(p_file_name), '');
  v_mime text := nullif(trim(p_mime), '');
  v_data bytea;
  v_size integer;
  v_msg public.messages;
  v_count integer;
  v_bytes bigint;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if p_client_id is null then
    raise exception 'missing_client_id' using errcode = '22023';
  end if;

  if not public.is_conversation_member(p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  -- Replies must point at a live message in this same conversation.
  if p_reply_to_id is not null and not exists (
    select 1
    from public.messages
    where id = p_reply_to_id
      and conversation_id = p_conversation_id
      and deleted_at is null
  ) then
    raise exception 'invalid_reply_target' using errcode = '22023';
  end if;

  if v_kind is null or v_kind not in ('file', 'voice') then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;

  if v_name is null or v_mime is null or p_data_base64 is null then
    raise exception 'missing_attachment' using errcode = '22023';
  end if;

  if length(v_name) > 200 then
    raise exception 'file_name_too_long' using errcode = '22023';
  end if;

  if length(v_mime) > 200 then
    raise exception 'mime_too_long' using errcode = '22023';
  end if;

  if v_kind = 'file' and p_duration_ms is not null then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;

  if v_kind = 'voice' and (
    p_duration_ms is null or p_duration_ms < 500 or p_duration_ms > 600000
  ) then
    raise exception 'invalid_voice_duration' using errcode = '22023';
  end if;

  if v_kind = 'voice' and v_mime not like 'audio/%' then
    raise exception 'invalid_voice_mime' using errcode = '22023';
  end if;

  -- Reject oversized payloads before decoding.
  if length(p_data_base64) > 7069056 then
    raise exception 'attachment_too_large' using errcode = '22023';
  end if;

  begin
    v_data := decode(p_data_base64, 'base64');
  exception
    when others then
      raise exception 'invalid_attachment' using errcode = '22023';
  end;

  v_size := octet_length(v_data);
  if v_size < 1 or v_size > 5242880 then
    raise exception 'attachment_too_large' using errcode = '22023';
  end if;

  select * into v_msg
  from public.messages
  where conversation_id = p_conversation_id
    and sender_id = v_uid
    and client_id = p_client_id;

  if found then
    return v_msg;
  end if;

  select count(*) into v_count
  from public.messages
  where conversation_id = p_conversation_id;
  if v_count >= 5000 then
    raise exception 'conversation_full' using errcode = '22023';
  end if;

  select coalesce(sum(attachment_size), 0) into v_bytes
  from public.messages
  where conversation_id = p_conversation_id;
  if v_bytes + v_size > 104857600 then
    raise exception 'conversation_storage_full' using errcode = '22023';
  end if;

  begin
    insert into public.messages (
      conversation_id, sender_id, kind, attachment_name, attachment_mime,
      attachment_size, duration_ms, client_id, reply_to_id
    )
    values (
      p_conversation_id, v_uid, v_kind, v_name, v_mime,
      v_size, p_duration_ms, p_client_id, p_reply_to_id
    )
    returning * into v_msg;

    insert into public.message_attachments (message_id, data)
    values (v_msg.id, v_data);
  exception
    when unique_violation then
      select * into v_msg
      from public.messages
      where conversation_id = p_conversation_id
        and sender_id = v_uid
        and client_id = p_client_id;
      if not found then
        raise;
      end if;
      return v_msg;
  end;

  update public.conversations
  set updated_at = now()
  where id = p_conversation_id;

  return v_msg;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reading RPCs
-- ---------------------------------------------------------------------------

drop function if exists public.get_messages(uuid, timestamptz, integer, uuid);

create or replace function public.get_messages(
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_limit integer default 100,
  p_before_id uuid default null
)
returns table (
  message_id uuid,
  conversation_id uuid,
  sender_id uuid,
  sender_username text,
  sender_accent smallint,
  kind text,
  body text,
  attachment_name text,
  attachment_mime text,
  attachment_size integer,
  duration_ms integer,
  client_id uuid,
  created_at timestamptz,
  is_mine boolean,
  is_read boolean,
  reply_to_id uuid,
  reply_to_body text,
  reply_to_kind text,
  reply_to_sender_id uuid,
  reply_to_sender_username text,
  edited_at timestamptz,
  deleted_at timestamptz,
  delivered_at timestamptz,
  reactions jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from (
    select
      m.id as message_id,
      m.conversation_id,
      m.sender_id,
      p.username,
      p.accent,
      m.kind,
      m.body,
      m.attachment_name,
      m.attachment_mime,
      m.attachment_size,
      m.duration_ms,
      m.client_id,
      m.created_at,
      (m.sender_id = auth.uid()) as is_mine,
      case
        when m.sender_id <> auth.uid() then true
        else coalesce((
          select other_cm.last_read_at >= m.created_at
          from public.conversation_members other_cm
          where other_cm.conversation_id = m.conversation_id
            and other_cm.user_id <> auth.uid()
          limit 1
        ), false)
      end as is_read,
      m.reply_to_id,
      rt.body as reply_to_body,
      rt.kind as reply_to_kind,
      rt.sender_id as reply_to_sender_id,
      rtp.username as reply_to_sender_username,
      m.edited_at,
      m.deleted_at,
      m.delivered_at,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'emoji', r.emoji,
            'user_id', r.user_id,
            'username', rp.username,
            'accent', rp.accent
          )
          order by r.created_at, r.user_id, r.emoji
        )
        from public.message_reactions r
        left join public.profiles rp on rp.id = r.user_id
        where r.message_id = m.id
      ), '[]'::jsonb) as reactions
    from public.messages m
    join public.profiles p on p.id = m.sender_id
    left join public.messages rt on rt.id = m.reply_to_id
    left join public.profiles rtp on rtp.id = rt.sender_id
    where m.conversation_id = p_conversation_id
      and public.is_conversation_member(m.conversation_id)
      and (
        p_before is null
        or (m.created_at, m.id) < (
          p_before,
          coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
        )
      )
    order by m.created_at desc, m.id desc
    limit greatest(1, least(coalesce(p_limit, 100), 200))
  ) recent
  order by recent.created_at asc, recent.message_id asc;
$$;

-- ---------------------------------------------------------------------------
-- 6. Edit / soft-delete / reaction / presence RPCs
-- ---------------------------------------------------------------------------

drop function if exists public.edit_message(uuid, text);

create or replace function public.edit_message(
  p_message_id uuid,
  p_body text
)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := trim(p_body);
  v_msg public.messages;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if v_body is null or char_length(v_body) < 1 or char_length(v_body) > 4000 then
    raise exception 'invalid_body' using errcode = '22023';
  end if;

  if not public.can_access_message(p_message_id) then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  update public.messages
  set body = v_body, edited_at = now()
  where id = p_message_id
    and sender_id = v_uid
    and kind = 'text'
    and deleted_at is null
  returning * into v_msg;

  if not found then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  return v_msg;
end;
$$;

drop function if exists public.delete_message(uuid);

create or replace function public.delete_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not public.can_access_message(p_message_id) then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  -- The UPDATE itself is the Realtime signal; no DELETE event is needed.
  update public.messages
  set deleted_at = now(),
      body = null,
      attachment_name = null,
      attachment_mime = null,
      attachment_size = null,
      duration_ms = null
  where id = p_message_id
    and sender_id = v_uid
    and deleted_at is null;

  if not found then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  delete from public.message_attachments where message_id = p_message_id;
end;
$$;

drop function if exists public.add_reaction(uuid, text);

create or replace function public.add_reaction(
  p_message_id uuid,
  p_emoji text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if p_emoji is null or char_length(p_emoji) < 1 or char_length(p_emoji) > 8 then
    raise exception 'invalid_emoji' using errcode = '22023';
  end if;

  if not public.can_access_message(p_message_id) then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.messages
    where id = p_message_id and deleted_at is not null
  ) then
    raise exception 'message_deleted' using errcode = '22023';
  end if;

  insert into public.message_reactions (message_id, user_id, emoji)
  values (p_message_id, auth.uid(), p_emoji)
  on conflict (message_id, user_id, emoji) do nothing;
end;
$$;

drop function if exists public.remove_reaction(uuid, text);

create or replace function public.remove_reaction(
  p_message_id uuid,
  p_emoji text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if p_emoji is null or char_length(p_emoji) < 1 or char_length(p_emoji) > 8 then
    raise exception 'invalid_emoji' using errcode = '22023';
  end if;

  if not public.can_access_message(p_message_id) then
    raise exception 'message_not_found' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.messages
    where id = p_message_id and deleted_at is not null
  ) then
    raise exception 'message_deleted' using errcode = '22023';
  end if;

  delete from public.message_reactions
  where message_id = p_message_id
    and user_id = auth.uid()
    and emoji = p_emoji;
end;
$$;

drop function if exists public.touch_presence();

create or replace function public.touch_presence()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  insert into public.user_presence (user_id, last_seen)
  values (v_uid, now())
  on conflict (user_id) do update set last_seen = excluded.last_seen
  returning last_seen into v_now;

  return v_now;
end;
$$;

drop function if exists public.get_partner_presence(uuid);

create or replace function public.get_partner_presence(p_conversation_id uuid)
returns table (
  user_id uuid,
  last_seen timestamptz,
  is_online boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not public.is_conversation_member(p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  -- A partner who has never checked in still gets a row, marked offline.
  return query
  select cm.user_id,
         up.last_seen,
         coalesce(up.last_seen >= now() - interval '30 seconds', false)
  from public.conversation_members cm
  left join public.user_presence up on up.user_id = cm.user_id
  where cm.conversation_id = p_conversation_id
    and cm.user_id <> auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Health check
-- ---------------------------------------------------------------------------

create or replace function public.health_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cron_schema text;
  v_cron_ok boolean := false;
begin
  v_cron_schema := public.cron_schema_name();

  if v_cron_schema is not null then
    execute format(
      'select exists (select 1 from %I.job where jobname = $1 and active)',
      v_cron_schema
    ) into v_cron_ok using 'provisional-purge-expired';
  end if;

  return jsonb_build_object(
    'ok',
      to_regclass('public.profiles') is not null
      and to_regclass('public.conversations') is not null
      and to_regclass('public.conversation_members') is not null
      and to_regclass('public.messages') is not null
      and to_regclass('public.message_attachments') is not null,
    'app', 'provisional-messenger',
    'schema_version', 5,
    'cron_ok', v_cron_ok,
    'server_now', now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Function privileges
-- ---------------------------------------------------------------------------

revoke all on function public.send_text_message(uuid, uuid, text, uuid) from public, anon;
revoke all on function public.send_attachment_message(uuid, uuid, text, text, text, integer, text, uuid) from public, anon;
revoke all on function public.get_messages(uuid, timestamptz, integer, uuid) from public, anon;
revoke all on function public.edit_message(uuid, text) from public, anon;
revoke all on function public.delete_message(uuid) from public, anon;
revoke all on function public.add_reaction(uuid, text) from public, anon;
revoke all on function public.remove_reaction(uuid, text) from public, anon;
revoke all on function public.touch_presence() from public, anon;
revoke all on function public.get_partner_presence(uuid) from public, anon;

grant execute on function public.send_text_message(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.send_attachment_message(uuid, uuid, text, text, text, integer, text, uuid) to authenticated;
grant execute on function public.get_messages(uuid, timestamptz, integer, uuid) to authenticated;
grant execute on function public.edit_message(uuid, text) to authenticated;
grant execute on function public.delete_message(uuid) to authenticated;
grant execute on function public.add_reaction(uuid, text) to authenticated;
grant execute on function public.remove_reaction(uuid, text) to authenticated;
grant execute on function public.touch_presence() to authenticated;
grant execute on function public.get_partner_presence(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Realtime
-- ---------------------------------------------------------------------------

do $$
begin
  begin
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'message_reactions'
    ) then
      execute 'alter publication supabase_realtime add table public.message_reactions';
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'user_presence'
    ) then
      execute 'alter publication supabase_realtime add table public.user_presence';
    end if;
  exception
    when undefined_object then
      raise notice 'supabase_realtime publication not found; enable Realtime in the dashboard.';
  end;
end;
$$;

notify pgrst, 'reload schema';
