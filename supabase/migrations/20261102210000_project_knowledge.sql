-- B Technica — Project Knowledge v1: document library, per-page extracted text, field notes.
-- Additive only. Prepared for future sync; the iOS app does not sync this module yet.
-- Object path convention for a future bucket (first folder = project UUID):
--   project-documents/{project_id}/{document_id}.pdf

-- ---------------------------------------------------------------------------
-- Folders (unlimited nesting, user-defined names)
-- ---------------------------------------------------------------------------

create table public.project_document_folders (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  parent_folder_id uuid references public.project_document_folders (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  constraint project_document_folders_parent_not_self check (parent_folder_id is distinct from id)
);

create index project_document_folders_project_id_idx
  on public.project_document_folders (project_id)
  where deleted_at is null;

create index project_document_folders_parent_id_idx
  on public.project_document_folders (parent_folder_id)
  where deleted_at is null;

create unique index project_document_folders_sibling_name_active_uidx
  on public.project_document_folders (
    project_id,
    coalesce(parent_folder_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(name)
  )
  where deleted_at is null;

create trigger project_document_folders_set_updated_at
  before update on public.project_document_folders
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Documents (stable id = citation anchor; revision + checksum metadata)
-- ---------------------------------------------------------------------------

create table public.project_documents (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  folder_id uuid references public.project_document_folders (id) on delete set null,
  name text not null check (char_length(trim(name)) > 0),
  category text not null default 'other' check (category in (
    'technical_specification',
    'construction_documentation',
    'material_specification',
    'installation_manual',
    'technical_approval',
    'construction_instruction',
    'other'
  )),
  description text not null default '',
  original_file_name text not null,
  storage_path text,
  file_size_bytes bigint not null default 0 check (file_size_bytes >= 0),
  page_count integer not null default 0 check (page_count >= 0),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  revision text,
  revision_date date,
  uploaded_by uuid references auth.users (id) on delete set null default auth.uid(),
  uploaded_at timestamptz not null default timezone('utc', now()),
  indexed_at timestamptz,
  indexed_checksum text,
  extractor_version integer,
  extraction_method text check (extraction_method is null or extraction_method in ('pdf_text', 'ocr', 'mixed', 'none')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index project_documents_project_id_idx
  on public.project_documents (project_id)
  where deleted_at is null;

create index project_documents_folder_id_idx
  on public.project_documents (folder_id)
  where deleted_at is null;

create index project_documents_checksum_idx
  on public.project_documents (project_id, checksum_sha256)
  where deleted_at is null;

create trigger project_documents_set_updated_at
  before update on public.project_documents
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Per-page extracted text (0-based page_index) — source for cited answers
-- ---------------------------------------------------------------------------

create table public.project_document_pages (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.project_documents (id) on delete cascade,
  project_id uuid not null references public.projects (id) on delete cascade,
  page_index integer not null check (page_index >= 0),
  page_label text,
  text text not null default '',
  extraction_method text not null check (extraction_method in ('pdf_text', 'ocr', 'none')),
  ocr_confidence real check (ocr_confidence is null or (ocr_confidence >= 0 and ocr_confidence <= 1)),
  extracted_at timestamptz not null default timezone('utc', now()),
  search_vector tsvector generated always as (to_tsvector('simple', coalesce(text, ''))) stored,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index project_document_pages_document_page_uidx
  on public.project_document_pages (document_id, page_index);

create index project_document_pages_project_id_idx
  on public.project_document_pages (project_id);

create index project_document_pages_search_idx
  on public.project_document_pages using gin (search_vector);

create trigger project_document_pages_set_updated_at
  before update on public.project_document_pages
  for each row execute function public.set_updated_at();

-- Page rows must belong to the same project as their document.
create or replace function public.project_document_pages_check_project()
returns trigger
language plpgsql
as $$
begin
  if not exists (
    select 1 from public.project_documents d
    where d.id = new.document_id and d.project_id = new.project_id
  ) then
    raise exception 'project_document_pages.project_id must match the document project'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger project_document_pages_check_project
  before insert or update of document_id, project_id on public.project_document_pages
  for each row execute function public.project_document_pages_check_project();

-- ---------------------------------------------------------------------------
-- Field notes
-- ---------------------------------------------------------------------------

create table public.project_notes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  title text not null default '',
  body text not null default '',
  category text check (category is null or category in (
    'inspection', 'meeting', 'measurement', 'defect', 'instruction', 'other'
  )),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  search_vector tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(body, '')), 'B')
  ) stored,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  constraint project_notes_not_empty check (char_length(trim(title)) > 0 or char_length(trim(body)) > 0)
);

create index project_notes_project_id_idx
  on public.project_notes (project_id, updated_at desc)
  where deleted_at is null;

create index project_notes_search_idx
  on public.project_notes using gin (search_vector);

create trigger project_notes_set_updated_at
  before update on public.project_notes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security (project membership; same helpers as drawings)
-- SELECT does not filter deleted_at, so soft-delete UPDATE ... RETURNING passes
-- (see 20261101194500_drawings_soft_delete_rls.sql). Clients filter deleted_at is null.
-- ---------------------------------------------------------------------------

alter table public.project_document_folders enable row level security;
alter table public.project_documents enable row level security;
alter table public.project_document_pages enable row level security;
alter table public.project_notes enable row level security;

create policy project_document_folders_select
  on public.project_document_folders for select to authenticated
  using (public.is_project_member(project_id));

create policy project_document_folders_insert
  on public.project_document_folders for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy project_document_folders_update
  on public.project_document_folders for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy project_document_folders_delete
  on public.project_document_folders for delete to authenticated
  using (public.can_edit_project(project_id));

create policy project_documents_select
  on public.project_documents for select to authenticated
  using (public.is_project_member(project_id));

create policy project_documents_insert
  on public.project_documents for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy project_documents_update
  on public.project_documents for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy project_documents_delete
  on public.project_documents for delete to authenticated
  using (public.can_edit_project(project_id));

create policy project_document_pages_select
  on public.project_document_pages for select to authenticated
  using (public.is_project_member(project_id));

create policy project_document_pages_insert
  on public.project_document_pages for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy project_document_pages_update
  on public.project_document_pages for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy project_document_pages_delete
  on public.project_document_pages for delete to authenticated
  using (public.can_edit_project(project_id));

create policy project_notes_select
  on public.project_notes for select to authenticated
  using (public.is_project_member(project_id));

create policy project_notes_insert
  on public.project_notes for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy project_notes_update
  on public.project_notes for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy project_notes_delete
  on public.project_notes for delete to authenticated
  using (public.can_edit_project(project_id));

grant select, insert, update, delete
  on public.project_document_folders,
     public.project_documents,
     public.project_document_pages,
     public.project_notes
  to authenticated;

revoke all
  on public.project_document_folders,
     public.project_documents,
     public.project_document_pages,
     public.project_notes
  from anon;
