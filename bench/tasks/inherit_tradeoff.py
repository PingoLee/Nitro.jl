"""#618: the classes' figure (agent-config #82 Idea 5: -i and -g on the rings). Two panels on the same
axes as share_tradeoff.py: the mixed cell (mixed_cell.jl, the starved cell with :interactive clients at
--threads=8,1, C = 500, H = 2 ms, D = 8 s, while unmarked fib_fine loops on :default) and the mixed-inner
cell (the same with the inner shape: each handler spawns four :default children of H/4 and fetches
them). x is the requests' p99, y is fib_fine's wall per run in the cell over its standalone wall in the
same process. Whiskers are [min-max] over 3 rounds, the point is the median. The fair wait (125 ms),
y = 1 and the two limits (p99 0.6 s, fib_fine 2.5x) are drawn in, so a rule that passes sits in the
lower-left box. -g's weight sweep (w = 1/4, 1/2, 3/4 of the time to the request side) is joined by a
line.

A variant whose fib_fine finished no run inside the 8 s cell in at least one round has no full y: it is
drawn hollow, with an arrow up, at the median of the rounds whose run did end (A in the mixed cell: 2 of
3; A and M-t-r2 in the mixed-inner cell: 1 of 3), a lower bound. M-g0-r2 never moves the balance (L
first), the negative control.

Every number is a literal from this run's tables (aggregate_fifo.jl mixed and mixedinner). Plain
Python, no dependencies; writes inherit-tradeoff.svg beside this file (the PNG is converted from it;
see the PR).

    python3 bench/tasks/inherit_tradeoff.py
"""
import html, math, os

# (label, p99 lo, p99 hi, p99 median, y lo, y hi, y median, measured y?, label dx, label dy)
MIXED = [
    ("A", 7326, 8077, 8039, 10.9, 11.5, 11.2, False, 8, -10),
    ("C", 674, 1749, 911, 3.13, 4.05, 3.73, True, 8, -8),
    ("M-l-r2", 8582, 8697, 8653, 0.94, 1.06, 0.98, True, -50, 20),
    ("M-g0-r2", 8100, 8816, 8161, 0.95, 1.07, 1.01, True, -62, -9),
    ("M-t-r2", 326, 334, 328, 1.69, 1.89, 1.75, True, -52, -9),
    ("M-it-r2", 326, 339, 327, 1.69, 1.82, 1.76, True, -56, 18),
    ("M-g (w 1/2)", 327, 330, 328, 1.71, 1.80, 1.75, True, 9, 4),
    ("M-g25 (w 1/4)", 672, 696, 689, 1.20, 1.29, 1.25, True, 9, 16),
    ("M-g75 (w 3/4)", 213, 214, 213, 3.12, 3.32, 3.21, True, 9, -7),
]
MIXED_INNER = [
    ("A", 3051, 6574, 5217, 10.3, 10.3, 10.3, False, -30, 22),
    ("M-t-r2", 4871, 7855, 5616, 10.6, 10.6, 10.6, False, 8, -10),
    ("C", 1214, 1277, 1270, 1.23, 1.78, 1.45, True, 8, -8),
    ("M-l-r2", 8693, 8768, 8711, 0.97, 1.08, 1.02, True, -50, -9),
    ("M-g0-r2", 8131, 8852, 8277, 0.95, 1.05, 0.99, True, -62, 20),
    ("M-it-r2", 293, 319, 302, 1.68, 1.86, 1.75, True, -56, 18),
    ("M-g (w 1/2)", 320, 329, 325, 1.77, 1.88, 1.81, True, 9, -6),
    ("M-g25 (w 1/4)", 687, 709, 692, 1.18, 1.31, 1.23, True, 9, 16),
    ("M-g75 (w 3/4)", 210, 213, 211, 3.22, 3.41, 3.31, True, 9, -7),
]
# -g's weight sweep, in order of w: the labels of the points joined by a line in each panel.
SWEEP = ["M-g25 (w 1/4)", "M-g (w 1/2)", "M-g75 (w 3/4)"]

FAIR_MS, LIMIT_MS, LIMIT_Y = 125.0, 600.0, 2.5
W, H = 1240, 640
BG, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1"
PT, NEW, FAIR, LIMIT = "#2a78d6", "#c0651a", "#2e8b57", "#9a3fb5"
X_LO, X_HI = 100.0, 10000.0          # log
Y_LO, Y_HI = 0.8, 14.0               # log
X_TICKS = [125, 300, 600, 1000, 3000, 10000]
Y_TICKS = [1, 1.5, 2.5, 4, 6, 10]


def panel(svg, x0, y0, w, h, title, points):
    px = lambda v: x0 + w * (math.log(v) - math.log(X_LO)) / (math.log(X_HI) - math.log(X_LO))
    py = lambda v: y0 + h - h * (math.log(v) - math.log(Y_LO)) / (math.log(Y_HI) - math.log(Y_LO))
    svg.append(f'<text x="{x0}" y="{y0 - 24}" font-size="15" font-weight="600" fill="{INK}">{html.escape(title)}</text>')
    for t in X_TICKS:
        svg.append(f'<line x1="{px(t):.1f}" y1="{y0}" x2="{px(t):.1f}" y2="{y0 + h}" stroke="{GRID}"/>')
        svg.append(f'<text x="{px(t):.1f}" y="{y0 + h + 18}" font-size="11" fill="{INK2}" text-anchor="middle">{t:,}</text>')
    for t in Y_TICKS:
        svg.append(f'<line x1="{x0}" y1="{py(t):.1f}" x2="{x0 + w}" y2="{py(t):.1f}" stroke="{GRID}"/>')
        svg.append(f'<text x="{x0 - 8}" y="{py(t) + 4:.1f}" font-size="11" fill="{INK2}" text-anchor="end">{t:g}×</text>')
    svg.append(f'<rect x="{x0}" y="{py(LIMIT_Y):.1f}" width="{px(LIMIT_MS) - x0:.1f}" height="{y0 + h - py(LIMIT_Y):.1f}" '
               f'fill="{FAIR}" fill-opacity="0.06" stroke="{LIMIT}" stroke-dasharray="6 3"/>')
    svg.append(f'<text x="{px(LIMIT_MS) - 4:.1f}" y="{py(LIMIT_Y) - 6:.1f}" font-size="11" fill="{LIMIT}" text-anchor="end">pass: p99 &lt; 0.6 s, fib_fine &lt; 2.5×</text>')
    svg.append(f'<line x1="{px(FAIR_MS):.1f}" y1="{y0}" x2="{px(FAIR_MS):.1f}" y2="{y0 + h}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{px(FAIR_MS) + 4:.1f}" y="{y0 + 12}" font-size="11" fill="{FAIR}">fair wait 125 ms</text>')
    svg.append(f'<line x1="{x0}" y1="{py(1):.1f}" x2="{x0 + w}" y2="{py(1):.1f}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{x0 + w / 2}" y="{y0 + h + 38}" font-size="12" fill="{INK2}" text-anchor="middle">request p99, ms (log): lower is fairer to requests</text>')
    svg.append(f'<text x="{x0 - 46}" y="{y0 + h / 2}" font-size="12" fill="{INK2}" text-anchor="middle" '
               f'transform="rotate(-90 {x0 - 46} {y0 + h / 2})">fib_fine per run / standalone (log)</text>')
    by = {p[0]: p for p in points}
    line = [by[l] for l in SWEEP if l in by]
    if len(line) > 1:
        d = " ".join(f'{"M" if i == 0 else "L"} {px(p[3]):.1f} {py(p[6]):.1f}' for i, p in enumerate(line))
        svg.append(f'<path d="{d}" fill="none" stroke="{NEW}" stroke-width="1.5" stroke-dasharray="5 3"/>')
    for label, a, b, xm, c, d, ym, measured, dx, dy in points:
        col = NEW if label.startswith(("M-g", "M-i")) else PT
        if b > a:
            svg.append(f'<line x1="{px(a):.1f}" y1="{py(ym):.1f}" x2="{px(b):.1f}" y2="{py(ym):.1f}" stroke="{col}" stroke-width="1.5"/>')
        if d > c:
            svg.append(f'<line x1="{px(xm):.1f}" y1="{py(c):.1f}" x2="{px(xm):.1f}" y2="{py(d):.1f}" stroke="{col}" stroke-width="1.5"/>')
        if measured:
            svg.append(f'<circle cx="{px(xm):.1f}" cy="{py(ym):.1f}" r="5" fill="{col}" stroke="{col}" stroke-width="1.5"/>')
        else:
            svg.append(f'<circle cx="{px(xm):.1f}" cy="{py(ym):.1f}" r="5" fill="{BG}" stroke="{col}" stroke-width="1.5"/>')
            svg.append(f'<line x1="{px(xm):.1f}" y1="{py(ym) - 6:.1f}" x2="{px(xm):.1f}" y2="{py(ym) - 22:.1f}" stroke="{col}" stroke-width="1.5"/>')
            svg.append(f'<path d="M {px(xm) - 4:.1f} {py(ym) - 18:.1f} L {px(xm):.1f} {py(ym) - 25:.1f} L {px(xm) + 4:.1f} {py(ym) - 18:.1f}" fill="none" stroke="{col}" stroke-width="1.5"/>')
        svg.append(f'<text x="{px(xm) + dx:.1f}" y="{py(ym) + dy:.1f}" font-size="12" fill="{INK}">{html.escape(label)}</text>')


def main():
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="40" y="34" font-size="18" font-weight="700" fill="{INK}">A request\'s children as the request\'s: the mixed cell, with and without a fork-join inside the request</text>',
           f'<text x="40" y="56" font-size="12" fill="{INK2}">Julia 1.13.4, --threads=8,1, 500 clients on :interactive, 2 ms handlers, 8 s, unmarked fib_fine looping beside them. '
           f'Medians of 3 rounds, whiskers [min-max].</text>']
    panel(svg, 110, 116, 500, 400, "The mixed cell (handlers burn 2 ms)", MIXED)
    panel(svg, 720, 116, 500, 400, "The mixed-inner cell (four children of 0.5 ms)", MIXED_INNER)
    svg.append(f'<text x="40" y="{H - 58}" font-size="11" fill="{MUTED}">-g: a marked request\'s children and its wakes go to a second set of stock heaps; the request side (those heaps, then the rings of roots) '
               f'and unmarked work share time,</text>')
    svg.append(f'<text x="40" y="{H - 40}" font-size="11" fill="{MUTED}">w to the request side. -i: the children are marked and queue with the roots.</text>')
    svg.append(f'<text x="40" y="{H - 22}" font-size="11" fill="{MUTED}">Hollow points with an arrow: in some rounds no fib_fine run ended inside the 8 s cell; a lower bound. M-g0-r2: the balance never moves (L first). '
               f'Orange: the classes; blue: the controls.</text>')
    svg.append('</svg>')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inherit-tradeoff.svg")
    with open(out, "w") as f:
        f.write("\n".join(svg) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
