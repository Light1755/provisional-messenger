-- Idempotent update for the live schema_version 5 database: profiles are
-- released for reuse after 48 hours without a presence check-in. The app's
-- touch_presence() call keeps an open app active; the anonymous auth user is
-- deliberately left in place so the same device can claim a new username.
-- Safe to run repeatedly: guarded drops, CREATE OR REPLACE, and cron discovery.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Inactive-profile expiry function
-- ---------------------------------------------------------------------------

drop function if exists public.expire_inactive_profiles();

create or replace function public.expire_inactive_profiles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Presence is authoritative once it exists; a profile that never checked in
  -- ages from its creation time. The profiles_burn_conversations trigger
  -- cascades conversations, messages, reactions, and attachment bytes. No auth
  -- row is deleted, so the device can still create a fresh profile.
  with expired as (
    select p.id
    from public.profiles p
    left join public.user_presence up on up.user_id = p.id
    where coalesce(up.last_seen, p.created_at) < now() - interval '48 hours'
  ), deleted as (
    delete from public.profiles p
    where p.id in (select id from expired)
    returning 1
  )
  select count(*) into v_count from deleted;

  return v_count;
end;
$$;

-- pg_cron calls this as the function owner. Clients must never be able to
-- expire an account directly, so there is deliberately no grant.
revoke all on function public.expire_inactive_profiles() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Health check: both cron jobs must be active (schema_version 6)
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
  v_purge_ok boolean := false;
  v_expire_ok boolean := false;
  v_cron_ok boolean := false;
begin
  v_cron_schema := public.cron_schema_name();

  if v_cron_schema is not null then
    execute format(
      'select exists (select 1 from %I.job where jobname = $1 and active)',
      v_cron_schema
    ) into v_purge_ok using 'provisional-purge-expired';

    execute format(
      'select exists (select 1 from %I.job where jobname = $1 and active)',
      v_cron_schema
    ) into v_expire_ok using 'provisional-expire-inactive-profiles';

    v_cron_ok := v_purge_ok and v_expire_ok;
  end if;

  return jsonb_build_object(
    'ok',
      to_regclass('public.profiles') is not null
      and to_regclass('public.conversations') is not null
      and to_regclass('public.conversation_members') is not null
      and to_regclass('public.messages') is not null
      and to_regclass('public.message_attachments') is not null,
    'app', 'provisional-messenger',
    'schema_version', 6,
    'cron_ok', v_cron_ok,
    'server_now', now()
  );
end;
$$;

-- CREATE OR REPLACE keeps existing ACLs; these lines make the intended access
-- explicit even if the function was dropped and recreated on this database.
revoke all on function public.health_check() from public, anon;
grant execute on function public.health_check() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Hourly pg_cron job (the minute purge job is left untouched)
-- ---------------------------------------------------------------------------

do $$
declare
  v_cron_schema text;
  v_job_exists boolean := false;
begin
  begin
    create extension if not exists pg_cron;
  exception
    when others then
      raise notice 'pg_cron could not be enabled. Enable it under Database -> Extensions, then re-run section 3.';
  end;

  v_cron_schema := public.cron_schema_name();

  if v_cron_schema is not null then
    execute format(
      'select exists (select 1 from %I.job where jobname = $1)',
      v_cron_schema
    ) into v_job_exists using 'provisional-expire-inactive-profiles';

    if v_job_exists then
      execute format('select %I.unschedule($1)', v_cron_schema)
        using 'provisional-expire-inactive-profiles';
    end if;

    execute format('select %I.schedule($1, $2, $3)', v_cron_schema)
      using
        'provisional-expire-inactive-profiles',
        '0 * * * *',
        'select public.expire_inactive_profiles();';
  else
    raise notice 'pg_cron is not installed. Enable it under Database -> Extensions, then re-run section 3.';
  end if;
end;
$$;

notify pgrst, 'reload schema';
