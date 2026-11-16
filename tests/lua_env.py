"""Runs WarRoom's pure-Lua files outside the game, in LuaJIT (Lua 5.1, as WoW uses) through lupa."""

from pathlib import Path

from lupa import luajit21

ROOT = Path(__file__).resolve().parents[1]
ADDONS = ROOT / "addons"
CORE = ADDONS / "WarRoom"

# A stand-in for Core's Init.lua: records fired events and runs deferred work at once.
_STUB = """
local ns = { WR = { fired = {} } }
function ns.WR.Fire(event, ...)
    local entry = { event = event, n = select("#", ...), ... }
    table.insert(ns.WR.fired, entry)
end
function ns.WR.Defer(fn) fn() end
return ns
"""


def compile_file(lua, path):
    """loadfile: (chunk, None) when the file compiles, else (None, message)."""
    result = lua.globals().loadfile(str(path))
    if isinstance(result, tuple):
        return result[0], result[1]
    return result, None


class LuaEnv:
    def __init__(self):
        self.lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        self.ns = self.lua.execute(_STUB)

    def load(self, relative):
        """Runs an addon file the way the game does: with (addonName, ns) as its `...`."""
        chunk, err = compile_file(self.lua, CORE / relative)
        if chunk is None:
            raise SyntaxError(err)
        chunk("WarRoom", self.ns)
        return self

    def eval(self, code):
        return self.lua.eval(code)

    def run(self, code):
        """Runs Lua with `ns`, `WR` and the loaded modules in scope."""
        prelude = "local ns, WR = ...; local Coords, Pins = ns.Coords, ns.Pins\n"
        fn = self.lua.execute("return function(...) " + prelude + code + " end")
        return fn(self.ns, self.ns.WR)

    def fired(self, event):
        return [e for e in self.ns.WR.fired.values() if e.event == event]
