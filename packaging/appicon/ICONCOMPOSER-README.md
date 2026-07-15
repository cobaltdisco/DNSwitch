# DNSwitch — Icon Composer layers (macOS 26)

Built to Apple's Icon Composer rules: **no mask baked in, full 1024 canvas, flat opaque
fills, no shadows or highlights.** All material effects are applied in Icon Composer.

```
layers/
  1_stars.svg  1_stars.png   # 10 stars, back layer
  2_hat.svg    2_hat.png     # witch hat, front layer
preview/
  approx-default.png  approx-dark.png  approx-mono.png  approx-all.png
```

Both layers are solid white on transparent — set the real fills in the inspector
(this is the workflow Apple's docs and Icon Composer's per-mode Color picker assume).
The numeric prefix drives Z-order: `1_` is behind `2_`.

## Geometry

- Canvas 1024 × 1024, full bleed, no mask
- Hat: 620 wide, centre (512, 530) — content bbox `(202, 239, 822, 821)`
- Stars: 10, radius 11–41, content bbox `(101, 113, 920, 720)`
- Verified: zero star/hat overlap at 26 px clearance; nothing clipped by the enclosure shape

## Fills to set in Icon Composer

Background is a **document setting**, not a layer — select the canvas in the sidebar,
then set Fill → Gradient. This keeps you at 2 of the 4 allowed layers.

| | Background gradient | `1_stars` | `2_hat` |
|---|---|---|---|
| **Default** | `#8B5CF6` → `#4C1D95` → `#1E1B4B` | `#FDE68A` | `#FFFFFF` |
| **Dark** | `#4C1D95` → `#2E1065` → `#0B0A1F` | `#EAB308` | `#F4F4F5` |
| **Mono** | — (system) | white @ 55 % opacity | `#FFFFFF` @ 100 % |

Mono matters: Icon Composer derives mono brightness from your Default colours, so a
mid-value amber would come out muddy grey. Setting the hat to pure white and dropping
the stars to a lower opacity gives the hierarchy explicitly.

## Steps

1. New icon in Icon Composer → drag both files from `layers/` in.
2. Select the canvas → Fill → Gradient → enter the stops above.
3. Per layer, per appearance mode: pick the mode at the bottom of the canvas, pick the
   matching entry in the inspector's **Color** menu, then set Fill.
4. Leave Liquid Glass on for both layers. Specular should sort itself out automatically —
   if you want to force it, the hat wants highlights *inside*, the stars *outside*.
5. Save as `AppIcon.icon` at the project root, then set **App Icon Set Name** in target
   settings to `AppIcon` (no extension).

## Two known traps

- **SVG may not pick up specular.** Several people report importing SVG and getting no
  glass highlight even with Specular on; PNG works because Icon Composer computes edges
  from the raster instead. Both formats are in `layers/` — start with SVG, and if the
  highlights don't appear, swap in the PNGs.
- **Icon Composer reinterprets SVG effects.** It only reliably handles flat fills, which
  is why these layers have no gradients. Anything fancier belongs in the inspector.

## Previews

`preview/*.png` are hand-rolled approximations to check composition only. They are not
what Icon Composer will render — no refraction, no real specular, and the enclosure
radius is an estimate. Judge composition from them, not material.

## Older macOS

`actool` generates a backwards-compatible `.icns` from the `.icon` file at build time,
so pre-Tahoe is covered without extra work. The baked `.icns` set from the earlier
`DNSwitch-icons` bundle is only needed if you want the old inset-squircle look preserved
verbatim on Sequoia and earlier — the two shapes have different corner radii.

## If you want a third layer

The stars could split into `1_stars-far` (small) and `2_stars-near` (large) for
independent refraction strength, pushing the hat to `3_hat`. Still under the 4-layer cap,
and it buys real parallax depth. Say the word and I'll re-cut the exports.
