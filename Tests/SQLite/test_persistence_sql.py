"""SQLite regression checks for B Technica local persistence (runs on Windows/macOS/Linux).

What is real here:
  * Schema: translated from the Swift migration code (`swift_sources.build_schema`).
  * SQL: every statement is extracted verbatim from the Swift sources at test time.
What is a port (marked `PORT`):
  * The loop/diff logic around those statements (`AppStore.persist`, `SQLiteWorkspaceBaseline`,
    `persistProjectWorkspace[Delta]`). The Swift code itself is covered by the DEBUG harness
    `WorkspaceDeltaPersistenceVerification` (`-BTVerifyWorkspaceDelta`), which needs a Mac.

Run:  python -m unittest discover -s Tests/SQLite -v
"""
from __future__ import annotations

import copy
import random
import sqlite3
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import swift_sources as S  # noqa: E402

DMS = "Persistence/DrawingMetadataStore.swift"
IAS = "Persistence/IssueAreaMetadataStore.swift"
NOW = "2026-01-01T00:00:00.000Z"

# Exact per-issue query that `fetchIssues` ran before the grouped fetch (commit c876605).
PRE_CHANGE_PHOTOS_PER_ISSUE = """
SELECT id, file_name, created_at
FROM issue_photos
WHERE issue_id = ?
ORDER BY created_at ASC
"""


def U() -> str:
    return str(uuid.uuid4()).upper()


def ts(seconds: int) -> str:
    return f"2026-01-01T00:{seconds // 60:02d}:{seconds % 60:02d}.000Z"


class SQL:
    """Statements pulled from the Swift sources (fails loudly if a function changes shape)."""
    fetch_issues = S.swift_sql(IAS, "fetchIssues")
    photos_grouped = S.swift_sql(IAS, "fetchPhotosByIssue")
    fetch_drawings = S.swift_sql(DMS, "fetchDrawings")
    calibrations_grouped = S.swift_sql(DMS, "fetchCalibrationsByDrawing")
    calibrations_per_drawing = S.swift_sql(DMS, "fetchCalibrations")
    upsert_project = S.swift_sql(DMS, "upsertProject")
    upsert_folder = S.swift_sql(DMS, "upsertFolders")
    upsert_drawing = S.swift_sql(DMS, "upsertDrawingsAndCalibrations", 0)
    upsert_calibration = S.swift_sql(DMS, "upsertDrawingsAndCalibrations", 1)
    calibration_ids = S.swift_inline_sql(DMS, "upsertDrawingsAndCalibrations", "SELECT id FROM page_calibrations")
    delete_calibration = S.swift_inline_sql(DMS, "upsertDrawingsAndCalibrations", "DELETE FROM page_calibrations")
    upsert_area = S.swift_sql(IAS, "upsertAreas")
    upsert_issue = S.swift_sql(IAS, "upsertIssuesAndPhotos", 0)
    upsert_photo = S.swift_sql(IAS, "upsertIssuesAndPhotos", 1)
    photo_ids = S.swift_inline_sql(IAS, "upsertIssuesAndPhotos", "SELECT id FROM issue_photos")
    delete_photo = S.swift_inline_sql(IAS, "upsertIssuesAndPhotos", "DELETE FROM issue_photos")
    delta_delete = S.swift_inline_sql(DMS, "persistProjectWorkspaceDelta", "DELETE FROM")
    parent_exists = S.swift_inline_sql(DMS, "insertMissingParentDrawings", "SELECT EXISTS")


def open_db() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:", isolation_level=None)
    conn.execute("PRAGMA foreign_keys = ON")  # AppDatabase.prepareDatabase
    S.build_schema(conn)
    return conn


# ---------------------------------------------------------------------------- PORT
# Mirrors DrawingMetadataStore / IssueAreaMetadataStore control flow around the real SQL.
def project_row(p):
    return (p["id"], p["name"], NOW)


def write_drawing(c, d):
    c.execute(SQL.upsert_drawing, (d["id"], d["project"], d["folder"], d["name"], d["id"] + ".pdf", 2, NOW,
                                   d["rev"], None, None, None))
    keep = {cal["id"] for cal in d["cals"]}
    for cal in d["cals"]:
        c.execute(SQL.upsert_calibration, (cal["id"], d["id"], cal["page"], 0, 0, 1, 0, 1000, "mm", 1000, cal["k"], NOW))
    for (cid,) in c.execute(SQL.calibration_ids, (d["id"],)).fetchall():
        if cid not in keep:
            c.execute(SQL.delete_calibration, (cid,))


def write_issue(c, i, project_id):
    c.execute(SQL.upsert_issue, (i["id"], project_id, i["drawing"], 0, 1.0, 2.0, None, i["number"], i["title"], "",
                                 "open", None, None, NOW))
    keep = {p["id"] for p in i["photos"]}
    for p in i["photos"]:
        c.execute(SQL.upsert_photo, (p["id"], i["id"], p["file"], p["at"]))
    for (pid,) in c.execute(SQL.photo_ids, (i["id"],)).fetchall():
        if pid not in keep:
            c.execute(SQL.delete_photo, (pid,))


def write_area(c, a):
    c.execute(SQL.upsert_area, (a["id"], a["project"], a["drawing"], 0, a["name"], "[]", "#fff", 0.3, 1, NOW, NOW))


def write_folder(c, f):
    c.execute(SQL.upsert_folder, (f["id"], f["project"], None, f["name"], 0, NOW))


def persist_full(c, m):
    """PORT of persistProjectWorkspace (pre-change writer)."""
    pid = m["project"]["id"]
    c.execute("BEGIN IMMEDIATE")
    try:
        c.execute(SQL.upsert_project, project_row(m["project"]))
        for f in m["folders"]: write_folder(c, f)
        for d in m["drawings"]: write_drawing(c, d)
        for a in m["areas"]: write_area(c, a)
        for i in m["issues"]: write_issue(c, i, pid)
        for table, key in (("issues", "issues"), ("areas", "areas"), ("drawings", "drawings"), ("drawing_folders", "folders")):
            keep = {x["id"] for x in m[key]}
            for (rid,) in c.execute(f"SELECT id FROM {table} WHERE project_id = ?", (pid,)).fetchall():
                if rid not in keep:
                    c.execute(f"DELETE FROM {table} WHERE id = ?", (rid,))
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise


def index(items):
    return {x["id"]: x for x in items}  # uniquingKeysWith: last wins


def baseline_of(m):
    return {k: index(copy.deepcopy(m[k])) for k in ("folders", "drawings", "areas", "issues")}


def diff(current, previous):
    seen, changed = set(), []
    for item in current:
        seen.add(item["id"])
        if previous.get(item["id"]) != item:
            changed.append(item)
    return changed, [k for k in previous if k not in seen]


# Parent-drawing handling generations:
#   "none"   – first delta version: children only (FK lock-up after a pull removed the parent)
#   "upsert" – previous sprint: parent fully re-upserted from memory (reverts newer pulled rows)
#   "ensure" – current: parent inserted only if its row is missing (insertMissingParentDrawings)
PARENTS_CURRENT = "ensure"


def delta_of(base, m, parents=PARENTS_CURRENT):
    """PORT of SQLiteWorkspaceBaseline.delta(to:)."""
    d = {}
    d["folders"], d["del_folders"] = diff(m["folders"], base["folders"])
    d["drawings"], d["del_drawings"] = diff(m["drawings"], base["drawings"])
    d["areas"], d["del_areas"] = diff(m["areas"], base["areas"])
    d["issues"], d["del_issues"] = diff(m["issues"], base["issues"])
    d["ensure_parents"] = []
    if parents != "none":
        parent_ids = {i["drawing"] for i in d["issues"]} | {a["drawing"] for a in d["areas"]}
        have = {x["id"] for x in d["drawings"]}
        for drawing in m["drawings"]:
            if drawing["id"] in parent_ids and drawing["id"] not in have and drawing["id"] not in d["del_drawings"]:
                (d["drawings"] if parents == "upsert" else d["ensure_parents"]).append(drawing)
    return d


def persist_delta(c, m, base, parents=PARENTS_CURRENT):
    """PORT of AppStore.persist → persistProjectWorkspaceDelta. Returns the new baseline."""
    d = delta_of(base, m, parents)
    pid = m["project"]["id"]
    c.execute("BEGIN IMMEDIATE")
    try:
        c.execute(SQL.upsert_project, project_row(m["project"]))
        for f in d["folders"]: write_folder(c, f)
        for x in d["drawings"]: write_drawing(c, x)
        for x in d["ensure_parents"]:  # insertMissingParentDrawings
            if not c.execute(SQL.parent_exists, (x["id"],)).fetchone()[0]:
                write_drawing(c, x)
        for a in d["areas"]: write_area(c, a)
        for i in d["issues"]: write_issue(c, i, pid)
        for table, key in (("issues", "del_issues"), ("areas", "del_areas"), ("drawings", "del_drawings"),
                           ("drawing_folders", "del_folders")):
            for rid in d[key]:
                c.execute(SQL.delta_delete.replace("\\(table)", table), (rid, pid))
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise
    return baseline_of(m)


# ---------------------------------------------------------------------------- fixtures
def make_workspace(project_id=None):
    pid = project_id or U()
    folder = {"id": U(), "project": pid, "name": "Plans"}
    d1 = {"id": U(), "project": pid, "folder": folder["id"], "name": "D1", "rev": "A",
          "cals": [{"id": U(), "page": 1, "k": 2.0}, {"id": U(), "page": 0, "k": 1.0}]}
    d2 = {"id": U(), "project": pid, "folder": None, "name": "D2", "rev": "A", "cals": []}
    i1 = {"id": U(), "drawing": d1["id"], "number": 1, "title": "t1",
          "photos": [{"id": U(), "file": "late.jpg", "at": ts(50)}, {"id": U(), "file": "early.jpg", "at": ts(5)}]}
    i2 = {"id": U(), "drawing": d1["id"], "number": 2, "title": "t2", "photos": []}
    i3 = {"id": U(), "drawing": d2["id"], "number": 3, "title": "t3", "photos": [{"id": U(), "file": "d2.jpg", "at": ts(1)}]}
    area = {"id": U(), "project": pid, "drawing": d2["id"], "name": "Zone"}
    return {"project": {"id": pid, "name": "P"}, "folders": [folder], "drawings": [d1, d2], "areas": [area],
            "issues": [i1, i2, i3]}


def dump(c, project_id):
    q = {
        "drawing_folders": "SELECT * FROM drawing_folders WHERE project_id = ? ORDER BY id",
        "drawings": "SELECT * FROM drawings WHERE project_id = ? ORDER BY id",
        "page_calibrations": "SELECT c.* FROM page_calibrations c JOIN drawings d ON d.id = c.drawing_id WHERE d.project_id = ? ORDER BY c.id",
        "areas": "SELECT * FROM areas WHERE project_id = ? ORDER BY id",
        "issues": "SELECT * FROM issues WHERE project_id = ? ORDER BY id",
        "issue_photos": "SELECT p.* FROM issue_photos p JOIN issues i ON i.id = p.issue_id WHERE i.project_id = ? ORDER BY p.id",
    }
    return {k: c.execute(v, (project_id,)).fetchall() for k, v in q.items()}


def count(c, sql, *args):
    return c.execute(sql, args).fetchone()[0]


# ---------------------------------------------------------------------------- tests
class SchemaTests(unittest.TestCase):
    def test_translator_covers_every_registered_migration_in_order(self):
        self.assertEqual([m[0] for m in S.MIGRATIONS], S.registered_migrations())

    def test_schema_applies_cleanly(self):
        c = open_db()
        self.assertEqual(c.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(c.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_every_foreign_key_lookup_uses_an_index(self):
        """For each FK, SQLite's enforcement lookup on the child table (run on every parent
        DELETE/UPDATE and cascade) must be an index SEARCH, not a full SCAN."""
        c = open_db()
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL%'")]
        scans = []
        for table in tables:
            fks = {}
            for row in c.execute(f"PRAGMA foreign_key_list('{table}')"):
                fks.setdefault(row[0], []).append((row[1], row[3]))
            for cols in fks.values():
                child = [col for _, col in sorted(cols)]
                where = " AND ".join(f"{col} = ?" for col in child)
                plan = " | ".join(r[3] for r in c.execute(f"EXPLAIN QUERY PLAN SELECT 1 FROM {table} WHERE {where}", [0] * len(child)))
                if not plan.startswith("SEARCH"):
                    scans.append(f"{table}({', '.join(child)}): {plan}")
        # Accepted: parent is `projects`, which the app never deletes on a hot path.
        accepted = [s for s in scans if s.startswith(("equipment_events(project_id)", "equipment_checkouts(project_id)"))]
        self.assertEqual([s for s in scans if s not in accepted], [], " || ".join(scans))


class GroupedFetchTests(unittest.TestCase):
    def setUp(self):
        self.c = open_db()
        self.a = make_workspace()
        self.b = make_workspace()
        persist_full(self.c, self.a)
        persist_full(self.c, self.b)

    def grouped_photos(self, project_id):
        out = {}
        for pid, issue_id, file_name, created in self.c.execute(SQL.photos_grouped, (project_id,)):
            out.setdefault(issue_id, []).append((pid, file_name, created))
        return out

    def test_grouped_photos_equal_pre_change_per_issue_queries(self):
        pid = self.a["project"]["id"]
        grouped = self.grouped_photos(pid)
        for (issue_id, *_rest) in self.c.execute(SQL.fetch_issues, (pid,)).fetchall():
            per_issue = self.c.execute(PRE_CHANGE_PHOTOS_PER_ISSUE, (issue_id,)).fetchall()
            self.assertEqual(grouped.get(issue_id, []), per_issue)

    def test_grouped_photos_order_empty_and_project_isolation(self):
        grouped = self.grouped_photos(self.a["project"]["id"])
        i1, i2 = self.a["issues"][0]["id"], self.a["issues"][1]["id"]
        self.assertEqual([p[1] for p in grouped[i1]], ["early.jpg", "late.jpg"])
        self.assertNotIn(i2, grouped)  # Swift maps a missing key to []
        b_issue_ids = {i["id"] for i in self.b["issues"]}
        self.assertFalse(b_issue_ids & set(grouped))
        self.assertEqual(self.grouped_photos(U()), {})

    def test_grouped_calibrations_equal_per_drawing_query(self):
        pid = self.a["project"]["id"]
        grouped = {}
        for row in self.c.execute(SQL.calibrations_grouped, (pid,)):
            grouped.setdefault(row[1], []).append((row[0],) + tuple(row[2:]))
        for (drawing_id, *_rest) in self.c.execute(SQL.fetch_drawings, (pid,)).fetchall():
            self.assertEqual(grouped.get(drawing_id, []), self.c.execute(SQL.calibrations_per_drawing, (drawing_id,)).fetchall())
        d1 = self.a["drawings"][0]["id"]
        self.assertEqual([r[1] for r in self.c.execute(SQL.calibrations_per_drawing, (d1,))], [0, 1])

    def test_photo_without_parent_issue_is_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.c.execute(SQL.upsert_photo, (U(), U(), "x.jpg", NOW))

    def test_duplicate_ids_upsert_to_one_row_last_wins(self):
        issue = copy.deepcopy(self.a["issues"][1])
        for title in ("first", "second"):
            issue["title"] = title
            write_issue(self.c, issue, self.a["project"]["id"])
        self.assertEqual(self.c.execute("SELECT COUNT(*), MAX(title) FROM issues WHERE id = ?", (issue["id"],)).fetchone(), (1, "second"))

    def test_query_plans_use_indexes(self):
        def plan(sql, *args):
            return " | ".join(r[3] for r in self.c.execute("EXPLAIN QUERY PLAN " + sql, args))
        self.assertIn("USING INDEX issues_project_id", plan(SQL.photos_grouped, "x"))
        self.assertIn("USING INDEX issue_photos_issue_id", plan(SQL.photos_grouped, "x"))
        self.assertIn("USING INDEX drawings_project_id", plan(SQL.calibrations_grouped, "x"))
        self.assertIn("USING INDEX page_calibrations_drawing_id", plan(SQL.calibrations_grouped, "x"))
        for table in ("issues", "areas", "drawings", "drawing_folders"):
            p = plan(SQL.delta_delete.replace("\\(table)", table), "a", "b")
            self.assertRegex(p, r"SEARCH .* USING (INDEX sqlite_autoindex|INTEGER PRIMARY KEY|PRIMARY KEY)", f"{table}: {p}")


class CascadeTests(unittest.TestCase):
    def test_drawing_delete_cascades_children_and_nulls_photo_links(self):
        c = open_db()
        a = make_workspace()
        persist_full(c, a)
        pid = a["project"]["id"]
        d2 = a["drawings"][1]["id"]
        i3, area = a["issues"][2]["id"], a["areas"][0]["id"]
        c.execute("INSERT INTO project_photos (id, project_id, file_name, taken_at, drawing_id, area_id, issue_id, created_at, updated_at)"
                  " VALUES (?, ?, 'Photos/a.jpg', ?, ?, ?, ?, ?, ?)", (U(), pid, NOW, d2, area, i3, NOW, NOW))
        c.execute("INSERT INTO drawing_page_mappings VALUES (?, ?, ?, ?, 0, ?)", (U(), pid, d2, U(), NOW))
        c.execute(SQL.delta_delete.replace("\\(table)", "drawings"), (d2, pid))
        self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE drawing_id = ?", d2), 0)
        self.assertEqual(count(c, "SELECT COUNT(*) FROM issue_photos WHERE issue_id = ?", i3), 0)
        self.assertEqual(count(c, "SELECT COUNT(*) FROM areas WHERE drawing_id = ?", d2), 0)
        self.assertEqual(count(c, "SELECT COUNT(*) FROM drawing_page_mappings WHERE drawing_id = ?", d2), 0)
        self.assertEqual(c.execute("SELECT drawing_id, area_id, issue_id FROM project_photos").fetchall(), [(None, None, None)])
        self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE project_id = ?", pid), 2)  # D1 untouched
        self.assertEqual(c.execute("PRAGMA foreign_key_check").fetchall(), [])


class DeltaPersistenceTests(unittest.TestCase):
    """PORT-level checks; the Swift equivalents live in WorkspaceDeltaPersistenceVerification."""

    def test_random_edit_sequences_match_full_writer(self):
        rnd = random.Random(20261106)
        full, inc = open_db(), open_db()
        m = make_workspace()
        persist_full(full, m)
        persist_full(inc, m)
        base = baseline_of(m)
        for step in range(300):
            op = rnd.random()
            if op < 0.25:
                m["issues"].append({"id": U(), "drawing": rnd.choice(m["drawings"])["id"], "number": step + 10,
                                    "title": "n", "photos": [{"id": U(), "file": "p.jpg", "at": ts(step % 3600)}] if rnd.random() < .5 else []})
            elif op < 0.50 and m["issues"]:
                i = rnd.choice(m["issues"]); i["title"] = f"e{step}"
                if rnd.random() < .3: i["photos"] = i["photos"][1:]
            elif op < 0.60 and m["issues"]:
                m["issues"].pop(rnd.randrange(len(m["issues"])))
            elif op < 0.70:
                m["drawings"].append({"id": U(), "project": m["project"]["id"], "folder": None, "name": "D", "rev": "A",
                                      "cals": [{"id": U(), "page": 0, "k": 1.0}]})
            elif op < 0.78 and len(m["drawings"]) > 1:
                gone = m["drawings"].pop(rnd.randrange(len(m["drawings"])))  # AppStore.deleteDrawing
                m["issues"] = [i for i in m["issues"] if i["drawing"] != gone["id"]]
                m["areas"] = [a for a in m["areas"] if a["drawing"] != gone["id"]]
            elif op < 0.88:
                m["areas"].append({"id": U(), "project": m["project"]["id"], "drawing": rnd.choice(m["drawings"])["id"], "name": "A"})
            elif m["drawings"]:
                d = rnd.choice(m["drawings"]); d["rev"] = rnd.choice("ABC")
                d["cals"] = [{"id": U(), "page": 0, "k": rnd.random()}]
            persist_full(full, m)
            base = persist_delta(inc, m, base)
            self.assertEqual(dump(full, m["project"]["id"]), dump(inc, m["project"]["id"]), f"step {step}")

    def test_unchanged_save_writes_nothing(self):
        m = make_workspace()
        d = delta_of(baseline_of(m), m)
        self.assertTrue(all(not v for v in d.values()))

    def test_pulled_folder_survives_unrelated_save(self):
        c = open_db()
        m = make_workspace()
        persist_full(c, m)
        base = baseline_of(m)
        pulled = U()
        c.execute("INSERT INTO drawing_folders VALUES (?, ?, NULL, 'Remote', 9, ?)", (pulled, m["project"]["id"], NOW))
        m["issues"][0]["title"] = "edit"
        persist_delta(c, m, base)
        self.assertEqual(count(c, "SELECT COUNT(*) FROM drawing_folders WHERE id = ?", pulled), 1)
        persist_full(c, m)  # the pre-change writer deleted it
        self.assertEqual(count(c, "SELECT COUNT(*) FROM drawing_folders WHERE id = ?", pulled), 0)

    def test_child_save_after_parent_vanished_from_sqlite(self):
        """Pull tombstoned D2 in SQLite while memory kept it; user then edits an issue on D2."""
        for parents, should_fail in (("none", True), ("ensure", False)):
            c = open_db()
            m = make_workspace()
            persist_full(c, m)
            base = baseline_of(m)
            d2 = m["drawings"][1]["id"]
            c.execute("DELETE FROM drawings WHERE id = ?", (d2,))  # cascades i3 + area
            del base["issues"][m["issues"][2]["id"]]
            m["issues"] = m["issues"][:2]
            del base["areas"][m["areas"][0]["id"]]
            m["areas"] = []
            m["issues"].append({"id": U(), "drawing": d2, "number": 9, "title": "new pin", "photos": []})
            if should_fail:
                with self.assertRaises(sqlite3.IntegrityError):
                    persist_delta(c, m, base, parents="none")
                # baseline was not advanced, so every later save retries and fails again
                with self.assertRaises(sqlite3.IntegrityError):
                    persist_delta(c, m, base, parents="none")
            else:
                persist_delta(c, m, base, parents="ensure")
                self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE drawing_id = ?", d2), 1)
                self.assertEqual(count(c, "SELECT COUNT(*) FROM page_calibrations WHERE drawing_id = ?", d2), 0)
                self.assertEqual(c.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_child_edit_keeps_newer_pulled_parent_metadata(self):
        """Pull renamed D1 and moved it to another folder; memory is stale; user edits an issue on D1."""
        outcomes = {}
        for parents in ("upsert", "ensure"):
            c = open_db()
            m = make_workspace()
            persist_full(c, m)
            base = baseline_of(m)
            d1 = m["drawings"][0]["id"]
            remote_folder = U()
            c.execute("INSERT INTO drawing_folders VALUES (?, ?, NULL, 'Remote', 1, ?)", (remote_folder, m["project"]["id"], NOW))
            c.execute("UPDATE drawings SET name = 'Remote name', revision = 'R2', folder_id = ? WHERE id = ?", (remote_folder, d1))
            m["issues"][0]["title"] = "edit on remotely renamed drawing"   # issue i1 lives on D1
            persist_delta(c, m, base, parents=parents)
            row = c.execute("SELECT name, revision, folder_id FROM drawings WHERE id = ?", (d1,)).fetchone()
            outcomes[parents] = (row, remote_folder)
            self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE title = 'edit on remotely renamed drawing'"), 1)
        ensure_row, ensure_folder = outcomes["ensure"]
        upsert_row, upsert_folder = outcomes["upsert"]
        self.assertEqual(ensure_row, ("Remote name", "R2", ensure_folder))
        # The previous sprint's full parent re-upsert reproduces the defect being fixed:
        self.assertNotEqual(upsert_row[0], "Remote name")
        self.assertNotEqual(upsert_row[2], upsert_folder)

    def test_ensure_parent_never_writes_into_another_project(self):
        c = open_db()
        a, b = make_workspace(), make_workspace()
        persist_full(c, a)
        persist_full(c, b)
        before = dump(c, b["project"]["id"])
        base = baseline_of(a)
        stale_copy = copy.deepcopy(b["drawings"][0])        # project A memory holding B's drawing id
        stale_copy.update(project=a["project"]["id"], name="hijack attempt", folder=None)
        a["drawings"].append(stale_copy)
        base["drawings"][stale_copy["id"]] = copy.deepcopy(stale_copy)   # unchanged → ensure-only path
        a["issues"].append({"id": U(), "drawing": stale_copy["id"], "number": 50, "title": "x", "photos": []})
        persist_delta(c, a, base)
        self.assertEqual(dump(c, b["project"]["id"])["drawings"], before["drawings"])

    def test_failed_transaction_rolls_back_every_statement(self):
        c = open_db()
        m = make_workspace()
        persist_full(c, m)
        base = baseline_of(m)
        m["issues"][0]["title"] = "inside failed save"
        m["issues"].append({"id": U(), "drawing": U(), "number": 99, "title": "orphan", "photos": []})
        with self.assertRaises(sqlite3.IntegrityError):
            persist_delta(c, m, base)
        self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE title = 'inside failed save'"), 0)
        m["issues"].pop()
        persist_delta(c, m, base)  # baseline unchanged after the failure → change is retried
        self.assertEqual(count(c, "SELECT COUNT(*) FROM issues WHERE title = 'inside failed save'"), 1)

    def test_deletes_are_scoped_to_the_saving_project(self):
        c = open_db()
        a, b = make_workspace(), make_workspace()
        persist_full(c, a)
        persist_full(c, b)
        before = dump(c, b["project"]["id"])
        for table, rows in (("issues", b["issues"]), ("areas", b["areas"]), ("drawings", b["drawings"]), ("drawing_folders", b["folders"])):
            for r in rows:
                c.execute(SQL.delta_delete.replace("\\(table)", table), (r["id"], a["project"]["id"]))
        self.assertEqual(dump(c, b["project"]["id"]), before)

    def test_statement_counts_full_vs_delta(self):
        """Deterministic cost evidence (statements, not wall time) for one edited issue."""
        c = open_db()
        m = make_workspace()
        for n in range(1000):
            m["issues"].append({"id": U(), "drawing": m["drawings"][0]["id"], "number": 100 + n, "title": "x",
                                "photos": [{"id": U(), "file": "p.jpg", "at": NOW}]})
        persist_full(c, m)
        base = baseline_of(m)
        m["issues"][500]["title"] = "edited"
        statements = []
        c.set_trace_callback(statements.append)
        persist_full(c, m)
        full_count = len(statements)
        statements.clear()
        m["issues"][500]["title"] = "edited again"
        persist_delta(c, m, base)
        c.set_trace_callback(None)
        delta_count = len(statements)
        print(f"\n    statements for one issue edit, 1003 issues: full={full_count} delta={delta_count}")
        self.assertLess(delta_count, 20)
        self.assertGreater(full_count, 3000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
