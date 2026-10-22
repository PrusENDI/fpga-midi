"""Tkinter desktop UI for the six-track MGC3130 Synthwave verifier."""

from __future__ import annotations

import csv
import json
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, TRACKS, LeadStartGate, _clamp,
                            compile_loop, load_jsonl_records, render_loop,
                            write_event_table)  # noqa: E402


def _project_point(row: dict, width: int, height: int,
                   x_span: float = 65535.0, y_span: float = 65535.0) -> tuple:
    left, right = 28.0, max(29.0, width - 28.0)
    top, bottom = 28.0, max(29.0, height - 28.0)
    px = int(round(left + float(row.get("x", 0)) / x_span * (right - left)))
    py = int(round(bottom - float(row.get("y", 0)) / y_span * (bottom - top)))
    return (px, py)


def _thin_path(samples: List[dict], width: int, height: int,
               x_span: float = 65535.0, y_span: float = 65535.0) -> List[tuple]:
    """Project the trajectory to canvas pixels and drop repeated pixels.

    Drawing every sample makes the redraw cost grow with the capture
    length; stride sampling instead aliases the shape, which is what makes
    fine drawing impossible late in a take. Mapping to integer pixels and
    dropping points that land on the same pixel keeps the drawn shape exact
    at display resolution and bounds the polyline by the canvas area, not by
    the number of captured frames.
    """
    pixels: List[tuple] = []
    previous: tuple | None = None
    for row in samples:
        point = _project_point(row, width, height, x_span, y_span)
        if point != previous:
            pixels.append(point)
            previous = point
    return pixels


class _PixelPathCache:
    """Incremental front end for :func:`_thin_path`.

    The capture list only ever grows during a take, so re-projecting all of
    it on every redraw is wasted work: at 200 Hz a 60 s take is 12000 points
    and the scan alone dominates the frame budget. Cache the projected pixels
    and append only the samples added since the previous draw.
    """

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._source: List[dict] | None = None
        self._count = 0
        self._size: tuple | None = None
        self._pixels: List[tuple] = []

    def points(self, samples: List[dict], width: int, height: int,
               x_span: float = 65535.0, y_span: float = 65535.0) -> List[tuple]:
        size = (width, height)
        if (self._source is not samples or self._size != size
                or len(samples) < self._count):
            self._source = samples
            self._count = 0
            self._size = size
            self._pixels = []
        pending = samples[self._count:]
        for row in pending:
            point = _project_point(row, width, height, x_span, y_span)
            if not self._pixels or point != self._pixels[-1]:
                self._pixels.append(point)
        self._count = len(samples)
        return self._pixels


DIAG_FIELDS = ("wall_ms", "elapsed_s", "state", "rate_hz", "queue", "draw_ms",
               "frames", "preview_points", "drawn_points", "canvas_w", "canvas_h")


def _append_diag_row(path: Path, row: dict) -> None:
    """Append one diagnostics row, writing the header on first use.

    Opening per row keeps the file valid even if the UI is killed, and one
    write per second costs nothing next to a canvas redraw.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=DIAG_FIELDS, extrasaction="ignore")
        if new_file:
            writer.writeheader()
        writer.writerow(row)


class SynthwaveUI(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("MGC3130 Melodic Synthwave — Capture & Loop")
        self.geometry("1200x780")
        self.minsize(980, 640)
        self.configure(bg="#10131b")
        self.selected_track = tk.StringVar(value="lead")
        self.status = tk.StringVar(value="IDLE — choose a track, then Record")
        self.bpm = tk.IntVar(value=STYLE.bpm)
        self.swing = tk.DoubleVar(value=STYLE.swing * 100.0)
        self.mapping_mode = tk.StringVar(value="workspace")
        self.records: Dict[str, List[dict]] = {track: [] for track in TRACKS}
        self.lead_samples: List[dict] = []
        self.current_capture: List[dict] = []
        self.lead_preview_capture: List[dict] = []
        self.lead_start_gate = LeadStartGate()
        self.event_table: dict | None = None
        self.receiver: subprocess.Popen[str] | None = None
        self.receiver_thread: threading.Thread | None = None
        self.inbox: queue.Queue[dict] = queue.Queue()
        self.recording = False
        self.playing = False
        # Redraw budget. The sensor streams at 200 Hz, but the trajectory view
        # runs at ~60 fps; drawing more often than that only adds latency to
        # the pointer.
        self.draw_interval_s = 0.016
        self._last_draw = 0.0
        self._draw_cost_ms = 0.0
        self.diag = tk.StringVar(value="idle")
        self._diag_window = (time.monotonic(), 0)
        self._path_cache = _PixelPathCache()
        # Persist the once-per-second readout so a slow take can be analysed
        # offline instead of being read off the screen.
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.session_started = time.monotonic()
        self.diag_path = ROOT / "pc_receiver" / "diagnostics" / f"ui_{stamp}.csv"
        self.capture_path: Path | None = None
        self._drawn_points = 0
        self._build_style()
        self._build_ui()
        self.after(16, self._poll_inbox)

    def _build_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background="#171b26")
        style.configure("TLabel", background="#171b26", foreground="#e9edf5")
        style.configure("Title.TLabel", background="#10131b", foreground="#f3c969", font=("Segoe UI", 18, "bold"))
        style.configure("Muted.TLabel", background="#171b26", foreground="#9da7bb")
        style.configure("TButton", padding=(10, 5))
        style.configure("Track.TButton", padding=(8, 12), font=("Segoe UI", 10, "bold"))

    def _build_ui(self) -> None:
        ttk.Label(self, text="MGC3130  ·  MELODIC SYNTHWAVE", style="Title.TLabel").pack(anchor="w", padx=18, pady=(14, 4))
        ttk.Label(self, text="CAPTURE & LOOP  |  six tracks  |  Lead trajectory + Touch/Tap performance", style="Muted.TLabel").pack(anchor="w", padx=20, pady=(0, 12))
        main = ttk.Frame(self)
        main.pack(fill="both", expand=True, padx=14, pady=6)
        left = ttk.Frame(main)
        left.pack(side="left", fill="y", padx=(0, 10))
        center = ttk.Frame(main)
        center.pack(side="left", fill="both", expand=True)
        right = ttk.Frame(main)
        right.pack(side="right", fill="y", padx=(10, 0))

        ttk.Label(left, text="TRACKS", style="Muted.TLabel").pack(anchor="w", pady=(0, 6))
        for track in TRACKS:
            label = {"lead": "LEAD  ·  3D curve", "bass": "BASS  ·  touch", "pad": "PAD  ·  touch", "arp": "ARP  ·  touch", "drums": "DRUMS  ·  tap", "texture_fx": "TEXTURE / FX"}[track]
            ttk.Radiobutton(left, text=label, value=track, variable=self.selected_track, command=self._track_changed).pack(fill="x", pady=2)
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Button(left, text="●  RECORD", style="Track.TButton", command=self.start_record).pack(fill="x", pady=3)
        ttk.Button(left, text="■  STOP", command=self.stop_record).pack(fill="x", pady=3)
        ttk.Button(left, text="COMPILE LOOP", command=self.compile).pack(fill="x", pady=3)
        ttk.Button(left, text="▶  PLAY PREVIEW", command=self.play_preview).pack(fill="x", pady=3)
        ttk.Button(left, text="CLEAR TRACK", command=self.clear_track).pack(fill="x", pady=3)
        ttk.Button(left, text="CLEAR ALL", command=self.clear_all).pack(fill="x", pady=3)
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Button(left, text="Import JSONL…", command=self.import_jsonl).pack(fill="x", pady=3)
        ttk.Button(left, text="Export Event JSON…", command=self.export_events).pack(fill="x", pady=3)
        ttk.Button(left, text="Render WAV…", command=self.render_wav).pack(fill="x", pady=3)
        ttk.Separator(left).pack(fill="x", pady=12)
        ttk.Label(left, text="LEAD SPACE", style="Muted.TLabel").pack(anchor="w")
        ttk.Radiobutton(left, text="Workspace (fixed)", value="workspace", variable=self.mapping_mode).pack(anchor="w")
        ttk.Radiobutton(left, text="Gesture-Aligned", value="gesture_aligned", variable=self.mapping_mode).pack(anchor="w")

        self.canvas = tk.Canvas(center, bg="#0c1018", highlightthickness=1, highlightbackground="#2d3548")
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Configure>", lambda _event: self._draw_canvas())
        ttk.Label(center, textvariable=self.status, anchor="w").pack(fill="x", pady=(8, 2))
        ttk.Label(center, textvariable=self.diag, style="Muted.TLabel", anchor="w").pack(fill="x")
        self.progress = ttk.Progressbar(center, mode="determinate", maximum=128)
        self.progress.pack(fill="x")
        columns = ("track", "tick", "note", "duration", "velocity", "source", "landmarks", "delta", "color")
        self.tree = ttk.Treeview(center, columns=columns, show="headings", height=8)
        for column in columns:
            self.tree.heading(column, text=column.upper())
            self.tree.column(column, width=88 if column not in ("landmarks", "delta") else 118, anchor="center")
        self.tree.pack(fill="x", pady=(10, 0))

        ttk.Label(right, text="SYNTHWAVE STYLE", style="Muted.TLabel").pack(anchor="w", pady=(0, 8))
        self._value_row(right, "BPM", self.bpm, 90, 120)
        self._value_row(right, "Swing %", self.swing, 50, 56)
        ttk.Label(right, text="Am  ·  F  ·  C  ·  G", font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=(16, 2))
        ttk.Label(right, text="8 bars  ·  4/4  ·  minor pentatonic", style="Muted.TLabel").pack(anchor="w")
        ttk.Label(right, text="PitchSpace  ·  A minor pentatonic  ·  G3–C5", style="Muted.TLabel").pack(anchor="w", pady=(4, 0))
        ttk.Separator(right).pack(fill="x", pady=16)
        ttk.Label(right, text="PLAY PERFORMANCE", style="Muted.TLabel").pack(anchor="w", pady=(0, 8))
        self.mod_x = tk.DoubleVar(value=0.0)
        self.mod_y = tk.DoubleVar(value=0.0)
        self.mod_z = tk.DoubleVar(value=0.0)
        self._slider(right, "X  Timbre / Morph", self.mod_x)
        self._slider(right, "Y  Pitch / Voicing", self.mod_y)
        self._slider(right, "Z  Energy / FX", self.mod_z)
        ttk.Label(right, text="PLAY never adds NOTE_ON.\nIt modulates the active loop only.", style="Muted.TLabel", justify="left").pack(anchor="w", pady=16)
        self.log = tk.Text(right, width=30, height=12, bg="#0c1018", fg="#b9c4d9", relief="flat", state="disabled")
        self.log.pack(fill="both", expand=True)

    def _value_row(self, parent: ttk.Frame, label: str, variable: tk.Variable, low: int, high: int) -> None:
        ttk.Label(parent, text=label).pack(anchor="w", pady=(5, 0))
        ttk.Spinbox(parent, from_=low, to=high, textvariable=variable, width=10).pack(anchor="w")

    def _slider(self, parent: ttk.Frame, label: str, variable: tk.DoubleVar) -> None:
        ttk.Label(parent, text=label).pack(anchor="w", pady=(4, 0))
        ttk.Scale(parent, from_=-1.0, to=1.0, variable=variable, orient="horizontal", length=180).pack(anchor="w")

    def _track_changed(self) -> None:
        if not self.recording:
            self.status.set(f"READY — selected {self.selected_track.get()}")
            self._log(f"selected track: {self.selected_track.get()}")

    def _log(self, message: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", time.strftime("%H:%M:%S ") + message + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start_record(self) -> None:
        if self.recording:
            return
        self.current_capture = []
        self.lead_preview_capture = []
        if self.selected_track.get() == "lead":
            self.lead_start_gate = LeadStartGate()
        self.recording = True
        track = self.selected_track.get()
        prompt = "move to the left edge, then move right" if track == "lead" else "stop when the take is complete"
        self.status.set(f"RECORDING — {track}; {prompt}")
        self._log(f"recording {track}")
        self._start_receiver()

    def _prepare_capture_path(self) -> Path | None:
        """Return a raw-capture path the receiver can create, or None.

        The receiver exits if it cannot open --output, so probe first and
        fall back to stdout-only rather than losing the take.
        """
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = ROOT / "pc_receiver" / "captures" / f"{self.selected_track.get()}_{stamp}.jsonl"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch(exist_ok=True)
        except OSError:
            return None
        return path

    def _start_receiver(self) -> None:
        if self.receiver is not None:
            return
        receiver = Path(__file__).with_name("Static-Release") / "mgc3130_receiver.exe"
        if not receiver.exists():
            self.status.set("RECORDING — receiver executable not found; import JSONL instead")
            self._log(f"missing receiver: {receiver}")
            return
        command = [str(receiver), "--format", "jsonl"]
        self.capture_path = self._prepare_capture_path()
        if self.capture_path is not None:
            command += ["--output", str(self.capture_path)]
        self._log(f"capture → {self.capture_path}" if self.capture_path else "capture → stdout only")
        self._log(f"diagnostics → {self.diag_path}")
        try:
            self.receiver = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        except OSError as error:
            self._log(f"receiver failed: {error}")
            self.receiver = None
            return
        def pump() -> None:
            assert self.receiver is not None and self.receiver.stdout is not None
            for line in self.receiver.stdout:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    self.inbox.put(record)
        self.receiver_thread = threading.Thread(target=pump, daemon=True)
        self.receiver_thread.start()

    def _poll_inbox(self) -> None:
        latest: dict | None = None
        while True:
            try:
                record = self.inbox.get_nowait()
            except queue.Empty:
                break
            if record.get("type") != "position":
                continue
            self.current_capture.append(record)
            latest = record
            if self.selected_track.get() == "lead":
                self.lead_preview_capture.extend(self.lead_start_gate.push(record))
        now = time.monotonic()
        if latest is not None:
            if self.selected_track.get() == "lead" and not self.lead_preview_capture:
                self.status.set("WAITING — Lead must start at the left edge and move right")
            self.progress["value"] = len(self.current_capture) % 128
            if now - self._last_draw >= self.draw_interval_s:
                self._last_draw = now
                started = time.perf_counter()
                self._draw_canvas(self.lead_preview_capture if self.selected_track.get() == "lead" else None)
                self._draw_cost_ms = (time.perf_counter() - started) * 1000.0
        # Logged even when nothing arrives: "0 Hz" is the answer when the
        # device or the session is silent.
        self._update_diag(now)
        self.after(16, self._poll_inbox)

    def _update_diag(self, now: float) -> None:
        since, frames = self._diag_window
        if now - since < 1.0:
            return
        rate = (len(self.current_capture) - frames) / (now - since)
        queue_depth = self.inbox.qsize()
        self.diag.set(f"{rate:5.1f} Hz  ·  queue {queue_depth:3d}  ·  "
                      f"draw {self._draw_cost_ms:4.2f} ms  ·  {len(self.current_capture)} frames")
        try:
            _append_diag_row(self.diag_path, {
                "wall_ms": int(time.time() * 1000),
                "elapsed_s": round(now - self.session_started, 3),
                "state": "recording" if self.recording else "idle",
                "rate_hz": round(rate, 2),
                "queue": queue_depth,
                "draw_ms": round(self._draw_cost_ms, 3),
                "frames": len(self.current_capture),
                "preview_points": len(self.lead_preview_capture),
                "drawn_points": self._drawn_points,
                "canvas_w": self.canvas.winfo_width(),
                "canvas_h": self.canvas.winfo_height(),
            })
        except OSError:
            pass
        self._diag_window = (now, len(self.current_capture))

    def stop_record(self) -> None:
        if not self.recording:
            return
        track = self.selected_track.get()
        self.recording = False
        if self.receiver is not None:
            self.receiver.terminate()
            self.receiver = None
        if track == "lead":
            self.lead_samples.extend(self.current_capture)
        else:
            self.records[track].extend(self.current_capture)
        self.status.set(f"CAPTURED — {track}: {len(self.current_capture)} reports")
        if track == "lead":
            accepted = sum(1 for row in self.lead_preview_capture if row.get("start_gate_state") == "accepted")
            self._log(f"captured {len(self.current_capture)} reports for {track}; {accepted} passed left-edge start gate")
        else:
            self._log(f"captured {len(self.current_capture)} reports for {track}")

    def compile(self) -> None:
        if self.recording:
            self.stop_record()
        if len(self.lead_samples) < 2:
            messagebox.showwarning("Lead required", "Record or import at least two Lead position reports first.")
            return
        self.event_table = compile_loop(self.lead_samples, self.records, mode=self.mapping_mode.get())
        self._refresh_events()
        diagnostics = self.event_table.get("diagnostics", {})
        self.status.set(f"COMPILED — {diagnostics.get('status', 'ok')} · {len(self.event_table['tracks']['lead'])} Lead events")
        self._log(json.dumps(self.event_table["diagnostics"], ensure_ascii=False))

    def _refresh_events(self) -> None:
        for item in self.tree.get_children():
            self.tree.delete(item)
        if not self.event_table:
            return
        for event in self.event_table["events"]:
            landmarks = ",".join(event.get("source_landmarks", []))
            self.tree.insert("", "end", values=(event.get("track"), event.get("tick"), event.get("note", "—"), event.get("duration", "—"), event.get("velocity", "—"), event.get("source"), landmarks or "—", event.get("quantization_delta", "—"), event.get("color_layer", "—")))

    def play_preview(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        output = ROOT / "pc_receiver" / "synthwave_preview.wav"
        render_loop(self.event_table, output)
        self.status.set(f"RENDERED — {output.name}")
        self._log(f"WAV written: {output}")
        try:
            import os
            os.startfile(str(output))
        except (AttributeError, OSError):
            pass

    def import_jsonl(self) -> None:
        path = filedialog.askopenfilename(filetypes=(("JSONL capture", "*.jsonl"), ("JSON", "*.json"), ("All files", "*.*")))
        if not path:
            return
        records = load_jsonl_records(path)
        if not records:
            messagebox.showerror("Import failed", "No position records found in this file.")
            return
        track = self.selected_track.get()
        if track == "lead":
            self.lead_samples.extend(records)
            gate = LeadStartGate()
            self.lead_preview_capture = [row for record in records for row in gate.push(record)]
        else:
            self.records[track].extend(records)
        self.status.set(f"IMPORTED — {len(records)} reports into {track}")
        self._log(f"imported {len(records)} reports into {track}")
        self._draw_canvas(self.lead_preview_capture if track == "lead" else records)

    def export_events(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        path = filedialog.asksaveasfilename(defaultextension=".json", filetypes=(("Event JSON", "*.json"),))
        if path:
            write_event_table(self.event_table, path)
            self.status.set(f"EXPORTED — {Path(path).name}")

    def render_wav(self) -> None:
        if not self.event_table:
            self.compile()
        if not self.event_table:
            return
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV audio", "*.wav"),))
        if path:
            render_loop(self.event_table, path)
            self.status.set(f"RENDERED — {Path(path).name}")

    def clear_track(self) -> None:
        track = self.selected_track.get()
        if track == "lead":
            self.lead_samples.clear()
        else:
            self.records[track].clear()
        self.event_table = None
        self._refresh_events()
        self.status.set(f"CLEARED — {track}")

    def clear_all(self) -> None:
        self.lead_samples.clear()
        for values in self.records.values():
            values.clear()
        self.event_table = None
        self._refresh_events()
        self.status.set("CLEARED — all captures")

    def _draw_canvas(self, samples: List[dict] | None = None) -> None:
        if samples is None:
            samples = (self.lead_preview_capture or self.current_capture or self.lead_samples
                       if self.selected_track.get() == "lead" else self.current_capture)
        self.canvas.delete("all")
        width, height = max(10, self.canvas.winfo_width()), max(10, self.canvas.winfo_height())
        for x in range(0, width, 80):
            self.canvas.create_line(x, 0, x, height, fill="#182235")
        for y in range(0, height, 60):
            self.canvas.create_line(0, y, width, y, fill="#182235")
        self.canvas.create_text(16, 14, anchor="nw", text="XYZ trajectory / current capture", fill="#8490a8")
        # Fixed G3–C5 PitchSpace guides. The labels are intentionally tied to
        # the calibrated workspace rather than to the current capture extent.
        for midi in DEFAULT_PITCH_SPACE.scale_pitches:
            ratio = (midi - DEFAULT_PITCH_SPACE.min_midi) / max(1, DEFAULT_PITCH_SPACE.max_midi - DEFAULT_PITCH_SPACE.min_midi)
            py = height - 28 - ratio * (height - 56)
            self.canvas.create_line(28, py, width - 28, py, fill="#27344d")
            self.canvas.create_text(width - 34, py - 2, anchor="e", text=str(midi), fill="#536078", font=("Segoe UI", 8))
        if len(samples) < 2:
            self.canvas.create_text(width / 2, height / 2, text="Record Lead or import a JSONL capture", fill="#536078")
            return
        # The grid is a fixed workspace. A short or wide gesture therefore
        # remains visibly comparable between takes; it is never stretched to
        # its own min/max range.
        pixels = self._path_cache.points(samples, width, height)
        self._drawn_points = len(pixels)
        points = []
        for px, py in pixels:
            points.extend((px, py))
        if len(points) < 4:
            self.canvas.create_text(width / 2, height / 2, text="Capture is shorter than one pixel", fill="#536078")
            return
        # No spline: the path is already thinned at display resolution, and
        # smoothing would round exactly the corners the user draws on purpose.
        self.canvas.create_line(*points, fill="#f3c969", width=2)
        self.canvas.create_oval(points[0] - 4, points[1] - 4, points[0] + 4, points[1] + 4, fill="#6ce5b1", outline="")
        self.canvas.create_oval(points[-2] - 4, points[-1] - 4, points[-2] + 4, points[-1] + 4, fill="#ef7896", outline="")
        if self.event_table and self.event_table.get("landmarks"):
            colors = {"move": "#6ce5b1", "hold": "#f3c969", "turn": "#ef7896", "apex": "#ff9f68", "valley": "#8aa7ff", "rest": "#667085", "release": "#d58cff"}
            for landmark in self.event_table["landmarks"]:
                tick_ratio = float(landmark.get("tick", 0)) / max(1, STYLE.loop_ticks - 1)
                pitch_ratio = _clamp(float(landmark.get("b_abs", 0.5)), 0.0, 1.0)
                px = 28 + tick_ratio * (width - 56)
                py = height - 28 - pitch_ratio * (height - 56)
                color = colors.get(str(landmark.get("kind")), "#d9e2f2")
                self.canvas.create_oval(px - 5, py - 5, px + 5, py + 5, fill=color, outline="#10131b", width=1)
                self.canvas.create_text(px + 7, py - 7, anchor="sw", text=str(landmark.get("kind", "")), fill=color, font=("Segoe UI", 8))


def main() -> int:
    app = SynthwaveUI()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
