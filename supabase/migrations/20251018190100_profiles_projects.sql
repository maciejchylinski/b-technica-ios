-- B Technica v2 — auth profiles, projects, membership.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.project_role as enum ('owner', 'editor', 'viewer');

-- ---------------------------------------------------------------------------
-- Profiles (1:1 with auth.users)
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  active_project_id uuid,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete restrict,
  name text not null check (char_length(trim(name)) > 0),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index projects_owner_id_idx
  on public.projects (owner_id)
  where deleted_at is null;

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

-- Deferred FK: profiles.active_project_id → projects.id
alter table public.profiles
  add constraint profiles_active_project_id_fkey
  foreign key (active_project_id) references public.projects (id)
  on delete set null;

-- ---------------------------------------------------------------------------
-- Project members (collaboration-ready)
-- ---------------------------------------------------------------------------

create table public.project_members (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.project_role not null default 'viewer',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index project_members_project_user_active_uidx
  on public.project_members (project_id, user_id)
  where deleted_at is null;

create index project_members_user_id_idx
  on public.project_members (user_id)
  where deleted_at is null;

create trigger project_members_set_updated_at
  before update on public.project_members
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Membership helpers (after project_members exists)
-- ---------------------------------------------------------------------------

-- Resolve caller id the same way Supabase auth.uid() does (claim.sub or claims JSON).
create or replace function public.current_user_id()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

create or replace function public.is_project_member(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.project_members pm
    where pm.project_id = p_project_id
      and pm.user_id = public.current_user_id()
      and pm.deleted_at is null
  );
$$;

create or replace function public.has_project_role(
  p_project_id uuid,
  p_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.project_members pm
    where pm.project_id = p_project_id
      and pm.user_id = public.current_user_id()
      and pm.deleted_at is null
      and pm.role::text = any (p_roles)
  );
$$;

create or replace function public.can_edit_project(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_project_role(p_project_id, array['owner', 'editor']);
$$;

revoke all on function public.current_user_id() from public;
revoke all on function public.is_project_member(uuid) from public;
revoke all on function public.has_project_role(uuid, text[]) from public;
revoke all on function public.can_edit_project(uuid) from public;

grant execute on function public.current_user_id() to authenticated;
grant execute on function public.is_project_member(uuid) to authenticated;
grant execute on function public.has_project_role(uuid, text[]) to authenticated;
grant execute on function public.can_edit_project(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Auto profile on signup
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Ensure project owner is always a member
-- ---------------------------------------------------------------------------

create or replace function public.ensure_project_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.project_members
    where project_id = new.id
      and user_id = new.owner_id
      and deleted_at is null
  ) then
    insert into public.project_members (project_id, user_id, role)
    values (new.id, new.owner_id, 'owner');
  end if;
  return new;
end;
$$;

create trigger projects_ensure_owner_member
  after insert on public.projects
  for each row execute function public.ensure_project_owner_membership();
