-- Shared context log for the VBT build. Two jobs: carry decisions from one ticket to the next, and
-- record every place the AI was wrong and how it was caught. Insert-only. Rows are written only
-- through log_context() and log_context_batch(), which stamp the author from the caller's sign-in,
-- so nobody can write as someone else. A wrong row is never edited: a new row with ref set to it
-- replaces it, and search_context() stops returning the old one.

-- Identity ---------------------------------------------------------------------------------------
-- One Supabase user per writer (factory-dispatch, austin-claude, shawn-claude), created by
-- scripts/provision.ts. The agent id lives in the user's app_metadata, which only the secret key
-- can set, and counts only while it matches an active row in this registry. Agents are deactivated,
-- never deleted, so their log rows keep their author.

create table public.agents (
  id text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(id) <= 64),
  user_id uuid not null unique references auth.users (id),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create function public.current_agent() returns text
language sql stable set search_path = '' as $$
  select auth.jwt() -> 'app_metadata' ->> 'agent_id'
$$;

-- Whether the caller is an active registered agent: the token's agent id belongs to the token's
-- user. Runs as its owner, since the registry's own policy calls it.
create function public.is_agent() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.agents a
    where a.id = public.current_agent() and a.user_id = auth.uid() and a.active
  )
$$;

alter table public.agents enable row level security;

create policy agents_visible on public.agents for select to authenticated
  using (public.is_agent());

-- Log --------------------------------------------------------------------------------------------
-- source, commit_sha and entry_key are set for rows ingested from a merged pull request's
-- context-log block, and empty for rows logged by hand. (source, entry_key) is unique, so
-- re-ingesting the same pull request skips what is already there.

create table public.context_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  author text not null references public.agents (id),
  type text not null check (type in ('decision', 'correction')),
  topic text not null check (length(topic) between 1 and 80),
  body text not null check (length(body) between 1 and 1500),
  ref bigint references public.context_log (id),
  source text check (length(source) between 1 and 300),
  commit_sha text check (commit_sha ~ '^[0-9a-f]{40}$'),
  entry_key text check (length(entry_key) between 1 and 80),
  constraint source_has_key check ((source is null) = (entry_key is null)),
  constraint commit_has_source check (commit_sha is null or source is not null),
  constraint one_entry_per_source unique (source, entry_key),
  search tsvector generated always as (to_tsvector('english', topic || ' ' || body)) stored
);

create index context_log_search on public.context_log using gin (search);
create index context_log_topic on public.context_log (topic, created_at desc);
create index context_log_ref on public.context_log (ref);

-- Insert-only, for everyone but the project's own admin roles (so test rows can be cleaned up).
create function public.context_log_insert_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'context_log is insert-only; add a new row with ref set to the old one instead';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger context_log_insert_only
  before update or delete on public.context_log
  for each row execute function public.context_log_insert_only();

-- TRUNCATE skips row triggers, so it gets its own, with no exceptions. Dropping this trigger is the
-- deliberate way to wipe the table.
create function public.context_log_no_truncate() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'context_log cannot be truncated';
end;
$$;

create trigger context_log_no_truncate
  before truncate on public.context_log
  for each statement execute function public.context_log_no_truncate();

alter table public.context_log enable row level security;

create policy context_log_visible on public.context_log for select to authenticated
  using (public.is_agent());

-- Write path for one row logged by hand. Runs as its owner because callers have no insert grant.
create function public.log_context(p_type text, p_topic text, p_body text, p_ref bigint default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  new_id bigint;
begin
  if not public.is_agent() then
    raise exception 'only a registered agent can write to the context log';
  end if;
  insert into public.context_log (author, type, topic, body, ref)
  values (public.current_agent(), p_type, btrim(p_topic), btrim(p_body), p_ref)
  returning id into new_id;
  return new_id;
end;
$$;

-- Write path for one merged pull request's entries, in a single statement: all rows go in or none
-- do. p_entries is a JSON array of {entry_key, type, topic, body, ref?}. Entries whose
-- (source, entry_key) is already logged are skipped. Returns the rows actually inserted.
create function public.log_context_batch(p_source text, p_commit_sha text, p_entries jsonb)
returns table (entry_key text, id bigint)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if not public.is_agent() then
    raise exception 'only a registered agent can write to the context log';
  end if;
  if p_source is null then
    raise exception 'a batch needs its source pull request URL';
  end if;
  if jsonb_typeof(p_entries) is distinct from 'array' then
    raise exception 'entries must be a JSON array';
  end if;
  return query
    with inserted as (
      insert into public.context_log (author, type, topic, body, ref, source, commit_sha, entry_key)
      select public.current_agent(), e.entry ->> 'type', btrim(e.entry ->> 'topic'), btrim(e.entry ->> 'body'),
        (e.entry ->> 'ref')::bigint, p_source, p_commit_sha, e.entry ->> 'entry_key'
      from jsonb_array_elements(p_entries) with ordinality as e(entry, n)
      order by e.n
      on conflict on constraint one_entry_per_source do nothing
      returning context_log.entry_key, context_log.id
    )
    select inserted.entry_key, inserted.id from inserted;
end;
$$;

-- Full-text search over topic and body, current entries only: a row that a later row's ref points
-- to has been replaced and is left out. An empty query returns the newest rows. Runs as the caller,
-- so the select policy applies.
create function public.search_context(
  p_query text default '', p_topic text default null, p_type text default null,
  p_since timestamptz default null, p_limit int default 20
)
returns table (
  id bigint, created_at timestamptz, author text, type text, topic text, body text, ref bigint,
  source text, commit_sha text
)
language sql stable set search_path = '' as $$
  select c.id, c.created_at, c.author, c.type, c.topic, c.body, c.ref, c.source, c.commit_sha
  from public.context_log c
  where (coalesce(btrim(p_query), '') = '' or c.search @@ websearch_to_tsquery('english', p_query))
    and (p_topic is null or c.topic = p_topic)
    and (p_type is null or c.type = p_type)
    and (p_since is null or c.created_at >= p_since)
    and not exists (select 1 from public.context_log later where later.ref = c.id)
  order by c.created_at desc, c.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 100)
$$;

-- Grants -----------------------------------------------------------------------------------------
-- Supabase grants every new table and function to anon and authenticated. Take that back for each
-- object made here, then grant only reads and the functions callers need.

revoke all on public.agents, public.context_log from anon, authenticated;
grant select on public.agents, public.context_log to authenticated;

revoke execute on function public.current_agent() from public, anon, authenticated;
revoke execute on function public.is_agent() from public, anon, authenticated;
revoke execute on function public.context_log_insert_only() from public, anon, authenticated;
revoke execute on function public.context_log_no_truncate() from public, anon, authenticated;
revoke execute on function public.log_context(text, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.log_context_batch(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_context(text, text, text, timestamptz, int)
  from public, anon, authenticated;

-- is_agent() is granted because the select policies call it as the caller.
grant execute on function public.is_agent(), public.log_context(text, text, text, bigint),
  public.log_context_batch(text, text, jsonb), public.search_context(text, text, text, timestamptz, int)
  to authenticated;
