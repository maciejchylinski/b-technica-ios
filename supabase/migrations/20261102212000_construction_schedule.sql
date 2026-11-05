-- B Technica — construction schedule (additive). NOT deployed.
--
-- One schedule per project; user-named phases; tasks / milestones with calendar
-- dates (Postgres `date`, no time zone); finish-to-start dependencies.
--
-- Mirrors the local SQLite schema (migration "v4_construction_schedule"):
-- same table names, column names and client-generated UUIDs, so a future sync
-- can push rows 1:1. Composite foreign keys carry project_id / schedule_id down
-- the tree, making cross-project and cross-schedule references impossible.
-- Rows are soft-deleted via deleted_at; clients soft-delete children together
-- with their parent (hard deletes cascade).

-- ---------------------------------------------------------------------------
-- Schedules
-- ---------------------------------------------------------------------------

create table public.schedules (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  details text not null default '',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  -- Target for composite FKs from children
  unique (id, project_id)
);

-- One live schedule per project
create unique index schedules_one_per_project_idx
  on public.schedules (project_id)
  where deleted_at is null;

create trigger schedules_set_updated_at
  before update on public.schedules
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Phases (free-text names, ordered)
-- ---------------------------------------------------------------------------

create table public.schedule_phases (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  schedule_id uuid not null,
  name text not null check (char_length(trim(name)) > 0),
  color text not null default '#1C7AE6'
    check (color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  foreign key (schedule_id, project_id)
    references public.schedules (id, project_id) on delete cascade,
  unique (id, schedule_id)
);

create index schedule_phases_schedule_id_idx
  on public.schedule_phases (schedule_id, sort_order)
  where deleted_at is null;

create index schedule_phases_project_id_idx
  on public.schedule_phases (project_id)
  where deleted_at is null;

create trigger schedule_phases_set_updated_at
  before update on public.schedule_phases
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Tasks and milestones
-- ---------------------------------------------------------------------------

create table public.schedule_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  schedule_id uuid not null,
  -- NULL = task without a phase (composite FK is skipped when phase_id is NULL)
  phase_id uuid,
  kind text not null default 'task'
    check (kind in ('task', 'milestone')),
  title text not null check (char_length(trim(title)) > 0),
  details text not null default '',
  start_date date not null,
  -- Inclusive last day
  finish_date date not null,
  progress smallint not null default 0
    check (progress between 0 and 100),
  status text not null default 'planned'
    check (status in ('planned', 'inProgress', 'completed', 'delayed')),
  -- Free-text responsibility (person or contractor)
  responsible_name text,
  -- Future link to project contacts; intentionally no FK until that module ships.
  responsible_contact_id uuid,
  notes text not null default '',
  sort_order integer not null default 0,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  foreign key (schedule_id, project_id)
    references public.schedules (id, project_id) on delete cascade,
  foreign key (phase_id, schedule_id)
    references public.schedule_phases (id, schedule_id) on delete cascade,
  unique (id, schedule_id),
  constraint schedule_tasks_date_order check (finish_date >= start_date),
  constraint schedule_tasks_milestone_single_day check (kind <> 'milestone' or finish_date = start_date),
  constraint schedule_tasks_completed_full check (status <> 'completed' or progress = 100)
);

create index schedule_tasks_schedule_id_idx
  on public.schedule_tasks (schedule_id, start_date)
  where deleted_at is null;

create index schedule_tasks_phase_id_idx
  on public.schedule_tasks (phase_id, sort_order)
  where deleted_at is null;

create index schedule_tasks_project_id_idx
  on public.schedule_tasks (project_id)
  where deleted_at is null;

-- Incremental sync cursor
create index schedule_tasks_project_updated_at_idx
  on public.schedule_tasks (project_id, updated_at);

create trigger schedule_tasks_set_updated_at
  before update on public.schedule_tasks
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Dependencies (finish-to-start)
-- ---------------------------------------------------------------------------

create table public.schedule_task_dependencies (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  schedule_id uuid not null,
  predecessor_task_id uuid not null,
  successor_task_id uuid not null,
  dependency_type text not null default 'finish_to_start'
    check (dependency_type in ('finish_to_start')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  foreign key (schedule_id, project_id)
    references public.schedules (id, project_id) on delete cascade,
  foreign key (predecessor_task_id, schedule_id)
    references public.schedule_tasks (id, schedule_id) on delete cascade,
  foreign key (successor_task_id, schedule_id)
    references public.schedule_tasks (id, schedule_id) on delete cascade,
  constraint schedule_task_dependencies_not_self check (predecessor_task_id <> successor_task_id)
);

create unique index schedule_task_dependencies_pair_idx
  on public.schedule_task_dependencies (predecessor_task_id, successor_task_id)
  where deleted_at is null;

create index schedule_task_dependencies_schedule_id_idx
  on public.schedule_task_dependencies (schedule_id)
  where deleted_at is null;

create index schedule_task_dependencies_successor_idx
  on public.schedule_task_dependencies (successor_task_id)
  where deleted_at is null;

create trigger schedule_task_dependencies_set_updated_at
  before update on public.schedule_task_dependencies
  for each row execute function public.set_updated_at();

-- Reject live edges that would close a loop. Serialized per schedule so two
-- concurrent inserts cannot each pass the check and together form a cycle.
create or replace function public.schedule_task_dependencies_no_cycle()
returns trigger
language plpgsql
as $$
declare
  v_cycle boolean;
begin
  if new.deleted_at is not null then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.schedule_id::text, 0));

  with recursive downstream(task_id) as (
    select d.successor_task_id
    from public.schedule_task_dependencies d
    where d.predecessor_task_id = new.successor_task_id
      and d.schedule_id = new.schedule_id
      and d.deleted_at is null
      and d.id <> new.id
    union
    select d.successor_task_id
    from public.schedule_task_dependencies d
    join downstream on d.predecessor_task_id = downstream.task_id
    where d.schedule_id = new.schedule_id
      and d.deleted_at is null
      and d.id <> new.id
  )
  select exists (select 1 from downstream where task_id = new.predecessor_task_id)
    into v_cycle;

  if v_cycle then
    raise exception 'schedule_task_dependencies: circular dependency denied'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger schedule_task_dependencies_no_cycle_trg
  before insert or update of predecessor_task_id, successor_task_id, deleted_at
  on public.schedule_task_dependencies
  for each row execute function public.schedule_task_dependencies_no_cycle();

-- ---------------------------------------------------------------------------
-- Row Level Security: project members read (incl. tombstones for sync),
-- editors write. Same helpers as the rest of the schema.
-- ---------------------------------------------------------------------------

alter table public.schedules enable row level security;
alter table public.schedule_phases enable row level security;
alter table public.schedule_tasks enable row level security;
alter table public.schedule_task_dependencies enable row level security;

-- schedules
create policy schedules_select
  on public.schedules for select to authenticated
  using (public.is_project_member(project_id));

create policy schedules_insert
  on public.schedules for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy schedules_update
  on public.schedules for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy schedules_delete
  on public.schedules for delete to authenticated
  using (public.can_edit_project(project_id));

-- schedule_phases
create policy schedule_phases_select
  on public.schedule_phases for select to authenticated
  using (public.is_project_member(project_id));

create policy schedule_phases_insert
  on public.schedule_phases for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy schedule_phases_update
  on public.schedule_phases for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy schedule_phases_delete
  on public.schedule_phases for delete to authenticated
  using (public.can_edit_project(project_id));

-- schedule_tasks
create policy schedule_tasks_select
  on public.schedule_tasks for select to authenticated
  using (public.is_project_member(project_id));

create policy schedule_tasks_insert
  on public.schedule_tasks for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy schedule_tasks_update
  on public.schedule_tasks for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy schedule_tasks_delete
  on public.schedule_tasks for delete to authenticated
  using (public.can_edit_project(project_id));

-- schedule_task_dependencies
create policy schedule_task_dependencies_select
  on public.schedule_task_dependencies for select to authenticated
  using (public.is_project_member(project_id));

create policy schedule_task_dependencies_insert
  on public.schedule_task_dependencies for insert to authenticated
  with check (public.can_edit_project(project_id));

create policy schedule_task_dependencies_update
  on public.schedule_task_dependencies for update to authenticated
  using (public.can_edit_project(project_id))
  with check (public.can_edit_project(project_id));

create policy schedule_task_dependencies_delete
  on public.schedule_task_dependencies for delete to authenticated
  using (public.can_edit_project(project_id));

-- ---------------------------------------------------------------------------
-- Privileges (default privileges already cover new tables; explicit for clarity)
-- ---------------------------------------------------------------------------

grant select, insert, update, delete
  on public.schedules,
     public.schedule_phases,
     public.schedule_tasks,
     public.schedule_task_dependencies
  to authenticated;

revoke all
  on public.schedules,
     public.schedule_phases,
     public.schedule_tasks,
     public.schedule_task_dependencies
  from anon;

grant execute on function public.schedule_task_dependencies_no_cycle() to authenticated;
