"""Procedural, synthetic construction-site "photos" for the B Technica demo (PNG).

Every image is drawn from geometric primitives with a fixed seed: no photographs, no
people, no real places. Each carries a "B TECHNICA DEMO — ZDJĘCIE SYNTETYCZNE" footer.
The app converts them to JPEG + thumbnail at seed time with PhotoImageProcessing.
"""
from __future__ import annotations

import math
import random
import struct
import zlib

W, H = 800, 600

_FONT = {
    "A": "01110,10001,10001,11111,10001,10001,10001", "B": "11110,10001,10001,11110,10001,10001,11110",
    "C": "01110,10001,10000,10000,10000,10001,01110", "D": "11100,10010,10001,10001,10001,10010,11100",
    "E": "11111,10000,10000,11110,10000,10000,11111", "F": "11111,10000,10000,11110,10000,10000,10000",
    "G": "01110,10001,10000,10111,10001,10001,01111", "H": "10001,10001,10001,11111,10001,10001,10001",
    "I": "01110,00100,00100,00100,00100,00100,01110", "J": "00111,00010,00010,00010,00010,10010,01100",
    "K": "10001,10010,10100,11000,10100,10010,10001", "L": "10000,10000,10000,10000,10000,10000,11111",
    "M": "10001,11011,10101,10101,10001,10001,10001", "N": "10001,10001,11001,10101,10011,10001,10001",
    "O": "01110,10001,10001,10001,10001,10001,01110", "P": "11110,10001,10001,11110,10000,10000,10000",
    "Q": "01110,10001,10001,10001,10101,10010,01101", "R": "11110,10001,10001,11110,10100,10010,10001",
    "S": "01111,10000,10000,01110,00001,00001,11110", "T": "11111,00100,00100,00100,00100,00100,00100",
    "U": "10001,10001,10001,10001,10001,10001,01110", "V": "10001,10001,10001,10001,10001,01010,00100",
    "W": "10001,10001,10001,10101,10101,10101,01010", "X": "10001,10001,01010,00100,01010,10001,10001",
    "Y": "10001,10001,01010,00100,00100,00100,00100", "Z": "11111,00001,00010,00100,01000,10000,11111",
    "0": "01110,10001,10011,10101,11001,10001,01110", "1": "00100,01100,00100,00100,00100,00100,01110",
    "2": "01110,10001,00001,00010,00100,01000,11111", "3": "11111,00010,00100,00010,00001,10001,01110",
    "4": "00010,00110,01010,10010,11111,00010,00010", "5": "11111,10000,11110,00001,00001,10001,01110",
    "6": "00110,01000,10000,11110,10001,10001,01110", "7": "11111,00001,00010,00100,01000,01000,01000",
    "8": "01110,10001,10001,01110,10001,10001,01110", "9": "01110,10001,10001,01111,00001,00010,01100",
    "-": "00000,00000,00000,11111,00000,00000,00000", "/": "00001,00010,00010,00100,01000,01000,10000",
    ".": "00000,00000,00000,00000,00000,01100,01100", ":": "00000,01100,01100,00000,01100,01100,00000",
    "|": "00100,00100,00100,00100,00100,00100,00100", "(": "00010,00100,01000,01000,01000,00100,00010",
    ")": "01000,00100,00010,00010,00010,00100,01000", "+": "00000,00100,00100,11111,00100,00100,00000",
    "#": "01010,01010,11111,01010,11111,01010,01010", ",": "00000,00000,00000,00000,01100,00100,01000",
    "%": "11000,11001,00010,00100,01000,10011,00011", " ": "00000,00000,00000,00000,00000,00000,00000",
}
_FOLD = str.maketrans("ĄĆĘŁŃÓŚŹŻąćęłńóśźż", "ACELNOSZZACELNOSZZ")


def clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def mix(c0, c1, t):
    return tuple(clamp(a + (b - a) * t) for a, b in zip(c0, c1))


def shade(c, d):
    return tuple(clamp(v + d) for v in c)


class Raster:
    def __init__(self, w=W, h=H, bg=(255, 255, 255)):
        self.w, self.h = w, h
        self.px = bytearray(bytes(bg) * (w * h))

    def span(self, y, xa, xb, c):
        if y < 0 or y >= self.h:
            return
        xa = max(0, xa)
        xb = min(self.w, xb)
        if xb <= xa:
            return
        i = (y * self.w + xa) * 3
        self.px[i:i + (xb - xa) * 3] = bytes(c) * (xb - xa)

    def rect(self, x0, y0, x1, y1, c):
        x0, x1 = int(round(min(x0, x1))), int(round(max(x0, x1)))
        y0, y1 = int(round(min(y0, y1))), int(round(max(y0, y1)))
        for y in range(max(0, y0), min(self.h, y1)):
            self.span(y, x0, x1, c)

    def poly(self, pts, c):
        ys = [p[1] for p in pts]
        y0 = max(0, int(math.floor(min(ys))))
        y1 = min(self.h - 1, int(math.ceil(max(ys))))
        n = len(pts)
        for y in range(y0, y1 + 1):
            yc = y + 0.5
            xs = []
            for i in range(n):
                (xa, ya), (xb, yb) = pts[i], pts[(i + 1) % n]
                if (ya <= yc < yb) or (yb <= yc < ya):
                    xs.append(xa + (yc - ya) * (xb - xa) / (yb - ya))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                self.span(y, int(math.ceil(xs[k] - 0.5)), int(math.floor(xs[k + 1] - 0.5)) + 1, c)

    def line(self, x0, y0, x1, y1, width, c):
        dx, dy = x1 - x0, y1 - y0
        d = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / d * width / 2, dx / d * width / 2
        self.poly([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], c)

    def polyline(self, pts, width, c):
        for a, b in zip(pts, pts[1:]):
            self.line(a[0], a[1], b[0], b[1], width, c)

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(max(0, int(cy - ry)), min(self.h, int(cy + ry) + 1)):
            t = (y + 0.5 - cy) / ry
            if abs(t) >= 1:
                continue
            dx = rx * math.sqrt(1 - t * t)
            self.span(y, int(round(cx - dx)), int(round(cx + dx)), c)

    def vgrad(self, y0, y1, c0, c1, x0=0, x1=None):
        x1 = self.w if x1 is None else x1
        for y in range(max(0, int(y0)), min(self.h, int(y1))):
            t = (y - y0) / max(1.0, (y1 - y0))
            self.span(y, int(x0), int(x1), mix(c0, c1, t))

    def blocks(self, x0, y0, x1, y1, base, amp, seed, size=8):
        rnd = random.Random(seed)
        y = int(y0)
        while y < y1:
            x = int(x0)
            while x < x1:
                d = rnd.randint(-amp, amp)
                self.rect(x, y, min(x + size, x1), min(y + size, y1), shade(base, d))
                x += size
            y += size

    def blend_rect(self, x0, y0, x1, y1, c, alpha):
        for y in range(max(0, int(y0)), min(self.h, int(y1))):
            for x in range(max(0, int(x0)), min(self.w, int(x1))):
                i = (y * self.w + x) * 3
                for k in range(3):
                    self.px[i + k] = clamp(self.px[i + k] * (1 - alpha) + c[k] * alpha)

    def text(self, x, y, s, scale, c):
        cx = x
        for ch in s.upper().translate(_FOLD):
            glyph = _FONT.get(ch, _FONT[" "]).split(",")
            for row, bits in enumerate(glyph):
                for col, bit in enumerate(bits):
                    if bit == "1":
                        self.rect(cx + col * scale, y + row * scale, cx + (col + 1) * scale, y + (row + 1) * scale, c)
            cx += 6 * scale
        return cx

    def png(self) -> bytes:
        raw = bytearray()
        stride = self.w * 3
        prev = bytes(stride)
        for y in range(self.h):
            row = bytes(self.px[y * stride:(y + 1) * stride])
            raw.append(2)  # filter: Up
            raw += bytes((a - b) & 0xFF for a, b in zip(row, prev))
            prev = row

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        ihdr = struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                + chunk(b"IEND", b""))


# ------------------------------------------------------------------------------------
# Scenes
# ------------------------------------------------------------------------------------

SKY = ((150, 190, 225), (215, 228, 238))
CONCRETE = (168, 168, 164)
STEEL = (120, 124, 130)
YELLOW = (238, 190, 40)
RUST = (130, 70, 40)


def footer(r: Raster, number: int, caption: str):
    r.blend_rect(0, H - 34, W, H, (20, 24, 30), 0.78)
    r.text(12, H - 25, f"B TECHNICA DEMO  FOTO {number:02d}", 2, (255, 255, 255))
    r.text(12, H - 11, caption[:60], 1, (210, 220, 230))
    r.text(W - 6 * 2 * 20 - 10, H - 25, "ZDJECIE SYNTETYCZNE", 2, (250, 205, 60))


def scene_site(r: Raster, v: int):
    rnd = random.Random(100 + v)
    r.vgrad(0, 330, *SKY)
    for i in range(14):
        cx = rnd.randint(0, W)
        r.ellipse(cx, 330, rnd.randint(30, 70), rnd.randint(20, 45), (70, 110, 70))
    r.vgrad(330, H, (150, 135, 110), (120, 108, 90))
    floors = 2 + v % 3
    left, right, base = 150, 640, 470
    for f in range(floors + 1):
        y = base - f * 70
        r.rect(left - 10, y - 12, right + 10, y, CONCRETE)
        r.rect(left - 10, y - 12, right + 10, y - 9, shade(CONCRETE, 25))
    for f in range(floors):
        y0 = base - (f + 1) * 70
        for x in range(left, right + 1, 70):
            r.rect(x - 6, y0, x + 6, y0 + 58, shade(CONCRETE, -12))
        if f < floors - 1:
            for x in range(left + 10, right - 30, 35):
                r.rect(x, y0 + 4, x + 22, y0 + 56, (225, 225, 220) if (x // 35 + f) % 3 else (90, 95, 105))
    for x in range(left - 40, left + 160, 32):
        r.line(x, base + 8, x, base - floors * 70 - 30, 3, STEEL)
    for y in range(base - floors * 70 - 20, base + 8, 35):
        r.line(left - 40, y, left + 160, y, 3, STEEL)
        r.rect(left - 40, y - 3, left + 160, y + 1, (190, 150, 70))
    mx = 700 - v * 25
    r.rect(mx - 9, 60, mx + 9, base, YELLOW)
    for y in range(70, base, 28):
        r.line(mx - 9, y, mx + 9, y + 28, 2, (180, 140, 20))
    r.rect(mx - 280, 52, mx + 70, 64, YELLOW)
    for x in range(mx - 280, mx + 70, 24):
        r.line(x, 64, x + 12, 52, 2, (180, 140, 20))
    r.rect(mx + 30, 64, mx + 68, 92, (90, 95, 105))
    r.rect(mx - 20, 64, mx + 2, 84, (60, 90, 140))
    hook_x = mx - 160 + v * 20
    r.line(hook_x, 64, hook_x, 210 + v * 15, 1.5, (40, 40, 40))
    r.rect(hook_x - 25, 210 + v * 15, hook_x + 25, 222 + v * 15, (160, 120, 60))
    r.rect(40, 440, 128, 500, (50, 90, 160))
    r.rect(40, 440, 128, 446, (35, 70, 130))
    for x in range(0, W, 46):
        r.rect(x, 505, x + 44, 565, (175, 178, 180))
        for xx in range(x + 4, x + 44, 6):
            r.line(xx, 507, xx, 563, 1, (150, 152, 155))


def scene_formwork(r: Raster, v: int):
    rnd = random.Random(200 + v)
    r.rect(0, 0, W, H, (175, 120, 70))
    for y in range(0, H, 120):
        for x in range(-(y // 120 % 2) * 100, W, 200):
            r.rect(x, y, x + 198, y + 118, shade((182, 128, 76), rnd.randint(-10, 10)))
    step = 26 if v % 2 == 0 else 32
    for x in range(10, W, step):
        r.line(x, 0, x + 12, H, 3, RUST)
    for y in range(8, H, step):
        r.line(0, y, W, y + 6, 3, shade(RUST, -15))
    for _ in range(18):
        x, y = rnd.randint(30, W - 30), rnd.randint(30, H - 80)
        r.ellipse(x, y, 7, 7, (90, 90, 95))
    r.rect(0, H - 120, W, H - 100, (120, 85, 50))
    for x in range(40, W, 90):
        r.rect(x, H - 160, x + 30, H - 120, (150, 150, 150))
        for k in range(4):
            r.line(x + 4 + k * 7, H - 200, x + 4 + k * 7, H - 120, 2, RUST)


def scene_masonry(r: Raster, v: int):
    r.rect(0, 0, W, H, (210, 205, 195))
    r.rect(0, 0, W, 70, (150, 150, 148))
    r.rect(0, H - 110, W, H, (140, 138, 132))
    top_rows = 9 - v % 3
    bh, bw = 48, 100
    for row in range(12):
        y = H - 110 - (row + 1) * bh
        if row >= top_rows:
            break
        offset = (row % 2) * bw // 2
        for x in range(-offset, W, bw):
            if row == top_rows - 1 and x > 420:
                break
            r.rect(x + 2, y + 2, x + bw - 2, y + bh - 2, (232, 230, 222))
    r.rect(330, 160, 560, 380, (60, 65, 75))
    r.rect(310, 140, 580, 162, (150, 150, 145))


def scene_balcony_threshold(r: Raster, v: int):
    r.vgrad(0, 260, (200, 205, 210), (170, 175, 180))
    frame_x = 160 if v == 0 else 90
    r.rect(frame_x, 0, frame_x + 60, 360, (240, 240, 238))
    r.rect(frame_x + 60, 0, W, 300, (110, 130, 150))
    r.rect(frame_x + 60, 0, W, 20, (240, 240, 238))
    r.rect(frame_x - 20, 300, W, 330, (235, 235, 233))
    r.poly([(0, 360), (W, 330), (W, H), (0, H)], (150, 150, 148))
    r.blocks(0, 400, W, H - 34, (150, 150, 148), 6, 300 + v, size=10)
    r.poly([(0, 342), (W, 312), (W, 330), (0, 360)], (95, 95, 100))
    r.rect(frame_x - 20, 330, 470, 352, (60, 110, 180))
    r.poly([(470, 330), (520, 336), (500, 352), (470, 352)], (60, 110, 180))
    r.ellipse(600, 470 if v == 0 else 430, 150, 40, (110, 115, 120))
    r.ellipse(600, 470 if v == 0 else 430, 130, 30, (125, 135, 145))
    for x in range(520, 760, 18):
        r.line(x, 330, x + 4, 360, 2, (70, 70, 72))
    if v == 1:
        r.rect(520, 330, 532, 450, (240, 200, 40))
        for k in range(10):
            r.rect(520, 330 + k * 12, 528, 331 + k * 12, (40, 40, 40))


def scene_lintel_crack(r: Raster, v: int):
    r.rect(0, 0, W, H, (226, 222, 214))
    r.blocks(0, 0, W, H - 34, (226, 222, 214), 3, 400 + v, size=16)
    r.rect(250, 210, 560, 520, (55, 65, 80))
    r.rect(240, 200, 570, 212, (245, 245, 245))
    r.rect(250, 210, 262, 520, (245, 245, 245))
    r.rect(548, 210, 560, 520, (245, 245, 245))
    r.rect(220, 150, 600, 200, (196, 192, 186))
    crack = [(300, 150), (318, 165), (309, 176), (330, 188), (322, 200)]
    r.polyline(crack, 3, (60, 55, 50))
    r.poly([(520, 200), (600, 200), (600, 168), (560, 160), (540, 182)], (150, 145, 138))
    r.line(528, 192, 596, 186, 4, RUST)
    r.polyline([(600, 160), (640, 120), (655, 92), (690, 70)], 2, (90, 85, 80))


def scene_floor_drain(r: Raster, v: int):
    r.rect(0, 0, W, H, (205, 200, 190))
    t = 100
    for y in range(0, H, t):
        for x in range(0, W, t):
            r.rect(x + 2, y + 2, x + t - 2, y + t - 2, (218, 214, 205) if (x // t + y // t) % 2 else (212, 208, 198))
    cx, cy, s = 430, 300, 70
    ang = math.radians(9 + v * 3)
    pts = [(cx + s * math.cos(ang + k * math.pi / 2), cy + s * math.sin(ang + k * math.pi / 2)) for k in range(4)]
    r.poly([(x + (x - cx) * 0.18, y + (y - cy) * 0.18) for x, y in pts], (60, 60, 62))
    r.poly(pts, (170, 172, 176))
    for k in range(-3, 4):
        a = (cx + k * 15 * math.cos(ang) - 45 * math.sin(ang), cy + k * 15 * math.sin(ang) + 45 * math.cos(ang))
        b = (cx + k * 15 * math.cos(ang) + 45 * math.sin(ang), cy + k * 15 * math.sin(ang) - 45 * math.cos(ang))
        r.line(a[0], a[1], b[0], b[1], 5, (95, 97, 100))
    r.rect(80, 470, 420, 492, (240, 200, 40))
    r.rect(230, 472, 270, 490, (120, 200, 120))


def scene_duct_collision(r: Raster, v: int):
    r.rect(0, 0, W, H, (150, 150, 148))
    r.blocks(0, 0, W, H - 34, (150, 150, 148), 5, 500 + v, size=20)
    r.rect(0, 210, W, 330, (200, 205, 210))
    r.rect(0, 210, W, 222, (225, 228, 232))
    r.rect(0, 318, W, 330, (165, 170, 176))
    for x in range(0, W, 120):
        r.rect(x, 210, x + 6, 330, (175, 180, 186))
    r.rect(380, 0, 470, H, (205, 165, 40))
    for x in (380, 462):
        r.rect(x, 0, x + 8, H, (175, 135, 20))
    for k, c in enumerate([(30, 30, 30), (80, 80, 80), (40, 90, 150), (30, 30, 30), (200, 180, 40)]):
        r.line(395 + k * 13, 0, 395 + k * 13, 205, 7, c)
        r.line(395 + k * 13, 335, 395 + k * 13, H, 7, c)
    r.polyline([(372, 200), (478, 340)], 6, (220, 40, 40))
    r.polyline([(478, 200), (372, 340)], 6, (220, 40, 40))


def scene_pipe_penetration(r: Raster, v: int):
    r.rect(0, 0, W, H, (190, 188, 182))
    r.blocks(0, 0, W, H - 34, (190, 188, 182), 4, 600 + v, size=14)
    pipes = [(200, 300, 55, (160, 165, 170), False), (420, 300, 40, (190, 120, 70), True),
             (610, 300, 62, (35, 35, 38), False)]
    for cx, cy, rr, col, sealed in pipes:
        r.ellipse(cx, cy, rr + 22, rr + 22, (200, 40, 40) if sealed else (40, 38, 36))
        r.ellipse(cx, cy, rr, rr, col)
        r.ellipse(cx - rr * 0.3, cy - rr * 0.3, rr * 0.35, rr * 0.35, shade(col, 35))
    r.rect(560, 120, 700, 150, (250, 250, 250))
    r.text(570, 128, "EI 60 ?", 2, (200, 30, 30))


def scene_switchboard(r: Raster, v: int):
    r.rect(0, 0, W, H, (205, 205, 200))
    r.rect(120, 30, 680, 560, (190, 192, 196))
    r.rect(140, 50, 660, 540, (230, 232, 235))
    colors = [(120, 70, 30), (40, 90, 170), (200, 190, 40), (30, 30, 30), (130, 130, 130)]
    for row in range(4):
        y = 80 + row * 115
        r.rect(150, y + 20, 650, y + 30, (150, 150, 155))
        for k in range(14):
            x = 160 + k * 34
            r.rect(x, y, x + 30, y + 52, (248, 248, 246))
            r.rect(x + 10, y + 14, x + 20, y + 30, (40, 40, 40))
        r.rect(160, y + 58, 640, y + 72, (255, 255, 255))
        if v == 1 and row == 0:
            for k in range(5):
                r.text(166 + k * 34, y + 61, f"F{k + 1}", 1, (30, 30, 30))
        for k in range(14):
            x = 172 + k * 34
            r.line(x, y + 52, x + (k % 3 - 1) * 8, y + 112, 4, colors[(k + row) % len(colors)])


def scene_paint_damage(r: Raster, v: int):
    rnd = random.Random(700 + v)
    r.rect(0, 0, W, H, (236, 232, 222))
    for x in range(0, W, 22):
        r.rect(x, 0, x + 11, H, (232, 228, 218))
    pts = []
    for k in range(18):
        a = 2 * math.pi * k / 18
        rr = 120 + rnd.randint(-35, 35)
        pts.append((400 + rr * 1.3 * math.cos(a), 290 + rr * 0.8 * math.sin(a)))
    r.poly(pts, (205, 198, 186))
    for _ in range(40):
        x, y = rnd.randint(260, 540), rnd.randint(200, 380)
        r.ellipse(x, y, rnd.randint(3, 10), rnd.randint(2, 6), (250, 250, 248))
    r.polyline([(330, 250), (380, 300), (430, 290), (470, 340)], 3, (170, 160, 148))
    r.rect(0, 0, 40, H, (250, 250, 250))
    r.rect(0, H - 90, W, H - 70, (120, 90, 60))


def scene_garage(r: Raster, v: int):
    vpx, vpy = 400, 250
    r.rect(0, 0, W, vpy, (95, 98, 104))
    r.rect(0, vpy, W, H, (128, 132, 128))
    for k in range(-6, 7):
        r.line(vpx, vpy, vpx + k * 160, H, 3, (230, 230, 225) if k % 2 else (240, 200, 60))
    for d in (1.0, 0.6, 0.38, 0.25):
        for side in (-1, 1):
            x = vpx + side * 330 * d
            w = 30 * d
            r.rect(x - w, vpy - 210 * d, x + w, vpy + 260 * d, (165, 165, 160))
            r.rect(x - w, vpy + 30 * d, x + w, vpy + 60 * d, (240, 200, 60))
        r.rect(vpx - 180 * d, vpy - 200 * d, vpx + 180 * d, vpy - 190 * d, (250, 250, 235))
    if v == 0:
        r.polyline([(200, 560), (260, 520), (300, 530), (360, 470), (420, 455)], 3, (60, 60, 60))


def scene_facade(r: Raster, v: int):
    r.vgrad(0, 140, *SKY)
    r.rect(0, 140, W, H, (230, 230, 226))
    for y in range(140, H, 50):
        off = (y // 50 % 2) * 50
        for x in range(-off, W, 100):
            r.rect(x + 1, y + 1, x + 99, y + 49, (246, 246, 243))
    r.rect(80, 260, 260, 420, (70, 85, 105))
    r.rect(470, 260, 650, 420, (70, 85, 105))
    r.poly([(300, 300), (390, 280), (430, 340), (370, 400), (290, 380)], (205, 205, 190))
    r.poly([(320, 320), (380, 305), (400, 345), (360, 380), (315, 365)], (240, 240, 240))
    for x in range(30, W, 140):
        r.line(x, 140, x, H, 5, (130, 130, 135))
    for y in range(180, H, 110):
        r.line(0, y, W, y, 5, (130, 130, 135))
        r.rect(0, y + 3, W, y + 9, (200, 160, 80))


def scene_door_opening(r: Raster, v: int):
    r.rect(0, 0, W, H, (215, 212, 205))
    r.rect(300, 80, 500, 520, (70, 68, 66))
    r.rect(250, 290, 560, 306, (245, 210, 40))
    for k in range(0, 31):
        x = 255 + k * 10
        r.rect(x, 290, x + 1, 300 if k % 5 else 306, (30, 30, 30))
    r.rect(340, 220, 470, 262, (255, 255, 255))
    r.text(352, 230, "86 CM", 4, (200, 30, 30))
    r.rect(0, 520, W, H, (150, 145, 135))


def scene_tech_room(r: Raster, v: int):
    r.rect(0, 0, W, H, (196, 198, 196))
    for i, (y, col) in enumerate(((150, (200, 40, 40)), (230, (40, 90, 190)), (310, (200, 40, 40)), (390, (40, 90, 190)))):
        r.rect(0, y - 18, W, y + 18, col)
        if i == 2:
            r.rect(0, y - 26, 380, y + 26, (120, 120, 125))
            r.rect(380, y - 18, 560, y + 18, (190, 120, 70))
            r.rect(560, y - 26, W, y + 26, (120, 120, 125))
        else:
            r.rect(0, y - 26, W, y + 26, (125, 125, 130))
    r.ellipse(250, 230, 30, 30, (60, 60, 60))
    r.rect(620, 90, 760, 470, (235, 235, 232))
    r.rect(100, 440, 220, 520, (40, 130, 70))


def scene_staircase(r: Raster, v: int):
    r.rect(0, 0, W, H, (215, 215, 210))
    for k in range(9):
        y = 520 - k * 50
        x0 = 120 + k * 45
        r.poly([(x0, y), (x0 + 420, y), (x0 + 440, y - 18), (x0 + 20, y - 18)], (185, 185, 180))
        r.rect(x0, y, x0 + 420, y + 32, (160, 160, 156))
    r.line(130, 420, 560, 30, 5, (60, 60, 64))
    for k in range(9):
        x = 140 + k * 46
        r.line(x, 470 - k * 50, x, 410 - k * 50, 3, (80, 80, 84))


def scene_excavation(r: Raster, v: int):
    r.vgrad(0, 200, *SKY)
    r.rect(0, 200, W, 260, (120, 100, 75))
    for i, col in enumerate(((145, 115, 80), (130, 100, 70), (155, 125, 90), (115, 90, 62))):
        r.rect(0, 260 + i * 70, W, 330 + i * 70, col)
    for x in range(30, W, 90):
        r.rect(x, 230, x + 14, H, (90, 90, 95))
    for y in range(250, H, 26):
        r.rect(0, y, W, y + 20, (150, 110, 60))
        for x in range(30, W, 90):
            r.rect(x, y, x + 14, y + 20, (90, 90, 95))
    ex = 520 - v * 60
    r.rect(ex, 120, ex + 160, 190, (240, 180, 30))
    r.rect(ex + 110, 80, ex + 160, 130, (240, 180, 30))
    r.rect(ex + 118, 88, ex + 152, 118, (120, 160, 190))
    r.rect(ex - 10, 190, ex + 180, 222, (50, 50, 52))
    r.line(ex, 140, ex - 120, 60, 12, (230, 170, 25))
    r.line(ex - 120, 60, ex - 170, 150, 10, (230, 170, 25))
    r.poly([(ex - 190, 150), (ex - 140, 150), (ex - 150, 185), (ex - 185, 180)], (80, 80, 84))


def scene_office(r: Raster, v: int):
    r.rect(0, 0, W, 200, (240, 240, 238))
    for x in range(0, W, 80):
        r.rect(x, 0, x + 2, 200, (200, 200, 198))
    for y in range(0, 200, 60):
        r.rect(0, y, W, y + 2, (200, 200, 198))
    for x in range(40, W, 160):
        r.rect(x, 62, x + 76, 118, (255, 255, 250))
    r.rect(0, 200, W, 430, (232, 236, 240))
    r.rect(0, 200, 200, 430, (190, 215, 230))
    for x in range(0, 200, 50):
        r.rect(x, 200, x + 3, 430, (150, 160, 170))
    r.rect(0, 430, W, H, (110, 115, 125))
    for x in range(0, W, 60):
        r.rect(x, 430, x + 2, H, (95, 100, 108))
    r.rect(560, 160, 620, 470, (215, 215, 212))
    if v == 0:
        for k in range(4):
            r.line(300 + k * 18, 0, 290 + k * 22, 170 + k * 12, 3, (40, 40, 40))
    else:
        r.poly([(320, 0), (420, 0), (420, 58), (320, 64)], (180, 175, 160))


def scene_server_room(r: Raster, v: int):
    r.rect(0, 0, W, H, (170, 175, 180))
    for k in range(4):
        x = 80 + k * 150
        r.rect(x, 80, x + 120, 520, (30, 32, 36))
        for y in range(100, 500, 22):
            r.rect(x + 10, y, x + 110, y + 14, (55, 58, 64))
            r.rect(x + 96, y + 4, x + 102, y + 9, (60, 220, 90) if (y // 22 + k) % 4 else (240, 160, 30))
    r.rect(0, 40, W, 60, (205, 165, 40))
    r.rect(680, 160, 780, 260, (40, 38, 36))
    for k in range(6):
        r.line(690 + k * 15, 170, 600 - k * 10, 40, 4, (40 + k * 30, 40, 160 - k * 20))


SCENES = {
    "site": scene_site, "formwork": scene_formwork, "masonry": scene_masonry,
    "balcony_threshold": scene_balcony_threshold, "lintel_crack": scene_lintel_crack,
    "floor_drain": scene_floor_drain, "duct_collision": scene_duct_collision,
    "pipe_penetration": scene_pipe_penetration, "switchboard": scene_switchboard,
    "paint_damage": scene_paint_damage, "garage": scene_garage, "facade": scene_facade,
    "door_opening": scene_door_opening, "tech_room": scene_tech_room, "staircase": scene_staircase,
    "excavation": scene_excavation, "office": scene_office, "server_room": scene_server_room,
}


def render(scene: str, variant: int, number: int, caption: str) -> bytes:
    r = Raster()
    SCENES[scene](r, variant)
    footer(r, number, caption)
    return r.png()
