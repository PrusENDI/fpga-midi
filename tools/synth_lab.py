"""PC test lab: draw a gesture or load a take, hear the reference engine.

Run from the repository root:

    python tools/synth_lab.py

The window is deliberately small. It exists so the mapping and the engine can
be judged by ear before any RTL is written: change the gate or the timbre,
press play, listen. Rendering is pure Python, so keep the preview short.
"""

from __future__ import annotations

import sys
import tempfile
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.synth_reference import (TIMBRE_SAW, TIMBRE_SINE, TIMBRE_SQUARE,
                                   TIMBRE_TRIANGLE)  # noqa: E402
from tools.synth_render import render_table  # noqa: E402
from tools.synthwave_loop import (DEFAULT_PITCH_SPACE, STYLE, TRACKS,
                                  compile_loop, density_to_lambda,
                                  load_jsonl_records)  # noqa: E402

TIMBRES = {"saw": TIMBRE_SAW, "sine": TIMBRE_SINE, "square": TIMBRE_SQUARE, "triangle": TIMBRE_TRIANGLE}


def synthetic_gesture(seconds: float = 6.0) -> list:
    """A slow up-down sweep with three touches, so the lab works with no file."""
    import math
    frames = int(seconds / 0.005)
    rows = []
    for index in range(frames):
        moment = index * 0.005
        y = 34000 + int(6 * 2498 * math.sin(2 * math.pi * 0.35 * moment))
        x = 32768 + int(0.10 * 32768 * math.sin(2 * math.pi * 0.8 * moment))
        touch = 1 if 0.5 + 1.1 * int(moment / 1.1) <= moment < 0.9 + 1.1 * int(moment / 1.1) else 0
        rows.append({"type": "position", "timestamp_ms": int(moment * 1000),
                     "x": x, "y": y, "z": 6000, "touch_flags": touch,
                     "position_valid": True})
    return rows


class Lab(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Synth reference lab")
        self.geometry("460x300")
        self.records: list = synthetic_gesture()
        self.table: dict | None = None

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)

        ttk.Button(frame, text="Load capture…", command=self.load).pack(fill="x", pady=2)
        ttk.Button(frame, text="Use synthetic gesture", command=self.use_synthetic).pack(fill="x", pady=2)

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=6)
        ttk.Label(row, text="Gate").pack(side="left")
        self.gate = tk.StringVar(value="touch")
        ttk.Radiobutton(row, text="touch", value="touch", variable=self.gate).pack(side="left")
        ttk.Radiobutton(row, text="bow", value="bow", variable=self.gate).pack(side="left")

        row2 = ttk.Frame(frame)
        row2.pack(fill="x", pady=6)
        ttk.Label(row2, text="Timbre").pack(side="left")
        self.timbre = tk.StringVar(value="saw")
        ttk.Combobox(row2, textvariable=self.timbre, values=sorted(TIMBRES), width=10,
                     state="readonly").pack(side="left", padx=6)
        ttk.Label(row2, text="Voices").pack(side="left", padx=(12, 0))
        self.voices = tk.IntVar(value=8)
        ttk.Spinbox(row2, from_=1, to=32, textvariable=self.voices, width=5).pack(side="left")

        row3 = ttk.Frame(frame)
        row3.pack(fill="x", pady=6)
        ttk.Label(row3, text="Density").pack(side="left")
        self.density = tk.DoubleVar(value=0.6)
        ttk.Scale(row3, from_=0.0, to=1.0, variable=self.density, orient="horizontal").pack(
            side="left", fill="x", expand=True, padx=6)

        row4 = ttk.Frame(frame)
        row4.pack(fill="x", pady=6)
        ttk.Label(row4, text="Preview seconds").pack(side="left")
        self.preview = tk.DoubleVar(value=4.0)
        ttk.Spinbox(row4, from_=1, to=20, increment=0.5, textvariable=self.preview, width=6).pack(side="left")

        ttk.Button(frame, text="▶  Compile and play", command=self.play).pack(fill="x", pady=(10, 2))
        ttk.Button(frame, text="Save WAV…", command=self.save).pack(fill="x", pady=2)
        self.status = tk.StringVar(value="ready")
        ttk.Label(frame, textvariable=self.status, style="Muted.TLabel").pack(fill="x", pady=(8, 0))

    # ---- inputs -----------------------------------------------------------
    def load(self) -> None:
        path = filedialog.askopenfilename(filetypes=(("JSONL capture", "*.jsonl"), ("All files", "*.*")))
        if not path:
            return
        self.records = load_jsonl_records(path)
        self.status.set(f"loaded {Path(path).name}: {len(self.records)} frames")

    def use_synthetic(self) -> None:
        self.records = synthetic_gesture()
        self.status.set("synthetic gesture loaded")

    # ---- rendering --------------------------------------------------------
    def _compile(self) -> dict:
        style = STYLE
        table = compile_loop(self.records, {}, note_source="variational",
                             lam=density_to_lambda(self.density.get()),
                             time_map="loop", auto_length=True,
                             gate_source=self.gate.get())
        return table

    def _render(self, path: Path) -> dict:
        table = self._compile()
        limit = float(self.preview.get())
        bpm = float(table["config"]["bpm"])
        seconds_per_tick = 60.0 / bpm / 4.0
        max_tick = int(limit / seconds_per_tick)
        trimmed = dict(table)
        trimmed["events"] = [event for event in table["events"]
                             if int(event.get("tick", 0)) < max_tick]
        trimmed["config"] = dict(table["config"], loop_bars=1)
        render_table(trimmed, path, voices=int(self.voices.get()),
                     tail_ms=300, loops=1)
        return table

    def play(self) -> None:
        try:
            path = Path(tempfile.gettempdir()) / "synth_lab.wav"
            table = self._render(path)
            notes = sum(1 for event in table["events"] if event["type"] == "note_on")
            self.status.set(f"playing · {notes} notes in take · preview {self.preview.get():.1f}s")
            try:
                import winsound
                winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
            except Exception:
                self.status.set(f"rendered to {path} (no audio device)")
        except Exception as error:                     # keep the window alive
            self.status.set(f"error: {error}")

    def save(self) -> None:
        path = filedialog.asksaveasfilename(defaultextension=".wav",
                                            filetypes=(("WAV", "*.wav"),))
        if not path:
            return
        try:
            self._render(Path(path))
            self.status.set(f"saved {Path(path).name}")
        except Exception as error:
            self.status.set(f"error: {error}")


if __name__ == "__main__":
    Lab().mainloop()
