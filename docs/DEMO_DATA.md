# Demo data (DEBUG only)

A realistic, fully local demo workspace for first-launch exploration on a simulator, Mac or iPhone.
Everything is **fictional** and exists only in **Debug builds**.

## Launching the demo in Xcode

1. Open `BTechnica.xcodeproj` and choose the **Debug** configuration (the default Run scheme).
2. Start the app. No Supabase configuration or sign-in is needed:
   - On the **sign-in screen**, tap **Open demo projects**.
   - Or, when already signed in, tap **Open demo projects** on the projects list.
   - Or add the launch argument `-BTDemo` (Scheme → Run → Arguments) to open the demo gate directly.
3. On first open, the app seeds the demo workspace. Pick **Osiedle Zielone Tarasy — Etap I** or **Modernizacja Biurowca — Centrum**.
4. *More → Switch Project* returns to the demo project list; *More → Exit demo mode* returns to normal sign-in.

### Reset

- In the demo gate, use **Reset demo data** (with confirmation), or start with `-BTDemoReset`.
- A reset deletes and recreates **only** the demo workspace: the demo user's SQLite rows and `Documents/Users/DE300000-…/Projects`. Real accounts, their databases and their files are never opened.

## How it works (safety)

| Concern | Mechanism |
|---|---|
| Isolation from real users | Fixed local demo user id `DE300000-B7EC-4A1C-8000-000000000001` (never a Supabase account), with its own `Documents/Users/<id>/btechnica.sqlite` and file tree. |
| No Supabase traffic | `LocalOnlyWorkspace.isLocalOnly(userId:)` is part of all 9 Supabase guards in `BTechnica/Sync/*` (outbox push, folder/drawing pull, PDF upload/download). It is always `false` in Release. |
| No outbox / transfers from seeding | The seeder uses only non-sync persistence APIs (`persistProjectWorkspace`, contacts, photos, schedule, knowledge, equipment). It never calls folder/area/PDF outbox APIs; a source test enforces this. |
| DEBUG only | All code in `BTechnica/Demo/` is wrapped in `#if DEBUG`; app hooks (gate, login/projects buttons, More tab, `KnowledgeStore.discardCachedStore`) are DEBUG-only too. Fixtures are excluded from Release via `EXCLUDED_SOURCE_FILE_NAMES[config=Release] = demo-fixture-*` (`Config/Base.xcconfig`). |
| Idempotency | Deterministic UUIDv5 ids plus a `sync_state` marker (`demo.seed.version` = manifest `seedVersion`). A matching marker means nothing is written; a new fixture version (or reset) wipes the demo database and seeds again, so re-runs never duplicate rows. |
| Wrong database | `DemoDataSeeder.seed()` throws `notDemoDatabase` for any database not owned by the demo user id. |
| Offline | All files ship in the app bundle; nothing is downloaded. |

User edits made inside the demo persist until the next reset or fixture version change.

## Contents

**Project A — Osiedle Zielone Tarasy — Etap I** (residential, building A, underground garage)

- 9 drawing folders, nested: Architektura → Rzuty / Przekroje / Elewacje / Detale; Konstrukcja; Instalacje sanitarne; Instalacje elektryczne; Zagospodarowanie terenu.
- 11 drawings (12 pages): Z-001 site plan 1:500, A-100 garage 1:200, A-101 ground floor, A-102 typical floor, A-201 section A-A, A-301 south elevation, A-501 detail D-1 1:5, K-101 slab structure, S-101 water and sewage, S-201 ventilation, E-101 electrical (2 sheets).
  - Vector PDFs with walls, doors, windows, stairs, grid axes, dimension chains, room labels with areas, and a title block with revision table.
  - Five drawings carry a scale calibration.
- 35 issues on 11 drawings: 15 open, 10 in progress, 6 resolved, 4 closed. They span 7 contractors, 8 disciplines and creation dates from 2 to 150 days ago.
- 8 polygon areas, for example: Budynek A — Parter / Piętro 1, Klatka schodowa A, Lokal A/12, Lokal A/08 z balkonem, Garaż — hala postojowa, Strefa instalacyjna, Strefa wjazdu do garażu.
- 20 documentation photos in 4 albums (9 linked to issues, 8 to areas, 15 to drawings), plus 8 photos attached to 7 issues.
- Schedule: 6 phases, 23 entries (4 milestones), 20 finish-to-start dependencies.
  - Completed, in-progress, delayed and planned work, with dates relative to the seed day.
- 22 project contacts (10 companies, 12 people) with roles.
- 6 searchable technical PDFs in 3 folders: ST-04 hydroizolacja (2 pages), ST-02 beton, narada nr 14, LK-03 lista odbioru, BHP-02, protokół PE-01. Also 4 field notes.

**Project B — Modernizacja Biurowca — Centrum** (office fit-out, 3rd floor)

- 2 folders, 3 drawings (architecture, electrical, HVAC)
- 8 issues and 2 areas (open space, server room)
- 3 + 1 photos
- 7 schedule entries
- 8 contact links: 2 companies and 2 people are shared with project A
- 1 document and 2 notes

**User-global**

- 8 contractors, 8 disciplines, 12 companies and 14 people in the address book.
- 10 equipment items with check-out and return history across both projects. Current state: 5 issued, 4 available, 1 damaged.

Issue pins and polygon vertices are stored in **PDF page coordinates**, which is the app's model (not normalized). Every pin is placed on a real drawing feature, for example the A/08 balcony door threshold or RG in the technical room.

Contact details are fictional: phone numbers `+48 000 000 xxx` and `*.demo.example` addresses. Photos are procedurally generated illustrations (no people, no real places) marked "ZDJĘCIE SYNTETYCZNE".

Not supported by the current models, so not seeded: issue priority and deadlines, and drawing page mappings (demo drawings are local-only, never uploaded).

## Fixture files

`BTechnica/DemoFixtures/` holds 54 files, about 0.5 MB:

- `demo-fixture-manifest.json`
- 14 `demo-fixture-dwg-*.pdf`
- 7 `demo-fixture-doc-*.pdf`
- 32 `demo-fixture-photo-*.png`

All are generated by `Tools/DemoFixtures/` (Python standard library only):

```bash
python Tools/DemoFixtures/generate_demo_fixtures.py
```

```bash
python Tools/DemoFixtures/generate_demo_fixtures.py --check
```

The generator is deterministic and validates every record at build time. Editing `Tools/DemoFixtures/dataset.py` and regenerating changes `seedVersion`, so the app re-seeds automatically. The PDFs can be opened in any PDF viewer (for example Microsoft Edge) for review.

## Verification

| Check | Where | Status |
|---|---|---|
| `python -m unittest discover -s Tests/DemoData -v` (21 tests) | Windows / any OS | Run: 21/21 pass |
| Also run here: `python -m unittest discover -s Tests/SQLite` | Windows / any OS | Run: pass |
| Swift harness `-BTVerifyDemoSeed` (`DemoSeedVerification.swift`) | Mac / simulator | Prepared, **not run** |

The Python suite verifies:

- Fixture freshness and determinism.
- PDF structure (xref, page count, MediaBox) and the document text layer, decoded through each PDF's own ToUnicode map.
- PNG validity.
- Unique UUIDs, and a demo user id that matches the Swift constant.
- Referential integrity: folders, drawings, areas, pin-in-area and pin-not-under-title-block, photo links, schedule rules, contact roles, equipment recipients.
- Seeding into the real schema with the INSERT/UPDATE statements extracted from the Swift persistence code (CHECK / FK / UNIQUE, FTS).
- Fictional contact data, plus source checks: DEBUG-only demo code, no sync APIs in the seeder, the guard on every Supabase call, and Release exclusion.

The Swift harness runs the real seeder on a temporary database, then checks:

- Idempotent second run, and a forced re-seed without duplicates.
- Zero outbox, file-transfer and page-mapping rows.
- Every drawing opens in PDFKit, with pins and areas inside the actual page bounds.
- Every document has a PDFKit text layer and stays pending for the app indexer.
- The seeder refuses a non-demo database.

## First run on a MacBook — checklist

1. Build **Debug** and **Release**. Confirm the Release `.app` contains no `demo-fixture-*` files: `EXCLUDED_SOURCE_FILE_NAMES` support for synchronized folders is still unverified.
2. Run with `-BTVerifyDemoSeed`: exit code 0, stderr `BT_DEMO_SEED_VERIFY passed=true`.
3. Run with `-BTDemo`, open project A:
   - Drawings: nested folders, A-101 opens; zoom and pan, pins and areas are visible.
   - Tap a pin to open the issue, then return to the drawing.
   - E-101 has 2 pages.
4. Issues: filter by status. Reports: filter by contractor or discipline, generate a PDF with and without photos.
5. More → Photo documentation: albums, thumbnails, full-screen viewer. Issue detail shows attached and linked photos.
6. More → Schedule & Gantt: list and Gantt show completed, active and delayed work around "today".
7. More → Contacts, and Equipment (5 issued, 1 damaged, with history).
8. More → Project Documents: indexing finishes; search for `hydroizolacja` and `IP44` finds documents with page numbers; notes are searchable.
9. Switch to project B: only office data is shown. Exit demo mode and sign in normally: real projects are unaffected.
10. Reset demo data, then reopen: the same content, no duplicates.

## Files

- **App (DEBUG):** `BTechnica/Demo/DemoMode.swift`, `DemoFixtureManifest.swift`, `DemoDataSeeder.swift`, `DemoGateView.swift`, `DemoSeedVerification.swift`.
- **App (always compiled):** `BTechnica/Support/LocalOnlyWorkspace.swift`.
- **App hooks:**
  - `Features/AppGateView.swift`, `Features/Auth/LoginView.swift`, `Features/Projects/ProjectsView.swift`, `Features/More/MoreView.swift`
  - `Store/KnowledgeStore.swift`, `BTechnicaApp.swift`
  - 8 files in `Sync/` (guards)
  - `Config/Base.xcconfig`
- **Fixtures and tools:** `BTechnica/DemoFixtures/*`, `Tools/DemoFixtures/*`, `Tests/DemoData/test_demo_fixtures.py`.
