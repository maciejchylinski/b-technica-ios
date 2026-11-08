"""Verification of the DEBUG demo fixtures (runs on Windows/macOS/Linux, no Xcode).

    python -m unittest discover -s Tests/DemoData -v

What is checked, and how real it is:
  * Files: every fixture PDF/PNG is parsed structurally here (xref offsets, page count,
    MediaBox, Flate streams, PNG CRCs); document text is decoded through each PDF's own
    ToUnicode CMap. PDFKit itself is exercised only by the Swift harness
    `-BTVerifyDemoSeed` (needs a Mac).
  * Data: the manifest is seeded into the real local schema (translated from the Swift
    migrations) using INSERT/UPDATE statements extracted verbatim from the Swift
    persistence code, so CHECK / FK / UNIQUE constraints are real. The control flow around
    those statements (which call in which order) is a port of DemoDataSeeder.
  * Safety: static source checks that demo code is DEBUG-only, uses no outbox/sync APIs,
    and that every Supabase guard in the sync layer has the local-only check.
"""
from __future__ import annotations

import json
import re
import sqlite3
import struct
import sys
import unittest
import uuid
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Tests" / "SQLite"))
sys.path.insert(0, str(REPO / "Tools" / "DemoFixtures"))
import swift_sources as S  # noqa: E402

FIXTURES = REPO / "BTechnica" / "DemoFixtures"
MANIFEST = json.loads((FIXTURES / "demo-fixture-manifest.json").read_text(encoding="utf-8"))
PROJECTS = MANIFEST["projects"]
TODAY = datetime(2026, 11, 7, tzinfo=timezone.utc)  # fixed reference day for date strings


def iso(day: int, minute: int = 9 * 60) -> str:
    return (TODAY + timedelta(days=day, minutes=minute)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def iso_day(day: int) -> str:
    return (TODAY + timedelta(days=day)).strftime("%Y-%m-%d")


def walk_ids(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "id" and isinstance(v, str):
                out.append(v)
            walk_ids(v, out)
    elif isinstance(node, list):
        for v in node:
            walk_ids(v, out)


def point_in_polygon(x, y, poly):
    inside = False
    for i in range(len(poly)):
        (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % len(poly)]
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            inside = not inside
    return inside


# ---------------------------------------------------------------------------- PDF parsing
class Pdf:
    def __init__(self, data: bytes):
        self.data = data
        m = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", data)
        assert m, "missing startxref/%%EOF"
        xref_at = int(m.group(1))
        assert data[xref_at:xref_at + 4] == b"xref", "startxref does not point to xref"
        header = re.match(rb"xref\s+0 (\d+)\s+", data[xref_at:])
        assert header, "bad xref header"
        count = int(header.group(1))
        pos = xref_at + header.end()
        self.objects = {}
        for n in range(count):
            entry = data[pos + n * 20: pos + n * 20 + 20]
            offset, _gen, kind = int(entry[:10]), int(entry[11:16]), entry[17:18]
            if kind == b"n":
                assert data[offset:].startswith(f"{n} 0 obj".encode()), f"xref offset of object {n} is wrong"
                end = data.index(b"endobj", offset)
                self.objects[n] = data[offset:end]
        trailer = data[data.index(b"trailer", xref_at):]
        assert b"/Root" in trailer and f"/Size {count}".encode() in trailer, "bad trailer"

    def stream(self, body: bytes) -> bytes:
        start = body.index(b"stream\n") + 7
        end = body.rindex(b"endstream")
        raw = body[start:end].rstrip(b"\n")
        return zlib.decompress(raw) if b"/FlateDecode" in body[:start] else raw

    def pages(self):
        return [b for b in self.objects.values() if re.search(rb"/Type /Page\b(?!s)", b)]

    def cmap(self) -> dict[int, str]:
        out = {}
        for body in self.objects.values():
            if b"beginbfchar" in body:
                for code, uni in re.findall(rb"<([0-9A-F]{2})> <([0-9A-F]{4})>", self.stream(body)):
                    out[int(code, 16)] = chr(int(uni, 16))
        return out

    def text(self) -> str:
        cmap = self.cmap()
        chunks = []
        for page in self.pages():
            content_ref = int(re.search(rb"/Contents (\d+) 0 R", page).group(1))
            content = self.stream(self.objects[content_ref])
            for lit in re.findall(rb"\(((?:\\.|[^\\)])*)\) Tj", content, re.S):
                raw = bytearray()
                i = 0
                while i < len(lit):
                    if lit[i] == 0x5C:
                        nxt = lit[i + 1:i + 4]
                        if nxt[:1].isdigit():
                            raw.append(int(nxt, 8))
                            i += 4
                            continue
                        raw.append(lit[i + 1])
                        i += 2
                        continue
                    raw.append(lit[i])
                    i += 1
                chunks.append("".join(cmap.get(b, "�") for b in raw))
        return " ".join(chunks)


def png_info(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, chunks, idat = 8, [], b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        assert zlib.crc32(tag + body) & 0xFFFFFFFF == crc, f"bad CRC in {tag}"
        chunks.append(tag)
        if tag == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", body[:10])
        if tag == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    assert chunks[0] == b"IHDR" and chunks[-1] == b"IEND"
    assert len(raw) == h * (1 + w * 3), "decompressed size does not match dimensions"
    assert all(raw[r * (1 + w * 3)] <= 4 for r in range(h)), "invalid filter byte"
    return w, h, depth, color


# ---------------------------------------------------------------------------- tests
class FixtureFilesTests(unittest.TestCase):
    def test_fixtures_match_generator_output(self):
        import generate_demo_fixtures as G
        self.assertEqual(G.main(["--check"]), 0, "run Tools/DemoFixtures/generate_demo_fixtures.py")

    def test_every_resource_exists_and_nothing_is_orphaned(self):
        referenced = set()
        for p in PROJECTS:
            referenced |= {d["resource"] for d in p["drawings"]}
            referenced |= {d["resource"] for d in p["documents"]}
            referenced |= {ph["resource"] for ph in p["photos"]}
            referenced |= {ph["resource"] for i in p["issues"] for ph in i["photos"]}
        on_disk = {f.name for f in FIXTURES.glob("demo-fixture-*")} - {"demo-fixture-manifest.json"}
        self.assertEqual(referenced, on_disk)
        # Bundle resources are flattened: names must be unique app-wide.
        clashes = [f for f in (REPO / "BTechnica").rglob("demo-fixture-*") if f.parent != FIXTURES]
        self.assertEqual(clashes, [])

    def test_drawing_pdfs_are_structurally_valid(self):
        for p in PROJECTS:
            for d in p["drawings"]:
                pdf = Pdf((FIXTURES / d["resource"]).read_bytes())
                pages = pdf.pages()
                self.assertEqual(len(pages), d["pageCount"], d["name"])
                for page in pages:
                    box = re.search(rb"/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]", page)
                    self.assertAlmostEqual(float(box.group(1)), d["pageWidth"], places=1)
                    self.assertAlmostEqual(float(box.group(2)), d["pageHeight"], places=1)
                self.assertIn(d["number"], pdf.text(), f"{d['name']}: drawing number not in the title block")

    def test_documents_have_searchable_polish_text(self):
        expected = {
            "st04": ["hydroizolac", "15 cm", "próg"], "st02": ["C30/37", "otulin"], "n14": ["kablow", "EI60"],
            "lk03": ["IP44", "tynk"], "bhp02": ["rusztowani", "szelek"], "pe01": ["rozdzielnic", "IP44"],
            "pfu": ["serwerowni", "EI30"],
        }
        for p in PROJECTS:
            for doc in p["documents"]:
                text = Pdf((FIXTURES / doc["resource"]).read_bytes()).text()
                self.assertNotIn("�", text, doc["name"])
                self.assertGreater(len(text), 800, doc["name"])
                key = doc["resource"].split("-doc-")[1].split("_")[0]
                for word in expected[key]:
                    self.assertIn(word.lower(), text.lower(), f"{doc['name']}: '{word}' not extractable")
        st04 = next(d for d in PROJECTS[0]["documents"] if d["name"].startswith("ST-04"))
        self.assertGreaterEqual(len(Pdf((FIXTURES / st04["resource"]).read_bytes()).pages()), 2,
                                "one multi-page document demonstrates page-level search hits")

    def test_photos_are_valid_png(self):
        for p in PROJECTS:
            for res in [ph["resource"] for ph in p["photos"]] + [x["resource"] for i in p["issues"] for x in i["photos"]]:
                w, h, depth, color = png_info((FIXTURES / res).read_bytes())
                self.assertEqual((w, h, depth, color), (800, 600, 8, 2), res)

    def test_fixture_storage_is_small(self):
        total = sum(f.stat().st_size for f in FIXTURES.glob("demo-fixture-*"))
        self.assertLess(total, 2 * 1024 * 1024, f"{total} bytes")


class ManifestIntegrityTests(unittest.TestCase):
    def test_ids_are_unique_uuids(self):
        ids = []
        walk_ids(MANIFEST, ids)
        for value in ids:
            uuid.UUID(value)
        self.assertEqual(len(ids), len(set(ids)), "duplicate ids in manifest")

    def test_demo_user_id_matches_swift(self):
        swift = (REPO / "BTechnica" / "Demo" / "DemoMode.swift").read_text(encoding="utf-8")
        literal = re.search(r'static let userId = UUID\(uuidString: "([0-9A-F-]+)"\)', swift).group(1)
        self.assertEqual(literal, MANIFEST["demoUserId"])

    def test_record_counts(self):
        a, b = PROJECTS
        self.assertEqual([p["name"] for p in PROJECTS], ["Osiedle Zielone Tarasy — Etap I", "Modernizacja Biurowca — Centrum"])
        self.assertTrue(8 <= len(a["drawings"]) <= 12)
        self.assertEqual(len(a["issues"]), 35)
        self.assertEqual(len(a["areas"]), 8)
        photos = sum(len(p["photos"]) + sum(len(i["photos"]) for i in p["issues"]) for p in PROJECTS)
        self.assertTrue(28 <= photos <= 34, photos)
        self.assertGreaterEqual(len(a["schedule"]["tasks"]), 20)
        self.assertGreaterEqual(len(MANIFEST["people"]), 12)
        self.assertEqual(len(MANIFEST["equipment"]), 10)
        self.assertGreaterEqual(sum(len(p["documents"]) for p in PROJECTS), 6)
        statuses = {i["status"] for i in a["issues"]}
        self.assertEqual(statuses, {"open", "inProgress", "resolved", "closed"})
        self.assertGreaterEqual(len({i["contractor"] for i in a["issues"]}), 6)
        self.assertGreaterEqual(len({i["drawingId"] for i in a["issues"]}), 10)
        self.assertGreater(len({i["createdDayOffset"] for i in a["issues"]}), 20, "issues spread over time")

    def test_relationships_inside_each_project(self):
        contractors = {c["name"] for c in MANIFEST["contractors"]}
        disciplines = {d["name"] for d in MANIFEST["disciplines"]}
        companies = {c["id"]: c for c in MANIFEST["companies"]}
        people = {p["id"]: p for p in MANIFEST["people"]}
        all_issue_ids = {}
        for p in PROJECTS:
            folders = {f["id"]: f for f in p["drawingFolders"]}
            for f in p["drawingFolders"]:
                seen, cur = set(), f
                while cur["parentId"]:
                    self.assertNotIn(cur["id"], seen, "folder cycle")
                    seen.add(cur["id"])
                    cur = folders[cur["parentId"]]
            drawings = {d["id"]: d for d in p["drawings"]}
            for d in p["drawings"]:
                self.assertIn(d["folderId"], folders)
                for c in d["calibrations"]:
                    self.assertLess(c["pageIndex"], d["pageCount"])
                    self.assertGreater(abs(c["bx"] - c["ax"]) + abs(c["by"] - c["ay"]), 100)
            areas = {a["id"]: a for a in p["areas"]}
            for a in p["areas"]:
                d = drawings[a["drawingId"]]
                self.assertLess(a["pageIndex"], d["pageCount"])
                self.assertGreaterEqual(len(a["vertices"]), 3)
                for x, y in a["vertices"]:
                    self.assertTrue(0 < x < d["pageWidth"] and 0 < y < d["pageHeight"], a["name"])
                self.assertRegex(a["color"], r"^#[0-9A-F]{6}$")
            numbers = [i["number"] for i in p["issues"]]
            self.assertEqual(numbers, list(range(1, len(numbers) + 1)))
            for i in p["issues"]:
                d = drawings[i["drawingId"]]
                self.assertLess(i["pageIndex"], d["pageCount"])
                # Inside the page and outside the title block (bottom-right 420 x 180 pt).
                self.assertTrue(20 < i["x"] < d["pageWidth"] - 20 and 20 < i["y"] < d["pageHeight"] - 20, i["title"])
                self.assertFalse(i["x"] > d["pageWidth"] - 440 and i["y"] < 200, f"{i['title']}: under title block")
                if i["areaId"]:
                    a = areas[i["areaId"]]
                    self.assertEqual((a["drawingId"], a["pageIndex"]), (i["drawingId"], i["pageIndex"]))
                    self.assertTrue(point_in_polygon(i["x"], i["y"], a["vertices"]), f"{i['title']} not in {a['name']}")
                self.assertIn(i["contractor"], contractors)
                self.assertIn(i["contractor"], {c["name"] for c in companies.values()}, "contractor has a contact card")
                self.assertIn(i["discipline"], disciplines)
                all_issue_ids[i["id"]] = p["id"]
            albums = {a["id"] for a in p["photoAlbums"]}
            for ph in p["photos"]:
                self.assertIn(ph["albumId"], albums)
                if ph["drawingId"]:
                    self.assertIn(ph["drawingId"], drawings)
                if ph["areaId"]:
                    self.assertEqual(areas[ph["areaId"]]["drawingId"], ph["drawingId"], "photo area on another drawing")
                if ph["issueId"]:
                    self.assertEqual(all_issue_ids[ph["issueId"]], p["id"], "photo linked to another project's issue")
            link_ids = {}
            for link in p["contactLinks"]:
                pool = companies if link["kind"] == "company" else people
                self.assertIn(link["contactId"], pool)
                link_ids[link["id"]] = link
            self.assertEqual(len({(l["kind"], l["contactId"]) for l in p["contactLinks"]}), len(p["contactLinks"]))
            sched = p["schedule"]
            phases = {ph["id"] for ph in sched["phases"]}
            tasks = {t["id"]: t for t in sched["tasks"]}
            for t in sched["tasks"]:
                self.assertIn(t["phaseId"], phases)
                self.assertGreaterEqual(t["finishOffset"], t["startOffset"])
                if t["kind"] == "milestone":
                    self.assertEqual(t["startOffset"], t["finishOffset"])
                if t["status"] == "completed":
                    self.assertEqual(t["progress"], 100)
                link = link_ids[t["responsibleLinkId"]]
                self.assertEqual(companies[link["contactId"]]["name"], t["responsibleName"])
            for dep in sched["dependencies"]:
                pred, succ = tasks[dep["predecessorId"]], tasks[dep["successorId"]]
                earliest = pred["finishOffset"] + (0 if pred["kind"] == "milestone" else 1)
                self.assertGreaterEqual(succ["startOffset"], earliest, f"{succ['title']} starts too early")
            for doc in p["documents"]:
                self.assertTrue(doc["folderId"] is None or doc["folderId"] in {f["id"] for f in p["documentFolders"]})
            today_tasks = [t for t in sched["tasks"] if t["startOffset"] <= 0 <= t["finishOffset"]]
            self.assertTrue(today_tasks, "schedule must have work in progress today")

    def test_projects_are_isolated(self):
        a, b = PROJECTS
        for key in ("drawings", "issues", "areas", "photos", "drawingFolders"):
            self.assertFalse({x["id"] for x in a[key]} & {x["id"] for x in b[key]}, key)
        project_ids = {p["id"] for p in PROJECTS}
        for e in MANIFEST["equipment"]:
            for action in e["actions"]:
                if action["kind"] == "issue":
                    self.assertIn(action["projectId"], project_ids)

    def test_contact_details_are_obviously_fictional(self):
        for c in MANIFEST["companies"] + MANIFEST["people"]:
            self.assertRegex(c["phone"], r"^\+48 000 000 \d{3}$")
            self.assertTrue(c["email"].endswith(".demo.example"), c["email"])
        for c in MANIFEST["companies"]:
            self.assertTrue(c["website"].endswith(".demo.example"))


# ---------------------------------------------------------------------------- real schema seeding
P = "Persistence/"


class SQL:
    contractor = S.swift_sql(P + "UserSharedMetadataStore.swift", "persistUserShared", 0)
    discipline = S.swift_sql(P + "UserSharedMetadataStore.swift", "persistUserShared", 1)
    company = S.swift_sql(P + "ContactsMetadataStore.swift", "upsertContactCompany")
    person = S.swift_sql(P + "ContactsMetadataStore.swift", "persistContactPerson")
    link = S.swift_sql(P + "ContactsMetadataStore.swift", "upsertProjectContactLink")
    project = S.swift_sql(P + "DrawingMetadataStore.swift", "upsertProject")
    folder = S.swift_sql(P + "DrawingMetadataStore.swift", "upsertFolders")
    drawing = S.swift_sql(P + "DrawingMetadataStore.swift", "upsertDrawingsAndCalibrations", 0)
    calibration = S.swift_sql(P + "DrawingMetadataStore.swift", "upsertDrawingsAndCalibrations", 1)
    area = S.swift_sql(P + "IssueAreaMetadataStore.swift", "upsertAreas")
    issue = S.swift_sql(P + "IssueAreaMetadataStore.swift", "upsertIssuesAndPhotos", 0)
    issue_photo = S.swift_sql(P + "IssueAreaMetadataStore.swift", "upsertIssuesAndPhotos", 1)
    album = S.swift_sql(P + "PhotoDocumentationMetadataStore.swift", "persistPhotoAlbum")
    photo = S.swift_sql(P + "PhotoDocumentationMetadataStore.swift", "persistProjectPhotos")
    schedule = S.swift_sql(P + "ScheduleMetadataStore.swift", "createSchedule")
    phase = S.swift_sql(P + "ScheduleMetadataStore.swift", "savePhase")
    task = S.swift_sql(P + "ScheduleMetadataStore.swift", "upsertTask")
    dependency = S.swift_sql(P + "ScheduleMetadataStore.swift", "insertDependency")
    doc_folder = S.swift_sql(P + "KnowledgeMetadataStore.swift", "insertDocumentFolder")
    document = S.swift_sql(P + "KnowledgeMetadataStore.swift", "insertProjectDocument")
    note = S.swift_sql(P + "KnowledgeMetadataStore.swift", "upsertProjectNote")
    equipment = S.swift_sql(P + "EquipmentMetadataStore.swift", "createEquipment")
    event = S.swift_sql(P + "EquipmentMetadataStore.swift", "insertEquipmentEvent")
    checkout = S.swift_sql(P + "EquipmentMetadataStore.swift", "issueEquipment", 0)
    item_issued = S.swift_sql(P + "EquipmentMetadataStore.swift", "issueEquipment", 1)
    close = S.swift_sql(P + "EquipmentMetadataStore.swift", "close")
    resting = S.swift_sql(P + "EquipmentMetadataStore.swift", "setResting")


def seed_into_real_schema():
    """PORT of DemoDataSeeder's call order, executing the real Swift SQL statements."""
    c = sqlite3.connect(":memory:", isolation_level=None)
    c.execute("PRAGMA foreign_keys = ON")
    S.build_schema(c)
    owner = MANIFEST["demoUserId"]
    created = iso(-330)
    for x in MANIFEST["contractors"]:
        c.execute(SQL.contractor, (x["id"], owner, x["name"], x["notes"], created))
    for x in MANIFEST["disciplines"]:
        c.execute(SQL.discipline, (x["id"], owner, x["name"], created))
    for x in MANIFEST["companies"]:
        c.execute(SQL.company, (x["id"], owner, x["name"], x["trade"], x["taxId"], x["phone"], x["email"],
                                x["website"], x["address"], x["notes"], True, created, created))
    for x in MANIFEST["people"]:
        c.execute(SQL.person, (x["id"], owner, x["companyId"], x["firstName"], x["lastName"], x["jobTitle"],
                               x["phone"], x["email"], x["notes"], True, created, created))
    for p in PROJECTS:
        pid = p["id"]
        pc = iso(p["createdDayOffset"])
        c.execute(SQL.project, (pid, p["name"], pc))
        for link in p["contactLinks"]:
            comp = link["contactId"] if link["kind"] == "company" else None
            pers = link["contactId"] if link["kind"] == "person" else None
            c.execute(SQL.link, (link["id"], pid, comp, pers, link["role"], pc, pc))
        for f in p["drawingFolders"]:
            c.execute(SQL.folder, (f["id"], pid, f["parentId"], f["name"], f["sortOrder"], pc))
        for d in p["drawings"]:
            c.execute(SQL.drawing, (d["id"], pid, d["folderId"], d["name"], f"{d['id']}.pdf", d["pageCount"], pc,
                                    d["revision"], d["discipline"], d["location"], d["drawingDate"]))
            for cal in d["calibrations"]:
                dist = ((cal["bx"] - cal["ax"]) ** 2 + (cal["by"] - cal["ay"]) ** 2) ** 0.5
                mm = cal["enteredValue"] * 1000
                c.execute(SQL.calibration, (cal["id"], d["id"], cal["pageIndex"], cal["ax"], cal["ay"], cal["bx"],
                                            cal["by"], mm, cal["unit"], cal["enteredValue"], mm / dist, pc))
        for a in p["areas"]:
            verts = json.dumps([{"x": x, "y": y} for x, y in a["vertices"]])
            c.execute(SQL.area, (a["id"], pid, a["drawingId"], a["pageIndex"], a["name"], verts, a["color"],
                                 a["opacity"], True, pc, pc))
        for i in p["issues"]:
            c.execute(SQL.issue, (i["id"], pid, i["drawingId"], i["pageIndex"], i["x"], i["y"], i["areaId"],
                                  i["number"], i["title"], i["details"], i["status"], i["discipline"], i["contractor"],
                                  iso(i["createdDayOffset"], i["createdMinute"])))
            for ph in i["photos"]:
                c.execute(SQL.issue_photo, (ph["id"], i["id"], f"{ph['id']}.jpg", iso(ph["dayOffset"], ph["minute"])))
        for al in p["photoAlbums"]:
            c.execute(SQL.album, (al["id"], pid, al["name"], al["sortOrder"], pc, pc))
        for ph in p["photos"]:
            taken = iso(ph["takenDayOffset"], ph["takenMinute"])
            c.execute(SQL.photo, (ph["id"], pid, ph["albumId"], f"Photos/{ph['id']}.jpg",
                                  f"Photos/Thumbnails/{ph['id']}.jpg", ph["title"], ph["description"], taken,
                                  ph["drawingId"], ph["pageIndex"] if ph["drawingId"] else None, ph["areaId"],
                                  ph["issueId"], 800, 600, 50_000, "local_only", taken, taken))
        s = p["schedule"]
        c.execute(SQL.schedule, (s["id"], pid, s["name"], s["details"], pc, pc))
        for ph in s["phases"]:
            c.execute(SQL.phase, (ph["id"], pid, s["id"], ph["name"], ph["color"], ph["sortOrder"], pc, pc))
        for t in s["tasks"]:
            c.execute(SQL.task, (t["id"], pid, s["id"], t["phaseId"], t["kind"], t["title"], t["details"],
                                 iso_day(t["startOffset"]), iso_day(t["finishOffset"]), t["progress"], t["status"],
                                 t["responsibleName"], t["responsibleLinkId"], t["notes"], t["sortOrder"], pc, pc))
        for dep in s["dependencies"]:
            c.execute(SQL.dependency, (dep["id"], pid, s["id"], dep["predecessorId"], dep["successorId"],
                                       "finish_to_start", pc, pc))
        for f in p["documentFolders"]:
            c.execute(SQL.doc_folder, (f["id"], pid, f["parentId"], f["name"], f["sortOrder"], pc, pc))
        for doc in p["documents"]:
            size = (FIXTURES / doc["resource"]).stat().st_size
            pages = len(Pdf((FIXTURES / doc["resource"]).read_bytes()).pages())
            c.execute(SQL.document, (doc["id"], pid, doc["folderId"], doc["name"], doc["category"], doc["description"],
                                     doc["originalFileName"], f"ProjectDocuments/{doc['id']}.pdf", size, pages,
                                     "0" * 64, doc["revision"], doc["revisionDate"],
                                     iso(doc["uploadedDayOffset"]), iso(doc["uploadedDayOffset"]), "pending", None, 0))
        for n in p["notes"]:
            at = iso(n["createdDayOffset"], 16 * 60)
            c.execute(SQL.note, (n["id"], pid, n["title"], n["body"], n["category"], at, at))
    # Equipment through the same state transitions as AppDatabase.issueEquipment / returnEquipment.
    for e in MANIFEST["equipment"]:
        made = iso(e["createdDayOffset"])
        c.execute(SQL.equipment, (e["id"], owner, e["name"], e["category"], e["identifier"], e["serialNumber"],
                                  e["notes"], made))
        c.execute(SQL.event, (str(uuid.uuid4()), e["id"], made, "created", None, None, e["notes"], None, None))
        active = None
        for act in e["actions"]:
            when = iso(act["dayOffset"], 8 * 60 + 30)
            status = c.execute("SELECT status FROM equipment_items WHERE id = ?", (e["id"],)).fetchone()[0]
            if act["kind"] == "issue":
                assert status in ("available", "returned") and active is None, f"{e['name']}: cannot issue"
                kind = act["recipientKind"]
                if kind == "text":
                    name = act["recipientName"]
                else:
                    table = "contact_people" if kind == "person" else "contact_companies"
                    column = "person_id" if kind == "person" else "company_id"
                    row = c.execute(f"SELECT t.* FROM {table} t JOIN project_contacts pc ON pc.{column} = t.id "
                                    f"AND pc.project_id = ? WHERE t.id = ?", (act["projectId"], act["recipientId"])).fetchone()
                    assert row, f"{e['name']}: recipient is not a contact of the project"
                    name = " ".join(filter(None, [row[3], row[4]])) if kind == "person" else row[2]
                active = str(uuid.uuid4())
                c.execute(SQL.checkout, (active, e["id"], act["projectId"], kind,
                                         act.get("recipientId") if kind == "person" else None,
                                         act.get("recipientId") if kind == "company" else None,
                                         name, act["location"], act["notes"], when, when, when))
                c.execute(SQL.event, (str(uuid.uuid4()), e["id"], when, "issued", name, act["location"], act["notes"],
                                      active, act["projectId"]))
                c.execute(SQL.item_issued, (name, act["location"], when, when, e["id"]))
            else:
                assert status == "issued" and active, f"{e['name']}: cannot return"
                outcome = "damaged" if act["condition"] == "damaged" else "returned"
                c.execute(SQL.close, (when, outcome, act["notes"], when, active))
                assert c.execute("SELECT changes()").fetchone()[0] == 1
                c.execute(SQL.event, (str(uuid.uuid4()), e["id"], when, "returned", None, None, act["notes"], active, None))
                c.execute(SQL.resting, ("damaged" if outcome == "damaged" else "available", when, when, e["id"]))
                active = None
    return c


class RealSchemaSeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = seed_into_real_schema()

    def count(self, sql, *args):
        return self.db.execute(sql, args).fetchone()[0]

    def test_constraints_hold(self):
        self.assertEqual(self.db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(self.db.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_row_counts_match_manifest(self):
        self.assertEqual(self.count("SELECT COUNT(*) FROM projects"), 2)
        self.assertEqual(self.count("SELECT COUNT(*) FROM issues"), sum(len(p["issues"]) for p in PROJECTS))
        self.assertEqual(self.count("SELECT COUNT(*) FROM schedule_tasks"),
                         sum(len(p["schedule"]["tasks"]) for p in PROJECTS))
        self.assertEqual(self.count("SELECT COUNT(*) FROM project_photos"), sum(len(p["photos"]) for p in PROJECTS))
        self.assertEqual(self.count("SELECT COUNT(*) FROM sync_outbox"), 0)
        self.assertEqual(self.count("SELECT COUNT(*) FROM file_transfers"), 0)

    def test_equipment_end_state_is_mixed(self):
        statuses = dict(self.db.execute("SELECT status, COUNT(*) FROM equipment_items GROUP BY status").fetchall())
        self.assertEqual(statuses, {"available": 4, "issued": 5, "damaged": 1})
        self.assertEqual(self.count("SELECT COUNT(*) FROM equipment_checkouts WHERE returned_at IS NULL"), 5)
        self.assertGreaterEqual(self.count("SELECT COUNT(DISTINCT project_id) FROM equipment_checkouts"), 2)

    def test_knowledge_rows_reach_the_fts_index(self):
        hits = self.count("SELECT COUNT(*) FROM project_note_fts WHERE project_note_fts MATCH ?", "wilgotnosci")
        self.assertGreaterEqual(hits, 1, "notes are searchable without diacritics (unicode61 remove_diacritics 2)")
        docs = self.count("SELECT COUNT(*) FROM project_document_fts WHERE project_document_fts MATCH ?", "hydroizolacyjne")
        self.assertGreaterEqual(docs, 1)


# ---------------------------------------------------------------------------- source-level safety
def debug_regions(lines):
    """For each line, whether it is compiled only in DEBUG (inside an `#if DEBUG` true branch)."""
    stack, out = [], []
    for line in lines:
        s = line.strip()
        if s.startswith("#if"):
            stack.append("DEBUG" if s == "#if DEBUG" else "other")
        elif s.startswith("#else") and stack:
            stack[-1] = "notDEBUG" if stack[-1] == "DEBUG" else stack[-1]
        elif s.startswith("#endif") and stack:
            stack.pop()
        out.append("DEBUG" in stack and "notDEBUG" not in stack)
    return out


class SourceSafetyTests(unittest.TestCase):
    def test_demo_sources_are_debug_only(self):
        for f in (REPO / "BTechnica" / "Demo").glob("*.swift"):
            code = [l for l in f.read_text(encoding="utf-8").splitlines() if l.strip() and not l.strip().startswith("//")]
            self.assertEqual(code[0].strip(), "#if DEBUG", f.name)
            self.assertEqual(code[-1].strip(), "#endif", f.name)

    def test_demo_symbols_used_only_in_debug_code(self):
        symbols = re.compile(r"\b(DemoMode|DemoModeController|DemoGateView|DemoDataSeeder|DemoSeedVerification)\b")
        demo_dir = REPO / "BTechnica" / "Demo"
        for f in (REPO / "BTechnica").rglob("*.swift"):
            if f.parent == demo_dir:
                continue
            lines = f.read_text(encoding="utf-8").splitlines()
            for n, (line, debug) in enumerate(zip(lines, debug_regions(lines)), 1):
                if symbols.search(line.split("//")[0]):
                    self.assertTrue(debug, f"{f.relative_to(REPO)}:{n} uses demo code outside #if DEBUG")

    def test_seeder_uses_no_sync_or_outbox_api(self):
        forbidden = ["SyncOutboxPushService", "persistDrawingFolderCreate", "persistDrawingFolderRename",
                     "persistDrawingFolderDelete", "persistAreaCreate", "enqueueDrawingPDFUpload",
                     "enqueueDrawingMetadataSync", "ensureDrawingPDFDownloadQueued", "insertOutboxEntry",
                     "SupabaseManager", "Coordinator.shared", "scheduleDrawing"]
        for f in (REPO / "BTechnica" / "Demo").glob("*.swift"):
            text = f.read_text(encoding="utf-8")
            for token in forbidden:
                self.assertNotIn(token, text, f"{f.name} calls {token}")

    def test_every_supabase_guard_skips_local_only_users(self):
        guards = 0
        for f in (REPO / "BTechnica" / "Sync").glob("*.swift"):
            if "Verification" in f.name:
                continue
            for line in f.read_text(encoding="utf-8").splitlines():
                if "SupabaseManager.isConfigured" in line:
                    guards += 1
                    self.assertIn("!LocalOnlyWorkspace.isLocalOnly(userId: userId)", line, f.name)
        self.assertEqual(guards, 9)
        local = (REPO / "BTechnica" / "Support" / "LocalOnlyWorkspace.swift").read_text(encoding="utf-8")
        self.assertRegex(local, r"#else\s+return false")

    def test_release_build_excludes_fixture_resources(self):
        xcconfig = (REPO / "Config" / "Base.xcconfig").read_text(encoding="utf-8")
        self.assertIn("EXCLUDED_SOURCE_FILE_NAMES[config=Release] = demo-fixture-*", xcconfig)


if __name__ == "__main__":
    unittest.main(verbosity=2)
