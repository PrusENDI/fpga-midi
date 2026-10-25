"""Draw the timbre: sixteen harmonic bars, hear it immediately.

Each bar is the amplitude of one harmonic. The bars are converted into a
1024 point wavetable by additive synthesis, blended with a small square base so
the result always has body, and rendered through the same engine the FPGA will
mirror.

    python tools/harmonic_draw.py
"""

from __future__ import annotations

import math
import sys
import tempfile
import tkinter as tk
from pathlib import Path
from tkinter import ttk

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.wavetable_lab import TABLE_SIZE, render  # noqa: E402

BARS = 16
BAR_WIDTH = 26
BAR_GAP = 10
CANVAS_HEIGHT = 220
SQUARE_MIX = 0.25
PREVIEW_SECONDS = 3.0


def table_from_bars(bars, size: int = TABLE_SIZE):
    """Additive synthesis from sixteen bar values, plus a small square base."""
    table = []
    for index in range(size):
        phase = 2.0 * math.pi * index / size
        value = sum(level * math.sin(phase * (harmonic + 1)) for harmonic, level in enumerate(bars))
        square = 1.0 if index < size // 2 else -1.0
        table.append((1.0 - SQUARE_MIX) * value + SQUARE_MIX * square * 0.35)
    peak = max((abs(value) for value in table), default=0.0) or 1.0
    return [value / peak for value in table]


def demo_notes(count: int = 8, step: float = 0.16):
    """A short rising phrase so the timbre can be judged without a capture."""
    pattern = [57, 60, 62, 64, 67, 64, 62, 60]
    return [{"tick": index * 2, "duration": 2, "note": pattern[index % len(pattern)], "velocity": 100}
            for index in range(count)], step


class HarmonicDraw(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Draw the timbre")
        self.geometry("560x420")
        self.bars = [1.0 / (index + 1) for index in range(BARS)]
        self.bars[0] = 1.0

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Drag a bar up or down. Harmonic 1 is on the left.").pack(anchor="w")

        width = BARS * (BAR_WIDTH + BAR_GAP) + BAR_GAP
        self.canvas = tk.Canvas(frame, width=width, height=CANVAS_HEIGHT, bg="#181d2a",
                                highlightthickness=0)
        self.canvas.pack(pady=8)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.canvas.bind("<Button-1>", self._drag)

        row = ttk.Frame(frame)
        row.pack(fill="x", pady=4)
        ttk.Button(row, text="▶  Play", command=self.play).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Saw", command=lambda: self._preset("saw")).pack(side="left", padx=4)
        ttk.Button(row, text="Soft", command=lambda: self._preset("soft")).pack(side="left", padx=4)
        ttk.Button(row, text="Square", command=lambda: self._preset("square")).pack(side="left", padx=4)
        ttk.Button(row, text="Save WAV…", command=self.save).pack(side="left", padx=4)

        self.status = tk.StringVar(value="ready")
        ttk.Label(frame, textvariable=self.status).pack(anchor="w", pady=(8, 0))
        self._draw()

    # ---- drawing ----------------------------------------------------------
    def _draw(self) -> None:
        self.canvas.delete("all")
        for index, level in enumerate(self.bars):
            x0 = BAR_GAP + index * (BAR_WIDTH + BAR_GAP)
            top = CANVAS_HEIGHT - max(2, level * (CANVAS_HEIGHT - 12))
            self.canvas.create_rectangle(x0, top, x0 + BAR_WIDTH, CANVAS_HEIGHT,
                                         fill="#5b8cff", outline="")
            self.canvas.create_text(x0 + BAR_WIDTH // 2, CANVAS_HEIGHT - 8,
                                    text=str(index + 1), fill="#8a93a6", font=("Segoe UI", 8))

    def _drag(self, event) -> None:
        index = int((event.x - BAR_GAP) / (BAR_WIDTH + BAR_GAP))
        if 0 <= index < BARS:
            level = 1.0 - (event.y - 6) / float(CANVAS_HEIGHT - 12)
            self.bars[index] = max(0.0, min(1.0, level))
            self._draw()
            self.status.set(f"harmonic {index + 1} = {self.bars[index]:.2f}")

    def _preset(self, name: str) -> None:
        if name == "saw":
            self.bars = [1.0 / (index + 1) for index in range(BARS)]
        elif name == "soft":
            self.bars = [1.0 / ((index + 1) ** 2) for index in range(BARS)]
        else:
            self.bars = [1.0 if index % 2 == 0 else 0.15 for index in range(BARS)]
        self.bars[0] = 1.0
        self._draw()
        self.status.set(f"{name} preset")

    # ---- audio ------------------------------------------------------------
    def _render(self, path: Path) -> None:
        notes, step = demo_notes(int(PREVIEW_SECONDS / 0.16))
        render(table_from_bars(self.bars), notes, step, path)

    def play(self) -> None:
        try:
            path = Path(tempfile.gettempdir()) / "harmonic_draw.wav"
            self._render(path)
            try:
                import winsound
                winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
                self.status.set("playing")
            except Exception:
                self.status.set(f"rendered to {path}")
        except Exception as error:
            self.status.set(f"error: {error}")

    def save(self) -> None:
        from tkinter import filedialog
        path = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=(("WAV", "*.wav"),))
        if path:
            try:
                self._render(Path(path))
                self.status.set(f"saved {Path(path).name}")
            except Exception as error:
                self.status.set(f"error: {error}")


if __name__ == "__main__":
    HarmonicDraw().mainloop()
