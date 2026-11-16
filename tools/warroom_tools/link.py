"""Links the repo's addons into the game's AddOns folder (directory junctions), so edits show up on /reload."""

import os
import subprocess
from pathlib import Path

REPO_ADDONS = Path(__file__).resolve().parents[2] / "addons"


def _points_to(link, target):
    try:
        return Path(os.readlink(link)).resolve() == target.resolve()
    except OSError:
        return False


def link_addons(addons_dir, unlink=False, dry_run=False):
    """Creates (or removes) one junction per repo addon. Never touches a real folder of the same name."""
    results = []
    for source in sorted(p for p in REPO_ADDONS.iterdir() if p.is_dir()):
        link = addons_dir / source.name
        if unlink:
            if link.is_junction() and _points_to(link, source):
                if not dry_run:
                    os.rmdir(link)  # removes the junction only, not what it points to
                results.append((source.name, "unlinked"))
            else:
                results.append((source.name, "not linked"))
            continue
        if link.is_junction():
            state = "already linked" if _points_to(link, source) else "linked elsewhere, left alone"
            results.append((source.name, state))
        elif link.exists():
            results.append((source.name, "a real folder is there, left alone"))
        else:
            if not dry_run:
                subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(source)], check=True, capture_output=True)
            results.append((source.name, "linked"))
    return results
