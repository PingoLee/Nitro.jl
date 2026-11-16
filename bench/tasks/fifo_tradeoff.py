"""#618: the trade-off figure. Every multiqueue order variant measured on the reduced repro, on one plot
per client pool: x is the starved cell's request p99 (C = 500 clients, H = 2 ms, D = 8 s, --threads=8,1),
y is fine-grain `pfib`'s (nested.jl `fib_fine`) wall time over stock's. Whiskers are [min-max] (over
rounds, or over builds and layouts for the earlier runs, as their comments report them). The fair wait
(125 ms: 500 clients x 2 ms / 8 threads) and y = 1 are drawn in, so the corner "fair and cheap" is the
lower left. A variant that failed stays on the plot.

Every number is a literal, with the #618 comment it came from. Plain Python, no dependencies; writes
fifo-tradeoff.svg beside this file (the PNG is converted from it; see the PR).

    python3 bench/tasks/fifo_tradeoff.py
"""
import html, math, os

ISSUE = "https://github.com/PingoLee/Nitro.jl/issues/618#issuecomment-"
E_COMMENT = ISSUE + "6289909490"      # variant E (A, C, E61 in the rounds; E2..E16 in the K sweep, 1.13.2)
D_COMMENT = ISSUE + "6258052506"      # variant D3
B_NOTE = ISSUE + "6252406575"         # B under nesting
THIS_RUN = "this run (variants M and O, 1.13.4)"

# (label, p99 lo, p99 hi, fib_fine/A lo, hi, source, kind[, label dy in px]) per panel. kind: "now" (this run) or
# "earlier". The earlier rows are the comments' ranges over builds (p99) and over build x layout
# cells (fib_fine); the K sweep's rows are 1.13.2 medians (one value).
INTERACTIVE = [
    # earlier runs: clients on :interactive at 8,1 (stock A is re-measured below)
    ("C (earlier)", 380, 443, 2.18, 2.61, E_COMMENT, "earlier", 18),
    ("D3", 401, 506, 1.71, 2.17, D_COMMENT, "earlier"),
    ("E61", 2871, 3088, 1.19, 1.26, E_COMMENT, "earlier"),
    ("E16", 1944, 1944, 1.34, 1.34, E_COMMENT, "earlier"),
    ("E8", 1148, 1148, 1.48, 1.48, E_COMMENT, "earlier"),
    ("E4", 592, 592, 1.65, 1.65, E_COMMENT, "earlier"),
    ("E2", 294, 294, 1.93, 1.93, E_COMMENT, "earlier"),
    # this run, 1.13.4, 3 rounds: p99 [min-max] at 8,1; fib_fine wall / A per round at 8,1, [min-max].
    # M marks nothing in nested.jl, so its fib_fine row is the unmarked program's.
    ("A (stock)", 2849, 2959, 1.0, 1.0, THIS_RUN, "now", -8),
    ("M-none", 3038, 3489, 0.98, 1.01, THIS_RUN, "now", 16),
    ("C", 397, 552, 2.39, 2.51, THIS_RUN, "now"),
    ("M-f, M-l, O-f, O-l", 139, 139, 0.97, 1.02, THIS_RUN, "now", -8),
    # the optional row: every fib_fine task marked (1 round, MARK_ALL=1), M-f 2.25x and M-l 2.28x
    ("M, every fib_fine task marked", 139, 139, 2.25, 2.28, THIS_RUN, "now", 18),
]
DEFAULT = [
    # earlier runs: clients on :default at 8,1
    ("C (earlier)", 298, 362, 2.18, 2.61, E_COMMENT, "earlier", 18),
    ("D3", 552, 659, 1.71, 2.17, D_COMMENT, "earlier"),
    ("E61", 2233, 2473, 1.19, 1.26, E_COMMENT, "earlier"),
    ("E16", 1171, 1171, 1.34, 1.34, E_COMMENT, "earlier"),
    ("E8", 779, 779, 1.48, 1.48, E_COMMENT, "earlier"),
    ("E4", 499, 499, 1.65, 1.65, E_COMMENT, "earlier"),
    ("E2", 266, 266, 1.93, 1.93, E_COMMENT, "earlier"),
    # this run. M-h marks the handlers only and O-l at 8,1 makes the clients F (one side marked);
    # their fib_fine rows are M-l's and O-l's (nothing in nested.jl is marked).
    ("A, M-none, M-h-f", 1829, 2473, 0.98, 1.02, THIS_RUN, "now", 16),
    ("O-f (clients F)", 2903, 3359, 0.99, 1.0, THIS_RUN, "now", -8),
    ("C", 331, 354, 2.39, 2.51, THIS_RUN, "now"),
    ("M-f, M-l", 153, 174, 0.97, 1.02, THIS_RUN, "now", 16),
    ("M-h-l, O-l (one side F)", 126, 126, 0.97, 1.02, THIS_RUN, "now", -8),
]
B_TEXT = "B (`<=`, upstream's reverted patch): p99 470-770 ms, fib_fine 283-350x stock, off the scale"

FAIR_MS = 125.0
W, H = 1180, 640
BG, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1"
NOW, EARLIER, FAIR = "#2a78d6", "#8a8984", "#2e8b57"
X_LO, X_HI = 100.0, 10000.0          # log
Y_LO, Y_HI = 0.8, 3.0                # log
X_TICKS = [125, 300, 1000, 3000, 10000]
Y_TICKS = [1, 1.25, 1.5, 2, 2.5, 3]


def panel(svg, x0, y0, w, h, title, rows):
    px = lambda v: x0 + w * (math.log(v) - math.log(X_LO)) / (math.log(X_HI) - math.log(X_LO))
    py = lambda v: y0 + h - h * (math.log(v) - math.log(Y_LO)) / (math.log(Y_HI) - math.log(Y_LO))
    svg.append(f'<text x="{x0}" y="{y0 - 28}" font-size="15" font-weight="600" fill="{INK}">{html.escape(title)}</text>')
    for t in X_TICKS:
        svg.append(f'<line x1="{px(t):.1f}" y1="{y0}" x2="{px(t):.1f}" y2="{y0 + h}" stroke="{GRID}"/>')
        svg.append(f'<text x="{px(t):.1f}" y="{y0 + h + 18}" font-size="11" fill="{INK2}" text-anchor="middle">{t:,}</text>')
    for t in Y_TICKS:
        svg.append(f'<line x1="{x0}" y1="{py(t):.1f}" x2="{x0 + w}" y2="{py(t):.1f}" stroke="{GRID}"/>')
        svg.append(f'<text x="{x0 - 8}" y="{py(t) + 4:.1f}" font-size="11" fill="{INK2}" text-anchor="end">{t:g}×</text>')
    # the fair wait and y = 1
    svg.append(f'<line x1="{px(FAIR_MS):.1f}" y1="{y0}" x2="{px(FAIR_MS):.1f}" y2="{y0 + h}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{px(FAIR_MS) + 4:.1f}" y="{y0 + 12}" font-size="11" fill="{FAIR}">fair wait 125 ms</text>')
    svg.append(f'<line x1="{x0}" y1="{py(1):.1f}" x2="{x0 + w}" y2="{py(1):.1f}" stroke="{FAIR}" stroke-dasharray="4 3"/>')
    svg.append(f'<text x="{x0 + w - 4}" y="{py(1) + 34:.1f}" font-size="11" fill="{FAIR}" text-anchor="end">stock\'s fib_fine (y = 1)</text>')
    svg.append(f'<text x="{x0 + w / 2}" y="{y0 + h + 38}" font-size="12" fill="{INK2}" text-anchor="middle">request p99, ms (log): lower is fairer</text>')
    svg.append(f'<text x="{x0 - 46}" y="{y0 + h / 2}" font-size="12" fill="{INK2}" text-anchor="middle" '
               f'transform="rotate(-90 {x0 - 46} {y0 + h / 2})">fib_fine wall / stock (log): lower is cheaper</text>')
    for row in rows:
        label, a, b, c, d, src, kind = row[:7]
        dy = row[7] if len(row) > 7 else -6
        col = NOW if kind == "now" else EARLIER
        xm, ym = math.sqrt(a * b), math.sqrt(c * d)
        if b > a:
            svg.append(f'<line x1="{px(a):.1f}" y1="{py(ym):.1f}" x2="{px(b):.1f}" y2="{py(ym):.1f}" stroke="{col}" stroke-width="1.5"/>')
        if d > c:
            svg.append(f'<line x1="{px(xm):.1f}" y1="{py(c):.1f}" x2="{px(xm):.1f}" y2="{py(d):.1f}" stroke="{col}" stroke-width="1.5"/>')
        svg.append(f'<circle cx="{px(xm):.1f}" cy="{py(ym):.1f}" r="{5 if kind == "now" else 4}" fill="{col if kind == "now" else BG}" stroke="{col}" stroke-width="1.5"/>')
        svg.append(f'<text x="{px(xm) + 8:.1f}" y="{py(ym) + dy:.1f}" font-size="12" fill="{INK if kind == "now" else MUTED}">{html.escape(label)}</text>')


def main():
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="40" y="34" font-size="18" font-weight="700" fill="{INK}">Julia multiqueue order variants: fair to requests, and cheap for fork-join?</text>',
           f'<text x="40" y="56" font-size="12" fill="{INK2}">Starved cell: 500 clients, 2 ms tasks, 8 s, --threads=8,1. fib_fine: nested.jl pfib(42) cut at 12. '
           f'Filled: {html.escape(THIS_RUN)}; hollow: earlier runs on #618. Whiskers: [min-max].</text>']
    panel(svg, 110, 120, 460, 380, "Clients on :interactive (where HTTP.jl runs connections)", INTERACTIVE)
    panel(svg, 680, 120, 460, 380, "Clients on :default", DEFAULT)
    svg.append(f'<text x="40" y="{H - 58}" font-size="11" fill="{MUTED}">M and O: x with the marks (or O\'s rule) in the request program; y with nothing in fib_fine marked, '
               f'except the row "every fib_fine task marked".</text>')
    svg.append(f'<text x="40" y="{H - 40}" font-size="11" fill="{MUTED}">One side F: M-h marks only the handlers; O at 8,1 makes only the clients F '
               f'(the main task that spawns them runs on :interactive).</text>')
    svg.append(f'<text x="40" y="{H - 22}" font-size="11" fill="{MUTED}">{html.escape(B_TEXT)}. '
               f'Sources: the #618 comments named in fifo_tradeoff.py.</text>')
    svg.append('</svg>')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fifo-tradeoff.svg")
    with open(out, "w") as f:
        f.write("\n".join(svg) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
