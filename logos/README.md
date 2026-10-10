# RotationAI logo options

All five options preserve the creator's [reference](https://fxumiqjngmabtgvruvka.supabase.co/storage/v1/object/public/forum-attachments/posts/mv2ue731-rff8pr.webp): clockwise rotation arrows, an ascending chart, neon green and emerald on a green-black background. Each delivered file is a square, fully opaque 1024×1024 PNG.

1. **[logo-1.png](logo-1.png) — Mascot:** a friendly AI face with a rotating arrow silhouette and three rising chart bars as its crown.
2. **[logo-2.png](logo-2.png) — Geometric symbol:** two broad rotation arrows enclosing a three-bar growth chart; selected as the wallet logo at [artifacts/logo.png](../artifacts/logo.png).
3. **[logo-3.png](logo-3.png) — Lettermark:** bold custom RAI lettering with a rotation-arrow R, triangular A, rising-bar I, and sweeping arrow underline.
4. **[logo-4.png](logo-4.png) — Minted emblem:** an emerald metal coin carrying the rotation-and-growth relief, with a bright lime bevel.
5. **[logo-5.png](logo-5.png) — Meme illustration:** a wildly excited spinning AI face with oversized eyes, a laughing grin, and ascending chart blocks.

**Production:** the built-in image generation tool (gpt-image) drew six drafts in total: one for each of the five options and one replacement geometric draft. Five were kept. The first geometric draft was rejected because its background was transparent and its edges had visible fringing. Image generation replaced that background with an opaque green-black field and cleaned the edges. The selected wallet mark therefore took two drafts.

The logos were generated as raster artwork, not drawn with code. `scripts/prepare_logos.py` only resampled the five option files from 1254×1254 to the required 1024×1024, without adding shapes, text, or backgrounds. `artifacts/logo.png` retains the selected original generated 1254×1254 PNG unchanged, including its embedded generation provenance. The [complete prompt set](prompts.md) records the generation instructions.

**Small-size review:** `python3 scripts/check_artwork.py` validates dimensions, opacity and five distinct outputs, confirms that `artifacts/logo.png` is the generated original of option 2, and makes a disposable preview in `test/scratch/logo-review.png`. Columns show options 1–5; rows show 64 px on light, 64 px on dark, 32 px on light, and 32 px on dark. Each cell pairs the square with its circular crop. The lettering belongs only to option 3, and the minted rim belongs only to option 4; the selected wallet mark has neither.
