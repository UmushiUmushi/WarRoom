# WarRoom

Map, minimap, routes and dungeon addon for World of Warcraft: Forever. GPL-3.0-or-later.

## Layout

| Path | What |
|---|---|
| `addons/WarRoom/` | Core addon: coordinates, position, pins, jobs, combat queue, saved data, data loading |
| `addons/WarRoom_Map/` | World map: WarRoom's map inside the game's world map window (module 2) |
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
tools/.venv/Scripts/python -m warroom_tools zones   # regenerate Data/Zones.lua (which zone owns the ground, outlines)
# (each command takes --build to pick a client build; by default the installed one's, which wago.tools may not have
#  yet the day the game updates: then pass the last one it has)
tools/.venv/Scripts/python -m warroom_tools worldart  # bake Media/Map and copy Data/Labels.lua (the world map's sheets)
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

`zones` takes the game's own borders: each 33-yard chunk of terrain names its area, which the game walks up to its
zone, and its world map shows that zone only where the zone's map lies. Stray ground tagged with a far zone's area
(a strip of Dun Morogh's western mountains is Westfall's) and unused ground of no area go to the zones around them,
so no land between zones is left out; places of no zone's (Gilneas) stay out. Hovering, clicking and the veil all
go by this one grid, so they agree with each other and with the game's coordinates. The continent paintings' hand-drawn
borders stray from it in places (the top of Redridge is Riverglades in game, Searing Gorge's border with Dun Morogh
runs straight). `zones` also bakes each zone's hover glow into `Media/Glow`, its veil into `Media/Veil` and the dark over each piece
of its map to explore into `Media/Fog` (the game's own drawing of the piece, as Veilmap darkens it, but all of a
continent's composed as one shape, so overlapping pieces show no darker bands; gitignored, about 36 MB). New texture
files: restart the game client once to see them. The cities keep their own ground; Zephras Isle's is the island as its own map paints it. `worldart` bakes the world map's sheets from those
cleaned copies: Azeroth's painting, each continent's cut down to its land and coast, and Zephras Isle's own map cut
down to the island; and copies OpenMap's table of the continents' and seas' names (MIT, its licence kept in the file),
which the world map letters live.

`addons/WarRoom/Media/Bake` and `addons/WarRoom/Media/Map` are not kept in git: after a fresh clone, run `mapart` and
`worldart` once before playing.

After `link`, edits show up in game on `/reload`.

In game:
- `/wr pos` prints your position and terrain tile.
- `M` opens the game's world map window with WarRoom's map in it, on you and close in: drag to pan, wheel to zoom,
  click a zone to frame it, right-click to go back out; the game's breadcrumb frames the map picked there. The zone
  the view is on stands out, everything round it softly dimmed, and the zone a click would go to glows under the
  pointer, as in the game's map. Places you haven't explored yet are darkened: still there to read.
  Zoomed out it is Azeroth's painting; in to a continent, the continent's own painting; on into the continent, the
  detailed painted map with the zones' big banners for their cities; nearing a city's zone, the city maps in place
  of those banners; closer than a city, the terrain. `/wr map` switches between WarRoom's map and the game's.
- The round button at the map's bottom left opens its settings: Transitions, a bar with a stop where each of those
  phases hands over to the next (drag the stops to move them, click the bar to zoom there; also `/wr transitions`),
  Terrain, the terrain at every zoom in place of the paintings (also `/wr terrain`), and Unexplored, the dark over
  places you haven't explored yet (also `/wr unexplored`).
- `/wr canvas` opens the Canvas test window (drag to pan, wheel to zoom; `/wr canvas help` for its options).
- `/wrprobe` runs the client checks; `/wrprobe tile` shows the minimap tile you stand on;
  `/wrprobe pins` lists other addons' map icons.
