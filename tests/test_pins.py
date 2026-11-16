def add(env, x, y, category="vendor", extra=""):
    return env.run(f"return Pins.Add({{ continent = 0, x = {x}, y = {y}, category = '{category}' {extra} }})")


def query(env, surface="map", x1=-1000, y1=-1000, x2=1000, y2=1000, zoom="nil", layer="nil"):
    ids = env.run(
        f"local out = Pins.Query(0, {x1}, {y1}, {x2}, {y2}, '{surface}', {zoom}, {layer}) "
        "local ids = {} for i, p in ipairs(out) do ids[i] = p.id end table.sort(ids) return table.concat(ids, ',')"
    )
    return [int(i) for i in ids.split(",")] if ids else []


def test_add_query_remove(pins):
    a = add(pins, 10, 10)
    b = add(pins, 600, -600)
    assert query(pins) == [a, b]
    assert query(pins, x1=0, y1=0, x2=100, y2=100) == [a]
    assert pins.run(f"return Pins.Remove({a})") is True
    assert query(pins) == [b]
    assert pins.run("return Pins.Count()") == 1


def test_query_rectangle_corners_any_order(pins):
    a = add(pins, 50, 50)
    assert query(pins, x1=100, y1=100, x2=0, y2=0) == [a]


def test_other_continent_not_returned(pins):
    pins.run("Pins.Add({ continent = 1, x = 0, y = 0, category = 'vendor' })")
    assert query(pins) == []


def test_move_between_buckets(pins):
    a = add(pins, 10, 10)
    pins.run(f"Pins.Move({a}, 0, 900, 900)")
    assert query(pins, x1=0, y1=0, x2=100, y2=100) == []
    assert query(pins, x1=800, y1=800, x2=1000, y2=1000) == [a]


def test_clear_by_source(pins):
    add(pins, 1, 1, extra=", source = 'Gathering'")
    keep = add(pins, 2, 2, extra=", source = 'Places'")
    add(pins, 3, 3, extra=", source = 'Gathering'")
    assert pins.run("return Pins.Clear('Gathering')") == 2
    assert query(pins) == [keep]


def test_surface_defaults_from_category(pins):
    pins.run("Pins.DefineCategory('inn', { map = true, minimap = false })")
    a = add(pins, 1, 1, category="inn")
    assert query(pins, "map") == [a]
    assert query(pins, "minimap") == []


def test_surface_precedence(pins):
    pins.run("Pins.DefineCategory('herb', { map = true, minimap = true })")
    a = add(pins, 1, 1, category="herb", extra=", key = 'herb:1', show = { minimap = false }")
    # The pin's own `show` beats its category's default.
    assert query(pins, "minimap") == []
    # The user's category choice beats the pin's own.
    pins.run("Pins.SetCategoryOption('herb', 'minimap', true)")
    assert query(pins, "minimap") == [a]
    # The user's choice for this pin beats everything.
    pins.run("Pins.SetPinOption('herb:1', 'minimap', false)")
    assert query(pins, "minimap") == []
    pins.run("Pins.SetPinOption('herb:1', 'minimap', nil)")
    assert query(pins, "minimap") == [a]


def test_category_disabled(pins):
    pins.run("Pins.DefineCategory('stable', { enabled = false })")
    a = add(pins, 1, 1, category="stable")
    assert query(pins) == []
    pins.run("Pins.SetCategoryOption('stable', 'enabled', true)")
    assert query(pins) == [a]


def test_min_zoom(pins):
    pins.run("Pins.DefineCategory('label', { minZoom = 3 })")
    a = add(pins, 1, 1, category="label")
    assert query(pins, zoom=1) == []
    assert query(pins, zoom=3) == [a]
    assert query(pins) == [a]  # no zoom given: any zoom


def test_layer_filter(pins):
    ground = add(pins, 1, 1)
    cave = add(pins, 2, 2, extra=", layer = 1")
    assert query(pins, layer=0) == [ground]
    assert query(pins, layer=1) == [cave]
    assert query(pins) == [ground, cave]


def test_changes_fire_once_per_flush(pins):
    add(pins, 1, 1)
    events = pins.fired("WR_PINS_CHANGED")
    assert events, "adding a pin fires WR_PINS_CHANGED"
    assert events[-1][1][0] is True  # continent 0 is in the changed set
