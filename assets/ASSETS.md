# Chalk Gaon — Village Art Assets

AI-generated stylized cartoon art (flat-color painterly, **no realism**, no photo
textures). Palettes per GDD §2 (warm terracotta/ochre/sand village tones).

## Ground texture
- `backgrounds/village_ground_2048x1536.png` — 2048×1536 px, ~1.0 MB, 80-color palette.
  Top-down Dholpur ground: dust roads/galis, central chowk (well ring), wheat fields
  (top), pond + ghat (bottom). **No buildings baked in** — all houses/temple/wall are
  separate sprites so the building-collapse event can remove them. Place the ground as
  a `Sprite2D`/`TextureRect` at z=0.

## Environment props (`sprites/environment/`, ≤256 px, ≤50 KB each, RGBA)
| File | Use |
|---|---|
| house_01…08.png | 8 kachcha mud houses (01–04 unique, 05–08 mirrored variants). Removable sprites — place above ground, add `StaticBody2D` for collision. |
| house_collapsed.png | Pre-crumbled house (swap in for the collapse event). |
| temple.png | Small temple, bell on front. Anchor the interaction area at its base. |
| temple_bell.png | Temple bell as separate small sprite (interactable anchor, e.g. Ghanti item). |
| banyan_canopy.png | Tree canopy — **separate from trunk so wind sway animates it**. |
| banyan_trunk.png | Banyan trunk + roots (stays still; canopy/trunk both at banyan location). |
| wall_segment_a/b/c.png | Village wall strips, cut from one long wall with ~8% end overlap — place end-to-end to rebuild it. |
| charpai.png | Rope bed prop. |
| clay_pot_a/b/c.png | 3 clay pot variants (matkas). |
| well.png | Well (top-down opening) — 6 fixed lantern locations include the chowk well. |
| scarecrow.png | Field scarecrow prop. |

## Entities (`sprites/entities/`, ≤96 px, ≤20 KB each, RGBA)
| File | Use |
|---|---|
| goat_idle.png / goat_walk.png / goat_bleat.png | Ambient goat, 3 poses. |
| cow.png | Village cow (optional ambient; prototype cow may stay procedural). |
| lantern.png | Lantern for the 6 fixed lantern points (attach `PointLight2D`). |
| chalk_stick.png | Chalk pickup, glowing, rarity-agnostic base (tint per rarity). |

## Notes for the developer
- All sprites RGBA with transparent backgrounds, quantized palettes (64–96 colors),
  PNG optimize — mobile-safe.
- Houses are drawn slightly-angled top-down (roof + front wall visible) so they read
  as buildings on the flat 90° ground; keep them on a z layer above the ground.
- Wall segments have a small overlap region for tiling; trim if seam is visible.
- Raw 1024px source images and processing scripts: `/home/team/shared/artwork/`
  (outside repo; not committed).
