#!/usr/bin/env python3
"""只检查明确要求保持上游原样的底层，不把策略层差异伪装为字节对齐。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
revision = "3cfe4b1e52cad6a99f5f19a7e01fb279752eb2a8"
prefix = "packages/OpenComputerUseKit/Sources/OpenComputerUseKit/"
for name in ("SkyLightSPI.swift", "AgentDisplay.swift", "WindowOcclusionKeepAlive.swift"):
    path = prefix + name
    result = subprocess.run(
        ["git", "show", revision + ":" + path], cwd=root, capture_output=True
    )
    if result.returncode:
        raise SystemExit(
            "Upstream object unavailable: fetch upstream revision " + revision
            + " before running this read-only check."
        )
    upstream = result.stdout
    if (root / path).read_bytes() != upstream:
        raise SystemExit("Unreviewed core divergence: " + name)
    print("unchanged:", name)
print("Core parity verified against", revision, "(not a GUI acceptance result)")
