"""Synthetic technical documents (A4 PDFs with a real text layer) for Project Knowledge.

The app's own indexer (DocumentIndexer / DocumentTextExtractor) extracts this text with
PDFKit at runtime; nothing here pre-computes search results. All content is fictional.
"""
from __future__ import annotations

from pdfwriter import A4_PORTRAIT, Page, text_width

MARGIN_X = 56.0
TOP = 790.0
BOTTOM = 70.0
BODY = 9.6
LEAD = 13.2


def _wrap(text: str, size: float, width: float, bold: bool = False) -> list[str]:
    words = text.split()
    lines, cur = [], ""
    for word in words:
        trial = f"{cur} {word}".strip()
        if text_width(trial, size, bold) <= width or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


class Layout:
    def __init__(self, header: str, number: str, project: str):
        self.header, self.number, self.project = header, number, project
        self.pages: list[Page] = []
        self.y = 0.0
        self._new_page()

    def _new_page(self):
        page = Page(*A4_PORTRAIT)
        page.fill((0.10, 0.36, 0.80))
        page.rect(0, A4_PORTRAIT[1] - 28, A4_PORTRAIT[0], 28, fill=True, stroke=False)
        page.text(MARGIN_X, A4_PORTRAIT[1] - 18, "B TECHNICA · DOKUMENT DEMONSTRACYJNY", 8, bold=True, rgb=(1, 1, 1))
        page.text(A4_PORTRAIT[0] - MARGIN_X, A4_PORTRAIT[1] - 18, self.number, 8, bold=True, align="right",
                  rgb=(1, 1, 1))
        page.text(MARGIN_X, 40, f"{self.project} — dane fikcyjne, wyłącznie do demonstracji aplikacji.", 7,
                  rgb=(0.4, 0.4, 0.45))
        self.pages.append(page)
        self.y = TOP

    @property
    def page(self) -> Page:
        return self.pages[-1]

    def _need(self, h: float):
        if self.y - h < BOTTOM:
            self._new_page()

    def title(self, text: str, subtitle: str):
        for line in _wrap(text, 17, A4_PORTRAIT[0] - 2 * MARGIN_X, bold=True):
            self.page.text(MARGIN_X, self.y, line, 17, bold=True)
            self.y -= 22
        self.page.text(MARGIN_X, self.y, subtitle, 9.5, rgb=(0.35, 0.35, 0.4))
        self.y -= 10
        self.page.stroke((0.10, 0.36, 0.80))
        self.page.width_(1.0)
        self.page.line(MARGIN_X, self.y, A4_PORTRAIT[0] - MARGIN_X, self.y)
        self.y -= 20

    def h(self, text: str):
        self._need(40)
        self.y -= 4
        self.page.text(MARGIN_X, self.y, text, 11.5, bold=True, rgb=(0.10, 0.22, 0.45))
        self.y -= 17

    def p(self, text: str, indent: float = 0.0, bullet: str | None = None):
        width = A4_PORTRAIT[0] - 2 * MARGIN_X - indent
        lines = _wrap(text, BODY, width)
        for i, line in enumerate(lines):
            self._need(LEAD)
            if i == 0 and bullet:
                self.page.text(MARGIN_X + indent - 11, self.y, bullet, BODY)
            self.page.text(MARGIN_X + indent, self.y, line, BODY)
            self.y -= LEAD
        self.y -= 4

    def li(self, text: str):
        self.p(text, indent=16, bullet="•")

    def table(self, header: list[str], rows: list[list[str]], widths: list[float]):
        total = sum(widths)
        scale = (A4_PORTRAIT[0] - 2 * MARGIN_X) / total
        widths = [w * scale for w in widths]
        row_h = 15.0
        self._need(row_h * 2)
        for r_i, row in enumerate([header] + rows):
            self._need(row_h)
            x = MARGIN_X
            top = self.y + 10
            if r_i == 0:
                self.page.fill((0.90, 0.93, 0.98))
                self.page.rect(MARGIN_X, top - row_h, sum(widths), row_h, fill=True, stroke=False)
            for c_i, cell in enumerate(row):
                self.page.text(x + 4, self.y - 1, cell, 8.2, bold=r_i == 0)
                x += widths[c_i]
            self.page.stroke((0.6, 0.6, 0.65))
            self.page.width_(0.4)
            self.page.line(MARGIN_X, top - row_h, MARGIN_X + sum(widths), top - row_h)
            self.y -= row_h
        self.y -= 8

    def finish(self) -> list[Page]:
        n = len(self.pages)
        for i, page in enumerate(self.pages):
            page.text(A4_PORTRAIT[0] - MARGIN_X, 40, f"strona {i + 1} z {n}", 7, align="right", rgb=(0.4, 0.4, 0.45))
        return self.pages


PROJECT_A = "Osiedle Zielone Tarasy — Etap I"
PROJECT_B = "Modernizacja Biurowca — Centrum"


def doc_waterproofing():
    d = Layout("ST-04", "ST-04 rew. B", PROJECT_A)
    d.title("Specyfikacja techniczna ST-04 Roboty hydroizolacyjne",
            "Balkony, tarasy, progi drzwi balkonowych i posadzki w pomieszczeniach mokrych · rewizja B")
    d.h("1. Zakres")
    d.p("Specyfikacja dotyczy wykonania i odbioru hydroizolacji płyt balkonowych, tarasów parteru, progów drzwi "
        "balkonowych oraz posadzek w łazienkach lokali budynku A. Rozwiązania detali przedstawia rysunek A-501 "
        "(detal D-1 — próg drzwi balkonowych).")
    d.h("2. Materiały")
    d.li("Hydroizolacja podpłytkowa: dwuskładnikowa masa uszczelniająca 2K, elastyczna, grubość warstwy min. 2 mm.")
    d.li("Taśmy uszczelniające w narożach, dylatacjach i przy ramach drzwi — systemowe, z wkładką elastyczną.")
    d.li("Kołnierze uszczelniające przy wpustach podłogowych i odwodnieniach liniowych.")
    d.li("Klej do płytek klasy C2S1, fuga cementowa wodoodporna, silikon sanitarny w narożach.")
    d.h("3. Wymagania wykonawcze")
    d.p("Podłoże betonowe musi być nośne, oczyszczone i zagruntowane. Wilgotność podłoża przed ułożeniem hydroizolacji "
        "nie może przekraczać 4% (metoda CM). Spadek płyty balkonowej od budynku wynosi 2%.")
    d.p("Hydroizolację należy wywinąć na ościeże i ramę drzwi balkonowych na wysokość min. 15 cm ponad poziom "
        "wykończonej posadzki balkonu. Krawędź wywinięcia zabezpiecza taśma uszczelniająca. Niedopuszczalne jest "
        "zakończenie hydroizolacji na poziomie progu bez wywinięcia.")
    d.p("W łazienkach hydroizolacja obejmuje całą posadzkę oraz ściany w strefie natrysku do wysokości 2,0 m. "
        "Wpust podłogowy osadza się w spadku, z kołnierzem wklejonym w warstwę uszczelniającą; korpus wpustu "
        "nie może być przechylony względem płaszczyzny posadzki.")
    d.h("4. Kontrola i odbiór")
    d.table(["Kontrola", "Częstotliwość", "Kryterium"], [
        ["Wilgotność podłoża", "każde pomieszczenie", "maks. 4% CM"],
        ["Grubość warstwy 2K", "co 10 m²", "min. 2 mm"],
        ["Wywinięcie przy progu", "każde drzwi", "min. 15 cm"],
        ["Próba wodna balkonu", "każdy balkon", "brak przecieku 24 h"],
        ["Spadki posadzki", "każde pomieszczenie", "1,5–2,0%"],
    ], [34, 30, 36])
    d.p("Odbiór robót zanikających (hydroizolacja przed ułożeniem płytek) dokumentuje się wpisem do dziennika "
        "budowy oraz zdjęciem w aplikacji B Technica, przypiętym do lokalizacji na rzucie.")
    d.h("5. Typowe nieprawidłowości")
    d.li("Brak wywinięcia hydroizolacji przy progu balkonowym lub wywinięcie poniżej 15 cm.")
    d.li("Brak taśmy uszczelniającej w narożu ściana–posadzka.")
    d.li("Nieprawidłowo osadzony wpust podłogowy (przechył korpusu, brak kołnierza).")
    d.li("Zastoiska wody na balkonie wynikające z braku spadku.")
    d.h("Załącznik A — protokół próby wodnej balkonów (wzór)")
    d.p("Próbę wodną wykonuje się po związaniu hydroizolacji, przed ułożeniem płytek. Balkon zalewa się wodą do "
        "wysokości 2 cm na 24 godziny, kontrolując spód płyty i ościeża drzwi balkonowych.")
    d.table(["Lokal", "Balkon", "Data próby", "Wynik", "Podpis"], [
        ["A/07", "B-07", "", "", ""], ["A/08", "B-08", "", "", ""], ["A/09", "B-09", "", "", ""],
        ["A/10", "B-10", "", "", ""], ["A/15", "B-15", "", "", ""], ["A/16", "B-16", "", "", ""],
        ["A/17", "B-17", "", "", ""], ["A/18", "B-18", "", "", ""], ["A/23", "B-23", "", "", ""],
        ["A/24", "B-24", "", "", ""], ["A/25", "B-25", "", "", ""], ["A/26", "B-26", "", "", ""],
    ], [16, 16, 24, 20, 24])
    d.p("Wynik negatywny (przeciek, zawilgocenie spodu płyty lub ościeży) wymaga naprawy hydroizolacji i ponownej "
        "próby. Usterkę rejestruje się w aplikacji z przypięciem do rzutu piętra typowego A-102 i detalu D-1.")
    return d.finish()


def doc_concrete():
    d = Layout("ST-02", "ST-02 rew. A", PROJECT_A)
    d.title("Specyfikacja techniczna ST-02 Beton konstrukcyjny — wymagania jakościowe",
            "Płyta fundamentowa, ściany garażu, stropy i ściany kondygnacji nadziemnych · rewizja A")
    d.h("1. Klasy betonu")
    d.table(["Element", "Klasa betonu", "Klasa ekspozycji", "Otulina"], [
        ["Płyta fundamentowa", "C30/37 W8", "XC2, XA1", "50 mm"],
        ["Ściany garażu", "C30/37 W8", "XC2, XD1", "40 mm"],
        ["Stropy nadziemne", "C30/37", "XC1", "25 mm"],
        ["Płyty balkonowe", "C30/37", "XC4, XF1", "35 mm"],
        ["Ściany trzonu", "C25/30", "XC1", "25 mm"],
    ], [30, 22, 26, 18])
    d.h("2. Wymagania dla mieszanki")
    d.p("Konsystencja mieszanki S3–S4, maksymalny wymiar kruszywa 16 mm. Wskaźnik w/c nie większy niż 0,50 dla "
        "elementów w klasie ekspozycji XD1 i XF1. Nasiąkliwość betonu płyty fundamentowej nie większa niż 5%.")
    d.h("3. Betonowanie i pielęgnacja")
    d.p("Betonowanie stropów prowadzić w sposób ciągły; przerwy robocze wyłącznie w miejscach uzgodnionych z "
        "projektantem konstrukcji (rysunek K-101 — przerwa robocza w osi 4). Powierzchnię świeżego betonu "
        "chronić przed wysychaniem przez min. 7 dni.")
    d.p("Rozdeskowanie stropów dopuszcza się po osiągnięciu 70% wytrzymałości projektowej, potwierdzonej badaniem "
        "próbek pielęgnowanych w warunkach budowy.")
    d.h("4. Badania")
    d.li("Próbki sześcienne 150 mm: 1 seria (3 próbki) na każde 50 m³ betonu, nie mniej niż 1 seria na dzień.")
    d.li("Kontrola otuliny zbrojenia przed betonowaniem — pomiar dystansów, dokumentacja fotograficzna.")
    d.li("Odsłonięte zbrojenie lub raki po rozdeskowaniu zgłaszać jako usterkę i naprawiać zaprawą PCC.")
    return d.finish()


def doc_coordination_meeting():
    d = Layout("N-14", "Notatka nr 14", PROJECT_A)
    d.title("Notatka z narady koordynacyjnej nr 14 — instalacje w korytarzach",
            "Budynek A, parter i piętro 1 · uczestnicy: GW, AquaTerm, Elektro-Volt, inspektor nadzoru")
    d.h("1. Kolizje międzybranżowe")
    d.p("Stwierdzono kolizję kanału wentylacyjnego 400×200 z korytem kablowym 200×60 w korytarzu parteru, w osi 5. "
        "Ustalono obniżenie koryta kablowego o 15 cm na odcinku 3 m oraz wykonanie obejścia kanału łukami 45°.")
    d.p("Klapy przeciwpożarowe KPP na przejściach kanałów przez ściany korytarza zostaną zamontowane przed "
        "zamknięciem sufitów. Odpowiedzialny: AquaTerm.")
    d.h("2. Przejścia instalacyjne")
    d.p("W pomieszczeniu technicznym 0.18 trzy przejścia rur przez ścianę EI60 nie mają uszczelnień ogniochronnych. "
        "Wykonawca instalacji sanitarnych uzupełni uszczelnienia systemowe i przekaże deklaracje właściwości użytkowych.")
    d.h("3. Rozdzielnica główna RG")
    d.p("Opis obwodów w rozdzielnicy RG jest niekompletny — brak oznaczeń przewodów odpływowych. Elektro-Volt uzupełni "
        "oznaczenia i schemat w drzwiach rozdzielnicy przed przeglądem instalacji.")
    d.h("4. Ustalenia i terminy")
    d.table(["Nr", "Ustalenie", "Odpowiedzialny", "Termin"], [
        ["14.1", "Obniżenie koryta kablowego w osi 5", "Elektro-Volt", "7 dni"],
        ["14.2", "Montaż klap KPP w korytarzu", "AquaTerm", "14 dni"],
        ["14.3", "Uszczelnienia przejść EI60", "AquaTerm", "10 dni"],
        ["14.4", "Opisy obwodów w RG", "Elektro-Volt", "5 dni"],
    ], [10, 46, 24, 14])
    return d.finish()


def doc_finishing_checklist():
    d = Layout("LK-03", "LK-03", PROJECT_A)
    d.title("Lista kontrolna odbioru robót wykończeniowych w lokalach",
            "Do stosowania przy odbiorach wewnętrznych przed przekazaniem lokali nabywcom")
    d.h("1. Tynki i malowanie")
    d.li("Odchyłka powierzchni tynku od płaszczyzny: maks. 3 mm na łacie 2 m.")
    d.li("Brak rys, pęcherzy, przebarwień; jednolity kolor i połysk powłoki malarskiej.")
    d.li("Ościeża okien i drzwi bez rys przy narożnikach, narożniki ochronne osadzone prosto.")
    d.h("2. Posadzki i okładziny")
    d.li("Wylewka: wilgotność przed układaniem okładzin wg wymagań producenta, dylatacja obwodowa wykonana.")
    d.li("Płytki: równe fugi, brak pustek pod płytkami (opukiwanie), spadki do wpustów w łazienkach.")
    d.li("Listwy przypodłogowe zamontowane, połączenia w narożach dopasowane.")
    d.h("3. Stolarka")
    d.li("Drzwi wejściowe do lokali: klasa EI30, Rw = 37 dB, szerokość w świetle zgodna z projektem (90 cm).")
    d.li("Okna i drzwi balkonowe: regulacja, uszczelki, brak uszkodzeń szyb i ram, obróbki parapetów.")
    d.h("4. Instalacje — kontrola wizualna")
    d.li("Osprzęt elektryczny zamontowany w osi, gniazda w łazienkach w wykonaniu IP44.")
    d.li("Biały montaż szczelny, syfony dostępne, wpusty podłogowe z kratkami osadzonymi w poziomie.")
    d.h("5. Ocena")
    d.table(["Element", "OK", "Usterka", "Uwagi"], [
        ["Tynki i malowanie", "", "", ""],
        ["Posadzki", "", "", ""],
        ["Okładziny ścienne", "", "", ""],
        ["Stolarka", "", "", ""],
        ["Instalacje", "", "", ""],
    ], [40, 10, 14, 36])
    return d.finish()


def doc_safety():
    d = Layout("BHP-02", "BHP-02", PROJECT_A)
    d.title("Instrukcja BHP — prace na wysokości i rusztowaniach",
            "Obowiązuje wszystkich pracowników generalnego wykonawcy i podwykonawców na budowie")
    d.h("1. Zasady ogólne")
    d.p("Prace na wysokości powyżej 1,0 m wykonuje się z zastosowaniem środków ochrony zbiorowej (balustrady, "
        "siatki), a gdy nie jest to możliwe — sprzętu ochrony indywidualnej: szelek bezpieczeństwa z amortyzatorem "
        "i linką przypiętą do punktu kotwiczenia.")
    d.h("2. Rusztowania")
    d.li("Rusztowanie użytkuje się wyłącznie po protokolarnym odbiorze technicznym i oznakowaniu tablicą.")
    d.li("Pomosty kompletne, z deską krawężnikową i barierą na wysokości 1,1 m.")
    d.li("Codzienny przegląd rusztowania przed rozpoczęciem pracy przez brygadzistę.")
    d.h("3. Otwory w stropach i krawędzie")
    d.p("Otwory w stropach (np. pod piony instalacyjne) zabezpiecza się trwale przykryciem z oznakowaniem lub "
        "balustradą. Krawędzie stropów i balkonów bez balustrad zabezpiecza się barierami ochronnymi.")
    d.h("4. Wykopy")
    d.p("Wykopy o głębokości powyżej 1,0 m zabezpiecza się barierami w odległości min. 1,0 m od krawędzi oraz "
        "oświetla w porze nocnej. Wejścia do wykopu tylko po drabinach lub schodach.")
    d.h("5. Zgłaszanie zagrożeń")
    d.p("Każde zauważone zagrożenie należy niezwłocznie zgłosić kierownikowi budowy i zarejestrować w aplikacji "
        "jako usterkę w kategorii BHP, z lokalizacją na rysunku i zdjęciem.")
    return d.finish()


def doc_electrical_inspection():
    d = Layout("PE-01", "Protokół PE-01", PROJECT_A)
    d.title("Protokół z przeglądu instalacji elektrycznej — parter budynku A",
            "Przegląd międzyoperacyjny przed zamknięciem sufitów · wykonawca: Elektro-Volt Instalacje s.c.")
    d.h("1. Zakres przeglądu")
    d.p("Przegląd objął rozdzielnicę główną RG w pomieszczeniu technicznym 0.18, wewnętrzne linie zasilające do "
        "tablic mieszkaniowych TM, instalację oświetlenia korytarza i klatki schodowej oraz oświetlenie awaryjne.")
    d.h("2. Wyniki pomiarów")
    d.table(["Obwód", "Pomiar", "Wynik", "Ocena"], [
        ["WLZ TM A/01", "rezystancja izolacji", "> 500 MOhm", "pozytywna"],
        ["WLZ TM A/02", "rezystancja izolacji", "> 500 MOhm", "pozytywna"],
        ["L1.3 korytarz", "impedancja pętli zwarcia", "0,62 Ohm", "pozytywna"],
        ["AW klatka A", "czas świecenia", "brak opraw", "negatywna"],
    ], [24, 32, 24, 20])
    d.h("3. Stwierdzone nieprawidłowości")
    d.li("Brak oznaczenia przewodów odpływowych w rozdzielnicy RG — do uzupełnienia przed odbiorem.")
    d.li("Brak opraw oświetlenia awaryjnego na klatce schodowej A (parter).")
    d.li("Gniazdo w łazience lokalu A/01 bez wymaganej klasy szczelności IP44.")
    d.h("4. Wnioski")
    d.p("Instalacja może zostać zakryta po usunięciu nieprawidłowości z pkt 3 i ponownym sprawdzeniu przez "
        "inspektora nadzoru. Wyniki przeglądu zarejestrowano w aplikacji jako usterki przypięte do rysunku E-101.")
    return d.finish()


def doc_office_program():
    d = Layout("PFU-3", "PFU — 3. piętro", PROJECT_B)
    d.title("Program funkcjonalno-użytkowy — aranżacja 3. piętra",
            "Modernizacja wnętrz i instalacji technicznych istniejącego biurowca (dane fikcyjne)")
    d.h("1. Założenia")
    d.p("Piętro 3. zostanie przebudowane na otwartą przestrzeń biurową (open space) dla 64 stanowisk, z salą "
        "konferencyjną na 16 osób, salą spotkań, pokojem kierownika, aneksem socjalnym i serwerownią.")
    d.h("2. Wymagania dla serwerowni 3.12")
    d.li("Drzwi o klasie odporności ogniowej EI30, kontrola dostępu.")
    d.li("Klimatyzacja precyzyjna 2×7 kW w układzie redundantnym, odprowadzenie skroplin grawitacyjne.")
    d.li("Zasilanie z rozdzielnicy RPS przez UPS 10 kVA; przejścia kablowe uszczelnione ogniochronnie EI60.")
    d.h("3. Instalacje")
    d.p("Podłoga podniesiona o wysokości 15 cm z puszkami podłogowymi przy stanowiskach. Oprawy LED 60×60 ze "
        "sterowaniem DALI. Klimakonwektory czterorurowe w strefach open space, kasetony VRF w salach.")
    d.h("4. Harmonogram")
    d.p("Prace prowadzone przy czynnym budynku — roboty głośne wyłącznie w godzinach 18:00–6:00 i w weekendy.")
    return d.finish()


DOCUMENTS = {
    "st04_hydroizolacja": doc_waterproofing,
    "st02_beton": doc_concrete,
    "n14_narada": doc_coordination_meeting,
    "lk03_odbior": doc_finishing_checklist,
    "bhp02_wysokosc": doc_safety,
    "pe01_elektryka": doc_electrical_inspection,
    "pfu_3pietro": doc_office_program,
}
