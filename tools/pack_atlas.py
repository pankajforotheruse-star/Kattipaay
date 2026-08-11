#!/usr/bin/env python3
"""pack_atlas.py — build texture atlases from assets/sprites for Chalk Gaon.

Prompt 16 (Android optimization): 28 individual village sprites each become a
separate GPU texture + draw call. Packing them into one atlas per category
(environment, entities) turns ~28 texture binds into 2, and shrinks the PCK
(shared palette/headers, single file). The original PNGs are kept untouched —
the atlas is an ADDITIONAL packaging path (see assets/ASSETS.md).

Outputs (in assets/atlases/):
  environment_atlas.png  — all environment props
  entities_atlas.png     — all entity sprites
  <category>/<name>.tres — one AtlasTexture resource per sprite

Region layout is deterministic: shelves sorted by descending height, sprites
placed left-to-right, 2 px padding, final canvas padded to a multiple of 4
(ETC2/ASTC block alignment — Godot pads anyway, this just keeps regions clean).

Usage: python3 tools/pack_atlas.py
Requires: Pillow (pip install pillow).
"""
import json
import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")

REPO = Path(__file__).resolve().parent.parent
SPRITES = REPO / "assets" / "sprites"
OUT = REPO / "assets" / "atlases"
PAD = 2  # px between sprites

CATEGORIES = [
    ("environment", SPRITES / "environment"),
    ("entities", SPRITES / "entities"),
]


def pack_sprites(files: list[Path], candidate_widths=(256, 512, 1024, 2048)):
    """Shelf pack trying several canvas widths; returns the best layout.

    Best = smallest canvas area, then the layout whose long edge is shortest
    (roughly square-ish — friendlier for texture samplers than a tall strip).
    Returns (canvas_size, {name: (x, y, w, h)}).
    """
    items = []
    for f in files:
        with Image.open(f) as im:
            w, h = im.size
        items.append((f.stem, w, h))
    items.sort(key=lambda it: -it[2])  # tallest first
    max_w = max(it[1] for it in items)

    best = None  # (area, long_edge, canvas_w, canvas_h, regions)
    for shelf_w in candidate_widths:
        if shelf_w < max_w:
            continue
        regions = {}
        shelves = []  # [y, h, used_x]
        for name, w, h in items:
            placed = False
            for s in shelves:
                y, sh, used_x = s
                if h <= sh and used_x + w + PAD <= shelf_w:
                    regions[name] = (used_x + PAD, y + (sh - h), w, h)
                    s[2] = used_x + w + PAD
                    placed = True
                    break
            if not placed:
                y = (shelves[-1][0] + shelves[-1][1]) if shelves else 0
                shelves.append([y, h, PAD])
                regions[name] = (PAD, y, w, h)
        canvas_h = shelves[-1][0] + shelves[-1][1] if shelves else 0
        # Pad to multiple of 4 (compressed texture block alignment).
        cw, ch = (shelf_w + 3) & ~3, (canvas_h + 3) & ~3
        area = cw * ch
        long_edge = max(cw, ch)
        if best is None or area < best[0] or (area == best[0] and long_edge < best[1]):
            best = (area, long_edge, cw, ch, dict(regions))

    return (best[2], best[3]), best[4]


def build_atlas(category: str, src_dir: Path) -> None:
    files = sorted(src_dir.glob("*.png"))
    if not files:
        print(f"  {category}: no sprites, skipped")
        return
    (cw, ch), regions = pack_sprites(files)

    canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    for f in files:
        x, y, _, _ = regions[f.stem]
        with Image.open(f) as im:
            im = im.convert("RGBA")
        canvas.paste(im, (x, y))

    atlas_png = OUT / f"{category}_atlas.png"
    canvas.save(atlas_png, "PNG", optimize=True)
    print(f"  {category}: {len(files)} sprites -> {atlas_png.name} "
          f"{cw}x{ch} ({os.path.getsize(atlas_png)} bytes)")

    # AtlasTexture .tres per sprite.
    out_dir = OUT / category
    out_dir.mkdir(parents=True, exist_ok=True)
    for f in files:
        name = f.stem
        x, y, w, h = regions[name]
        tres = out_dir / f"{name}.tres"
        tres.write_text(
            f'[gd_resource type="AtlasTexture" load_steps=2 format=3]\n\n'
            f'[ext_resource type="Texture2D" '
            f'path="res://assets/atlases/{category}_atlas.png" id="1"]\n\n'
            f'[resource]\n'
            f'atlas = ExtResource("1")\n'
            f'region = Rect2({x}, {y}, {w}, {h})\n'
        )

    # Manifest for the docs / ASSETS.md.
    manifest = {"category": category, "atlas": f"{category}_atlas.png",
                "size": [cw, ch], "regions": regions}
    (OUT / f"{category}_atlas.json").write_text(
        json.dumps(manifest, indent=1))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for category, src_dir in CATEGORIES:
        build_atlas(category, src_dir)
    print("Done. .tres AtlasTexture resources written under assets/atlates/.")


if __name__ == "__main__":
    main()
