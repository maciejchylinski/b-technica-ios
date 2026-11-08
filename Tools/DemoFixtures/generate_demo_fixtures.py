"""Generates the B Technica DEBUG demo fixtures into BTechnica/DemoFixtures/.

    python Tools/DemoFixtures/generate_demo_fixtures.py          # (re)write fixtures
    python Tools/DemoFixtures/generate_demo_fixtures.py --check  # verify committed files are current

Output (all prefixed `demo-fixture-`, flattened into the app bundle by Xcode):
  * demo-fixture-manifest.json   — every record, deterministic UUIDs, relative dates
  * demo-fixture-dwg-*.pdf        — vector drawings (PDFKit viewer)
  * demo-fixture-doc-*.pdf        — searchable technical documents (Project Knowledge)
  * demo-fixture-photo-*.png      — synthetic site photos (converted to JPEG at seed time)

Generation is deterministic: running it twice produces byte-identical files.
Standard library only.
"""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import dataset as D  # noqa: E402
import documents  # noqa: E402
import raster  # noqa: E402
import sheets as S  # noqa: E402
from pdfwriter import build_pdf  # noqa: E402

REPO = HERE.parents[1]
OUT = REPO / "BTechnica" / "DemoFixtures"
PREFIX = "demo-fixture-"
FORMAT_VERSION = 1


class FixtureError(Exception):
    pass


def check(cond: bool, message: str):
    if not cond:
        raise FixtureError(message)


def point_in_polygon(x, y, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % n]
        if (y0 > y) != (y1 > y):
            if x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
                inside = not inside
    return inside


def in_content(page, x, y) -> bool:
    x0, y0, x1, y1 = S.content_box(page)
    tbx = page.width - S.FRAME - S.TB_W
    in_title = x >= tbx and y <= S.FRAME + S.TB_H + S.REV_H
    return x0 < x < x1 and y0 < y < y1 and not in_title


def title_info(project: dict, spec: dict, subtitle_override=None) -> dict:
    if project["key"] == "A":
        proj, investor = S.PROJECT_A, S.INVESTOR_A
    else:
        proj = "Modernizacja Biurowca — Centrum · 3. piętro"
        investor = "Inwestor: Centrum Office Park Sp. z o.o. (podmiot fikcyjny)"
    return dict(project=proj, investor=investor, title=spec["title"], subtitle=subtitle_override or spec["subtitle"],
                number=spec["number"], scale=spec["scale"], revision=spec["revision"], date=spec["date"],
                discipline=spec["discipline"], revisions=spec["revisions"],
                author=spec.get("author", "arch. J. Czarnecka"), checker=spec.get("checker", "inż. K. Nowicki"))


def render_drawing(project: dict, spec: dict):
    if spec["key"] == "e101":
        pages, transforms = S.sheet_electrical(
            title_info(project, spec, "Arkusz 1 z 2 — instalacja oświetleniowa"),
            title_info(project, spec, "Arkusz 2 z 2 — gniazda i tablice"))
    else:
        pages, transforms = spec["sheet"](title_info(project, spec))
    sheet = S.Sheet(key=spec["key"], number=spec["number"], title=spec["title"], scale_label=spec["scale"],
                    pages=pages, transforms=transforms)
    pdf = build_pdf(pages, f"{spec['number']} {spec['title']}", subject=f"{project['name']} — rysunek demonstracyjny",
                    keywords="B Technica, demo, rysunek fikcyjny")
    return sheet, pdf


def build(out_dir: Path) -> dict:
    files: dict[str, bytes] = {}
    manifest = {"formatVersion": FORMAT_VERSION, "seedVersion": "", "demoUserId": D.DEMO_USER_ID,
                "note": "Dane fikcyjne do trybu demonstracyjnego (DEBUG). Generator: Tools/DemoFixtures.",
                **D.base_records(), "projects": []}
    contractor_names = {c["name"] for c in manifest["contractors"]}
    discipline_names = {d["name"] for d in manifest["disciplines"]}
    photo_number = 0

    for project in D.PROJECTS:
        pk = project["key"]
        pid = D.uid(f"project/{pk}")
        links = []
        link_id_of = {}
        for kind, key, role in project["links"]:
            lid = D.uid(f"{pk}/link/{kind}/{key}")
            link_id_of[(kind, key)] = lid
            links.append({"id": lid, "kind": kind, "contactId": D.uid(f"{kind}/{key}"), "role": role})

        folder_ids = {key: D.uid(f"{pk}/folder/{key}") for key, *_ in project["folders"]}
        folders = [{"id": folder_ids[key], "parentId": folder_ids.get(parent) if parent else None, "name": name,
                    "sortOrder": order} for key, parent, name, order in project["folders"]]

        sheets_by_key = {}
        drawings = []
        for spec in project["drawings"]:
            sheet, pdf = render_drawing(project, spec)
            sheets_by_key[spec["key"]] = sheet
            resource = f"{PREFIX}dwg-{spec['key']}.pdf"
            files[resource] = pdf
            calibrations = []
            if spec.get("calibration"):
                page_index, a, b, meters = spec["calibration"]
                ax, ay = sheet.to_page(page_index, *a)
                bx, by = sheet.to_page(page_index, *b)
                check(in_content(sheet.pages[page_index], ax, ay) and in_content(sheet.pages[page_index], bx, by),
                      f"calibration points of {spec['number']} outside the drawing area")
                calibrations.append({"id": D.uid(f"{pk}/drawing/{spec['key']}/cal/{page_index}"),
                                     "pageIndex": page_index, "ax": ax, "ay": ay, "bx": bx, "by": by,
                                     "enteredValue": meters, "unit": "m"})
            drawings.append({
                "id": D.uid(f"{pk}/drawing/{spec['key']}"), "folderId": folder_ids[spec["folder"]],
                "number": spec["number"], "name": f"{spec['number']} {spec['title']}", "resource": resource,
                "pageCount": len(sheet.pages), "pageWidth": sheet.pages[0].width, "pageHeight": sheet.pages[0].height,
                "revision": spec["revision"], "discipline": spec["discipline"], "location": spec["location"],
                "drawingDate": spec["date"], "calibrations": calibrations})
        drawing_id = {spec["key"]: D.uid(f"{pk}/drawing/{spec['key']}") for spec in project["drawings"]}

        areas = []
        area_page_poly = {}
        for key, dkey, page_index, name, world_poly, color, opacity in project["areas"]:
            sheet = sheets_by_key[dkey]
            pts = [sheet.to_page(page_index, x, y) for x, y in world_poly]
            for x, y in pts:
                check(in_content(sheet.pages[page_index], x, y), f"area {name} vertex outside the drawing area")
            check(len(pts) >= 3, f"area {name} needs 3+ vertices")
            area_page_poly[key] = (dkey, page_index, pts)
            areas.append({"id": D.uid(f"{pk}/area/{key}"), "drawingId": drawing_id[dkey], "pageIndex": page_index,
                          "name": name, "color": color, "opacity": opacity, "vertices": [[x, y] for x, y in pts]})

        issues = []
        issue_id = {}
        attachments = []
        for number, row in enumerate(project["issues"], start=1):
            (key, dkey, page_index, (wx, wy), title, details, status, discipline, contractor, day, minute, area_key,
             photo_specs) = row
            sheet = sheets_by_key[dkey]
            check(page_index < len(sheet.pages), f"issue {key}: page {page_index} does not exist")
            x, y = sheet.to_page(page_index, wx, wy)
            check(in_content(sheet.pages[page_index], x, y), f"issue {key}: pin outside the drawing area")
            if area_key:
                adkey, apage, apoly = area_page_poly[area_key]
                check(adkey == dkey and apage == page_index, f"issue {key}: area on another drawing/page")
                check(point_in_polygon(x, y, apoly), f"issue {key}: pin is not inside area {area_key}")
            check(status in ("open", "inProgress", "resolved", "closed"), f"issue {key}: bad status")
            check(discipline in discipline_names, f"issue {key}: unknown discipline {discipline}")
            check(D.CONTRACTOR_NAME[contractor] in contractor_names, f"issue {key}: unknown contractor")
            iid = D.uid(f"{pk}/issue/{key}")
            issue_id[key] = iid
            photos = []
            for scene, variant in photo_specs:
                photo_number += 1
                resource = f"{PREFIX}photo-{pk.lower()}-{scene}-{variant}.png"
                files[resource] = raster.render(scene, variant, photo_number, f"{title[:42]}")
                photos.append({"id": D.uid(f"{pk}/photo/{scene}-{variant}"), "resource": resource,
                               "dayOffset": day, "minute": minute + 2 + len(photos)})
                attachments.append(resource)
            issues.append({"id": iid, "number": number, "drawingId": drawing_id[dkey], "pageIndex": page_index,
                           "x": x, "y": y, "areaId": D.uid(f"{pk}/area/{area_key}") if area_key else None,
                           "title": title, "details": details, "status": status, "discipline": discipline,
                           "contractor": D.CONTRACTOR_NAME[contractor], "createdDayOffset": day,
                           "createdMinute": minute, "photos": photos})

        album_id = {key: D.uid(f"{pk}/album/{key}") for key, *_ in project["albums"]}
        albums = [{"id": album_id[key], "name": name, "sortOrder": order} for key, name, order in project["albums"]]
        photos = []
        for scene, variant, album, title, description, day, minute, dkey, page_index, area_key, issue_key in \
                project["photos"]:
            photo_number += 1
            resource = f"{PREFIX}photo-{pk.lower()}-{scene}-{variant}.png"
            check(resource not in files, f"photo resource reused: {resource}")
            files[resource] = raster.render(scene, variant, photo_number, title[:42])
            if area_key:
                check(dkey is not None and area_page_poly[area_key][0] == dkey, f"photo {title}: area/drawing mismatch")
            photos.append({"id": D.uid(f"{pk}/photo/{scene}-{variant}"), "resource": resource,
                           "albumId": album_id[album], "title": title, "description": description,
                           "takenDayOffset": day, "takenMinute": minute,
                           "drawingId": drawing_id[dkey] if dkey else None,
                           "pageIndex": page_index if dkey else None,
                           "areaId": D.uid(f"{pk}/area/{area_key}") if area_key else None,
                           "issueId": issue_id[issue_key] if issue_key else None})

        sched_name, sched_details, phase_rows, task_rows = project["schedule"]
        phase_id = {key: D.uid(f"{pk}/phase/{key}") for key, *_ in phase_rows}
        task_id = {row[0]: D.uid(f"{pk}/task/{row[0]}") for row in task_rows}
        tasks, deps = [], []
        by_key = {row[0]: row for row in task_rows}
        for order, (key, phase, kind, title, start, finish, progress, status, resp, preds) in enumerate(task_rows):
            check(finish >= start, f"task {key}: finish before start")
            check(kind != "milestone" or start == finish, f"milestone {key}: start != finish")
            check(status != "completed" or progress == 100, f"task {key}: completed but progress {progress}")
            check(("company", resp) in link_id_of, f"task {key}: responsible company not linked to project {pk}")
            for pred in preds:
                p = by_key[pred]
                earliest = p[5] if p[2] == "milestone" else p[5] + 1
                check(start >= earliest, f"task {key} starts before predecessor {pred} allows")
                deps.append({"id": D.uid(f"{pk}/dep/{pred}-{key}"), "predecessorId": task_id[pred],
                             "successorId": task_id[key]})
            tasks.append({"id": task_id[key], "phaseId": phase_id[phase], "kind": kind, "title": title, "details": "",
                          "startOffset": start, "finishOffset": finish, "progress": progress, "status": status,
                          "responsibleName": D.CONTRACTOR_NAME[resp],
                          "responsibleLinkId": link_id_of[("company", resp)], "notes": "", "sortOrder": order})
        schedule = {"id": D.uid(f"{pk}/schedule"), "name": sched_name, "details": sched_details,
                    "phases": [{"id": phase_id[k], "name": n, "color": c, "sortOrder": i}
                               for i, (k, n, c) in enumerate(phase_rows)],
                    "tasks": tasks, "dependencies": deps}

        doc_folder_id = {key: D.uid(f"{pk}/docfolder/{key}") for key, *_ in project["doc_folders"]}
        doc_folders = [{"id": doc_folder_id[key], "parentId": None, "name": name, "sortOrder": order}
                       for key, name, order in project["doc_folders"]]
        docs = []
        for key, folder, name, category, description, revision, rev_date, uploaded in project["documents"]:
            resource = f"{PREFIX}doc-{key}.pdf"
            pages = documents.DOCUMENTS[key]()
            files[resource] = build_pdf(pages, name, subject=f"{project['name']} — dokument demonstracyjny",
                                        keywords="B Technica, demo, dokument fikcyjny")
            docs.append({"id": D.uid(f"{pk}/document/{key}"), "folderId": doc_folder_id.get(folder) if folder else None,
                         "resource": resource, "originalFileName": f"{name}.pdf", "name": name, "category": category,
                         "description": description, "revision": revision, "revisionDate": rev_date,
                         "uploadedDayOffset": uploaded})
        notes = [{"id": D.uid(f"{pk}/note/{i}"), "title": title, "category": category, "createdDayOffset": day,
                  "body": body} for i, (title, category, day, body) in enumerate(project["notes"])]

        manifest["projects"].append({
            "id": pid, "key": pk, "name": project["name"], "description": project["description"],
            "createdDayOffset": project["created"], "contactLinks": links, "drawingFolders": folders,
            "drawings": drawings, "areas": areas, "issues": issues, "photoAlbums": albums, "photos": photos,
            "schedule": schedule, "documentFolders": doc_folders, "documents": docs, "notes": notes})

    # Seed version: hash of everything that ends up in the app, so a regenerated fixture set reseeds.
    digest = hashlib.sha256()
    digest.update(json.dumps(manifest, ensure_ascii=False, sort_keys=True).encode("utf-8"))
    for name in sorted(files):
        digest.update(name.encode("utf-8"))
        digest.update(files[name])
    manifest["seedVersion"] = f"{FORMAT_VERSION}-{digest.hexdigest()[:12]}"
    files[f"{PREFIX}manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=1) + "\n").encode("utf-8")

    out_dir.mkdir(parents=True, exist_ok=True)
    for stale in out_dir.glob(f"{PREFIX}*"):
        stale.unlink()
    for name, data in files.items():
        (out_dir / name).write_bytes(data)
    return {"files": len(files), "bytes": sum(len(d) for d in files.values()), "seedVersion": manifest["seedVersion"]}


def main(argv):
    if "--check" in argv:
        with tempfile.TemporaryDirectory() as tmp:
            build(Path(tmp))
            fresh = {p.name: p.read_bytes() for p in Path(tmp).glob(f"{PREFIX}*")}
        current = {p.name: p.read_bytes() for p in OUT.glob(f"{PREFIX}*")}
        if fresh != current:
            missing = sorted(set(fresh) - set(current))
            extra = sorted(set(current) - set(fresh))
            changed = sorted(n for n in set(fresh) & set(current) if fresh[n] != current[n])
            print(f"fixtures out of date: missing={missing} extra={extra} changed={changed}")
            return 1
        print(f"fixtures up to date ({len(current)} files)")
        return 0
    info = build(OUT)
    print(f"wrote {info['files']} files, {info['bytes'] // 1024} KB, seedVersion {info['seedVersion']} -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
