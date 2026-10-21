"""Build an explicit PC HostCalibrationProfile from real capture files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    from .host_xyz_filter import build_profile
    from .replay_host_filter import load_capture
except ImportError:  # direct script execution
    from host_xyz_filter import build_profile
    from replay_host_filter import load_capture


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a fixed MGC3130 host profile")
    parser.add_argument("--neutral", type=Path, required=True)
    parser.add_argument("--depth", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--profile-id", default=None)
    args = parser.parse_args()
    metadata = {"neutral": str(args.neutral), "depth": str(args.depth), "workspace": str(args.workspace)}
    profile, diagnostics = build_profile(load_capture(args.neutral), load_capture(args.depth), load_capture(args.workspace), metadata)
    if args.profile_id:
        profile = type(profile)(**{**profile.to_dict(include_hash=False), "profile_id": args.profile_id})
        diagnostics["profile_id"] = profile.profile_id
        diagnostics["profile_hash"] = profile.profile_hash
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(profile.to_dict(), indent=2, ensure_ascii=False, default=list) + "\n", encoding="utf-8")
    print(json.dumps(diagnostics, indent=2, ensure_ascii=False, default=list))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
