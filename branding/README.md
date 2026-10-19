# HiveMinds brand

## The idea
Seven hexagons in a honeycomb. The six graphite cells around the edge are the agents. The one lit honey cell in the middle is the mind that ties them together: you, running the hive. It's calm, geometric and mostly black, to match the app's OLED look. One warm accent, nothing cartoonish.

## Files
| File | Use |
|---|---|
| `icon/HiveMinds.icns` | The app icon. `scripts/build-app.sh` copies it into `HiveMinds.app` as `AppIcon.icns`. |
| `icon/icon-1024.png`, `icon/icon.svg` | The app icon as a flat image, for READMEs, websites and release notes. |
| `icon/HiveMinds.iconset/` | Every size macOS needs (16 to 1024 px). `iconutil` builds the `.icns` from it. |
| `logo/mark-dark.svg`, `logo/mark-1024.png` | The mark alone, for dark backgrounds. |
| `logo/mark-light.svg` | The mark alone, for light backgrounds. |
| `logo/wordmark-dark.svg`, `logo/wordmark-light.svg` | Mark plus name, for headers and banners. |
| `scripts/render.swift`, `scripts/render.sh` | Draw all of the above from one set of shapes. |

Don't edit the generated files by hand. Change `scripts/render.swift`, run `branding/scripts/render.sh`, then rebuild the app.

## Colour
| Name | Hex | Where |
|---|---|---|
| Ink | `#000000` | Backgrounds. The app is black first. |
| Tile | `#1C1C1F` → `#050506` | Icon background, top to bottom. |
| Graphite | white at 7–16% | Agent cells; matches `Theme.surface` and `Theme.hairline` in the app. |
| Honey | `#F5B53D` | The one accent. Use it sparingly: a single lit thing per view. |
| Honey light / deep | `#FFD37A` / `#E8922A` | Gradient ends for the lit cell in the icon only. |
| Text | `#F2F2F2`, 60% for secondary | Words on dark backgrounds. |

## Type
SF Pro, the system font. The wordmark is SF Pro Display Semibold with slightly tight tracking. "Hive" is full strength and "Minds" is 60%, so the name reads as two words without a space.

## Use
- Keep the mark on black or near-black where you can. On light backgrounds use the `-light` files.
- Leave clear space around the mark of at least one cell's width.
- Don't recolour the agent cells, add outlines, rotate the mark or put it in a different shape.
- Honey is an accent, not a theme colour. Don't fill large areas with it.
