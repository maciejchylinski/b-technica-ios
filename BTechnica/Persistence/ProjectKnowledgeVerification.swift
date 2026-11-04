import Foundation
import GRDB
import PDFKit
import UIKit
import Vision

/// Focused checks for the project document library: persistence, PDF text + OCR extraction,
/// FTS search (phrases, diacritics, categories) and strict project isolation.
/// Runs in an isolated temp tree — never touches live Documents data.
///
/// Launch with `-BTVerifyProjectKnowledge` (DEBUG builds).
enum ProjectKnowledgeVerification {
    struct Step {
        var name: String
        var passed: Bool
        var detail: String
    }

    struct Result {
        var passed: Bool
        var steps: [Step]
        var metrics: [String: Any]
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-BTVerifyProjectKnowledge") else { return }
        let result = run()
        let payload: [String: Any] = [
            "passed": result.passed,
            "steps": result.steps.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
            "metrics": result.metrics
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bt-project-knowledge-verify.json")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            fputs("BT_PROJECT_KNOWLEDGE_VERIFY \(text)\n", stderr)
        } else {
            fputs("BT_PROJECT_KNOWLEDGE_VERIFY passed=\(result.passed)\n", stderr)
        }
    }

    static func run() -> Result {
        var steps: [Step] = []
        var metrics: [String: Any] = [:]
        do {
            try runThrowing(steps: &steps, metrics: &metrics)
        } catch {
            steps.append(Step(name: "unexpected error", passed: false, detail: "\(error)"))
        }
        return Result(passed: !steps.isEmpty && steps.allSatisfy(\.passed), steps: steps, metrics: metrics)
    }

    // MARK: Scenario

    private static let userId = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private static let projectA = Project(
        id: UUID(uuidString: "A0A0A0A0-0000-0000-0000-00000000000A")!,
        name: "Knowledge A",
        createdDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    private static let projectB = Project(
        id: UUID(uuidString: "B0B0B0B0-0000-0000-0000-00000000000B")!,
        name: "Knowledge B",
        createdDate: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static let specPage1 = """
    SPECYFIKACJA TECHNICZNA ST-05
    Izolacja fundamentów

    Izolacja fundamentów wykonana z dwóch warstw papy termozgrzewalnej.
    Ściany fundamentowe należy zabezpieczyć przed wilgocią gruntową.
    """
    private static let specPage2 = """
    Konstrukcja żelbetowa
    Ławy fundamentowe wykonać z betonu C25/30 klasy ekspozycji XC2.
    Docieplenie ścian: wełna mineralna gr. 150 mm, lambda 0,035.
    Przegrody oddzielenia pożarowego: odporność ogniowa REI 120.
    """
    private static let scannedLines = [
        "FIRE RESISTANCE CERTIFICATE",
        "Mineral wool partition",
        "Fire resistance class EI 120",
        "Approval number AT-15-9876"
    ]

    private static func runThrowing(steps: inout [Step], metrics: inout [String: Any]) throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            steps.append(Step(name: name, passed: condition, detail: condition ? "ok" : detail()))
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("btechnica-knowledge-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("btechnica.sqlite")
        var db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        try db.ensureProject(projectA)
        try db.ensureProject(projectB)
        let rootA = DocumentFileStorage.projectRootURL(userRootURL: root, projectId: projectA.id)
        let rootB = DocumentFileStorage.projectRootURL(userRootURL: root, projectId: projectB.id)

        // Schema
        let ftsTables = try db.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_fts'")
        }
        check("schema: three FTS5 tables",
              Set(ftsTables) == ["project_document_page_fts", "project_document_fts", "project_note_fts"],
              "found \(ftsTables)")

        // Fixtures
        let specURL = inbox.appendingPathComponent("ST-05 Izolacje.pdf")
        try makeTextPDF(pages: [specPage1, specPage2], to: specURL)
        let scanURL = inbox.appendingPathComponent("Aprobata EI120 (skan).pdf")
        try makeScannedPDF(lines: scannedLines, to: scanURL)
        let otherURL = inbox.appendingPathComponent("Projekt B fundamenty.pdf")
        try makeTextPDF(pages: ["Projekt B. Izolacja fundamentów z masy bitumicznej. Beton C30/37."], to: otherURL)
        let junkURL = inbox.appendingPathComponent("broken.pdf")
        try Data("this is not a pdf".utf8).write(to: junkURL)

        // Import
        let spec = try importDocument(specURL, project: projectA.id, root: rootA, db: db, category: .technicalSpecification)
        let scan = try importDocument(scanURL, project: projectA.id, root: rootA, db: db, category: .technicalApproval)
        let other = try importDocument(otherURL, project: projectB.id, root: rootB, db: db, category: .technicalSpecification)
        check("import: original copied byte-for-byte",
              fm.contentsEqual(atPath: specURL.path,
                               andPath: DocumentFileStorage.fileURL(projectRootURL: rootA, relativePath: spec.fileRelativePath).path))
        check("import: file stored under project scope",
              spec.fileRelativePath.hasPrefix("ProjectDocuments/") &&
              fm.fileExists(atPath: rootA.appendingPathComponent(spec.fileRelativePath).path) &&
              !fm.fileExists(atPath: rootB.appendingPathComponent(spec.fileRelativePath).path))
        check("import: metadata (pages, size, checksum)",
              spec.pageCount == 2 && spec.fileSizeBytes > 0 && spec.checksumSHA256?.count == 64,
              "pages=\(spec.pageCount) size=\(spec.fileSizeBytes)")

        var junkRejected = false
        do {
            _ = try importDocument(junkURL, project: projectA.id, root: rootA, db: db, category: .other)
        } catch {
            junkRejected = true
        }
        let leftovers = (try? fm.contentsOfDirectory(atPath: rootA.appendingPathComponent("ProjectDocuments").path)) ?? []
        check("import: unreadable PDF rejected without leftovers", junkRejected && leftovers.count == 2,
              "rejected=\(junkRejected) files=\(leftovers.count)")
        check("import: duplicate detected by checksum",
              try db.fetchProjectDocument(projectId: projectA.id, checksum: spec.checksumSHA256 ?? "")?.id == spec.id)

        // Extraction
        var started = CFAbsoluteTimeGetCurrent()
        let specOutcome = DocumentIndexer.index(documentId: spec.id, projectId: projectA.id, database: db, projectRootURL: rootA)
        metrics["text_index_seconds"] = round((CFAbsoluteTimeGetCurrent() - started) * 1000) / 1000
        check("extract: PDFKit text for every page",
              specOutcome == .indexed(pages: 2, textPages: 2, ocrPages: 0), "\(specOutcome)")
        let specPages = try db.fetchDocumentPages(documentId: spec.id, projectId: projectA.id)
        check("extract: page-level text references",
              specPages.count == 2 && specPages[1].text.contains("C25/30") && specPages[0].text.contains("Izolacja fundamentów"),
              "pages=\(specPages.map { String($0.text.prefix(40)) })")

        started = CFAbsoluteTimeGetCurrent()
        let scanOutcome = DocumentIndexer.index(documentId: scan.id, projectId: projectA.id, database: db, projectRootURL: rootA)
        metrics["ocr_index_seconds"] = round((CFAbsoluteTimeGetCurrent() - started) * 1000) / 1000
        let scanPages = try db.fetchDocumentPages(documentId: scan.id, projectId: projectA.id)
        let ocrText = scanPages.first?.text ?? ""
        metrics["ocr_text"] = ocrText
        metrics["ocr_confidence"] = scanPages.first?.ocrConfidence ?? 0
        metrics["ocr_languages"] = DocumentTextExtractor.ocrLanguages(for: VNRecognizeTextRequest())
        check("ocr: scanned page read with Vision",
              scanOutcome == .indexed(pages: 1, textPages: 0, ocrPages: 1) && scanPages.first?.extractionMethod == .ocr,
              "\(scanOutcome)")
        check("ocr: recognised text content",
              ocrText.localizedCaseInsensitiveContains("resistance") && ocrText.contains("120"),
              "text=\(ocrText)")

        _ = DocumentIndexer.index(documentId: other.id, projectId: projectB.id, database: db, projectRootURL: rootB)

        let indexedAtBefore = try db.fetchProjectDocument(id: spec.id, projectId: projectA.id)?.indexedAt
        let repeatOutcome = DocumentIndexer.index(documentId: spec.id, projectId: projectA.id, database: db, projectRootURL: rootA)
        let indexedAtAfter = try db.fetchProjectDocument(id: spec.id, projectId: projectA.id)?.indexedAt
        check("index: unchanged document is not re-extracted",
              repeatOutcome == .skippedUnchanged && indexedAtBefore == indexedAtAfter, "\(repeatOutcome)")
        let queue = try db.fetchDocumentsNeedingIndex(projectId: projectA.id, extractorVersion: DocumentTextExtractor.version)
        check("index: queue empty after indexing", queue.isEmpty, "queue=\(queue.map(\.name))")

        // Search (project A)
        func pageHit(_ query: String, scope: KnowledgeSearchScope = .all, project: UUID = projectA.id) throws -> [KnowledgeSearchResult] {
            try db.searchKnowledge(projectId: project, query: query, scope: scope)
        }
        func firstPage(_ results: [KnowledgeSearchResult], document: UUID) -> Int? {
            results.first { $0.reference.sourceId == document && $0.reference.sourceType == .documentPage }?.reference.pageIndex
        }

        var searchLog: [String: String] = [:]
        for (query, expectedPage) in [
            ("izolacja fundamentów", 0),
            ("\"izolacja fundamentów\"", 0),
            ("beton C25/30", 1),
            ("wełna mineralna", 1),
            ("odporność ogniowa", 1),
            ("odpornosc ogniowa", 1),
            ("fundament", 0)
        ] {
            let results = try pageHit(query)
            let page = firstPage(results, document: spec.id)
            searchLog[query] = results
                .map { result -> String in
                    let pageText = result.reference.pageNumber.map { String($0) } ?? "-"
                    return "\(result.reference.title) p\(pageText)"
                }
                .joined(separator: "; ")
            let pageText = page.map { String($0) } ?? "nil"
            check("search A: \(query) → page \(expectedPage + 1)", page == expectedPage,
                  "got page \(pageText) in \(results.count) results")
            check("search A: \(query) excludes project B",
                  !results.contains { $0.reference.sourceId == other.id || $0.reference.projectId != projectA.id })
        }
        let snippet = try pageHit("beton C25/30").first?.snippet ?? ""
        check("search: snippet marks matched words",
              snippet.contains(KnowledgeSearchResult.matchStart) && snippet.contains("C25"), "snippet=\(snippet)")
        let ocrHits = try pageHit("fire resistance")
        check("search: OCR text searchable with page reference", firstPage(ocrHits, document: scan.id) == 0,
              "results=\(ocrHits.count)")
        check("search: phrase does not match scattered words",
              try pageHit("\"fundamentów beton\"").isEmpty)
        metrics["search_results"] = searchLog

        // Isolation
        let fromB = try pageHit("izolacja fundamentów", project: projectB.id)
        check("isolation: project B sees only its own document",
              !fromB.isEmpty && fromB.allSatisfy { $0.reference.sourceId == other.id },
              "B results=\(fromB.map(\.reference.title))")
        check("isolation: project B does not see A-only terms", try pageHit("wełna mineralna", project: projectB.id).isEmpty)
        check("isolation: cross-project document lookup refused",
              try db.fetchProjectDocument(id: spec.id, projectId: projectB.id) == nil &&
              (try db.fetchDocumentPages(documentId: spec.id, projectId: projectB.id)).isEmpty)

        // Category filter
        check("filter: matching category keeps results",
              firstPage(try pageHit("beton", scope: .category(.technicalSpecification)), document: spec.id) == 1)
        check("filter: other category hides results",
              try pageHit("beton", scope: .category(.installationManual)).isEmpty)
        check("filter: approvals category finds OCR doc only",
              try pageHit("resistance", scope: .category(.technicalApproval)).allSatisfy { $0.reference.sourceId == scan.id })

        // Notes
        let noteId = UUID()
        var note = ProjectNote(
            id: noteId, projectId: projectA.id, title: "Odbiór hydroizolacji",
            body: "Sprawdzono hydroizolację ścian fundamentowych w osi 3 – bez uwag.",
            category: .inspection, createdAt: Date(), updatedAt: Date()
        )
        try db.upsertProjectNote(note)
        let noteHits = try pageHit("hydroizolację")
        check("notes: searchable in own project",
              noteHits.contains { $0.reference.sourceType == .note && $0.reference.sourceId == noteId })
        check("notes: not visible from project B", try pageHit("hydroizolację", project: projectB.id).isEmpty)
        check("notes: documents scope excludes notes",
              try pageHit("hydroizolację", scope: .documents).isEmpty)
        note.body = "Zmieniono: kontrola zbrojenia stropu."
        note.updatedAt = Date()
        try db.upsertProjectNote(note)
        check("notes: edit updates index",
              try pageHit("hydroizolacji").contains { $0.reference.sourceId == noteId }
                && (try pageHit("zbrojenia")).contains { $0.reference.sourceId == noteId }
                && (try pageHit("hydroizolację")).allSatisfy { $0.reference.sourceId != noteId })

        // Metadata search + citation
        try db.updateProjectDocumentMetadata(
            id: spec.id, projectId: projectA.id, name: "Specyfikacja ST-05 Izolacje",
            category: .technicalSpecification, descriptionText: "Branża konstrukcyjna",
            revision: "B", revisionDate: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let titleHits = try pageHit("specyfikacja konstrukcyjna")
        check("metadata: renamed document found by name/description",
              titleHits.contains { $0.reference.sourceType == .document && $0.reference.sourceId == spec.id })
        let citation = try db.knowledgeSourceReference(documentId: spec.id, projectId: projectA.id, pageIndex: 1)?.citation
        check("citation: document + revision + page", citation == "Specyfikacja ST-05 Izolacje (rev B), p. 2",
              "citation=\(citation ?? "nil")")

        // Folders
        let now = Date()
        let parent = ProjectDocumentFolder(id: UUID(), projectId: projectA.id, parentFolderId: nil, name: "Specyfikacje", sortOrder: 0, createdAt: now, updatedAt: now)
        let child = ProjectDocumentFolder(id: UUID(), projectId: projectA.id, parentFolderId: parent.id, name: "Konstrukcja", sortOrder: 0, createdAt: now, updatedAt: now)
        try db.insertDocumentFolder(parent)
        try db.insertDocumentFolder(child)
        var duplicateRejected = false
        do {
            try db.insertDocumentFolder(ProjectDocumentFolder(id: UUID(), projectId: projectA.id, parentFolderId: nil, name: "specyfikacje", sortOrder: 1, createdAt: now, updatedAt: now))
        } catch { duplicateRejected = true }
        check("folders: sibling names unique (case-insensitive)", duplicateRejected)
        var cycleRejected = false
        do { try db.moveDocumentFolder(id: parent.id, projectId: projectA.id, toParentId: child.id) } catch { cycleRejected = true }
        check("folders: cannot move into own subfolder", cycleRejected)
        try db.moveProjectDocument(id: spec.id, projectId: projectA.id, toFolderId: child.id)
        check("folders: B cannot use A's folder",
              (try? db.moveProjectDocument(id: other.id, projectId: projectB.id, toFolderId: child.id)) == nil)

        // Persistence across reopen
        db = try AppDatabase.open(userId: userId, at: dbURL, rootURL: root)
        let reopenedDocs = try db.fetchProjectDocuments(projectId: projectA.id)
        let reopenedSpec = reopenedDocs.first { $0.id == spec.id }
        check("persistence: documents, folders, notes survive reopen",
              reopenedDocs.count == 2
                && reopenedSpec?.folderId == child.id
                && reopenedSpec?.revision == "B"
                && reopenedSpec?.indexStatus == .indexed
                && (try db.fetchDocumentFolders(projectId: projectA.id)).count == 2
                && (try db.fetchProjectNotes(projectId: projectA.id)).count == 1
                && (try db.fetchDocumentFolders(projectId: projectB.id)).isEmpty,
              "docs=\(reopenedDocs.count)")
        check("persistence: search works after reopen", firstPage(try pageHit("beton C25/30"), document: spec.id) == 1)
        check("persistence: checksum still matches file",
              try DocumentFileStorage.sha256Hex(of: rootA.appendingPathComponent(spec.fileRelativePath)) == spec.checksumSHA256)

        // Missing file is reported, not crashed on
        try fm.removeItem(at: rootA.appendingPathComponent(scan.fileRelativePath))
        try db.requestDocumentIndexing(id: scan.id, projectId: projectA.id, force: true)
        let missingOutcome = DocumentIndexer.index(documentId: scan.id, projectId: projectA.id, database: db, projectRootURL: rootA)
        let missingDoc = try db.fetchProjectDocument(id: scan.id, projectId: projectA.id)
        check("missing file: indexing fails gracefully",
              missingDoc?.indexStatus == .failed && missingDoc?.indexError?.contains("missing") == true,
              "\(missingOutcome)")

        // Folder delete cascades documents and their index
        let removed = try db.deleteDocumentFolder(id: parent.id, projectId: projectA.id)
        for document in removed {
            DocumentFileStorage.removeFile(projectRootURL: rootA, relativePath: document.fileRelativePath)
        }
        check("delete: folder tree removes nested document",
              removed.map(\.id) == [spec.id] && !fm.fileExists(atPath: rootA.appendingPathComponent(spec.fileRelativePath).path))
        check("delete: removed document no longer searchable", firstPage(try pageHit("beton"), document: spec.id) == nil)
        check("delete: other project untouched", firstPage(try pageHit("beton", project: projectB.id), document: other.id) == 0)

        try db.deleteProjectNote(id: noteId, projectId: projectA.id)
        check("delete: note removed from index", try pageHit("zbrojenia").isEmpty)

        // External-content FTS consistency
        try db.dbQueue.write { db in
            for table in ["project_document_page_fts", "project_document_fts", "project_note_fts"] {
                try db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES ('integrity-check', 1)")
            }
        }
        check("fts: integrity-check passes for all indexes", true)
    }

    // MARK: Helpers

    private static func importDocument(
        _ url: URL,
        project: UUID,
        root: URL,
        db: AppDatabase,
        category: DocumentCategory
    ) throws -> ProjectDocument {
        let id = UUID()
        let stored = try DocumentFileStorage.storePDF(from: url, documentId: id, projectRootURL: root)
        let document = ProjectDocument.imported(
            id: id, projectId: project, folderId: nil,
            originalFileName: url.lastPathComponent, stored: stored, category: category
        )
        try db.insertProjectDocument(document)
        return document
    }

    private static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    private static func makeTextPDF(pages: [String], to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: a4)
        try renderer.writePDF(to: url) { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(
                    in: a4.insetBy(dx: 48, dy: 56),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13)]
                )
            }
        }
    }

    /// Image-only PDF page (no text layer), like a scanner produces.
    private static func makeScannedPDF(lines: [String], to url: URL) throws {
        let pixelSize = CGSize(width: 1240, height: 1754)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            var y: CGFloat = 160
            for line in lines {
                (line as NSString).draw(
                    at: CGPoint(x: 110, y: y),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: UIColor.black]
                )
                y += 90
            }
        }
        let renderer = UIGraphicsPDFRenderer(bounds: a4)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            image.draw(in: a4)
        }
    }
}
