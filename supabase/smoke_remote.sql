-- Remote deployment smoke checks. Entire script must run in one transaction and ROLLBACK.
-- Do not commit. Leaves no permanent data.

begin;

do $$
declare
  v_members int;
  v_next int;
  v_n1 int;
  v_n2 int;
  v_failed boolean := false;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'smoke-a-btechnica@example.com',
    crypt('x', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    now(), now()
  ),
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'smoke-b-btechnica@example.com',
    crypt('x', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    now(), now()
  );

  insert into public.profiles (id, display_name) values
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Smoke A'),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Smoke B')
  on conflict (id) do nothing;

  insert into public.projects (id, owner_id, name) values
    ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Smoke PA'),
    ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Smoke PB');

  select count(*) into v_members
  from public.project_members
  where project_id = '11111111-1111-1111-1111-111111111111'
    and user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and role = 'owner'
    and deleted_at is null;
  if v_members <> 1 then
    raise exception 'FAIL owner membership: got %', v_members;
  end if;

  select next_number into v_next
  from public.project_issue_counters
  where project_id = '11111111-1111-1111-1111-111111111111';
  if v_next is distinct from 1 then
    raise exception 'FAIL issue counter init: got %', v_next;
  end if;

  v_n1 := public.allocate_issue_number('11111111-1111-1111-1111-111111111111');
  v_n2 := public.allocate_issue_number('11111111-1111-1111-1111-111111111111');
  if v_n1 <> 1 or v_n2 <> 2 then
    raise exception 'FAIL allocate_issue_number: %, %', v_n1, v_n2;
  end if;

  select next_number into v_next
  from public.project_issue_counters
  where project_id = '11111111-1111-1111-1111-111111111111';
  if v_next is distinct from 3 then
    raise exception 'FAIL counter after allocate: got %', v_next;
  end if;

  insert into public.drawings (id, project_id, name) values
    ('d1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'DA'),
    ('d2222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'DB');
  insert into public.drawing_revisions (id, drawing_id, storage_path, page_count, is_current) values
    ('a1111111-1111-1111-1111-111111111111', 'd1111111-1111-1111-1111-111111111111',
     '11111111-1111-1111-1111-111111111111/a.pdf', 1, true),
    ('a2222222-2222-2222-2222-222222222222', 'd2222222-2222-2222-2222-222222222222',
     '22222222-2222-2222-2222-222222222222/a.pdf', 1, true);
  insert into public.drawing_pages (id, revision_id, page_index) values
    ('b1111111-1111-1111-1111-111111111111', 'a1111111-1111-1111-1111-111111111111', 0),
    ('b2222222-2222-2222-2222-222222222222', 'a2222222-2222-2222-2222-222222222222', 0);

  begin
    insert into public.issues (project_id, number, title, drawing_id, page_id, pdf_x, pdf_y)
    values (
      '11111111-1111-1111-1111-111111111111', 1, 'cross',
      'd2222222-2222-2222-2222-222222222222',
      'b2222222-2222-2222-2222-222222222222', 1, 1
    );
    v_failed := true;
  exception
    when check_violation then
      v_failed := false;
  end;
  if v_failed then
    raise exception 'FAIL: cross-project issue was allowed';
  end if;

end $$;

select 'SMOKE_PASS' as status;
rollback;
