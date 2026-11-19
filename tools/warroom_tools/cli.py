"""warroom <command>: the WarRoom data tools."""

import argparse

from . import client, link, mapart, tiles, wago, worldart, zones


def cmd_client_info(args):
    root = client.find_install(args.wow)
    print(f"install  {root}")
    for row in client.read_build_info(root):
        print(f"  {row.get('Product', '?'):6} {row.get('Version', '?'):16} active={row.get('Active')}")
    print(f"forever  {client.forever_build(root)}")
    print(f"addons   {client.addons_dir(root)}")


def cmd_db2(args):
    build = args.build or client.forever_build(client.find_install(args.wow))
    rows = wago.read_db2(args.table, build, refresh=args.refresh)
    print(f"{args.table} @ {build}: {len(rows)} rows -> {wago.fetch_db2(args.table, build)}")
    if rows:
        print("columns: " + ", ".join(rows[0].keys()))


def cmd_tiles(args):
    build = args.build or client.forever_build(client.find_install(args.wow))
    summary, keys = tiles.build(build, refresh=args.refresh)
    for map_id, (name, count, edges, dropped) in summary.items():
        print(f"{map_id:5} {name:28} {count:5} tiles, {edges:4} on the edge, {dropped:4} left out (open ocean, islands of no zone, placeholders)")
    print(f"{len(keys)} fade masks -> {tiles.MASK_DIR}")
    print(f"tile table -> {tiles.DATA_FILE}")


def cmd_zones(args):
    build = args.build or client.forever_build(client.find_install(args.wow))
    for map_id, (name, count, runs, points) in zones.build(build, refresh=args.refresh).items():
        print(f"{map_id:5} {name:28} {count:3} maps, {runs:5} runs, {points:6} outline points")
    print(f"zone table -> {zones.DATA_FILE}")


def cmd_worldart(args):
    build = args.build or client.forever_build(client.find_install(args.wow))
    for name, what in worldart.build(build, refresh=args.refresh):
        print(f"{name:22} {what}")
    print(f"sheets -> {worldart.OUT_DIR}")


def cmd_mapart(args):
    build = args.build or client.forever_build(client.find_install(args.wow))
    summary, cities = mapart.build(build, refresh=args.refresh)
    for map_id, counts in sorted(summary.items()):
        print(f"continent {map_id}: " + ", ".join(f"{n} {level} tiles" for level, n in counts.items()))
    print(f"cities drawn live: {', '.join(str(c) for c in sorted(cities))}")
    print(f"map art -> {mapart.DATA_FILE}")
    print(f"tiles -> {mapart.BAKE_DIR}")


def cmd_link(args):
    addons_dir = client.addons_dir(client.find_install(args.wow))
    for name, state in link.link_addons(addons_dir, unlink=args.unlink, dry_run=args.dry_run):
        print(f"{name:20} {state}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="warroom", description=__doc__)
    parser.add_argument("--wow", help="WoW install root (holding .build.info); default $WARROOM_WOW or the usual path")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("client-info", help="show the installed builds").set_defaults(fn=cmd_client_info)

    db2 = sub.add_parser("db2", help="download (and cache) a game data table from wago.tools")
    db2.add_argument("table", help="DB2 table name, e.g. UiMap")
    db2.add_argument("--build", help="client build (default: the installed Forever build)")
    db2.add_argument("--refresh", action="store_true", help="download again even if cached")
    db2.set_defaults(fn=cmd_db2)

    tl = sub.add_parser("tiles", help="write the terrain tile table and coast fade masks for the Canvas")
    tl.add_argument("--build", help="client build (default: the installed Forever build)")
    tl.add_argument("--refresh", action="store_true", help="download the file lists again")
    tl.set_defaults(fn=cmd_tiles)

    zn = sub.add_parser("zones", help="write which zone owns each patch of ground, and the zones' outlines")
    zn.add_argument("--build", help="client build (default: the installed Forever build)")
    zn.add_argument("--refresh", action="store_true", help="download the tables again")
    zn.set_defaults(fn=cmd_zones)

    wa = sub.add_parser("worldart", help="bake the world map's painted sheets and copy its lettered names")
    wa.add_argument("--build", help="client build (default: the installed Forever build)")
    wa.add_argument("--refresh", action="store_true", help="download the tables again")
    wa.set_defaults(fn=cmd_worldart)

    ma = sub.add_parser("mapart", help="bake the painted map for the Canvas (OpenMap's renderer over the game's art) into tiles")
    ma.add_argument("--build", help="client build (default: the installed Forever build)")
    ma.add_argument("--refresh", action="store_true", help="download the tables again")
    ma.set_defaults(fn=cmd_mapart)

    ln = sub.add_parser("link", help="link the repo's addons into the game's AddOns folder")
    ln.add_argument("--unlink", action="store_true", help="remove the links instead")
    ln.add_argument("--dry-run", action="store_true", help="only say what would happen")
    ln.set_defaults(fn=cmd_link)

    args = parser.parse_args(argv)
    args.fn(args)
    return 0
