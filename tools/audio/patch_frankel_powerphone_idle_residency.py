#!/usr/bin/env python3
"""Select the optional PowerPhone low-latency cluster-idle configuration.

Only four display-idle actions are changed. The research setting holds the
same 1,500,000-us cluster minimum-residency used by the working stock
AUDIO_STREAMING_LOW_LATENCY hint, without sharing its global Boolean owner.
This is an idle-power tradeoff, not CPU-frequency locking. No device calls,
hashes, image packaging, or changes to unrelated power actions are made.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import stat

from patch_frankel_primary_hal_192k import write_atomic


TARGETS = {
    (mode, cluster): stock_value
    for mode in ("DISPLAY_INACTIVE", "DISPLAY_PRI_0_IDLE")
    for cluster, stock_value in (("CL1MinResidency", "10000"),
                                 ("CL2MinResidency", "15000"))
}
RESEARCH_VALUE = "1500000"


def transform(document: dict, state: str) -> str:
    nodes = document["Nodes"]
    for number in (1, 2):
        name = f"CL{number}MinResidency"
        selected = [node for node in nodes if node.get("Name") == name]
        expected_path = ("/sys/devices/platform/gs_domain_idle/"
                         f"power-domain-cluster-{number}-state-0/min-residency-us")
        if len(selected) != 1 or selected[0].get("Path") != expected_path:
            raise ValueError(f"reviewed {name} node changed")
        node = selected[0]
        if (node.get("DefaultIndex") != 0 or not node.get("ResetOnInit") or
                node.get("Values", [None])[0] != RESEARCH_VALUE):
            raise ValueError(f"reviewed {name} default/reset behavior changed")
    found = {}
    for action in document["Actions"]:
        key = (action.get("PowerHint"), action.get("Node"))
        if key in TARGETS:
            if key in found or action.get("Duration") != 0:
                raise ValueError(f"duplicate or changed idle action: {key}")
            found[key] = action
        elif action.get("Node") in ("CL1MinResidency", "CL2MinResidency"):
            if action.get("Value") != RESEARCH_VALUE:
                raise ValueError("another action changes the reviewed cluster idle residency")
    if found.keys() != TARGETS.keys():
        raise ValueError("expected exactly four reviewed display-idle actions")
    old_stock = all(found[key].get("Value") == value for key, value in TARGETS.items())
    old_research = all(action.get("Value") == RESEARCH_VALUE for action in found.values())
    if old_stock == old_research:
        raise ValueError("refusing mixed or unknown display-idle values")
    for key, action in found.items():
        action["Value"] = RESEARCH_VALUE if state == "research" else TARGETS[key]
    return "stock" if old_stock else "research"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--state", choices=("stock", "research"), default="research")
    parser.add_argument("--in-place", action="store_true")
    args = parser.parse_args()
    try:
        if not args.input.is_file() or args.input.is_symlink():
            raise ValueError("input must be a regular non-symlink file")
        if args.in_place == (args.output is not None):
            raise ValueError("choose exactly one of OUTPUT or --in-place")
        document = json.loads(args.input.read_text())
        before = transform(document, args.state)
        destination = args.input if args.in_place else args.output
        if before != args.state or destination != args.input:
            result = (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()
            write_atomic(destination, result, stat.S_IMODE(args.input.stat().st_mode))
        print(f"selected {args.state} cluster-idle profile (was {before}): {destination}")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
