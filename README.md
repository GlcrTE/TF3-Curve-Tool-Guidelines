# Precision Guidelines (TF3)

A Transport Fever 3 mod that shows guidelines while you build streets and tracks, similar to the guidelines in Cities: Skylines.

While you drag a street or track, the mod looks at the open road ends within 300 m and the intersections within 100 m of the end you are dragging (build points in the middle of a road are ignored) and draws:

- **Extension lines** that continue every road at those nodes straight ahead, pointing away from the road.
- **Perpendicular lines** at those nodes, to both sides.

Guidelines are one-way rays starting at the node, so they never run back over the road they come from. A ray that would run along another road leaving the same node (within 20°) is left out, e.g. the continuation of a road straight through a crossing. Each node shows only its one guideline closest to the cursor, since a new road can connect to a node only once.

The road you are extending (every road attached to the node you start dragging from, up to its next intersection or open end) gives no guidelines, and neither does the intersection or open end where it stops. While the dragged end is attached to an existing street or node, no guidelines are shown at all.
- **Crossing markers** where two guidelines intersect.

Colours:

| Colour | Meaning |
|--------|---------|
| Blue | Guideline near the dragged end |
| Green | The dragged end is on the guideline (within 0.3 m) |
| Gold | On the guideline **and** arriving parallel to it: the new segment continues the guideline seamlessly |

Only guidelines within 40 m of the dragged end are shown, at most 8 at a time, so the view stays clean. Line width scales with the camera distance.

The mod only draws. It does not move or snap your segments: the builder event lets scripts report errors, but changes to its proposal have no effect (tested in-game).

## How it works

`content/guidelines/guidelines.gs.lua` registers a game script. Its GUI part (`guidelines.script.tl`) listens to the builder's `builder.proposalCreate` event, which fires with the current street/track proposal while you drag:

1. The new segments of the proposal are chained together. The open end closest to the mouse is the dragged end, the other end is the drag start.
2. Existing segments near the dragged end are read with `api.engine.util.octree.findEntitiesInCircle`. A segment end that is an open end within 300 m or an intersection within 100 m (`api.engine.system.streetSystem.getNodeSegments` returns 1 or 3+ segments) gives an extension line along its tangent and a perpendicular line.
3. The shapes are drawn as ground overlays through `api.gui.mission.setZone`, or as dotted lines through the engine's debug points. You can choose in the mod's settings ("Guideline renderer").

The guidelines are removed when the segment is built. The builder sends no event when a drag is cancelled, but while dragging every mouse move produces a new proposal. In the game log a proposal followed every cursor movement within 3-5 ms. So when the cursor moves and no proposal follows within 0.1 s, the drag has ended (right-click, Esc, tool closed) and the guidelines are removed. Set `debugLog = true` in `guidelines.script.tl` to log builder events, cursor positions and clear decisions.

## Status

Tested in-game: the ground overlay renderer works. Still to verify:

- The debug point API (`api.util.debug.draw`) is bound in the release build. It is missing from the type definitions.

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
