-- B Technica — project contacts (additive).
--
-- Companies and people are user-owned address book entries (owner_id), like
-- contractors. project_contacts links either a company or a person to a project
-- with a project-specific role; one contact can be linked to many projects.
-- Project members can read contacts linked to their projects; only the owner
-- edits the contact record itself.

-- ---------------------------------------------------------------------------
-- Companies
-- ---------------------------------------------------------------------------

create table public.contact_companies (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  trade text,
  tax_id text,
  phone text,
  email text,
  website text,
  address text,
  notes text,
  -- false = project-only contact, hidden from the address book picker
  in_address_book boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  -- Target for the same-owner FK from contact_people
  unique (id, owner_id)
);

create index contact_companies_owner_id_idx
  on public.contact_companies (owner_id)
  where deleted_at is null;

create trigger contact_companies_set_updated_at
  before update on public.contact_companies
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------

create table public.contact_people (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  company_id uuid,
  first_name text not null,
  last_name text not null default '',
  job_title text,
  phone text,
  email text,
  notes text,
  in_address_book boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  check (char_length(trim(first_name || last_name)) > 0),
  -- Employer must belong to the same owner; deleting it clears company_id only.
  foreign key (company_id, owner_id)
    references public.contact_companies (id, owner_id)
    on delete set null (company_id)
);

create index contact_people_owner_id_idx
  on public.contact_people (owner_id)
  where deleted_at is null;

create index contact_people_company_id_idx
  on public.contact_people (company_id)
  where deleted_at is null;

create trigger contact_people_set_updated_at
  before update on public.contact_people
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Project ↔ contact links
-- ---------------------------------------------------------------------------

create table public.project_contacts (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  company_id uuid references public.contact_companies (id) on delete cascade,
  person_id uuid references public.contact_people (id) on delete cascade,
  role text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  check (num_nonnulls(company_id, person_id) = 1)
);

create unique index project_contacts_project_company_active_uidx
  on public.project_contacts (project_id, company_id)
  where deleted_at is null and company_id is not null;

create unique index project_contacts_project_person_active_uidx
  on public.project_contacts (project_id, person_id)
  where deleted_at is null and person_id is not null;

create index project_contacts_project_id_idx
  on public.project_contacts (project_id)
  where deleted_at is null;

create index project_contacts_company_id_idx
  on public.project_contacts (company_id)
  where company_id is not null;

create index project_contacts_person_id_idx
  on public.project_contacts (person_id)
  where person_id is not null;

create trigger project_contacts_set_updated_at
  before update on public.project_contacts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Visibility helper
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER so contact policies can consult project_contacts without
-- recursing into project_contacts RLS (whose write checks read contacts).
create or replace function public.is_contact_in_my_projects(
  p_company_id uuid,
  p_person_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.project_contacts pc
    where pc.deleted_at is null
      and (pc.company_id = p_company_id or pc.person_id = p_person_id)
      and public.is_project_member(pc.project_id)
  );
$$;

revoke all on function public.is_contact_in_my_projects(uuid, uuid) from public;
grant execute on function public.is_contact_in_my_projects(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.contact_companies enable row level security;
alter table public.contact_people enable row level security;
alter table public.project_contacts enable row level security;

-- Companies

create policy contact_companies_select
  on public.contact_companies for select to authenticated
  using (
    deleted_at is null
    and (owner_id = auth.uid() or public.is_contact_in_my_projects(id, null))
  );

-- Tombstones: soft-delete UPDATE ... RETURNING must pass SELECT RLS.
create policy contact_companies_select_tombstones
  on public.contact_companies for select to authenticated
  using (deleted_at is not null and owner_id = auth.uid());

create policy contact_companies_insert_own
  on public.contact_companies for insert to authenticated
  with check (owner_id = auth.uid());

create policy contact_companies_update_own
  on public.contact_companies for update to authenticated
  using (owner_id = auth.uid() and deleted_at is null)
  with check (owner_id = auth.uid());

create policy contact_companies_delete_own
  on public.contact_companies for delete to authenticated
  using (owner_id = auth.uid());

-- People

create policy contact_people_select
  on public.contact_people for select to authenticated
  using (
    deleted_at is null
    and (owner_id = auth.uid() or public.is_contact_in_my_projects(null, id))
  );

create policy contact_people_select_tombstones
  on public.contact_people for select to authenticated
  using (deleted_at is not null and owner_id = auth.uid());

create policy contact_people_insert_own
  on public.contact_people for insert to authenticated
  with check (owner_id = auth.uid());

create policy contact_people_update_own
  on public.contact_people for update to authenticated
  using (owner_id = auth.uid() and deleted_at is null)
  with check (owner_id = auth.uid());

create policy contact_people_delete_own
  on public.contact_people for delete to authenticated
  using (owner_id = auth.uid());

-- Project links: members read; editors write, and may only link contacts
-- they can already see (own address book or shared through another project).

create policy project_contacts_select
  on public.project_contacts for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy project_contacts_select_tombstones
  on public.project_contacts for select to authenticated
  using (deleted_at is not null and public.is_project_member(project_id));

create policy project_contacts_insert
  on public.project_contacts for insert to authenticated
  with check (
    public.can_edit_project(project_id)
    and (
      project_contacts.company_id is null
      or exists (select 1 from public.contact_companies c where c.id = project_contacts.company_id)
    )
    and (
      project_contacts.person_id is null
      or exists (select 1 from public.contact_people p where p.id = project_contacts.person_id)
    )
  );

create policy project_contacts_update
  on public.project_contacts for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (
    public.can_edit_project(project_id)
    and (
      project_contacts.company_id is null
      or exists (select 1 from public.contact_companies c where c.id = project_contacts.company_id)
    )
    and (
      project_contacts.person_id is null
      or exists (select 1 from public.contact_people p where p.id = project_contacts.person_id)
    )
  );

create policy project_contacts_delete
  on public.project_contacts for delete to authenticated
  using (public.can_edit_project(project_id));

-- Privileges come from the default privileges in 20251018190800_grants.sql;
-- stated explicitly so this migration is self-contained.
grant select, insert, update, delete
  on public.contact_companies, public.contact_people, public.project_contacts
  to authenticated;
