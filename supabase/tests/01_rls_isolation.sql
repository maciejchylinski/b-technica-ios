-- Cross-project isolation and unauthorized access tests (pgTAP).
-- Requires local Supabase with auth schema.

begin;

select plan(14);

-- ---------------------------------------------------------------------------
-- Fixtures: two users, two projects
-- ---------------------------------------------------------------------------

create temporary table _t (
  user_a uuid,
  user_b uuid,
  project_a uuid,
  project_b uuid,
  drawing_a uuid,
  drawing_b uuid,
  revision_a uuid,
  revision_b uuid,
  page_a uuid,
  page_b uuid
);

insert into _t default values;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'a@example.com',
    crypt('password', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(), now()
  ),
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'b@example.com',
    crypt('password', gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    now(), now()
  );

update _t set
  user_a = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  user_b = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- Profiles are created by trigger; ensure present
insert into public.profiles (id, display_name)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'User A'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'User B')
on conflict (id) do nothing;

insert into public.projects (id, owner_id, name)
values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Project A'),
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Project B');

update _t set
  project_a = '11111111-1111-1111-1111-111111111111',
  project_b = '22222222-2222-2222-2222-222222222222';

insert into public.drawings (id, project_id, name)
values
  ('d1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Drawing A'),
  ('d2222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Drawing B');

insert into public.drawing_revisions (id, drawing_id, storage_path, page_count, is_current)
values
  ('a1111111-1111-1111-1111-111111111111', 'd1111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111/a1111111-1111-1111-1111-111111111111.pdf', 1, true),
  ('a2222222-2222-2222-2222-222222222222', 'd2222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222/a2222222-2222-2222-2222-222222222222.pdf', 1, true);

insert into public.drawing_pages (id, revision_id, page_index)
values
  ('b1111111-1111-1111-1111-111111111111', 'a1111111-1111-1111-1111-111111111111', 0),
  ('b2222222-2222-2222-2222-222222222222', 'a2222222-2222-2222-2222-222222222222', 0);

update _t set
  drawing_a = 'd1111111-1111-1111-1111-111111111111',
  drawing_b = 'd2222222-2222-2222-2222-222222222222',
  revision_a = 'a1111111-1111-1111-1111-111111111111',
  revision_b = 'a2222222-2222-2222-2222-222222222222',
  page_a = 'b1111111-1111-1111-1111-111111111111',
  page_b = 'b2222222-2222-2222-2222-222222222222';

insert into public.issues (
  id, project_id, number, title, drawing_id, page_id, pdf_x, pdf_y, created_by
)
values
  (
    'c1111111-1111-1111-1111-111111111111',
    '11111111-1111-1111-1111-111111111111',
    1, 'Issue A',
    'd1111111-1111-1111-1111-111111111111',
    'b1111111-1111-1111-1111-111111111111',
    10.0, 20.0,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  ),
  (
    'c2222222-2222-2222-2222-222222222222',
    '22222222-2222-2222-2222-222222222222',
    1, 'Issue B',
    'd2222222-2222-2222-2222-222222222222',
    'b2222222-2222-2222-2222-222222222222',
    30.0, 40.0,
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  );

-- ---------------------------------------------------------------------------
-- As User A: can see Project A, cannot see Project B
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.projects where id = '11111111-1111-1111-1111-111111111111'),
  1,
  'user A can select own project'
);

select is(
  (select count(*)::int from public.projects where id = '22222222-2222-2222-2222-222222222222'),
  0,
  'user A cannot select other project'
);

select is(
  (select count(*)::int from public.issues where project_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'user A can select own project issues'
);

select is(
  (select count(*)::int from public.issues where project_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'user A cannot select other project issues'
);

select is(
  (select count(*)::int from public.drawings where project_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'user A cannot select other project drawings'
);

-- Unauthorized insert into Project B
select throws_ok(
  $$
    insert into public.issues (
      project_id, number, title, drawing_id, page_id, pdf_x, pdf_y
    ) values (
      '22222222-2222-2222-2222-222222222222',
      2, 'Hack',
      'd2222222-2222-2222-2222-222222222222',
      'b2222222-2222-2222-2222-222222222222',
      1, 1
    )
  $$,
  null,
  null,
  'user A cannot insert issue into project B'
);

-- Cross-project drawing link on own issue must fail integrity
select throws_ok(
  $$
    insert into public.issues (
      project_id, number, title, drawing_id, page_id, pdf_x, pdf_y
    ) values (
      '11111111-1111-1111-1111-111111111111',
      99, 'Cross',
      'd2222222-2222-2222-2222-222222222222',
      'b2222222-2222-2222-2222-222222222222',
      1, 1
    )
  $$,
  '23514',
  null,
  'cannot attach project B drawing to project A issue'
);

-- Viewer cannot edit
reset role;
insert into public.project_members (project_id, user_id, role)
values (
  '11111111-1111-1111-1111-111111111111',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'viewer'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.issues where project_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'viewer can read shared project issues'
);

select throws_ok(
  $$
    insert into public.issues (project_id, number, title)
    values ('11111111-1111-1111-1111-111111111111', 3, 'Viewer write')
  $$,
  null,
  null,
  'viewer cannot insert issues'
);

-- Anon has no access
reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select count(*)::int from public.projects),
  0,
  'anon cannot select projects'
);

select is(
  (select count(*)::int from public.issues),
  0,
  'anon cannot select issues'
);

-- Soft-deleted membership removes access
reset role;
update public.project_members
set deleted_at = timezone('utc', now())
where project_id = '11111111-1111-1111-1111-111111111111'
  and user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and role = 'viewer';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.issues where project_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'soft-deleted membership blocks access'
);

-- Owner-owned contractor invisible to other user
reset role;
insert into public.contractors (id, owner_id, name)
values (
  'e1111111-1111-1111-1111-111111111111',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'Acme Electric'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.contractors where id = 'e1111111-1111-1111-1111-111111111111'),
  0,
  'user B cannot read user A contractors'
);

select * from finish();
rollback;
