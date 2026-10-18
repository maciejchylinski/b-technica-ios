# B Technica v2 — Supabase database

Versioned PostgreSQL migrations, RLS, Storage policies, and pgTAP tests for the cloud schema.

## Layout

```
supabase/
  config.toml
  seed.sql                 # empty (no product seed data)
  migrations/              # ordered SQL migrations
  tests/                   # pgTAP isolation / smoke tests
docs/
  APPDATA_MAPPING.md       # local appdata.json → schema mapping
```

## Migrations (apply order)

| File | Purpose |
|---|---|
| `20251018190000_extensions_helpers.sql` | pgcrypto, `set_updated_at` |
| `20251018190100_profiles_projects.sql` | profiles, projects, members, auth trigger |
| `20251018190200_dictionaries_equipment.sql` | contractors, disciplines, issue types, equipment |
| `20251018190300_drawings.sql` | folders, drawings, revisions, pages, calibrations |
| `20251018190400_areas_issues.sql` | areas, issues, photos, issue counters |
| `20251018190500_cross_project_integrity.sql` | same-project FK triggers |
| `20251018190600_rls_policies.sql` | RLS on all client tables |
| `20251018190700_storage.sql` | private buckets + storage policies |
| `20251018190800_grants.sql` | privileges for `authenticated` / revoke `anon` |

## Local commands (requires Docker)

```bash
supabase start
supabase db reset          # apply migrations + seed
supabase test db           # run pgTAP tests under supabase/tests/
```

Without Docker, migrations can still be syntax-applied against a local Postgres 17
instance with stub `auth` / `storage` schemas (used during preparation).

Do **not** push these migrations to the production Supabase project until explicitly approved.

## Security notes

- Never embed the `service_role` key in the iOS app.
- Client uses anon key + authenticated JWT only.
- Authorization is enforced by RLS and integrity triggers, not UI filters.
