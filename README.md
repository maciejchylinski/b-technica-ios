# BTechnica — iOS/iPadOS field app (MVP slice 2)

A native SwiftUI, offline-first construction **field app** (Dalux-style). The
drawing/PDF is the centre of the product. This slice covers importing a PDF
drawing, viewing it with PDFKit, calibrating its real-world scale, and pinning
field issues to PDF page coordinates.

Requirements: Xcode 26+, iOS 17+. iPhone first, iPad compatible. No backend, no
login, no cloud sync, no third-party libraries.

## Run

Open `BTechnica.xcodeproj` in Xcode, pick an iPhone or iPad simulator, and Run.
Or from the command line:

```bash
xcodebuild -project BTechnica.xcodeproj -scheme BTechnica \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## What works in this slice

- **Project shell** with a single local default project and a Dalux-like tab
  bar: Home · Drawings · Issues · Equipment · More.
- **Drawings**: import a PDF from the Files app; the file is copied into the
  app's local `Documents/Drawings/` folder; metadata is saved locally.
- **PDF viewer**: native PDFKit (`PDFView`) via a SwiftUI wrapper, with native
  zoom/pan and the drawing name in the header.
- **Scale calibration**: tap point A → tap point B → enter real distance + unit
  (mm/cm/m). Stored per drawing/page in **PDF page coordinates**, with the
  computed `mm per PDF unit` and a small debug readout.
- **Issues**: Add issue → tap PDF → form (title, description, optional
  discipline/contractor, status Open) → numbered pin on the PDF → tap pin for
  compact preview → open Issue Detail. Issues tab lists all saved issues.
  Persists across app restarts.

## Architecture

- `BTechnicaApp.swift` — app entry, injects `AppStore`.
- `Models/` — `Project`, `Drawing`, `PageCalibration`, `PDFPoint`, `Issue`,
  `EquipmentItem`, `LengthUnit`.
- `Store/` — `AppData` (Codable document) + `AppStore` (`ObservableObject`,
  JSON persistence to `Documents/appdata.json`, PDF file management).
- `Features/` — `RootView` (tabs) and one folder per tab. Drawings holds the
  document picker, list, PDFKit wrapper, detail view and calibration sheet.
  Issues holds the list, create form and detail screen.
- `Support/Theme.swift` — small white/blue design tokens.

## Storage

Single JSON file (`Documents/appdata.json`) via `Codable`. Chosen over SwiftData
to keep this slice simple and readable; the feature code only talks to
`AppStore`, so the persistence layer can be swapped later without UI changes.

## Coordinate foundation

All tapped points are converted from view coordinates into **PDF page
coordinates** using `PDFView.page(for:nearest:)` + `PDFView.convert(_:to:)`, and
stored as `PDFPoint` / `Issue.pdfX`+`pdfY`. Issue pins are drawn as PDF
annotations so they stay attached to the page through zoom and pan. Never store
screen coordinates or percentages.

## Not in this slice (by design)

No backend / auth / cloud / email / reports, no issue photos, no measurements
beyond the calibration debug, no equipment UI beyond the placeholder, no
third-party libraries, no Mac desktop.
