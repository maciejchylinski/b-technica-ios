-- B Technica v2 — drawing folders, drawings, revisions, pages, calibrations.

create type public.length_unit as enum ('mm', 'cm', 'm');

-- ---------------------------------------------------------------------------
-- Unlimited nested folders (user-defined names, no naming convention)
-- ---------------------------------------------------------------------------

create table public.drawing_folders (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  parent_folder_id uuid references public.drawing_folders (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  constraint drawing_folders_parent_not_self check (parent_folder_id is distinct from id)
);

create index drawing_folders_project_id_idx
  on public.drawing_folders (project_id)
  where deleted_at is null;

create index drawing_folders_parent_id_idx
  on public.drawing_folders (parent_folder_id)
  where deleted_at is null;

create unique index drawing_folders_sibling_name_active_uidx
  on public.drawing_folders (project_id, coalesce(parent_folder_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name))
  where deleted_at is null;

create trigger drawing_folders_set_updated_at
  before update on public.drawing_folders
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Drawings (logical sheet; PDF bytes live on revisions)
-- ---------------------------------------------------------------------------

create table public.drawings (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  folder_id uuid references public.drawing_folders (id) on delete set null,
  name text not null check (char_length(trim(name)) > 0),
  discipline text,
  location text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index drawings_project_id_idx
  on public.drawings (project_id)
  where deleted_at is null;

create index drawings_folder_id_idx
  on public.drawings (folder_id)
  where deleted_at is null;

create trigger drawings_set_updated_at
  before update on public.drawings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Revisions (separate records; one current revision per drawing)
-- ---------------------------------------------------------------------------

create table public.drawing_revisions (
  id uuid primary key default gen_random_uuid(),
  drawing_id uuid not null references public.drawings (id) on delete cascade,
  revision_label text,
  storage_path text not null check (char_length(trim(storage_path)) > 0),
  original_file_name text,
  page_count integer not null default 0 check (page_count >= 0),
  drawing_date date,
  is_current boolean not null default false,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index drawing_revisions_drawing_id_idx
  on public.drawing_revisions (drawing_id)
  where deleted_at is null;

create unique index drawing_revisions_one_current_uidx
  on public.drawing_revisions (drawing_id)
  where deleted_at is null and is_current;

create trigger drawing_revisions_set_updated_at
  before update on public.drawing_revisions
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- PDF pages (separate records; 0-based page_index)
-- ---------------------------------------------------------------------------

create table public.drawing_pages (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.drawing_revisions (id) on delete cascade,
  page_index integer not null check (page_index >= 0),
  width_pts double precision,
  height_pts double precision,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index drawing_pages_revision_index_active_uidx
  on public.drawing_pages (revision_id, page_index)
  where deleted_at is null;

create trigger drawing_pages_set_updated_at
  before update on public.drawing_pages
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Page calibrations (PDF page coordinates preserved as doubles)
-- ---------------------------------------------------------------------------

create table public.page_calibrations (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references public.drawing_pages (id) on delete cascade,
  point_a_x double precision not null,
  point_a_y double precision not null,
  point_b_x double precision not null,
  point_b_y double precision not null,
  real_distance_mm double precision not null check (real_distance_mm > 0),
  entered_unit public.length_unit not null,
  entered_value double precision not null check (entered_value > 0),
  mm_per_pdf_unit double precision not null check (mm_per_pdf_unit >= 0),
  calibrated_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

-- One active calibration per page (matches current Swift model).
create unique index page_calibrations_page_active_uidx
  on public.page_calibrations (page_id)
  where deleted_at is null;

create trigger page_calibrations_set_updated_at
  before update on public.page_calibrations
  for each row execute function public.set_updated_at();
