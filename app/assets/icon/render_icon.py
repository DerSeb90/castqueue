"""Renders CastQueue launcher icon assets with Pillow (4x supersampled).
Glyph: three amber queue bars top-left, big amber play triangle bottom-right."""
from PIL import Image, ImageDraw

BG = (0x0E, 0x0E, 0x10, 255)
AMBER = (0xF5, 0xA5, 0x24, 255)
S = 4  # supersample
N = 1024


def glyph(draw, ox, oy, scale):
    """Draw glyph into a box of size `scale` (glyph design space 0..1) at offset."""
    def P(x, y):
        return (ox + x * scale, oy + y * scale)

    def bar(x0, y0, x1, y1):
        r = (y1 - y0) / 2 * scale
        draw.rounded_rectangle([P(x0, y0), P(x1, y1)], radius=r, fill=AMBER)

    # three bars: equal height, decreasing width (queue)
    h = 0.115
    gap = 0.075
    y = 0.06
    bar(0.04, y, 0.62, y + h); y += h + gap
    bar(0.04, y, 0.50, y + h); y += h + gap
    bar(0.04, y, 0.38, y + h)
    # play triangle bottom-right with properly rounded corners:
    # inset the triangle by r, then fill polygon + thick edges + corner discs.
    import math
    r = 0.06
    pts = [(0.46, 0.46), (1.00, 0.72), (0.46, 0.98)]
    # inward offset of each vertex along the angle bisector
    def inset(i):
        a = pts[i - 1]; b = pts[i]; c = pts[(i + 1) % 3]
        v1 = (a[0] - b[0], a[1] - b[1]); v2 = (c[0] - b[0], c[1] - b[1])
        n1 = math.hypot(*v1); n2 = math.hypot(*v2)
        v1 = (v1[0] / n1, v1[1] / n1); v2 = (v2[0] / n2, v2[1] / n2)
        bis = (v1[0] + v2[0], v1[1] + v2[1]); nb = math.hypot(*bis)
        bis = (bis[0] / nb, bis[1] / nb)
        half = math.acos(max(-1, min(1, v1[0] * v2[0] + v1[1] * v2[1]))) / 2
        d = r / math.sin(half)
        return (b[0] + bis[0] * d, b[1] + bis[1] * d)
    ins = [inset(i) for i in range(3)]
    draw.polygon([P(*q) for q in ins], fill=AMBER)
    w = int(2 * r * scale)
    for i in range(3):
        draw.line([P(*ins[i]), P(*ins[(i + 1) % 3])], fill=AMBER, width=w)
    rr = r * scale
    for (x, yv) in [P(*q) for q in ins]:
        draw.ellipse([x - rr, yv - rr, x + rr, yv + rr], fill=AMBER)


def render(with_bg: bool, glyph_frac: float, path: str):
    W = N * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if with_bg:
        d.rounded_rectangle([0, 0, W - 1, W - 1], radius=int(W * 0.22), fill=BG)
    g = W * glyph_frac
    off = (W - g) / 2
    glyph(d, off, off, g)
    img = img.resize((N, N), Image.LANCZOS)
    img.save(path)


render(True, 0.62, "assets/icon/icon.png")
render(False, 0.88, "assets/icon/icon_foreground.png")
print("done")
