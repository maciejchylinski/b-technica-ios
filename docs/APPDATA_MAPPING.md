# appdata.json → Supabase schema mapping

Migration guide for existing local `Documents/appdata.json` records.
**Do not run data migration yet** — this document is the contract for a future importer.

## Principles

- Preserve existing UUIDs (`id` fields) wherever a matching table exists.
- Preserve PDF page coordinates exactly (`pdfX`/`pdfY`, calibration points).
- Prefer soft delete (`deleted_at`) over hard delete after cloud sync exists.
- One local `AppData.project` becomes one `projects` row; the signed-in user becomes `owner_id` and an `owner` `project_members` row.

## Root document

| appdata.json | Supabase |
|---|---|
| `schemaVersion` | Not stored remotely (local-only). Track importer version separately. |
| `project` | `projects` (+ `project_members`, `project_issue_counters`) |
| `drawings[]` | `drawings` + `drawing_revisions` + `drawing_pages` + `page_calibrations` |
| `issues[]` | `issues` + `issue_photos` |
| `equipment[]` | `equipment_items` + `equipment_events` |
| `contractors[]` | `contractors` (`owner_id` = signed-in user) |
| `disciplines[]` | `disciplines` (`owner_id` = signed-in user) |

## Project

| Swift `Project` | `projects` |
|---|---|
| `id` | `id` (preserve) |
| `name` | `name` |
| `createdDate` | `created_at` |
| — | `owner_id` = auth user |
| — | `active_project_id` on `profiles` |

## Drawing

Local `Drawing` is a single record with embedded PDF file + revision label + calibrations.
Cloud splits that into logical drawing / revision / pages.

| Swift `Drawing` | Supabase |
|---|---|
| `id` | `drawings.id` (preserve) |
| `projectId` | `drawings.project_id` |
| `name` | `drawings.name` |
| `discipline` | `drawings.discipline` (text; optional later FK) |
| `location` | `drawings.location` |
| `createdDate` | `drawings.created_at` |
| `folderId` | `drawings.folder_id` (`null` = project root); local `drawingFolders[]` → `drawing_folders` |
| `fileName` | Upload `Documents/Drawings/{fileName}` → Storage `drawings/{project_id}/{revision_id}.pdf`; store path in `drawing_revisions.storage_path`; keep basename in `original_file_name` |
| `pageCount` | `drawing_revisions.page_count` + N `drawing_pages` rows (`page_index` 0..n-1) |
| `revision` | `drawing_revisions.revision_label` |
| `drawingDate` | `drawing_revisions.drawing_date` |
| — | `drawing_revisions.is_current = true` for the imported revision |
| `calibrations[]` | See below |

### PageCalibration

| Swift `PageCalibration` | `page_calibrations` |
|---|---|
| `id` | `id` (preserve) |
| `pageIndex` | Resolve `drawing_pages` where `page_index` matches current revision → `page_id` |
| `pointA.x/y` | `point_a_x` / `point_a_y` |
| `pointB.x/y` | `point_b_x` / `point_b_y` |
| `realDistanceMM` | `real_distance_mm` |
| `enteredUnit` | `entered_unit` (`mm`/`cm`/`m`) |
| `enteredValue` | `entered_value` |
| `mmPerPDFUnit` | `mm_per_pdf_unit` |
| `calibratedDate` | `calibrated_at` |

## Issue

| Swift `Issue` | `issues` |
|---|---|
| `id` | `id` (preserve) |
| — | `project_id` = parent project (required) |
| `number` | `number` (preserve; advance `project_issue_counters.next_number` to max+1) |
| `title` | `title` |
| `details` | `details` |
| `status` | `status` (`open`/`inProgress`/`resolved`/`closed`) |
| — | `issue_type_id` null on import (or default project type “Issue”) |
| `drawingId` | `drawing_id` (optional in schema; present for current data) |
| `pageIndex` | Resolve to `page_id` on current revision |
| `pdfX` / `pdfY` | `pdf_x` / `pdf_y` (unchanged doubles) |
| `areaId` (optional UUID) | `area_id` (preserve UUID; null when unassigned) |
| `discipline` (string) | Resolve/create `disciplines` → `discipline_id`; also copy into `discipline_name` |
| `contractor` (string) | Resolve/create `contractors` → `contractor_id`; also copy into `contractor_name` |
| `createdDate` | `created_at` |
| `photos[]` | `issue_photos` |

### IssuePhoto

| Swift `IssuePhoto` | `issue_photos` |
|---|---|
| `id` | `id` (preserve) |
| `fileName` | Upload `Documents/IssuePhotos/{fileName}` → Storage `issue-photos/{project_id}/{issue_id}/{photo_id}.jpg`; set `storage_path` |
| `createdDate` | `created_at` |

## Equipment

| Swift `EquipmentItem` | `equipment_items` |
|---|---|
| `id` | `id` (preserve) |
| `item` | `name` |
| `category` | `category` |
| `identifier` | `identifier` |
| `notes` | `notes` |
| `status` | `status` |
| `issuedTo` | `issued_to` |
| `location` | `location` |
| `issuedDate` | `issued_at` |
| `returnedDate` | `returned_at` |
| — | `owner_id` = signed-in user |
| `history[]` | `equipment_events` |

| Swift `EquipmentEvent` | `equipment_events` |
|---|---|
| `id` | `id` (preserve) |
| `date` | `event_at` |
| `type` | `event_type` |
| `person` | `person` |
| `location` | `location` |
| `notes` | `notes` |

Optional: create `equipment_project_assignments` linking each item to the imported project.

## Dictionaries

| Swift | Supabase |
|---|---|
| `Contractor.id/name/notes/createdDate` | `contractors` with `owner_id` |
| `Discipline.id/name/createdDate` | `disciplines` with `owner_id` |

## Areas (local → cloud)

| Swift `Area` | Supabase `areas` |
|---|---|
| `id` | `id` (preserve UUID) |
| `projectId` | `project_id` |
| `drawingId` | `drawing_id` |
| `pageIndex` (0-based) | `page_id` → resolve via `drawing_pages` |
| `name` | `name` |
| `vertices` `[PDFPoint]` | `vertices` jsonb `[{x,y},…]` (≥3, PDF page coords) |
| `color` (`#RRGGBB`) | `color` |
| `opacity` | `opacity` |
| `isVisible` | `is_visible` |
| `createdDate` / `updatedDate` | `created_at` / `updated_at` |

## New cloud-only concepts (no local source yet)

- `drawing_revisions` history beyond the single current PDF
- `issue_types` — seed a default type per project if desired
- `deleted_at` — null for all imported rows

## Storage path conventions

```
drawings/{project_id}/{revision_id}.pdf
issue-photos/{project_id}/{issue_id}/{photo_id}.jpg
```

## Import safety checklist

1. Export / backup `appdata.json`, `Drawings/`, `IssuePhotos/` before any write.
2. Create auth user; confirm `profiles` row.
3. Insert project with preserved UUID; confirm owner membership + issue counter.
4. Upload binaries, then insert metadata in FK order: folders → drawings → revisions → pages → calibrations → dictionaries → issues → photos → equipment.
5. Verify issue numbers and counter: `next_number = max(number) + 1`.
6. Spot-check pin coordinates against a known PDF page.
7. Keep local JSON as read-only fallback until sync is proven.
