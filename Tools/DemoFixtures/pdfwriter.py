"""Minimal deterministic PDF writer for the B Technica demo fixtures.

Vector drawing primitives plus text in the standard Helvetica fonts. Polish letters use
character codes 1-16 remapped through /Differences, and every font carries a ToUnicode
CMap, so PDFKit can both render the glyphs and extract the text (`PDFPage.string`), which
is what the Project Knowledge indexer reads. No timestamps: output is byte-for-byte stable.
"""
from __future__ import annotations

import math
import zlib

PL_CHARS = "ĄąĆćĘęŁłŃńŚśŹźŻż"
PL_GLYPHS = ["Aogonek", "aogonek", "Cacute", "cacute", "Eogonek", "eogonek", "Lslash", "lslash",
             "Nacute", "nacute", "Sacute", "sacute", "Zacute", "zacute", "Zdotaccent", "zdotaccent"]
WINANSI_EXTRA = {
    "Ó": 0xD3, "ó": 0xF3, "–": 0x96, "—": 0x97, "„": 0x84, "”": 0x94, "“": 0x93, "’": 0x92,
    "²": 0xB2, "³": 0xB3, "°": 0xB0, "±": 0xB1, "×": 0xD7, "Ø": 0xD8, "ø": 0xF8, "·": 0xB7,
    "…": 0x85, "§": 0xA7, "é": 0xE9, "ü": 0xFC, "ö": 0xF6, "ä": 0xE4, "•": 0x95,
}

CODE_OF: dict[str, int] = {chr(c): c for c in range(32, 127)}
for _i, _ch in enumerate(PL_CHARS):
    CODE_OF[_ch] = _i + 1
CODE_OF.update(WINANSI_EXTRA)
UNICODE_OF_CODE = {code: ch for ch, code in CODE_OF.items()}

# Helvetica / Helvetica-Bold advance widths (1/1000 em) for printable ASCII 32..126.
_REG = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]
_BOLD = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
         556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
         975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
         667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
         333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
         611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584]
_BASE_LETTER = {"Ą": "A", "ą": "a", "Ć": "C", "ć": "c", "Ę": "E", "ę": "e", "Ł": "L", "ł": "l",
                "Ń": "N", "ń": "n", "Ś": "S", "ś": "s", "Ź": "Z", "ź": "z", "Ż": "Z", "ż": "z",
                "Ó": "O", "ó": "o", "é": "e", "ü": "u", "ö": "o", "ä": "a", "Ø": "O", "ø": "o"}
_SPECIAL_WIDTH = {"–": 556, "—": 1000, "„": 333, "”": 333, "“": 333, "’": 222, "²": 333, "³": 333,
                  "°": 400, "±": 584, "×": 584, "·": 278, "…": 1000, "§": 556, "•": 350}


def char_width(ch: str, bold: bool) -> int:
    table = _BOLD if bold else _REG
    ch = _BASE_LETTER.get(ch, ch)
    if ch in _SPECIAL_WIDTH:
        return _SPECIAL_WIDTH[ch]
    code = ord(ch)
    if 32 <= code <= 126:
        return table[code - 32]
    return 556


def text_width(text: str, size: float, bold: bool = False) -> float:
    return sum(char_width(ch, bold) for ch in text) * size / 1000.0


def encode_text(text: str) -> bytes:
    out = bytearray()
    for ch in text:
        if ch not in CODE_OF:
            raise ValueError(f"character {ch!r} (U+{ord(ch):04X}) is not in the fixture font encoding: {text!r}")
        out.append(CODE_OF[ch])
    return bytes(out)


def pdf_string(raw: bytes) -> bytes:
    out = bytearray(b"(")
    for b in raw:
        if b in (0x28, 0x29, 0x5C):
            out += b"\\" + bytes([b])
        elif b < 32 or b > 126:
            out += b"\\%03o" % b
        else:
            out.append(b)
    out += b")"
    return bytes(out)


def fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


class Page:
    """One page of vector content in PDF user space (points, origin bottom-left)."""

    def __init__(self, width: float, height: float):
        self.width = width
        self.height = height
        self.ops: list[str] = []

    # -- state ---------------------------------------------------------------------------
    def save(self):
        self.ops.append("q")

    def restore(self):
        self.ops.append("Q")

    def stroke(self, rgb):
        self.ops.append(f"{fmt(rgb[0])} {fmt(rgb[1])} {fmt(rgb[2])} RG")

    def fill(self, rgb):
        self.ops.append(f"{fmt(rgb[0])} {fmt(rgb[1])} {fmt(rgb[2])} rg")

    def width_(self, w: float):
        self.ops.append(f"{fmt(w)} w")

    def dash(self, pattern=None, phase: float = 0):
        if not pattern:
            self.ops.append("[] 0 d")
        else:
            self.ops.append("[" + " ".join(fmt(p) for p in pattern) + f"] {fmt(phase)} d")

    def caps(self, cap: int = 0, join: int = 0):
        self.ops.append(f"{cap} J {join} j")

    # -- paths ---------------------------------------------------------------------------
    def _paint(self, fill: bool, stroke: bool):
        self.ops.append("B" if fill and stroke else ("f" if fill else ("S" if stroke else "n")))

    def line(self, x1, y1, x2, y2):
        self.ops.append(f"{fmt(x1)} {fmt(y1)} m {fmt(x2)} {fmt(y2)} l S")

    def polyline(self, pts, close=False, fill=False, stroke=True):
        if not pts:
            return
        parts = [f"{fmt(pts[0][0])} {fmt(pts[0][1])} m"]
        parts += [f"{fmt(x)} {fmt(y)} l" for x, y in pts[1:]]
        if close:
            parts.append("h")
        self.ops.append(" ".join(parts))
        self._paint(fill, stroke)

    def rect(self, x, y, w, h, fill=False, stroke=True):
        self.ops.append(f"{fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)} re")
        self._paint(fill, stroke)

    def clip_rect(self, x, y, w, h):
        self.ops.append(f"{fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)} re W n")

    def _arc_segments(self, cx, cy, r, a0, a1):
        """Cubic Bezier segments (each <= 90 degrees) from angle a0 to a1 (degrees)."""
        segs = max(1, int(math.ceil(abs(a1 - a0) / 90.0)))
        step = (a1 - a0) / segs
        out = []
        for i in range(segs):
            t0 = math.radians(a0 + i * step)
            t1 = math.radians(a0 + (i + 1) * step)
            k = 4.0 / 3.0 * math.tan((t1 - t0) / 4.0)
            p0 = (cx + r * math.cos(t0), cy + r * math.sin(t0))
            p3 = (cx + r * math.cos(t1), cy + r * math.sin(t1))
            p1 = (p0[0] - k * r * math.sin(t0), p0[1] + k * r * math.cos(t0))
            p2 = (p3[0] + k * r * math.sin(t1), p3[1] - k * r * math.cos(t1))
            out.append((p0, p1, p2, p3))
        return out

    def arc(self, cx, cy, r, a0, a1):
        segs = self._arc_segments(cx, cy, r, a0, a1)
        parts = [f"{fmt(segs[0][0][0])} {fmt(segs[0][0][1])} m"]
        for _, p1, p2, p3 in segs:
            parts.append(f"{fmt(p1[0])} {fmt(p1[1])} {fmt(p2[0])} {fmt(p2[1])} {fmt(p3[0])} {fmt(p3[1])} c")
        self.ops.append(" ".join(parts) + " S")

    def circle(self, cx, cy, r, fill=False, stroke=True):
        segs = self._arc_segments(cx, cy, r, 0, 360)
        parts = [f"{fmt(segs[0][0][0])} {fmt(segs[0][0][1])} m"]
        for _, p1, p2, p3 in segs:
            parts.append(f"{fmt(p1[0])} {fmt(p1[1])} {fmt(p2[0])} {fmt(p2[1])} {fmt(p3[0])} {fmt(p3[1])} c")
        self.ops.append(" ".join(parts) + " h")
        self._paint(fill, stroke)

    def ellipse(self, cx, cy, rx, ry, fill=False, stroke=True):
        self.save()
        self.ops.append(f"1 0 0 {fmt(ry / rx if rx else 1)} {fmt(cx)} {fmt(cy)} cm")
        self.circle(0, 0, rx, fill=fill, stroke=stroke)
        self.restore()

    # -- text ----------------------------------------------------------------------------
    def text(self, x, y, s: str, size: float = 8, bold: bool = False, align: str = "left",
             angle: float = 0.0, rgb=None):
        if not s:
            return
        w = text_width(s, size, bold)
        dx = {"left": 0.0, "center": -w / 2.0, "right": -w}[align]
        a = math.radians(angle)
        ca, sa = math.cos(a), math.sin(a)
        tx = x + dx * ca
        ty = y + dx * sa
        # Always set the text colour: inheriting the current fill made text drawn after a white
        # fill (e.g. the title block background) invisible.
        rgb = rgb or (0, 0, 0)
        color = f"{fmt(rgb[0])} {fmt(rgb[1])} {fmt(rgb[2])} rg "
        font = "F2" if bold else "F1"
        literal = pdf_string(encode_text(s)).decode("latin-1")
        self.ops.append(
            f"q {color}BT /{font} {fmt(size)} Tf {fmt(ca)} {fmt(sa)} {fmt(-sa)} {fmt(ca)} {fmt(tx)} {fmt(ty)} Tm "
            f"{literal} Tj ET Q")

    def content(self) -> bytes:
        return ("\n".join(self.ops) + "\n").encode("latin-1")


def _tounicode_cmap() -> bytes:
    entries = sorted(UNICODE_OF_CODE.items())
    lines = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
             "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
             "/CMapName /BTechnicaDemo-UCS def", "/CMapType 2 def",
             "1 begincodespacerange", "<00> <FF>", "endcodespacerange"]
    for start in range(0, len(entries), 100):
        chunk = entries[start:start + 100]
        lines.append(f"{len(chunk)} beginbfchar")
        for code, ch in chunk:
            lines.append(f"<{code:02X}> <{ord(ch):04X}>")
        lines.append("endbfchar")
    lines += ["endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end"]
    return ("\n".join(lines) + "\n").encode("ascii")


def _pdf_text_string(s: str) -> bytes:
    """Info dictionary string as UTF-16BE with BOM (handles Polish letters)."""
    data = b"\xfe\xff" + s.encode("utf-16-be")
    return b"<" + data.hex().upper().encode("ascii") + b">"


def build_pdf(pages: list[Page], title: str, subject: str = "", keywords: str = "") -> bytes:
    objects: list[bytes] = []

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)

    catalog_id = add(b"")  # placeholder, filled below
    pages_id = add(b"")
    info_id = add(b"<< /Title " + _pdf_text_string(title)
                  + b" /Subject " + _pdf_text_string(subject or title)
                  + b" /Keywords " + _pdf_text_string(keywords)
                  + b" /Author " + _pdf_text_string("B Technica — dane demonstracyjne (fikcyjne)")
                  + b" /Creator " + _pdf_text_string("Tools/DemoFixtures/generate_demo_fixtures.py")
                  + b" /Producer (btechnica-demo-fixtures 1) >>")
    differences = " ".join(f"/{g}" for g in PL_GLYPHS)
    encoding_id = add(f"<< /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 {differences}] >>"
                      .encode("ascii"))
    cmap = _tounicode_cmap()
    tounicode_id = add(b"<< /Length " + str(len(cmap)).encode() + b" >>\nstream\n" + cmap + b"endstream")
    font_ids = []
    for base in ("Helvetica", "Helvetica-Bold"):
        font_ids.append(add(f"<< /Type /Font /Subtype /Type1 /BaseFont /{base} /Encoding {encoding_id} 0 R "
                            f"/ToUnicode {tounicode_id} 0 R >>".encode("ascii")))
    resources = f"<< /Font << /F1 {font_ids[0]} 0 R /F2 {font_ids[1]} 0 R >> /ProcSet [/PDF /Text] >>"

    page_ids = []
    for page in pages:
        raw = page.content()
        packed = zlib.compress(raw, 9)
        content_id = add(b"<< /Length " + str(len(packed)).encode() + b" /Filter /FlateDecode >>\nstream\n"
                         + packed + b"\nendstream")
        page_ids.append(add(
            f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 {fmt(page.width)} {fmt(page.height)}] "
            f"/Resources {resources} /Contents {content_id} 0 R >>".encode("ascii")))

    objects[catalog_id - 1] = f"<< /Type /Catalog /Pages {pages_id} 0 R >>".encode("ascii")
    kids = " ".join(f"{pid} 0 R" for pid in page_ids)
    objects[pages_id - 1] = f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>".encode("ascii")

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref_at = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode("ascii")
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root {catalog_id} 0 R /Info {info_id} 0 R >>\n"
            f"startxref\n{xref_at}\n%%EOF\n").encode("ascii")
    return bytes(out)


A3_LANDSCAPE = (1190.55, 841.89)
A4_PORTRAIT = (595.28, 841.89)
MM = 72.0 / 25.4
