"""Demo dataset for B Technica: two fictional projects with linked records.

Everything here is fictional: company names, people, phone numbers (+48 000 …, an unused
prefix) and e-mail addresses (`*.demo.example`, a reserved domain). Identifiers are
deterministic UUIDv5 values, so regenerating the fixtures never changes record ids.
Positions are given in each drawing's world coordinates (metres) and converted to PDF
page coordinates by the generator.
"""
from __future__ import annotations

import uuid

import sheets as S

NAMESPACE = uuid.UUID("5c0f8a1e-3b52-4d6e-9a47-0be1d3c2f9a0")
DEMO_USER_ID = "DE300000-B7EC-4A1C-8000-000000000001"


def uid(key: str) -> str:
    return str(uuid.uuid5(NAMESPACE, key)).upper()


# ------------------------------------------------------------------------------------
# User-global dictionaries and address book
# ------------------------------------------------------------------------------------

CONTRACTORS = [
    ("gw", "GB Horyzont Sp. z o.o.", "Generalny wykonawca — projekt A"),
    ("betonex", "Betonex Konstrukcje Sp. z o.o.", "Konstrukcje żelbetowe"),
    ("elektro", "Elektro-Volt Instalacje s.c.", "Instalacje elektryczne i teletechniczne"),
    ("aquaterm", "AquaTerm Sp. z o.o.", "Instalacje sanitarne, c.o., wentylacja, HVAC"),
    ("prodom", "Pro-Dom Wykończenia Sp. j.", "Roboty wykończeniowe"),
    ("lumen", "Lumen Okna i Fasady Sp. z o.o.", "Stolarka okienna i elewacje"),
    ("zielen", "Zieleń-Tech Sp. z o.o.", "Zagospodarowanie terenu"),
    ("modulo", "Modulo Fit-Out Sp. z o.o.", "Generalny wykonawca — projekt B"),
]
CONTRACTOR_NAME = {key: name for key, name, _ in CONTRACTORS}

DISCIPLINES = ["Architektura", "Konstrukcja", "Instalacje sanitarne", "Wentylacja i klimatyzacja",
               "Instalacje elektryczne", "Roboty wykończeniowe", "Zagospodarowanie terenu", "BHP"]

COMPANIES = [
    # key, name, trade, phone suffix, mail domain
    ("investor_a", "Zielone Tarasy Development Sp. z o.o.", "Inwestor", "101", "zielonetarasy"),
    ("gw", CONTRACTOR_NAME["gw"], "Generalny wykonawca", "102", "horyzont"),
    ("betonex", CONTRACTOR_NAME["betonex"], "Konstrukcje żelbetowe", "103", "betonex"),
    ("elektro", CONTRACTOR_NAME["elektro"], "Instalacje elektryczne i teletechniczne", "104", "elektrovolt"),
    ("aquaterm", CONTRACTOR_NAME["aquaterm"], "Instalacje sanitarne i HVAC", "105", "aquaterm"),
    ("prodom", CONTRACTOR_NAME["prodom"], "Roboty wykończeniowe", "106", "prodom"),
    ("lumen", CONTRACTOR_NAME["lumen"], "Stolarka okienna i elewacje", "107", "lumen"),
    ("zielen", CONTRACTOR_NAME["zielen"], "Zagospodarowanie terenu", "108", "zielentech"),
    ("kamien", "Hurtownia Budowlana Kamień", "Dostawca materiałów budowlanych", "109", "kamien"),
    ("linea", "Pracownia Projektowa Linea", "Projektant — architektura i konstrukcja", "110", "linea"),
    ("investor_b", "Centrum Office Park Sp. z o.o.", "Inwestor (zarządca budynku)", "111", "centrumoffice"),
    ("modulo", CONTRACTOR_NAME["modulo"], "Generalny wykonawca fit-out", "112", "modulo"),
]

PEOPLE = [
    # key, first, last, company, job title, phone suffix
    ("wierzbicki", "Tomasz", "Wierzbicki", "gw", "Kierownik budowy", "201"),
    ("malinowska", "Katarzyna", "Malinowska", "gw", "Kierownik projektu", "202"),
    ("sadowski", "Piotr", "Sadowski", "investor_a", "Inspektor nadzoru inwestorskiego", "203"),
    ("lis", "Agnieszka", "Lis", "gw", "Koordynator BHP", "204"),
    ("kubiak", "Rafał", "Kubiak", "betonex", "Kierownik robót konstrukcyjnych", "205"),
    ("domanski", "Michał", "Domański", "elektro", "Kierownik robót elektrycznych", "206"),
    ("jablonska", "Ewa", "Jabłońska", "aquaterm", "Kierownik robót sanitarnych", "207"),
    ("gorecki", "Paweł", "Górecki", "prodom", "Brygadzista wykończeń", "208"),
    ("wrobel", "Magdalena", "Wróbel", "kamien", "Opiekun handlowy", "209"),
    ("czarnecka", "Joanna", "Czarnecka", "linea", "Architekt prowadząca", "210"),
    ("nowicki", "Krzysztof", "Nowicki", "linea", "Projektant konstrukcji", "211"),
    ("pawlak", "Łukasz", "Pawlak", "lumen", "Kierownik robót elewacyjnych", "212"),
    ("zajac", "Monika", "Zając", "modulo", "Kierownik projektu fit-out", "213"),
    ("kowalczyk", "Adam", "Kowalczyk", "investor_b", "Administrator budynku", "214"),
]

_ASCII = str.maketrans("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", "acelnoszzACELNOSZZ")


def _company_records():
    out = []
    for key, name, trade, phone, domain in COMPANIES:
        out.append({
            "id": uid(f"company/{key}"), "name": name, "trade": trade,
            "taxId": f"000-000-{phone[:2]}-{phone[1:]}",
            "phone": f"+48 000 000 {phone}",
            "email": f"biuro@{domain}.demo.example",
            "website": f"https://{domain}.demo.example",
            "address": "ul. Przykładowa 1, 00-000 Miasto (adres fikcyjny)",
            "notes": "Dane fikcyjne — projekt demonstracyjny B Technica.",
        })
    return out


def _people_records():
    domains = {key: domain for key, _, _, _, domain in COMPANIES}
    out = []
    for key, first, last, company, title, phone in PEOPLE:
        login = f"{first[0]}.{last}".lower().translate(_ASCII)
        out.append({
            "id": uid(f"person/{key}"), "firstName": first, "lastName": last,
            "companyId": uid(f"company/{company}"), "jobTitle": title,
            "phone": f"+48 000 000 {phone}",
            "email": f"{login}@{domains[company]}.demo.example",
            "notes": "Osoba fikcyjna.",
        })
    return out


# ------------------------------------------------------------------------------------
# Equipment (user-global) with check-out history across both projects
# ------------------------------------------------------------------------------------

def _person(key):
    return {"recipientKind": "person", "recipientId": uid(f"person/{key}")}


def _company(key):
    return {"recipientKind": "company", "recipientId": uid(f"company/{key}")}


def _text(name):
    return {"recipientKind": "text", "recipientName": name}


EQUIPMENT = [
    ("niwelator", "Niwelator optyczny NO-32", "Geodezja", "BT-EQ-001", "NO32-2291-DEMO", -200, [
        ("issue", -120, "A", _person("kubiak"), "Budynek A — strop nad parterem", "Kontrola rzędnych szalunku"),
        ("return", -100, "good", "Zwrot po betonowaniu stropu"),
        ("issue", -40, "A", _person("wierzbicki"), "Biuro budowy", None)]),
    ("tachimetr", "Tachimetr elektroniczny TS-05", "Geodezja", "BT-EQ-002", "TS05-7781-DEMO", -200, [
        ("issue", -150, "A", _text("Geodeta uprawniony (podwykonawca zewnętrzny)"), "Plac budowy", "Tyczenie osi"),
        ("return", -149, "good", None),
        ("issue", -30, "A", _text("Geodeta uprawniony (podwykonawca zewnętrzny)"), "Budynek A", "Inwentaryzacja"),
        ("return", -29, "good", None)]),
    ("laser", "Laser rotacyjny LR-300", "Geodezja", "BT-EQ-003", "LR300-1045-DEMO", -180, [
        ("issue", -90, "A", _person("kubiak"), "Garaż podziemny", "Poziomowanie posadzki"),
        ("return", -60, "damaged", "Pęknięta osłona głowicy — do serwisu")]),
    ("wilgotnosc", "Miernik wilgotności betonu CM-2", "Pomiary", "BT-EQ-004", "CM2-3310-DEMO", -150, [
        ("issue", -20, "A", _person("gorecki"), "Budynek A — piętro 1, lokale A/07–A/10", "Pomiary wylewek")]),
    ("termo", "Kamera termowizyjna TK-160", "Pomiary", "BT-EQ-005", "TK160-5522-DEMO", -150, [
        ("issue", -15, "B", _person("domanski"), "3. piętro — serwerownia 3.12", "Pomiary złączy w RPS")]),
    ("mlotowiertarka", "Młotowiertarka SDS-Max 8 kg", "Elektronarzędzia", "BT-EQ-006", "SDS8-8812-DEMO", -210, [
        ("issue", -70, "A", _company("elektro"), "Budynek A — parter", "Przebicia pod trasy kablowe"),
        ("return", -50, "good", None),
        ("issue", -10, "A", _company("aquaterm"), "Pomieszczenie techniczne 0.18", "Przejścia instalacyjne")]),
    ("tablet", "Tablet budowlany #1", "IT", "BT-EQ-007", "TAB1-0007-DEMO", -100, [
        ("issue", -80, "A", _person("sadowski"), "Inspektor nadzoru", "Odbiory z aplikacją B Technica")]),
    ("dalmierz", "Dalmierz laserowy 80 m", "Pomiary", "BT-EQ-008", "DL80-4410-DEMO", -120, [
        ("issue", -40, "B", _person("zajac"), "3. piętro", "Inwentaryzacja pomieszczeń"),
        ("return", -5, "good", None)]),
    ("agregat", "Agregat prądotwórczy 5 kVA", "Zasilanie", "BT-EQ-009", "AG5-2210-DEMO", -220, [
        ("issue", -200, "A", _text("Brygada ogólnobudowlana GW"), "Zaplecze budowy", "Zasilanie tymczasowe"),
        ("return", -150, "good", "Podłączono przyłącze budowlane")]),
    ("detektor", "Detektor przewodów i zbrojenia", "Pomiary", "BT-EQ-010", "DET-6620-DEMO", -90, [
        ("issue", -60, "A", _person("kubiak"), "Budynek A — strop nad parterem", "Lokalizacja zbrojenia"),
        ("return", -58, "good", None),
        ("issue", -25, "B", _person("zajac"), "3. piętro — strop", "Przebicia pod koryta"),
        ("return", -24, "good", None)]),
]


def _equipment_records():
    out = []
    for key, name, category, ident, serial, created, actions in EQUIPMENT:
        acts = []
        for a in actions:
            if a[0] == "issue":
                _, day, proj, recipient, location, notes = a
                acts.append({"kind": "issue", "dayOffset": day, "projectId": uid(f"project/{proj}"),
                             "location": location, "notes": notes, **recipient})
            else:
                _, day, condition, notes = a
                acts.append({"kind": "return", "dayOffset": day, "condition": condition, "notes": notes})
        out.append({"id": uid(f"equipment/{key}"), "name": name, "category": category, "identifier": ident,
                    "serialNumber": serial, "notes": "Sprzęt demonstracyjny (dane fikcyjne).",
                    "createdDayOffset": created, "actions": acts})
    return out


# ------------------------------------------------------------------------------------
# Project A — Osiedle Zielone Tarasy — Etap I
# ------------------------------------------------------------------------------------

FOLDERS_A = [
    ("arch", None, "Architektura", 0), ("arch_rzuty", "arch", "Rzuty", 0), ("arch_przekroje", "arch", "Przekroje", 1),
    ("arch_elewacje", "arch", "Elewacje", 2), ("arch_detale", "arch", "Detale", 3),
    ("konstrukcja", None, "Konstrukcja", 1), ("sanitarne", None, "Instalacje sanitarne", 2),
    ("elektryczne", None, "Instalacje elektryczne", 3), ("teren", None, "Zagospodarowanie terenu", 4),
]

REV_A = [("A", "Wydanie do realizacji", "2026-02-16")]


def _rev(*extra):
    return REV_A + list(extra)


DRAWINGS_A = [
    dict(key="z001", number="Z-001", title="Plan zagospodarowania terenu", subtitle="Etap I — budynki A i B, garaż",
         folder="teren", sheet=S.sheet_site, scale="1:500", revision="B", discipline="Zagospodarowanie terenu",
         location="Działka 123/4", date="2026-03-02", revisions=_rev(("B", "Korekta miejsc dla gości", "2026-03-02")),
         calibration=(0, (100.0, 80.0), (140.0, 80.0), 40.0)),
    dict(key="a100", number="A-100", title="Rzut garażu podziemnego", subtitle="Poziom -1 · hala garażowa",
         folder="arch_rzuty", sheet=S.sheet_garage, scale="1:200", revision="B", discipline="Architektura",
         location="Garaż podziemny, poziom -1", date="2026-03-20",
         revisions=_rev(("B", "Numeracja miejsc postojowych", "2026-03-20")),
         calibration=(0, (0.0, -19.0), (36.0, -19.0), 36.0)),
    dict(key="a101", number="A-101", title="Rzut parteru", subtitle="Budynek A · kondygnacja ±0,00",
         folder="arch_rzuty", sheet=S.sheet_ground_floor, scale="1:100", revision="C", discipline="Architektura",
         location="Budynek A, parter", date="2026-05-12",
         revisions=_rev(("B", "Korekta drzwi do lokali", "2026-04-02"), ("C", "Wymiary otworów drzwiowych", "2026-05-12")),
         calibration=(0, (0.0, -2.0), (36.0, -2.0), 36.0)),
    dict(key="a102", number="A-102", title="Rzut piętra typowego", subtitle="Budynek A · kondygnacje +1 do +3",
         folder="arch_rzuty", sheet=S.sheet_typical_floor, scale="1:100", revision="B", discipline="Architektura",
         location="Budynek A, piętra 1–3", date="2026-04-24",
         revisions=_rev(("B", "Balustrady i progi balkonów", "2026-04-24")),
         calibration=(0, (0.0, -2.0), (36.0, -2.0), 36.0)),
    dict(key="a201", number="A-201", title="Przekrój A-A", subtitle="Budynek A z garażem podziemnym",
         folder="arch_przekroje", sheet=S.sheet_section, scale="1:100", revision="A", discipline="Architektura",
         location="Budynek A, oś 3/4", date="2026-02-16", revisions=REV_A, calibration=None),
    dict(key="a301", number="A-301", title="Elewacja południowa", subtitle="Budynek A · od strony dziedzińca",
         folder="arch_elewacje", sheet=S.sheet_elevation, scale="1:100", revision="B", discipline="Architektura",
         location="Budynek A, elewacja S", date="2026-04-08",
         revisions=_rev(("B", "Kolorystyka elewacji", "2026-04-08")), calibration=None),
    dict(key="a501", number="A-501", title="Detal D-1 — próg drzwi balkonowych", subtitle="Przekrój pionowy",
         folder="arch_detale", sheet=S.sheet_detail, scale="1:5", revision="B", discipline="Architektura",
         location="Balkony lokali, piętra 1–3", date="2026-04-24",
         revisions=_rev(("B", "Wywinięcie hydroizolacji min. 15 cm", "2026-04-24")), calibration=None),
    dict(key="k101", number="K-101", title="Rzut stropu nad parterem", subtitle="Konstrukcja · strop płytowy gr. 22 cm",
         folder="konstrukcja", sheet=S.sheet_structure, scale="1:100", revision="B", discipline="Konstrukcja",
         location="Budynek A, strop +3,00", date="2026-03-11",
         revisions=_rev(("B", "Otwory pod piony K1–K8", "2026-03-11")), author="inż. K. Nowicki",
         checker="arch. J. Czarnecka", calibration=(0, (0.0, -2.0), (36.0, -2.0), 36.0)),
    dict(key="s101", number="S-101", title="Instalacje wod.-kan. — rzut parteru", subtitle="Woda, c.w.u., cyrkulacja, kanalizacja",
         folder="sanitarne", sheet=S.sheet_sanitary, scale="1:100", revision="B", discipline="Instalacje sanitarne",
         location="Budynek A, parter", date="2026-03-27",
         revisions=_rev(("B", "Przejścia przez ścianę EI60", "2026-03-27")), author="inż. E. Jabłońska",
         checker="inż. K. Nowicki", calibration=None),
    dict(key="s201", number="S-201", title="Wentylacja mechaniczna — rzut parteru", subtitle="Kanały, klapy KPP, koordynacja",
         folder="sanitarne", sheet=S.sheet_ventilation, scale="1:100", revision="A", discipline="Wentylacja i klimatyzacja",
         location="Budynek A, parter", date="2026-03-27", revisions=REV_A, author="inż. E. Jabłońska",
         checker="inż. K. Nowicki", calibration=None),
    dict(key="e101", number="E-101", title="Instalacje elektryczne — rzut parteru",
         subtitle="Arkusz 1: oświetlenie · arkusz 2: gniazda i tablice",
         folder="elektryczne", sheet=None, scale="1:100", revision="B", discipline="Instalacje elektryczne",
         location="Budynek A, parter", date="2026-04-15",
         revisions=_rev(("B", "Oświetlenie awaryjne klatki A", "2026-04-15")), author="inż. M. Domański",
         checker="inż. K. Nowicki", calibration=None),
]

POLY_A101 = S.building_polygons("ground")
POLY_A102 = S.building_polygons("typical")
POLY_A100 = S.garage_polygons()
POLY_Z001 = S.site_polygons()

AREAS_A = [
    ("building_ground", "a101", 0, "Budynek A — Parter", POLY_A101["building"], "#007AFF", 0.12),
    ("staircase", "a101", 0, "Klatka schodowa A", POLY_A101["staircase"], "#FF9500", 0.30),
    ("building_floor1", "a102", 0, "Budynek A — Piętro 1", POLY_A102["building"], "#007AFF", 0.12),
    ("unit_a12", "a102", 0, "Lokal A/12", POLY_A102["A/12"], "#34C759", 0.30),
    ("unit_a08", "a102", 0, "Lokal A/08 z balkonem", POLY_A102["A/08 with balcony"], "#AF52DE", 0.30),
    ("garage_hall", "a100", 0, "Garaż podziemny — hala postojowa", POLY_A100["hall"], "#5AC8FA", 0.20),
    ("tech_zone", "s101", 0, "Strefa instalacyjna — pom. techniczne 0.18", POLY_A101["tech_room"], "#FF3B30", 0.30),
    ("ramp_zone", "z001", 0, "Strefa wjazdu do garażu", POLY_Z001["ramp_zone"], "#FF9500", 0.30),
]

# key, drawing, page, (x, y) world, title, details, status, discipline, contractor, day, minute, area, attachments
ISSUES_A = [
    ("a101_door", "a101", 0, (13.05, 5.4), "Niezgodne wymiary otworu drzwiowego — lokal A/02",
     "Szerokość otworu w świetle ościeżnicy 86 cm zamiast projektowanych 90 cm (A-101 rew. C). "
     "Korekta przed montażem drzwi EI30.", "open", "Architektura", "gw", -21, 9 * 60 + 40, None, []),
    ("a101_lintel", "a101", 0, (23.25, 11.95), "Uszkodzona krawędź nadproża okna — lokal A/05",
     "Odspojenie otuliny i odsłonięte zbrojenie na długości ok. 30 cm, rysa ukośna nad oknem. "
     "Naprawa zaprawą PCC po oczyszczeniu zbrojenia.", "inProgress", "Konstrukcja", "betonex", -15, 11 * 60 + 5,
     None, [("lintel_crack", 0)]),
    ("a101_paint", "a101", 0, (30.5, 6.9), "Uszkodzenie powłoki malarskiej w korytarzu 0.23",
     "Zarysowania i odpryski farby na ścianie korytarza na długości ok. 1,2 m po transporcie materiałów.",
     "open", "Roboty wykończeniowe", "prodom", -4, 14 * 60 + 20, "building_ground", [("paint_damage", 0)]),
    ("a101_plaster", "a101", 0, (1.75, 0.8), "Rysa na tynku przy ościeżu okna — lokal A/01",
     "Rysa skurczowa przy narożniku ościeża. Naprawiono siatką i masą szpachlową.", "closed",
     "Roboty wykończeniowe", "gw", -48, 10 * 60 + 15, None, []),
    ("a101_bikes", "a101", 0, (3.1, 8.2), "Brak odbojnicy przy drzwiach wózkowni",
     "Ściana przy drzwiach wózkowni 0.17 narażona na uszkodzenia. Zamontowano odbojnicę stalową.", "resolved",
     "Architektura", "gw", -9, 8 * 60 + 50, None, []),
    ("a101_entrance", "a101", 0, (20.85, 11.95), "Nieszczelność drzwi wejściowych do klatki A",
     "Przedmuchy na uszczelce przylgowej, drzwi wymagają regulacji samozamykacza i docisku.", "inProgress",
     "Architektura", "lumen", -12, 13 * 60 + 30, None, []),
    ("a101_exit_sign", "a101", 0, (16.2, 9.0), "Brak oznakowania drogi ewakuacyjnej na klatce A",
     "Brak znaków ewakuacyjnych na biegu schodów i przy wyjściu. Uzupełniono znaki fotoluminescencyjne.",
     "resolved", "BHP", "gw", -30, 7 * 60 + 55, "staircase", []),

    ("a102_balcony", "a102", 0, (15.25, 0.25), "Brak izolacji przeciwwilgociowej przy progu balkonowym — lokal A/08",
     "Hydroizolacja podpłytkowa zakończona na poziomie progu, brak wywinięcia min. 15 cm na ościeże "
     "(detal D-1, ST-04). Ryzyko zawilgocenia wylewki w pokoju dziennym.", "open", "Architektura", "gw", -6,
     10 * 60 + 10, "unit_a08", [("balcony_threshold", 0), ("balcony_threshold", 1)]),
    ("a102_drain", "a102", 0, (8.0, 8.3), "Nieprawidłowo zamontowany wpust podłogowy — łazienka lokalu A/12",
     "Korpus wpustu przechylony, kratka powyżej poziomu płytek. Brak kołnierza wklejonego w hydroizolację.",
     "inProgress", "Instalacje sanitarne", "aquaterm", -4, 9 * 60 + 25, "unit_a12", [("floor_drain", 0)]),
    ("a102_tile", "a102", 0, (8.9, 9.25), "Pęknięta płytka ścienna w łazience lokalu A/12",
     "Pęknięcie płytki w strefie natrysku, prawdopodobnie pustka pod płytką. Do wymiany.", "open",
     "Roboty wykończeniowe", "prodom", -3, 15 * 60 + 0, "unit_a12", []),
    ("a102_slope", "a102", 0, (24.6, -0.75), "Brak spadku posadzki balkonu — lokal A/09",
     "Po próbie wodnej zastoisko wody przy balustradzie. Spadek poniżej 1,5%.", "open", "Architektura", "gw", -10,
     12 * 60 + 45, None, []),
    ("a102_glass", "a102", 0, (30.45, 11.95), "Uszkodzona szyba w oknie pokoju — lokal A/14",
     "Rysa na szybie zewnętrznej pakietu. Zamówiono nowy pakiet szybowy.", "inProgress", "Architektura", "lumen", -14,
     8 * 60 + 35, None, []),
    ("a102_screed", "a102", 0, (5.2, 10.4), "Brak dylatacji obwodowej wylewki — lokal A/11",
     "Wylewka przylega bezpośrednio do ścian. Wykonano nacięcia i wypełnienie dylatacji.", "closed",
     "Roboty wykończeniowe", "prodom", -40, 11 * 60 + 20, None, []),
    ("a102_railing", "a102", 0, (6.6, -1.3), "Niedokręcona balustrada balkonu — lokal A/07",
     "Luz na dwóch mocowaniach balustrady szklanej. Dokręcono i zabezpieczono.", "resolved", "BHP", "lumen", -19,
     14 * 60 + 5, None, []),

    ("a100_crack", "a100", 0, (12.9, -4.4), "Zarysowanie posadzki żywicznej przy słupie 3/B",
     "Rysa długości ok. 1,5 m, rozwartość do 0,3 mm. Do oceny projektanta konstrukcji.", "open", "Konstrukcja",
     "betonex", -11, 10 * 60 + 0, "garage_hall", []),
    ("a100_marking", "a100", 0, (20.0, -1.1), "Brak oznakowania miejsc postojowych P17–P24",
     "Linie i numeracja miejsc niewykonane po naprawie posadzki.", "inProgress", "Roboty wykończeniowe", "gw", -18,
     13 * 60 + 10, "garage_hall", []),
    ("a100_leak", "a100", 0, (-1.5, 4.4), "Przeciek przez dylatację stropu nad garażem",
     "Ślady przecieku na stropie po opadach. Do sprawdzenia taśma dylatacyjna w stropodachu dziedzińca.", "open",
     "Konstrukcja", "betonex", -7, 9 * 60 + 5, "garage_hall", []),
    ("a100_column", "a100", 0, (36.7, -4.3), "Uszkodzona krawędź słupa przy wjeździe na rampę",
     "Obicie krawędzi słupa przez pojazd. Naprawiono i zamontowano osłonę narożnika.", "resolved", "Konstrukcja",
     "betonex", -33, 16 * 60 + 0, None, []),

    ("k101_rebar", "k101", 0, (8.0, 0.3), "Odsłonięte zbrojenie w wieńcu stropu — oś A/2–3",
     "Raki i odsłonięte strzemiona wieńca po rozdeskowaniu. Naprawiono zaprawą PCC.", "closed", "Konstrukcja",
     "betonex", -150, 10 * 60 + 30, None, []),
    ("k101_opening", "k101", 0, (8.95, 8.1), "Otwór w stropie pod pion K6 przesunięty względem projektu",
     "Otwór pod pion kanalizacyjny lokalu A/12 wykonany ok. 20 cm od lokalizacji projektowej. "
     "Do decyzji projektanta: poszerzenie otworu lub korekta trasy pionu.", "open", "Konstrukcja", "betonex", -26,
     11 * 60 + 40, None, []),

    ("s101_seal", "s101", 0, (11.2, 7.9), "Brak uszczelnienia przejścia instalacyjnego przez ścianę EI60",
     "Trzy przejścia rur z pomieszczenia technicznego do korytarza bez uszczelnień ogniochronnych "
     "(notatka z narady nr 14, pkt 14.3).", "open", "Instalacje sanitarne", "aquaterm", -9, 10 * 60 + 50,
     "tech_zone", []),
    ("s101_insulation", "s101", 0, (12.5, 10.3), "Brak izolacji termicznej rur c.w.u. w pomieszczeniu technicznym",
     "Odcinek ok. 2 m rury c.w.u. przy zasobniku bez otuliny.", "inProgress", "Instalacje sanitarne", "aquaterm", -8,
     12 * 60 + 15, "tech_zone", []),
    ("s101_riser", "s101", 0, (11.6, 5.0), "Kolizja pionu kanalizacyjnego PK2 z nadprożem",
     "Pion PK2 kolidował z nadprożem drzwi łazienki. Zmieniono trasę odejścia.", "resolved",
     "Instalacje sanitarne", "aquaterm", -16, 9 * 60 + 35, None, []),

    ("s201_collision", "s201", 0, (23.5, 6.25), "Kolizja przewodu wentylacyjnego z instalacją elektryczną",
     "Kanał nawiewny 400×200 koliduje z korytem kablowym 200×60 w osi 5. Ustalenie 14.1: obniżenie koryta o 15 cm.",
     "open", "Wentylacja i klimatyzacja", "aquaterm", -5, 11 * 60 + 0, None, [("duct_collision", 0)]),
    ("s201_damper", "s201", 0, (22.05, 5.55), "Brak klapy przeciwpożarowej na przejściu do lokalu A/03",
     "Przejście kanału Ø125 przez ścianę korytarza bez klapy KPP.", "inProgress", "Wentylacja i klimatyzacja",
     "aquaterm", -12, 14 * 60 + 40, None, []),

    ("e101_emergency", "e101", 0, (16.2, 10.0), "Brak opraw oświetlenia awaryjnego na klatce schodowej A",
     "Wynik negatywny w protokole PE-01. Oprawy AW do montażu przed odbiorem.", "open", "Instalacje elektryczne",
     "elektro", -2, 10 * 60 + 25, None, []),
    ("e101_switch", "e101", 0, (21.62, 4.85), "Niezgodna wysokość montażu łącznika — lokal A/03",
     "Łącznik zamontowany na wysokości 1,40 m zamiast 1,10 m. Przełożono.", "closed", "Instalacje elektryczne",
     "elektro", -35, 13 * 60 + 15, None, []),
    ("e101_labels", "e101", 1, (8.0, 8.8), "Brak oznaczenia przewodów w rozdzielnicy RG",
     "Przewody odpływowe bez oznaczeń, brak aktualnego schematu w drzwiach rozdzielnicy (PE-01, pkt 3).",
     "inProgress", "Instalacje elektryczne", "elektro", -2, 11 * 60 + 30, None, [("switchboard", 0)]),
    ("e101_ip44", "e101", 1, (2.04, 4.05), "Gniazdo w łazience lokalu A/01 bez klasy szczelności IP44",
     "Zamontowano gniazdo IP20 w strefie łazienki. Do wymiany na IP44.", "open", "Instalacje elektryczne", "elektro",
     -2, 11 * 60 + 45, None, []),

    ("a301_etics", "a301", 0, (27.4, 7.5), "Ubytki w warstwie zbrojonej ocieplenia — oś 5–6",
     "Odsłonięte płyty EPS i brak siatki na powierzchni ok. 1 m². Uzupełnić przed tynkowaniem.", "open",
     "Architektura", "lumen", -6, 12 * 60 + 0, None, [("facade", 0)]),
    ("a301_sill", "a301", 0, (10.75, 6.85), "Brak obróbki blacharskiej parapetu — okno lokalu A/16",
     "Parapet zewnętrzny niezamontowany, woda spływa po ociepleniu.", "inProgress", "Architektura", "lumen", -13,
     10 * 60 + 20, None, []),

    ("z001_curb", "z001", 0, (79.0, 41.0), "Uszkodzony krawężnik przy zjeździe do garażu",
     "Pęknięty i przesunięty krawężnik na łuku drogi przy rampie.", "open", "Zagospodarowanie terenu", "zielen", -8,
     15 * 60 + 10, "ramp_zone", []),
    ("z001_excavation", "z001", 0, (10.0, 49.2), "Brak zabezpieczenia wykopu przy przyłączu wod.-kan.",
     "Wykop głębokości ok. 1,6 m bez barier i oznakowania. Zabezpieczono barierami.", "resolved", "BHP", "gw", -60,
     8 * 60 + 10, None, []),

    ("a201_attic", "a201", 0, (12.45, 12.9), "Niezgodna wysokość attyki z projektem",
     "Attyka od strony północnej niższa o ok. 6 cm od rzędnej +13,20. Do decyzji projektanta.", "open",
     "Architektura", "gw", -20, 9 * 60 + 15, None, []),
    ("a501_upturn", "a501", 0, (0.592, 0.44), "Hydroizolacja wywinięta poniżej 15 cm — próg balkonowy",
     "Wywinięcie hydroizolacji ok. 8 cm w lokalach A/08 i A/16. Wymagane min. 15 cm wg detalu D-1.", "inProgress",
     "Architektura", "gw", -6, 10 * 60 + 30, None, []),
]

ALBUMS_A = [("progress", "Postęp robót", 0), ("defects", "Usterki", 1), ("garage", "Garaż podziemny", 2),
            ("mep", "Instalacje", 3)]

# scene, variant, album, title, description, day, minute, drawing, page, area, issue
PHOTOS_A = [
    ("excavation", 0, "progress", "Wykop i ścianka berlińska — strona wschodnia",
     "Zabezpieczenie wykopu przed rozpoczęciem płyty fundamentowej.", -290, 11 * 60, None, None, None, None),
    ("formwork", 0, "progress", "Zbrojenie płyty fundamentowej",
     "Stan przed betonowaniem — odbiór zbrojenia przez inspektora nadzoru.", -240, 9 * 60 + 30, None, None, None, None),
    ("formwork", 1, "progress", "Zbrojenie stropu nad parterem",
     "Kontrola otuliny i rozstawu prętów przed betonowaniem stropu.", -170, 10 * 60, "k101", 0, None, None),
    ("site", 0, "progress", "Widok ogólny — konstrukcja dwóch kondygnacji",
     "Stan robót od strony dziedzińca.", -150, 12 * 60, None, None, None, None),
    ("site", 1, "progress", "Widok ogólny — konstrukcja zakończona",
     "Żuraw przed demontażem, rozpoczęte ścianki działowe.", -110, 12 * 60 + 30, None, None, None, None),
    ("masonry", 0, "progress", "Ścianki działowe — piętro 1",
     "Murowanie ścianek z bloczków silikatowych 12 cm.", -95, 9 * 60, "a102", 0, "building_floor1", None),
    ("staircase", 0, "progress", "Klatka schodowa A — biegi po montażu",
     "Schody prefabrykowane, przed montażem balustrad.", -60, 13 * 60, "a101", 0, "staircase", None),
    ("site", 2, "progress", "Widok ogólny od strony dziedzińca",
     "Aktualny stan budowy: elewacja w trakcie, instalacje wewnętrzne.", -3, 15 * 60, None, None, None, None),
    ("pipe_penetration", 0, "defects", "Nieuszczelnione przejście rury przez ścianę EI60",
     "Pomieszczenie techniczne 0.18, ściana od strony korytarza.", -9, 10 * 60 + 52, "s101", 0, "tech_zone",
     "s101_seal"),
    ("tech_room", 0, "defects", "Rura c.w.u. bez izolacji termicznej",
     "Odcinek przy zasobniku c.w.u.", -8, 12 * 60 + 17, "s101", 0, "tech_zone", "s101_insulation"),
    ("door_opening", 0, "defects", "Pomiar szerokości otworu drzwiowego — lokal A/02",
     "Szerokość w świetle 86 cm (projekt: 90 cm).", -21, 9 * 60 + 42, "a101", 0, None, "a101_door"),
    ("lintel_crack", 1, "defects", "Nadproże okna lokalu A/05 — widok ogólny",
     "Zakres uszkodzenia przed naprawą.", -15, 11 * 60 + 8, "a101", 0, None, "a101_lintel"),
    ("facade", 1, "defects", "Elewacja — ubytki warstwy zbrojonej (oś 5–6)",
     "Widok z rusztowania, poziom piętra 2.", -6, 12 * 60 + 3, "a301", 0, None, "a301_etics"),
    ("garage", 0, "defects", "Zarysowanie posadzki przy słupie 3/B",
     "Rysa w posadzce żywicznej, widok w kierunku rampy.", -11, 10 * 60 + 2, "a100", 0, "garage_hall", "a100_crack"),
    ("garage", 1, "garage", "Hala garażowa — oznakowanie w trakcie",
     "Malowanie linii miejsc postojowych.", -18, 13 * 60 + 12, "a100", 0, "garage_hall", None),
    ("pipe_penetration", 1, "garage", "Przejścia instalacyjne — ściana pompowni",
     "Przejścia rur przez ścianę pompowni -1.02.", -25, 14 * 60, "a100", 0, None, None),
    ("switchboard", 1, "mep", "Rozdzielnica RG — opisy częściowo uzupełnione",
     "Stan po pierwszej części opisów obwodów.", -2, 11 * 60 + 35, "e101", 1, None, "e101_labels"),
    ("duct_collision", 1, "mep", "Kolizja kanału wentylacyjnego z korytem kablowym",
     "Widok od dołu, korytarz parteru w osi 5.", -5, 11 * 60 + 2, "s201", 0, None, "s201_collision"),
    ("tech_room", 1, "mep", "Węzeł cieplny — stan montażu",
     "Montaż armatury i zasobnika c.w.u.", -30, 10 * 60 + 40, "s101", 0, "tech_zone", None),
    ("floor_drain", 1, "mep", "Wpust podłogowy w łazience lokalu A/12",
     "Widok po ułożeniu płytek.", -4, 9 * 60 + 27, "a102", 0, "unit_a12", "a102_drain"),
]

# Schedule — offsets in days relative to the seed day ("today").
PHASES_A = [("ziemne", "Roboty ziemne", "#7A8794"), ("konstrukcja", "Konstrukcja", "#1C7AE6"),
            ("sso", "Stan surowy", "#8E5BD6"), ("instalacje", "Instalacje", "#E08A1E"),
            ("wykonczenia", "Wykończenia", "#2E9E5B"), ("odbiory", "Odbiory", "#D6455D")]

# key, phase, kind, title, start, finish, progress, status, responsible(contractor key), predecessors
TASKS_A = [
    ("t01", "ziemne", "task", "Zabezpieczenie wykopu — ścianka berlińska", -305, -291, 100, "completed", "gw", []),
    ("t02", "ziemne", "task", "Wykopy szerokoprzestrzenne i odwóz urobku", -290, -268, 100, "completed", "gw", ["t01"]),
    ("m01", "ziemne", "milestone", "Odbiór geotechniczny dna wykopu", -266, -266, 100, "completed", "gw", ["t02"]),
    ("t03", "konstrukcja", "task", "Płyta fundamentowa i ściany garażu", -262, -215, 100, "completed", "betonex", ["m01"]),
    ("t04", "konstrukcja", "task", "Strop nad garażem (dach zielony)", -214, -196, 100, "completed", "betonex", ["t03"]),
    ("t05", "konstrukcja", "task", "Konstrukcja kondygnacji 0–3 (ściany i stropy)", -194, -118, 100, "completed",
     "betonex", ["t04"]),
    ("m02", "konstrukcja", "milestone", "Zakończenie konstrukcji stanu surowego", -116, -116, 100, "completed", "betonex",
     ["t05"]),
    ("t06", "sso", "task", "Ściany działowe — silikat 12 cm", -130, -70, 100, "completed", "gw", []),
    ("t07", "sso", "task", "Dach — stropodach i attyka", -112, -84, 100, "completed", "gw", ["m02"]),
    ("t08", "sso", "task", "Stolarka okienna i drzwi balkonowe", -95, -40, 100, "completed", "lumen", []),
    ("m03", "sso", "milestone", "Stan surowy zamknięty", -38, -38, 100, "completed", "gw", ["t08"]),
    ("t09", "instalacje", "task", "Instalacje wod.-kan. — piony i poziomy", -88, 12, 85, "inProgress", "aquaterm", []),
    ("t10", "instalacje", "task", "Instalacje elektryczne — okablowanie lokali", -75, 18, 72, "inProgress", "elektro", []),
    ("t11", "instalacje", "task", "Wentylacja mechaniczna — kanały i centrala", -45, 20, 40, "delayed", "aquaterm", []),
    ("t12", "instalacje", "task", "Instalacje teletechniczne i domofonowe", 20, 42, 0, "planned", "elektro", ["t10"]),
    ("t13", "wykonczenia", "task", "Tynki wewnętrzne gipsowe", -50, 14, 70, "inProgress", "prodom", ["t06"]),
    ("t14", "wykonczenia", "task", "Wylewki posadzkowe", -24, 26, 30, "inProgress", "prodom", []),
    ("t15", "wykonczenia", "task", "Elewacja — ocieplenie ETICS i tynk", -32, 48, 20, "delayed", "lumen", []),
    ("t16", "wykonczenia", "task", "Malowanie, okładziny i biały montaż", 28, 76, 0, "planned", "prodom", ["t13", "t14"]),
    ("t17", "odbiory", "task", "Odbiory branżowe instalacji", 62, 80, 0, "planned", "gw", ["t09", "t11", "t12"]),
    ("t18", "odbiory", "task", "Zagospodarowanie terenu i plac zabaw", 40, 88, 0, "planned", "zielen", []),
    ("m04", "odbiory", "milestone", "Odbiór końcowy budynku A", 95, 95, 0, "planned", "gw", ["t15", "t16", "t17", "t18"]),
    ("t19", "odbiory", "task", "Przekazanie lokali nabywcom", 100, 125, 0, "planned", "gw", ["m04"]),
]

DOC_FOLDERS_A = [("spec", "Specyfikacje techniczne", 0), ("protocols", "Protokoły i notatki", 1), ("bhp", "BHP", 2)]

# key (documents.DOCUMENTS), folder, display name, category, description, revision, revision date, uploaded day
DOCUMENTS_A = [
    ("st04_hydroizolacja", "spec", "ST-04 Roboty hydroizolacyjne", "technical_specification",
     "Balkony, tarasy, progi i łazienki — wymagania wykonania i odbioru.", "B", "2026-03-18", -200),
    ("st02_beton", "spec", "ST-02 Beton konstrukcyjny", "material_specification",
     "Klasy betonu, otuliny, pielęgnacja i badania.", "A", "2026-02-16", -280),
    ("n14_narada", "protocols", "Notatka z narady koordynacyjnej nr 14", "construction_documentation",
     "Kolizje instalacji w korytarzach, przejścia EI60, opisy RG.", None, None, -5),
    ("lk03_odbior", "protocols", "LK-03 Lista kontrolna odbioru wykończeń", "construction_instruction",
     "Odbiory wewnętrzne lokali przed przekazaniem nabywcom.", "A", "2026-09-01", -45),
    ("bhp02_wysokosc", "bhp", "BHP-02 Prace na wysokości i rusztowaniach", "construction_instruction",
     "Instrukcja dla pracowników GW i podwykonawców.", "A", "2026-01-20", -300),
    ("pe01_elektryka", "protocols", "PE-01 Protokół przeglądu instalacji elektrycznej", "construction_documentation",
     "Parter budynku A — przegląd przed zamknięciem sufitów.", None, None, -2),
]

NOTES_A = [
    ("Narada nr 14 — ustalenia dla korytarza parteru", "meeting", -5,
     "Obniżenie koryta kablowego w osi 5 o 15 cm (Elektro-Volt). Klapy KPP przed zamknięciem sufitów (AquaTerm). "
     "Uszczelnienia przejść EI60 w pom. 0.18 w ciągu 10 dni."),
    ("Pomiar wilgotności wylewek — lokale A/07–A/10", "measurement", -3,
     "Metoda CM: A/07 1,8%, A/08 2,4%, A/09 1,9%, A/10 2,1%. Wymagane maks. 2,0% pod parkiet — A/08 i A/10 do "
     "ponownego pomiaru za 7 dni."),
    ("Przegląd balkonów — piętro 1", "inspection", -6,
     "Próba wodna: A/08 przeciek przy progu (usterka zgłoszona), A/09 zastoisko przy balustradzie. Pozostałe bez uwag."),
    ("Polecenie KB — zabezpieczenie otworów w stropach", "instruction", -27,
     "Wszystkie otwory pod piony K1–K8 przykryć płytą OSB z oznakowaniem do czasu montażu pionów. Odpowiedzialny: "
     "brygadzista GW."),
]

# ------------------------------------------------------------------------------------
# Project B — Modernizacja Biurowca — Centrum
# ------------------------------------------------------------------------------------

FOLDERS_B = [("arch", None, "Architektura", 0), ("instalacje", None, "Instalacje", 1)]

REV_B = [("A", "Projekt aranżacji", "2026-08-21")]

DRAWINGS_B = [
    dict(key="b301", number="B-A-301", title="Rzut 3. piętra — stan projektowany", subtitle="Aranżacja wnętrz",
         folder="arch", sheet=S.sheet_office_arch, scale="1:100", revision="A", discipline="Architektura",
         location="Biurowiec Centrum, 3. piętro", date="2026-08-21", revisions=REV_B, author="Studio wnętrz (fikcyjne)",
         checker="arch. J. Czarnecka", calibration=(0, (0.0, -1.6), (30.0, -1.6), 30.0)),
    dict(key="be301", number="B-E-301", title="Instalacje elektryczne i teletechniczne — 3. piętro",
         subtitle="Oświetlenie, puszki podłogowe, serwerownia", folder="instalacje", sheet=S.sheet_office_electrical,
         scale="1:100", revision="A", discipline="Instalacje elektryczne", location="Biurowiec Centrum, 3. piętro",
         date="2026-08-28", revisions=REV_B, author="inż. M. Domański", checker="inż. K. Nowicki", calibration=None),
    dict(key="bh301", number="B-H-301", title="Instalacje HVAC — 3. piętro", subtitle="Klimakonwektory, VRF, świeże powietrze",
         folder="instalacje", sheet=S.sheet_office_hvac, scale="1:100", revision="A",
         discipline="Wentylacja i klimatyzacja", location="Biurowiec Centrum, 3. piętro", date="2026-08-28",
         revisions=REV_B, author="inż. E. Jabłońska", checker="inż. K. Nowicki", calibration=None),
]

POLY_OFFICE = S.office_polygons()

AREAS_B = [
    ("open_west", "b301", 0, "Open space — strefa zachodnia", POLY_OFFICE["open_west"], "#5AC8FA", 0.20),
    ("server", "be301", 0, "Serwerownia 3.12", POLY_OFFICE["server"], "#FF3B30", 0.30),
]

ISSUES_B = [
    ("b_cable_seal", "be301", 0, (23.4, 9.8), "Brak uszczelnienia przejścia kablowego do serwerowni",
     "Przejście koryta przez ścianę serwerowni bez uszczelnienia ogniochronnego EI60.", "open",
     "Instalacje elektryczne", "elektro", -6, 10 * 60 + 15, "server", []),
    ("b_tray_duct", "bh301", 0, (22.0, 12.15), "Kolizja trasy kablowej z kanałem świeżego powietrza nad salą 3.05",
     "Koryto kablowe przechodzi pod kanałem 500×250 — brak miejsca na montaż sufitu.", "inProgress",
     "Wentylacja i klimatyzacja", "aquaterm", -9, 11 * 60 + 40, None, []),
    ("b_ceiling", "b301", 0, (6.0, 10.0), "Uszkodzona płyta sufitu podwieszanego",
     "Pęknięta płyta 60×60 po montażu instalacji nad sufitem.", "open", "Roboty wykończeniowe", "modulo", -4,
     9 * 60 + 5, "open_west", [("office", 1)]),
    ("b_server_door", "b301", 0, (24.45, 5.6), "Drzwi do serwerowni bez klasy EI30",
     "Zamontowano drzwi bez klasy odporności ogniowej, wymagane EI30 (PFU, pkt 2).", "open", "Architektura", "modulo",
     -3, 14 * 60 + 25, None, []),
    ("b_raised_floor", "b301", 0, (6.6, 5.9), "Niewypoziomowana podłoga podniesiona przy słupie B/2",
     "Różnica poziomów płyt do 4 mm. Wyregulowano wsporniki.", "resolved", "Roboty wykończeniowe", "modulo", -15,
     16 * 60 + 0, "open_west", []),
    ("b_condensate", "bh301", 0, (26.0, 6.25), "Brak podłączenia odpływu skroplin klimatyzatora",
     "Odpływ skroplin z klimatyzacji precyzyjnej niepodłączony do pionu.", "inProgress", "Wentylacja i klimatyzacja",
     "aquaterm", -5, 10 * 60 + 55, None, []),
    ("b_exit_signs", "b301", 0, (12.6, 12.6), "Niezgodne oznakowanie ewakuacyjne przy klatce",
     "Kierunek strzałek niezgodny z planem ewakuacji. Poprawiono.", "closed", "BHP", "modulo", -20, 12 * 60 + 0,
     None, []),
    ("b_floor_boxes", "be301", 0, (8.2, 6.2), "Puszki podłogowe bez oznaczenia obwodów",
     "Brak oznaczeń obwodów na puszkach podłogowych w strefie zachodniej.", "open", "Instalacje elektryczne", "elektro",
     -2, 13 * 60 + 35, None, []),
]

ALBUMS_B = [("progress", "Postęp prac — 3. piętro", 0), ("defects", "Usterki", 1)]

PHOTOS_B = [
    ("office", 0, "progress", "Instalacje nad sufitem — strefa zachodnia",
     "Przewody przed zamknięciem sufitu podwieszanego.", -12, 10 * 60, "b301", 0, "open_west", None),
    ("server_room", 0, "defects", "Serwerownia — przejście kablowe",
     "Nieuszczelnione przejście koryta przez ścianę.", -6, 10 * 60 + 17, "be301", 0, "server", "b_cable_seal"),
    ("server_room", 1, "progress", "Szafy rack po montażu",
     "Serwerownia 3.12 — montaż szaf i koryt.", -8, 15 * 60, None, None, None, None),
]

PHASES_B = [("demontaz", "Demontaż", "#7A8794"), ("instalacje", "Instalacje", "#E08A1E"),
            ("wykonczenie", "Wykończenie", "#2E9E5B"), ("odbiory", "Odbiory", "#D6455D")]

TASKS_B = [
    ("b01", "demontaz", "task", "Demontaż ścianek i sufitów — 3. piętro", -45, -30, 100, "completed", "modulo", []),
    ("b02", "instalacje", "task", "Instalacje elektryczne i teletechnika", -28, 10, 65, "inProgress", "elektro", ["b01"]),
    ("b03", "instalacje", "task", "HVAC — klimakonwektory i kanały", -25, 14, 55, "inProgress", "aquaterm", ["b01"]),
    ("b04", "wykonczenie", "task", "Ścianki szkło/GK i sufity podwieszane", -5, 25, 15, "inProgress", "modulo", []),
    ("b05", "wykonczenie", "task", "Podłoga podniesiona i wykładzina", 15, 32, 0, "planned", "modulo", ["b02"]),
    ("b06", "instalacje", "task", "Serwerownia — wyposażenie i klimatyzacja", 5, 20, 0, "planned", "elektro", []),
    ("bm1", "odbiory", "milestone", "Odbiór i przekazanie 3. piętra najemcy", 40, 40, 0, "planned", "modulo",
     ["b04", "b05", "b06"]),
]

DOCUMENTS_B = [
    ("pfu_3pietro", None, "PFU — aranżacja 3. piętra", "construction_documentation",
     "Program funkcjonalno-użytkowy modernizacji.", "1", "2026-08-10", -50),
]

NOTES_B = [
    ("Spotkanie z najemcą — wymagania serwerowni", "meeting", -10,
     "Najemca potwierdził redundantną klimatyzację 2×7 kW i drzwi EI30 z kontrolą dostępu. UPS 10 kVA w zakresie GW."),
    ("Inwentaryzacja instalacji nad sufitem — strefa zachodnia", "inspection", -12,
     "Stare przewody teletechniczne do demontażu. Kanał świeżego powietrza w dobrym stanie, do ponownego użycia."),
]

# key, project label, name, description, created day offset, project contact links (kind, key, role)
PROJECTS = [
    dict(key="A", name="Osiedle Zielone Tarasy — Etap I",
         description="Budowa zespołu budynków mieszkalnych z garażem podziemnym. Etap I: budynek A (30 lokali), "
                     "budynek B, garaż na 40 miejsc i zagospodarowanie terenu.",
         created=-320,
         links=[("company", "investor_a", "Inwestor"), ("company", "gw", "Generalny wykonawca"),
                ("company", "betonex", "Podwykonawca — konstrukcja"), ("company", "elektro", "Podwykonawca — elektryka"),
                ("company", "aquaterm", "Podwykonawca — sanitarne i wentylacja"),
                ("company", "prodom", "Podwykonawca — wykończenia"), ("company", "lumen", "Podwykonawca — stolarka i elewacja"),
                ("company", "zielen", "Podwykonawca — teren"), ("company", "kamien", "Dostawca materiałów"),
                ("company", "linea", "Projektant"),
                ("person", "wierzbicki", "Kierownik budowy"), ("person", "malinowska", "Kierownik projektu GW"),
                ("person", "sadowski", "Inspektor nadzoru"), ("person", "lis", "Koordynator BHP"),
                ("person", "kubiak", "Kierownik robót konstrukcyjnych"), ("person", "domanski", "Kierownik robót elektrycznych"),
                ("person", "jablonska", "Kierownik robót sanitarnych"), ("person", "gorecki", "Brygadzista wykończeń"),
                ("person", "wrobel", "Dostawy materiałów"), ("person", "czarnecka", "Nadzór autorski — architektura"),
                ("person", "nowicki", "Nadzór autorski — konstrukcja"), ("person", "pawlak", "Kierownik robót elewacyjnych")],
         folders=FOLDERS_A, drawings=DRAWINGS_A, areas=AREAS_A, issues=ISSUES_A, albums=ALBUMS_A, photos=PHOTOS_A,
         schedule=("Harmonogram realizacji — Etap I", "Harmonogram ramowy budynku A (dane demonstracyjne).",
                   PHASES_A, TASKS_A),
         doc_folders=DOC_FOLDERS_A, documents=DOCUMENTS_A, notes=NOTES_A),
    dict(key="B", name="Modernizacja Biurowca — Centrum",
         description="Modernizacja wnętrz i instalacji technicznych 3. piętra istniejącego biurowca: open space, "
                     "sale spotkań, serwerownia, nowe instalacje HVAC i elektryczne.",
         created=-60,
         links=[("company", "investor_b", "Inwestor / zarządca"), ("company", "modulo", "Generalny wykonawca"),
                ("company", "elektro", "Podwykonawca — elektryka i teletechnika"),
                ("company", "aquaterm", "Podwykonawca — HVAC"),
                ("person", "zajac", "Kierownik projektu"), ("person", "kowalczyk", "Administrator budynku"),
                ("person", "domanski", "Kierownik robót elektrycznych"), ("person", "jablonska", "Kierownik robót HVAC")],
         folders=FOLDERS_B, drawings=DRAWINGS_B, areas=AREAS_B, issues=ISSUES_B, albums=ALBUMS_B, photos=PHOTOS_B,
         schedule=("Harmonogram modernizacji 3. piętra", "Prace prowadzone przy czynnym budynku.", PHASES_B, TASKS_B),
         doc_folders=[], documents=DOCUMENTS_B, notes=NOTES_B),
]


def base_records():
    return {
        "contractors": [{"id": uid(f"contractor/{k}"), "name": n, "notes": notes} for k, n, notes in CONTRACTORS],
        "disciplines": [{"id": uid(f"discipline/{n}"), "name": n} for n in DISCIPLINES],
        "companies": _company_records(),
        "people": _people_records(),
        "equipment": _equipment_records(),
    }
