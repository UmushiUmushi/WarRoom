import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lua_env import LuaEnv  # noqa: E402


@pytest.fixture
def coords():
    return LuaEnv().load("Core/Coords.lua")


@pytest.fixture
def pins():
    return LuaEnv().load("Core/Pins.lua")
