-- B Technica v2 — prevent cross-project relationships at the database layer.

create or replace function public.assert_same_project(
  p_left uuid,
  p_right uuid,
  p_context text
)
returns void
language plpgsql
immutable
as $$
begin
  if p_left is distinct from p_right then
    raise exception '%: cross-project reference denied', p_context
      using errcode = '23514';
  end if;
end;
$$;

-- Folders: parent must belong to same project
create or replace function public.drawing_folders_same_project()
returns trigger
language plpgsql
as $$
declare
  v_parent_project uuid;
begin
  if new.parent_folder_id is null then
    return new;
  end if;

  select project_id into v_parent_project
  from public.drawing_folders
  where id = new.parent_folder_id
    and deleted_at is null;

  if v_parent_project is null then
    raise exception 'drawing_folders: parent folder not found'
      using errcode = '23503';
  end if;

  perform public.assert_same_project(
    new.project_id,
    v_parent_project,
    'drawing_folders.parent_folder_id'
  );
  return new;
end;
$$;

create trigger drawing_folders_same_project_trg
  before insert or update of project_id, parent_folder_id
  on public.drawing_folders
  for each row execute function public.drawing_folders_same_project();

-- Drawings: folder must belong to same project
create or replace function public.drawings_same_project()
returns trigger
language plpgsql
as $$
declare
  v_folder_project uuid;
begin
  if new.folder_id is null then
    return new;
  end if;

  select project_id into v_folder_project
  from public.drawing_folders
  where id = new.folder_id
    and deleted_at is null;

  if v_folder_project is null then
    raise exception 'drawings: folder not found'
      using errcode = '23503';
  end if;

  perform public.assert_same_project(
    new.project_id,
    v_folder_project,
    'drawings.folder_id'
  );
  return new;
end;
$$;

create trigger drawings_same_project_trg
  before insert or update of project_id, folder_id
  on public.drawings
  for each row execute function public.drawings_same_project();

-- Areas: drawing + page must belong to same project (via drawing / revision)
create or replace function public.areas_same_project()
returns trigger
language plpgsql
as $$
declare
  v_drawing_project uuid;
  v_page_drawing uuid;
begin
  select project_id into v_drawing_project
  from public.drawings
  where id = new.drawing_id
    and deleted_at is null;

  if v_drawing_project is null then
    raise exception 'areas: drawing not found'
      using errcode = '23503';
  end if;

  perform public.assert_same_project(
    new.project_id,
    v_drawing_project,
    'areas.drawing_id'
  );

  select dr.drawing_id into v_page_drawing
  from public.drawing_pages dp
  join public.drawing_revisions dr on dr.id = dp.revision_id
  where dp.id = new.page_id
    and dp.deleted_at is null
    and dr.deleted_at is null;

  if v_page_drawing is null then
    raise exception 'areas: page not found'
      using errcode = '23503';
  end if;

  if v_page_drawing is distinct from new.drawing_id then
    raise exception 'areas.page_id: page does not belong to drawing'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger areas_same_project_trg
  before insert or update of project_id, drawing_id, page_id
  on public.areas
  for each row execute function public.areas_same_project();

-- Issues: drawing / page / area / issue_type must match project
create or replace function public.issues_same_project()
returns trigger
language plpgsql
as $$
declare
  v_project uuid;
  v_page_drawing uuid;
begin
  if new.issue_type_id is not null then
    select project_id into v_project
    from public.issue_types
    where id = new.issue_type_id
      and deleted_at is null;
    if v_project is null then
      raise exception 'issues: issue_type not found' using errcode = '23503';
    end if;
    perform public.assert_same_project(new.project_id, v_project, 'issues.issue_type_id');
  end if;

  if new.drawing_id is not null then
    select project_id into v_project
    from public.drawings
    where id = new.drawing_id
      and deleted_at is null;
    if v_project is null then
      raise exception 'issues: drawing not found' using errcode = '23503';
    end if;
    perform public.assert_same_project(new.project_id, v_project, 'issues.drawing_id');
  end if;

  if new.page_id is not null then
    select dr.drawing_id into v_page_drawing
    from public.drawing_pages dp
    join public.drawing_revisions dr on dr.id = dp.revision_id
    where dp.id = new.page_id
      and dp.deleted_at is null
      and dr.deleted_at is null;
    if v_page_drawing is null then
      raise exception 'issues: page not found' using errcode = '23503';
    end if;
    if new.drawing_id is distinct from v_page_drawing then
      raise exception 'issues.page_id: page does not belong to drawing'
        using errcode = '23514';
    end if;
  end if;

  if new.area_id is not null then
    select project_id into v_project
    from public.areas
    where id = new.area_id
      and deleted_at is null;
    if v_project is null then
      raise exception 'issues: area not found' using errcode = '23503';
    end if;
    perform public.assert_same_project(new.project_id, v_project, 'issues.area_id');
  end if;

  return new;
end;
$$;

create trigger issues_same_project_trg
  before insert or update of project_id, issue_type_id, drawing_id, page_id, area_id
  on public.issues
  for each row execute function public.issues_same_project();

-- Equipment assignment: equipment owner must be project member (or project owner)
create or replace function public.equipment_assignment_owner_member()
returns trigger
language plpgsql
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner
  from public.equipment_items
  where id = new.equipment_id
    and deleted_at is null;

  if v_owner is null then
    raise exception 'equipment_project_assignments: equipment not found'
      using errcode = '23503';
  end if;

  if not exists (
    select 1
    from public.project_members pm
    where pm.project_id = new.project_id
      and pm.user_id = v_owner
      and pm.deleted_at is null
  ) then
    raise exception 'equipment_project_assignments: equipment owner is not a project member'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger equipment_assignment_owner_member_trg
  before insert or update of equipment_id, project_id
  on public.equipment_project_assignments
  for each row execute function public.equipment_assignment_owner_member();

-- Profiles: active project must be one the user belongs to
create or replace function public.profiles_active_project_member()
returns trigger
language plpgsql
as $$
begin
  if new.active_project_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.project_members pm
    where pm.project_id = new.active_project_id
      and pm.user_id = new.id
      and pm.deleted_at is null
  ) then
    raise exception 'profiles.active_project_id: user is not a member of that project'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger profiles_active_project_member_trg
  before insert or update of active_project_id
  on public.profiles
  for each row execute function public.profiles_active_project_member();
