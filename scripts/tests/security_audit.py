#!/usr/bin/env python3
"""Kattipaay CI security/configuration baseline (Python stdlib only).

This is a deterministic security *gate*, not a proof of no vulnerabilities.
GDScript has no generally supported CodeQL database. In particular this
cannot replace Nakama/RPC authorization reviews, a dependency audit of
binary addons, Android device permission verification or penetration tests.

Run: python3 scripts/tests/security_audit.py
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
failures: list[str] = []
checks = 0

def require(ok: bool, reason: str) -> None:
    global checks
    checks += 1
    if not ok:
        failures.append(reason)

def read(relative: str) -> str:
    p = ROOT / relative
    require(p.is_file(), f"Required project file missing: {relative}")
    return p.read_text(encoding="utf-8") if p.is_file() else ""

def main() -> int:
    project = read("project.godot")
    config = read("export_presets.cfg")
    workflow = read(".github/workflows/godot.yml")
    read("scripts/networking/AuthorityGuard.gd")
    read("scripts/autoload/NetworkManager.gd")
    require('config/features=PackedStringArray("4.4"' in project,
            "Godot 4.4 configuration has drifted")
    require('run/main_scene="res://scenes/main.tscn"' in project,
            "Main game scene missing from project settings")
    require("pull_request:" in workflow, "Merge gate must run on PRs")
    require("permissions:\n  contents: read" in workflow,
            "CI default token permission must be read-only")
    require("pull_request_target:" not in workflow,
            "Untrusted PR code must not run in privileged pull_request_target")
    require(not re.search(r"permissions:[\s\S]{0,50}contents:\s*write", workflow),
            "No write-scoped workflow tokens")
    require("secrets." not in workflow, "Untrusted PR CI must not consume repo secrets")
    require("needs: [static-check, unit-tests, component-tests, playable-smoke-test, security-check]" in workflow,
            "Merge regression gate must depend on all independent jobs")
    for key in ("access_fine_location", "nearby_wifi_devices",
                "access_wifi_state", "change_wifi_state", "change_network_state"):
        require(f"permissions/{key}=false" in config,
                f"Android export unexpectedly enables unnecessary permission {key}")
    for key in ("permissions/internet=true", "permissions/access_network_state=true"):
        require(key in config, f"Expected multiplayer-ready Android permission missing: {key}")

    suffixes = {".gd", ".tscn", ".tres", ".cfg", ".yml", ".py", ".md", ".json", ".gdshader"}
    excluded = {".git", ".godot", ".import", "__pycache__"}
    paths = [p for p in ROOT.rglob("*") if p.is_file()
             and p.suffix in suffixes and not (set(p.parts) & excluded)]
    # Look for definite red flags only; pattern scanning is inherently incomplete.
    secret_rules = [
        (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "embedded private key"),
        (re.compile(r"(?i)(?:sk_live_|rk_live_)[0-9A-Za-z]{12,}"), "live payment secret"),
        (re.compile(r"gh[pousr]_[A-Za-z0-9_]{30,}"), "embedded GitHub token"),
        (re.compile(r"(?i)-----BEGIN PGP PRIVATE KEY BLOCK-----"), "embedded PGP secret"),
    ]
    for path in paths:
        relative = path.relative_to(ROOT).as_posix()
        content = path.read_text(encoding="utf-8", errors="replace")
        # Our own scanner necessarily contains example patterns. Exclude its
        # static rules from the content scan, but still validate every game
        # asset, workflow and other test/script in this repository.
        if path.resolve() != Path(__file__).resolve():
            for pattern, label in secret_rules:
                require(pattern.search(content) is None, f"{relative}: potential {label}")
        if path.suffix == ".gd":
            for pattern, label in [
                (r"\bOS\.execute\s*\(", "process execution"),
                (r"\bJavaScriptBridge\.eval\s*\(", "dynamic JavaScript evaluation"),
                (r"\bExpression\.execute\s*\(", "dynamic code evaluation"),
            ]:
                # Match executable statements, not doc comments or quoted examples.
                for line_no, line in enumerate(content.splitlines(), 1):
                    if line.lstrip().startswith("#"):
                        continue
                    require(re.search(pattern, line) is None,
                            f"{relative}:{line_no}: review unsafe {label}")
    print(f"SECURITY_AUDIT: {'PASS' if not failures else 'FAIL'} checks={checks} files={len(paths)}")
    for failure in failures:
        print("SECURITY_AUDIT: FAIL " + failure)
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
