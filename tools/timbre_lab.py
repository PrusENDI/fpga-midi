"""Knob panel for the timbre: move a slider, hear the result.

Run from the repository root:

    python tools/timbre_lab.py

Three knobs match the three CSR parameters the FPGA will receive: square base
mix, spectral exponent and unison detune. Changing one rebuilds the wavetable
from the segmented FFT and renders a short preview.
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

from tools.synthwave_loop import (STYLE, compile_loop, load_jsonl_records,  # noqa: E402
                                  preprocess_samples, resample_to_ticks, length_from_take)
from tools.timbre import build_timbre  # noqa: E402
from tools.wavetable_lab import render  # noqa: E402

DEFAULT_CAPTURE = ROOT / "pc_receiver" / "captures" / "lead_20261025-131102.jsonl"


class TimbreLab(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Timbre lab")
        self.geometry("430x320")
        self.capture = DEFAULT_CAPTURE if DEFAULT_CAPTURE.exists() else None
        self.notes: list = []
        self.seconds_per_tick = 0.15

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        ttk.Button(frame, text="Load capture…", command=self.load).pack(fill="x")
        ttk.Button(frame, text="Analyse", command=self.analyse).pack(fill="x", pady=(4, 8))

        self.knobs = {}
        for name, low, high, value in (("square_mix", 0.0, 1.0, 0.6),
                                       ("exponent", 0.6, 3.0, 1.5),
                                       ("detune_cents", 0.0, 20.0, 7.0)):
            row = ttk.Frame(frame)
            row.pack(fill="x", pady=4)
            ttk.Label(row, text=name, width=14).pack(side="left")
            variable = tk.DoubleVar(value=value)
            label = ttk.Label(row, text=f"{value:.2f}", width=6)
            ttk.Scale(row, from_=low, to=high, variable=variable, orient="horizontal").pack(
                side="left", fill="x", expand=True, padx=4)
            label.pack(side="left")
            variable.trace_add("write", lambda *_args, var=variable, lbl=label: lbl.configure(
                text=f"{var.get():.2f}"))
            self.knobs[name] = variable

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=(10, 4))
        ttk.Label(row, text="Preview seconds").pack(side="left")
        self.preview = tk.DoubleVar(value=4.0)
        ttk.Spinbox(row, from_=1, to=20, increment=1, textvariable=self.preview, width=6).pack(side="left", padx=6)
        ttk.Button(frame, text="▶  Play", command=self.play).pack(fill="x", pady=(8, 2))
        ttk.Button(frame, text="Save WAV…", command=self.save).pack(fill="x")
        self.status = tk.StringVar(value="load a capture, then Analyse")
        ttk.Label(frame, textvariable=self.status).pack(fill="x", pady=(8, 0))

    def load(self) -> None:
        path = filedialog.askopenfilename(filetypes=(("JSONL", "*.jsonl"), ("All", "*.*")))
        if not path:
            return
        self.capture = Path(path)
        self.analyse()

    def analyse(self) -> None:
        if self.capture is None or not Path(self.capture).exists():
            self.status.set("no capture loaded")
            return
        try:
            records = load_jsonl_records(self.capture)
            table = compile_loop(records, {}, note_source="variational", lam=5.83,
                                 time_map="loop", auto_length=True)
            rows = preprocess_samples(records, pitch_source="cursor")
            style = length_from_take(rows, STYLE, 32)
            self.seconds_per_tick = 60.0 / style.bpm / 4.0
            self.notes = [{"tick": int(event["tick"]), "duration": int(event.get("duration", 1)),
                           "note": int(event["note"]), "velocity": int(event.get("velocity", 90))}
                          for event in table["events"] if event.get("type") == "note_on"]
            self.status.set(f"{len(self.notes)} notes, {table['config']['loop_bars']} bars")
        except Exception as error:
            self.status.set(f"error: {error}")

    def _render(self, path: Path) -> None:
        if not self.notes:
            self.analyse()
        info = build_timbre(self.capture, {name: value.get() for name, value in self.knobs.items()})
        limit = float(self.preview.get())
        max_tick = limit / self.seconds_per_tick
        notes = [note for note in self.notes if note["tick"] < max_tick]
        render(info["table"], notes or self.notes[:4], self.seconds_per_tick, path)
        self.status.set(f"rendered {limit:.0f}s · square {self.knobs['square_mix'].get():.2f} "
                        f"· exponent {self.knobs['exponent'].get():.2f}")

    def play(self) -> None:
        try:
            path = Path(tempfile.gettempdir()) / "timbre_lab.wav"
            self._render(path)
            try:
                import winsound
                winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
            except Exception:
                self.status.set(f"rendered to {path} (no audio device)")
        except Exception as error:
            self.status.set(f"error: {error}")

    def save(self) -> None:
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV", "*.wav"),))
        if path:
            try:
                self._render(Path(path))
                self.status.set(f"saved {Path(path).name}")
            except Exception as error:
                self.status.set(f"error: {error}")


if __name__ == "__main__":
    TimbreLab().mainloop()
