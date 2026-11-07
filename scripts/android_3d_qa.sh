#!/usr/bin/env bash
# Android-first QA harness for the protected 3D feature branch.
# Usage: bash scripts/android_3d_qa.sh build [low|balanced|high]
#        bash scripts/android_3d_qa.sh collect [output-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-build}"
package="com.chalkgaon.ghostlines"
if [[ "$mode" == "build" ]]; then
  quality="${2:-balanced}"
  case "$quality" in low|balanced|high) ;; *) echo "Quality must be low, balanced or high"; exit 2;; esac
  godot_bin="${GODOT_BIN:-godot}"
  command -v "$godot_bin" >/dev/null || { echo "Godot 4.4 executable not found: $godot_bin"; exit 2; }
  [[ -f export_presets.cfg ]] || { echo "Android export preset missing"; exit 2; }
  mkdir -p build
  original_project="$(mktemp)"
  original_export="$(mktemp)"
  cp project.godot "$original_project"
  cp export_presets.cfg "$original_export"
  cleanup() {
    cp "$original_project" project.godot
    cp "$original_export" export_presets.cfg
    rm -f "$original_project" "$original_export"
  }
  trap cleanup EXIT
  python3 - "$quality" <<'PY'
import pathlib, sys
quality=sys.argv[1]
p=pathlib.Path("project.godot")
s=p.read_text()
s=s.replace('run/main_scene="res://scenes/main.tscn"',
            'run/main_scene="res://scenes/3d/game_world_3d.tscn"')
assert 'run/main_scene="res://scenes/3d/game_world_3d.tscn"' in s
s=s.replace('[chalk_gaon]', '[chalk_gaon]\n3d_profile_enabled=true\n3d_quality_tier="'+quality+'"\n3d_sound_enabled=true\n3d_art_quality='+('0' if quality=='low' else '2' if quality=='high' else '1'))
p.write_text(s)
e=pathlib.Path("export_presets.cfg")
s=e.read_text().replace('gradle_build/use_gradle_build=true','gradle_build/use_gradle_build=false')
s=s.replace('package/show_as_launcher_app=false','package/show_as_launcher_app=true')
e.write_text(s)
PY
  "$godot_bin" --headless --editor --path . --quit
  "$godot_bin" --headless --path . --export-debug Android "build/chalk-gaon-3d-qa-${quality}.apk"
  test -s "build/chalk-gaon-3d-qa-${quality}.apk"
  echo "3D Android QA APK: build/chalk-gaon-3d-qa-${quality}.apk"
  echo "Temporary main-scene/export changes were not committed; cleanup restores originals."
elif [[ "$mode" == "collect" ]]; then
  command -v adb >/dev/null || { echo "adb is required"; exit 2; }
  output="${2:-build/android-qa-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$output"
  adb devices -l > "$output/adb-devices.txt"
  adb shell getprop > "$output/device-properties.txt"
  adb shell dumpsys gfxinfo "$package" > "$output/gfxinfo.txt" || true
  adb shell dumpsys meminfo "$package" > "$output/meminfo.txt" || true
  adb shell dumpsys thermalservice > "$output/thermalservice.txt" || true
  adb shell dumpsys battery > "$output/battery.txt" || true
  for file in chalk_gaon_3d_perf.csv chalk_gaon_3d_perf_summary.json chalk_gaon_3d_match_telemetry.jsonl chalk_gaon_3d_qa_screenshot.png; do
    adb exec-out run-as "$package" cat "files/$file" > "$output/$file" 2>/dev/null || rm -f "$output/$file"
  done
  echo "Collected available Android QA evidence to $output"
  echo "F9 exports CSV/JSON; F10 captures a screenshot in the QA build."
  echo "Thermal service fields vary by OEM. Measure a sustained 30-minute session."
else
  echo "Usage: $0 build [low|balanced|high] | collect [output-directory]"
  exit 2
fi
