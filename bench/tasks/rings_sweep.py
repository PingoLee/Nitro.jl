"""#618: the rings figure. The H = 0 cell (spawn_order.jl 500:0: C = 500 clients on :default, 0 ms handlers,
every handler and client marked under M) against the thread count: --threads=2,0 on CPUs 0,1; 4,0 on 0-3
(one thread per core); 8,0 on the 8 CPUs (4 cores x 2 SMT). Requests per second, medians of 3 rounds,
whiskers [min-max]. A is stock; M-l is the single F queue behind one lock; M-l-r<d> is a ring per stock
heap, each behind its own lock, popped by sampling d rings for the older head. The dashed line is 0.9x A,
the rings prompt's cost limit.

Every number is a literal from the rings run's sweep rounds (aggregate_fifo.jl <dir> sweep). Plain Python,
no dependencies; writes rings-sweep.svg beside this file (the PNG is converted from it; see the PR).

    python3 bench/tasks/rings_sweep.py
"""
import html, os

THREADS = [2, 4, 8]
# label -> [(median, min, max) per thread count], req/s
SERIES = [
    ("A (stock)", "#52514e", "square", [(1372034, 1366833, 1372975), (2268300, 2253177, 2269176), (3119382, 3020412, 3148336)]),
    ("M-l (one lock)", "#c0651a", "circle", [(1325862, 1318101, 1328216), (1563759, 1563442, 1573040), (1192781, 1192723, 1193843)]),
    ("M-l-r2 (rings, d = 2)", "#2a78d6", "diamond", [(1293677, 1274960, 1303822), (2157844, 2135148, 2165596), (2837952, 2837880, 2865296)]),
    ("M-l-r4 (rings, d = 4)", "#2e9a6a", "triangle", [(1270637, 1269530, 1290574), (2116171, 2096402, 2117332), (2788852, 2768574, 2835532)]),
]
LABEL_DY = {"A (stock)": -10, "M-l (one lock)": 4, "M-l-r2 (rings, d = 2)": 2, "M-l-r4 (rings, d = 4)": 18}

W, H = 720, 470
BG, INK, INK2, MUTED, GRID, LIMIT = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1", "#8a8984"
X0, Y0, PW, PH = 90, 90, 400, 290
Y_HI = 3.5e6


def px(t):
    return X0 + PW * THREADS.index(t) / (len(THREADS) - 1)


def py(v):
    return Y0 + PH - PH * v / Y_HI


def marker(shape, x, y, col):
    if shape == "square":
        return f'<rect x="{x - 4.5:.1f}" y="{y - 4.5:.1f}" width="9" height="9" fill="{col}" stroke="{BG}" stroke-width="2"/>'
    if shape == "diamond":
        return f'<path d="M {x:.1f} {y - 6:.1f} L {x + 6:.1f} {y:.1f} L {x:.1f} {y + 6:.1f} L {x - 6:.1f} {y:.1f} Z" fill="{col}" stroke="{BG}" stroke-width="2"/>'
    if shape == "triangle":
        return f'<path d="M {x:.1f} {y - 6:.1f} L {x + 6:.1f} {y + 5:.1f} L {x - 6:.1f} {y + 5:.1f} Z" fill="{col}" stroke="{BG}" stroke-width="2"/>'
    return f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{col}" stroke="{BG}" stroke-width="2"/>'


def main():
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="30" y="32" font-size="17" font-weight="700" fill="{INK}">Every task marked, no work per task: does the F queue scale?</text>',
           f'<text x="30" y="54" font-size="12" fill="{INK2}">Julia 1.13.4, 500 clients on :default, 0 ms handlers, all marked. Medians of 3 rounds, whiskers [min-max].</text>']
    for v in [0, 1e6, 2e6, 3e6]:
        svg.append(f'<line x1="{X0}" y1="{py(v):.1f}" x2="{X0 + PW}" y2="{py(v):.1f}" stroke="{GRID}"/>')
        svg.append(f'<text x="{X0 - 8}" y="{py(v) + 4:.1f}" font-size="11" fill="{INK2}" text-anchor="end">{f"{v / 1e6:g}M" if v else "0"}</text>')
    for t in THREADS:
        svg.append(f'<text x="{px(t):.1f}" y="{Y0 + PH + 18}" font-size="11" fill="{INK2}" text-anchor="middle">{t},0</text>')
    svg.append(f'<text x="{X0 + PW / 2}" y="{Y0 + PH + 38}" font-size="12" fill="{INK2}" text-anchor="middle">--threads (2 and 4: one per core; 8: 4 cores x 2 SMT)</text>')
    svg.append(f'<text x="{X0 - 58}" y="{Y0 + PH / 2}" font-size="12" fill="{INK2}" text-anchor="middle" '
               f'transform="rotate(-90 {X0 - 58} {Y0 + PH / 2})">requests per second</text>')
    # 0.9x A, the cost limit
    a = SERIES[0][3]
    pts = " ".join(f"{px(t):.1f},{py(0.9 * m[0]):.1f}" for t, m in zip(THREADS, a))
    svg.append(f'<polyline points="{pts}" fill="none" stroke="{LIMIT}" stroke-width="1.5" stroke-dasharray="5 4"/>')
    mid = 0.9 * (a[1][0] + a[2][0]) / 2
    svg.append(f'<text x="{(px(4) + px(8)) / 2 + 10:.1f}" y="{py(mid) + 22:.1f}" font-size="11" fill="{MUTED}">0.9x A (the limit)</text>')
    for label, col, shape, vals in SERIES:
        pts = " ".join(f"{px(t):.1f},{py(m[0]):.1f}" for t, m in zip(THREADS, vals))
        svg.append(f'<polyline points="{pts}" fill="none" stroke="{col}" stroke-width="2"/>')
        for t, (m, lo, hi) in zip(THREADS, vals):
            if hi > lo:
                svg.append(f'<line x1="{px(t):.1f}" y1="{py(lo):.1f}" x2="{px(t):.1f}" y2="{py(hi):.1f}" stroke="{col}" stroke-width="1.5"/>')
            svg.append(marker(shape, px(t), py(m), col))
        m8 = vals[-1][0]
        svg.append(marker(shape, X0 + PW + 16, py(m8) + LABEL_DY[label] - 4, col))
        svg.append(f'<text x="{X0 + PW + 28}" y="{py(m8) + LABEL_DY[label]:.1f}" font-size="12" fill="{INK}">{html.escape(label)}: '
                   f'{m8 / a[-1][0]:.2f}x A</text>')
    svg.append(f'<text x="30" y="{H - 20}" font-size="11" fill="{MUTED}">M-none (the same code, nothing marked) is within 2% of A at every count. '
               f'Source: rings_sweep.py, the rings run on #618.</text>')
    svg.append('</svg>')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rings-sweep.svg")
    with open(out, "w") as f:
        f.write("\n".join(svg) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
