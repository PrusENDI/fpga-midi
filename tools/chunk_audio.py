"""Chunked audio output that needs no numpy.

sounddevice cannot build its callback buffers without numpy, which is not
installed here and could not be fetched. This player renders short blocks,
wraps each in a WAV in memory, and hands it to winsound asynchronously. Block
duration sets the latency; 120 ms is comfortable for playing.
"""

from __future__ import annotations

import io
import os
import struct
import tempfile
import threading
import time
import wave

try:
    import winsound
except ImportError:  # pragma: no cover - non Windows
    winsound = None

SR = 48000


def block_to_wav(samples, sample_rate: int = SR) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value)) * 30000))
                                    for value in samples))
    return buffer.getvalue()


class ChunkPlayer:
    """Renders blocks from a callback and plays them back to back."""

    def __init__(self, render, chunk_ms: float = 120.0, sample_rate: int = SR) -> None:
        self.render = render
        self.sample_rate = sample_rate
        self.chunk = max(1, int(sample_rate * chunk_ms / 1000.0))
        self.running = False
        self.thread = None
        self.error = None
        self._slot = 0

    def start(self) -> bool:
        if winsound is None or self.running:
            return False
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()
        return True

    def _loop(self) -> None:
        while self.running:
            started = time.monotonic()
            samples = [self.render() for _ in range(self.chunk)]
            # winsound refuses SND_MEMORY with SND_ASYNC, so hand it a file.
            self._slot ^= 1
            path = os.path.join(tempfile.gettempdir(), "chunk_audio_%d.wav" % self._slot)
            try:
                with open(path, "wb") as handle:
                    handle.write(block_to_wav(samples, self.sample_rate))
                winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
                self.error = None
            except Exception as error:
                self.error = str(error)
            elapsed = time.monotonic() - started
            time.sleep(max(0.0, self.chunk / self.sample_rate - elapsed))

    def stop(self) -> None:
        self.running = False
        if winsound is not None:
            winsound.PlaySound(None, winsound.SND_PURGE)
