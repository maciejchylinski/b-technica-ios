-- Schema smoke tests (pgTAP). Run via: supabase test db
begin;

select plan(20);

select has_table('public', 'profiles', 'profiles exists');
select has_table('public', 'projects', 'projects exists');
select has_table('public', 'project_members', 'project_members exists');
select has_table('public', 'contractors', 'contractors exists');
select has_table('public', 'disciplines', 'disciplines exists');
select has_table('public', 'issue_types', 'issue_types exists');
select has_table('public', 'equipment_items', 'equipment_items exists');
select has_table('public', 'equipment_events', 'equipment_events exists');
select has_table('public', 'equipment_project_assignments', 'equipment assignments exist');
select has_table('public', 'drawing_folders', 'drawing_folders exists');
select has_table('public', 'drawings', 'drawings exists');
select has_table('public', 'drawing_revisions', 'drawing_revisions exists');
select has_table('public', 'drawing_pages', 'drawing_pages exists');
select has_table('public', 'page_calibrations', 'page_calibrations exists');
select has_table('public', 'areas', 'areas exists');
select has_table('public', 'issues', 'issues exists');
select has_table('public', 'issue_photos', 'issue_photos exists');
select has_table('public', 'project_issue_counters', 'issue counters exist');

select has_function('public', 'is_project_member', array['uuid'], 'is_project_member helper');
select has_function('public', 'allocate_issue_number', array['uuid'], 'allocate_issue_number helper');

select * from finish();
rollback;
