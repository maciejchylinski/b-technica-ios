-- B Technica v2 — areas (polygons) and issues (+ photos).

create type public.issue_status as enum (
  'open',
  'inProgress',
  'resolved',
  'closed'
);

-- ---------------------------------------------------------------------------
-- Areas: named polygons in PDF page coordinates
-- ---------------------------------------------------------------------------

create table public.areas (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  drawing_id uuid not null references public.drawings (id) on delete cascade,
  page_id uuid not null references public.drawing_pages (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  -- JSON array of { "x": number, "y": number } in PDF page coordinates.
  vertices jsonb not null,
  color text not null default '#007AFF',
  opacity real not null default 0.35
    check (opacity >= 0 and opacity <= 1),
  is_visible boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  constraint areas_vertices_is_array check (jsonb_typeof(vertices) = 'array'),
  constraint areas_vertices_min_points check (jsonb_array_length(vertices) >= 3)
);

create index areas_project_id_idx
  on public.areas (project_id)
  where deleted_at is null;

create index areas_drawing_id_idx
  on public.areas (drawing_id)
  where deleted_at is null;

create index areas_page_id_idx
  on public.areas (page_id)
  where deleted_at is null;

create trigger areas_set_updated_at
  before update on public.areas
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Issues: exactly one project; drawing / area / contractor optional
-- ---------------------------------------------------------------------------

create table public.issues (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  number integer not null check (number > 0),
  title text not null check (char_length(trim(title)) > 0),
  details text not null default '',
  status public.issue_status not null default 'open',
  issue_type_id uuid references public.issue_types (id) on delete set null,
  drawing_id uuid references public.drawings (id) on delete set null,
  page_id uuid references public.drawing_pages (id) on delete set null,
  -- Pin in PDF page coordinates (origin bottom-left). Null when no drawing pin.
  pdf_x double precision,
  pdf_y double precision,
  area_id uuid references public.areas (id) on delete set null,
  contractor_id uuid references public.contractors (id) on delete set null,
  discipline_id uuid references public.disciplines (id) on delete set null,
  -- Legacy free-text mirrors for migration / display when dictionary FK is null.
  contractor_name text,
  discipline_name text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  constraint issues_pin_requires_drawing check (
    (drawing_id is null and page_id is null and pdf_x is null and pdf_y is null)
    or (drawing_id is not null and page_id is not null and pdf_x is not null and pdf_y is not null)
  )
);

create unique index issues_project_number_active_uidx
  on public.issues (project_id, number)
  where deleted_at is null;

create index issues_project_id_idx
  on public.issues (project_id)
  where deleted_at is null;

create index issues_drawing_id_idx
  on public.issues (drawing_id)
  where deleted_at is null;

create index issues_status_idx
  on public.issues (project_id, status)
  where deleted_at is null;

create index issues_area_id_idx
  on public.issues (area_id)
  where deleted_at is null;

create trigger issues_set_updated_at
  before update on public.issues
  for each row execute function public.set_updated_at();

-- Per-project issue number counter (avoids race on max(number)+1)
create table public.project_issue_counters (
  project_id uuid primary key references public.projects (id) on delete cascade,
  next_number integer not null default 1 check (next_number > 0)
);

create or replace function public.allocate_issue_number(p_project_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_number integer;
begin
  insert into public.project_issue_counters (project_id, next_number)
  values (p_project_id, 2)
  on conflict (project_id) do update
    set next_number = public.project_issue_counters.next_number + 1
  returning next_number - 1 into v_number;

  return v_number;
end;
$$;

revoke all on function public.allocate_issue_number(uuid) from public;
grant execute on function public.allocate_issue_number(uuid) to authenticated;

create or replace function public.init_project_issue_counter()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.project_issue_counters (project_id, next_number)
  values (new.id, 1)
  on conflict do nothing;
  return new;
end;
$$;

create trigger projects_init_issue_counter
  after insert on public.projects
  for each row execute function public.init_project_issue_counter();

-- ---------------------------------------------------------------------------
-- Issue photos (bytes in Storage; metadata here)
-- ---------------------------------------------------------------------------

create table public.issue_photos (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues (id) on delete cascade,
  storage_path text not null check (char_length(trim(storage_path)) > 0),
  original_file_name text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index issue_photos_issue_id_idx
  on public.issue_photos (issue_id)
  where deleted_at is null;

create trigger issue_photos_set_updated_at
  before update on public.issue_photos
  for each row execute function public.set_updated_at();
