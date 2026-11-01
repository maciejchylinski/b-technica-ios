-- Allow project members to read soft-deleted drawing_folders (tombstones).
-- Soft-delete UPDATE currently fails with 42501 because PostgREST RETURNING
-- requires the new row to pass SELECT RLS, and drawing_folders_select
-- requires deleted_at IS NULL.
-- Project isolation is preserved via is_project_member(project_id).
-- Normal folder listings must still filter deleted_at IS NULL.

create policy drawing_folders_select_tombstones
  on public.drawing_folders for select to authenticated
  using (deleted_at is not null and public.is_project_member(project_id));
