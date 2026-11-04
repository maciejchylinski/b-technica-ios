-- Construction schedule: RLS isolation, integrity and cycle prevention (pgTAP).
-- Requires local Supabase with auth schema.

begin;

select plan(16);

-- ---------------------------------------------------------------------------
-- Fixtures: two users, two projects (owners become members via trigger)
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'sched-a@example.com', crypt('password', gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'sched-b@example.com', crypt('password', gen_salt('bf')),
   now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now())
on conflict (id) do nothing;

insert into public.profiles (id, display_name)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'User A'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'User B')
on conflict (id) do nothing;

insert into public.projects (id, owner_id, name)
values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Project A'),
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Project B');

-- Project B schedule + task (created as owner of B, outside RLS)
insert into public.schedules (id, project_id, name)
values ('5b000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'B schedule');

insert into public.schedule_tasks (id, project_id, schedule_id, title, start_date, finish_date)
values ('7b000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
        '5b000000-0000-0000-0000-000000000000', 'B task', '2026-11-02', '2026-11-06');

-- ---------------------------------------------------------------------------
-- As User A
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);

select lives_ok(
  $$ insert into public.schedules (id, project_id, name)
     values ('5a000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'A schedule') $$,
  'user A can create a schedule in project A'
);

select throws_ok(
  $$ insert into public.schedules (project_id, name)
     values ('22222222-2222-2222-2222-222222222222', 'Hack') $$,
  '42501', null,
  'user A cannot create a schedule in project B'
);

select throws_ok(
  $$ insert into public.schedules (project_id, name)
     values ('11111111-1111-1111-1111-111111111111', 'Second') $$,
  '23505', null,
  'only one live schedule per project'
);

select lives_ok(
  $$
    insert into public.schedule_phases (id, project_id, schedule_id, name)
    values ('6a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
            '5a000000-0000-0000-0000-000000000000', 'Foundations');
    insert into public.schedule_tasks (id, project_id, schedule_id, phase_id, title, start_date, finish_date)
    values
      ('7a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
       '5a000000-0000-0000-0000-000000000000', '6a000000-0000-0000-0000-000000000001', 'Excavate', '2026-11-02', '2026-11-06'),
      ('7a000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
       '5a000000-0000-0000-0000-000000000000', '6a000000-0000-0000-0000-000000000001', 'Footings', '2026-11-09', '2026-11-13'),
      ('7a000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
       '5a000000-0000-0000-0000-000000000000', null, 'Slab', '2026-11-16', '2026-11-18');
    insert into public.schedule_task_dependencies (id, project_id, schedule_id, predecessor_task_id, successor_task_id)
    values
      ('8a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
       '7a000000-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000002'),
      ('8a000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
       '7a000000-0000-0000-0000-000000000002', '7a000000-0000-0000-0000-000000000003');
  $$,
  'user A can add phases, tasks and dependencies'
);

select throws_ok(
  $$ insert into public.schedule_task_dependencies (project_id, schedule_id, predecessor_task_id, successor_task_id)
     values ('11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
             '7a000000-0000-0000-0000-000000000003', '7a000000-0000-0000-0000-000000000001') $$,
  '23514', null,
  'circular dependency rejected'
);

select throws_ok(
  $$ insert into public.schedule_task_dependencies (project_id, schedule_id, predecessor_task_id, successor_task_id)
     values ('11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
             '7a000000-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001') $$,
  '23514', null,
  'self dependency rejected'
);

select throws_ok(
  $$ update public.schedule_tasks set finish_date = '2026-10-01'
     where id = '7a000000-0000-0000-0000-000000000002' $$,
  '23514', null,
  'finish before start rejected'
);

select throws_ok(
  $$ insert into public.schedule_tasks (project_id, schedule_id, kind, title, start_date, finish_date)
     values ('11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
             'milestone', 'Bad milestone', '2026-12-01', '2026-12-03') $$,
  '23514', null,
  'multi-day milestone rejected'
);

select throws_ok(
  $$ insert into public.schedule_task_dependencies (project_id, schedule_id, predecessor_task_id, successor_task_id)
     values ('11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
             '7a000000-0000-0000-0000-000000000001', '7b000000-0000-0000-0000-000000000001') $$,
  '23503', null,
  'dependency to a task in another project rejected'
);

select throws_ok(
  $$ insert into public.schedule_tasks (project_id, schedule_id, title, start_date, finish_date)
     values ('11111111-1111-1111-1111-111111111111', '5b000000-0000-0000-0000-000000000000',
             'Cross', '2026-11-02', '2026-11-03') $$,
  '23503', null,
  'task cannot reference another project''s schedule'
);

select is(
  (select count(*)::int from public.schedule_tasks where project_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'user A cannot see project B tasks'
);

select is(
  (select count(*)::int from public.schedules where project_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'user A cannot see project B schedule'
);

-- Soft-deleting an edge frees the path: A3 → A1 is no longer a cycle.
select lives_ok(
  $$
    update public.schedule_task_dependencies set deleted_at = now()
    where id = '8a000000-0000-0000-0000-000000000002';
    insert into public.schedule_task_dependencies (project_id, schedule_id, predecessor_task_id, successor_task_id)
    values ('11111111-1111-1111-1111-111111111111', '5a000000-0000-0000-0000-000000000000',
            '7a000000-0000-0000-0000-000000000003', '7a000000-0000-0000-0000-000000000001');
  $$,
  'tombstoned dependency is ignored by the cycle check'
);

select is(
  (select count(*)::int from public.schedule_task_dependencies
   where project_id = '11111111-1111-1111-1111-111111111111' and deleted_at is not null),
  1,
  'members can read tombstones for sync'
);

-- ---------------------------------------------------------------------------
-- As User B
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);

select is(
  (select count(*)::int from public.schedule_tasks where project_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'user B cannot see project A tasks'
);

select is(
  (select count(*)::int from public.schedule_tasks where project_id = '22222222-2222-2222-2222-222222222222'),
  1,
  'user B sees own project tasks'
);

select * from finish();

rollback;
