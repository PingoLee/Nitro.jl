"""#618: the share figure. The mixed cell (mixed_cell.jl: the starved cell with :interactive clients at
--threads=8,1, C = 500, H = 2 ms, D = 8 s, while unmarked fib_fine loops on :default) for every variant
of the share run: x is the requests' p99, y is fib_fine's wall per run in the cell over its standalone
wall in the same process. Whiskers are [min-max] over 3 rounds, the point is the median. The fair wait
(125 ms: 500 clients x 2 ms / 8 threads), y = 1 and the share prompt's two limits (p99 0.6 s,
fib_fine 2.5x) are drawn in, so a share that passes sits in the lower-left box.

A variant whose fib_fine finished no run inside the 8 s cell has no measured y: it is drawn at 8 s over
its standalone wall, a lower bound, with an arrow up.

The right panel is the inner shape (spawn_order.jl 500:2:inner, :interactive clients, 8,1), where a
share must keep the request p99 under 0.2 s; it is the cell the time share fails.

Every number is a literal from this run's tables (aggregate_fifo.jl mixed and the rounds). Plain Python,
no dependencies; writes share-tradeoff.svg beside this file (the PNG is converted from it; see the PR).

    python3 bench/tasks/share_tradeoff.py
"""
import html, math, os

# (label, p99 lo, p99 hi, p99 median, y lo, y hi, y median, measured y?, label dx, label dy)
MIXED = [
    ("A (stock)",  4554, 8117, 8030, 10.3, 10.3, 10.3, False, 8, -10),
    ("C",          1077, 1217, 1082, 3.23, 3.83, 3.74, True,  8, -8),
    ("M-l",        8616, 8805, 8628, 0.97, 1.08, 1.02, True,  -36, -8),
    ("M-t0 (accounting off)", 8663, 8780, 8758, 0.95, 1.07, 1.00, True, -150, -26),
    ("M-t (time share)", 305, 322, 308, 1.74, 1.85, 1.78, True, 8, 16),
    ("M-p2",       139, 139, 139, 10.5, 10.5, 10.5, False, -48, 4),
    ("M-p16",      141, 143, 142, 10.2, 10.2, 10.2, False, -20, 24),
    ("M-p128",     157, 161, 159, 10.1, 10.4, 10.1, True,  10, 5),
    ("M-p1024",    262, 264, 263, 2.06, 2.14, 2.09, True,  8, -8),
]
# (label, p99 lo, hi, median)
INNER = [
    ("A (stock)", 1786, 1819, 1805),
    ("M-l",       135, 138, 137),
    ("M-t",       2366, 3088, 2516),
    ("M-p2",      2169, 2471, 2369),
    ("M-p1024",   137, 137, 137),
]

FAIR_MS, LIMIT_MS, LIMIT_Y, INNER_LIMIT_MS = 125.0, 600.0, 2.5, 200.0
W, H = 1180, 620
BG, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1"
PT, FAIR, LIMIT, FAILC = "#2a78d6", "#2e8b57", "#c0651a", "#b8322a"
X_LO, X_HI = 100.0, 10000.0          # log
Y_LO, Y_HI = 0.8, 14.0               # log
X_TICKS = [125, 300, 600, 1000, 3000, 10000]
Y_TICKS = [1, 1.5, 2.5, 4, 6, 10]


def mixed_panel(svg, x0, y0, w, h):
    px = lambda v: x0 + w * (math.log(v) - math.log(X_LO)) / (math.log(X_HI) - math.log(X_LO))
    py = lambda v: y0 + h - h * (math.log(v) - math.log(Y_LO)) / (math.log(Y_HI) - math.log(Y_LO))
    svg.append(f'<text x="{x0}" y="{y0 - 24}" font-size="15" font-weight="600" fill="{INK}">The mixed cell: requests beside unmarked fib_fine</text>')
    for t in X_TICKS:
        svg.append(f'<line x1="{px(t):.1f}" y1="{y0}" x2="{px(t):.1f}" y2="{y0 + h}" stroke="{GRID}"/>')
        svg.append(f'<text x="{px(t):.1f}" y="{y0 + h + 18}" font-size="11" fill="{INK2}" text-anchor="middle">{t:,}</text>')
    for t in Y_TICKS:
        svg.append(f'<line x1="{x0}" y1="{py(t):.1f}" x2="{x0 + w}" y2="{py(t):.1f}" stroke="{GRID}"/>')
        svg.append(f'<text x="{x0 - 8}" y="{py(t) + 4:.1f}" font-size="11" fill="{INK2}" text-anchor="end">{t:g}×</text>')
    # the pass box: p99 < 0.6 s and fib_fine < 2.5x
    svg.append(f'<rect x="{x0}" y="{py(LIMIT_Y):.1f}" width="{px(LIMIT_MS) - x0:.1f}" height="{y0 + h - py(LIMIT_Y):.1f}" '
               f'fill="{FAIR}" fill-opacity="0.06" stroke="{LIMIT}" stroke-dasharray="6 3"/>')
    svg.append(f'<text x="{px(LIMIT_MS) - 4:.1f}" y="{py(LIMIT_Y) - 6:.1f}" font-size="11" fill="{LIMIT}" text-anchor="end">pass: p99 &lt; 0.6 s, fib_fine &lt; 2.5×</text>')
    svg.append(f'<line x1="{px(FAIR_MS):.1f}" y1="{y0}" x2="{px(FAIR_MS):.1f}" y2="{y0 + h}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{px(FAIR_MS) + 4:.1f}" y="{y0 + 12}" font-size="11" fill="{FAIR}">fair wait 125 ms</text>')
    svg.append(f'<line x1="{x0}" y1="{py(1):.1f}" x2="{x0 + w}" y2="{py(1):.1f}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{px(LIMIT_MS) + 8:.1f}" y="{py(1) + 16:.1f}" font-size="11" fill="{FAIR}">fib_fine at its standalone wall (y = 1)</text>')
    svg.append(f'<text x="{x0 + w / 2}" y="{y0 + h + 38}" font-size="12" fill="{INK2}" text-anchor="middle">request p99, ms (log): lower is fairer to requests</text>')
    svg.append(f'<text x="{x0 - 46}" y="{y0 + h / 2}" font-size="12" fill="{INK2}" text-anchor="middle" '
               f'transform="rotate(-90 {x0 - 46} {y0 + h / 2})">fib_fine wall per run / standalone (log): lower is fairer to it</text>')
    for label, a, b, xm, c, d, ym, measured, dx, dy in MIXED:
        if b > a:
            svg.append(f'<line x1="{px(a):.1f}" y1="{py(ym):.1f}" x2="{px(b):.1f}" y2="{py(ym):.1f}" stroke="{PT}" stroke-width="1.5"/>')
        if d > c:
            svg.append(f'<line x1="{px(xm):.1f}" y1="{py(c):.1f}" x2="{px(xm):.1f}" y2="{py(d):.1f}" stroke="{PT}" stroke-width="1.5"/>')
        if measured:
            svg.append(f'<circle cx="{px(xm):.1f}" cy="{py(ym):.1f}" r="5" fill="{PT}" stroke="{PT}" stroke-width="1.5"/>')
        else:   # a lower bound: no fib_fine run ended inside the cell
            svg.append(f'<circle cx="{px(xm):.1f}" cy="{py(ym):.1f}" r="5" fill="{BG}" stroke="{PT}" stroke-width="1.5"/>')
            svg.append(f'<line x1="{px(xm):.1f}" y1="{py(ym) - 6:.1f}" x2="{px(xm):.1f}" y2="{py(ym) - 22:.1f}" stroke="{PT}" stroke-width="1.5"/>')
            svg.append(f'<path d="M {px(xm) - 4:.1f} {py(ym) - 18:.1f} L {px(xm):.1f} {py(ym) - 25:.1f} L {px(xm) + 4:.1f} {py(ym) - 18:.1f}" fill="none" stroke="{PT}" stroke-width="1.5"/>')
        svg.append(f'<text x="{px(xm) + dx:.1f}" y="{py(ym) + dy:.1f}" font-size="12" fill="{INK}">{html.escape(label)}</text>')


def inner_panel(svg, x0, y0, w, h):
    px = lambda v: x0 + w * (math.log(v) - math.log(X_LO)) / (math.log(X_HI) - math.log(X_LO))
    svg.append(f'<text x="{x0}" y="{y0 - 24}" font-size="15" font-weight="600" fill="{INK}">The inner shape: request p99</text>')
    for t in [125, 200, 1000, 3000, 10000]:
        svg.append(f'<line x1="{px(t):.1f}" y1="{y0}" x2="{px(t):.1f}" y2="{y0 + h}" stroke="{GRID}"/>')
        svg.append(f'<text x="{px(t):.1f}" y="{y0 + h + 18}" font-size="11" fill="{INK2}" text-anchor="middle">{t:,}</text>')
    svg.append(f'<rect x="{x0}" y="{y0}" width="{px(INNER_LIMIT_MS) - x0:.1f}" height="{h}" fill="{FAIR}" fill-opacity="0.06" stroke="{LIMIT}" stroke-dasharray="6 3"/>')
    svg.append(f'<text x="{px(INNER_LIMIT_MS) + 4:.1f}" y="{y0 + 12}" font-size="11" fill="{LIMIT}">pass: &lt; 0.2 s</text>')
    svg.append(f'<text x="{x0 + w / 2}" y="{y0 + h + 38}" font-size="12" fill="{INK2}" text-anchor="middle">request p99, ms (log)</text>')
    step = h / (len(INNER) + 1)
    for i, (label, a, b, m) in enumerate(INNER):
        y = y0 + step * (i + 1)
        col = PT if m < INNER_LIMIT_MS else FAILC
        if b > a:
            svg.append(f'<line x1="{px(a):.1f}" y1="{y:.1f}" x2="{px(b):.1f}" y2="{y:.1f}" stroke="{col}" stroke-width="1.5"/>')
        svg.append(f'<circle cx="{px(m):.1f}" cy="{y:.1f}" r="5" fill="{col}"/>')
        anchor, lx = ("end", px(a) - 8) if m > 1000 else ("start", px(b) + 8)
        svg.append(f'<text x="{lx:.1f}" y="{y + 4:.1f}" font-size="12" fill="{INK}" text-anchor="{anchor}">{html.escape(label)}</text>')


def main():
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="40" y="34" font-size="18" font-weight="700" fill="{INK}">A share between marked and unmarked work: who starves whom?</text>',
           f'<text x="40" y="56" font-size="12" fill="{INK2}">Julia 1.13.4, --threads=8,1, 500 clients on :interactive, 2 ms handlers, 8 s. Marked: handlers and clients (M). '
           f'Medians of 3 rounds, whiskers [min-max].</text>']
    mixed_panel(svg, 110, 116, 640, 390)
    inner_panel(svg, 830, 116, 300, 390)
    svg.append(f'<text x="40" y="{H - 40}" font-size="11" fill="{MUTED}">M-t: each thread serves the side (F queue or heaps) with less time since the two last balanced, capped at 10 ms. '
               f'M-pK: heaps first, every K-th pop F first. M-l: heaps first, always.</text>')
    svg.append(f'<text x="40" y="{H - 22}" font-size="11" fill="{MUTED}">Hollow points with an arrow: no fib_fine run ended inside the 8 s cell; drawn at 8 s / standalone, a lower bound. '
               f'Red: fails the inner shape\'s 0.2 s limit.</text>')
    svg.append('</svg>')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "share-tradeoff.svg")
    with open(out, "w") as f:
        f.write("\n".join(svg) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
