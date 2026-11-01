-- Allow project members to read soft-deleted drawings (tombstones).
-- Soft-delete UPDATE can fail with 42501 because PostgREST RETURNING
-- requires the new row to pass SELECT RLS, and drawings_select
-- requires deleted_at IS NULL.
-- Project isolation is preserved via is_project_member(project_id).
-- Normal drawing listings must still filter deleted_at IS NULL.

create policy drawings_select_tombstones
  on public.drawings for select to authenticated
  using (deleted_at is not null and public.is_project_member(project_id));
