-- B Technica v2 — Row Level Security on all client-accessible tables.
-- Unauthenticated (anon) has no policies → no access.
-- Authorization is membership / ownership based; never UI-only.

-- ---------------------------------------------------------------------------
-- Enable RLS
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.contractors enable row level security;
alter table public.disciplines enable row level security;
alter table public.issue_types enable row level security;
alter table public.equipment_items enable row level security;
alter table public.equipment_events enable row level security;
alter table public.equipment_project_assignments enable row level security;
alter table public.drawing_folders enable row level security;
alter table public.drawings enable row level security;
alter table public.drawing_revisions enable row level security;
alter table public.drawing_pages enable row level security;
alter table public.page_calibrations enable row level security;
alter table public.areas enable row level security;
alter table public.issues enable row level security;
alter table public.issue_photos enable row level security;
alter table public.project_issue_counters enable row level security;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

create policy profiles_select_own
  on public.profiles for select to authenticated
  using (id = auth.uid() and deleted_at is null);

create policy profiles_update_own
  on public.profiles for update to authenticated
  using (id = auth.uid() and deleted_at is null)
  with check (id = auth.uid());

-- Inserts come from auth trigger (security definer); no client insert.

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

create policy projects_select_member
  on public.projects for select to authenticated
  using (deleted_at is null and public.is_project_member(id));

create policy projects_insert_own
  on public.projects for insert to authenticated
  with check (owner_id = auth.uid());

create policy projects_update_owner
  on public.projects for update to authenticated
  using (deleted_at is null and public.has_project_role(id, array['owner']))
  with check (public.has_project_role(id, array['owner']));

-- Soft-delete via update preferred; hard delete restricted to owner
create policy projects_delete_owner
  on public.projects for delete to authenticated
  using (public.has_project_role(id, array['owner']));

-- ---------------------------------------------------------------------------
-- Project members
-- ---------------------------------------------------------------------------

create policy project_members_select_same_project
  on public.project_members for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy project_members_insert_owner
  on public.project_members for insert to authenticated
  with check (public.has_project_role(project_id, array['owner']));

create policy project_members_update_owner
  on public.project_members for update to authenticated
  using (deleted_at is null and public.has_project_role(project_id, array['owner']))
  with check (public.has_project_role(project_id, array['owner']));

create policy project_members_delete_owner
  on public.project_members for delete to authenticated
  using (public.has_project_role(project_id, array['owner']));

-- ---------------------------------------------------------------------------
-- User-owned dictionaries / equipment
-- ---------------------------------------------------------------------------

create policy contractors_select_own
  on public.contractors for select to authenticated
  using (owner_id = auth.uid() and deleted_at is null);

create policy contractors_insert_own
  on public.contractors for insert to authenticated
  with check (owner_id = auth.uid());

create policy contractors_update_own
  on public.contractors for update to authenticated
  using (owner_id = auth.uid() and deleted_at is null)
  with check (owner_id = auth.uid());

create policy contractors_delete_own
  on public.contractors for delete to authenticated
  using (owner_id = auth.uid());

create policy disciplines_select_own
  on public.disciplines for select to authenticated
  using (owner_id = auth.uid() and deleted_at is null);

create policy disciplines_insert_own
  on public.disciplines for insert to authenticated
  with check (owner_id = auth.uid());

create policy disciplines_update_own
  on public.disciplines for update to authenticated
  using (owner_id = auth.uid() and deleted_at is null)
  with check (owner_id = auth.uid());

create policy disciplines_delete_own
  on public.disciplines for delete to authenticated
  using (owner_id = auth.uid());

create policy equipment_items_select_own
  on public.equipment_items for select to authenticated
  using (owner_id = auth.uid() and deleted_at is null);

create policy equipment_items_insert_own
  on public.equipment_items for insert to authenticated
  with check (owner_id = auth.uid());

create policy equipment_items_update_own
  on public.equipment_items for update to authenticated
  using (owner_id = auth.uid() and deleted_at is null)
  with check (owner_id = auth.uid());

create policy equipment_items_delete_own
  on public.equipment_items for delete to authenticated
  using (owner_id = auth.uid());

create policy equipment_events_select_own
  on public.equipment_events for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

create policy equipment_events_insert_own
  on public.equipment_events for insert to authenticated
  with check (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

create policy equipment_events_update_own
  on public.equipment_events for update to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  )
  with check (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

create policy equipment_events_delete_own
  on public.equipment_events for delete to authenticated
  using (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

-- Assignments: visible to project members OR equipment owner
create policy equipment_assignments_select
  on public.equipment_project_assignments for select to authenticated
  using (
    deleted_at is null
    and (
      public.is_project_member(project_id)
      or exists (
        select 1 from public.equipment_items ei
        where ei.id = equipment_id
          and ei.owner_id = auth.uid()
          and ei.deleted_at is null
      )
    )
  );

create policy equipment_assignments_insert
  on public.equipment_project_assignments for insert to authenticated
  with check (
    public.can_edit_project(project_id)
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

create policy equipment_assignments_update
  on public.equipment_project_assignments for update to authenticated
  using (
    deleted_at is null
    and public.can_edit_project(project_id)
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  )
  with check (
    public.can_edit_project(project_id)
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

create policy equipment_assignments_delete
  on public.equipment_project_assignments for delete to authenticated
  using (
    public.can_edit_project(project_id)
    and exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id
        and ei.owner_id = auth.uid()
        and ei.deleted_at is null
    )
  );

-- ---------------------------------------------------------------------------
-- Project-scoped content (generic pattern)
-- ---------------------------------------------------------------------------

-- issue_types
create policy issue_types_select
  on public.issue_types for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy issue_types_insert
  on public.issue_types for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy issue_types_update
  on public.issue_types for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy issue_types_delete
  on public.issue_types for delete to authenticated
  using (public.can_edit_project(project_id));

-- drawing_folders
create policy drawing_folders_select
  on public.drawing_folders for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy drawing_folders_insert
  on public.drawing_folders for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy drawing_folders_update
  on public.drawing_folders for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy drawing_folders_delete
  on public.drawing_folders for delete to authenticated
  using (public.can_edit_project(project_id));

-- drawings
create policy drawings_select
  on public.drawings for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy drawings_insert
  on public.drawings for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy drawings_update
  on public.drawings for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy drawings_delete
  on public.drawings for delete to authenticated
  using (public.can_edit_project(project_id));

-- drawing_revisions (via drawing.project_id)
create policy drawing_revisions_select
  on public.drawing_revisions for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.drawings d
      where d.id = drawing_id
        and d.deleted_at is null
        and public.is_project_member(d.project_id)
    )
  );

create policy drawing_revisions_insert
  on public.drawing_revisions for insert to authenticated
  with check (
    exists (
      select 1 from public.drawings d
      where d.id = drawing_id
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy drawing_revisions_update
  on public.drawing_revisions for update to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.drawings d
      where d.id = drawing_id
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  )
  with check (
    exists (
      select 1 from public.drawings d
      where d.id = drawing_id
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy drawing_revisions_delete
  on public.drawing_revisions for delete to authenticated
  using (
    exists (
      select 1 from public.drawings d
      where d.id = drawing_id
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

-- drawing_pages
create policy drawing_pages_select
  on public.drawing_pages for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1
      from public.drawing_revisions r
      join public.drawings d on d.id = r.drawing_id
      where r.id = revision_id
        and r.deleted_at is null
        and d.deleted_at is null
        and public.is_project_member(d.project_id)
    )
  );

create policy drawing_pages_insert
  on public.drawing_pages for insert to authenticated
  with check (
    exists (
      select 1
      from public.drawing_revisions r
      join public.drawings d on d.id = r.drawing_id
      where r.id = revision_id
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy drawing_pages_update
  on public.drawing_pages for update to authenticated
  using (
    deleted_at is null
    and exists (
      select 1
      from public.drawing_revisions r
      join public.drawings d on d.id = r.drawing_id
      where r.id = revision_id
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  )
  with check (
    exists (
      select 1
      from public.drawing_revisions r
      join public.drawings d on d.id = r.drawing_id
      where r.id = revision_id
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy drawing_pages_delete
  on public.drawing_pages for delete to authenticated
  using (
    exists (
      select 1
      from public.drawing_revisions r
      join public.drawings d on d.id = r.drawing_id
      where r.id = revision_id
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

-- page_calibrations
create policy page_calibrations_select
  on public.page_calibrations for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1
      from public.drawing_pages dp
      join public.drawing_revisions r on r.id = dp.revision_id
      join public.drawings d on d.id = r.drawing_id
      where dp.id = page_id
        and dp.deleted_at is null
        and r.deleted_at is null
        and d.deleted_at is null
        and public.is_project_member(d.project_id)
    )
  );

create policy page_calibrations_insert
  on public.page_calibrations for insert to authenticated
  with check (
    exists (
      select 1
      from public.drawing_pages dp
      join public.drawing_revisions r on r.id = dp.revision_id
      join public.drawings d on d.id = r.drawing_id
      where dp.id = page_id
        and dp.deleted_at is null
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy page_calibrations_update
  on public.page_calibrations for update to authenticated
  using (
    deleted_at is null
    and exists (
      select 1
      from public.drawing_pages dp
      join public.drawing_revisions r on r.id = dp.revision_id
      join public.drawings d on d.id = r.drawing_id
      where dp.id = page_id
        and dp.deleted_at is null
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  )
  with check (
    exists (
      select 1
      from public.drawing_pages dp
      join public.drawing_revisions r on r.id = dp.revision_id
      join public.drawings d on d.id = r.drawing_id
      where dp.id = page_id
        and dp.deleted_at is null
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

create policy page_calibrations_delete
  on public.page_calibrations for delete to authenticated
  using (
    exists (
      select 1
      from public.drawing_pages dp
      join public.drawing_revisions r on r.id = dp.revision_id
      join public.drawings d on d.id = r.drawing_id
      where dp.id = page_id
        and dp.deleted_at is null
        and r.deleted_at is null
        and d.deleted_at is null
        and public.can_edit_project(d.project_id)
    )
  );

-- areas
create policy areas_select
  on public.areas for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy areas_insert
  on public.areas for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy areas_update
  on public.areas for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy areas_delete
  on public.areas for delete to authenticated
  using (public.can_edit_project(project_id));

-- issues
create policy issues_select
  on public.issues for select to authenticated
  using (deleted_at is null and public.is_project_member(project_id));

create policy issues_insert
  on public.issues for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy issues_update
  on public.issues for update to authenticated
  using (deleted_at is null and public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy issues_delete
  on public.issues for delete to authenticated
  using (public.can_edit_project(project_id));

-- issue_photos
create policy issue_photos_select
  on public.issue_photos for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.issues i
      where i.id = issue_id
        and i.deleted_at is null
        and public.is_project_member(i.project_id)
    )
  );

create policy issue_photos_insert
  on public.issue_photos for insert to authenticated
  with check (
    exists (
      select 1 from public.issues i
      where i.id = issue_id
        and i.deleted_at is null
        and public.can_edit_project(i.project_id)
    )
  );

create policy issue_photos_update
  on public.issue_photos for update to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.issues i
      where i.id = issue_id
        and i.deleted_at is null
        and public.can_edit_project(i.project_id)
    )
  )
  with check (
    exists (
      select 1 from public.issues i
      where i.id = issue_id
        and i.deleted_at is null
        and public.can_edit_project(i.project_id)
    )
  );

create policy issue_photos_delete
  on public.issue_photos for delete to authenticated
  using (
    exists (
      select 1 from public.issues i
      where i.id = issue_id
        and i.deleted_at is null
        and public.can_edit_project(i.project_id)
    )
  );

-- Counters: members can read; only editors allocate via security definer fn
create policy project_issue_counters_select
  on public.project_issue_counters for select to authenticated
  using (public.is_project_member(project_id));

-- No direct client insert/update/delete on counters (function is security definer).
