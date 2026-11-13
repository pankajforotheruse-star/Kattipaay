#!/usr/bin/env python3
"""Analyze genuine local 3D match telemetry, excluding scripted benchmarks.
Usage: python3 scripts/analyze_3d_playtests.py build/android-qa-.../chalk_gaon_3d_match_telemetry.jsonl
No external packages required. Never equate automated fixtures with human trials.
"""
import collections
import json
import math
import pathlib
import statistics
import sys

def wilson(wins, n):
    if n == 0:
        return (0.0, 0.0)
    z = 1.959963984540054
    p = wins / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    radius = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, center - radius), min(1.0, center + radius))

def analyze(path):
    rows = []
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON at line {line_no}: {exc}") from exc
        if row.get("schema") != "chalk_gaon_3d_match_v1":
            continue
        if row.get("session_kind") != "local_play_vs_cpu":
            continue
        rows.append(row)
    report = {"source": str(path), "study": "real_local_3d_sessions_unverified_human_identity",
              "note": "Manual playtest verification is required; automated sessions must be excluded.",
              "difficulties": []}
    for difficulty in range(4):
        matches = [r for r in rows if r.get("difficulty") == difficulty]
        n = len(matches)
        wins = sum(str(r.get("result", "")).startswith("HUMAN WINS") for r in matches)
        losses = sum(str(r.get("result", "")).startswith("CPU WINS") for r in matches)
        draws = n - wins - losses
        def avg(field):
            return statistics.fmean(float(r.get(field, 0)) for r in matches) if matches else 0.0
        low, high = wilson(wins, n)
        report["difficulties"].append({
            "difficulty": difficulty, "matches": n,
            "human_wins": wins, "cpu_wins": losses, "draws": draws,
            "human_win_rate": wins / n if n else 0.0,
            "human_win_rate_95ci": [low, high],
            "mean_cpu_search_cells": avg("cpu_search_cells"),
            "mean_cpu_inspections": avg("cpu_inspections"),
            "mean_human_marks": avg("human_marks"),
            "mean_cpu_marks": avg("cpu_marks"),
            "mean_cpu_draw_target": avg("cpu_draw_target"),
            "mean_cpu_draw_shortfall": avg("cpu_draw_shortfall"),
            "mean_cpu_draw_failures": avg("cpu_draw_failures"),
            "mean_cpu_roof_visits": avg("cpu_roof_visits"),
            "mean_player_input_seconds": avg("player_input_seconds"),
            "minimum_100_complete_matches": n >= 100
        })
    return report

def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print(f"Missing telemetry: {path}", file=sys.stderr)
        return 2
    report = analyze(path)
    print("| Difficulty | Matches | Human win % | 95% CI | Search cells | CPU inspections | CPU shortfall | Sample gate |")
    print("|---|---:|---:|---|---:|---:|---|")
    for r in report["difficulties"]:
        low, high = r["human_win_rate_95ci"]
        print(f'| {r["difficulty"]} | {r["matches"]} | {100*r["human_win_rate"]:.1f}% '
              f'| {100*low:.1f}–{100*high:.1f}% | {r["mean_cpu_search_cells"]:.1f} '
              f'| {r["mean_cpu_inspections"]:.1f} | {r["mean_cpu_draw_shortfall"]:.1f} | {"PASS" if r["minimum_100_complete_matches"] else "NOT MET"} |')
    output = path.with_name("chalk_gaon_3d_human_playtest_analysis.json")
    output.write_text(json.dumps(report, indent=2))
    print(f"Report: {output}")
    if not all(r["minimum_100_complete_matches"] for r in report["difficulties"]):
        print("NOT CERTIFIED: fewer than 100 complete recorded sessions in one or more difficulties.")
    print("Recorded local sessions do not by themselves prove distinct human testers or balanced gameplay.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
