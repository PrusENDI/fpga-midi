"""Two stage instrument: capture a timbre from the sensor, then perform with it.

Stage one: hold still-ish and sweep the hand once. The captured trajectory is
normalised in time and mapped onto phase, so a slow sweep still becomes a full
cycle; that is the trick a wavetable plugin uses when you draw one period.

Stage two: the same sensor now plays notes through that table, with height
setting the follow rate and contact freezing the cursor.

    python tools/timbre_then_play.py
"""

from __future__ import annotations

import json
import math
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import ttk


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from live_play import (CANVAS_H, CANVAS_W, RECEIVER, SCALE, SR,  # noqa: E402
                       Instrument, build_table)
from chunk_audio import ChunkPlayer  # noqa: E402

CAPTURE_SECONDS = 2.0


class TimbreStage:
    """Collects one sweep and turns it into a table."""

    def __init__(self) -> None:
        self.samples = []
        self.active = False
        self.started = 0.0

    def begin(self) -> None:
        self.samples = []
        self.active = True
        self.started = time.monotonic()

    def feed(self, y: float) -> bool:
        if not self.active:
            return False
        self.samples.append(y)
        if time.monotonic() - self.started >= CAPTURE_SECONDS:
            self.active = False
            return True
        return False

    def table(self, width: int = CANVAS_W):
        if len(self.samples) < 16:
            return None
        points = []
        span = len(self.samples) - 1
        for index in range(96):
            position = index * span / 95.0
            left = int(position)
            right = min(len(self.samples) - 1, left + 1)
            frac = position - left
            value = self.samples[left] * (1.0 - frac) + self.samples[right] * frac
            points.append((index / 95.0 * width, (1.0 - value) * CANVAS_H))
        return build_table(points)


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Timbre then play")
        self.geometry("520x420")
        self.instrument = Instrument()
        self.stage = TimbreStage()
        self.state = "idle"
        self.queue: queue.Queue = queue.Queue()
        self.points = []
        self.process = None
        self.stream = None

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        self.hint = ttk.Label(frame, text="1) Press Capture, sweep the hand once, 2) press Play.")
        self.hint.pack(anchor="w")
        self.canvas = tk.Canvas(frame, width=CANVAS_W, height=CANVAS_H, bg="#181d2a",
                                highlightthickness=1, highlightbackground="#333a4d")
        self.canvas.pack(pady=8)

        row = ttk.Frame(frame)
        row.pack(fill="x")
        self.capture_button = ttk.Button(row, text="Capture timbre", command=self.capture)
        self.capture_button.pack(side="left", padx=2)
        self.play_button = ttk.Button(row, text="▶  Play", command=self.play)
        self.play_button.pack(side="left", padx=2)
        ttk.Button(row, text="Stop", command=self.stop).pack(side="left", padx=2)
        ttk.Button(row, text="Sine", command=lambda: self.preset("sine")).pack(side="left", padx=8)
        ttk.Button(row, text="Saw", command=lambda: self.preset("saw")).pack(side="left", padx=2)

        self.status = tk.StringVar(value="idle")
        ttk.Label(frame, textvariable=self.status).pack(anchor="w", pady=(8, 0))
        self.after(30, self._poll)

    # ---- sensor ----------------------------------------------------------
    def ensure_sensor(self) -> bool:
        if self.process is not None and self.process.poll() is None:
            return True
        if not RECEIVER.exists():
            self.status.set("receiver executable not found")
            return False
        self.process = subprocess.Popen([str(RECEIVER), "--format", "jsonl"],
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True, encoding="utf-8")
        threading.Thread(target=self._pump, daemon=True).start()
        return True

    def _pump(self) -> None:
        assert self.process and self.process.stdout
        for line in self.process.stdout:
            if '"position"' in line:
                try:
                    self.queue.put(json.loads(line))
                except json.JSONDecodeError:
                    pass

    # ---- stages ----------------------------------------------------------
    def capture(self) -> None:
        if not self.ensure_sensor():
            return
        self.state = "capturing"
        self.stage.begin()
        self.points = []
        self.canvas.delete("all")
        self.status.set("capturing: sweep the hand once")

    def _finish_capture(self) -> None:
        table = self.stage.table()
        self.state = "frozen"
        if table is None:
            self.status.set("capture too short")
            return
        self.instrument.set_table(table)
        self._draw_from(table)
        self.status.set("timbre frozen - press Play")

    def _draw_from(self, table) -> None:
        self.canvas.delete("all")
        step = max(1, len(table) // CANVAS_W)
        points = []
        for index in range(0, len(table), step):
            points.extend([index / len(table) * CANVAS_W,
                           CANVAS_H / 2 - table[index] * CANVAS_H * 0.4])
        if len(points) > 3:
            self.canvas.create_line(*points, fill="#5b8cff", width=2)

    def play(self) -> None:
        """Play the fixed melody with the current table, for judging timbre."""
        from tools.timbre_test import render
        import tempfile
        import winsound
        path = Path(tempfile.gettempdir()) / "timbre_preview.wav"
        seconds = render(self.instrument.table, path, 48000)
        try:
            winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
            self.status.set(f"fixed melody, %.2f s, %d notes" % (seconds, 5))
        except Exception as error:
            self.status.set(f"audio error: {error}")

    def preset(self, name: str) -> None:
        points = []
        for index in range(65):
            x = index / 64.0 * CANVAS_W
            if name == "sine":
                y = CANVAS_H / 2 - math.sin(2 * math.pi * index / 64) * CANVAS_H * 0.4
            else:
                y = CANVAS_H - index / 64.0 * CANVAS_H
            points.append((x, y))
        self.instrument.set_table(build_table(points))
        self._draw_from(build_table(points))
        self.status.set(f"{name} preset")

    def _poll(self) -> None:
        latest = None
        while not self.queue.empty():
            latest = self.queue.get()
        if latest is not None:
            y = (float(latest.get("y") or 0)) / 65535.0
            z = (float(latest.get("z") or 0)) / 65535.0
            touch = int(latest.get("touch_flags") or 0) != 0
            if self.state == "capturing":
                if self.stage.feed(y):
                    self._finish_capture()
                else:
                    self.canvas.create_oval(2, (1 - y) * CANVAS_H - 2, 6, (1 - y) * CANVAS_H + 2,
                                            fill="#ffb020", outline="")
            elif self.state == "performing":
                self.instrument.feed(0.0, y, z, touch)
                self.status.set(f"y {y:.2f}  z {z:.2f}{'  touch' if touch else ''}")
        self.after(30, self._poll)

    def stop(self) -> None:
        self.state = "idle"
        if self.player is not None:
            self.player.stop()
            self.player = None
        if self.process is not None:
            self.process.terminate()
            self.process = None
        self.status.set("stopped")


def _callback(outdata, frames, time_info, status) -> None:
    instrument = _callback.instrument
    for index in range(frames):
        outdata[index][0] = instrument.next_sample()


if __name__ == "__main__":
    App().mainloop()
