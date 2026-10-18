import csv, json, math, statistics, sys
from pathlib import Path

SESSION = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    r"C:\weizijian\documents\gowin fpga\mgc3130_uart\calibration\session_0014_boardside"
)
OUT = SESSION / "analysis"
OUT.mkdir(parents=True, exist_ok=True)
THRESHOLD = 4096

def flag(v): return str(v).strip().lower() in ("1", "true", "yes")
def med(v): return statistics.median(v) if v else None
def q(v, p):
    if not v: return None
    a=sorted(v); k=(len(a)-1)*p; lo,hi=math.floor(k),math.ceil(k)
    return a[lo] if lo==hi else a[lo]+(a[hi]-a[lo])*(k-lo)
def label(r):
    s=[]
    if r["x"] <= THRESHOLD: s.append("L")
    if r["x"] >= 65535-THRESHOLD: s.append("R")
    if r["y"] <= THRESHOLD: s.append("B")
    if r["y"] >= 65535-THRESHOLD: s.append("T")
    return "".join(s) or "."

with open(SESSION/"samples.csv", newline="", encoding="utf-8") as f:
    rows=list(csv.DictReader(f))
for r in rows:
    for k in ("sequence","timestamp","gap_before","x","y","z"): r[k]=int(r[k],0)
    r["valid"]=(flag(r["report_valid"]) and flag(r["xyz_valid"]) and not flag(r["report_error"])
                 and not (r["x"]==0x7fff and r["y"]==0x7fff))

# Split at explicit sequence gaps. Do not silently discard either physical sweep.
blocks=[]; cur=[]
for r in rows:
    if cur and r["gap_before"]>0:
        blocks.append(cur); cur=[]
    cur.append(r)
if cur: blocks.append(cur)

def summarize_block(block):
    v=[r for r in block if r["valid"]]
    edge={}
    for name,axis,edgekey in (("x_left","x","L"),("x_right","x","R"),("y_bottom","y","B"),("y_top","y","T")):
        a=[r[axis] for r in v if edgekey in label(r)]
        other=[r["y"] if axis=="x" else r["x"] for r in v if edgekey in label(r)]
        edge[name]={"frames":len(a),"primary_median":med(a),"primary_p05":q(a,.05),"primary_p95":q(a,.95),
                    "primary_min":min(a) if a else None,"primary_max":max(a) if a else None,
                    "other_median":med(other),"other_min":min(other) if other else None,"other_max":max(other) if other else None}
    # Runs preserve transitions and invalid frames as breaks.
    runs=[]; run=None
    for r in block:
        lab=label(r) if r["valid"] else "INVALID"
        if run is None or lab!=run["label"] or r["gap_before"]>0:
            if run: runs.append(run)
            run={"label":lab,"start_sequence":r["sequence"],"end_sequence":r["sequence"],"frames":0}
        run["end_sequence"]=r["sequence"]; run["frames"]+=1
    if run: runs.append(run)
    order=[{"edge":a["label"],"start_sequence":a["start_sequence"],"end_sequence":a["end_sequence"],"frames":a["frames"]}
           for a in runs if a["label"] in ("L","R","B","T") and a["frames"]>=20]
    return {"start_sequence":block[0]["sequence"],"end_sequence":block[-1]["sequence"],"frames":len(block),
            "valid_frames":len(v),"invalid_sequences":[r["sequence"] for r in block if not r["valid"]],
            "x_range":[min(r["x"] for r in v),max(r["x"] for r in v)],"y_range":[min(r["y"] for r in v),max(r["y"] for r in v)],
            "z_range":[min(r["z"] for r in v),max(r["z"] for r in v)],"edge_stats":edge,"edge_order":order,"runs":runs}

summaries=[summarize_block(b) for b in blocks]
valid=[r for r in rows if r["valid"]]

with open(OUT/"edge_segments.csv","w",newline="",encoding="utf-8") as f:
    w=csv.writer(f); w.writerow(["block","label","frames","start_sequence","end_sequence","x_min","x_max","y_min","y_max"])
    for bi,b in enumerate(blocks,1):
        run=None
        for r in b:
            lab=label(r) if r["valid"] else "INVALID"
            if run is None or lab!=run["label"]:
                if run and run["label"] not in (".","INVALID"):
                    w.writerow([bi,run["label"],run["frames"],run["start_sequence"],run["end_sequence"],min(run["x"]),max(run["x"]),min(run["y"]),max(run["y"])])
                run={"label":lab,"frames":0,"start_sequence":r["sequence"],"end_sequence":r["sequence"],"x":[] ,"y":[]}
            run["frames"]+=1; run["end_sequence"]=r["sequence"]
            if r["valid"]: run["x"].append(r["x"]);run["y"].append(r["y"])
        if run and run["label"] not in (".","INVALID") and run["x"]:
            w.writerow([bi,run["label"],run["frames"],run["start_sequence"],run["end_sequence"],min(run["x"]),max(run["x"]),min(run["y"]),max(run["y"])])

with open(OUT/"trajectory_sample.csv","w",newline="",encoding="utf-8") as f:
    w=csv.writer(f); w.writerow(["block","sequence","x","y","z","label","gap_before"])
    for bi,b in enumerate(blocks,1):
        v=[r for r in b if r["valid"]]
        for i,r in enumerate(v):
            if i%4==0 or i in (0,len(v)-1): w.writerow([bi,r["sequence"],r["x"],r["y"],r["z"],label(r),r["gap_before"]])

result={"session":SESSION.name,"threshold":THRESHOLD,"frames":len(rows),"valid_frames":len(valid),
        "invalid_frames":sum(not r["valid"] for r in rows),"sequence_gap_events":[{"sequence":r["sequence"],"gap_before":r["gap_before"]} for r in rows if r["gap_before"]>0],
        "overall_range":{"x":[min(r["x"] for r in valid),max(r["x"] for r in valid)],"y":[min(r["y"] for r in valid),max(r["y"] for r in valid)],"z":[min(r["z"] for r in valid),max(r["z"] for r in valid)]},
        "blocks":summaries,
        "interpretation":{"x_left_observed":min(r["x"] for r in valid),"y_bottom_observed":min(r["y"] for r in valid),
                           "left_edge_reached":any(r["x"]<=THRESHOLD for r in valid),"bottom_edge_reached":any(r["y"]<=THRESHOLD for r in valid),
                           "note":"Physical board-side sweep does not provide a left-edge X calibration sample; most samples concentrate on right/top edges."},
        "outputs":["edge_segments.csv","trajectory_sample.csv"]}
(OUT/"analysis.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
print(json.dumps(result,ensure_ascii=False,indent=2))
