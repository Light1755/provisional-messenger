-- Idempotent schema update applied to the live project on 26 Nov 2026.
-- It re-runs setup.sql so existing databases receive the read-receipt fix,
-- deletion tombstones, bounded purge, safer validation, and search index.
-- Safe to run more than once.
-- ============================================================================
-- Provisional Messenger â€” complete Supabase setup
--
-- Run this once in a NEW Supabase project:
--   Dashboard -> SQL Editor -> New query -> paste -> Run
--
-- Then enable anonymous sign-ins:
--   Authentication -> Providers -> Anonymous -> Enable
--
-- What this file creates:
--   * username-only profiles tied to Supabase anonymous auth users
--   * two-person conversations with a fixed expiry countdown
--   * text, file, image, and voice-note messages
--   * row level security so only the two members can read a conversation
--   * RPCs for account creation, search, sending, burning, and expiry
--   * a pg_cron job that purges expired conversations in batches every minute
--   * realtime for new messages, conversations, read receipts, and deletions
--
-- Privacy notes:
--   * There is no message log table and no archive/restore path.
--   * File bytes live in Postgres and are deleted by ON DELETE CASCADE.
--   * Deleting a profile deletes every conversation the user belongs to.
--   * Short-lived deletion notices carry only conversation and member ids so
--     an open client can leave a burned chat immediately.
--   * Message content is never placed in URLs or app logs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null,
  accent smallint not null default 0 check (accent between 0 and 5),
  created_at timestamptz not null default now(),
  constraint profiles_username_format
    check (username = lower(username) and username ~ '^[a-z0-9_]{3,24}$'),
  constraint profiles_username_key unique (username)
);

-- Enables index-backed prefix searches on the discover screen.
create index if not exists profiles_username_pattern_idx
  on public.profiles (username text_pattern_ops);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  expiry_seconds integer not null check (expiry_seconds between 300 and 2592000),
  constraint conversations_expiry_after_creation check (expires_at > created_at)
);

create index if not exists conversations_expires_at_idx
  on public.conversations (expires_at);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_read_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index if not exists conversation_members_user_idx
  on public.conversation_members (user_id);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('text', 'file', 'voice')),
  body text,
  attachment_name text,
  attachment_mime text,
  attachment_size integer,
  duration_ms integer,
  client_id uuid not null,
  created_at timestamptz not null default now(),
  constraint messages_text_body check (
    kind <> 'text' or (body is not null and length(body) between 1 and 4000)
  ),
  constraint messages_attachment_meta check (
    kind not in ('file', 'voice')
    or (
      attachment_name is not null
      and attachment_mime is not null
      and attachment_size is not null
      and attachment_size between 1 and 5242880
    )
  ),
  constraint messages_voice_duration check (
    kind <> 'voice' or (duration_ms is not null and duration_ms between 500 and 600000)
  ),
  constraint messages_client_id_key unique (conversation_id, sender_id, client_id)
);

create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at, id);

-- File bytes are separated from message metadata so Realtime never broadcasts
-- the payload. Fetch on demand through get_attachment().
create table if not exists public.message_attachments (
  message_id uuid primary key references public.messages (id) on delete cascade,
  data bytea not null,
  constraint message_attachments_size check (octet_length(data) between 1 and 5242880)
);

-- A DELETE event's old conversation row cannot pass RLS after its member rows
-- are cascaded away. This tombstone records the member ids before the delete so
-- both clients receive a Realtime notice and can leave the chat immediately.
-- It contains no message content and is removed by the purge job.
create table if not exists public.conversation_deletions (
  conversation_id uuid primary key,
  member_ids uuid[] not null,
  deleted_at timestamptz not null default now()
);

create index if not exists conversation_deletions_deleted_at_idx
  on public.conversation_deletions (deleted_at);

-- ---------------------------------------------------------------------------
-- 2. Integrity triggers
-- ---------------------------------------------------------------------------

-- A conversation is exactly two people. Constraint triggers are deferred, so
-- start_conversation() can insert both members in one statement.
create or replace function public.check_conversation_member_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.conversation_members
  where conversation_id = new.conversation_id;

  if v_count <> 2 then
    raise exception 'A conversation must have exactly two members'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists conversation_members_max_two on public.conversation_members;
create constraint trigger conversation_members_max_two
after insert or update on public.conversation_members
deferrable initially deferred
for each row execute function public.check_conversation_member_count();

-- When a profile is deleted, every conversation the person belongs to is
-- deleted too, regardless of who created it. Cascades remove members,
-- messages, and attachment bytes.
create or replace function public.handle_profile_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.conversations
  where id in (
    select conversation_id
    from public.conversation_members
    where user_id = old.id
  );
  return old;
end;
$$;

drop trigger if exists profiles_burn_conversations on public.profiles;
create trigger profiles_burn_conversations
before delete on public.profiles
for each row execute function public.handle_profile_delete();

-- Capture the member list while it still exists so Realtime can deliver a
-- DELETE notice after the cascades have removed the conversation row.
create or replace function public.record_conversation_deletion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.conversation_deletions (conversation_id, member_ids)
  values (
    old.id,
    coalesce(
      array(
        select user_id
        from public.conversation_members
        where conversation_id = old.id
      ),
      '{}'::uuid[]
    )
  )
  on conflict (conversation_id) do nothing;
  return old;
end;
$$;

drop trigger if exists conversations_record_deletion on public.conversations;
create trigger conversations_record_deletion
before delete on public.conversations
for each row execute function public.record_conversation_deletion();

-- ---------------------------------------------------------------------------
-- 3. Access helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
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
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.messages m
    where m.id = p_message_id
      and public.is_conversation_member(m.conversation_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- 4. Row level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_attachments enable row level security;
alter table public.conversation_deletions enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
for select to authenticated
using (
  id = auth.uid()
  or exists (
    select 1
    from public.conversation_members me
    join public.conversations c
      on c.id = me.conversation_id and c.expires_at > now()
    join public.conversation_members them
      on them.conversation_id = me.conversation_id
    where me.user_id = auth.uid()
      and them.user_id = profiles.id
  )
);

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations
for select to authenticated
using (public.is_conversation_member(id));

drop policy if exists conversation_members_select on public.conversation_members;
create policy conversation_members_select on public.conversation_members
for select to authenticated
using (public.is_conversation_member(conversation_id));

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
for select to authenticated
using (public.is_conversation_member(conversation_id));

drop policy if exists message_attachments_select on public.message_attachments;
create policy message_attachments_select on public.message_attachments
for select to authenticated
using (public.can_access_message(message_id));

drop policy if exists conversation_deletions_select on public.conversation_deletions;
create policy conversation_deletions_select on public.conversation_deletions
for select to authenticated
using (auth.uid() = any(member_ids));

-- All writes go through the SECURITY DEFINER RPCs below. Direct table writes
-- are denied, which keeps validation and cascading deletes in one place.
revoke all on public.profiles from anon, authenticated;
revoke all on public.conversations from anon, authenticated;
revoke all on public.conversation_members from anon, authenticated;
revoke all on public.messages from anon, authenticated;
revoke all on public.message_attachments from anon, authenticated;
revoke all on public.conversation_deletions from anon, authenticated;

grant select on public.profiles to authenticated;
grant select on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant select on public.messages to authenticated;
grant select on public.message_attachments to authenticated;
grant select on public.conversation_deletions to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Account RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_profile(p_username text)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_username text := lower(trim(p_username));
  v_profile public.profiles;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if v_username is null or v_username !~ '^[a-z0-9_]{3,24}$' then
    raise exception 'invalid_username' using errcode = '22023';
  end if;

  if v_username in (
    'admin', 'administrator', 'support', 'system', 'provisional',
    'moderator', 'mod', 'help', 'everyone', 'here'
  ) then
    raise exception 'reserved_username' using errcode = '22023';
  end if;

  if exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'profile_exists' using errcode = 'P0001';
  end if;

  begin
    insert into public.profiles (id, username, accent)
    values (
      v_uid,
      v_username,
      (abs(hashtextextended(v_username, 0)) % 6)::smallint
    )
    returning * into v_profile;
  exception
    when unique_violation then
      -- Two simultaneous calls can both pass the pre-check. If this user now
      -- owns a profile, let the client adopt it instead of showing "taken".
      if exists (select 1 from public.profiles where id = v_uid) then
        raise exception 'profile_exists' using errcode = 'P0001';
      end if;
      raise exception 'username_taken' using errcode = 'P0001';
  end;

  return v_profile;
end;
$$;

drop function if exists public.get_my_profile();

create or replace function public.get_my_profile()
returns setof public.profiles
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.profiles where id = auth.uid();
$$;

create or replace function public.search_profiles(p_query text)
returns table (
  profile_id uuid,
  profile_username text,
  profile_accent smallint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_query text := lower(trim(p_query));
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  -- Three characters matches the minimum username length and keeps two-letter
  -- enumeration useless. Underscore is escaped because it is a LIKE wildcard.
  if v_query is null
     or length(v_query) < 3
     or v_query !~ '^[a-z0-9_]{3,24}$' then
    return;
  end if;

  return query
  select p.id, p.username, p.accent
  from public.profiles p
  where p.id <> v_uid
    and p.username like
      replace(replace(v_query, '\', '\\'), '_', '\_') || '%' escape '\'
  order by (p.username = v_query) desc, p.username asc
  limit 20;
end;
$$;

-- Best-effort full account removal. The profile and all content are deleted
-- first; deleting the opaque Supabase anonymous auth row is attempted last.
-- If the SQL role cannot touch auth.users, the content deletion still stands.
create or replace function public.burn_profile()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  delete from public.conversations
  where id in (
    select conversation_id
    from public.conversation_members
    where user_id = v_uid
  );

  delete from public.profiles where id = v_uid;

  begin
    delete from auth.users where id = v_uid;
  exception
    when others then
      -- Profile and conversation deletion already succeeded. The remaining
      -- auth row is an opaque UUID with no username or content, but surface
      -- the failure so operators can see it in the database logs.
      raise notice 'profile % burned, but auth user % could not be deleted: %',
        v_uid, v_uid, sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Conversation RPCs
-- ---------------------------------------------------------------------------

create or replace function public.start_conversation(
  p_other_user_id uuid,
  p_expiry_seconds integer default 86400
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_expiry integer := coalesce(p_expiry_seconds, 86400);
  v_lock_key text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  if p_other_user_id is null or p_other_user_id = v_uid then
    raise exception 'invalid_recipient' using errcode = '22023';
  end if;

  if v_expiry < 300 or v_expiry > 2592000 then
    raise exception 'invalid_expiry' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_other_user_id) then
    raise exception 'recipient_not_found' using errcode = 'P0002';
  end if;

  -- Serialize simultaneous "start chat" taps for the same pair.
  v_lock_key := least(v_uid::text, p_other_user_id::text)
    || ':' || greatest(v_uid::text, p_other_user_id::text);
  perform pg_advisory_xact_lock(hashtextextended(v_lock_key, 0));

  select c.id into v_id
  from public.conversations c
  where c.expires_at > now()
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = c.id and m.user_id = v_uid
    )
    and exists (
      select 1 from public.conversation_members m
      where m.conversation_id = c.id and m.user_id = p_other_user_id
    )
  order by c.created_at desc
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  insert into public.conversations (created_by, expires_at, expiry_seconds)
  values (v_uid, now() + make_interval(secs => v_expiry), v_expiry)
  returning id into v_id;

  insert into public.conversation_members (conversation_id, user_id)
  values (v_id, v_uid), (v_id, p_other_user_id);

  return v_id;
end;
$$;

create or replace function public.set_conversation_expiry(
  p_conversation_id uuid,
  p_expiry_seconds integer
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_expires timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if p_expiry_seconds is null
     or p_expiry_seconds < 300
     or p_expiry_seconds > 2592000 then
    raise exception 'invalid_expiry' using errcode = '22023';
  end if;

  if not public.is_conversation_member(p_conversation_id) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  update public.conversations
  set expiry_seconds = p_expiry_seconds,
      expires_at = now() + make_interval(secs => p_expiry_seconds),
      updated_at = now()
  where id = p_conversation_id
  returning expires_at into v_expires;

  return v_expires;
end;
$$;

create or replace function public.mark_conversation_read(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  update public.conversation_members
  set last_read_at = now()
  where conversation_id = p_conversation_id
    and user_id = auth.uid()
    and exists (
      select 1 from public.conversations c
      where c.id = p_conversation_id and c.expires_at > now()
    );
end;
$$;

create or replace function public.burn_conversation(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  -- Deliberately ignores expiry: a member can still burn an already-expired
  -- conversation if the cleanup job has not reached it yet.
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = auth.uid()
  ) then
    raise exception 'conversation_not_found' using errcode = 'P0002';
  end if;

  delete from public.conversations where id = p_conversation_id;
end;
$$;

create or replace function public.list_conversations()
returns table (
  conversation_id uuid,
  partner_id uuid,
  partner_username text,
  partner_accent smallint,
  expires_at timestamptz,
  expiry_seconds integer,
  created_at timestamptz,
  last_message_at timestamptz,
  last_message_kind text,
  last_message_body text,
  last_message_attachment_name text,
  last_message_sender_id uuid,
  unread_count integer,
  partner_last_read_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id,
    p.id,
    p.username,
    p.accent,
    c.expires_at,
    c.expiry_seconds,
    c.created_at,
    lm.created_at,
    lm.kind,
    lm.body,
    lm.attachment_name,
    lm.sender_id,
    coalesce((
      select count(*)::integer
      from public.messages m2
      where m2.conversation_id = c.id
        and m2.sender_id <> auth.uid()
        and m2.created_at > cm.last_read_at
    ), 0),
    other_cm.last_read_at
  from public.conversations c
  join public.conversation_members cm
    on cm.conversation_id = c.id and cm.user_id = auth.uid()
  join public.conversation_members other_cm
    on other_cm.conversation_id = c.id and other_cm.user_id <> auth.uid()
  join public.profiles p on p.id = other_cm.user_id
  left join lateral (
    select m.kind, m.body, m.attachment_name, m.sender_id, m.created_at
    from public.messages m
    where m.conversation_id = c.id
    order by m.created_at desc
    limit 1
  ) lm on true
  where c.expires_at > now()
  order by coalesce(lm.created_at, c.created_at) desc;
$$;

create or replace function public.get_conversation(p_conversation_id uuid)
returns table (
  conversation_id uuid,
  partner_id uuid,
  partner_username text,
  partner_accent smallint,
  expires_at timestamptz,
  expiry_seconds integer,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.id, p.id, p.username, p.accent, c.expires_at, c.expiry_seconds, c.created_at
  from public.conversations c
  join public.conversation_members me
    on me.conversation_id = c.id and me.user_id = auth.uid()
  join public.conversation_members other_cm
    on other_cm.conversation_id = c.id and other_cm.user_id <> auth.uid()
  join public.profiles p on p.id = other_cm.user_id
  where c.id = p_conversation_id
    and c.expires_at > now();
$$;

-- ---------------------------------------------------------------------------
-- 7. Message RPCs
-- ---------------------------------------------------------------------------

create or replace function public.send_text_message(
  p_conversation_id uuid,
  p_client_id uuid,
  p_body text
)
returns public.messages
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := trim(p_body);
  v_msg public.messages;
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

  select * into v_msg
  from public.messages
  where conversation_id = p_conversation_id
    and sender_id = v_uid
    and client_id = p_client_id;

  if found then
    return v_msg;
  end if;

  begin
    insert into public.messages (conversation_id, sender_id, kind, body, client_id)
    values (p_conversation_id, v_uid, 'text', v_body, p_client_id)
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

create or replace function public.send_attachment_message(
  p_conversation_id uuid,
  p_client_id uuid,
  p_kind text,
  p_file_name text,
  p_mime text,
  p_duration_ms integer,
  p_data_base64 text
)
returns public.messages
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_kind text := lower(trim(p_kind));
  v_name text := nullif(trim(p_file_name), '');
  v_mime text := nullif(trim(p_mime), '');
  v_data bytea;
  v_size integer;
  v_msg public.messages;
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

  if v_kind = 'voice' and (
    p_duration_ms is null or p_duration_ms < 500 or p_duration_ms > 600000
  ) then
    raise exception 'invalid_voice_duration' using errcode = '22023';
  end if;

  if v_kind = 'voice' and v_mime not like 'audio/%' then
    raise exception 'invalid_voice_mime' using errcode = '22023';
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

  begin
    insert into public.messages (
      conversation_id, sender_id, kind, attachment_name, attachment_mime,
      attachment_size, duration_ms, client_id
    )
    values (
      p_conversation_id, v_uid, v_kind, v_name, v_mime,
      v_size, p_duration_ms, p_client_id
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

create or replace function public.get_attachment(p_message_id uuid)
returns table (
  file_name text,
  mime_type text,
  byte_size integer,
  data_base64 text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.attachment_name, m.attachment_mime, m.attachment_size,
         encode(a.data, 'base64')
  from public.messages m
  join public.message_attachments a on a.message_id = m.id
  where m.id = p_message_id
    and public.is_conversation_member(m.conversation_id);
$$;

drop function if exists public.get_messages(uuid, timestamptz, integer);

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
  is_read boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
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
      end as is_read
    from public.messages m
    join public.profiles p on p.id = m.sender_id
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
-- 8. Expiry cleanup
-- ---------------------------------------------------------------------------

create or replace function public.purge_expired_conversations()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  -- Delete in bounded batches so a backlog cannot lock the whole table or
  -- blow up the WAL in one cron run. The next minute picks up the rest.
  with batch as (
    select id
    from public.conversations
    where expires_at <= now()
    order by expires_at
    limit 1000
  ), deleted as (
    delete from public.conversations
    where id in (select id from batch)
    returning 1
  )
  select count(*) into v_count from deleted;

  delete from public.conversation_deletions
  where deleted_at < now() - interval '1 hour';

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Connection probe
-- ---------------------------------------------------------------------------

-- Used by the app's setup screen to confirm the URL/key are correct and this
-- SQL has been installed, before any account is created.
create or replace function public.health_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cron_ok boolean := false;
begin
  if to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = $1)'
      into v_cron_ok using 'provisional-purge-expired';
  end if;

  return jsonb_build_object(
    'ok',
      to_regclass('public.profiles') is not null
      and to_regclass('public.conversations') is not null
      and to_regclass('public.conversation_members') is not null
      and to_regclass('public.messages') is not null
      and to_regclass('public.message_attachments') is not null,
    'app', 'provisional-messenger',
    'schema_version', 2,
    'cron_ok', v_cron_ok
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Function privileges
-- ---------------------------------------------------------------------------

revoke all on function public.create_profile(text) from public, anon;
revoke all on function public.get_my_profile() from public, anon;
revoke all on function public.search_profiles(text) from public, anon;
revoke all on function public.burn_profile() from public, anon;
revoke all on function public.start_conversation(uuid, integer) from public, anon;
revoke all on function public.set_conversation_expiry(uuid, integer) from public, anon;
revoke all on function public.mark_conversation_read(uuid) from public, anon;
revoke all on function public.burn_conversation(uuid) from public, anon;
revoke all on function public.list_conversations() from public, anon;
revoke all on function public.get_conversation(uuid) from public, anon;
revoke all on function public.send_text_message(uuid, uuid, text) from public, anon;
revoke all on function public.send_attachment_message(uuid, uuid, text, text, text, integer, text) from public, anon;
revoke all on function public.get_attachment(uuid) from public, anon;
revoke all on function public.get_messages(uuid, timestamptz, integer, uuid) from public, anon;
revoke all on function public.purge_expired_conversations() from public, anon, authenticated;
revoke all on function public.is_conversation_member(uuid) from public, anon;
revoke all on function public.can_access_message(uuid) from public, anon;
revoke all on function public.check_conversation_member_count() from public, anon, authenticated;
revoke all on function public.handle_profile_delete() from public, anon, authenticated;
revoke all on function public.record_conversation_deletion() from public, anon, authenticated;
revoke all on function public.health_check() from public, anon;

grant execute on function public.create_profile(text) to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.search_profiles(text) to authenticated;
grant execute on function public.burn_profile() to authenticated;
grant execute on function public.start_conversation(uuid, integer) to authenticated;
grant execute on function public.set_conversation_expiry(uuid, integer) to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.burn_conversation(uuid) to authenticated;
grant execute on function public.list_conversations() to authenticated;
grant execute on function public.get_conversation(uuid) to authenticated;
grant execute on function public.send_text_message(uuid, uuid, text) to authenticated;
grant execute on function public.send_attachment_message(uuid, uuid, text, text, text, integer, text) to authenticated;
grant execute on function public.get_attachment(uuid) to authenticated;
grant execute on function public.get_messages(uuid, timestamptz, integer, uuid) to authenticated;
grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.can_access_message(uuid) to authenticated;
grant execute on function public.health_check() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11. Realtime
-- ---------------------------------------------------------------------------

do $$
begin
  begin
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'messages'
    ) then
      execute 'alter publication supabase_realtime add table public.messages';
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'conversations'
    ) then
      execute 'alter publication supabase_realtime add table public.conversations';
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'conversation_members'
    ) then
      execute 'alter publication supabase_realtime add table public.conversation_members';
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'conversation_deletions'
    ) then
      execute 'alter publication supabase_realtime add table public.conversation_deletions';
    end if;
  exception
    when undefined_object then
      raise notice 'supabase_realtime publication not found; enable Realtime in the dashboard.';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Minute-level expiry cleanup
-- ---------------------------------------------------------------------------

do $$
begin
  begin
    create extension if not exists pg_cron;
  exception
    when others then
      raise notice 'pg_cron could not be enabled. Enable it under Database -> Extensions, then re-run section 12.';
  end;

  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'provisional-purge-expired') then
      perform cron.unschedule('provisional-purge-expired');
    end if;

    perform cron.schedule(
      'provisional-purge-expired',
      '* * * * *',
      'select public.purge_expired_conversations();'
    );
  end if;
end;
$$;

-- PostgREST caches the function list. Reload it now so the setup screen's
-- health_check() call works immediately instead of after a dashboard refresh.
notify pgrst, 'reload schema';

-- Done.

