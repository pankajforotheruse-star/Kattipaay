#!/usr/bin/env python3
"""Reject unclassified Godot engine errors; narrowly classify headless editor noise.

This is a log gate, not a substitute for a failing engine exit code.
"""
import argparse
import re
import sys
from pathlib import Path

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--allow-editor-task-noise", action="store_true")
    args = parser.parse_args()
    try:
        lines = args.path.read_text(errors="replace").splitlines()
    except OSError as error:
        print(f"GODOT_LOG_GATE: cannot read {args.path}: {error}", file=sys.stderr)
        return 1
    allowed = 0
    unexpected = []
    for i, line in enumerate(lines, 1):
        match = re.search(r"\b(?:SCRIPT ERROR|ERROR):\s*(.*)", line)
        if not match:
            continue
        message = match.group(1)
        known_editor_task_noise = (
            "Do not use progress dialog (task) while flushing the message queue" in message
            or 'Condition "!tasks.has(p_task)" is true.' in message
        )
        if args.allow_editor_task_noise and known_editor_task_noise:
            allowed += 1
        else:
            unexpected.append((i, message))
    for line, message in unexpected[:20]:
        print(f"GODOT_LOG_GATE: unexpected error {args.path}:{line}: {message}", file=sys.stderr)
    if unexpected:
        print(f"GODOT_LOG_GATE: FAIL unexpected={len(unexpected)} allowed={allowed}")
        return 1
    print(f"GODOT_LOG_GATE: PASS allowed_headless_editor_errors={allowed}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
