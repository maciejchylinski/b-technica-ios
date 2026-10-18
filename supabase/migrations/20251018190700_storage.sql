-- B Technica v2 — private Storage buckets and path-based access.
-- Object path convention (first folder = project UUID):
--   drawings/{project_id}/{revision_id}.pdf
--   issue-photos/{project_id}/{issue_id}/{photo_id}.jpg

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'drawings',
    'drawings',
    false,
    104857600, -- 100 MiB
    array['application/pdf']
  ),
  (
    'issue-photos',
    'issue-photos',
    false,
    20971520, -- 20 MiB
    array['image/jpeg', 'image/jpg', 'image/png', 'image/heic', 'image/heif']
  )
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Helper: first path segment as project UUID (null if invalid)
create or replace function public.storage_project_id(object_name text)
returns uuid
language plpgsql
immutable
as $$
declare
  v_segment text;
  v_id uuid;
begin
  v_segment := split_part(object_name, '/', 1);
  begin
    v_id := v_segment::uuid;
  exception
    when invalid_text_representation then
      return null;
  end;
  return v_id;
end;
$$;

revoke all on function public.storage_project_id(text) from public;
grant execute on function public.storage_project_id(text) to authenticated;

-- ---------------------------------------------------------------------------
-- drawings bucket
-- ---------------------------------------------------------------------------

create policy storage_drawings_select
  on storage.objects for select to authenticated
  using (
    bucket_id = 'drawings'
    and public.is_project_member(public.storage_project_id(name))
  );

create policy storage_drawings_insert
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'drawings'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_drawings_update
  on storage.objects for update to authenticated
  using (
    bucket_id = 'drawings'
    and public.can_edit_project(public.storage_project_id(name))
  )
  with check (
    bucket_id = 'drawings'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_drawings_delete
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'drawings'
    and public.can_edit_project(public.storage_project_id(name))
  );

-- ---------------------------------------------------------------------------
-- issue-photos bucket
-- ---------------------------------------------------------------------------

create policy storage_issue_photos_select
  on storage.objects for select to authenticated
  using (
    bucket_id = 'issue-photos'
    and public.is_project_member(public.storage_project_id(name))
  );

create policy storage_issue_photos_insert
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'issue-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_issue_photos_update
  on storage.objects for update to authenticated
  using (
    bucket_id = 'issue-photos'
    and public.can_edit_project(public.storage_project_id(name))
  )
  with check (
    bucket_id = 'issue-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );

create policy storage_issue_photos_delete
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'issue-photos'
    and public.can_edit_project(public.storage_project_id(name))
  );
