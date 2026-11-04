-- B Technica — project photo documentation (additive). Prepared for review; not deployed.
--
-- Photos belong to one project and are independent of issues; optional links to a
-- drawing (page), area, issue and album must stay inside the same project.
-- Object path convention (first folder = project UUID):
--   project-photos/{project_id}/{photo_id}.jpg
--   project-photos/{project_id}/thumbnails/{photo_id}.jpg

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'project-photos',
  'project-photos',
  false,
  20971520, -- 20 MiB
  array['image/jpeg', 'image/jpg', 'image/png', 'image/heic', 'image/heif']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Albums
-- ---------------------------------------------------------------------------

create table public.photo_albums (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create unique index photo_albums_project_name_active_uidx
  on public.photo_albums (project_id, lower(name))
  where deleted_at is null;

create trigger photo_albums_set_updated_at
  before update on public.photo_albums
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Photos
-- ---------------------------------------------------------------------------

create table public.project_photos (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  album_id uuid references public.photo_albums (id) on delete set null,
  storage_path text not null check (char_length(trim(storage_path)) > 0),
  thumbnail_path text,
  title text,
  description text not null default '',
  taken_at timestamptz not null,
  drawing_id uuid references public.drawings (id) on delete set null,
  page_index integer check (page_index is null or page_index >= 0),
  area_id uuid references public.areas (id) on delete set null,
  issue_id uuid references public.issues (id) on delete set null,
  pixel_width integer,
  pixel_height integer,
  byte_size bigint,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz
);

create index project_photos_project_taken_idx
  on public.project_photos (project_id, taken_at desc)
  where deleted_at is null;

create index project_photos_album_id_idx
  on public.project_photos (album_id)
  where deleted_at is null;

create index project_photos_issue_id_idx
  on public.project_photos (issue_id)
  where deleted_at is null;

create index project_photos_drawing_id_idx
  on public.project_photos (drawing_id)
  where deleted_at is null;

create trigger project_photos_set_updated_at
  before update on public.project_photos
  for each row execute function public.set_updated_at();

create or replace function public.project_photos_same_project()
returns trigger
language plpgsql
as $$
declare
  v_project uuid;
  v_area_drawing uuid;
begin
  if new.album_id is not null then
    select project_id into v_project from public.photo_albums where id = new.album_id;
    perform public.assert_same_project(new.project_id, v_project, 'project_photos.album_id');
  end if;
  if new.drawing_id is not null then
    select project_id into v_project from public.drawings where id = new.drawing_id;
    perform public.assert_same_project(new.project_id, v_project, 'project_photos.drawing_id');
  end if;
  if new.area_id is not null then
    select project_id, drawing_id into v_project, v_area_drawing from public.areas where id = new.area_id;
    perform public.assert_same_project(new.project_id, v_project, 'project_photos.area_id');
    if new.drawing_id is not null and v_area_drawing is distinct from new.drawing_id then
      raise exception 'project_photos.area_id: area belongs to another drawing'
        using errcode = '23514';
    end if;
  end if;
  if new.issue_id is not null then
    select project_id into v_project from public.issues where id = new.issue_id;
    perform public.assert_same_project(new.project_id, v_project, 'project_photos.issue_id');
  end if;
  return new;
end;
$$;

create trigger project_photos_same_project_trg
  before insert or update of project_id, album_id, drawing_id, area_id, issue_id
  on public.project_photos
  for each row execute function public.project_photos_same_project();

-- ---------------------------------------------------------------------------
-- RLS: members read; owners / editors write.
-- ---------------------------------------------------------------------------

alter table public.photo_albums enable row level security;
alter table public.project_photos enable row level security;

create policy photo_albums_select
  on public.photo_albums for select to authenticated
  using (public.is_project_member(project_id));

create policy photo_albums_insert
  on public.photo_albums for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy photo_albums_update
  on public.photo_albums for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy photo_albums_delete
  on public.photo_albums for delete to authenticated
  using (public.can_edit_project(project_id));

create policy project_photos_select
  on public.project_photos for select to authenticated
  using (public.is_project_member(project_id));

create policy project_photos_insert
  on public.project_photos for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy project_photos_update
  on public.project_photos for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy project_photos_delete
  on public.project_photos for delete to authenticated
  using (public.can_edit_project(project_id));

grant select, insert, update, delete on public.photo_albums, public.project_photos to authenticated;

-- ---------------------------------------------------------------------------
-- project-photos bucket
-- ---------------------------------------------------------------------------

create policy storage_project_photos_select
  on storage.objects for select to authenticated
  using (
    bucket_id = 'project-photos'
    and public.is_project_member(public.storage_project_id(name))
  );

create policy storage_project_photos_insert
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'project-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_project_photos_update
  on storage.objects for update to authenticated
  using (
    bucket_id = 'project-photos'
    and public.can_edit_project(public.storage_project_id(name))
  )
  with check (
    bucket_id = 'project-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_project_photos_delete
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'project-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );
