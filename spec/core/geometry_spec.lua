local Geometry = require("Anodyne.core.geometry")

describe("core geometry", function()
  it("rounds halves with the established floor-plus-half rule", function()
    assert.same({ 2, 1, 0, -1 }, { Geometry.round(1.5), Geometry.round(1.49), Geometry.round(-0.5), Geometry.round(-1.5) })
  end)

  it("clamps scalars and treats an inverted range as its minimum", function()
    assert.same({ 2, 4, 8, 9 }, { Geometry.clamp(1, 2, 8), Geometry.clamp(4, 2, 8), Geometry.clamp(9, 2, 8), Geometry.clamp(3, 9, 2) })
  end)

  it("copies and compares frames without aliasing", function()
    local source = { x = 1.49, y = -2.5, w = 300.49, h = 400.5 }
    local copied = Geometry.copyFrame(source)
    copied.x = 99
    assert.are.equal(1.49, source.x)
    assert.is_true(Geometry.framesEqual(source, { x = 1.4, y = -2.49, w = 300.4, h = 400.6 }))
    assert.is_false(Geometry.framesEqual(source, { x = 2, y = -2.5, w = 300.49, h = 400.5 }))
  end)

  it("clamps oversized frames to a fractional negative-origin screen", function()
    local result = Geometry.clampFrameToScreen({ x = -900.4, y = 80.8, w = 1500.7, h = 1200.8 }, { x = -500.4, y = 20.4, w = 1000.2, h = 700.2 }, 500, 500)
    assert.same({ x = -500, y = 21, w = 1000, h = 700 }, result)
  end)

  it("uses a tiny screen rather than impossible configured minima", function()
    assert.same(
      { x = 10, y = -30, w = 320, h = 240 },
      Geometry.clampFrameToScreen({ x = 99, y = 99, w = 10, h = 10 }, { x = 10, y = -30, w = 320, h = 240 }, 500, 500)
    )
  end)

  it("enforces configured minimum dimensions", function()
    assert.same(
      { x = 100, y = 200, w = 500, h = 550 },
      Geometry.clampFrameToScreen({ x = 0, y = 0, w = 20, h = 550 }, { x = 100, y = 200, w = 1200, h = 900 }, 500, 500)
    )
  end)

  it("allows aspect targets below configured minima", function()
    assert.same({ x = 0, y = 0, w = 3, h = 2 }, Geometry.clampFrameToScreen({ x = 0, y = 0, w = 3, h = 2 }, { x = 0, y = 0, w = 300, h = 200 }, 500, 500, true))
  end)

  it("builds all six corner targets including centered and bottom positions", function()
    local frame = { x = 9, y = 8, w = 200, h = 100 }
    local screen = { x = -100, y = 50, w = 1000, h = 700 }
    local expected = {
      topleft = { x = -100, y = 50, w = 200, h = 100 },
      centertop = { x = 300, y = 50, w = 200, h = 100 },
      topright = { x = 700, y = 50, w = 200, h = 100 },
      bottomleft = { x = -100, y = 650, w = 200, h = 100 },
      centerbottom = { x = 300, y = 650, w = 200, h = 100 },
      bottomright = { x = 700, y = 650, w = 200, h = 100 },
    }
    for corner, target in pairs(expected) do
      assert.same(target, Geometry.cornerTarget(frame, screen, corner))
    end
    assert.same({ x = 9, y = 8, w = 200, h = 100 }, frame)
  end)

  it("rejects an invalid corner without returning an aliased frame", function()
    assert.is_nil(Geometry.cornerTarget({ x = 1, y = 2, w = 3, h = 4 }, { x = 0, y = 0, w = 9, h = 9 }, "middle"))
  end)

  it("fits common aspect ratios while retaining the current width", function()
    local cases = {
      { preset = { width = 16, height = 9 }, expected = { x = 10, y = 20, w = 1600, h = 900 } },
      { preset = { width = 4, height = 3 }, expected = { x = 10, y = 20, w = 1600, h = 1200 } },
      { preset = { width = 2, height = 1 }, expected = { x = 10, y = 20, w = 1600, h = 800 } },
    }
    for _, case in ipairs(cases) do
      assert.same(case.expected, Geometry.aspectTarget({ x = 10, y = 20, w = 1600, h = 700 }, { x = 0, y = 0, w = 2400, h = 1400 }, case.preset, 500, 500))
    end
  end)

  it("fits an aspect ratio to a screen too small for configured minima", function()
    assert.same(
      { x = 4, y = 5, w = 320, h = 180 },
      Geometry.aspectTarget({ x = 4, y = 5, w = 900, h = 700 }, { x = 0, y = 0, w = 320, h = 200 }, { width = 16, height = 9 }, 500, 500)
    )
  end)

  it("snaps dimensions to adjacent step boundaries without mutating its input", function()
    local frame = { x = -5, y = 7, w = 800, h = 600 }
    assert.same({ x = -5, y = 7, w = 850, h = 650 }, Geometry.resizeTarget(frame, 50, 50))
    assert.same({ x = -5, y = 7, w = 750, h = 550 }, Geometry.resizeTarget(frame, -50, -50))
    assert.same({ x = -5, y = 7, w = 800, h = 600 }, frame)
    local unaligned = { x = -5, y = 7, w = 1005, h = 1005 }
    assert.same({ x = -5, y = 7, w = 1050, h = 1050 }, Geometry.resizeTarget(unaligned, 50, 50))
    assert.same({ x = -5, y = 7, w = 1000, h = 1000 }, Geometry.resizeTarget(unaligned, -50, -50))
    assert.same({ x = -5, y = 7, w = 1005, h = 1005 }, unaligned)
    local fractional = { x = -5, y = 7, w = 1005.5, h = 713.5 }
    assert.same({ x = -5, y = 7, w = 1025, h = 713.5 }, Geometry.resizeTarget(fractional, 25, 0))
    assert.same({ x = -5, y = 7, w = 1000, h = 713.5 }, Geometry.resizeTarget(fractional, -25, 0))
    assert.same({ x = -5, y = 7, w = 1005.5, h = 725 }, Geometry.resizeTarget(fractional, 0, 25))
  end)

  it("snaps aligned positions one full step in all directions", function()
    local expected = { left = -75, right = 25, up = -75, down = 25 }
    for direction, value in pairs(expected) do
      assert.are.equal(value, Geometry.snapPosition(-25, -25, 50, direction))
    end
  end)

  it("snaps unaligned positions to adjacent origin-relative lines", function()
    local expected = { left = -25, right = 25, up = -25, down = 25 }
    for direction, value in pairs(expected) do
      assert.are.equal(value, Geometry.snapPosition(-75, -13, 50, direction))
    end
  end)

  it("uses fractional origins for origin-relative snapping", function()
    local expected = { left = -149.5, right = -99.5, up = -149.5, down = -99.5 }
    for direction, value in pairs(expected) do
      assert.are.equal(value, Geometry.snapPosition(-149.5, -102.25, 50, direction))
    end
  end)

  it("builds horizontal and vertical step targets without mutation", function()
    local frame = { x = 13, y = 27, w = 600, h = 500 }
    local screen = { x = -7, y = 7, w = 1200, h = 900 }
    assert.same({ x = 43, y = 27, w = 600, h = 500 }, Geometry.stepTarget(frame, screen, 50, "right"))
    assert.same({ x = 13, y = 7, w = 600, h = 500 }, Geometry.stepTarget(frame, screen, 50, "up"))
    assert.same({ x = 13, y = 27, w = 600, h = 500 }, frame)
  end)

  it("rejects invalid movement directions", function()
    assert.is_nil(Geometry.snapPosition(0, 10, 50, "diagonal"))
    assert.is_nil(Geometry.stepTarget({ x = 0, y = 0, w = 2, h = 2 }, { x = 0, y = 0, w = 9, h = 9 }, 50, "diagonal"))
  end)

  it("has no Hammerspoon, global, window, screen, timer, or UI dependency", function()
    local source = assert(io.open("Anodyne/core/geometry.lua")):read("*a")
    for _, forbidden in ipairs({ "require%s*%(", "_G", "hs%.", "window", "timer", "canvas", "menubar" }) do
      assert.is_nil(source:match(forbidden), forbidden)
    end
  end)
end)
