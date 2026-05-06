# Spatial Asset Inventory

This phase prepares editable source assets and app asset scaffolding without locking in final production artwork.

## Brand Source Assets

- `Resources/Brand/spatial-logo.svg`
  - Figure-8 mark with orbital ellipse and accent dot.
- `Resources/Brand/menubar-active.svg`
  - Violet active-state menu bar glyph.
- `Resources/Brand/menubar-bypassed.svg`
  - Neutral bypassed-state menu bar glyph.
- `Resources/Brand/menubar-processing.svg`
  - Processing glyph with offset accent orbit.
- `Resources/Brand/app-icon-placeholder.svg`
  - Circular background treatment for the future app icon.

## Xcode Asset Catalog

- `Resources/Assets.xcassets/AppIcon.appiconset`
  - Placeholder container for final exported icon sizes.
- `Resources/Assets.xcassets/Accent.colorset`
  - Primary accent token for app-level asset usage.
- `Resources/Assets.xcassets/AccentLight.colorset`
  - Secondary accent token.
- `Resources/Assets.xcassets/ActiveGreen.colorset`
  - Success / power-on token.

## UI Primitive Coverage

- Knob visuals are represented in code by `KnobPlaceholderView`.
- Visualizer styling is represented in code by `VisualizerBarsView`.
- Card surfaces, pills, and section labels are tokenized in `Shared/UI`.

## Next Asset Pass

- Export final PDF or SVG glyphs into the asset catalog.
- Add menu bar template-compatible monochrome variants.
- Produce full app icon sizes for notarized distribution.
- Replace placeholder knob and orbit geometry with polished vectors.
