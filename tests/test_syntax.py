"""Every addon Lua file must at least compile as Lua 5.1."""

import pytest
from lupa import luajit21

from lua_env import ADDONS, compile_file

FILES = sorted(p for p in ADDONS.rglob("*.lua") if "Libs" not in p.parts)


@pytest.mark.parametrize("path", FILES, ids=lambda p: str(p.relative_to(ADDONS)))
def test_compiles(path):
    lua = luajit21.LuaRuntime()
    chunk, err = compile_file(lua, path)
    assert chunk is not None, err


def test_toc_files_exist():
    for toc in ADDONS.rglob("*.toc"):
        for line in toc.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                assert (toc.parent / line.replace("\\", "/")).exists(), f"{toc.name}: missing {line}"
