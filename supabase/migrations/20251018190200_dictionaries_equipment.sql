-- B Technica v2 — user-owned dictionaries and equipment inventory.

-- ---------------------------------------------------------------------------
-- Contractors (global to owning user)
-- ---------------------------------------------------------------------------

create table public.contractors (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index contractors_owner_name_active_uidx
  on public.contractors (owner_id, lower(name))
  where deleted_at is null;

create index contractors_owner_id_idx
  on public.contractors (owner_id)
  where deleted_at is null;

create trigger contractors_set_updated_at
  before update on public.contractors
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Disciplines (global to owning user)
-- ---------------------------------------------------------------------------

create table public.disciplines (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index disciplines_owner_name_active_uidx
  on public.disciplines (owner_id, lower(name))
  where deleted_at is null;

create index disciplines_owner_id_idx
  on public.disciplines (owner_id)
  where deleted_at is null;

create trigger disciplines_set_updated_at
  before update on public.disciplines
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Issue types (project-scoped, customizable tags)
-- ---------------------------------------------------------------------------

create table public.issue_types (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  color text,
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index issue_types_project_name_active_uidx
  on public.issue_types (project_id, lower(name))
  where deleted_at is null;

create index issue_types_project_id_idx
  on public.issue_types (project_id)
  where deleted_at is null;

create trigger issue_types_set_updated_at
  before update on public.issue_types
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Equipment (global to owning user)
-- ---------------------------------------------------------------------------

create type public.equipment_status as enum (
  'available',
  'issued',
  'returned',
  'damaged',
  'lost'
);

create type public.equipment_event_type as enum (
  'created',
  'issued',
  'returned',
  'markedDamaged',
  'markedLost',
  'edited'
);

create table public.equipment_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  category text,
  identifier text,
  notes text,
  status public.equipment_status not null default 'available',
  issued_to text,
  location text,
  issued_at timestamptz,
  returned_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index equipment_items_owner_id_idx
  on public.equipment_items (owner_id)
  where deleted_at is null;

create index equipment_items_status_idx
  on public.equipment_items (owner_id, status)
  where deleted_at is null;

create trigger equipment_items_set_updated_at
  before update on public.equipment_items
  for each row execute function public.set_updated_at();

create table public.equipment_events (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment_items (id) on delete cascade,
  event_type public.equipment_event_type not null,
  event_at timestamptz not null default timezone('utc', now()),
  person text,
  location text,
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index equipment_events_equipment_id_idx
  on public.equipment_events (equipment_id, event_at desc)
  where deleted_at is null;

create trigger equipment_events_set_updated_at
  before update on public.equipment_events
  for each row execute function public.set_updated_at();

-- Equipment ↔ project assignment (inventory remains user-owned)
create table public.equipment_project_assignments (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment_items (id) on delete cascade,
  project_id uuid not null references public.projects (id) on delete cascade,
  assigned_at timestamptz not null default timezone('utc', now()),
  unassigned_at timestamptz,
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index equipment_project_active_uidx
  on public.equipment_project_assignments (equipment_id, project_id)
  where deleted_at is null and unassigned_at is null;

create index equipment_project_assignments_project_id_idx
  on public.equipment_project_assignments (project_id)
  where deleted_at is null;

create trigger equipment_project_assignments_set_updated_at
  before update on public.equipment_project_assignments
  for each row execute function public.set_updated_at();
