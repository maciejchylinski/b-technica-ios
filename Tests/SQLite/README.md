# SQLite regression checks (no Xcode needed)

```bash
python -m unittest discover -s Tests/SQLite -v
```

Python 3.10+ standard library only, synthetic data in `:memory:` databases.

- `swift_sources.py` builds the local schema by translating the GRDB migration code in
  `BTechnica/Persistence/AppDatabase+*.swift` (in `AppDatabase.migrator` order), and extracts
  SQL literals from Swift functions by name. If the Swift code uses a construct the translator
  does not know, or it parses fewer `db.create/alter/execute` calls than the function contains,
  it raises an error and the tests fail.
- `test_persistence_sql.py` covers schema integrity, FK-lookup index use (`EXPLAIN QUERY PLAN`),
  grouped photo and calibration fetches against the pre-change per-row queries, cascades,
  project-scoped deletes, transaction rollback, and the incremental (delta) workspace save.

The delta-save tests run a **Python port** of `AppStore.persist` / `SQLiteWorkspaceBaseline`
around the real SQL. They do not execute Swift. The Swift implementation is covered by the
DEBUG harnesses `-BTVerifyWorkspaceDelta` and `-BTVerifyOutboxDrain` (see
`docs/INTEGRATION_ENGINEERING_HANDOFF.md`).
