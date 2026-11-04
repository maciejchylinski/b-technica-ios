# Construction Schedule & Gantt (v1)

Project-scoped construction schedule: phases, tasks, milestones, finish-to-start
dependencies, field task list, upcoming work, overview, and an interactive Gantt.
Local SQLite only; cloud sync is prepared (schema, ids) but not implemented.

## Where it lives

| Layer | Files |
| --- | --- |
| Models | `Models/CalendarDay.swift`, `Models/ConstructionSchedule.swift`, `Models/ScheduleRules.swift`, `Models/ScheduleAnalytics.swift` |
| SQLite | `Persistence/AppDatabase+ScheduleSchema.swift` (migration `v4_construction_schedule`), `Persistence/ScheduleMetadataStore.swift` |
| Store | `Store/ScheduleStore.swift` (self-contained; opens `AppDatabase.shared(for:)`) |
| UI | `Features/Schedule/**` (entry: `ScheduleHomeView(userId:project:contractorNames:)`) |
| Supabase | `supabase/migrations/20261102210000_construction_schedule.sql`, `supabase/tests/02_schedule_rls.sql` |
| Checks | `Persistence/ScheduleVerification.swift` (launch arg `-BTVerifySchedule`, DEBUG) |

## Data rules

- One schedule per project (`schedules.project_id` unique; partial unique index in Postgres).
- Composite foreign keys carry `project_id` / `schedule_id` into phases, tasks and
  dependencies, so no row can reference another project's or schedule's data.
- Calendar days are `yyyy-MM-dd` TEXT locally and `date` in Postgres. `CalendarDay`
  does integer day arithmetic; `Date` is used only at the `DatePicker` edge (local noon).
- `finish_date >= start_date`, milestones are a single day, `progress` 0–100,
  `completed ⇒ progress = 100` — enforced in Swift, SQLite CHECKs and Postgres CHECKs.
- Dependency cycles are rejected in Swift (`ScheduleRules`), inside the SQLite write
  transaction, and by a Postgres trigger (serialized per schedule with an advisory lock).
- Deleting a phase deletes its tasks; deleting a task deletes its dependencies.

## Integration with parallel work

Shared files touched (small, additive hunks):

- `Persistence/AppDatabase.swift` — registers `v4_construction_schedule` after
  `v1_foundation`. Other branches register `v2_drawing_page_mappings` and
  `v3_project_contacts` at the same spot. When merging, keep all registrations;
  the schedule migration is independent of v2/v3, so order among them does not matter,
  but already-shipped identifiers must never be renamed.
- `Features/More/MoreView.swift` — new `Section("Planning")` after the Project section.
  The Contacts branch inserts into `Section("Tools")`; the hunks do not overlap.
- `Features/Home/HomeView.swift` — one "Schedule" shortcut row.
- `BTechnicaApp.swift` — one DEBUG line `ScheduleVerification.runIfRequested()`.

## Future Contacts integration

`schedule_tasks.responsible_name` (free text) is the v1 responsibility field.
`schedule_tasks.responsible_contact_id` (UUID, nullable, **no FK yet**) is reserved
for the Project Contacts module and is preserved on every save.

When Contacts lands:

1. Point `responsible_contact_id` at `project_contacts.id` (the per-project link, so
   the responsible party is always a member of the same project). Add the FK in an
   additive migration (`on delete set null`), plus a same-project check
   (`project_contacts.project_id = schedule_tasks.project_id`).
2. In `ScheduleTaskEditor`, replace the "Choose existing" contractor menu with a
   project-contact picker that sets both `responsibleContactId` and
   `responsibleName` (keep the name as a display/offline fallback).
3. Optionally backfill: match existing `responsible_name` values to contacts.

No schedule code imports Contacts types today.

## Future sync

- Table/column names and client UUIDs match Supabase 1:1; `updated_at` is set on every
  local mutation. Postgres rows have `deleted_at` and members can read tombstones.
- Local deletes are hard deletes. A sync implementation should enqueue
  `sync_outbox` delete operations (existing pattern) or add local tombstones.
- Suggested push order: schedules → phases → tasks → dependencies.
