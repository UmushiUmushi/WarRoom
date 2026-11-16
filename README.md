# WarRoom

Map, minimap, routes and dungeon addon for World of Warcraft: Forever. GPL-3.0-or-later.

## Layout

| Path | What |
|---|---|
| `addons/WarRoom/` | Core addon: coordinates, position, pins, jobs, combat queue, saved data, data loading |
| `addons/WarRoom_Probe/` | Development checks (`/wrprobe`). Not for release |
| `tools/warroom_tools/` | Python tools that build data files from the game client |
| `tests/` | Unit tests for the pure-Lua parts (run in LuaJIT through `lupa`) and the tools |

Feature modules (`WarRoom_Map`, `WarRoom_Minimap`, ...) are separate load-on-demand addons that use the global
`WarRoom` from Core.

## Development

```sh
python -m venv tools/.venv
tools/.venv/Scripts/python -m pip install -e ".[dev,art]"   # art: Pillow, numpy and scipy, for the game's images
tools/.venv/Scripts/python -m pytest              # tests
tools/.venv/Scripts/python -m warroom_tools client-info
tools/.venv/Scripts/python -m warroom_tools link   # link addons/ into the game's AddOns (--unlink to undo)
tools/.venv/Scripts/python -m warroom_tools tiles   # regenerate Data/Tiles.lua and Media/Fade (after a game patch)
tools/.venv/Scripts/python -m warroom_tools mapart  # bake Data/MapArt.lua and Media/Bake (the painted map)
```

`tiles` and `mapart` download game files from wago.tools on their first run: the minimap images (kept in
`tools/.cache/casc`) and every terrain file of the continents (about 1 GB, read for their area IDs and heights and
not kept; what they say is cached in `tools/.cache/areas`). Later runs use the caches.

`mapart` stitches the game's zone maps into one painted map with [OpenMap](https://github.com/openmap-world/openmap)'s
renderer (MIT licence): it checks out a pinned commit of OpenMap into `tools/.cache/openmap`, reads the map art from
the installed game (or wago.tools) and bakes about 520 tiles at three sizes (6, 12 and 24 px a map unit; the finest
only over the small zones), about 140 MB. Several renderers run side by side (a first run took about 6 minutes on 8), and
the pictures are kept in `tools/.cache/bake`, so a second run only draws and encodes what changed. The sea is not
baked: the Canvas tiles OpenMap's sea paper and coastal hatching live, under the tiles' clear sea.

`addons/WarRoom/Media/Bake` is not kept in git: after a fresh clone, run `mapart` once before playing.

After `link`, edits show up in game on `/reload`.

In game:
- `/wr pos` prints your position and terrain tile.
- `/wr canvas` opens the Canvas test window (drag to pan, wheel to zoom; `/wr canvas help` for its options).
- `/wrprobe` runs the client checks; `/wrprobe tile` shows the minimap tile you stand on;
  `/wrprobe pins` lists other addons' map icons.
