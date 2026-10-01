# Precision Guidelines (TF3)

A Transport Fever 3 mod that shows guidelines while you build streets and tracks, similar to the guidelines and the Precision Engineering mod in Cities: Skylines.

While you drag a street or track, the mod looks at the open road ends and intersections within 100 m of the end you are dragging (build points in the middle of a road are ignored) and draws:

- **Extension lines** that continue every road at those nodes straight ahead.
- **Perpendicular lines** at those nodes, plus extension, perpendicular and **45° diagonals** at the node you started dragging from.
- **Crossing markers** where two guidelines intersect.
- **Perfect curve targets**: for each guideline, the point where a circular arc that leaves your drag start in its current direction would meet the guideline tangentially. The arc is drawn in orange and its end point is marked.

Colours:

| Colour | Meaning |
|--------|---------|
| Blue | Guideline near the dragged end |
| Green | The dragged end is on the guideline (within 0.3 m) |
| Gold | On the guideline **and** arriving parallel to it, or on a perfect curve target: the new segment continues the guideline seamlessly |
| Orange | Perfect curve preview and target |

Only guidelines within 40 m of the dragged end are shown, at most 8 at a time, so the view stays clean. Line width scales with the camera distance.

The mod only draws. It does not move or snap your segments, and it does not change what gets built.

## How it works

`content/guidelines/guidelines.gs.lua` registers a game script. Its GUI part (`guidelines.script.tl`) listens to the builder's `builder.proposalCreate` event, which fires with the current street/track proposal while you drag:

1. The new segments of the proposal are chained together. The open end closest to the mouse is the dragged end, the other end is the drag start.
2. Existing segments near the dragged end are read with `api.engine.util.octree.findEntitiesInCircle`. A segment end that is an open end or an intersection (`api.engine.system.streetSystem.getNodeSegments` returns 1 or 3+ segments) within 100 m gives an extension line along its tangent and a perpendicular line.
3. For the curve targets, the circle that touches the drag start's direction and a guideline is solved directly (two candidate radii per side). Only arcs up to 180° are used.
4. The shapes are drawn as ground overlays through `api.gui.mission.setZone`, or as dotted lines through the engine's debug points. You can choose in the mod's settings ("Guideline renderer").

The guidelines are removed when the segment is built. The builder sends no event when a drag is cancelled, but while dragging every mouse move produces a new proposal. So when the mouse moves on the terrain and no proposal follows within 0.15 s, the drag has ended and the guidelines are removed.

## Status

Tested in-game: the ground overlay renderer works. Still to verify:

- The debug point API (`api.util.debug.draw`) is bound in the release build. It is missing from the type definitions.
- A curve that ends on a gold target arrives tangentially. This depends on the builder making circular curves when the start direction is fixed.

The game log (`<Steam>\userdata\<your Steam ID>\3493540\local\crash_dump\stdout.txt`) shows lines starting with `[Precision Guidelines]`: the selected renderer and the first error, if any.

## Installation

Copy `mod/glcrte_precision_guidelines_1` into your local TF3 mods folder:

```
<Steam>\userdata\<your Steam ID>\3493540\local\mods\
```

Then enable the mod in the game's mod menu.

`tools/deploy.ps1` copies the mod into the `staging_area` folder next to `mods`, where it shows up under "My Mods" in the in-game Mod Manager for uploading to mod.io. `tools/deploy.ps1 -Target mods` installs it as a plain local mod instead. Either way the copy in the other folder is removed, so the mod ID never exists twice.

## Development

```
pip install lupa
python tools/check.py [--game "<TF3 install dir>"]
```

This checks that `_content.json` lists every file in `content/`, type-checks all `.tl` scripts against the game's definitions in `api/tealdef` and `base/tealdef`, and runs the tests in `tests/`. The Teal compiler is downloaded into `tools/.cache` on first use.

Tuning values (search radius, show distance, tolerances, colours) are at the top of `guidelines.script.tl`.
