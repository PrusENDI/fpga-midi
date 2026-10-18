import csv, json, math, statistics, sys
from pathlib import Path

SESSION = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    r"C:\weizijian\documents\gowin fpga\mgc3130_uart\calibration\session_0011_side"
)
OUT = SESSION / "analysis"
OUT.mkdir(parents=True, exist_ok=True)

def flag(v):
    return str(v).strip().lower() in ("1", "true", "yes")

def quantile(values, p):
    if not values:
        return None
    a = sorted(values)
    k = (len(a) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return a[lo]
    return a[lo] + (a[hi] - a[lo]) * (k - lo)

def median(values):
    return statistics.median(values) if values else None

def stdev(values):
    return statistics.stdev(values) if len(values) > 1 else 0.0

with open(SESSION / "samples.csv", newline="", encoding="utf-8") as f:
    rows = list(csv.DictReader(f))

for r in rows:
    for k in ("sequence", "timestamp", "gap_before", "x", "y", "z"):
        r[k] = int(r[k], 0)
    r["valid"] = (flag(r["report_valid"]) and flag(r["xyz_valid"])
                  and not flag(r["report_error"])
                  and not (r["x"] == 0x7FFF and r["y"] == 0x7FFF))

# The largest explicit sequence gap separates the principal sweep from the
# preceding residual capture in this session.
gap_indices = [i for i, r in enumerate(rows) if r["gap_before"] > 0]
gap_i = max(gap_indices, key=lambda i: rows[i]["gap_before"]) if gap_indices else -1
# Keep the first frame after the missing sequence range. Its ``gap_before``
# marks a break, but the frame itself is valid and belongs to the sweep.
main = rows[gap_i:] if gap_i >= 0 else rows
valid = [r for r in main if r["valid"]]
invalid = [r for r in main if not r["valid"]]
threshold = 4096

def candidate(r):
    return {"L": r["x"] <= threshold, "R": r["x"] >= 65535 - threshold,
            "B": r["y"] <= threshold, "T": r["y"] >= 65535 - threshold}

def label(r):
    c = candidate(r)
    s = "".join(k for k in ("L", "R", "B", "T") if c[k])
    return s or "."

# Build runs by classification. Invalid reports and explicit gaps are retained
# as breaks so an edge run cannot bridge missing data.
runs = []
cur = None
for r in main:
    lab = label(r) if r["valid"] else "INVALID"
    if cur is None or lab != cur["label"] or r["gap_before"] > 0:
        if cur:
            runs.append(cur)
        cur = {"label": lab, "start_sequence": r["sequence"],
               "end_sequence": r["sequence"], "frames": 0,
               "valid_frames": 0, "x": [], "y": []}
    cur["end_sequence"] = r["sequence"]
    cur["frames"] += 1
    if r["valid"]:
        cur["valid_frames"] += 1
        cur["x"].append(r["x"])
        cur["y"].append(r["y"])
if cur:
    runs.append(cur)

edge_runs = []
for run in runs:
    if run["label"] not in (".", "INVALID"):
        edge_runs.append({"label": run["label"], "frames": run["frames"],
                          "start_sequence": run["start_sequence"],
                          "end_sequence": run["end_sequence"],
                          "x_min": min(run["x"]), "x_max": max(run["x"]),
                          "y_min": min(run["y"]), "y_max": max(run["y"])})

with open(OUT / "edge_segments.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=["label", "frames", "start_sequence",
                                      "end_sequence", "x_min", "x_max",
                                      "y_min", "y_max"])
    w.writeheader()
    w.writerows(edge_runs)

edge_stats = {}
for name, edge, axis, other in (("x_left", "L", "x", "y"),
                                ("x_right", "R", "x", "y"),
                                ("y_bottom", "B", "y", "x"),
                                ("y_top", "T", "y", "x")):
    rs = [r for r in valid if candidate(r)[edge]]
    primary = [r[axis] for r in rs]
    secondary = [r[other] for r in rs]
    edge_stats[name] = {
        "threshold": threshold, "frames": len(rs),
        "primary_median": median(primary),
        "primary_p05": quantile(primary, .05), "primary_p95": quantile(primary, .95),
        "primary_min": min(primary) if primary else None,
        "primary_max": max(primary) if primary else None,
        "primary_std": stdev(primary),
        "other_median": median(secondary),
        "other_p05": quantile(secondary, .05), "other_p95": quantile(secondary, .95),
        "other_min": min(secondary) if secondary else None,
        "other_max": max(secondary) if secondary else None,
    }

order = []
for run in edge_runs:
    if run["frames"] < 20 or run["label"] not in ("L", "R", "B", "T"):
        continue
    if not order or order[-1]["edge"] != run["label"]:
        order.append({"edge": run["label"], "start_sequence": run["start_sequence"],
                      "end_sequence": run["end_sequence"], "frames": run["frames"]})
    else:
        order[-1]["end_sequence"] = run["end_sequence"]
        order[-1]["frames"] += run["frames"]

sampled = [r for i, r in enumerate(valid) if i % 4 == 0 or i in (0, len(valid) - 1)]
with open(OUT / "trajectory_sample.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["sequence", "x", "y", "z", "label", "gap_before"])
    for r in sampled:
        w.writerow([r["sequence"], r["x"], r["y"], r["z"], label(r), r["gap_before"]])

# Render the post-gap path as an SVG, with y increasing upward in the figure.
W = H = 860
pad = 70
sx = lambda v: pad + (v / 65535) * (W - 2 * pad)
sy = lambda v: H - pad - (v / 65535) * (H - 2 * pad)
colors = {"L": "#2563eb", "R": "#dc2626", "B": "#16a34a", "T": "#9333ea", ".": "#9ca3af"}
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       '<rect width="100%" height="100%" fill="white"/>',
       f'<text x="{pad}" y="28" font-family="sans-serif" font-size="18" font-weight="bold">session_0011_side trajectory (post-gap)</text>',
       f'<rect x="{pad}" y="{pad}" width="{W-2*pad}" height="{H-2*pad}" fill="#fafafa" stroke="#6b7280"/>']
for v in (0, 16384, 32768, 49152, 65535):
    x, y = sx(v), sy(v)
    svg += [f'<line x1="{x:.1f}" y1="{pad}" x2="{x:.1f}" y2="{H-pad}" stroke="#e5e7eb"/>',
            f'<line x1="{pad}" y1="{y:.1f}" x2="{W-pad}" y2="{y:.1f}" stroke="#e5e7eb"/>',
            f'<text x="{x:.1f}" y="{H-pad+22}" text-anchor="middle" font-family="sans-serif" font-size="11">{v}</text>',
            f'<text x="{pad-8}" y="{y+4:.1f}" text-anchor="end" font-family="sans-serif" font-size="11">{v}</text>']
last = None
for r in sampled:
    lab = label(r)
    c = colors.get(lab[0] if lab in ("L", "R", "B", "T") else ".")
    x, y = sx(r["x"]), sy(r["y"])
    if last:
        svg.append(f'<line x1="{last[0]:.1f}" y1="{last[1]:.1f}" x2="{x:.1f}" y2="{y:.1f}" stroke="{c}" stroke-width="1.5" opacity="0.72"/>')
    svg.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2.2" fill="{c}"/>')
    last = (x, y)
for i, (k, c, text) in enumerate((("B", "#16a34a", "bottom y"), ("R", "#dc2626", "right x"),
                                    ("T", "#9333ea", "top y"), ("L", "#2563eb", "left x"),
                                    (".", "#9ca3af", "transition/interior"))):
    x = pad + i * 150
    svg.append(f'<circle cx="{x}" cy="{H-24}" r="5" fill="{c}"/><text x="{x+9}" y="{H-20}" font-family="sans-serif" font-size="11">{text}</text>')
svg.append('</svg>')
(OUT / "trajectory.svg").write_text("\n".join(svg), encoding="utf-8")

result = {
    "session": SESSION.name, "threshold": threshold,
    "frames": len(rows), "valid_frames_all": sum(r["valid"] for r in rows),
    "invalid_frames_all": sum(not r["valid"] for r in rows),
    "largest_gap_before": rows[gap_i]["gap_before"] if gap_i >= 0 else 0,
    "largest_gap_before_sequence": rows[gap_i]["sequence"] if gap_i >= 0 else None,
    "principal_track_start_sequence": main[0]["sequence"] if main else None,
    "principal_track_end_sequence": main[-1]["sequence"] if main else None,
    "principal_track_frames": len(main), "principal_track_valid_frames": len(valid),
    "principal_track_invalid_frames": len(invalid),
    "principal_track_invalid_sequences": [r["sequence"] for r in invalid],
    "x_range": [min(r["x"] for r in valid), max(r["x"] for r in valid)],
    "y_range": [min(r["y"] for r in valid), max(r["y"] for r in valid)],
    "z_range": [min(r["z"] for r in valid), max(r["z"] for r in valid)],
    "edge_stats": edge_stats, "significant_single_edge_order": order,
    "edge_runs_count": len(edge_runs),
    "outputs": ["edge_segments.csv", "trajectory_sample.csv", "trajectory.svg"],
}
(OUT / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
