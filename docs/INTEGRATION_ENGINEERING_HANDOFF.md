# Integration engineering handoff — `integration/btechnica-v2`

Base commit `c876605`. Everything below is **uncommitted** in the working tree. Nothing has been
compiled: the work was done on Windows without Xcode.

## 1. Inherited from the previous session (re-verified in this sprint)

| Change | Files |
|---|---|
| Incremental workspace save: `SQLiteWorkspaceBaseline` + `persistProjectWorkspaceDelta`; skip the JSON rewrite when it would be identical | `Store/AppStore.swift`, `Persistence/DrawingMetadataStore.swift` |
| Grouped photo / calibration fetch (replaces N+1) | `Persistence/IssueAreaMetadataStore.swift`, `Persistence/DrawingMetadataStore.swift` |
| Folder pull refreshes memory (`onApplied: refreshHandler`) | `Sync/DrawingFolderSyncCoordinator.swift` |
| Issue photos: async 480 px thumbnails, 2560 px preview | `Features/Issues/IssueDetailView.swift` |
| Report photos decoded lazily at 1200 px | `Features/Reports/IssueReportGenerator.swift`, `ReportsView.swift` |
| Per-transfer PDF download dedup | `Sync/DrawingPDFDownloadService.swift` |
| `#if DEBUG` around all `*Verification.swift` | 18 files under `Persistence/`, `Sync/` |
| `IdentifiedUUID` collision → `LinkedPhotoEditTarget` | `Features/Photos/LinkedDocumentationPhotosSection.swift` |

## 2. This sprint

| # | Problem | Fix | Files |
|---|---|---|---|
| S1 | Delta save could get permanently stuck. A pull tombstones drawing D in SQLite while memory isn't reloaded, then the user pins an issue on D. The delta upserts only the issue, which fails the FK; the baseline never advances, so **every later save fails** and the unsaved edits are lost at restart. | Parents of changed issues and areas go into `ProjectWorkspaceDelta.ensureParentDrawings`; `insertMissingParentDrawings` writes one **only if no row with that id exists**. *Safety review correction:* the first version fully re-upserted the parent from memory on every child edit, which reverted newer pulled name, revision and `folder_id` whenever memory was stale. | `Store/AppStore.swift`, `Persistence/DrawingMetadataStore.swift` |
| S2 | Outbox head-of-line blocking across projects: one pending op from project A (`.stopDrain` on project mismatch) blocked **all** pushes of project B. | Other projects' ops return `.continueDrain` and stay queued untouched. FIFO order is unchanged within each project. | `Sync/SyncOutboxPushService.swift` |
| S3 | A drawing-create op whose PDF upload isn't confirmed stopped the drain, so unrelated folder and area ops waited behind it, possibly forever. | Returns `.continueDrain`, the same rule the area path already uses for a drawing that isn't ready. | `Sync/SyncOutboxPushService.swift` |
| S4 | The issue form drew each pending full-resolution `UIImage` in a 72 pt cell, keeping a full bitmap resident per photo. | One-time 216 px `preparingThumbnail` for display; the saved image is unchanged. | `Features/Issues/IssueFormView.swift` |
| S5 | No regression coverage for the above. | Swift DEBUG harnesses plus a Python SQLite suite (section 5). | new files below |

`SQLiteWorkspaceBaseline` changed from `private` to internal so the harness can drive it.

## 3. Data-integrity status (WP1 scenarios against the actual Swift)

| Scenario | Result |
|---|---|
| Edit an issue once or repeatedly | Only that issue is upserted; the last value is persisted; an unchanged save opens no transaction. |
| Delete an issue with photos | `DELETE issues` cascades `issue_photos`; `project_photos.issue_id` is set to NULL; files are removed by `AppStore.deleteIssue`. |
| Delete a drawing with issues and areas | `AppStore.deleteDrawing` removes dependents from memory first; the delta deletes issues, then areas, then the drawing (calibrations and page mappings cascade). |
| Remote change after the baseline was taken | Pull plus refresh update memory and the baseline together (same main-actor turn). Without a refresh, the pulled rows are no longer deleted or overwritten by unrelated saves (the old full writer did both). |
| Project switch during async work | The baseline belongs to the `AppStore` instance (immutable `projectId`); deletes are `WHERE id = ? AND project_id = ?`. |
| Write failure, then save again | The GRDB write is one transaction; the baseline advances only after success, so the next save re-applies the rolled-back changes. |
| Folder pulled, drawing pull fails | Memory is refreshed after the folder pull (inherited fix); the delta doesn't treat the folder as an orphan. |
| Direct writes outside `persist()` | Folder create/rename/delete and area create write SQLite and then memory; the delta re-upserts identical rows (idempotent). Pulls refresh memory and the baseline. The JSON importer only does `INSERT OR IGNORE` at bootstrap. |

Remaining after the safety review:

- If a refresh after a pull fails, memory can show stale drawing metadata until the next successful pull or restart. SQLite keeps the newer row, because child edits never overwrite an existing parent.
- **Operator decision:** a drawing tombstoned remotely, while it had no local dependents and memory wasn't reloaded, is restored locally when the user then adds the first issue or area on it. That keeps the user's data, and later pulls keep the drawing because it now has local dependents. It stays local-only, its download transfer was removed by the pull, and its `folder_id` comes from memory, so it may point to a folder that no longer exists. Should the app tell the user, or move such issues elsewhere?
- After a failed transaction, memory stays ahead of SQLite (as before). The baseline isn't advanced, so the next save retries; a restart before a successful save loses the unsaved edits (pre-existing behaviour).

## 4. Synchronization limitations: decision boundary (not implemented)

| Issue | Evidence | Proposed implementation, needs a decision |
|---|---|---|
| A local drawing rename or move is reverted by the next pull | `moveDrawing` / `updateDrawingDetails` call only `persist()`; the drawing outbox supports only `.create` (`processDrawing`); `applyRemoteDrawingPull` upserts `folder_id, name, revision, …` | Enqueue a drawing `.update` op in the same transaction as the local write (pattern: `persistDrawingFolderRename`). `pendingDrawingEntityIds` already makes the pull skip drawings with pending ops. Add `DrawingRemoteStore.ensureUpdated`. **Decide:** last-writer-wins vs. reject when the remote changed since the base (needs a remote `updated_at` / revision check). |
| A locally deleted drawing reappears | `deleteDrawing` enqueues nothing; the next pull re-inserts it as new | `.delete` op mapped to a remote soft delete (`deleted_at`; RLS from `20261101194500_drawings_soft_delete_rls.sql`), plus a local tombstone (`sync_state`) so the pull won't re-insert while the op is pending. **Decide:** whether a remote delete also removes revisions and Storage objects. |
| A permanently invalid outbox payload blocks its project | Decode failure → `.stopDrain` (`processFolder` / `processDrawing` / `processArea`) | Dead-letter after N attempts (`attempt_count`), surfaced in the UI; skipping it silently could reorder dependent ops for the same entity. |
| Backoff never applies | `pushPending` calls `clearOutboxBackoff()` on every drain | Acceptable while drains run only on user or network events (no timer). Revisit if a periodic retry is added. |
| Pull clears documentation-photo links | Remote tombstone → `project_photos.drawing_id` set to NULL (`ON DELETE SET NULL`) | Product decision: protect drawings that have photos the way issues and areas are protected. |

Verified OK: interrupted transfers (`uploading` rows are re-selected by both pending queries); an upload completes only after `objectExists`; a download completes only after a valid PDF is present; downloads use unique staging files; drains are single-flight per coordinator with generation tokens; pull callbacks apply only to the issuing store's own project.

## 5. Tests and actual results

| Test | Runs on | Status |
|---|---|---|
| `python -m unittest discover -s Tests/SQLite -v` (19 tests): real schema translated from Swift, real SQL extracted from Swift; FK lookups use indexes; grouped fetch equals the per-row queries; cascades; scoped deletes; rollback; delta port vs. full writer over 300 random edits; parent handling in all three generations (no parent → FK lock-up reproduced; full re-upsert → metadata/folder revert reproduced; insert-if-missing → neither); no cross-project write; statement count for one edit with 1,003 issues: full = 3,024, delta = 7 | Windows (run) | **19/19 pass** |
| `-BTVerifyWorkspaceDelta` → `WorkspaceDeltaPersistenceVerification` (real Swift: scenarios 1–10 plus 5a "pulled rename/move survives child edit", grouped-fetch order, isolation, integrity) | Mac only | **prepared, not run** |
| `-BTVerifyOutboxDrain` → `OutboxDrainVerification` (real `SyncOutboxPushService` with fake remotes. S1: cross-project isolation. S2: blocked drawing create → dependent area stays deferred, independent folders pushed, no duplicates across drains, skipped rows persist with growing `attempt_count`, after upload confirmation drawing is pushed before area) | Mac only | **prepared, not run** |
| Bracket/interpolation balance of all 32 changed/new Swift files; `git diff --check`; conflict markers; DEBUG wrapping of every `*Verification.swift` | Windows (run) | pass |

Known index gap (accepted): `equipment_events(project_id)` FK lookup is a SCAN (its parent `projects` isn't deleted on a hot path; fixing it needs a new local migration).

## 6. Still requires Xcode

- Compile both configurations. Swift type checking, `Sendable` warnings on `UIImage` crossing actors in `.task`, and the `for … where` / tuple-destructuring forms in `AppStore.swift` have not been compiled.
- Run both new harnesses plus the existing ones (`-BTVerifySQLiteImport`, `-BTVerifyDrawingSQLite`, `-BTVerifyIssueAreaSQLite`, `-BTVerifyFolderSyncCoordinator`, `-BTVerifyFieldOperations`, `-BTVerifySchedule`, …).
- On-device memory and timing. Nothing here is a measured iPhone number.

## 7. First-build smoke checklist

1. `Config/Secrets.xcconfig` from `.example` (URL + anon key); Xcode 26; iOS 17+ simulator.
2. Build **Debug** and **Release** (Release must compile without any `*Verification` symbol).
3. Run with `-BTVerifyWorkspaceDelta`, then with `-BTVerifyOutboxDrain`: exit code 0, stderr `passed`/`true`.
4. Sign in → open a project → create an issue with 2 library photos → edit it 3× → kill and relaunch → values persist.
5. Delete that issue; delete a drawing that has issues and an area; relaunch; nothing else changed.
6. Issue detail: thumbnails appear, preview opens, a missing file shows a placeholder.
7. Generate a report with photos (portrait and landscape): orientation and pagination as before.
8. Create a folder while another project has a pending op: the new folder reaches Supabase (staging only).

## 8. Next sprint

1. Run sections 6 and 7; fix compile errors first.
2. Decide the drawing update/delete sync semantics (section 4) and implement them with the outbox pattern.
3. Outbox dead-letter with UI surface.
4. Product decision on capping stored issue photos at 4096 px (Photos already does); library import currently stores and decodes full resolution on the main actor.
5. Optional: add `equipment_events(project_id)` index in a new local migration; cancel Knowledge indexing and drop `AppDatabase` cache on sign-out.
