-- B Technica v2 — privileges for Supabase client roles.
-- RLS still decides which rows are visible; without GRANT, policies never run.

grant usage on schema public to anon, authenticated, service_role;

-- auth.uid() is provided by Supabase; clients need schema USAGE to call it.
grant usage on schema auth to authenticated, anon, service_role;

grant select, insert, update, delete
  on all tables in schema public
  to authenticated;

grant usage, select
  on all sequences in schema public
  to authenticated;

grant execute
  on all functions in schema public
  to authenticated;

-- anon: no table access (defense in depth; RLS also has no anon policies)
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- Future objects created by migrations/owners
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

alter default privileges in schema public
  grant usage, select on sequences to authenticated;

alter default privileges in schema public
  grant execute on functions to authenticated;
