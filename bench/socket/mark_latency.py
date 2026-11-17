"""#618: the mark in a real server, cell 1's figure. The server is bench/socket/server.jl behind
HTTP.jl, driven by the go/fairness client (500 keep-alive connections, 3 interleaved rounds of 8 s,
servers on 8 CPUs, the client on 4) on /aggregate?n=100000&op=groupby, whose handler computes for
1.5 ms without yielding. One panel per layout: --threads=8,1 (HTTP.jl's connection tasks on the
one :interactive thread) and --threads=8,0 (they fall back to :default, beside the requests).

x is the percentile, y the latency in ms (log). The point is the median of the 3 rounds and the
whisker [min-max]. The servers: go (net/http, the reference), bare_spawn (a request per
`Threads.@spawn`, the variant file never included: "A", stock's scheduler), bare_pool (8 worker
tasks fed by a channel, under VARIANT=A), and bare_marked under M-l-r2 and M-g-r2 (the request
task made by `spawn_marked`, the only marked task in the process). The fair wait (connections over
throughput) and twice it (the p99 limit of the pass criterion) are drawn in.

The single max near 1.1 s in some rounds is a connection's first request: a connect the listen
backlog (128) dropped, retried by the client's kernel a second later.

Every number is a literal from this run's fairness.sh tables (bench/results/618-mark/cell1-8_1.log
and cell1-8_0.log), reported on #618. Plain Python, no dependencies; writes mark-latency.svg beside
this file.

    python3 bench/socket/mark_latency.py
"""
import html, math, os

PCTS = ["p50", "p90", "p99", "p99.9", "max"]
# server: [(median, min, max) per percentile, in PCTS order], ms
L81 = {
    "go": [(95.698, 95.673, 95.742), (134.163, 133.819, 134.563), (161.84, 161.45, 165.341),
           (206.767, 193.092, 315.082), (291.561, 251.494, 392.601)],
    "bare_spawn (A)": [(13.337, 13.299, 13.467), (101.572, 94.706, 105.228), (2301.74, 2129.15, 2312.93),
                       (7759.62, 6259.36, 8071.87), (8098.86, 8097.71, 8104.05)],
    "bare_pool": [(100.338, 100.208, 100.552), (101.71, 101.351, 101.982), (103.315, 103.124, 104.755),
                  (107.889, 106.029, 112.31), (150.527, 133.672, 1160.86)],
    "bare_marked, M-l-r2": [(103.496, 103.182, 103.535), (110.261, 109.932, 110.758), (118.241, 118.145, 123.105),
                            (129.072, 125.372, 135.921), (161.324, 136.194, 1115.29)],
    "bare_marked, M-g-r2": [(103.835, 102.726, 104.211), (110.402, 109.906, 110.573), (118.234, 117.826, 118.762),
                            (126.099, 125.632, 1120.45), (146.362, 133.47, 1140.56)],
}
L80 = {
    "go": [(95.698, 95.571, 95.761), (134.155, 134.023, 134.957), (161.081, 160.599, 164.328),
           (206.479, 170.267, 350.189), (288.933, 241.669, 432.543)],
    "bare_spawn (A)": [(10.901, 10.892, 10.914), (135.313, 132.137, 137.501), (1892.17, 1636.93, 1899.97),
                       (6598.2, 5583.1, 7766.97), (8092.01, 8079.94, 8095.57)],
    "bare_pool": [(15.691, 15.34, 16.447), (106.825, 105.06, 107.692), (2294.4, 2003.01, 2516.77),
                  (7199.97, 5984.14, 7781.56), (8093.01, 8072.5, 8095.19)],
    "bare_marked, M-l-r2": [(99.866, 99.824, 100.342), (106.372, 106.243, 107.448), (113.66, 113.561, 123.303),
                            (121.514, 119.26, 132.96), (133.862, 129.081, 147.824)],
    "bare_marked, M-g-r2": [(8.232, 8.082, 8.483), (79.466, 75.825, 89.862), (2195.59, 1977.56, 2880.14),
                            (7451.43, 6250.56, 7578.1), (8087.0, 7108.61, 8098.41)],
}
FAIR_81, FAIR_80 = 103.0, 98.2       # bare_spawn (A): 500 connections over its throughput, ms

W, H = 1240, 660
BG, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1"
FAIR, LIMIT = "#2e8b57", "#9a3fb5"
COLORS = {"go": "#52514e", "bare_spawn (A)": "#2a78d6", "bare_pool": "#2e8b57",
          "bare_marked, M-l-r2": "#9a3fb5", "bare_marked, M-g-r2": "#c0651a"}
DX = {"go": -12, "bare_spawn (A)": -6, "bare_pool": 0, "bare_marked, M-l-r2": 6, "bare_marked, M-g-r2": 12}
Y_LO, Y_HI = 5.0, 12000.0            # log
Y_TICKS = [10, 30, 100, 300, 1000, 3000, 10000]


def panel(svg, x0, y0, w, h, title, data, fair):
    step = w / len(PCTS)
    px = lambda i: x0 + step * (i + 0.5)
    py = lambda v: y0 + h - h * (math.log(v) - math.log(Y_LO)) / (math.log(Y_HI) - math.log(Y_LO))
    svg.append(f'<text x="{x0}" y="{y0 - 14}" font-size="15" font-weight="600" fill="{INK}">{html.escape(title)}</text>')
    for t in Y_TICKS:
        svg.append(f'<line x1="{x0}" y1="{py(t):.1f}" x2="{x0 + w}" y2="{py(t):.1f}" stroke="{GRID}"/>')
        svg.append(f'<text x="{x0 - 8}" y="{py(t) + 4:.1f}" font-size="11" fill="{INK2}" text-anchor="end">{t:,}</text>')
    for i, p in enumerate(PCTS):
        svg.append(f'<text x="{px(i):.1f}" y="{y0 + h + 18}" font-size="12" fill="{INK2}" text-anchor="middle">{p}</text>')
    for v, col, text in ((fair, FAIR, f"fair wait {fair:g} ms"), (2 * fair, LIMIT, f"2× fair wait: the p99 limit")):
        svg.append(f'<line x1="{x0}" y1="{py(v):.1f}" x2="{x0 + w}" y2="{py(v):.1f}" stroke="{col}" stroke-dasharray="4 3"/>')
        svg.append(f'<text x="{x0 + 4}" y="{py(v) - 4:.1f}" font-size="11" fill="{col}">{text}</text>')
    svg.append(f'<text x="{x0 - 50}" y="{y0 + h / 2}" font-size="12" fill="{INK2}" text-anchor="middle" '
               f'transform="rotate(-90 {x0 - 50} {y0 + h / 2})">latency, ms (log)</text>')
    for name, pts in data.items():
        col, dx = COLORS[name], DX[name]
        d = " ".join(f'{"M" if i == 0 else "L"} {px(i) + dx:.1f} {py(m):.1f}' for i, (m, _, _) in enumerate(pts))
        svg.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="1.6"/>')
        for i, (m, lo, hi) in enumerate(pts):
            if hi > lo:
                svg.append(f'<line x1="{px(i) + dx:.1f}" y1="{py(lo):.1f}" x2="{px(i) + dx:.1f}" y2="{py(hi):.1f}" stroke="{col}" stroke-width="1.2"/>')
            svg.append(f'<circle cx="{px(i) + dx:.1f}" cy="{py(m):.1f}" r="3.5" fill="{col}"/>')


def main():
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="40" y="34" font-size="18" font-weight="700" fill="{INK}">One mark on the request task, through HTTP.jl: /aggregate at c = 500</text>',
           f'<text x="40" y="56" font-size="12" fill="{INK2}">Julia 1.13.4, HTTP.jl 2.15.0, go/fairness client, 500 keep-alive connections, 1.5 ms handlers that do not yield, '
           f'3 interleaved rounds of 8 s. Medians, whiskers [min-max].</text>']
    lx = 40
    for name, col in COLORS.items():
        svg.append(f'<line x1="{lx}" y1="80" x2="{lx + 22}" y2="80" stroke="{col}" stroke-width="2"/>'
                   f'<circle cx="{lx + 11}" cy="80" r="3.5" fill="{col}"/>'
                   f'<text x="{lx + 28}" y="84" font-size="12" fill="{INK}">{html.escape(name)}</text>')
        lx += 40 + 7.2 * len(name)
    panel(svg, 110, 126, 500, 420, "--threads=8,1: connection tasks on :interactive", L81, FAIR_81)
    panel(svg, 720, 126, 500, 420, "--threads=8,0: connection tasks on :default", L80, FAIR_80)
    svg.append(f'<text x="40" y="{H - 58}" font-size="11" fill="{MUTED}">bare_spawn (A): the variant file never included (stock). bare_pool: 8 workers fed by a channel. bare_marked: '
               f'the request task made by spawn_marked, the only marked task; -l serves</text>')
    svg.append(f'<text x="40" y="{H - 40}" font-size="11" fill="{MUTED}">unmarked work first, -g shares time between the request side and unmarked work (w 1/2). '
               f'At 8,0 the slow requests under -g and bare_pool wait before their connection task runs.</text>')
    svg.append(f'<text x="40" y="{H - 22}" font-size="11" fill="{MUTED}">Max near 1.1 s: a first request whose connect the listen backlog dropped. '
               f'Source: bench/socket/mark_latency.py; #618.</text>')
    svg.append('</svg>')
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mark-latency.svg")
    with open(out, "w") as f:
        f.write("\n".join(svg) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    main()
