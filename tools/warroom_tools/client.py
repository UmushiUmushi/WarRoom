"""The local WoW install: where it is and which builds it has."""

import os
from pathlib import Path

DEFAULT_INSTALL = Path(r"C:\Program Files (x86)\World of Warcraft")
FOREVER_PRODUCT = "wowf"
FOREVER_FOLDER = "_forever_"


def find_install(path=None):
    """The install root (the folder holding .build.info): an argument, $WARROOM_WOW, or the default path."""
    root = Path(path or os.environ.get("WARROOM_WOW") or DEFAULT_INSTALL)
    if not (root / ".build.info").is_file():
        raise FileNotFoundError(f"no .build.info in {root}; pass --wow or set WARROOM_WOW")
    return root


def read_build_info(root):
    """Rows of .build.info as dicts; column names drop their type suffix ('Version!STRING:0' -> 'Version')."""
    lines = (root / ".build.info").read_text(encoding="utf-8").splitlines()
    header = [column.split("!")[0] for column in lines[0].split("|")]
    return [dict(zip(header, line.split("|"))) for line in lines[1:] if line.strip()]


def forever_build(root):
    """The installed WoW Forever version, e.g. '1.60.1.70938'."""
    for row in read_build_info(root):
        if row.get("Product") == FOREVER_PRODUCT and row.get("Active") == "1":
            return row["Version"]
    raise LookupError(f"no active {FOREVER_PRODUCT} build in {root / '.build.info'}")


def addons_dir(root):
    return root / FOREVER_FOLDER / "Interface" / "AddOns"
