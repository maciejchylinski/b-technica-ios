"""Synthetic construction drawings (vector PDFs) for the B Technica demo.

Each sheet is drawn in world metres and mapped to PDF points (origin bottom-left, the same
page space the app stores issue pins and polygon areas in). Every sheet returns a `Sheet`
whose `to_page()` converts world coordinates, so the dataset can place pins and areas on
real features of the drawing. These are UX fixtures, not engineering documentation.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from pdfwriter import A3_LANDSCAPE, MM, Page

BLACK = (0, 0, 0)
WALL = (0.22, 0.22, 0.24)
WALL_FAINT = (0.74, 0.74, 0.76)
INK_FAINT = (0.55, 0.55, 0.58)
GRID = (0.45, 0.45, 0.5)
RED = (0.82, 0.12, 0.12)
BLUE = (0.10, 0.36, 0.80)
HOT = (0.85, 0.20, 0.15)
CIRC = (0.70, 0.20, 0.65)
SEWER = (0.50, 0.32, 0.12)
ORANGE = (0.93, 0.50, 0.05)
GREEN = (0.20, 0.55, 0.25)
LIGHT_GREEN = (0.86, 0.94, 0.84)
CONCRETE = (0.80, 0.80, 0.80)
DUCT = (0.20, 0.55, 0.65)

FRAME = 20.0
TB_W, TB_H, REV_H = 420.0, 130.0, 50.0


@dataclass
class Sheet:
    """One drawing (one or more pages) with its world→page transform per page."""
    key: str
    number: str
    title: str
    scale_label: str
    pages: list = field(default_factory=list)
    transforms: list = field(default_factory=list)   # per page: (ox, oy, k)
    content_boxes: list = field(default_factory=list)

    def to_page(self, page_index: int, x: float, y: float) -> tuple[float, float]:
        ox, oy, k = self.transforms[page_index]
        return (round(ox + x * k, 2), round(oy + y * k, 2))


class W:
    """World-coordinate drawing helper bound to one page."""

    def __init__(self, page: Page, scale: float, ox: float, oy: float):
        self.p = page
        self.k = 1000.0 / scale * MM
        self.ox, self.oy = ox, oy

    def P(self, x, y):
        return (self.ox + x * self.k, self.oy + y * self.k)

    def L(self, d):
        return d * self.k

    # primitives in world units
    def rect(self, x0, y0, x1, y1, fill=None, stroke=BLACK, lw=0.5):
        (a, b), (c, d) = self.P(x0, y0), self.P(x1, y1)
        if fill is not None:
            self.p.fill(fill)
        if stroke is not None:
            self.p.stroke(stroke)
            self.p.width_(lw)
        self.p.rect(min(a, c), min(b, d), abs(c - a), abs(d - b), fill=fill is not None, stroke=stroke is not None)

    def poly(self, pts, fill=None, stroke=BLACK, lw=0.5, close=True):
        if fill is not None:
            self.p.fill(fill)
        if stroke is not None:
            self.p.stroke(stroke)
            self.p.width_(lw)
        self.p.polyline([self.P(x, y) for x, y in pts], close=close, fill=fill is not None, stroke=stroke is not None)

    def line(self, x0, y0, x1, y1, color=BLACK, lw=0.4, dash=None):
        self.p.stroke(color)
        self.p.width_(lw)
        if dash:
            self.p.dash(dash)
        a, b = self.P(x0, y0)
        c, d = self.P(x1, y1)
        self.p.line(a, b, c, d)
        if dash:
            self.p.dash()

    def circle(self, x, y, r_world=None, r_pt=None, fill=None, stroke=BLACK, lw=0.4):
        cx, cy = self.P(x, y)
        r = r_pt if r_pt is not None else self.L(r_world)
        if fill is not None:
            self.p.fill(fill)
        if stroke is not None:
            self.p.stroke(stroke)
            self.p.width_(lw)
        self.p.circle(cx, cy, r, fill=fill is not None, stroke=stroke is not None)

    def arc(self, x, y, r_world, a0, a1, color=BLACK, lw=0.3):
        cx, cy = self.P(x, y)
        self.p.stroke(color)
        self.p.width_(lw)
        self.p.arc(cx, cy, self.L(r_world), a0, a1)

    def text(self, x, y, s, size=7, bold=False, align="center", angle=0.0, rgb=None):
        px, py = self.P(x, y)
        self.p.text(px, py, s, size=size, bold=bold, align=align, angle=angle, rgb=rgb)

    def hatch(self, x0, y0, x1, y1, spacing_pt=4.0, color=GRID, lw=0.25, angle45=True):
        (a, b), (c, d) = self.P(x0, y0), self.P(x1, y1)
        a, c = min(a, c), max(a, c)
        b, d = min(b, d), max(b, d)
        self.p.save()
        self.p.clip_rect(a, b, c - a, d - b)
        self.p.stroke(color)
        self.p.width_(lw)
        span = (c - a) + (d - b)
        t = -span
        while t < span:
            if angle45:
                self.p.line(a + t, b, a + t + (d - b), d)
            else:
                self.p.line(a + t, d, a + t + (d - b), b)
            t += spacing_pt
        self.p.restore()


# ------------------------------------------------------------------------------------
# Sheet frame, title block, clipping
# ------------------------------------------------------------------------------------

def content_box(page: Page):
    """Drawable area: inside the frame, excluding the title block + revision table."""
    return (FRAME, FRAME, page.width - FRAME, page.height - FRAME)


def begin_content(page: Page):
    """Clip everything drawn until end_content() away from the title block (even-odd)."""
    x0, y0, x1, y1 = content_box(page)
    tbx = page.width - FRAME - TB_W
    page.save()
    page.ops.append(f"{x0:.2f} {y0:.2f} {x1 - x0:.2f} {y1 - y0:.2f} re "
                    f"{tbx:.2f} {FRAME:.2f} {TB_W:.2f} {TB_H + REV_H:.2f} re W* n")


def end_content(page: Page):
    page.restore()


def title_block(page: Page, info: dict):
    W_, H_ = page.width, page.height
    p = page
    p.stroke(BLACK)
    p.width_(1.2)
    p.rect(FRAME, FRAME, W_ - 2 * FRAME, H_ - 2 * FRAME)
    x0 = W_ - FRAME - TB_W
    y0 = FRAME
    p.fill((1, 1, 1))
    p.width_(0.8)
    p.rect(x0, y0, TB_W, TB_H + REV_H, fill=True, stroke=True)
    # revision table
    ry = y0 + TB_H
    p.width_(0.4)
    p.line(x0, ry, x0 + TB_W, ry)
    p.line(x0, ry + REV_H - 14, x0 + TB_W, ry + REV_H - 14)
    for cx in (x0 + 40, x0 + TB_W - 80):
        p.line(cx, ry, cx, ry + REV_H)
    p.text(x0 + 6, ry + REV_H - 10, "Rew.", 6.5, bold=True)
    p.text(x0 + 46, ry + REV_H - 10, "Opis zmiany", 6.5, bold=True)
    p.text(x0 + TB_W - 74, ry + REV_H - 10, "Data", 6.5, bold=True)
    for i, (rev, desc, date) in enumerate(info.get("revisions", [])[-2:]):
        yy = ry + REV_H - 25 - i * 12
        p.text(x0 + 6, yy, rev, 6.5)
        p.text(x0 + 46, yy, desc, 6.5)
        p.text(x0 + TB_W - 74, yy, date, 6.5)
    # main block rows
    rows = [y0 + 20, y0 + 44, y0 + 78, y0 + 100]
    for yy in rows:
        p.line(x0, yy, x0 + TB_W, yy)
    p.text(x0 + 6, y0 + 112, info["project"], 9.5, bold=True)
    p.text(x0 + 6, y0 + 104 - 1, info.get("investor", ""), 6.0, rgb=(0.25, 0.25, 0.25))
    p.text(x0 + 6, y0 + 86, info["title"], 12, bold=True)
    p.text(x0 + 6, y0 + 80 - 0.5, info.get("subtitle", ""), 6.5, rgb=(0.25, 0.25, 0.25))
    cols = [x0, x0 + 110, x0 + 190, x0 + 260, x0 + TB_W]
    labels = [("Nr rysunku", info["number"]), ("Skala", info["scale"]), ("Rewizja", info["revision"]),
              ("Data", info["date"])]
    for i, (lab, val) in enumerate(labels):
        cx = cols[i]
        if i > 0:
            p.line(cx, y0 + 44, cx, y0 + 78)
        p.text(cx + 5, y0 + 69, lab, 5.5, rgb=(0.35, 0.35, 0.35))
        p.text(cx + 5, y0 + 52, val, 10 if i == 0 else 9, bold=i == 0)
    p.line(x0 + 200, y0 + 20, x0 + 200, y0 + 44)
    p.text(x0 + 5, y0 + 35, "Branża: " + info["discipline"], 6.5)
    p.text(x0 + 5, y0 + 26, "Faza: projekt wykonawczy", 6.0, rgb=(0.3, 0.3, 0.3))
    p.text(x0 + 205, y0 + 35, "Projektował: " + info.get("author", "arch. J. Czarnecka"), 6.5)
    p.text(x0 + 205, y0 + 26, "Sprawdził: " + info.get("checker", "inż. K. Nowicki"), 6.0, rgb=(0.3, 0.3, 0.3))
    p.text(x0 + TB_W / 2, y0 + 7, "DANE DEMONSTRACYJNE — RYSUNEK FIKCYJNY, NIE DO BUDOWY", 7.5, bold=True,
           align="center", rgb=RED)
    # small north-agnostic logo box
    p.text(FRAME + 8, H_ - FRAME - 14, "B TECHNICA · DEMO", 7, bold=True, rgb=(0.1, 0.36, 0.8))
    p.text(FRAME + 8, H_ - FRAME - 23, f"{info['number']} — {info['title']}", 6.5, rgb=(0.3, 0.3, 0.3))


def north_arrow(page: Page, x, y, size=18):
    page.stroke(BLACK)
    page.width_(0.6)
    page.circle(x, y, size)
    page.fill(BLACK)
    page.polyline([(x, y + size * 0.9), (x - size * 0.35, y - size * 0.6), (x, y - size * 0.25)], close=True,
                  fill=True, stroke=True)
    page.polyline([(x, y + size * 0.9), (x + size * 0.35, y - size * 0.6), (x, y - size * 0.25)], close=True,
                  fill=False, stroke=True)
    page.text(x, y + size + 4, "N", 8, bold=True, align="center")


def scale_bar(w: W, x, y, length_m, step_m, label):
    for i in range(int(length_m / step_m)):
        w.rect(x + i * step_m, y, x + (i + 1) * step_m, y + length_m / 40.0,
               fill=BLACK if i % 2 == 0 else (1, 1, 1), stroke=BLACK, lw=0.4)
    w.text(x, y - length_m / 25.0, "0", 6, align="center")
    w.text(x + length_m, y - length_m / 25.0, f"{length_m:g} m", 6, align="center")
    w.text(x + length_m / 2, y + length_m / 12.0, label, 6, align="center")


def axis_grid(w: W, xs, ys, x_ext, y_ext, bubble_pt=8.5, faint=False):
    color = GRID if not faint else (0.7, 0.7, 0.72)
    for name, x in xs:
        w.line(x, y_ext[0], x, y_ext[1], color=color, lw=0.3, dash=[10, 3, 2, 3])
        for yy, off in ((y_ext[0], -1), (y_ext[1], 1)):
            px, py = w.P(x, yy)
            py += off * bubble_pt
            w.p.stroke(color)
            w.p.width_(0.5)
            w.p.fill((1, 1, 1))
            w.p.circle(px, py, bubble_pt, fill=True, stroke=True)
            w.p.text(px, py - 3, name, 8, bold=True, align="center", rgb=color)
    for name, y in ys:
        w.line(x_ext[0], y, x_ext[1], y, color=color, lw=0.3, dash=[10, 3, 2, 3])
        for xx, off in ((x_ext[0], -1), (x_ext[1], 1)):
            px, py = w.P(xx, y)
            px += off * bubble_pt
            w.p.stroke(color)
            w.p.width_(0.5)
            w.p.fill((1, 1, 1))
            w.p.circle(px, py, bubble_pt, fill=True, stroke=True)
            w.p.text(px, py - 3, name, 8, bold=True, align="center", rgb=color)


def dim_h(w: W, xs, y, y_from=None, size=6.0):
    w.line(xs[0], y, xs[-1], y, lw=0.3)
    for x in xs:
        if y_from is not None:
            w.line(x, y_from, x, y, lw=0.2, color=(0.45, 0.45, 0.45))
        px, py = w.P(x, y)
        w.p.stroke(BLACK)
        w.p.width_(0.6)
        w.p.line(px - 2.2, py - 2.2, px + 2.2, py + 2.2)
    for a, b in zip(xs, xs[1:]):
        px, py = w.P((a + b) / 2, y)
        w.p.text(px, py + 1.8, f"{round((b - a) * 1000):d}", size, align="center")


def dim_v(w: W, ys, x, x_from=None, size=6.0):
    w.line(x, ys[0], x, ys[-1], lw=0.3)
    for y in ys:
        if x_from is not None:
            w.line(x_from, y, x, y, lw=0.2, color=(0.45, 0.45, 0.45))
        px, py = w.P(x, y)
        w.p.stroke(BLACK)
        w.p.width_(0.6)
        w.p.line(px - 2.2, py - 2.2, px + 2.2, py + 2.2)
    for a, b in zip(ys, ys[1:]):
        px, py = w.P(x, (a + b) / 2)
        w.p.text(px - 1.8, py, f"{round((b - a) * 1000):d}", size, align="center", angle=90)


def leader(w: W, x0, y0, x1, y1, text, size=6.5, align="left", color=BLACK):
    w.line(x0, y0, x1, y1, color=color, lw=0.35)
    w.circle(x0, y0, r_pt=1.2, fill=color, stroke=None)
    px, py = w.P(x1, y1)
    w.p.text(px + (2 if align == "left" else -2), py - 2, text, size, align=align, rgb=color)


# ------------------------------------------------------------------------------------
# Building A geometry (world metres; origin = outer corner at axes A/1)
# ------------------------------------------------------------------------------------

BX, BY = 36.0, 12.6
EXT, STR, PRT = 0.44, 0.25, 0.12
AXES_X = [("1", 0.0), ("2", 6.0), ("3", 12.0), ("4", 18.0), ("5", 24.0), ("6", 30.0), ("7", 36.0)]
AXES_Y = [("A", 0.0), ("B", 5.7), ("C", 7.5), ("D", 12.6)]
SOUTH = [0.0, 9.0, 18.0, 27.0]
NORTH = [0.0, 7.2, 21.6, 28.8]
CORE = (14.4, 21.6)


def poly_area(pts):
    a = 0.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
        a += x0 * y1 - x1 * y0
    return abs(a) / 2.0


def rect_pts(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def m2(v):
    return f"{v:.1f}".replace(".", ",") + " m²"


def south_unit_rooms(x0):
    xl = EXT if x0 == 0.0 else x0 + STR / 2
    xr = x0 + 9.0 - STR / 2 if x0 < 27.0 else BX - EXT
    yb, yt = EXT, 5.7 - STR / 2
    return {
        "bedroom": rect_pts(xl, yb, x0 + 3.34, 3.54),
        "bath": rect_pts(xl, 3.66, x0 + 3.34, yt),
        "hall": rect_pts(x0 + 3.46, 2.6, x0 + 4.94, yt),
        "living": [(x0 + 3.46, yb), (xr, yb), (xr, yt), (x0 + 5.06, yt), (x0 + 5.06, 2.6), (x0 + 3.46, 2.6)],
        "unit": rect_pts(xl, yb, xr, yt),
        "balcony": rect_pts(x0 + 4.6, -1.5, x0 + 8.6, 0.0),
    }


def north_unit_rooms(x0):
    xl = EXT if x0 == 0.0 else x0 + STR / 2
    xr = x0 + 7.2 - STR / 2 if x0 < 28.8 else BX - EXT
    yb, yt = 7.5 + STR / 2, BY - EXT
    return {
        "bath": rect_pts(xl, yb, x0 + 2.24, 9.54),
        "hall": rect_pts(x0 + 2.36, yb, x0 + 3.3, 9.54),
        "bedroom": rect_pts(xl, 9.66, x0 + 3.24, yt),
        "living": rect_pts(x0 + 3.36, yb, xr, yt),
        "unit": rect_pts(xl, yb, xr, yt),
    }


def centroid(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (sum(xs) / len(xs), sum(ys) / len(ys))


def unit_names(level):
    if level == "ground":
        south = ["A/01", "A/02", "A/03", "A/04"]
        north = {21.6: "A/05", 28.8: "A/06"}
    else:
        south = ["A/07", "A/08", "A/09", "A/10"]
        north = {0.0: "A/11", 7.2: "A/12", 21.6: "A/13", 28.8: "A/14"}
    return south, north


def building_polygons(level):
    """Named world polygons used by the dataset (areas) and for pin placement checks."""
    out = {"building": rect_pts(0, 0, BX, BY), "corridor": rect_pts(EXT, 5.7 + STR / 2, BX - EXT, 7.5 - STR / 2),
           "staircase": rect_pts(14.4 + STR / 2, 7.5 + STR / 2, 18.0 - STR / 2, BY - EXT),
           "tech_room": rect_pts(7.2 + STR / 2, 7.5 + STR / 2, 14.4 - STR / 2, BY - EXT),
           "bike_room": rect_pts(EXT, 7.5 + STR / 2, 7.2 - STR / 2, BY - EXT)}
    south, north = unit_names(level)
    for x0, name in zip(SOUTH, south):
        r = south_unit_rooms(x0)
        out[name] = r["unit"]
        out[name + " balcony"] = r["balcony"]
        out[name + " with balcony"] = [r["unit"][0], (x0 + 4.6, EXT), (x0 + 4.6, -1.5), (x0 + 8.6, -1.5),
                                       (x0 + 8.6, EXT), r["unit"][1], r["unit"][2], r["unit"][3]]
        for room in ("bedroom", "bath", "hall", "living"):
            out[f"{name} {room}"] = r[room]
    for x0, name in north.items():
        r = north_unit_rooms(x0)
        out[name] = r["unit"]
        for room in ("bedroom", "bath", "hall", "living"):
            out[f"{name} {room}"] = r[room]
    return out


# -- wall drawing -----------------------------------------------------------------------

def _clear(w: W, x0, y0, x1, y1):
    w.rect(x0, y0, x1, y1, fill=(1, 1, 1), stroke=None)


def window_h(w: W, xa, xb, yc, t, ink=BLACK):
    _clear(w, xa, yc - t / 2, xb, yc + t / 2)
    w.rect(xa, yc - t / 2, xb, yc + t / 2, stroke=ink, lw=0.35)
    w.line(xa, yc - 0.03, xb, yc - 0.03, color=ink, lw=0.25)
    w.line(xa, yc + 0.03, xb, yc + 0.03, color=ink, lw=0.25)


def window_v(w: W, ya, yb, xc, t, ink=BLACK):
    _clear(w, xc - t / 2, ya, xc + t / 2, yb)
    w.rect(xc - t / 2, ya, xc + t / 2, yb, stroke=ink, lw=0.35)
    w.line(xc - 0.03, ya, xc - 0.03, yb, color=ink, lw=0.25)
    w.line(xc + 0.03, ya, xc + 0.03, yb, color=ink, lw=0.25)


def door_h(w: W, xa, xb, yc, t, swing_up=True, hinge_left=True, ink=BLACK):
    _clear(w, xa, yc - t / 2, xb, yc + t / 2)
    width = xb - xa
    hx = xa if hinge_left else xb
    face = yc + t / 2 if swing_up else yc - t / 2
    sign = 1 if swing_up else -1
    w.line(hx, face, hx, face + sign * width, color=ink, lw=0.45)
    if hinge_left:
        a0, a1 = (0, 90) if swing_up else (-90, 0)
    else:
        a0, a1 = (90, 180) if swing_up else (180, 270)
    w.arc(hx, face, width, a0, a1, color=ink, lw=0.25)


def door_v(w: W, ya, yb, xc, t, swing_right=True, hinge_bottom=True, ink=BLACK):
    _clear(w, xc - t / 2, ya, xc + t / 2, yb)
    width = yb - ya
    hy = ya if hinge_bottom else yb
    face = xc + t / 2 if swing_right else xc - t / 2
    sign = 1 if swing_right else -1
    w.line(face, hy, face + sign * width, hy, color=ink, lw=0.45)
    if hinge_bottom:
        a0, a1 = (0, 90) if swing_right else (90, 180)
    else:
        a0, a1 = (270, 360) if swing_right else (180, 270)
    w.arc(face, hy, width, a0, a1, color=ink, lw=0.25)


def room_label(w: W, pts, number, name, size=6.2, ink=BLACK, show_area=True, dy=0.0):
    cx, cy = centroid(pts)
    cy += dy
    w.text(cx, cy + 0.12, f"{number} {name}".strip(), size, align="center", rgb=ink)
    if show_area:
        w.text(cx, cy - 0.32, m2(poly_area(pts)), size - 0.7, align="center", rgb=ink)


def building_plan(w: W, level: str, faint: bool = False, furniture: bool = True, labels: bool = True):
    """Rzut kondygnacji budynku A (parter lub piętro typowe)."""
    wall = WALL_FAINT if faint else WALL
    ink = INK_FAINT if faint else BLACK
    lw = 0.35 if faint else 0.5
    # balconies / terraces first (under walls)
    for x0 in SOUTH:
        r = south_unit_rooms(x0)["balcony"]
        w.poly(r, fill=(0.95, 0.95, 0.95) if not faint else (0.97, 0.97, 0.97), stroke=ink, lw=0.3)
        if level == "typical":
            w.line(x0 + 4.65, -1.42, x0 + 8.55, -1.42, color=ink, lw=0.3, dash=[3, 2])
        if labels:
            w.text(x0 + 6.6, -1.0, "Balkon" if level == "typical" else "Taras", 5.5, align="center", rgb=ink)
    # external walls
    for x0, y0, x1, y1 in ((0, 0, BX, EXT), (0, BY - EXT, BX, BY), (0, 0, EXT, BY), (BX - EXT, 0, BX, BY)):
        w.rect(x0, y0, x1, y1, fill=wall, stroke=ink, lw=lw)
    # corridor walls
    for yc in (5.7, 7.5):
        w.rect(EXT, yc - STR / 2, BX - EXT, yc + STR / 2, fill=wall, stroke=ink, lw=lw)
    # unit separation walls
    for x in SOUTH[1:]:
        w.rect(x - STR / 2, EXT, x + STR / 2, 5.7 - STR / 2, fill=wall, stroke=ink, lw=lw)
    for x in (7.2, 14.4, 21.6, 28.8, 18.0):
        w.rect(x - STR / 2, 7.5 + STR / 2, x + STR / 2, BY - EXT, fill=wall, stroke=ink, lw=lw)
    # lift shaft walls
    w.rect(18.0, 10.3, 20.2, 10.5, fill=wall, stroke=ink, lw=lw)
    w.rect(20.0, 10.3, 20.2, BY - EXT, fill=wall, stroke=ink, lw=lw)
    # partitions
    pw = (0.6, 0.6, 0.62) if not faint else (0.85, 0.85, 0.87)
    north_units = [21.6, 28.8] if level == "ground" else NORTH
    for x0 in SOUTH:
        xl = EXT if x0 == 0 else x0 + STR / 2
        w.rect(x0 + 3.34, EXT, x0 + 3.46, 5.7 - STR / 2, fill=pw, stroke=ink, lw=0.3)
        w.rect(xl, 3.54, x0 + 3.34, 3.66, fill=pw, stroke=ink, lw=0.3)
        w.rect(x0 + 4.94, 2.6, x0 + 5.06, 5.7 - STR / 2, fill=pw, stroke=ink, lw=0.3)
    for x0 in north_units:
        xl = EXT if x0 == 0 else x0 + STR / 2
        w.rect(x0 + 2.24, 7.5 + STR / 2, x0 + 2.36, 9.6, fill=pw, stroke=ink, lw=0.3)
        w.rect(xl, 9.54, x0 + 3.3, 9.66, fill=pw, stroke=ink, lw=0.3)
        w.rect(x0 + 3.24, 9.54, x0 + 3.36, BY - EXT, fill=pw, stroke=ink, lw=0.3)
    if level == "ground":
        w.rect(20.2, 10.44, BX - 14.525, 10.56, fill=pw, stroke=ink, lw=0.3)  # vestibule partition
    # windows - south facade
    for x0 in SOUTH:
        window_h(w, x0 + 1.0, x0 + 2.5, EXT / 2, EXT, ink)
        window_h(w, x0 + 7.3, x0 + 8.5, EXT / 2, EXT, ink)
        door_h(w, x0 + 5.8, x0 + 6.7, EXT / 2, EXT, swing_up=True, hinge_left=False, ink=ink)
    # windows - north facade
    for x0 in north_units:
        window_h(w, x0 + 0.9, x0 + 2.4, BY - EXT / 2, EXT, ink)
        window_h(w, x0 + 4.4, x0 + 6.2, BY - EXT / 2, EXT, ink)
    if level == "ground":
        for xa in (1.2, 4.4):
            window_h(w, xa, xa + 1.2, BY - EXT / 2, EXT, ink)
        for xa in (9.0, 11.8):
            window_h(w, xa, xa + 1.2, BY - EXT / 2, EXT, ink)
        door_h(w, 20.4, 21.3, BY - EXT / 2, EXT, swing_up=False, hinge_left=True, ink=ink)
    window_h(w, 15.4, 17.0, BY - EXT / 2, EXT, ink)
    for xc in (EXT / 2, BX - EXT / 2):
        window_v(w, 6.0, 7.2, xc, EXT, ink)
    # doors from corridor
    for x0 in SOUTH:
        door_h(w, x0 + 3.6, x0 + 4.5, 5.7, STR, swing_up=False, hinge_left=True, ink=ink)
        door_v(w, 4.5, 5.2, x0 + 3.4, PRT, swing_right=False, hinge_bottom=False, ink=ink)
        door_v(w, 2.7, 3.5, x0 + 3.4, PRT, swing_right=False, hinge_bottom=True, ink=ink)
    for x0 in north_units:
        door_h(w, x0 + 2.45, x0 + 3.2, 7.5, STR, swing_up=True, hinge_left=False, ink=ink)
        door_v(w, 8.0, 8.7, x0 + 2.3, PRT, swing_right=False, hinge_bottom=True, ink=ink)
        door_h(w, x0 + 2.45, x0 + 3.15, 9.6, PRT, swing_up=True, hinge_left=True, ink=ink)
    if level == "ground":
        door_h(w, 2.6, 3.6, 7.5, STR, swing_up=True, hinge_left=True, ink=ink)
        door_h(w, 8.0, 9.0, 7.5, STR, swing_up=True, hinge_left=True, ink=ink)
        _clear(w, 18.6, 7.5 - STR / 2, 21.0, 7.5 + STR / 2)
        door_h(w, 20.35, 21.25, 10.5, PRT, swing_up=False, hinge_left=False, ink=ink)
    else:
        door_h(w, 19.2, 20.2, 7.5, STR, swing_up=True, hinge_left=True, ink=ink)
    door_h(w, 15.6, 16.6, 7.5, STR, swing_up=True, hinge_left=False, ink=ink)
    # stairs
    sx0, sx1 = 14.4 + STR / 2, 18.0 - STR / 2
    mid = (sx0 + sx1) / 2
    y = 7.9
    while y <= 10.6:
        w.line(sx0, y, mid - 0.05, y, color=ink, lw=0.25)
        w.line(mid + 0.05, y, sx1, y, color=ink, lw=0.25)
        y += 0.28
    w.rect(mid - 0.05, 7.9, mid + 0.05, 10.6, fill=(1, 1, 1), stroke=ink, lw=0.3)
    w.line((sx0 + mid) / 2, 8.0, (sx0 + mid) / 2, 10.4, color=ink, lw=0.35)
    w.poly([((sx0 + mid) / 2 - 0.12, 10.15), ((sx0 + mid) / 2 + 0.12, 10.15), ((sx0 + mid) / 2, 10.45)],
           fill=ink, stroke=None)
    # lift
    w.line(18.125, 10.5, 20.0, BY - EXT, color=ink, lw=0.25)
    w.line(18.125, BY - EXT, 20.0, 10.5, color=ink, lw=0.25)
    if not furniture:
        pass
    else:
        for x0 in SOUTH:
            r = south_unit_rooms(x0)
            bx, by = r["bedroom"][0]
            w.rect(bx + 0.3, by + 0.35, bx + 1.9, by + 2.35, stroke=ink, lw=0.25)
            w.rect(bx + 0.3, by + 2.05, bx + 1.9, by + 2.35, stroke=ink, lw=0.2)
            w.rect(x0 + 6.6, EXT + 0.4, x0 + 8.6, EXT + 1.25, stroke=ink, lw=0.25)
            w.circle(x0 + 4.6, 1.6, r_world=0.45, stroke=ink, lw=0.25)
            yt = 5.7 - STR / 2
            xr = r["unit"][1][0]
            w.rect(x0 + 5.12, yt - 0.62, xr - 0.05, yt - 0.02, stroke=ink, lw=0.25)
            w.circle(x0 + 6.0, yt - 0.32, r_world=0.18, stroke=ink, lw=0.2)
            for i, j in ((0, 0), (1, 0), (0, 1), (1, 1)):
                w.circle(x0 + 7.2 + i * 0.3, yt - 0.47 + j * 0.3, r_world=0.09, stroke=ink, lw=0.2)
            bl = EXT if x0 == 0 else x0 + STR / 2
            w.rect(bl + 0.1, yt - 1.0, bl + 1.0, yt - 0.1, stroke=ink, lw=0.25)
            w.line(bl + 0.1, yt - 1.0, bl + 1.0, yt - 0.1, color=ink, lw=0.2)
            w.circle(x0 + 2.85, yt - 0.42, r_world=0.22, stroke=ink, lw=0.25)
            w.circle(x0 + 2.0, 3.95, r_world=0.2, stroke=ink, lw=0.25)
        for x0 in north_units:
            r = north_unit_rooms(x0)
            bx, by = r["bedroom"][0]
            w.rect(bx + 0.3, BY - EXT - 2.2, bx + 1.9, BY - EXT - 0.2, stroke=ink, lw=0.25)
            lx = r["living"][0][0]
            xr = r["living"][1][0]
            w.rect(lx + 0.2, 7.5 + STR / 2 + 0.02, xr - 0.05, 7.5 + STR / 2 + 0.62, stroke=ink, lw=0.25)
            w.rect(lx + 0.8, 10.6, lx + 2.6, 11.4, stroke=ink, lw=0.25)
            bl = EXT if x0 == 0 else x0 + STR / 2
            w.rect(bl + 0.1, 7.5 + STR / 2 + 0.1, bl + 1.0, 7.5 + STR / 2 + 1.0, stroke=ink, lw=0.25)
            w.circle(x0 + 1.9, 9.15, r_world=0.2, stroke=ink, lw=0.25)
    if level == "ground":
        for i in range(8):
            w.line(0.9 + i * 0.75, 9.0, 0.9 + i * 0.75, 11.6, color=ink, lw=0.3)
        tech = [(7.8, 10.6, 9.6, 11.9, "Węzeł cieplny"), (10.0, 10.9, 11.3, 11.9, "Zasobnik c.w.u."),
                (12.2, 10.6, 14.1, 11.9, "Wodomierz DN50"), (7.6, 8.0, 8.4, 9.6, "RG")]
        for x0, y0, x1, y1, name in tech:
            w.rect(x0, y0, x1, y1, fill=(0.93, 0.93, 0.93), stroke=ink, lw=0.3)
            if labels:
                w.text((x0 + x1) / 2, (y0 + y1) / 2 - 0.08, name, 4.8, align="center", rgb=ink)
    # labels
    if labels:
        south, north = unit_names(level)
        num = 1 if level == "ground" else 1
        prefix = "0" if level == "ground" else "1"
        for x0, name in zip(SOUTH, south):
            r = south_unit_rooms(x0)
            room_label(w, r["bedroom"], f"{prefix}.{num:02d}", "Pokój", ink=ink); num += 1
            room_label(w, r["bath"], f"{prefix}.{num:02d}", "Łazienka", ink=ink, dy=-0.25); num += 1
            room_label(w, r["hall"], f"{prefix}.{num:02d}", "Przedpokój", size=5.0, ink=ink); num += 1
            room_label(w, r["living"], f"{prefix}.{num:02d}", "Pokój dzienny z aneksem", ink=ink, dy=0.45); num += 1
            area_sum = sum(poly_area(r[k]) for k in ("bedroom", "bath", "hall", "living"))
            w.text(x0 + 6.6, 1.15 - 0.55, name, 10, bold=True, align="center", rgb=BLUE if not faint else ink)
            w.text(x0 + 6.6, 0.68 - 0.45, f"M2 · {m2(area_sum)}", 6, align="center", rgb=ink)
        for x0, name in north.items():
            r = north_unit_rooms(x0)
            room_label(w, r["bedroom"], f"{prefix}.{num:02d}", "Pokój", ink=ink, dy=-0.3); num += 1
            room_label(w, r["bath"], f"{prefix}.{num:02d}", "Łazienka", size=5.0, ink=ink); num += 1
            room_label(w, r["living"], f"{prefix}.{num:02d}", "Pokój dzienny z aneksem", ink=ink, dy=0.6); num += 1
            area_sum = sum(poly_area(r[k]) for k in ("bedroom", "bath", "hall", "living"))
            cx = r["living"][0][0] + 1.8
            w.text(cx, 10.05, name, 10, bold=True, align="center", rgb=BLUE if not faint else ink)
            w.text(cx, 9.62, f"M1 · {m2(area_sum)}", 6, align="center", rgb=ink)
        polys = building_polygons(level)
        room_label(w, polys["corridor"], f"{prefix}.{num:02d}", "Korytarz", ink=ink, dy=0.05); num += 1
        w.text(16.2, 11.55, "Klatka schodowa A", 6.2, bold=True, align="center", rgb=ink)
        w.text(19.06, 11.1, "Winda", 5.5, align="center", rgb=ink)
        w.text(19.8, 8.9, "Hol windowy", 6.0, align="center", rgb=ink)
        if level == "ground":
            room_label(w, polys["bike_room"], "0.17", "Wózkownia / rowerownia", ink=ink, dy=-0.8)
            room_label(w, polys["tech_room"], "0.18", "Pomieszczenie techniczne", ink=ink, dy=-0.55)
            w.text(20.85, 11.4, "Wiatrołap", 5.0, align="center", rgb=ink)
            w.text(20.85, 12.85, "WEJŚCIE", 6.5, bold=True, align="center", rgb=ink)
        else:
            w.text(20.85, 11.4, "Szacht", 5.0, align="center", rgb=ink)


def plan_frame(w: W, faint=False, dims=True):
    axis_grid(w, AXES_X, AXES_Y, (-1.4, BX + 1.4), (-2.6, BY + 1.6), faint=faint)
    if dims:
        dim_h(w, [x for _, x in AXES_X], -2.0, y_from=-1.6)
        dim_h(w, [0.0, BX], -2.35)
        dim_v(w, [y for _, y in AXES_Y], -0.9)
        dim_v(w, [0.0, BY], -1.25)


def section_mark(w: W, x, label="A"):
    w.line(x, -2.9, x, -1.9, lw=1.6, color=BLACK)
    w.line(x, BY + 0.9, x, BY + 1.9, lw=1.6, color=BLACK)
    for yy in (-2.4, BY + 1.4):
        w.poly([(x, yy - 0.18), (x, yy + 0.18), (x - 0.45, yy)], fill=BLACK, stroke=None)
        w.text(x + 0.45, yy - 0.15, label, 9, bold=True, align="center")


def notes_block(page: Page, x, y, title, lines, size=6.2, width=330):
    page.text(x, y, title, 7.5, bold=True)
    yy = y - 11
    for line in lines:
        page.text(x, yy, line, size)
        yy -= size + 2.6
    return yy


def legend_item(page: Page, x, y, kind, color, label):
    page.stroke(color)
    page.width_(1.2 if kind != "thin" else 0.5)
    if kind == "dash":
        page.dash([4, 2])
    page.line(x, y + 2.5, x + 22, y + 2.5)
    page.dash()
    page.text(x + 28, y, label, 6.2)


# ------------------------------------------------------------------------------------
# Sheets — project A (Osiedle Zielone Tarasy, Etap I)
# ------------------------------------------------------------------------------------

PROJECT_A = "Osiedle Zielone Tarasy — Etap I · Budynek A"
INVESTOR_A = "Inwestor: Zielone Tarasy Development Sp. z o.o. (podmiot fikcyjny)"
PLAN_ORIGIN = (90.0, 330.0)


def _plan_page():
    page = Page(*A3_LANDSCAPE)
    w = W(page, 100, *PLAN_ORIGIN)
    return page, w


def sheet_ground_floor(info):
    page, w = _plan_page()
    begin_content(page)
    plan_frame(w)
    building_plan(w, "ground")
    section_mark(w, 12.9)
    north_arrow(page, 1080, 760)
    notes_block(page, 40, 175, "Uwagi", [
        "1. Wymiary w milimetrach, poziomy w metrach. ±0,00 = 112,40 m n.p.m. (wartość fikcyjna).",
        "2. Ściany zewnętrzne: silikat 24 cm + EPS 20 cm (lambda = 0,031 W/mK). Ściany międzylokalowe: silikat 25 cm.",
        "3. Ścianki działowe: silikat 12 cm. Drzwi do lokali EI30 Rw=37 dB.",
        "4. Progi drzwi balkonowych — patrz detal D-1, rysunek A-501.",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*PLAN_ORIGIN, w.k)]


def sheet_typical_floor(info):
    page, w = _plan_page()
    begin_content(page)
    plan_frame(w)
    building_plan(w, "typical")
    section_mark(w, 12.9)
    north_arrow(page, 1080, 760)
    notes_block(page, 40, 175, "Uwagi", [
        "1. Rzut obowiązuje dla kondygnacji +1 do +3; numeracja lokali dla piętra 1 (piętro 2: +8, piętro 3: +16).",
        "2. Balkony na łącznikach termoizolacyjnych, balustrady szklane h=1,10 m.",
        "3. Hydroizolacja balkonów i progów wg detalu D-1 (A-501).",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*PLAN_ORIGIN, w.k)]


GARAGE_X = (-6.0, 42.0)
GARAGE_Y = (-17.4, 12.6)


def garage_polygons():
    hall = [(-5.7, -14.6), (41.7, -14.6), (41.7, 7.4), (36.0, 7.4), (36.0, 12.3), (21.6, 12.3), (21.6, 7.4),
            (14.4, 7.4), (14.4, 12.3), (0.0, 12.3), (0.0, 7.4), (-5.7, 7.4)]
    return {"hall": hall, "pump_room": rect_pts(-5.7, 7.4, 0.0, 12.3), "fan_room": rect_pts(36.0, 7.4, 41.7, 12.3),
            "storage": rect_pts(-5.7, -17.1, 41.7, -14.6), "core": rect_pts(14.4, 7.4, 21.6, 12.3)}


def garage_spaces():
    """Parking spaces as (label, x0, y0, x1, y1); two per 6.0 m bay."""
    rows = [(-14.6, -9.6), (-3.6, 1.4), (7.4, 12.3)]
    spaces = []
    n = 1
    for (y0, y1) in rows:
        for bay in range(-1, 7):
            bx = bay * 6.0
            for i in range(2):
                x0 = bx + 0.4 + i * 2.6
                x1 = x0 + 2.5
                if x0 < -5.6 or x1 > 41.6:
                    continue
                if y0 == 7.4 and (x1 > 14.4 and x0 < 21.6 or x1 > 36.0 or x0 < 0.0):
                    continue
                spaces.append((f"P{n:02d}", x0, y0, x1, y1))
                n += 1
    return spaces


def sheet_garage(info):
    page = Page(*A3_LANDSCAPE)
    origin = (150.0 + 6.0 * (1000 / 200 * MM), 300.0 + 17.4 * (1000 / 200 * MM))
    w = W(page, 200, *origin)
    begin_content(page)
    gx0, gx1 = GARAGE_X
    gy0, gy1 = GARAGE_Y
    axis_grid(w, AXES_X, [("A", 0.0), ("D", 12.6)], (gx0 - 2.0, gx1 + 2.0), (gy0 - 2.5, gy1 + 2.0))
    w.rect(gx0, gy0, gx1, gy1, fill=WALL, stroke=BLACK, lw=0.6)
    w.rect(gx0 + 0.3, gy0 + 0.3, gx1 - 0.3, gy1 - 0.3, fill=(1, 1, 1), stroke=BLACK, lw=0.4)
    polys = garage_polygons()
    w.poly(polys["storage"], fill=(0.94, 0.94, 0.94), stroke=BLACK, lw=0.3)
    for i in range(16):
        x = -5.7 + i * 2.9625
        w.line(x, -17.1, x, -14.6, lw=0.25)
    w.text(18.0, -16.0, "-1.04 Komórki lokatorskie (16 szt.)", 6, align="center")
    w.poly(polys["pump_room"], fill=(0.94, 0.94, 0.94), stroke=BLACK, lw=0.4)
    w.text(-2.85, 9.9, "-1.02 Pompownia", 5.5, align="center")
    w.poly(polys["fan_room"], fill=(0.94, 0.94, 0.94), stroke=BLACK, lw=0.4)
    w.text(38.85, 9.9, "-1.03 Wentylatornia", 5.5, align="center")
    w.poly(polys["core"], fill=(0.9, 0.9, 0.9), stroke=BLACK, lw=0.4)
    w.text(18.0, 10.4, "Klatka A + winda", 5.5, align="center")
    for x0, y0, x1, y1 in ((14.4, 7.4, 14.65, 12.3), (21.35, 7.4, 21.6, 12.3), (14.4, 7.4, 21.6, 7.65)):
        w.rect(x0, y0, x1, y1, fill=WALL, stroke=BLACK, lw=0.3)
    for label, x0, y0, x1, y1 in garage_spaces():
        w.rect(x0, y0, x1, y1, stroke=(0.3, 0.3, 0.3), lw=0.3)
        w.text((x0 + x1) / 2, (y0 + y1) / 2 - 0.3, label, 4.8, align="center")
    for x in (0.0, 6.0, 12.0, 18.0, 24.0, 30.0, 36.0):
        for y in (-14.6, -3.6, 1.4, 7.4):
            if 14.4 <= x <= 21.6 and y >= 7.4:
                continue
            w.rect(x - 0.25, y - 0.25, x + 0.25, y + 0.25, fill=WALL, stroke=BLACK, lw=0.3)
    for y_mid in (-6.6, 4.4):
        w.line(-4.5, y_mid, 40.5, y_mid, color=(0.3, 0.3, 0.3), lw=0.4, dash=[6, 4])
        for x in (-2.0, 9.0, 21.0, 33.0):
            w.rect(x - 0.15, y_mid - 0.15, x + 0.15, y_mid + 0.15, stroke=BLUE, lw=0.4)
            w.text(x, y_mid + 0.35, "WP", 4.5, align="center", rgb=BLUE)
    _clear(w, gx1 - 0.3, -9.6, gx1, -3.6)
    w.rect(gx1, -9.6, gx1 + 6.0, -3.6, fill=(0.93, 0.93, 0.93), stroke=BLACK, lw=0.4)
    for i in range(1, 12):
        w.line(gx1 + i * 0.5, -9.6, gx1 + i * 0.5, -3.6, lw=0.2)
    w.text(gx1 + 3.0, -2.9, "Rampa zjazdowa 12%", 6, align="center")
    w.rect(gx1 - 0.6, -9.6, gx1 - 0.3, -3.6, fill=(0.6, 0.75, 0.95), stroke=BLUE, lw=0.4)
    w.text(16.5, -6.0, "Droga manewrowa — szer. 6,0 m", 6, align="center")
    w.text(4.0, 4.0, "-1.01 Hala garażowa", 7, bold=True, align="center")
    w.text(4.0, 3.2, f"{len(garage_spaces())} miejsc postojowych · {m2(poly_area(polys['hall']))}", 5.8,
           align="center")
    w.p.dash([5, 3])
    w.rect(0.0, 0.0, BX, BY, stroke=(0.5, 0.5, 0.55), lw=0.5)
    w.p.dash()
    w.text(30.0, 11.6, "obrys budynku A nad garażem", 5.5, align="center", rgb=(0.4, 0.4, 0.45))
    dim_h(w, [gx0, 0.0, 18.0, 36.0, gx1], gy0 - 1.6, y_from=gy0)
    dim_v(w, [gy0, -14.6, -9.6, -3.6, 1.4, 7.4, gy1], gx0 - 1.2, x_from=gx0)
    north_arrow(page, 1080, 760)
    notes_block(page, 40, 175, "Uwagi", [
        "1. Posadzka żywiczna na płycie fundamentowej gr. 60 cm, spadek 1% do wpustów WP.",
        "2. Strop nad garażem — dach zielony dziedzińca (patrz przekrój A-A, A-201).",
        "3. Wentylacja mechaniczna garażu z detekcją CO/LPG — patrz S-201.",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*origin, w.k)]


def sheet_section(info):
    page = Page(*A3_LANDSCAPE)
    k = 1000 / 100 * MM
    origin = (60.0 + 17.4 * k, 330.0)
    w = W(page, 100, *origin)
    begin_content(page)
    u0, u1 = -17.4, 12.6
    # ground / soil
    w.hatch(-19.5, -4.4, u0, 0.0, spacing_pt=6, color=(0.6, 0.5, 0.35))
    w.hatch(u1, -4.4, 14.6, -0.15, spacing_pt=6, color=(0.6, 0.5, 0.35))
    w.line(-19.5, 0.0, u0, 0.0, lw=0.8)
    w.line(u1, -0.15, 14.6, -0.15, lw=0.8)
    # foundation slab, garage walls, slab over garage
    w.rect(u0, -3.9, u1, -3.3, fill=CONCRETE, stroke=BLACK, lw=0.5)
    w.hatch(u0, -3.9, u1, -3.3, spacing_pt=5, color=(0.55, 0.55, 0.55))
    for a, b in ((u0, u0 + 0.3), (u1 - 0.3, u1)):
        w.rect(a, -3.3, b, -0.3, fill=CONCRETE, stroke=BLACK, lw=0.5)
    w.rect(u0, -0.3, u1, 0.0, fill=CONCRETE, stroke=BLACK, lw=0.5)
    w.rect(u0, 0.0, -0.6, 0.5, fill=LIGHT_GREEN, stroke=GREEN, lw=0.4)
    w.text(-9.0, 0.15, "Dach zielony dziedzińca — substrat 50 cm", 6, align="center", rgb=GREEN)
    w.text(-5.0, -2.0, "Garaż podziemny  -1.01", 7, bold=True, align="center")
    for u in (-14.6, -9.6, -3.6, 1.4, 5.7):
        w.rect(u - 0.25, -3.3, u + 0.25, -0.3, fill=CONCRETE, stroke=BLACK, lw=0.3)
    # building
    levels = [0.0, 3.0, 6.0, 9.0]
    for i, lvl in enumerate(levels):
        top = lvl + 2.75
        for a, b in ((0.0, EXT), (BY - EXT, BY)):
            w.rect(a, lvl, b, top, fill=WALL, stroke=BLACK, lw=0.5)
            _clear(w, a, lvl + 0.9, b, lvl + 2.4)
            w.rect(a, lvl + 0.9, b, lvl + 2.4, stroke=BLACK, lw=0.3)
            w.line((a + b) / 2, lvl + 0.9, (a + b) / 2, lvl + 2.4, lw=0.25)
        for uc in (5.7, 7.5):
            w.rect(uc - STR / 2, lvl, uc + STR / 2, top, fill=WALL, stroke=BLACK, lw=0.4)
            _clear(w, uc - STR / 2, lvl, uc + STR / 2, lvl + 2.1)
        w.rect(0.0, top, BY, top + 0.25, fill=CONCRETE, stroke=BLACK, lw=0.5)
        w.hatch(0.0, top, BY, top + 0.25, spacing_pt=4.5, color=(0.55, 0.55, 0.55))
        w.line(EXT, lvl + 0.08, BY - EXT, lvl + 0.08, lw=0.25, color=(0.4, 0.4, 0.4))
        if i >= 1:
            w.rect(-1.5, lvl - 0.2, 0.0, lvl, fill=CONCRETE, stroke=BLACK, lw=0.4)
            w.line(-1.42, lvl, -1.42, lvl + 1.1, lw=0.6, color=(0.3, 0.5, 0.75))
            w.line(-1.5, lvl + 1.1, -1.3, lvl + 1.1, lw=0.6, color=(0.3, 0.5, 0.75))
        south_unit = ["A/02", "A/08", "A/16", "A/24"][i]
        north_unit = ["Pom. techniczne", "A/12", "A/20", "A/28"][i]
        w.text(2.9, lvl + 1.5, f"Lokal {south_unit}" if i else "Lokal A/02", 6.2, align="center")
        w.text(6.6, lvl + 1.5, "Korytarz", 5.5, align="center")
        w.text(10.1, lvl + 1.5, north_unit if i == 0 else f"Lokal {north_unit}", 6.2, align="center")
    # roof
    w.rect(0.0, 11.75, BY, 12.0, fill=CONCRETE, stroke=BLACK, lw=0.5)
    w.rect(0.3, 12.0, BY - 0.3, 12.3, fill=(1.0, 0.97, 0.75), stroke=BLACK, lw=0.3)
    w.hatch(0.3, 12.0, BY - 0.3, 12.3, spacing_pt=3, color=(0.75, 0.65, 0.2))
    w.line(0.3, 12.32, BY - 0.3, 12.32, lw=1.0, color=BLUE)
    for a, b in ((0.0, 0.3), (BY - 0.3, BY)):
        w.rect(a, 12.0, b, 13.2, fill=WALL, stroke=BLACK, lw=0.5)
    w.rect(-0.05, 13.2, 0.35, 13.28, fill=(0.4, 0.4, 0.45), stroke=None)
    w.rect(BY - 0.35, 13.2, BY + 0.05, 13.28, fill=(0.4, 0.4, 0.45), stroke=None)
    w.text(6.3, 12.6, "Stropodach: XPS 30 cm + membrana PVC 1,5 mm, spadek 2%", 6, align="center")
    # levels
    for lvl, lab in ((13.2, "+13,20 attyka"), (12.0, "+12,00"), (9.0, "+9,00"), (6.0, "+6,00"), (3.0, "+3,00"),
                     (0.0, "±0,00"), (-0.3, "-0,30"), (-3.3, "-3,30"), (-3.9, "-3,90")):
        x = 14.2
        w.line(BY + 0.2, lvl, x + 1.6, lvl, lw=0.25, color=(0.45, 0.45, 0.45))
        w.poly([(x, lvl), (x + 0.25, lvl + 0.3), (x - 0.25, lvl + 0.3)], fill=None, stroke=BLACK, lw=0.4)
        w.text(x + 0.35, lvl + 0.1, lab, 6.5, align="left")
    axis_grid(w, [(n, u) for n, u in AXES_Y], [], (0, 0), (-4.4, 14.4))
    dim_v(w, [0.0, 3.0, 6.0, 9.0, 12.0, 13.2], -2.4, x_from=-1.6)
    dim_v(w, [-3.9, -3.3, 0.0], -2.4, x_from=u0)
    w.text(-8.0, 9.5, "PRZEKRÓJ A-A", 16, bold=True, align="center")
    w.text(-8.0, 8.6, "przez lokale A/02, A/12 — oś 3/4 (x = 12,90 m)", 7, align="center")
    end_content(page)
    title_block(page, info)
    return [page], [(*origin, w.k)]


def sheet_elevation(info):
    page = Page(*A3_LANDSCAPE)
    origin = (90.0, 300.0)
    w = W(page, 100, *origin)
    begin_content(page)
    w.hatch(-1.5, -1.2, BX + 1.5, 0.0, spacing_pt=6, color=(0.6, 0.5, 0.35))
    w.line(-1.5, 0.0, BX + 1.5, 0.0, lw=0.9)
    w.rect(0.0, 0.0, BX, 3.0, fill=(0.42, 0.43, 0.46), stroke=BLACK, lw=0.5)
    for x in range(1, 36):
        w.line(x * 1.0, 0.0, x * 1.0, 3.0, lw=0.2, color=(0.3, 0.3, 0.33))
    w.rect(0.0, 3.0, BX, 12.0, fill=(0.97, 0.97, 0.96), stroke=BLACK, lw=0.5)
    w.rect(0.0, 12.0, BX, 13.2, fill=(0.80, 0.80, 0.80), stroke=BLACK, lw=0.5)
    w.rect(-0.05, 13.2, BX + 0.05, 13.3, fill=(0.3, 0.3, 0.33), stroke=None)
    glass = (0.70, 0.82, 0.92)
    for lvl in (0.0, 3.0, 6.0, 9.0):
        for x0 in SOUTH:
            for xa, xb, low in ((x0 + 1.0, x0 + 2.5, 0.9), (x0 + 7.3, x0 + 8.5, 0.9), (x0 + 5.8, x0 + 6.7, 0.0)):
                w.rect(xa, lvl + low, xb, lvl + 2.4, fill=glass, stroke=BLACK, lw=0.45)
                w.line((xa + xb) / 2, lvl + low, (xa + xb) / 2, lvl + 2.4, lw=0.25)
                w.rect(xa - 0.05, lvl + low - 0.06, xb + 0.05, lvl + low, fill=(0.3, 0.3, 0.33), stroke=None)
            if lvl > 0:
                w.rect(x0 + 4.6, lvl - 0.2, x0 + 8.6, lvl, fill=(0.75, 0.75, 0.75), stroke=BLACK, lw=0.4)
                w.rect(x0 + 4.6, lvl, x0 + 8.6, lvl + 1.1, fill=(0.85, 0.92, 0.97), stroke=(0.35, 0.5, 0.65), lw=0.4)
    for x in (0.3, BX - 0.3):
        w.line(x, 0.2, x, 12.4, lw=1.2, color=(0.35, 0.35, 0.38))
    for lvl, lab in ((13.2, "+13,20"), (12.0, "+12,00"), (9.0, "+9,00"), (6.0, "+6,00"), (3.0, "+3,00"),
                     (0.0, "±0,00")):
        x = -2.4
        w.line(x + 0.3, lvl, 0.0, lvl, lw=0.25, color=(0.45, 0.45, 0.45))
        w.poly([(x, lvl), (x + 0.25, lvl + 0.3), (x - 0.25, lvl + 0.3)], fill=None, stroke=BLACK, lw=0.4)
        w.text(x - 0.35, lvl + 0.1, lab, 6.5, align="right")
    axis_grid(w, AXES_X, [], (0, 0), (-2.0, 14.6))
    leader(w, 12.0, 4.5, 14.0, 15.6, "1 Tynk cienkowarstwowy silikonowy, RAL 9010, na EPS 20 cm")
    leader(w, 3.0, 1.5, 5.5, 15.0, "2 Płyty elewacyjne włóknocementowe, grafit (cokół i parter)")
    leader(w, 24.6, 6.5, 26.0, 15.6, "3 Balustrady szklane VSG 8.8.2, h = 1,10 m")
    leader(w, 33.0, 12.7, 30.0, 15.0, "4 Attyka — obróbki z blachy powlekanej RAL 7016")
    dim_h(w, [x for _, x in AXES_X], -1.6)
    w.text(18.0, -3.6, "ELEWACJA POŁUDNIOWA (od strony dziedzińca)", 12, bold=True, align="center")
    end_content(page)
    title_block(page, info)
    return [page], [(*origin, w.k)]


def sheet_detail(info):
    page = Page(*A3_LANDSCAPE)
    origin = (120.0, 330.0)
    w = W(page, 5, *origin)
    begin_content(page)
    # interior slab and floor build-up (left), balcony slab (right)
    w.rect(0.0, 0.10, 0.55, 0.32, fill=CONCRETE, stroke=BLACK, lw=0.6)
    w.hatch(0.0, 0.10, 0.55, 0.32, spacing_pt=7, color=(0.55, 0.55, 0.55))
    w.rect(0.0, 0.32, 0.50, 0.35, fill=(1.0, 0.97, 0.75), stroke=BLACK, lw=0.3)
    w.hatch(0.0, 0.32, 0.50, 0.35, spacing_pt=3, color=(0.8, 0.7, 0.2))
    w.rect(0.0, 0.35, 0.50, 0.41, fill=(0.88, 0.88, 0.88), stroke=BLACK, lw=0.3)
    w.rect(0.0, 0.41, 0.50, 0.42, fill=(0.55, 0.40, 0.25), stroke=None)
    w.rect(0.55, 0.12, 0.62, 0.32, fill=(1.0, 0.97, 0.75), stroke=BLACK, lw=0.5)
    w.hatch(0.55, 0.12, 0.62, 0.32, spacing_pt=3, color=(0.8, 0.7, 0.2))
    w.poly([(0.62, 0.12), (1.10, 0.13), (1.10, 0.31), (0.62, 0.32)], fill=CONCRETE, stroke=BLACK, lw=0.6)
    w.hatch(0.63, 0.13, 1.09, 0.31, spacing_pt=7, color=(0.55, 0.55, 0.55))
    # waterproofing membrane: along balcony, up the door frame (upturn >= 150 mm)
    membrane = [(1.08, 0.315), (0.64, 0.325), (0.585, 0.33), (0.585, 0.49)]
    w.poly(membrane, stroke=BLUE, lw=2.4, close=False)
    w.poly([(0.62, 0.335), (1.10, 0.326), (1.10, 0.338), (0.62, 0.347)], fill=(0.85, 0.85, 0.85), stroke=BLACK,
           lw=0.3)
    for i in range(5):
        x0 = 0.64 + i * 0.09
        w.rect(x0, 0.347 - i * 0.0018, x0 + 0.085, 0.362 - i * 0.0018, fill=(0.75, 0.55, 0.45), stroke=BLACK, lw=0.3)
    w.poly([(1.10, 0.31), (1.135, 0.31), (1.135, 0.27), (1.12, 0.27), (1.12, 0.30), (1.10, 0.30)],
           fill=(0.6, 0.6, 0.65), stroke=BLACK, lw=0.3)
    # door frame and threshold
    w.rect(0.50, 0.42, 0.585, 0.64, fill=(0.95, 0.95, 0.95), stroke=BLACK, lw=0.6)
    w.rect(0.515, 0.44, 0.57, 0.62, stroke=BLACK, lw=0.3)
    w.rect(0.47, 0.405, 0.60, 0.425, fill=(0.6, 0.6, 0.65), stroke=BLACK, lw=0.3)
    w.rect(0.485, 0.42, 0.50, 0.49, fill=(0.2, 0.2, 0.2), stroke=None)
    w.rect(0.585, 0.33, 0.60, 0.49, fill=(0.95, 0.5, 0.1), stroke=None)
    # dimensions and slope
    dim_v(w, [0.338, 0.49], 0.66, x_from=0.59)
    w.text(0.705, 0.42, "min. 150", 7, align="left")
    w.line(0.78, 0.40, 0.98, 0.396, lw=0.5)
    w.poly([(0.98, 0.396), (0.96, 0.404), (0.96, 0.388)], fill=BLACK, stroke=None)
    w.text(0.88, 0.41, "spadek 2%", 7, align="center")
    labels = [
        (0.25, 0.20, 0.10, 0.60, "1 Strop żelbetowy gr. 22 cm, C30/37"),
        (0.58, 0.22, 0.20, 0.66, "2 Łącznik termoizolacyjny płyty balkonowej"),
        (0.95, 0.22, 0.85, 0.08, "3 Płyta balkonowa, spadek 2% od budynku"),
        (0.585, 0.46, 0.75, 0.62, "4 Hydroizolacja podpłytkowa 2K, wywinięcie min. 15 cm"),
        (0.592, 0.40, 0.92, 0.58, "5 Taśma uszczelniająca w narożu i przy ramie"),
        (0.80, 0.355, 1.00, 0.52, "6 Płytki mrozoodporne na kleju C2S1"),
        (1.13, 0.29, 1.05, 0.04, "7 Okapnik — profil aluminiowy"),
        (0.54, 0.60, 0.30, 0.72, "8 Rama drzwi balkonowych, próg niski 20 mm"),
        (0.25, 0.38, 0.05, 0.50, "9 Wylewka 6 cm + izolacja akustyczna 3 cm"),
    ]
    for x0, y0, x1, y1, text in labels:
        leader(w, x0, y0, x1, y1, text, size=7.5)
    w.text(0.55, 0.80, "DETAL D-1 — PRÓG DRZWI BALKONOWYCH", 13, bold=True, align="center")
    w.text(0.55, 0.765, "przekrój pionowy, skala 1:5", 8, align="center")
    end_content(page)
    title_block(page, info)
    return [page], [(*origin, w.k)]


def sheet_structure(info):
    page, w = _plan_page()
    begin_content(page)
    plan_frame(w, dims=True)
    building_plan(w, "ground", faint=True, furniture=False, labels=False)
    # load-bearing walls highlighted
    for x0, y0, x1, y1 in ((0, 0, BX, EXT), (0, BY - EXT, BX, BY), (0, 0, EXT, BY), (BX - EXT, 0, BX, BY)):
        w.rect(x0, y0, x1, y1, fill=(0.35, 0.35, 0.4), stroke=BLACK, lw=0.5)
    for yc in (5.7, 7.5):
        w.rect(EXT, yc - STR / 2, BX - EXT, yc + STR / 2, fill=(0.35, 0.35, 0.4), stroke=BLACK, lw=0.4)
    for x in (9.0, 18.0, 27.0):
        w.rect(x - STR / 2, EXT, x + STR / 2, 5.7 - STR / 2, fill=(0.35, 0.35, 0.4), stroke=BLACK, lw=0.4)
    for x in (7.2, 14.4, 18.0, 21.6, 28.8):
        w.rect(x - STR / 2, 7.5 + STR / 2, x + STR / 2, BY - EXT, fill=(0.35, 0.35, 0.4), stroke=BLACK, lw=0.4)
    # slab panels and reinforcement callouts
    for i, (x0, x1) in enumerate(((0.44, 9.0), (9.0, 18.0), (18.0, 27.0), (27.0, 35.56))):
        w.text((x0 + x1) / 2, 3.3, f"PŁ-{i + 1}", 9, bold=True, align="center", rgb=BLUE)
        w.text((x0 + x1) / 2, 2.6, "gr. 22 cm · C30/37", 6, align="center", rgb=BLUE)
        w.line(x0 + 0.6, 1.6, x1 - 0.6, 1.6, color=RED, lw=0.6)
        w.text((x0 + x1) / 2, 1.75, "dołem #12 co 150", 5.5, align="center", rgb=RED)
    for x0, x1 in ((0.44, 7.2), (7.2, 14.4), (21.6, 28.8), (28.8, 35.56)):
        w.text((x0 + x1) / 2, 10.6, "PŁ-5  gr. 22 cm", 7, bold=True, align="center", rgb=BLUE)
        w.line(x0 + 0.5, 9.8, x1 - 0.5, 9.8, color=RED, lw=0.6)
        w.text((x0 + x1) / 2, 9.95, "dołem #10 co 150", 5.5, align="center", rgb=RED)
    for x0 in SOUTH:
        w.line(x0 + 4.6, 0.05, x0 + 8.6, 0.05, color=ORANGE, lw=2.0, dash=[3, 1.5])
    w.text(18.0, -1.0, "łączniki termoizolacyjne balkonów (typ wg producenta)", 6, align="center", rgb=ORANGE)
    w.line(-0.2, -0.2, -0.2, BY + 0.2, color=(0.2, 0.5, 0.2), lw=0.6, dash=[6, 2])
    w.text(-0.6, 6.3, "wieniec W1 25×25", 5.5, align="center", angle=90, rgb=(0.2, 0.5, 0.2))
    # slab openings for risers (one per unit bathroom)
    openings = []
    for x0 in SOUTH:
        openings.append((x0 + 2.6, 4.85))
    for x0 in NORTH:
        openings.append((x0 + 1.6, 8.0))
    for i, (x, y) in enumerate(openings):
        w.rect(x - 0.2, y - 0.15, x + 0.2, y + 0.15, fill=(1, 1, 1), stroke=BLACK, lw=0.4)
        w.line(x - 0.2, y - 0.15, x + 0.2, y + 0.15, lw=0.3)
        w.line(x - 0.2, y + 0.15, x + 0.2, y - 0.15, lw=0.3)
        w.text(x, y + 0.25, f"K{i + 1}", 5, bold=True, align="center")
    w.line(18.0, -0.6, 18.0, BY + 0.6, color=RED, lw=0.9, dash=[8, 3])
    w.text(18.3, BY + 0.9, "przerwa robocza — oś 4 (do uzgodnienia z projektantem)", 6, align="left", rgb=RED)
    notes_block(page, 40, 175, "Konstrukcja — uwagi", [
        "1. Strop płytowy żelbetowy gr. 22 cm, beton C30/37 XC1, stal B500SP, otulina 25 mm.",
        "2. Otwory K1–K8 pod piony kanalizacyjne 40×30 cm — lokalizacja wg branży sanitarnej.",
        "3. Rozdeskowanie stropu po osiągnięciu 70% wytrzymałości (potwierdzenie badaniem).",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*PLAN_ORIGIN, w.k)]


def sheet_sanitary(info):
    page, w = _plan_page()
    begin_content(page)
    plan_frame(w, faint=True, dims=False)
    building_plan(w, "ground", faint=True, furniture=False, labels=True)
    w.poly(building_polygons("ground")["tech_room"], fill=None, stroke=RED, lw=0.6)
    # mains from the technical room along the corridor
    for y, color, dash, name in ((6.25, BLUE, None, "W"), (6.55, HOT, None, "C"), (6.85, CIRC, [3, 2], "Cyrk.")):
        w.line(8.4, y, 34.8, y, color=color, lw=1.0, dash=dash)
        w.line(1.2, y, 8.4, y, color=color, lw=1.0, dash=dash)
        w.text(34.95, y - 0.1, name, 5.5, align="left", rgb=color)
    w.line(11.0, 7.5, 11.0, 10.6, color=BLUE, lw=1.0)
    w.line(11.4, 7.5, 11.4, 10.9, color=HOT, lw=1.0)
    risers = []
    for x0 in SOUTH:
        risers.append((x0 + 2.6, 5.3))
    for x0 in (21.6, 28.8):
        risers.append((x0 + 1.6, 7.95))
    for i, (x, y) in enumerate(risers):
        w.circle(x, y, r_world=0.13, fill=(1, 1, 1), stroke=SEWER, lw=0.8)
        w.text(x, y - 0.45, f"PK{i + 1}", 5, bold=True, align="center", rgb=SEWER)
        w.circle(x + 0.35, y, r_world=0.08, fill=(1, 1, 1), stroke=BLUE, lw=0.6)
        w.line(x + 0.35, y, x + 0.35, 6.25, color=BLUE, lw=0.6)
    for x0 in SOUTH:
        yt = 5.7 - STR / 2
        bl = EXT if x0 == 0 else x0 + STR / 2
        w.line(bl + 0.55, yt - 0.55, x0 + 2.6, 5.3, color=SEWER, lw=0.7, dash=[4, 1.5])
        w.rect(bl + 0.45, yt - 0.65, bl + 0.65, yt - 0.45, stroke=SEWER, lw=0.6)
        w.text(bl + 0.55, yt - 0.95, "WP", 4.5, align="center", rgb=SEWER)
    w.text(10.75, 11.9, "Zestaw wodomierza głównego DN50", 5.2, align="center", rgb=BLUE)
    w.text(10.75, 8.5, "Przejścia przez ścianę EI60 — uszczelnienie systemowe", 5.0, align="center", rgb=RED)
    w.line(7.325, 9.2, 8.4, 9.2, color=BLUE, lw=1.0)
    w.line(7.325, 9.4, 8.4, 9.4, color=HOT, lw=1.0)
    legend = [("line", BLUE, "Woda zimna (W) — PE-X 25×3,5 / 20×2,8"), ("line", HOT, "Ciepła woda użytkowa (C)"),
              ("dash", CIRC, "Cyrkulacja c.w.u."), ("dash", SEWER, "Kanalizacja sanitarna, piony PK DN110")]
    yy = 175
    page.text(40, yy, "Legenda", 7.5, bold=True)
    for kind, color, label in legend:
        yy -= 12
        legend_item(page, 40, yy, kind, color, label)
    end_content(page)
    title_block(page, info)
    return [page], [(*PLAN_ORIGIN, w.k)]


def sheet_ventilation(info):
    page, w = _plan_page()
    begin_content(page)
    plan_frame(w, faint=True, dims=False)
    building_plan(w, "ground", faint=True, furniture=False, labels=True)
    w.rect(1.0, 6.05, 35.0, 6.45, fill=(0.85, 0.93, 0.95), stroke=DUCT, lw=0.8)
    w.text(4.0, 6.6, "kanał nawiewny 400×200", 5.2, align="left", rgb=DUCT)
    w.rect(1.0, 6.85, 35.0, 7.15, fill=(0.92, 0.95, 0.97), stroke=DUCT, lw=0.6)
    w.text(4.0, 7.25, "kanał wywiewny 315×200", 5.2, align="left", rgb=DUCT)
    w.rect(19.9, 10.55, 20.15, 12.0, fill=(0.85, 0.93, 0.95), stroke=DUCT, lw=0.6)
    w.text(19.1, 12.4, "pion W1 do centrali CW-1 (dach)", 5.2, align="center", rgb=DUCT)
    for x0 in SOUTH:
        x = x0 + 4.05
        w.line(x, 6.05, x, 4.6, color=DUCT, lw=0.8)
        w.circle(x, 4.4, r_world=0.18, stroke=DUCT, lw=0.6)
        w.text(x + 0.35, 4.1, "Ø125", 4.8, align="left", rgb=DUCT)
        w.rect(x - 0.15, 5.55, x + 0.15, 5.85, fill=(1, 1, 1), stroke=RED, lw=0.6)
        w.line(x - 0.15, 5.55, x + 0.15, 5.85, color=RED, lw=0.5)
    for x0 in (21.6, 28.8):
        x = x0 + 2.8
        w.line(x, 7.15, x, 8.9, color=DUCT, lw=0.8)
        w.circle(x, 9.1, r_world=0.18, stroke=DUCT, lw=0.6)
        w.rect(x - 0.15, 7.35, x + 0.15, 7.65, fill=(1, 1, 1), stroke=RED, lw=0.6)
        w.line(x - 0.15, 7.35, x + 0.15, 7.65, color=RED, lw=0.5)
    w.line(23.5, 5.5, 23.5, 7.4, color=ORANGE, lw=1.4, dash=[4, 2])
    w.line(23.5, 6.2, 35.3, 6.2, color=ORANGE, lw=1.4, dash=[4, 2])
    w.text(30.5, 5.8, "koryto kablowe 200×60 (branża E) — koordynacja", 5.0, align="center", rgb=ORANGE)
    legend = [("line", DUCT, "Kanały wentylacyjne (blacha ocynkowana)"), ("thin", RED, "KPP — klapa przeciwpożarowa"),
              ("dash", ORANGE, "Trasy kablowe branży elektrycznej")]
    yy = 175
    page.text(40, yy, "Legenda", 7.5, bold=True)
    for kind, color, label in legend:
        yy -= 12
        legend_item(page, 40, yy, kind, color, label)
    end_content(page)
    title_block(page, info)
    return [page], [(*PLAN_ORIGIN, w.k)]


def sheet_electrical(info_lighting, info_sockets):
    pages, transforms = [], []
    for variant, info in (("lighting", info_lighting), ("sockets", info_sockets)):
        page, w = _plan_page()
        begin_content(page)
        plan_frame(w, faint=True, dims=False)
        building_plan(w, "ground", faint=True, furniture=False, labels=True)
        w.rect(7.6, 8.0, 8.4, 9.6, fill=(1.0, 0.9, 0.7), stroke=ORANGE, lw=0.8)
        w.text(8.0, 8.65, "RG", 6, bold=True, align="center", rgb=ORANGE)
        tms = [(x0 + 4.75, 5.35) for x0 in SOUTH] + [(x0 + 2.75, 7.85) for x0 in (21.6, 28.8)]
        for x, y in tms:
            w.rect(x - 0.2, y - 0.12, x + 0.2, y + 0.12, fill=(1.0, 0.9, 0.7), stroke=ORANGE, lw=0.6)
            w.text(x, y + 0.2, "TM", 4.5, bold=True, align="center", rgb=ORANGE)
        if variant == "lighting":
            for i in range(11):
                x = 1.6 + i * 3.2
                if i % 3 == 1:
                    w.rect(x - 0.18, 6.42, x + 0.18, 6.78, fill=(0.85, 1.0, 0.85), stroke=GREEN, lw=0.6)
                    w.text(x, 6.95, "AW", 4.5, bold=True, align="center", rgb=GREEN)
                else:
                    w.circle(x, 6.6, r_world=0.17, stroke=ORANGE, lw=0.6)
                    w.line(x - 0.12, 6.48, x + 0.12, 6.72, color=ORANGE, lw=0.4)
                    w.line(x - 0.12, 6.72, x + 0.12, 6.48, color=ORANGE, lw=0.4)
            w.line(1.6, 6.3, 33.6, 6.3, color=ORANGE, lw=0.4, dash=[2, 1.5])
            for (x, y) in ((16.2, 9.0), (16.2, 11.6)):
                w.rect(x - 0.18, y - 0.18, x + 0.18, y + 0.18, fill=(0.85, 1.0, 0.85), stroke=GREEN, lw=0.6)
            for x0 in SOUTH:
                r = south_unit_rooms(x0)
                for room in ("bedroom", "living", "bath", "hall"):
                    cx, cy = centroid(r[room])
                    w.circle(cx, cy + 0.6, r_world=0.15, stroke=ORANGE, lw=0.6)
                    w.line(cx - 0.1, cy + 0.5, cx + 0.1, cy + 0.7, color=ORANGE, lw=0.4)
                    w.line(cx - 0.1, cy + 0.7, cx + 0.1, cy + 0.5, color=ORANGE, lw=0.4)
                w.circle(x0 + 3.62, 5.0, r_world=0.07, fill=ORANGE, stroke=None)
                w.text(x0 + 3.62, 4.7, "Ł", 4.5, align="center", rgb=ORANGE)
            title = "Instalacja oświetleniowa i oświetlenie awaryjne"
        else:
            for x0 in SOUTH:
                r = south_unit_rooms(x0)
                yt = 5.7 - STR / 2
                for x in (x0 + 5.6, x0 + 6.4, x0 + 7.4, x0 + 8.2):
                    w.arc(x, yt - 0.66, 0.12, 180, 360, color=ORANGE, lw=0.6)
                    w.line(x, yt - 0.78, x, yt - 0.92, color=ORANGE, lw=0.5)
                for (x, y) in ((x0 + 1.2, 0.8), (x0 + 3.0, 2.2), (x0 + 6.2, 0.8), (x0 + 8.4, 2.0)):
                    w.arc(x, y, 0.12, 0, 180, color=ORANGE, lw=0.6)
                bl = EXT if x0 == 0 else x0 + STR / 2
                w.arc(bl + 1.6, 3.9, 0.12, 0, 180, color=(0.7, 0.1, 0.5), lw=0.6)
                w.text(bl + 1.6, 4.1, "IP44", 4.2, align="center", rgb=(0.7, 0.1, 0.5))
            w.line(8.4, 6.95, 33.0, 6.95, color=ORANGE, lw=1.0)
            w.text(20.0, 7.05, "WLZ do tablic mieszkaniowych TM — YDY 5×10 mm²", 5.2, align="left", rgb=ORANGE)
            w.line(1.0, 6.2, 35.0, 6.2, color=ORANGE, lw=1.2, dash=[4, 2])
            w.text(3.0, 5.95, "koryto kablowe 200×60", 5.0, align="left", rgb=ORANGE)
            title = "Instalacja gniazd wtykowych i zasilanie tablic"
        page.text(40, 175, title, 7.5, bold=True)
        legend = [("thin", ORANGE, "Oprawy / gniazda instalacji elektrycznej"),
                  ("thin", GREEN, "AW — oprawa oświetlenia awaryjnego / ewakuacyjnego"),
                  ("dash", ORANGE, "Trasy kablowe")]
        yy = 175
        for kind, color, label in legend:
            yy -= 12
            legend_item(page, 40, yy, kind, color, label)
        end_content(page)
        title_block(page, info)
        pages.append(page)
        transforms.append((*PLAN_ORIGIN, w.k))
    return pages, transforms


SITE_K = 1000 / 500 * MM
SITE_ORIGIN = (60.0, 255.0)
SITE_A = (24.0, 50.0)   # building A origin in site coordinates


def site_polygons():
    ax, ay = SITE_A
    return {
        "plot": [(0, 0), (150, 0), (150, 90), (0, 86)],
        "building_A": rect_pts(ax, ay, ax + BX, ay + BY),
        "building_B": rect_pts(84, 50, 120, 62.6),
        "building_C": rect_pts(84, 10, 120, 22.6),
        "garage": rect_pts(ax + GARAGE_X[0], ay + GARAGE_Y[0], ax + GARAGE_X[1], ay + GARAGE_Y[1]),
        "ramp": rect_pts(ax + GARAGE_X[1], ay - 9.6, ax + GARAGE_X[1] + 12.0, ay - 3.6),
        "ramp_zone": rect_pts(64.0, 37.0, 80.0, 48.5),
        "playground": rect_pts(24, 10, 46, 24),
    }


def sheet_site(info):
    page = Page(*A3_LANDSCAPE)
    w = W(page, 500, *SITE_ORIGIN)
    begin_content(page)
    pol = site_polygons()
    w.rect(-12, -14, 162, -2, fill=(0.82, 0.82, 0.84), stroke=None)
    w.line(-12, -8, 162, -8, color=(1, 1, 1), lw=1.0, dash=[8, 6])
    w.text(30, -10.5, "ul. Słonecznikowa (nazwa fikcyjna)", 7, bold=True, align="center")
    w.poly(pol["plot"], fill=(0.97, 0.99, 0.96), stroke=RED, lw=1.0)
    w.text(4, 80, "granica działki nr 123/4 (dane fikcyjne)", 6, align="left", rgb=RED)
    for x0, y0, x1, y1 in ((2, 2, 22, 30), (124, 30, 148, 86), (2, 66, 80, 84), (48, 8, 80, 30)):
        w.rect(x0, y0, x1, y1, fill=LIGHT_GREEN, stroke=None)
    w.p.dash([5, 3])
    w.poly(pol["garage"], fill=None, stroke=(0.4, 0.4, 0.45), lw=0.6)
    w.p.dash()
    w.text(SITE_A[0] + 18, SITE_A[1] - 14.5, "obrys garażu podziemnego (poziom -1)", 6, align="center",
           rgb=(0.35, 0.35, 0.4))
    road = [(60, 0), (72, 0), (72, 34), (130, 34), (130, 44), (84, 44), (84, 46.4), (78, 46.4), (78, 40.4),
            (72, 40.4), (72, 44), (60, 44)]
    w.poly(road, fill=(0.78, 0.78, 0.8), stroke=(0.45, 0.45, 0.5), lw=0.5)
    w.poly(pol["ramp"], fill=(0.68, 0.68, 0.72), stroke=BLACK, lw=0.6)
    w.text(72.0, 47.4, "zjazd do garażu", 6, align="center")
    for i in range(10):
        x0 = 86 + i * 2.5
        w.rect(x0, 34.2, x0 + 2.5, 39.0, stroke=(1, 1, 1), lw=0.6)
    w.text(98.5, 32.8, "10 miejsc postojowych dla gości", 6, align="center")
    for name, poly, label in (("A", pol["building_A"], "BUDYNEK A"), ("B", pol["building_B"], "BUDYNEK B")):
        w.poly(poly, fill=(0.35, 0.35, 0.4), stroke=BLACK, lw=0.8)
        cx, cy = centroid(poly)
        w.text(cx, cy + 0.6, label, 9, bold=True, align="center", rgb=(1, 1, 1))
        w.text(cx, cy - 2.6, "4 kondygnacje, 30 lokali", 6, align="center", rgb=(1, 1, 1))
    w.p.dash([6, 3])
    w.poly(pol["building_C"], fill=None, stroke=(0.4, 0.4, 0.45), lw=0.8)
    w.p.dash()
    w.text(102, 16, "Budynek C — Etap II (poza zakresem)", 7, align="center", rgb=(0.4, 0.4, 0.45))
    w.poly(pol["playground"], fill=(1.0, 0.93, 0.75), stroke=ORANGE, lw=0.6)
    w.text(35, 17, "Plac zabaw", 7, bold=True, align="center", rgb=(0.6, 0.35, 0.0))
    for x, y in ((6, 10), (6, 20), (14, 26), (128, 40), (136, 52), (144, 64), (136, 76), (10, 72), (20, 78),
                 (32, 74), (46, 78), (60, 72), (54, 14), (64, 22), (76, 12), (128, 70), (144, 34)):
        w.circle(x, y, r_world=2.0, fill=(0.75, 0.88, 0.7), stroke=GREEN, lw=0.5)
        w.circle(x, y, r_pt=0.8, fill=GREEN, stroke=None)
    w.rect(132, 4, 138, 8, fill=(0.9, 0.9, 0.9), stroke=BLACK, lw=0.5)
    w.text(135, 9, "wiata śmietnikowa", 5.5, align="center")
    w.line(2, 47, SITE_A[0], 53.0, color=BLUE, lw=0.8, dash=[5, 2])
    w.text(3, 48.2, "przyłącze wod.-kan.", 5.5, align="left", rgb=BLUE)
    w.poly([(0, 70), (150, 70), (150, 76), (0, 76)], fill=None, stroke=(0.55, 0.55, 0.6), lw=0.4)
    w.text(100, 72.5, "droga pożarowa — szer. 4,0 m", 6, align="center", rgb=(0.4, 0.4, 0.45))
    north_arrow(page, 1080, 760, size=22)
    scale_bar(w, 100, 80, 40, 10, "skala 1:500")
    notes_block(page, 40, 175, "Bilans terenu (wartości fikcyjne)", [
        "Powierzchnia działki: 13 320 m²; zabudowa: 1 361 m² (10,2%); biologicznie czynna: 4 890 m² (36,7%).",
        "Miejsca postojowe: 40 w garażu podziemnym + 10 naziemnych dla gości.",
        "Rzędne terenu wg mapy do celów projektowych (dane fikcyjne).",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*SITE_ORIGIN, w.k)]


# ------------------------------------------------------------------------------------
# Project B — office floor (Modernizacja Biurowca — Centrum, 3. piętro)
# ------------------------------------------------------------------------------------

OX, OY = 30.0, 16.8
OFFICE_ORIGIN = (115.0, 280.0)
OFFICE_AX_X = [("1", 0.0), ("2", 6.0), ("3", 12.0), ("4", 18.0), ("5", 24.0), ("6", 30.0)]
OFFICE_AX_Y = [("A", 0.0), ("B", 5.4), ("C", 11.4), ("D", 16.8)]


def office_polygons():
    return {
        "floor": rect_pts(0, 0, OX, OY),
        "open_west": rect_pts(0.3, 0.3, 11.9, 16.5),
        "open_east": rect_pts(18.1, 0.3, 29.7, 5.3),
        "core": rect_pts(12.0, 5.4, 18.0, 11.4),
        "conference": rect_pts(18.1, 11.5, 23.9, 16.5),
        "meeting": rect_pts(24.1, 11.5, 26.9, 16.5),
        "manager": rect_pts(27.1, 11.5, 29.7, 16.5),
        "kitchen": rect_pts(18.1, 5.5, 22.9, 11.3),
        "server": rect_pts(23.1, 5.5, 26.4, 11.3),
        "storage": rect_pts(26.6, 5.5, 29.7, 11.3),
        "corridor_n": rect_pts(12.0, 11.5, 18.0, 16.5),
        "corridor_s": rect_pts(12.0, 0.3, 18.0, 5.3),
    }


def office_plan(w: W, faint=False):
    ink = INK_FAINT if faint else BLACK
    wall = WALL_FAINT if faint else WALL
    pol = office_polygons()
    w.rect(0, 0, OX, OY, fill=None, stroke=ink, lw=0.9)
    w.rect(0.1, 0.1, OX - 0.1, OY - 0.1, fill=None, stroke=ink, lw=0.3)
    for i in range(1, 25):
        x = i * 1.25
        for y in (0.0, OY - 0.1):
            w.line(x, y, x, y + 0.1, color=ink, lw=0.3)
    for x in (0.0, 6.0, 12.0, 18.0, 24.0, 30.0):
        for y in (0.0, 5.4, 11.4, 16.8):
            xc = min(max(x, 0.25), OX - 0.25)
            yc = min(max(y, 0.25), OY - 0.25)
            w.rect(xc - 0.25, yc - 0.25, xc + 0.25, yc + 0.25, fill=wall, stroke=ink, lw=0.3)
    w.rect(12.0, 5.4, 18.0, 11.4, fill=(0.88, 0.88, 0.9) if not faint else (0.95, 0.95, 0.96), stroke=ink, lw=0.6)
    for x0, y0, x1, y1 in ((12.0, 5.4, 18.0, 5.6), (12.0, 11.2, 18.0, 11.4), (12.0, 5.4, 12.2, 11.4),
                           (17.8, 5.4, 18.0, 11.4)):
        w.rect(x0, y0, x1, y1, fill=wall, stroke=ink, lw=0.4)
    w.text(15.0, 9.8, "Trzon: klatka, 2 windy, WC", 6, align="center", rgb=ink)
    w.text(15.0, 9.1, "(bez zmian)", 5.5, align="center", rgb=ink)
    for name in ("conference", "meeting", "manager", "kitchen", "server", "storage"):
        w.poly(pol[name], fill=None, stroke=ink, lw=0.6)
    door_h(w, 19.0, 19.9, 11.4, 0.2, swing_up=True, hinge_left=True, ink=ink)
    door_h(w, 24.6, 25.5, 11.4, 0.2, swing_up=True, hinge_left=True, ink=ink)
    door_h(w, 27.6, 28.5, 11.4, 0.2, swing_up=True, hinge_left=True, ink=ink)
    door_h(w, 24.0, 24.9, 5.4, 0.2, swing_up=True, hinge_left=False, ink=ink)
    door_h(w, 27.0, 27.9, 5.4, 0.2, swing_up=True, hinge_left=True, ink=ink)
    labels = [("open_west", "3.01", "Open space — strefa zachodnia"), ("open_east", "3.02", "Open space — strefa wschodnia"),
              ("conference", "3.05", "Sala konferencyjna"), ("meeting", "3.06", "Sala spotkań"),
              ("manager", "3.07", "Pokój kierownika"), ("kitchen", "3.08", "Aneks socjalny"),
              ("server", "3.12", "Serwerownia"), ("storage", "3.11", "Magazyn")]
    for key, num, name in labels:
        room_label(w, pol[key], num, name, size=6.2, ink=ink, dy=-0.9 if key == "open_west" else 0.0)
    if not faint:
        for row in range(4):
            for col in range(2):
                x = 1.6 + col * 5.0
                y = 1.8 + row * 3.6
                w.rect(x, y, x + 3.2, y + 1.6, stroke=ink, lw=0.3)
                w.line(x + 1.6, y, x + 1.6, y + 1.6, color=ink, lw=0.2)
        for i in range(3):
            x = 19.0 + i * 3.6
            w.rect(x, 1.4, x + 3.2, 3.0, stroke=ink, lw=0.3)
        w.rect(19.2, 13.0, 22.8, 15.0, stroke=ink, lw=0.3)
        w.rect(18.3, 5.7, 22.7, 6.3, stroke=ink, lw=0.3)
        for i in range(3):
            w.rect(23.4 + i * 0.95, 9.9, 24.2 + i * 0.95, 11.0, fill=(0.3, 0.3, 0.33), stroke=ink, lw=0.2)


def _office_page(faint):
    page = Page(*A3_LANDSCAPE)
    w = W(page, 100, *OFFICE_ORIGIN)
    begin_content(page)
    axis_grid(w, OFFICE_AX_X, OFFICE_AX_Y, (-1.4, OX + 1.4), (-2.2, OY + 1.4), faint=faint)
    if not faint:
        dim_h(w, [x for _, x in OFFICE_AX_X], -1.6, y_from=-1.2)
        dim_v(w, [y for _, y in OFFICE_AX_Y], -0.9)
    office_plan(w, faint=faint)
    north_arrow(page, 1080, 760)
    return page, w


def sheet_office_arch(info):
    page, w = _office_page(False)
    notes_block(page, 40, 175, "Zakres modernizacji 3. piętra", [
        "1. Demontaż ścianek działowych i sufitu podwieszanego w strefie A i B.",
        "2. Nowe ścianki szkło/GK w salach 3.05–3.07; serwerownia 3.12 z drzwiami EI30.",
        "3. Podłoga podniesiona h = 15 cm w open space; wykładzina modułowa.",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*OFFICE_ORIGIN, w.k)]


def sheet_office_electrical(info):
    page, w = _office_page(True)
    for row in range(5):
        for col in range(4):
            x = 1.4 + col * 2.8
            y = 1.4 + row * 3.0
            w.rect(x, y, x + 0.6, y + 0.6, stroke=ORANGE, lw=0.5)
    for x, y in ((3.2, 2.6), (8.2, 2.6), (3.2, 6.2), (8.2, 6.2), (3.2, 9.8), (8.2, 9.8), (3.2, 13.4), (8.2, 13.4),
                 (20.6, 2.2), (24.2, 2.2), (27.8, 2.2)):
        w.rect(x - 0.15, y - 0.15, x + 0.15, y + 0.15, fill=(1.0, 0.9, 0.7), stroke=ORANGE, lw=0.5)
    w.line(0.8, 11.0, 29.2, 11.0, color=ORANGE, lw=1.2, dash=[4, 2])
    w.text(5.0, 11.25, "koryto kablowe 300×60 nad sufitem", 5.2, align="left", rgb=ORANGE)
    w.rect(23.3, 8.0, 24.1, 9.6, fill=(1.0, 0.9, 0.7), stroke=ORANGE, lw=0.8)
    w.text(23.7, 8.65, "RPS", 5.5, bold=True, align="center", rgb=ORANGE)
    w.rect(24.4, 8.0, 25.4, 9.0, fill=(0.9, 0.9, 1.0), stroke=BLUE, lw=0.6)
    w.text(24.9, 8.4, "UPS", 5.0, bold=True, align="center", rgb=BLUE)
    w.text(15.0, 4.0, "RG-3 w szachcie trzonu", 5.5, align="center", rgb=ORANGE)
    notes_block(page, 40, 175, "Instalacje elektryczne i teletechniczne", [
        "Puszki podłogowe 3×230 V + 2×RJ45 przy każdym stanowisku; oprawy LED 60×60 z DALI.",
        "Serwerownia: rozdzielnica RPS, UPS 10 kVA, przejścia kablowe uszczelnione EI60.",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*OFFICE_ORIGIN, w.k)]


def sheet_office_hvac(info):
    page, w = _office_page(True)
    w.rect(12.6, 11.9, 29.0, 12.4, fill=(0.85, 0.93, 0.95), stroke=DUCT, lw=0.8)
    w.text(20.0, 12.55, "kanał świeżego powietrza 500×250", 5.2, align="center", rgb=DUCT)
    w.rect(0.8, 11.9, 11.6, 12.4, fill=(0.85, 0.93, 0.95), stroke=DUCT, lw=0.8)
    for x in (2.0, 5.0, 8.0, 11.0):
        for y in (0.6, 15.8):
            w.rect(x - 0.6, y - 0.2, x + 0.6, y + 0.2, fill=(0.9, 0.97, 0.9), stroke=GREEN, lw=0.5)
            w.text(x, y + 0.3 if y < 1 else y - 0.55, "FCU", 4.5, align="center", rgb=GREEN)
    for x, y in ((21.0, 14.0), (25.5, 14.0), (28.4, 14.0), (20.5, 8.5)):
        w.rect(x - 0.4, y - 0.4, x + 0.4, y + 0.4, stroke=DUCT, lw=0.6)
        w.line(x - 0.4, y - 0.4, x + 0.4, y + 0.4, color=DUCT, lw=0.4)
        w.line(x - 0.4, y + 0.4, x + 0.4, y - 0.4, color=DUCT, lw=0.4)
    w.rect(23.4, 6.0, 25.9, 6.5, fill=(0.85, 0.93, 1.0), stroke=BLUE, lw=0.7)
    w.text(24.65, 6.65, "klimatyzacja precyzyjna 2×7 kW", 5.0, align="center", rgb=BLUE)
    w.line(25.9, 6.25, 29.6, 6.25, color=BLUE, lw=0.6, dash=[2, 1.5])
    w.text(27.8, 5.95, "odpływ skroplin", 4.8, align="center", rgb=BLUE)
    w.line(22.0, 10.5, 22.0, 13.0, color=ORANGE, lw=1.2, dash=[4, 2])
    notes_block(page, 40, 175, "Instalacje HVAC", [
        "Klimakonwektory FCU 4-rurowe w strefach open space; kasetony VRF w salach 3.05–3.07.",
        "Nawiew świeżego powietrza z centrali na dachu, rekuperacja 78% (wartość fikcyjna).",
    ])
    end_content(page)
    title_block(page, info)
    return [page], [(*OFFICE_ORIGIN, w.k)]
