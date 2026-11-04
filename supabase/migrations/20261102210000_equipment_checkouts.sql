-- B Technica — equipment checkouts (additive). Prepared for review; not deployed.
--
-- Equipment stays user-owned (equipment_items.owner_id). A checkout records one
-- issue → return cycle: the project the item was issued in and its holder (a project
-- contact or free text). At most one open checkout exists per item.
-- equipment_items.status / issued_to remain the denormalized current state; the app
-- writes them in the same transaction as the checkout. 'returned' is kept in the enum
-- for existing rows; new returns leave the item 'available'.
-- Requires 20261102200000_project_contacts.sql.

alter type public.equipment_event_type add value if not exists 'markedAvailable';
alter type public.equipment_event_type add value if not exists 'handedOver';

alter table public.equipment_items
  add column if not exists serial_number text;

create type public.equipment_recipient_kind as enum ('person', 'company', 'text');

create type public.equipment_checkout_outcome as enum ('returned', 'damaged', 'lost', 'handedOver');

create table public.equipment_checkouts (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment_items (id) on delete cascade,
  project_id uuid references public.projects (id) on delete set null,
  recipient_kind public.equipment_recipient_kind not null,
  person_id uuid references public.contact_people (id) on delete set null,
  company_id uuid references public.contact_companies (id) on delete set null,
  -- Holder name snapshot; survives contact edits and deletion.
  recipient_name text not null check (char_length(trim(recipient_name)) > 0),
  location text,
  notes text,
  issued_at timestamptz not null,
  returned_at timestamptz,
  outcome public.equipment_checkout_outcome,
  return_notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  deleted_at timestamptz,
  check ((returned_at is null) = (outcome is null)),
  check (returned_at is null or returned_at >= issued_at),
  check (num_nonnulls(person_id, company_id) <= 1)
);

create unique index equipment_checkouts_one_active_uidx
  on public.equipment_checkouts (equipment_id)
  where returned_at is null and deleted_at is null;

create index equipment_checkouts_equipment_id_idx
  on public.equipment_checkouts (equipment_id, issued_at desc)
  where deleted_at is null;

create index equipment_checkouts_project_id_idx
  on public.equipment_checkouts (project_id)
  where deleted_at is null;

create index equipment_checkouts_person_id_idx
  on public.equipment_checkouts (person_id)
  where deleted_at is null;

create index equipment_checkouts_company_id_idx
  on public.equipment_checkouts (company_id)
  where deleted_at is null;

create trigger equipment_checkouts_set_updated_at
  before update on public.equipment_checkouts
  for each row execute function public.set_updated_at();

-- A contact holder must be linked to the checkout's project (no cross-project leakage).
create or replace function public.equipment_checkouts_validate_recipient()
returns trigger
language plpgsql
as $$
begin
  if new.project_id is null then
    return new;
  end if;
  if new.person_id is not null and not exists (
    select 1 from public.project_contacts pc
    where pc.project_id = new.project_id
      and pc.person_id = new.person_id
      and pc.deleted_at is null
  ) then
    raise exception 'equipment_checkouts.person_id: person is not a contact of the project'
      using errcode = '23514';
  end if;
  if new.company_id is not null and not exists (
    select 1 from public.project_contacts pc
    where pc.project_id = new.project_id
      and pc.company_id = new.company_id
      and pc.deleted_at is null
  ) then
    raise exception 'equipment_checkouts.company_id: company is not a contact of the project'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger equipment_checkouts_validate_recipient_trg
  before insert or update of project_id, person_id, company_id
  on public.equipment_checkouts
  for each row execute function public.equipment_checkouts_validate_recipient();

alter table public.equipment_events
  add column if not exists checkout_id uuid references public.equipment_checkouts (id) on delete set null,
  add column if not exists project_id uuid references public.projects (id) on delete set null;

create index if not exists equipment_events_checkout_id_idx
  on public.equipment_events (checkout_id)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- RLS: the equipment owner manages checkouts; members of the checkout's project
-- can see who holds equipment on their project.
-- ---------------------------------------------------------------------------

alter table public.equipment_checkouts enable row level security;

create policy equipment_checkouts_select
  on public.equipment_checkouts for select to authenticated
  using (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id and ei.owner_id = auth.uid()
    )
    or (deleted_at is null and project_id is not null and public.is_project_member(project_id))
  );

create policy equipment_checkouts_insert_own
  on public.equipment_checkouts for insert to authenticated
  with check (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id and ei.owner_id = auth.uid()
    )
    and (project_id is null or public.is_project_member(project_id))
  );

create policy equipment_checkouts_update_own
  on public.equipment_checkouts for update to authenticated
  using (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id and ei.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id and ei.owner_id = auth.uid()
    )
    and (project_id is null or public.is_project_member(project_id))
  );

create policy equipment_checkouts_delete_own
  on public.equipment_checkouts for delete to authenticated
  using (
    exists (
      select 1 from public.equipment_items ei
      where ei.id = equipment_id and ei.owner_id = auth.uid()
    )
  );

grant select, insert, update, delete on public.equipment_checkouts to authenticated;
