#!/usr/bin/env python3
"""Check the PC-to-FPGA UART RX path using the official echo bitstream."""

from __future__ import annotations

import argparse
import time

import serial  # type: ignore


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()

    token = b"RXTEST42"
    with serial.Serial(args.port, args.baud, timeout=0.1,
                       bytesize=8, parity=serial.PARITY_NONE,
                       stopbits=serial.STOPBITS_ONE,
                       rtscts=False, dsrdtr=False) as port:
        port.reset_input_buffer()
        port.write(token)
        port.flush()
        data = bytearray()
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            data.extend(port.read(256))

    print(f"RX bytes: {data.hex(' ')}")
    if token in data:
        print("PASS: FPGA echoed RXTEST42; COM4 -> FPGA B3 RX is working")
        return 0
    print("FAIL: no complete echo; keep the official echo bitstream loaded "
          "and check the board RX wiring/channel")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
